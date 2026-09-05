import Stripe from 'npm:stripe@18.5.0';
import {
  authenticatedUserId,
  billingAdminClient,
  billingCorsFor,
  billingCorsJson,
  billingPreflight,
  requiredEnv,
} from '../_shared/billing-service.ts';
import { billingCommandFailureDisposition } from '../_shared/billing-command-recovery.ts';
import {
  enforceProviderNoTaxV125,
  stripePendingUpdateParamsV125,
  stripeReductionUpdateParamsV665,
  stripeSubscriptionHasNoTaxV125,
  stripeSubscriptionMatchesCommandV125,
} from '../_shared/billing-tax-policy-v125.ts';

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/* nestly_v791 — Stripe is the platform provider again (owner, 2026-09-06: Razorpay's OTP never
   arrived). This executor is the August one with two additions: BRANCH scope (a v786 command that
   names a branch acts on that branch's own subscription — one unit, metadata.branch_id, its own
   card, its own renewal) and a demo firm's commands going to STRIPE_TEST_SECRET_KEY when that
   secret exists, so a demo never moves money once the platform key is live. */
async function stripeSecretKeyFor(
  admin: ReturnType<typeof billingAdminClient>,
  businessId: string,
): Promise<{ secretKey: string; mode: 'live' | 'test' }> {
  const live = requiredEnv('STRIPE_SECRET_KEY');
  const test = (Deno.env.get('STRIPE_TEST_SECRET_KEY') || '').trim();
  if (!test) return { secretKey: live, mode: 'live' };
  try {
    const { data, error } = await admin.from('businesses').select('is_demo').eq('id', businessId).maybeSingle();
    if (!error && data?.is_demo === true) return { secretKey: test, mode: 'test' };
  } catch { /* unreadable is not demo */ }
  return { secretKey: live, mode: 'live' };
}

/* The base subscription item of a subscription, read from the mirror. A branch subscription is
   ONE item; its id is what a price change is applied to. */
async function baseItemIdFor(
  admin: ReturnType<typeof billingAdminClient>,
  subscriptionId: string,
): Promise<string> {
  const { data } = await admin
    .from('billing_provider_subscription_items')
    .select('provider_item_id,item_role,updated_at')
    .eq('provider_subscription_id', subscriptionId)
    .order('updated_at', { ascending: false })
    .limit(5);
  const rows = (data || []) as Array<{ provider_item_id: string; item_role: string }>;
  const base = rows.find((row) => row.item_role === 'base') || rows[0];
  return base ? String(base.provider_item_id) : '';
}

function returnOrigin(): string {
  const configured = new URL(requiredEnv('BILLING_RETURN_ORIGIN'));
  if (
    configured.protocol !== 'https:' ||
    configured.username ||
    configured.password ||
    configured.pathname !== '/' ||
    configured.search ||
    configured.hash
  ) {
    throw new Error('billing service unavailable');
  }
  return configured.origin;
}

async function validateV124Prices(
  stripe: Stripe,
  data: Record<string, unknown>,
): Promise<void> {
  if (data.pricing_model !== 'v124_customer_capacity') return;
  if (data.tax_behavior !== 'exclusive') {
    throw new Error('Peekaa is not GST-registered; catalogue tax behavior must be exclusive');
  }
  const cadence = String(data.requested_cadence || '');
  const expectedInterval = cadence === 'annual' ? 'year' : 'month';
  const expectedBase = Number(data.base_amount_cents);
  const expectedCapacity = Number(data.capacity_block_amount_cents);
  /* nestly_v664: under tiered capacity the whole price is the base price and there is no capacity
     line item at all, so the claim sends provider_capacity_price_id = null. Retrieving "null" from
     Stripe would fail the checkout with an unrelated error; a catalogue that names no capacity
     price simply has no second price to validate. The BASE price is still validated against the
     tier amount the owner was shown, which is the check that matters. */
  const capacityPriceId = data.provider_capacity_price_id
    ? String(data.provider_capacity_price_id)
    : '';
  const [basePrice, capacityPrice] = await Promise.all([
    stripe.prices.retrieve(String(data.provider_base_price_id)),
    capacityPriceId ? stripe.prices.retrieve(capacityPriceId) : Promise.resolve(null),
  ]);
  const valid = (
    price: Stripe.Price,
    expectedAmount: number,
  ): boolean =>
    price.active === true &&
    price.type === 'recurring' &&
    price.currency.toUpperCase() === String(data.currency || '').toUpperCase() &&
    price.unit_amount === expectedAmount &&
    price.recurring?.interval === expectedInterval &&
    price.recurring?.interval_count === 1 &&
    price.recurring?.usage_type === 'licensed' &&
    price.tax_behavior === 'exclusive';
  if (
    !valid(basePrice, expectedBase) ||
    (capacityPrice !== null && !valid(capacityPrice, expectedCapacity))
  ) {
    throw new Error('Stripe prices do not match the reviewed V124 catalogue');
  }
}

