/* v536 — the ONLY thing in Peekaa that talks to Meta's send API.
 *
 * Cron pokes app.v536_run_support_dispatch(), which pg_net POSTs here with a
 * shared secret. This function claims leased outbound rows, sends each one, and
 * reports the outcome back through a SECURITY DEFINER RPC. The browser cannot
 * reach graph.facebook.com — it can only enqueue, through one chokepoint.
 *
 * Every decision worth testing lives in _shared/whatsapp-send-boundaries.mjs
 * (v517, already written and covered by 27 tests). This file is plumbing.
 *
 * NEVER LOGGED: the access token, the phone number id, the rendered body, the
 * recipient number, and the wamid — which base64-decodes to the customer's
 * phone number and is therefore PII, not an opaque key. Log lines carry message
 * uuids and dispositions only.
 */
import { createClient } from 'npm:@supabase/supabase-js@2.110.7';
import {
  buildTemplateSend,
  classifyMetaResponse,
  classifyTransportError,
  reportFailureCode,
  reportSendOutcome,
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
  console.log(JSON.stringify({ fn: 'whatsapp-send-dispatch', event, ...detail }));
}

/* Constant-time compare, same shape as pushDispatchAuthorized. */
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

/* The single fetch, injected so tests can point it at a local server. */
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
    /* Fail CLOSED and loudly, exactly like the webhook does for a missing app
       secret. A half-configured dispatcher must not look like an idle one. */
    log('rejected', { reason: 'send_credentials_unconfigured' });
    return json(503, { error: 'send_credentials_unconfigured' });
  }

  const admin = adminClient();
  const workerId = crypto.randomUUID();
  const { data, error } = await admin.rpc('internal_support_claim_outbound_v535', {
    p_worker_id: workerId, p_limit: MAX_CLAIM, p_lease_seconds: LEASE_SECONDS,
  });
  if (error || !Array.isArray(data)) {
    log('claim_failed', { code: error?.code || null });
    return json(503, { error: 'claim_failed' });
  }
  /* No early return on an empty support queue: since v557 this worker ALSO
     drains the template queue below, and the empty-support case is the NORMAL
     state when a reminder is due. Returning here would strand every template
     send at 'queued' forever. */
  let sent = 0, retried = 0, failed = 0;
  /* v687 (audit F126): outcomes Meta gave us that we could NOT write down. Counted and returned
     so a dispatcher that is delivering messages it cannot record is visible in the cron response,
     not only in a customer's duplicate WhatsApp thread. */
  let unreported = 0;

  /* One place where "the outcome is now durable" is decided, so the support loop and the
     template loop cannot drift apart on it. Bounded retries with backoff (the whole budget is
     ~4.25s, far inside the 120s lease this worker still holds for the row), a named non-retryable
     case for a stale lease or a vanished row, and a counted, logged failure when it still will
     not write — never the old `await admin.rpc(...)` with the error dropped on the floor. */
  const report = async (fn: string, args: Record<string, unknown>, event: string, messageId: string,
                        disposition: string) => {
    const result = await reportSendOutcome(
      (name: string, params: Record<string, unknown>) => admin.rpc(name, params), fn, args);
    if (result.ok) return true;
    unreported += 1;
    /* A uuid, a word and an error code. Never the wamid: it base64-decodes to the customer's
       phone number, so it is PII and this file says so at the top. */
    log(event, {
      message_id: messageId,
      disposition,
      attempts: result.attempts,
      code: reportFailureCode(result.error),
      /* The tell for the exact failure mode F126 describes: Meta accepted the message and the
         database never learned it, so the row is still re-claimable. */
      delivered_but_unrecorded: disposition === 'sent',
    });
    return false;
  };

  for (const lease of data as Array<Record<string, string | number>>) {
    const messageId = String(lease.message_id);
    const leaseToken = String(lease.lease_token);
    const attempt = Number(lease.attempt_count || 0);

    /* Pre-flight refusals are recorded as PERMANENT before the try-block, with a
       named code. The push dispatcher learned this the hard way: an unrenderable
       lease that fell into a catch masqueraded as a transport error and retried
       forever, invisibly. */
    const e164 = toE164(String(lease.recipient_phone_norm || ''));
    const rendered = String(lease.rendered_body || '');
    if (!e164 || !rendered) {
      await report('internal_support_report_outbound_v535', {
        p_message: messageId, p_lease_token: leaseToken, p_disposition: 'failed',
        p_error_code: !e164 ? 'recipient_not_normalisable' : 'rendered_body_missing',
      }, 'report_failed', messageId, 'failed');
      failed += 1;
      log('preflight_failed', { message_id: messageId });
      continue;
    }

    /* C6 sends free-form text inside the 24h service window. Templates are out of
       scope by owner ruling, so this is a `text` message, not a template. */
    const payload = {
      messaging_product: 'whatsapp',
      recipient_type: 'individual',
      to: e164,
      type: 'text',
      text: { preview_url: false, body: rendered },
    };

    let classification;
    try {
      const response = await metaSend(phoneNumberId, token, payload);
      let parsed: unknown = null;
      try { parsed = await response.json(); } catch { parsed = null; }
      classification = classifyMetaResponse(response.status, parsed, response.headers);
    } catch {
      classification = classifyTransportError();
    }

    const outcome = resolveOutcome(classification, attempt);
    const disposition = outcome.status === 'sent' ? 'sent'
      : outcome.status === 'retry' ? 'retry' : 'failed';

    await report('internal_support_report_outbound_v535', {
      p_message: messageId,
      p_lease_token: leaseToken,
      p_disposition: disposition,
      p_provider_message_id: disposition === 'sent' ? classification.wamid : null,
      p_error_code: disposition === 'sent' ? null : String(outcome.code || outcome.status),
      p_http_status: null,
      p_retry_in_seconds: outcome.retryInSeconds,
    }, 'report_failed', messageId, disposition);

    if (disposition === 'sent') sent += 1;
    else if (disposition === 'retry') retried += 1;
    else failed += 1;

    /* No wamid, no body, no number — a uuid and a word. */
    log('dispatched', { message_id: messageId, disposition });
  }

  /* Template queue: same worker, same lease semantics, a second RPC pair.
     Kept as a separate claim rather than merged with the support queue because
     the two lease shapes and report RPCs differ (template_name/language_code/
     parameters vs rendered_body) — merging them would mean branching on shape
     inside one loop instead of two readable ones. */
  let templateClaimed = 0, templateSent = 0, templateRetried = 0, templateFailed = 0;

  const { data: templateData, error: templateError } = await admin.rpc(
    'internal_whatsapp_claim_template_sends_v557',
    { p_worker_id: workerId, p_limit: MAX_CLAIM, p_lease_seconds: LEASE_SECONDS },
  );
  if (templateError || !Array.isArray(templateData)) {
    log('template_claim_failed', { code: templateError?.code || null });
  } else {
    templateClaimed = templateData.length;

    for (const lease of templateData as Array<Record<string, unknown>>) {
      const messageId = String(lease.message_id);
      const leaseToken = String(lease.lease_token);
      const attempt = Number(lease.attempt_count || 0);

      /* Same preflight discipline as the support queue: a permanent refusal
         found before any network call is reported as 'failed' with a named
         code, never allowed to fall into the catch block and masquerade as
         transient. */
      const e164 = toE164(String(lease.recipient_phone_norm || ''));
      if (!e164) {
        await report('internal_whatsapp_report_template_send_v557', {
          p_message: messageId, p_lease_token: leaseToken, p_disposition: 'failed',
          p_error_code: 'recipient_not_normalisable', p_http_status: null, p_retry_in_seconds: null,
        }, 'template_report_failed', messageId, 'failed');
        templateFailed += 1;
        log('template_preflight_failed', { message_id: messageId });
        continue;
      }

      const built = buildTemplateSend({
        toE164: e164,
        templateName: String(lease.template_name || ''),
        languageCode: String(lease.language_code || ''),
        parameters: Array.isArray(lease.parameters) ? lease.parameters : [],
      });
      if (!built.ok) {
        await report('internal_whatsapp_report_template_send_v557', {
          p_message: messageId, p_lease_token: leaseToken, p_disposition: 'failed',
          p_error_code: built.reason, p_http_status: null, p_retry_in_seconds: null,
        }, 'template_report_failed', messageId, 'failed');
        templateFailed += 1;
        log('template_preflight_failed', { message_id: messageId });
        continue;
      }

      let classification;
      try {
        const response = await metaSend(phoneNumberId, token, built.body);
        let parsed: unknown = null;
        try { parsed = await response.json(); } catch { parsed = null; }
        classification = classifyMetaResponse(response.status, parsed, response.headers);
      } catch {
        classification = classifyTransportError();
      }

      const outcome = resolveOutcome(classification, attempt);
      const disposition = outcome.status === 'sent' ? 'sent'
        : outcome.status === 'retry' ? 'retry' : 'failed';

      await report('internal_whatsapp_report_template_send_v557', {
        p_message: messageId,
        p_lease_token: leaseToken,
        p_disposition: disposition,
        p_provider_message_id: disposition === 'sent' ? classification.wamid : null,
        p_error_code: disposition === 'sent' ? null : String(outcome.code || outcome.status),
        p_http_status: null,
        p_retry_in_seconds: outcome.retryInSeconds,
      }, 'template_report_failed', messageId, disposition);

      if (disposition === 'sent') templateSent += 1;
      else if (disposition === 'retry') templateRetried += 1;
      else templateFailed += 1;

      log('template_dispatched', { message_id: messageId, disposition });
    }
  }

  return json(200, {
    claimed: data.length, sent, retried, failed,
    template_claimed: templateClaimed, template_sent: templateSent,
    template_retried: templateRetried, template_failed: templateFailed,
    /* v687 (audit F126). Non-zero means at least one outcome Meta gave us was never written
       down, so at least one row is still 'processing' with a lease that will expire and be
       re-claimed — i.e. a duplicate is coming. Closing that residual for good needs a queue that
       can record "sent, unconfirmed" (a terminal state the claim RPCs will not re-claim), which
       is a schema decision for the owner; until then this counter is the alarm. */
    unreported,
  });
});
