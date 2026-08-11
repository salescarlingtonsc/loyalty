import Stripe from 'npm:stripe@18.5.0';
import {
  billingAdminClient,
  billingJson,
  requiredEnv,
  sha256Hex,
} from '../_shared/billing-service.ts';

const MAX_WEBHOOK_BYTES = 1024 * 1024;
declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

/* V281 — the durable inbox stores event.livemode but nothing ever compared it to the mode this
   deployment is actually operating in, and the two are configured by SEPARATE secrets:
   STRIPE_WEBHOOK_SECRET decides which events verify, STRIPE_SECRET_KEY decides which mode
   stripe-billing-command creates Checkout sessions in. Switching to live is therefore a
   two-value change, and getting it half done is silent: with a live endpoint secret and a test
   API key, real customers are sent to a TEST Checkout, pay nothing, and no live invoice ever
   arrives to activate them; with the pair the other way round, test-mode traffic is applied to
   production billing tables and can drive a real activation. Deriving the expected mode from the
   API key needs no new configuration and fails the FIRST mismatched event with a named error,
   which is the moment it is cheapest to notice. An unrecognised key prefix (a restricted key,
   for example) is not treated as a mismatch — it disables the check rather than the webhook. */
function expectedLivemode(secretKey: string): boolean | null {
  if (secretKey.startsWith('sk_live_') || secretKey.startsWith('rk_live_')) return true;
  if (secretKey.startsWith('sk_test_') || secretKey.startsWith('rk_test_')) return false;
  return null;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return billingJson(405, { error: 'method_not_allowed' });
  }

  const declaredLength = Number(req.headers.get('content-length') || '0');
  if (declaredLength > MAX_WEBHOOK_BYTES) {
    return billingJson(413, { error: 'payload_too_large' });
  }

  try {
    const rawBody = await req.text();
    if (new TextEncoder().encode(rawBody).length > MAX_WEBHOOK_BYTES) {
      return billingJson(413, { error: 'payload_too_large' });
    }
    const signature = req.headers.get('stripe-signature') || '';
    if (!signature) return billingJson(400, { error: 'invalid_signature' });

    const secretKey = requiredEnv('STRIPE_SECRET_KEY');
    const stripe = new Stripe(secretKey, {
      httpClient: Stripe.createFetchHttpClient(),
    });
    const event = await stripe.webhooks.constructEventAsync(
      rawBody,
      signature,
      requiredEnv('STRIPE_WEBHOOK_SECRET'),
      undefined,
      Stripe.createSubtleCryptoProvider(),
    );
    const wantLivemode = expectedLivemode(secretKey);
    if (wantLivemode !== null && event.livemode !== wantLivemode) {
      /* 400, not 500: this event is not retryable into correctness, and Stripe should stop
         resending it. Nothing is written to the durable inbox — a mode-mismatched event must
         not become production billing evidence. */
      return billingJson(400, {
        error: 'livemode_mismatch',
        expected_livemode: wantLivemode,
        event_livemode: event.livemode,
      });
    }
    const object = event.data.object as Stripe.Event.Data.Object & { id?: string };
    if (!object?.id) return billingJson(400, { error: 'invalid_event_object' });

    const admin = billingAdminClient();
    const payloadDigest = await sha256Hex(rawBody);
    const eventCreatedAt = new Date(event.created * 1000).toISOString();
    const { data: inbox, error: inboxError } = await admin.rpc(
      'ingest_stripe_billing_event_v77',
      {
        p_event_id: event.id,
        p_event_type: event.type,
        p_object_id: object.id,
        p_event_created_at: eventCreatedAt,
        p_livemode: event.livemode,
        p_payload: event,
        p_payload_sha256: payloadDigest,
      },
    );
    if (inboxError) {
      return billingJson(400, { error: 'event_envelope_rejected' });
    }

    const { data: applied, error: applyError } = await admin.rpc(
      'apply_stripe_billing_event_v77',
      { p_event_id: event.id },
    );
    if (applyError || applied?.status === 'failed') {
      return billingJson(500, {
        received: true,
        durable: true,
        event_id: event.id,
        error: 'event_processing_failed',
      });
    }
    const dispatchSecret = Deno.env.get('SUBSCRIPTION_OPERATIONS_DISPATCH_SECRET') || '';
    if (dispatchSecret) {
      const dispatch = fetch(`${requiredEnv('SUPABASE_URL')}/functions/v1/subscription-document-dispatch`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-v156-dispatch-secret': dispatchSecret },
        body: JSON.stringify({ source_event_id: event.id }),
      }).catch(() => undefined);
      if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(dispatch);
      else await dispatch;
    }
    return billingJson(200, {
      received: true,
      durable: true,
      duplicate: inbox?.duplicate === true,
      event_id: event.id,
      status: applied?.status || 'processed',
    });
  } catch (error) {
    const invalidSignature = error instanceof Stripe.errors.StripeSignatureVerificationError;
    return billingJson(invalidSignature ? 400 : 500, {
      error: invalidSignature ? 'invalid_signature' : 'webhook_unavailable',
    });
  }
});
