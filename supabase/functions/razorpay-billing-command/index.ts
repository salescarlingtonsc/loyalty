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
  livemodeFromKey,
  razorpayClient,
  razorpayPlanMatchesCatalogue,
  RazorpayApiError,
  type RazorpayClient,
  type RazorpaySubscription,
} from '../_shared/razorpay-client.ts';

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/* Razorpay requires total_count (number of billing cycles) and has no "until cancelled" option.
   These are the practical forevers: 100 years monthly, 100 years annually. A subscription that
   reaches the end simply completes; nobody in this product will. */
const TOTAL_COUNT_MONTHLY = 1200;
const TOTAL_COUNT_ANNUAL = 100;
const CHECKOUT_EXPIRY_SECONDS = 7 * 24 * 60 * 60;

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

/* Test-mode override so a live plan id can be pointed at without a migration. Keys are the
   catalogue's own provider_*_price_id values (or a catalogue key); the value is a Razorpay
   plan id. A malformed JSON blob disables the override rather than the function. */
function planIdOverrides(): Record<string, string> {
  try {
    const parsed = JSON.parse(Deno.env.get('RAZORPAY_PLAN_MAP_JSON') || '{}');
    return parsed && typeof parsed === 'object' ? parsed as Record<string, string> : {};
  } catch {
    return {};
  }
}

function resolvePlanId(catalogueId: string): string {
  const overrides = planIdOverrides();
  return overrides[catalogueId] || catalogueId;
}

async function validateV755Plan(
  razorpay: RazorpayClient,
  data: Record<string, unknown>,
  planId: string,
): Promise<void> {
  if (data.pricing_model !== 'v124_customer_capacity') return;
  /* Peekaa is not GST-registered (V125). The catalogue must still declare exclusive pricing;
     Razorpay has no automatic tax to disable, so nothing is ever added to the plan amount. */
  if (data.tax_behavior !== 'exclusive') {
    throw new Error('Peekaa is not GST-registered; catalogue tax behavior must be exclusive');
  }
  const plan = await razorpay.getPlan(planId);
  if (
    !razorpayPlanMatchesCatalogue(plan, {
      cadence: String(data.requested_cadence || ''),
      amountCents: Number(data.base_amount_cents),
      currency: String(data.currency || 'SGD'),
    })
  ) {
    throw new Error('Razorpay plans do not match the reviewed catalogue');
  }
}

function subscriptionNotes(
  businessId: string,
  data: Record<string, unknown>,
  commandId: string,
): Record<string, string> {
  return {
    business_id: businessId,
    cadence: String(data.requested_cadence || ''),
    pricing_model: String(data.pricing_model || 'legacy_seat'),
    customer_capacity: String(Number(data.requested_customer_capacity || 0) || ''),
    command_id: commandId,
    /* The return function reads this back from Razorpay (not from the query string) to decide
       which success/cancel route the browser is sent to, so a tampered redirect cannot move a
       self-serve signup onto the owner settings route or vice versa. */
    self_serve: data.self_service_onboarding === true ? '1' : '0',
  };
}

/* Razorpay has no Idempotency-Key header. The stand-in is the command id written into notes:
   before creating anything, look for a subscription this command already created. This is also
   the recovery path for a 'recovery_required' row whose prior provider object id is unknown. */
async function findSubscriptionByCommand(
  razorpay: RazorpayClient,
  planId: string,
  commandId: string,
): Promise<RazorpaySubscription | null> {
  const page = await razorpay.listSubscriptions({ plan_id: planId, count: 100 });
  const items = page?.items || [];
  return items.find((item) => String(item.notes?.command_id || '') === commandId) || null;
}

function checkoutRedirectUrl({
  origin,
  subscriptionId,
  keyId,
  commandId,
  description,
  cancelUrl,
}: {
  origin: string;
  subscriptionId: string;
  keyId: string;
  commandId: string;
  description: string;
  cancelUrl: string;
}): string {
  /* No secrets travel in this URL: the publishable key id, the subscription id and two of our
     own routes. The page it opens loads Razorpay Checkout with them and nothing else. */
  const params = new URLSearchParams({
    sid: subscriptionId,
    key: keyId,
    name: 'Peekaa',
    desc: description,
    cb: `${Deno.env.get('SUPABASE_URL') || ''}/functions/v1/razorpay-billing-return?cmd=${commandId}`,
    cancel: cancelUrl,
    color: '#0f766e',
  });
  /* The Vercel project's Root Directory is `app`, so app/razorpay-checkout.html is served at
     the ORIGIN ROOT — `/razorpay-checkout.html`, never `/app/...`. (`/app` is a rewrite to
     index.gen.html, so the wrong path would have served the app shell instead of the
     payment page and the checkout would simply never have opened.) */
  return `${origin}/razorpay-checkout.html#${params.toString()}`;
}

