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

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

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

function subscriptionMatchesRecovery(
  subscription: Stripe.Subscription,
  commandType: string,
  data: Record<string, unknown>,
): boolean {
  if (commandType === 'cancel_at_period_end') {
    return subscription.cancel_at_period_end === true;
  }
  if (commandType === 'resume') {
    return subscription.cancel_at_period_end === false;
  }
  if (commandType !== 'change_cadence') return false;
  const baseItem = subscription.items.data.find(
    (item) => item.id === String(data.provider_base_item_id || ''),
  );
  if (
    !baseItem ||
    baseItem.price.id !== String(data.provider_base_price_id || '') ||
    baseItem.quantity !== 1
  ) {
    return false;
  }
  const extraSeats = Number(data.extra_seats || 0);
  const seatItemId = data.provider_seat_item_id
    ? String(data.provider_seat_item_id)
    : '';
  const seatItem = seatItemId
    ? subscription.items.data.find((item) => item.id === seatItemId)
    : undefined;
  return extraSeats > 0
    ? Boolean(
        seatItem &&
          seatItem.price.id === String(data.provider_seat_price_id || '') &&
          seatItem.quantity === extraSeats,
      )
    : !seatItem;
}

async function retrieveRecoveredProviderResult(
  stripe: Stripe,
  commandType: string,
  providerObjectId: string,
  data: Record<string, unknown>,
): Promise<{ providerObjectId: string; redirectUrl?: string } | null> {
  if (commandType === 'create_checkout') {
    const session = await stripe.checkout.sessions.retrieve(providerObjectId);
    return session.url
      ? { providerObjectId: session.id, redirectUrl: session.url }
      : null;
  }
  if (
    ['change_cadence', 'cancel_at_period_end', 'resume'].includes(commandType)
  ) {
    const subscription = await stripe.subscriptions.retrieve(providerObjectId);
    return subscriptionMatchesRecovery(subscription, commandType, data)
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
  } catch {
    return billingCorsJson(req, 401, { error: 'authentication_required' });
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
    const { data, error } = await admin.rpc('claim_billing_command_v77', {
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

    const stripe = new Stripe(requiredEnv('STRIPE_SECRET_KEY'), {
      httpClient: Stripe.createFetchHttpClient(),
    });
    const origin = returnOrigin();
    const idempotencyKey = String(data.provider_idempotency_key);
    const commandType = String(data.command_type);
    const businessId = String(data.business_id);
    const cadence = data.requested_cadence ? String(data.requested_cadence) : '';
    const customerId = data.provider_customer_id
      ? String(data.provider_customer_id)
      : undefined;
    const subscriptionId = data.provider_subscription_id
      ? String(data.provider_subscription_id)
      : undefined;
    redirectUrl = `${origin}/#/settings`;
    let providerResolved = false;

    const portalRecoveryReplay =
      data.recovery_required && commandType === 'create_portal';
    if (
      data.recovery_required &&
      data.prior_provider_object_id &&
      !portalRecoveryReplay
    ) {
      providerCallStarted = true;
      try {
        const recovered = await retrieveRecoveredProviderResult(
          stripe,
          commandType,
          String(data.prior_provider_object_id),
          data,
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
        { price: String(data.provider_base_price_id), quantity: 1 },
      ];
      const extraSeats = Number(data.extra_seats || 0);
      if (extraSeats > 0) {
        lineItems.push({
          price: String(data.provider_seat_price_id),
          quantity: extraSeats,
        });
      }
      providerCallStarted = true;
      const session = await stripe.checkout.sessions.create(
        {
          mode: 'subscription',
          customer: customerId,
          client_reference_id: businessId,
          line_items: lineItems,
          success_url: `${origin}/#/settings?billing=processing`,
          cancel_url: `${origin}/#/settings?billing=canceled`,
          metadata: { business_id: businessId, cadence },
          subscription_data: { metadata: { business_id: businessId, cadence } },
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
    } else if (!providerResolved && commandType === 'change_cadence') {
      if (!subscriptionId || !data.provider_base_item_id) {
        throw new Error('Stripe subscription items are not linked');
      }
      const extraSeats = Number(data.extra_seats || 0);
      const items: Stripe.SubscriptionUpdateParams.Item[] = [
        {
          id: String(data.provider_base_item_id),
          price: String(data.provider_base_price_id),
          quantity: 1,
        },
      ];
      if (data.provider_seat_item_id) {
        items.push(
          extraSeats > 0
            ? {
                id: String(data.provider_seat_item_id),
                price: String(data.provider_seat_price_id),
                quantity: extraSeats,
              }
            : { id: String(data.provider_seat_item_id), deleted: true },
        );
      } else if (extraSeats > 0) {
        items.push({
          price: String(data.provider_seat_price_id),
          quantity: extraSeats,
        });
      }
      providerCallStarted = true;
      const subscription = await stripe.subscriptions.update(
        subscriptionId,
        {
          items,
          proration_behavior: 'none',
          metadata: { business_id: businessId, cadence },
        },
        { idempotencyKey },
      );
      providerObjectId = subscription.id;
    } else if (
      !providerResolved &&
      (commandType === 'cancel_at_period_end' || commandType === 'resume')
    ) {
      if (!subscriptionId) throw new Error('Stripe subscription is not linked');
      providerCallStarted = true;
      const subscription = await stripe.subscriptions.update(
        subscriptionId,
        { cancel_at_period_end: commandType === 'cancel_at_period_end' },
        { idempotencyKey },
      );
      providerObjectId = subscription.id;
    } else if (!providerResolved) {
      throw new Error('billing command is not executable');
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