async function retrieveRecoveredProviderResult(
  stripe: Stripe,
  commandType: string,
  providerObjectId: string,
  data: Record<string, unknown>,
  expectedBaseQuantity = 1,
): Promise<{ providerObjectId: string; redirectUrl?: string } | null> {
  if (commandType === 'create_checkout') {
    const session = await stripe.checkout.sessions.retrieve(providerObjectId);
    return session.url
      ? { providerObjectId: session.id, redirectUrl: session.url }
      : null;
  }
  if (
    /* v621: change_branches now recovers the same way the other item-shape commands do —
       without it, an 'uncertain' branch command had no server-side resolution path at all. */
    ['change_cadence', 'change_capacity', 'change_branches', 'cancel_at_period_end', 'resume'].includes(commandType)
  ) {
    const subscription = await stripe.subscriptions.retrieve(providerObjectId);
    return stripeSubscriptionMatchesCommandV125(
      subscription, commandType, data, expectedBaseQuantity,
    )
      ? { providerObjectId: subscription.id }
      : null;
  }
  return null;
}

Deno.serve(async (req) => {
  const preflight = billingPreflight(req);
  if (preflight) return preflight;
  if (!billingCorsFor(req)) {
    return billingCorsJson(req, 403, { error: 'origin_not_allowed' });
  }
  if (req.method !== 'POST') {
    return billingCorsJson(req, 405, { error: 'method_not_allowed' });
  }

  let actor = '';
  try {
    actor = await authenticatedUserId(req);
  } catch (authError) {
    /* V208: name WHICH auth step failed. A bare 401 cost a live debugging session on a real
       branch purchase — no token, a rejected token and a missing service key looked identical. */
    const reason = String((authError as Error)?.message || 'authentication_required');
    return billingCorsJson(req, 401, { error: 'authentication_required', reason });
  }

  let commandId = '';
  try {
    const length = Number(req.headers.get('content-length') || '0');
    if (length > 2048 || !req.headers.get('content-type')?.includes('application/json')) {
      return billingCorsJson(req, 400, { error: 'invalid_request' });
    }
    const body = await req.json();
    commandId = typeof body?.command_id === 'string' ? body.command_id : '';
  } catch {
    return billingCorsJson(req, 400, { error: 'invalid_request' });
  }
  if (!UUID.test(commandId)) {
    return billingCorsJson(req, 400, { error: 'invalid_request' });
  }

  let claimed: Record<string, unknown> | null = null;
  let admin: ReturnType<typeof billingAdminClient> | null = null;
  let providerCallStarted = false;
  let providerObjectId = '';
  let redirectUrl = '';
  try {
    admin = billingAdminClient();
    // v786 answers a branch-scoped command; business scope delegates to V130 -> V124 -> V77.
    const { data, error } = await admin.rpc('claim_billing_command_v786', {
      p_command: commandId,
      p_actor: actor,
    });
    if (error || !data) {
      return billingCorsJson(req, 403, { error: 'command_not_available' });
    }
    claimed = data;
    if (['completed', 'failed', 'canceled'].includes(String(data.status))) {
      return billingCorsJson(req, 200, data);
    }

    const commandType = String(data.command_type);
    const businessId = String(data.business_id);
    const branchScope = String(data.scope || '') === 'branch';
    const branchId = branchScope && typeof data.branch_id === 'string' ? data.branch_id : '';
    const account = await stripeSecretKeyFor(admin, businessId);
    const stripe = new Stripe(account.secretKey, {
      httpClient: Stripe.createFetchHttpClient(),
    });
    const origin = returnOrigin();
    const idempotencyKey = String(data.provider_idempotency_key);
    const cadence = data.requested_cadence ? String(data.requested_cadence) : '';
    const requestedCustomerCapacity = Number(data.requested_customer_capacity || 0);
    const customerId = data.provider_customer_id
      ? String(data.provider_customer_id)
      : undefined;
    const subscriptionId = data.provider_subscription_id
      ? String(data.provider_subscription_id)
      : undefined;
    redirectUrl = `${origin}/#/settings`;

    /* V202 — an extra branch costs exactly what a firm costs (owner ruling 2026-08-07:
       "same price $99/month billed annually (same as normal)"), so it is billed as another
       UNIT OF THE BASE PLAN rather than as a new Stripe price. Counting here, from the
       service-role client, keeps claim_billing_command_v130 untouched — that RPC is on the
       live payment path for every existing command type and is not worth reshaping for this.
       Grandfathered branches are 'included' and deliberately excluded: the owner already had
       them, so they are never back-charged. */
    /* V280 (owner, live bar tenant: "why when add branch = pay for 2 branch? i only added 1 new
       branch - the older one is manual payment"). The count above is right; the CONSTANT 1 was
       not. That 1 is the firm's own base unit, and it belongs in the Stripe quantity only when
       Stripe is the thing collecting the base plan. Bistro 999 pays for the firm outside Stripe,
       so its branch checkout asked for 1 (firm) + 1 (branch) = two units of the plan — the firm a
       second time, plus the one branch they actually bought.

       Whether Stripe collects the base is recorded on the subscription
       (subscriptions.provider_covers_base_unit, V280 migration): true for every firm whose
       subscription was created by the Settings checkout, and set to false by
       business_add_branch_v202 when the checkout it mints exists only to pay for a branch.
       Unknown (column absent, row missing, SELECT failed) resolves by intent: a branch command
       bills branches only. Every unknown therefore under-bills rather than over-bills, which is
       the same direction the V202 fail-closed comment chose. */
    let planUnits = 1;
    {
      const [branchCount, commandRow, subscriptionRow] = await Promise.all([
        admin
          .from('branches')
          .select('id', { count: 'exact', head: true })
          .eq('business_id', businessId)
          .in('billing_state', ['pending_payment', 'active'])
          .eq('billing_mode', 'shared'),
        admin
          .from('billing_commands')
          .select('requested_branch_id')
          .eq('id', commandId)
          .maybeSingle(),
        admin
          .from('subscriptions')
          .select('provider_covers_base_unit')
          .eq('business_id', businessId)
          .maybeSingle(),
      ]);
      const { count, error: branchError } = branchCount;
      const isBranchCommand = commandType === 'change_branches' ||
        Boolean(commandRow?.data?.requested_branch_id);
      const declaredBaseCoverage = subscriptionRow?.error
        ? null
        : subscriptionRow?.data?.provider_covers_base_unit;
      const baseUnits = (
        typeof declaredBaseCoverage === 'boolean' ? declaredBaseCoverage : !isBranchCommand
      )
        ? 1
        : 0;
      /* Fail closed on an unreadable count: a branch command is paying for the one branch it
         names, and a base command adds nothing. Over-charging a firm because a SELECT failed is
         the one outcome that must not happen. */
      const branchUnits = !branchError && typeof count === 'number'
        ? count
        : (isBranchCommand ? 1 : 0);
      planUnits = Math.max(1, baseUnits + branchUnits);
      /* v786/v791: a branch's own subscription is exactly one unit. */
      if (branchScope) planUnits = 1;
    }
    /* v786: only SHARED branches are units of the company subscription. */
    let providerResolved = false;
    let providerConfirmationPending = false;

    if (
      data.pricing_model === 'v124_customer_capacity' &&
      ['create_checkout', 'change_cadence', 'change_capacity', 'change_branches'].includes(commandType)
    ) {
      providerCallStarted = true;
      await validateV124Prices(stripe, data);
      providerCallStarted = false;
    }

    const portalRecoveryReplay =
      data.recovery_required && commandType === 'create_portal';
    if (
      data.recovery_required &&
      data.prior_provider_object_id &&
      !portalRecoveryReplay
    ) {
      providerCallStarted = true;
      try {
        if (
          ['change_cadence', 'change_capacity', 'change_branches',
            'cancel_at_period_end', 'resume'].includes(commandType)
        ) {
          await enforceProviderNoTaxV125(
            stripe,
            String(data.prior_provider_object_id),
            idempotencyKey,
          );
        }
        const recovered = await retrieveRecoveredProviderResult(
          stripe,
          commandType,
          String(data.prior_provider_object_id),
          data,
          planUnits,
        );
        if (recovered) {
          providerObjectId = recovered.providerObjectId;
          redirectUrl = recovered.redirectUrl || redirectUrl;
          providerResolved = true;
        }
      } catch {
        // Replaying the exact Stripe request below uses the same stable
        // idempotency key and is the recovery path when retrieval is unavailable.
      }
    }

    if (!providerResolved && commandType === 'create_checkout') {
      const lineItems: Stripe.Checkout.SessionCreateParams.LineItem[] = [
        { price: String(data.provider_base_price_id), quantity: planUnits },
      ];
      const capacityModel = data.pricing_model === 'v124_customer_capacity';
      const extraItemQuantity = Number(
        capacityModel ? data.extra_capacity_blocks || 0 : data.extra_seats || 0,
      );
      if (extraItemQuantity > 0) {
        lineItems.push({
          price: String(
            capacityModel
              ? data.provider_capacity_price_id
              : data.provider_seat_price_id,
          ),
          quantity: extraItemQuantity,
        });
      }
      providerCallStarted = true;
      const selfServiceOnboarding = data.self_service_onboarding === true;
      const session = await stripe.checkout.sessions.create(
        {
          mode: 'subscription',
          customer: customerId,
          client_reference_id: businessId,
          line_items: lineItems,
          automatic_tax: { enabled: false },
          success_url: selfServiceOnboarding
            ? `${origin}/business#/onboarding/payment?status=processing`
            : `${origin}/#/settings?billing=processing`,
          cancel_url: selfServiceOnboarding
            ? `${origin}/business#/onboarding/payment?status=canceled`
            : `${origin}/#/settings?billing=canceled`,
          metadata: {
            business_id: businessId,
            cadence,
            pricing_model: String(data.pricing_model || 'legacy_seat'),
            customer_capacity: String(requestedCustomerCapacity || ''),
            ...(branchId ? { branch_id: branchId } : {}),
          },
          subscription_data: {
            default_tax_rates: [],
            metadata: {
              business_id: businessId,
              cadence,
              pricing_model: String(data.pricing_model || 'legacy_seat'),
              customer_capacity: String(requestedCustomerCapacity || ''),
              ...(branchId ? { branch_id: branchId } : {}),
            },
          },
        },
        { idempotencyKey },
      );
      if (!session.url) throw new Error('Stripe Checkout did not return a redirect');
      providerObjectId = session.id;
      redirectUrl = session.url;
    } else if (!providerResolved && commandType === 'create_portal') {
      if (!customerId) throw new Error('Stripe customer is not linked');
      // Billing Portal sessions have no retrieve endpoint. A recovery attempt
      // explicitly replays this identical create with the command's stable
      // Stripe idempotency key.
      providerCallStarted = true;
      const session = await stripe.billingPortal.sessions.create(
        { customer: customerId, return_url: `${origin}/#/settings` },
        { idempotencyKey },
      );
      providerObjectId = session.id;
      redirectUrl = session.url;
    } else if (
      !providerResolved &&
      ['change_cadence', 'change_capacity', 'change_branches'].includes(commandType)
    ) {
      if (branchScope && subscriptionId && !data.provider_base_item_id) {
        data.provider_base_item_id = await baseItemIdFor(admin, subscriptionId);
      }
      if (!subscriptionId || !data.provider_base_item_id) {
        throw new Error('Stripe subscription items are not linked');
      }
      if (branchScope && commandType !== 'change_cadence') {
        throw new Error('a branch subscription only changes its billing cycle');
      }
      providerCallStarted = true;
      await enforceProviderNoTaxV125(
        stripe,
        subscriptionId,
        idempotencyKey,
      );
      const capacityModel = data.pricing_model === 'v124_customer_capacity';
      const extraItemQuantity = Number(
        capacityModel ? data.extra_capacity_blocks || 0 : data.extra_seats || 0,
      );
      const extraItemId = capacityModel
        ? data.provider_capacity_item_id
        : data.provider_seat_item_id;
      const extraPriceId = capacityModel
        ? data.provider_capacity_price_id
        : data.provider_seat_price_id;
      const itemsById = new Map<string, Stripe.SubscriptionUpdateParams.Item>();
      itemsById.set(String(data.provider_base_item_id), {
          id: String(data.provider_base_item_id),
          price: String(data.provider_base_price_id),
          quantity: planUnits,
        });
      if (extraItemId) {
        itemsById.set(
          String(extraItemId),
          extraItemQuantity > 0
            ? {
                id: String(extraItemId),
                price: String(extraPriceId),
                quantity: extraItemQuantity,
              }
            : { id: String(extraItemId), deleted: true },
        );
      } else if (extraItemQuantity > 0) {
        itemsById.set('__new_capacity_item__', {
          price: String(extraPriceId),
          quantity: extraItemQuantity,
        });
      }
      const items = [...itemsById.values()];
      /* nestly_v665: proration follows DIRECTION. The owner's two rules are opposites — a branch
         added part-way through a paid period is invoiced for the time left in it, and a branch
         unsubscribed is not refunded, it simply stops renewing. Reading the quantity Stripe holds
         right now is the only way to know which of the two this update is; a failed read falls
         through to the existing always_invoice path, which is the one that cannot lose money. */
      let reducesQuantity = false;
      try {
        const current = await stripe.subscriptions.retrieve(subscriptionId);
        const currentBase = (current.items?.data || []).find(
          (item) => item.id === String(data.provider_base_item_id || ''),
        );
        reducesQuantity = typeof currentBase?.quantity === 'number' &&
          planUnits < currentBase.quantity;
      } catch {
        reducesQuantity = false;
      }
      const metadata = {
        business_id: businessId,
        cadence,
        pricing_model: String(data.pricing_model || 'legacy_seat'),
        customer_capacity: String(requestedCustomerCapacity || ''),
        ...(branchId ? { branch_id: branchId } : {}),
      };
      const subscription = await stripe.subscriptions.update(
        subscriptionId,
        capacityModel
          ? (reducesQuantity
              ? stripeReductionUpdateParamsV665(items, metadata)
              : stripePendingUpdateParamsV125(items, metadata))
          : { items, proration_behavior: 'none', metadata },
        { idempotencyKey },
      );
      const verifiedSubscription = await stripe.subscriptions.retrieve(subscriptionId);
      if (!stripeSubscriptionHasNoTaxV125(verifiedSubscription)) {
        throw new Error('Stripe subscription retained a tax configuration');
      }
      providerObjectId = subscription.id;
      providerConfirmationPending =
        capacityModel && verifiedSubscription.pending_update !== null;
      if (
        !providerConfirmationPending &&
        !stripeSubscriptionMatchesCommandV125(verifiedSubscription, commandType, data, planUnits)
      ) {
        throw new Error('Stripe subscription does not match the requested command');
      }
    } else if (
      !providerResolved &&
      (commandType === 'cancel_at_period_end' || commandType === 'resume')
    ) {
      if (!subscriptionId) throw new Error('Stripe subscription is not linked');
      providerCallStarted = true;
      await enforceProviderNoTaxV125(
        stripe,
        subscriptionId,
        idempotencyKey,
      );
      const subscription = await stripe.subscriptions.update(
        subscriptionId,
        {
          cancel_at_period_end: commandType === 'cancel_at_period_end',
        },
        { idempotencyKey },
      );
      const verifiedSubscription = await stripe.subscriptions.retrieve(subscriptionId);
      if (!stripeSubscriptionHasNoTaxV125(verifiedSubscription)) {
        throw new Error('Stripe subscription retained a tax configuration');
      }
      if (!stripeSubscriptionMatchesCommandV125(verifiedSubscription, commandType, data, planUnits)) {
        throw new Error('Stripe subscription does not match the requested command');
      }
      providerObjectId = subscription.id;
    } else if (!providerResolved && commandType === 'update_card') {
      /* v764 ruling 5 on Stripe: the customer's own Billing Portal, where the card is changed;
         the portal returns to Settings and the nightly backfill (or refresh_payment_method)
         reads the new digits. */
      const portalCustomer = customerId || (subscriptionId
        ? String((await stripe.subscriptions.retrieve(subscriptionId)).customer || '')
        : '');
      if (!portalCustomer) throw new Error('Stripe customer is not linked');
      providerCallStarted = true;
      const session = await stripe.billingPortal.sessions.create(
        { customer: portalCustomer, return_url: `${origin}/#/settings?billing=card_updated` },
        { idempotencyKey },
      );
      providerObjectId = session.id;
      redirectUrl = session.url;
    } else if (!providerResolved && commandType === 'refresh_payment_method') {
      if (!subscriptionId) throw new Error('Stripe subscription is not linked');
      providerCallStarted = true;
      const current = await stripe.subscriptions.retrieve(subscriptionId, {
        expand: ['default_payment_method', 'customer.invoice_settings.default_payment_method'],
      });
      const method = (current.default_payment_method ||
        (current.customer as Stripe.Customer)?.invoice_settings?.default_payment_method) as
          Stripe.PaymentMethod | null;
      const card = method && typeof method === 'object' ? method.card : null;
      if (card?.last4) {
        const args = {
          p_payment_id: String(method?.id || ''),
          p_kind: 'card',
          p_brand: String(card.brand || '').replace(/^\w/, (c) => c.toUpperCase()),
          p_last4: String(card.last4),
        };
        const { error: writeError } = branchId
          ? await admin.rpc('set_branch_payment_method_v786', { p_branch: branchId, ...args })
          : await admin.rpc('set_billing_payment_method_v758', { p_business: businessId, ...args });
        if (writeError) throw new Error('payment method write rejected');
      }
      providerCallStarted = false;
      providerObjectId = subscriptionId;
    } else if (!providerResolved) {
      throw new Error('billing command is not executable');
    }

    if (providerConfirmationPending) {
      const { data: pending, error: pendingError } = await admin.rpc(
        'complete_billing_command_v77',
        {
          p_command: commandId,
          p_status: 'uncertain',
          p_provider_object_id: providerObjectId,
          p_redirect_url: null,
          p_error_code: 'provider_confirmation_pending',
          p_error_message:
            'Stripe has not confirmed the prorated subscription change. Retry this command ID after payment confirmation.',
        },
      );
      if (pendingError) {
        throw new Error('billing command pending-state persistence failed');
      }
      return billingCorsJson(req, 202, {
        command_id: commandId,
        status: pending?.status || 'uncertain',
        error: 'provider_confirmation_pending',
      });
    }

    const { data: completed, error: completionError } = await admin.rpc(
      'complete_billing_command_v77',
      {
        p_command: commandId,
        p_status: 'completed',
        p_provider_object_id: providerObjectId,
        p_redirect_url: redirectUrl,
        p_error_code: null,
        p_error_message: null,
      },
    );
    if (completionError) {
      throw new Error('billing command completion persistence failed');
    }
    return billingCorsJson(req, 200, {
      command_id: commandId,
      status: completed?.status || 'completed',
      redirect_url: completed?.redirect_url || redirectUrl,
    });
  } catch (error) {
    const stripeError = error as {
      code?: string;
      type?: string;
      message?: string;
    };
    const priorExecutionWasUncertain = claimed?.recovery_required === true;
    const nonExecutionProven =
      !priorExecutionWasUncertain &&
      (!providerCallStarted ||
        error instanceof Stripe.errors.StripeInvalidRequestError);
    const disposition = billingCommandFailureDisposition({
      providerCallStarted,
      nonExecutionProven,
    });
    if (commandId && claimed && admin) {
      const persistence = await admin.rpc('complete_billing_command_v77', {
        p_command: commandId,
        p_status: disposition,
        p_provider_object_id:
          disposition === 'uncertain' ? providerObjectId || null : null,
        p_redirect_url:
          disposition === 'uncertain' ? redirectUrl || null : null,
        p_error_code:
          disposition === 'uncertain'
            ? 'provider_result_uncertain'
            : stripeError.code || stripeError.type || 'command_failed',
        p_error_message:
          disposition === 'uncertain'
            ? 'Provider execution may have succeeded; retry this command ID to retrieve or replay the same Stripe idempotency result.'
            : stripeError.message || 'billing command failed before provider execution',
      });
      if (persistence.error && disposition === 'uncertain') {
        console.error('billing command uncertain-state persistence failed', {
          command_id: commandId,
        });
      }
    }
    const uncertain = disposition === 'uncertain';
    return billingCorsJson(req, uncertain ? 202 : 500, {
      command_id: commandId || undefined,
      status: disposition,
      error: uncertain
        ? 'billing_command_outcome_uncertain'
        : 'billing_command_failed',
      recovery: uncertain ? 'retry_same_command_id' : undefined,
    });
  }
});
