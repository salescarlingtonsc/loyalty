import Stripe from 'npm:stripe@18.5.0';
import {
  billingAdminClient,
  billingJson,
  requiredEnv,
  sha256Hex,
} from '../_shared/billing-service.ts';

const MAX_WEBHOOK_BYTES = 1024 * 1024;

function capability(account: Stripe.Account): string {
  const value = account.capabilities?.paynow_payments;
  return ['active', 'pending', 'inactive'].includes(String(value))
    ? String(value)
    : account.requirements?.disabled_reason ? 'restricted' : 'unavailable';
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return billingJson(405, { error: 'method_not_allowed' });
  const declaredLength = Number(req.headers.get('content-length') || '0');
  if (declaredLength > MAX_WEBHOOK_BYTES) return billingJson(413, { error: 'payload_too_large' });
  try {
    const rawBody = await req.text();
    if (new TextEncoder().encode(rawBody).length > MAX_WEBHOOK_BYTES) {
      return billingJson(413, { error: 'payload_too_large' });
    }
    const signature = req.headers.get('stripe-signature') || '';
    if (!signature) return billingJson(400, { error: 'invalid_signature' });
    const stripeSecret = requiredEnv('STRIPE_SECRET_KEY');
    const stripe = new Stripe(stripeSecret, {
      httpClient: Stripe.createFetchHttpClient(),
    });
    const event = await stripe.webhooks.constructEventAsync(
      rawBody,
      signature,
      requiredEnv('STRIPE_CONNECT_WEBHOOK_SECRET'),
      undefined,
      Stripe.createSubtleCryptoProvider(),
    );
    const connectedAccount = typeof event.account === 'string' ? event.account : '';
    const object = event.data.object as Stripe.Event.Data.Object & { id?: string };
    if (!connectedAccount.startsWith('acct_') || !object?.id) {
      return billingJson(400, { error: 'invalid_connect_event' });
    }
    const expectedLivemode = !stripeSecret.startsWith('sk_test_');
    if (event.livemode !== expectedLivemode) {
      return billingJson(200, { received: true, ignored: true, reason: 'mode_mismatch' });
    }
    const admin = billingAdminClient();
    const digest = await sha256Hex(rawBody);
    const eventCreatedAt = new Date(event.created * 1000).toISOString();
    const { data: inbox, error: inboxError } = await admin.rpc('ingest_stripe_connect_event_v142', {
      p_event_id: event.id,
      p_connected_account_id: connectedAccount,
      p_event_type: event.type,
      p_object_id: object.id,
      p_livemode: event.livemode,
      p_event_created_at: eventCreatedAt,
      p_payload: event,
      p_payload_sha256: digest,
    });
    if (inboxError) return billingJson(400, { error: 'event_envelope_rejected' });

    if (event.type === 'account.updated') {
      const account = object as Stripe.Account;
      const { error: syncError } = await admin.rpc('sync_merchant_payment_account_v142', {
        p_account_id: account.id,
        p_livemode: event.livemode,
        p_details_submitted: account.details_submitted === true,
        p_charges_enabled: account.charges_enabled === true,
        p_payouts_enabled: account.payouts_enabled === true,
        p_paynow_capability: capability(account),
        p_currently_due: account.requirements?.currently_due || [],
        p_eventually_due: account.requirements?.eventually_due || [],
        p_disabled_reason: account.requirements?.disabled_reason || null,
        p_event_id: event.id,
        p_event_created_at: eventCreatedAt,
      });
      if (syncError) return billingJson(500, { received: true, durable: true, error: 'account_sync_failed' });
    }

    const isRefundEvent = event.type === 'refund.updated' || event.type === 'refund.failed';
    const { data: applied, error: applyError } = await admin.rpc(
      isRefundEvent ? 'apply_stripe_connect_refund_event_v142' : 'apply_stripe_connect_payment_event_v142',
      { p_event_id: event.id },
    );
    if (applyError) return billingJson(500, { received: true, durable: true, error: 'event_processing_failed' });

    if (applied?.status === 'refund_required') {
      try {
        const refund = await stripe.refunds.create({
          payment_intent: String(applied.payment_intent_id),
          reason: 'requested_by_customer',
          metadata: {
            peekaa_pos_attempt_id: String(applied.attempt_id),
            peekaa_reason: 'checkout_not_fulfilled',
          },
        }, {
          stripeAccount: String(applied.provider_account_id),
          idempotencyKey: `peekaa-auto-refund-${String(applied.attempt_id)}`,
        });
        const { error: markError } = await admin.rpc('mark_pos_paynow_refund_state_v142', {
          p_attempt: applied.attempt_id,
          p_event_id: event.id,
          p_refund_id: refund.id,
          p_provider_status: refund.status,
          p_failure_reason: refund.failure_reason || null,
        });
        if (markError) throw new Error('refund projection failed');
      } catch {
        return billingJson(500, {
          received: true,
          durable: true,
          status: 'refund_required',
          error: 'automatic_refund_retry_required',
        });
      }
    }
    return billingJson(200, {
      received: true,
      durable: true,
      duplicate: inbox?.duplicate === true,
      event_id: event.id,
      status: applied?.status || 'processed',
    });
  } catch (error) {
    const invalid = error instanceof Stripe.errors.StripeSignatureVerificationError;
    return billingJson(invalid ? 400 : 500, {
      error: invalid ? 'invalid_signature' : 'webhook_unavailable',
    });
  }
});
