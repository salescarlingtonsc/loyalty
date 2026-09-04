/* v504 — Meta WhatsApp Cloud API webhook endpoint.
 *
 * SCOPE (owner directive 2026-08-25): receive and record. This function does
 * NOT reply to customers, does NOT resolve a delivery to a Peekaa business, and
 * does NOT trigger any automation. It answers Meta's verification challenge and
 * files signed deliveries in public.whatsapp_webhook_events. Nothing consumes
 * that table yet.
 *
 * Shape follows razorpay-billing-webhook/index.ts: verify the provider signature
 * over the RAW body, hand the envelope to a SECURITY DEFINER ingest RPC, return
 * a small JSON acknowledgement. No CORS — a webhook has no browser origin, and
 * offering one would only widen the surface.
 */
import { createClient } from 'npm:@supabase/supabase-js@2.110.7';
import {
  sha256Hex,
  signatureValid,
  summariseEnvelope,
  verificationOutcome,
  whatsappEnv,
  whatsappJson,
} from '../_shared/whatsapp-webhook.ts';

/* Meta's documented webhook payload ceiling is far below this. The cap exists
   so an unsigned flood cannot make us buffer megabytes before rejecting. */
const MAX_WEBHOOK_BYTES = 256 * 1024;

function serviceKey(): string {
  const current = whatsappEnv('SUPABASE_SECRET_KEYS');
  if (current) {
    const keys = JSON.parse(current);
    if (typeof keys.default === 'string' && keys.default) return keys.default;
  }
  const legacy = whatsappEnv('SUPABASE_SERVICE_ROLE_KEY');
  if (!legacy) throw new Error('whatsapp webhook unavailable');
  return legacy;
}

function adminClient() {
  const url = whatsappEnv('SUPABASE_URL');
  if (!url) throw new Error('whatsapp webhook unavailable');
  return createClient(url, serviceKey(), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/* Structured, non-sensitive. NEVER log the payload, a phone number, message
   text, the verify token, the app secret or any part of a signature — an
   inbound WhatsApp body is customer personal data and edge logs are not the
   place for it. Ids and counts are enough to answer "did it arrive, was it
   signed, was it a retry". */
function log(event: string, detail: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ fn: 'whatsapp-webhook', event, ...detail }));
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  /* ---------------- GET: Meta subscription verification ---------------- */
  if (req.method === 'GET') {
    const outcome = verificationOutcome(
      url.searchParams,
      whatsappEnv('WHATSAPP_WEBHOOK_VERIFY_TOKEN'),
    );
    if (!outcome.ok) {
      log('verification_rejected', { status: outcome.status, reason: outcome.error });
      return whatsappJson(outcome.status, { error: outcome.error });
    }
    log('verification_succeeded');
    /* Plain text, bare challenge, 200. Meta rejects anything else. */
    return new Response(outcome.challenge, {
      status: 200,
      headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' },
    });
  }

  if (req.method !== 'POST') {
    return whatsappJson(405, { error: 'method_not_allowed' });
  }

  /* ---------------- POST: signed delivery ---------------- */

  /* Fail CLOSED when the app secret is absent. 503 rather than 200 so a
     half-configured deployment is loud instead of silently accepting forged
     traffic. GET verification does not need this secret, so Meta's
     "Verify and save" still succeeds while this is outstanding. */
  const appSecret = whatsappEnv('WHATSAPP_APP_SECRET');
  if (!appSecret) {
    log('rejected', { reason: 'app_secret_unconfigured' });
    return whatsappJson(503, { error: 'signature_verification_unconfigured' });
  }

  if (Number(req.headers.get('content-length') || '0') > MAX_WEBHOOK_BYTES) {
    return whatsappJson(413, { error: 'payload_too_large' });
  }

  let rawBody: string;
  try {
    rawBody = await req.text();
  } catch {
    return whatsappJson(400, { error: 'unreadable_body' });
  }
  if (new TextEncoder().encode(rawBody).length > MAX_WEBHOOK_BYTES) {
    return whatsappJson(413, { error: 'payload_too_large' });
  }

  /* The signature is checked over the RAW bytes, before any parsing. An
     unsigned request costs one HMAC and touches no database. */
  if (!await signatureValid(req.headers.get('x-hub-signature-256'), rawBody, appSecret)) {
    log('rejected', { reason: 'invalid_signature' });
    return whatsappJson(401, { error: 'invalid_signature' });
  }

  let payload: unknown;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return whatsappJson(400, { error: 'invalid_json' });
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    return whatsappJson(400, { error: 'invalid_envelope' });
  }

  const summary = summariseEnvelope(payload);
  const digest = await sha256Hex(rawBody);

  let admin;
  try {
    admin = adminClient();
  } catch {
    log('rejected', { reason: 'admin_client_unavailable' });
    return whatsappJson(503, { error: 'whatsapp_webhook_unavailable' });
  }

  const { data, error } = await admin.rpc('ingest_whatsapp_webhook_event_v504', {
    p_payload_sha256: digest,
    p_payload: payload,
    p_signature_verified: true,
    p_waba_id: summary.wabaId,
    p_phone_number_id: summary.phoneNumberId,
    p_entry_kinds: summary.entryKinds,
    p_meta_message_ids: summary.metaMessageIds,
  });

  if (error) {
    /* 500 so Meta retries: the delivery was genuine and we failed to record it.
       The RPC's own message is not echoed to the caller. */
    log('ingest_failed', { code: error.code || null });
    return whatsappJson(500, { error: 'ingest_failed' });
  }

  const result = (data || {}) as { duplicate?: boolean; received_count?: number };
  log('received', {
    duplicate: result.duplicate === true,
    received_count: result.received_count ?? null,
    entry_kinds: summary.entryKinds,
    message_id_count: summary.metaMessageIds.length,
  });

  return whatsappJson(200, {
    received: true,
    duplicate: result.duplicate === true,
  });
});