async function retrieveRecoveredProviderResult(
  razorpay: RazorpayClient,
  commandType: string,
  providerObjectId: string,
): Promise<RazorpaySubscription | null> {
  if (
    ![
      'create_checkout',
      'change_cadence',
      'change_capacity',
      'change_branches',
      'cancel_at_period_end',
      'resume',
    ].includes(commandType)
  ) {
    return null;
  }
  return await razorpay.getSubscription(providerObjectId);
}

/* Verification after a PATCH/cancel/resume: the fresh subscription must actually carry the shape
   the command asked for. Unlike Stripe there are no line items — the plan id and the quantity
   ARE the shape. A change Razorpay scheduled for cycle end is not yet visible here, which is
   exactly what has_scheduled_changes reports and why the capacity model treats it as uncertain. */
function subscriptionMatchesCommandV755(
  subscription: RazorpaySubscription,
  commandType: string,
  expectedPlanId: string,
  expectedQuantity: number,
): boolean {
  if (!['change_cadence', 'change_capacity', 'change_branches'].includes(commandType)) {
    return false;
  }
  /* A change Razorpay scheduled for cycle end is not visible on the live subscription yet, which
     is exactly what has_scheduled_changes reports — the capacity model treats that as uncertain
     (above) rather than matched, and the quantity models accept it as applied-as-requested. */
  if (subscription.has_scheduled_changes === true) return true;
  return (
    String(subscription.plan_id) === expectedPlanId &&
    Number(subscription.quantity || 0) === expectedQuantity
  );
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
    /* V208: name WHICH auth step failed — no token, a rejected token and a missing service key
       used to look identical from a bare 401 and cost a live debugging session. */
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
  let nonExecutionProvenByProvider = false;
  let providerObjectId = '';
  let redirectUrl = '';
  try {
    admin = billingAdminClient();
    // V130 decorates the V124 dispatcher with the locked self-service return
    // route; V124 still delegates historical commands to V77.
    const { data, error } = await admin.rpc('claim_billing_command_v130', {
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

    const keyId = requiredEnv('RAZORPAY_KEY_ID');
    const razorpay = razorpayClient({
      keyId,
      keySecret: requiredEnv('RAZORPAY_KEY_SECRET'),
    });
    const origin = returnOrigin();
    const commandType = String(data.command_type);
    const businessId = String(data.business_id);
    const cadence = data.requested_cadence ? String(data.requested_cadence) : '';
    const subscriptionId = data.provider_subscription_id
      ? String(data.provider_subscription_id)
      : undefined;
    const selfServiceOnboarding = data.self_service_onboarding === true;
    const successUrl = selfServiceOnboarding
      ? `${origin}/business#/onboarding/payment?status=processing`
      : `${origin}/#/settings?billing=processing`;
    const cancelUrl = selfServiceOnboarding
      ? `${origin}/business#/onboarding/payment?status=canceled`
      : `${origin}/#/settings?billing=canceled`;
    redirectUrl = `${origin}/#/settings`;

    /* V202/V280 — an extra branch costs exactly what a firm costs, so it is billed as another
       UNIT OF THE BASE PLAN (Razorpay: `quantity`) rather than as a second plan. The constant 1
       is the firm's own base unit and belongs in the quantity only when the provider is the thing
       collecting the base plan; subscriptions.provider_covers_base_unit records that, and every
       unknown resolves to UNDER-billing rather than over-billing. Grandfathered branches are
       'included' and deliberately excluded — the owner already had them. */
    let planUnits = 1;
    {
      const [branchCount, commandRow, subscriptionRow] = await Promise.all([
        admin
          .from('branches')
          .select('id', { count: 'exact', head: true })
          .eq('business_id', businessId)
          .in('billing_state', ['pending_payment', 'active']),
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
         names, and a base command adds nothing. Over-charging because a SELECT failed is the one
         outcome that must not happen. */
      const branchUnits = !branchError && typeof count === 'number'
        ? count
        : (isBranchCommand ? 1 : 0);
      planUnits = Math.max(1, baseUnits + branchUnits);
    }

    const capacityModel = data.pricing_model === 'v124_customer_capacity';
    const cataloguePlanId = String(data.provider_base_price_id || '');
    const planId = resolvePlanId(cataloguePlanId);
    /* Razorpay subscriptions carry exactly ONE plan; there is no second line item to hold extra
       capacity blocks or extra seats. Under the v664 tiered model the whole price is the base
       plan, which is the shape this executor supports. A catalogue row that still asks for a
       separate extra-quantity item is refused rather than silently under-charged. */
    const extraItemQuantity = Number(
      capacityModel ? data.extra_capacity_blocks || 0 : data.extra_seats || 0,
    );
    if (
      extraItemQuantity > 0 &&
      ['create_checkout', 'change_cadence', 'change_capacity', 'change_branches'].includes(
        commandType,
      )
    ) {
      throw new Error(
        'Razorpay subscriptions carry one plan; the catalogue must price the whole tier as the base plan',
      );
    }

    let providerResolved = false;
    let providerConfirmationPending = false;

    if (
      capacityModel &&
      ['create_checkout', 'change_cadence', 'change_capacity', 'change_branches'].includes(
        commandType,
      )
    ) {
      if (!planId) throw new Error('Razorpay plan is not configured for this catalogue row');
      providerCallStarted = true;
      await validateV755Plan(razorpay, data, planId);
      providerCallStarted = false;
    }

    const portalRecoveryReplay = data.recovery_required && commandType === 'create_portal';
    if (data.recovery_required && data.prior_provider_object_id && !portalRecoveryReplay) {
      providerCallStarted = true;
      try {
        const recovered = await retrieveRecoveredProviderResult(
          razorpay,
          commandType,
          String(data.prior_provider_object_id),
        );
        if (recovered) {
          providerObjectId = recovered.id;
          if (commandType === 'create_checkout') {
            redirectUrl = checkoutRedirectUrl({
              origin,
              subscriptionId: recovered.id,
              keyId,
              commandId,
              description: `Peekaa ${cadence || 'subscription'}`,
              cancelUrl,
            });
          }
          providerResolved = true;
        }
      } catch {
        /* Retrieval unavailable: the notes-based lookup below is the replacement for Stripe's
           stable idempotency key and finds anything this command already created. */
      }
      providerCallStarted = false;
    }

    if (!providerResolved && commandType === 'create_checkout') {
      if (!planId) throw new Error('Razorpay plan is not configured for this catalogue row');
      providerCallStarted = true;
      let subscription = await findSubscriptionByCommand(razorpay, planId, commandId);
      if (!subscription) {
        subscription = await razorpay.createSubscription({
          plan_id: planId,
          quantity: planUnits,
          total_count: cadence === 'annual' ? TOTAL_COUNT_ANNUAL : TOTAL_COUNT_MONTHLY,
          customer_notify: 0,
          expire_by: Math.floor(Date.now() / 1000) + CHECKOUT_EXPIRY_SECONDS,
          notes: subscriptionNotes(businessId, data, commandId),
        });
      }
      if (!subscription?.id) throw new Error('Razorpay did not return a subscription');
      providerObjectId = subscription.id;
      /* The redirect is a page of OURS that opens Razorpay Checkout — it is not, and must never
         be treated as, evidence that anything was paid. Only subscription.charged does that. */
      redirectUrl = checkoutRedirectUrl({
        origin,
        subscriptionId: subscription.id,
        keyId,
        commandId,
        description: `Peekaa ${cadence || 'subscription'}`,
        cancelUrl,
      });
    } else if (!providerResolved && commandType === 'create_portal') {
      /* Razorpay has no customer billing portal. Completing 'failed' with a named code is the
         honest answer: the client no longer offers the button, and any stale caller learns why
         instead of being redirected somewhere that does not exist. */
      const { data: unavailable, error: unavailableError } = await admin.rpc(
        'complete_billing_command_v77',
        {
          p_command: commandId,
          p_status: 'failed',
          p_provider_object_id: null,
          p_redirect_url: null,
          p_error_code: 'provider_portal_unavailable',
          p_error_message:
            'Razorpay does not provide a customer billing portal. Manage the subscription from Peekaa settings.',
        },
      );
      if (unavailableError) {
        throw new Error('billing command completion persistence failed');
      }
      return billingCorsJson(req, 200, {
        command_id: commandId,
        status: unavailable?.status || 'failed',
        error: 'provider_portal_unavailable',
      });
    } else if (
      !providerResolved &&
      ['change_cadence', 'change_capacity', 'change_branches'].includes(commandType)
    ) {
      if (!subscriptionId) throw new Error('Razorpay subscription is not linked');
      if (!planId) throw new Error('Razorpay plan is not configured for this catalogue row');
      providerCallStarted = true;
      const current = await razorpay.getSubscription(subscriptionId);
      /* nestly_v665 proration rule, carried over: DIRECTION decides when the change takes
         effect. More units (or a higher tier) start now and are charged; fewer units take effect
         at cycle end so nothing is refunded and the owner keeps what they paid for until the
         billing date. A cadence change is always cycle_end — switching mid-period would rebase
         the period the owner has already paid for. */
      let scheduleChangeAt: 'now' | 'cycle_end';
      if (commandType === 'change_cadence') {
        scheduleChangeAt = 'cycle_end';
      } else if (commandType === 'change_branches') {
        scheduleChangeAt = planUnits < Number(current.quantity || 0) ? 'cycle_end' : 'now';
      } else {
        scheduleChangeAt = Number(data.base_amount_cents || 0) <
            Number(data.prior_base_amount_cents || data.base_amount_cents || 0)
          ? 'cycle_end'
          : 'now';
      }
      const updated = await razorpay.updateSubscription(subscriptionId, {
        plan_id: planId,
        quantity: planUnits,
        schedule_change_at: scheduleChangeAt,
        customer_notify: 0,
      });
      const verified = await razorpay.getSubscription(updated.id || subscriptionId);
      providerObjectId = verified.id || subscriptionId;
      /* Only the capacity model waits: a scheduled (not yet applied) change means Razorpay has
         not confirmed the new price, and completing 'completed' here would grant capacity the
         firm has not paid for. Same rule the Stripe pending_update check enforced. */
      providerConfirmationPending = capacityModel && verified.has_scheduled_changes === true;
      if (
        !providerConfirmationPending &&
        !subscriptionMatchesCommandV755(verified, commandType, planId, planUnits)
      ) {
        throw new Error('Razorpay subscription does not match the requested command');
      }
    } else if (!providerResolved && commandType === 'cancel_at_period_end') {
      if (!subscriptionId) throw new Error('Razorpay subscription is not linked');
      providerCallStarted = true;
      const cancelled = await razorpay.cancelSubscription(subscriptionId, 1);
      providerObjectId = cancelled.id || subscriptionId;
    } else if (!providerResolved && commandType === 'resume') {
      if (!subscriptionId) throw new Error('Razorpay subscription is not linked');
      providerCallStarted = true;
      const current = await razorpay.getSubscription(subscriptionId);
      if (String(current.status) === 'paused') {
        const resumed = await razorpay.resumeSubscription(subscriptionId);
        providerObjectId = resumed.id || subscriptionId;
      } else {
        /* A Razorpay cancellation scheduled for cycle end cannot be withdrawn — there is no
           "uncancel" and PATCHing remaining_count does not restore it. Saying so with a named
           code is the only honest outcome; the firm re-subscribes instead. */
        const { data: unsupported, error: unsupportedError } = await admin.rpc(
          'complete_billing_command_v77',
          {
            p_command: commandId,
            p_status: 'failed',
            p_provider_object_id: subscriptionId,
            p_redirect_url: null,
            p_error_code: 'provider_resume_unavailable',
            p_error_message:
              'Razorpay cannot withdraw a scheduled cancellation. Start a new subscription to continue after the current period.',
          },
        );
        if (unsupportedError) {
          throw new Error('billing command completion persistence failed');
        }
        return billingCorsJson(req, 200, {
          command_id: commandId,
          status: unsupported?.status || 'failed',
          error: 'provider_resume_unavailable',
        });
      }
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
            'Razorpay has not applied the scheduled subscription change. Retry this command ID after payment confirmation.',
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
      livemode: livemodeFromKey(requiredEnv('RAZORPAY_KEY_ID')),
    });
  } catch (error) {
    const providerError = error as { code?: string; message?: string };
    const priorExecutionWasUncertain = claimed?.recovery_required === true;
    /* Disposition rules unchanged from V77. 'failed' requires PROOF that nothing happened at the
       provider: either the call never started, or Razorpay rejected it with a 4xx (not a 429).
       A timeout, a 429 or a 5xx is 'uncertain' — retried under the same command id, which
       re-finds the subscription by notes.command_id rather than creating a second one. */
    nonExecutionProvenByProvider = error instanceof RazorpayApiError &&
      error.nonExecutionProven;
    const nonExecutionProven =
      !priorExecutionWasUncertain &&
      (!providerCallStarted || nonExecutionProvenByProvider);
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
        p_redirect_url: disposition === 'uncertain' ? redirectUrl || null : null,
        p_error_code: disposition === 'uncertain'
          ? 'provider_result_uncertain'
          : providerError.code || 'command_failed',
        p_error_message: disposition === 'uncertain'
          ? 'Provider execution may have succeeded; retry this command ID to re-find the same Razorpay subscription by its command note.'
          : providerError.message || 'billing command failed before provider execution',
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
      error: uncertain ? 'billing_command_outcome_uncertain' : 'billing_command_failed',
      recovery: uncertain ? 'retry_same_command_id' : undefined,
    });
  }
});
