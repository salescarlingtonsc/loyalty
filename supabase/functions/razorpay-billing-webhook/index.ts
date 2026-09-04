import {
  billingAdminClient,
  billingJson,
  requiredEnv,
  sha256Hex,
} from '../_shared/billing-service.ts';
import { livemodeFromKey, verifyWebhookSignature } from '../_shared/razorpay-client.ts';

const MAX_WEBHOOK_BYTES = 1024 * 1024;
declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

type RazorpayEventEnvelope = {
  entity?: string;
  account_id?: string;
  event?: string;
  contains?: string[];
  created_at?: number;
  payload?: {
    subscription?: { entity?: { id?: string } };
    payment?: { entity?: { id?: string } };
    refund?: { entity?: { id?: string } };
  };
};

function objectId(event: RazorpayEventEnvelope): string {
  return (
    event.payload?.subscription?.entity?.id ||
    event.payload?.payment?.entity?.id ||
    event.payload?.refund?.entity?.id ||
    ''
  );
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
    /* RAW body. Razorpay signs the exact bytes it sent; parsing and re-serialising would
       reorder keys and fail every genuine event. */
    const rawBody = await req.text();
    if (new TextEncoder().encode(rawBody).length > MAX_WEBHOOK_BYTES) {
      return billingJson(413, { error: 'payload_too_large' });
    }
    const signature = req.headers.get('x-razorpay-signature') || '';
    if (!signature) return billingJson(400, { error: 'invalid_signature' });

    const verified = await verifyWebhookSignature(
      rawBody,
      signature,
      requiredEnv('RAZORPAY_WEBHOOK_SECRET'),
    );
    /* Nothing is written before the signature verifies: an unverified body must never become
       production billing evidence, not even in the durable inbox. */
    if (!verified) return billingJson(400, { error: 'invalid_signature' });

    let event: RazorpayEventEnvelope;
    try {
      event = JSON.parse(rawBody) as RazorpayEventEnvelope;
    } catch {
      return billingJson(400, { error: 'invalid_event_object' });
    }
    const eventType = String(event.event || '');
    if (!eventType) return billingJson(400, { error: 'invalid_event_object' });
    const providerObjectId = objectId(event);
    if (!providerObjectId) return billingJson(400, { error: 'invalid_event_object' });

    const payloadDigest = await sha256Hex(rawBody);
    /* x-razorpay-event-id is Razorpay's own per-event unique id and is the dedupe key. It is
       absent on a few older account configurations; the body digest is a stable fallback that
       still collapses a redelivery of the identical body onto one inbox row. */
    const eventId = (req.headers.get('x-razorpay-event-id') || '').trim() ||
      `sha256_${payloadDigest}`;
    /* Razorpay carries no livemode flag anywhere in the payload, so the mode is derived from the
       API key this deployment is configured with — the same two-secret hazard the Stripe V281
       check existed for (a live webhook secret against a test key sends real customers to a test
       checkout). Unknown prefix disables the check rather than the webhook. */
    const livemode = livemodeFromKey(requiredEnv('RAZORPAY_KEY_ID'));

    const admin = billingAdminClient();
    const eventCreatedAt = new Date(
      (typeof event.created_at === 'number' ? event.created_at : Math.floor(Date.now() / 1000)) *
        1000,
    ).toISOString();
    const { data: inbox, error: inboxError } = await admin.rpc('ingest_billing_event_v755', {
      p_provider: 'razorpay',
      p_event_id: eventId,
      p_event_type: eventType,
      p_object_id: providerObjectId,
      p_event_created_at: eventCreatedAt,
      p_livemode: livemode === null ? false : livemode,
      p_payload: event,
      p_payload_sha256: payloadDigest,
    });
    if (inboxError) {
      return billingJson(400, { error: 'event_envelope_rejected' });
    }

    const { data: applied, error: applyError } = await admin.rpc(
      'apply_razorpay_billing_event_v755',
      { p_event_id: eventId },
    );
    if (applyError || applied?.status === 'failed') {
      return billingJson(500, {
        received: true,
        durable: true,
        event_id: eventId,
        error: 'event_processing_failed',
      });
    }

    /* subscription.charged is the Razorpay event that carries the same meaning Stripe's
       invoice.paid did: money settled for a period. The subscription-document dispatch trigger
       moves with it unchanged. */
    const dispatchSecret = Deno.env.get('SUBSCRIPTION_OPERATIONS_DISPATCH_SECRET') || '';
    if (dispatchSecret && eventType === 'subscription.charged') {
      const dispatch = fetch(
        `${requiredEnv('SUPABASE_URL')}/functions/v1/subscription-document-dispatch`,
        {
          method: 'POST',
          headers: {
            'content-type': 'application/json',
            'x-v156-dispatch-secret': dispatchSecret,
          },
          body: JSON.stringify({ source_event_id: eventId }),
        },
      ).catch(() => undefined);
      /* Razorpay disables an endpoint after 24h of failures and expects 2xx inside 5s, so the
         dispatch is deliberately not awaited on the response path. */
      if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(dispatch);
      else await dispatch;
    }

    return billingJson(200, {
      received: true,
      durable: true,
      duplicate: inbox?.duplicate === true,
      event_id: eventId,
      status: applied?.status || 'processed',
    });
  } catch {
    return billingJson(500, { error: 'webhook_unavailable' });
  }
});
