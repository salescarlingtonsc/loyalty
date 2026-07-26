import Stripe from 'npm:stripe@18.5.0';
import {
  billingAdminClient,
  billingJson,
  requiredEnv,
  sha256Hex,
} from '../_shared/billing-service.ts';

const MAX_WEBHOOK_BYTES = 1024 * 1024;

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

    const stripe = new Stripe(requiredEnv('STRIPE_SECRET_KEY'), {
      httpClient: Stripe.createFetchHttpClient(),
    });
    const event = await stripe.webhooks.constructEventAsync(
      rawBody,
      signature,
      requiredEnv('STRIPE_WEBHOOK_SECRET'),
      undefined,
      Stripe.createSubtleCryptoProvider(),
    );
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
