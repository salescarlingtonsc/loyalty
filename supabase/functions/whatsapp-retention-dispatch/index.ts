/* v551 — the retention lane's Meta sender: bring-back voucher TEMPLATE sends.
 *
 * The v536 support dispatcher's sibling, not its replacement: same shared
 * secret, same lease/report protocol, same classification boundaries — but a
 * different queue (retention_sends_v551, never support_messages_v530) and the
 * template path the support lane deliberately left unused (business-initiated
 * marketing requires an approved Meta template; free-form text is only lawful
 * inside the 24h service window the support lane lives in).
 *
 * Every decision worth testing lives in _shared/whatsapp-send-boundaries.mjs
 * (v517, 27 tests). This file is plumbing.
 *
 * NEVER LOGGED: the access token, the phone number id, the rendered variables,
 * the recipient number, and the wamid. Log lines carry message uuids and
 * dispositions only.
 */
import { createClient } from 'npm:@supabase/supabase-js@2.110.7';
import {
  bindTemplateParameters,
  buildTemplateSend,
  classifyMetaResponse,
  classifyTransportError,
  resolveOutcome,
  sendPath,
  toE164,
} from '../_shared/whatsapp-send-boundaries.mjs';

const MAX_CLAIM = 20;
const LEASE_SECONDS = 120;
const GRAPH_HOST = 'https://graph.facebook.com';

function env(name: string): string {
  return Deno.env.get(name) || '';
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  });
}

function log(event: string, detail: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ fn: 'whatsapp-retention-dispatch', event, ...detail }));
}

/* Constant-time compare; the SAME header + env the support dispatcher uses, so
   one vault secret drives both lanes and rotating it cannot strand either. */
function authorized(req: Request): boolean {
  const expected = env('WHATSAPP_DISPATCH_SECRET');
  const supplied = req.headers.get('x-peekaa-whatsapp-dispatch-secret') || '';
  if (expected.length < 32 || supplied.length !== expected.length) return false;
  let mismatch = 0;
  for (let i = 0; i < expected.length; i += 1) mismatch |= expected.charCodeAt(i) ^ supplied.charCodeAt(i);
  return mismatch === 0;
}

function adminClient() {
  const url = env('SUPABASE_URL');
  const keys = env('SUPABASE_SECRET_KEYS');
  const key = keys ? (JSON.parse(keys).default || '') : env('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) throw new Error('dispatcher unavailable');
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

async function metaSend(phoneNumberId: string, token: string, body: unknown) {
  const path = sendPath(phoneNumberId);
  if (!path) throw new Error('phone_number_id_invalid');
  return await fetch(`${GRAPH_HOST}${path}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(20000),
  });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' });
  try {
    if (!authorized(req)) return json(401, { error: 'dispatcher_authentication_required' });
  } catch {
    return json(503, { error: 'dispatcher_unavailable' });
  }

  const token = env('WHATSAPP_ACCESS_TOKEN');
  const phoneNumberId = env('WHATSAPP_PHONE_NUMBER_ID');
  if (!token || !phoneNumberId) {
    log('rejected', { reason: 'send_credentials_unconfigured' });
    return json(503, { error: 'send_credentials_unconfigured' });
  }

  const admin = adminClient();
  const workerId = crypto.randomUUID();
  const { data, error } = await admin.rpc('internal_retention_claim_v551', {
    p_worker_id: workerId, p_limit: MAX_CLAIM, p_lease_seconds: LEASE_SECONDS,
  });
  if (error || !Array.isArray(data)) {
    log('claim_failed', { code: error?.code || null });
    return json(503, { error: 'claim_failed' });
  }
  if (data.length === 0) return json(200, { claimed: 0, sent: 0 });

  let sent = 0, retried = 0, failed = 0;

  for (const lease of data as Array<Record<string, unknown>>) {
    const messageId = String(lease.message_id);
    const leaseToken = String(lease.lease_token);
    const attempt = Number(lease.attempt_count || 0);

    const report = async (
      disposition: string,
      wamid: string | null,
      code: string | null,
      retryInSeconds: number | null,
    ) => {
      await admin.rpc('internal_retention_report_v551', {
        p_message: messageId,
        p_lease_token: leaseToken,
        p_disposition: disposition,
        p_provider_message_id: wamid,
        p_error_code: code,
        p_retry_in_seconds: retryInSeconds,
      });
    };

    /* Pre-flight refusals are PERMANENT and named, before the try-block — the
       lesson the push dispatcher learned about unrenderable leases. */
    const e164 = toE164(String(lease.recipient_phone_norm || ''));
    if (!e164) {
      await report('failed', null, 'recipient_not_normalisable', null);
      failed += 1;
      log('preflight_failed', { message_id: messageId });
      continue;
    }
    const bound = bindTemplateParameters(
      lease.parameter_descriptors as unknown[],
      lease.variables as Record<string, unknown>,
    );
    if (!bound.ok) {
      await report('template_fault', null, String(bound.reason || 'parameter_missing'), null);
      failed += 1;
      log('preflight_failed', { message_id: messageId });
      continue;
    }
    const send = buildTemplateSend({
      toE164: e164,
      templateName: String(lease.template_name || ''),
      languageCode: String(lease.language_code || ''),
      parameters: bound.parameters,
    });
    if (!send.ok) {
      await report('template_fault', null, String(send.reason || 'template_invalid'), null);
      failed += 1;
      log('preflight_failed', { message_id: messageId });
      continue;
    }

    let classification;
    try {
      const response = await metaSend(phoneNumberId, token, send.body);
      let parsed: unknown = null;
      try { parsed = await response.json(); } catch { parsed = null; }
      classification = classifyMetaResponse(response.status, parsed, response.headers);
    } catch {
      classification = classifyTransportError();
    }

    const outcome = resolveOutcome(classification, attempt);
    const disposition = outcome.status === 'sent' ? 'sent'
      : outcome.status === 'retry' ? 'retry' : outcome.status;

    await report(
      disposition,
      disposition === 'sent' ? classification.wamid : null,
      disposition === 'sent' ? null : String(outcome.code || outcome.status),
      outcome.retryInSeconds,
    );

    if (disposition === 'sent') sent += 1;
    else if (disposition === 'retry') retried += 1;
    else failed += 1;

    log('dispatched', { message_id: messageId, disposition });
  }

  return json(200, { claimed: data.length, sent, retried, failed });
});
