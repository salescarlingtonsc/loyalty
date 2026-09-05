import {
  billingAdminClient,
  billingJson,
  requiredEnv,
  sha256Hex,
} from '../_shared/billing-service.ts';
import { verifyWebhookSignature } from '../_shared/razorpay-client.ts';
import { webhookSecretCandidates } from '../_shared/razorpay-mode.ts';

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

/* nestly_v755 incident 2026-09: Razorpay retried subscription.activated/charged/authenticated
   for a REAL payment and every attempt was answered 400, with nothing in the function logs but
   "booted". Four different faults share that one status code, so the logs could not say which —
   and a webhook Razorpay disables after 24h of failures is exactly the place where the first
   rejection has to name itself. Every non-2xx path now emits one structured line.

   These lines are read by whoever is holding the incident, so they carry only what identifies
   the delivery: the event id Razorpay itself sent, the event type, sizes and provider error
   codes. Never the raw body (it is customer billing data), never the signature, never a secret —
   the signature's LENGTH is enough to separate "header absent" from "header truncated" from
   "header present but wrong". */
function rejected(reason: string, detail: Record<string, unknown> = {}): void {
  console.warn(JSON.stringify({ scope: 'razorpay-billing-webhook', reason, ...detail }));
}

function headerEventId(req: Request): string | null {
  return (req.headers.get('x-razorpay-event-id') || '').trim() || null;
}

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
    rejected('method_not_allowed', { event_id: headerEventId(req), method: req.method });
    return billingJson(405, { error: 'method_not_allowed' });
  }

  const declaredLength = Number(req.headers.get('content-length') || '0');
  if (declaredLength > MAX_WEBHOOK_BYTES) {
    rejected('payload_too_large', {
      event_id: headerEventId(req),
      body_bytes: declaredLength,
      limit_bytes: MAX_WEBHOOK_BYTES,
    });
    return billingJson(413, { error: 'payload_too_large' });
  }

  try {
    /* RAW body. Razorpay signs the exact bytes it sent; parsing and re-serialising would
       reorder keys and fail every genuine event. */
    const rawBody = await req.text();
    const bodyBytes = new TextEncoder().encode(rawBody).length;
    if (bodyBytes > MAX_WEBHOOK_BYTES) {
      rejected('payload_too_large', {
        event_id: headerEventId(req),
        body_bytes: bodyBytes,
        limit_bytes: MAX_WEBHOOK_BYTES,
      });
      return billingJson(413, { error: 'payload_too_large' });
    }
    const signature = req.headers.get('x-razorpay-signature') || '';
    if (!signature) {
      rejected('invalid_signature', {
        event_id: headerEventId(req),
        body_bytes: bodyBytes,
        sig_len: 0,
        detail: 'signature_header_absent',
      });
      return billingJson(400, { error: 'invalid_signature', reason: 'signature_header_absent' });
    }

    /* nestly_v759 — the rotation window. RAZORPAY_WEBHOOK_SECRET is the secret the dashboard
       is configured with now; RAZORPAY_WEBHOOK_SECRET_PREVIOUS, when set and non-empty, is the
       one it was configured with before. Razorpay signs a queued retry with the secret that was
       live when the delivery was CREATED, so during a rotation both are genuine. Unset (the
       steady state) accepts only the current secret. */
    /* nestly_v790: three secrets can sign a genuine delivery — the platform's current one, its
       previous one during a rotation (v759), and the SANDBOX's, which is where demo firms' events
       come from once the platform keys are live. Which one matched decides the livemode the event
       is recorded under: the sandbox is never live. */
    const candidates = webhookSecretCandidates();
    if (!candidates.length) requiredEnv('RAZORPAY_WEBHOOK_SECRET');
    let matched: 'current' | 'previous' | 'test' | null = null;
    let matchedLivemode = false;
    for (const candidate of candidates) {
      if (await verifyWebhookSignature(rawBody, signature, candidate.secret)) {
        matched = candidate.label;
        matchedLivemode = candidate.livemode;
        break;
      }
    }
    /* Nothing is written before the signature verifies: an unverified body must never become
       production billing evidence, not even in the durable inbox. */
    if (!matched) {
      /* sig_len separates the three real causes: a truncated header, a hex digest of the right
         length signed with the WRONG secret (64), and a proxy that rewrote the body. */
      rejected('invalid_signature', {
        event_id: headerEventId(req),
        body_bytes: bodyBytes,
        sig_len: signature.length,
        detail: 'signature_mismatch',
      });
      return billingJson(400, { error: 'invalid_signature', reason: 'signature_mismatch' });
    }

    let event: RazorpayEventEnvelope;
    try {
      event = JSON.parse(rawBody) as RazorpayEventEnvelope;
    } catch {
      rejected('invalid_event_object', {
        event_id: headerEventId(req),
        event_type: null,
        detail: 'body_is_not_json',
      });
      return billingJson(400, { error: 'invalid_event_object', reason: 'body_is_not_json' });
    }
    const eventType = String(event.event || '');
    if (!eventType) {
      rejected('invalid_event_object', {
        event_id: headerEventId(req),
        event_type: null,
        detail: 'event_type_absent',
      });
      return billingJson(400, { error: 'invalid_event_object', reason: 'event_type_absent' });
    }
    const providerObjectId = objectId(event);
    if (!providerObjectId) {
      /* The envelope named an event we cannot attach to any object — a `contains` shape this
         function does not read yet. The TYPE is the whole diagnosis, so it is logged. */
      rejected('invalid_event_object', {
        event_id: headerEventId(req),
        event_type: eventType,
        detail: 'no_subscription_payment_or_refund_id',
      });
      return billingJson(400, {
        error: 'invalid_event_object',
        reason: 'no_subscription_payment_or_refund_id',
      });
    }

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
    const livemode: boolean | null = matchedLivemode;

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
      /* The provider's own error text, not ours: an event id that fails the v755 pattern, a
         livemode check, a missing grant and a schema drift all land here and look identical
         from the outside. */
      rejected('event_envelope_rejected', {
        event_id: eventId,
        event_type: eventType,
        code: inboxError.code,
        message: inboxError.message,
      });
      return billingJson(400, { error: 'event_envelope_rejected', reason: inboxError.code });
    }

    const { data: applied, error: applyError } = await admin.rpc(
      'apply_razorpay_billing_event_v755',
      { p_event_id: eventId },
    );
    if (applyError || applied?.status === 'failed') {
      /* The event IS durable at this point — this 500 asks Razorpay to retry the apply, and the
         retry is only worth anything if the reason it failed is on the record. */
      rejected('event_processing_failed', {
        event_id: eventId,
        event_type: eventType,
        status: applied?.status,
        error: applied?.error,
        code: applyError?.code,
        message: applyError?.message,
      });
      return billingJson(500, {
        received: true,
        durable: true,
        event_id: eventId,
        error: 'event_processing_failed',
        reason: applyError?.code || applied?.error || 'apply_failed',
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

    /* `matched` is which of the two rotation secrets verified this delivery — the LABEL, never
       the value. It is what tells the operator whether the previous secret is still carrying
       traffic, i.e. whether the rotation window can yet be closed. */
    console.info(JSON.stringify({
      scope: 'razorpay-billing-webhook',
      reason: 'accepted',
      event_id: eventId,
      event_type: eventType,
      duplicate: inbox?.duplicate === true,
      status: applied?.status || 'processed',
      secret: matched,
    }));
    return billingJson(200, {
      received: true,
      durable: true,
      duplicate: inbox?.duplicate === true,
      event_id: eventId,
      status: applied?.status || 'processed',
    });
  } catch (error) {
    /* A missing secret throws out of requiredEnv and used to produce a bare 500 with an empty
       log — indistinguishable from a Supabase outage. The message names the FAULT, never a
       value. */
    rejected('webhook_unavailable', {
      event_id: headerEventId(req),
      message: String((error as Error)?.message || 'unknown'),
    });
    return billingJson(500, { error: 'webhook_unavailable' });
  }
});
