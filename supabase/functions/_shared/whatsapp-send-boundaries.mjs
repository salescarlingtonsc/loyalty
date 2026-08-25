// v517 — every decision the WhatsApp sender makes, with no Deno, no network and
// no Meta app in it.
//
// Plain .mjs for the same reason whatsapp-webhook-boundaries.mjs is: `node --test`
// imports it directly, so the rules below are covered without a Deno runtime or a
// live Meta credential. The dispatcher keeps only plumbing; the single fetch() is
// injected, so everything here is exercised for real in tests.
//
// SCOPE FENCE: the webhook must never import this module. tests/whatsapp/
// v504-webhook.test.mjs re-derives the webhook's import graph and fails if it does.

// ---------------------------------------------------------------------------
// Addressing
// ---------------------------------------------------------------------------

// clients.phone_norm is GENERATED ALWAYS AS (app.norm_phone(phone)) and is a BARE
// 8-digit Singapore local number — app.norm_phone returns NULL for anything it
// cannot fold, including every non-SG number. Meta wants E.164 without the '+'.
//
// This deliberately does NOT re-implement normalisation. app.norm_phone has 20+
// callers and a partial unique index depending on its contract; a second, subtly
// different normaliser is how two systems start disagreeing about who a customer
// is. Anything that arrives here already went through it.
export function toE164(phoneNorm) {
  if (typeof phoneNorm !== 'string') return null;
  if (!/^[3689][0-9]{7}$/.test(phoneNorm)) return null;
  return `65${phoneNorm}`;
}

// Presentational only — never send this to Meta.
export function formatE164(phoneNorm) {
  const e164 = toE164(phoneNorm);
  return e164 ? `+${e164}` : null;
}

// ---------------------------------------------------------------------------
// Template parameter binding
// ---------------------------------------------------------------------------

// A Meta template body is positional: {{1}}, {{2}}, {{3}}. Peekaa stores an
// ORDERED DESCRIPTOR LIST rather than a variable count, because the count alone
// cannot survive a template being re-approved with its variables reordered — and
// because a positional array in a migration is unreadable six months later.
//
// Returns a discriminated result rather than throwing: a missing variable is a
// data problem for one message, not an exception that should abort a batch.
export function bindTemplateParameters(descriptors, values) {
  if (!Array.isArray(descriptors)) return { ok: false, reason: 'descriptors_invalid', missing: [] };
  const missing = [];
  const parameters = [];
  for (const descriptor of descriptors) {
    const key = typeof descriptor === 'string' ? descriptor : descriptor?.key;
    if (typeof key !== 'string' || key.length === 0) {
      return { ok: false, reason: 'descriptors_invalid', missing: [] };
    }
    const value = values?.[key];
    // A blank string is as unsendable as an absent one: Meta rejects empty
    // positional parameters, and "Hi , your appointment" is worse than no message.
    if (value === undefined || value === null || String(value).trim() === '') {
      missing.push(key);
      continue;
    }
    // Meta rejects newlines and tabs inside a body parameter.
    parameters.push({ type: 'text', text: String(value).replace(/\s+/g, ' ').trim() });
  }
  if (missing.length > 0) return { ok: false, reason: 'parameter_missing', missing };
  return { ok: true, parameters };
}

// ---------------------------------------------------------------------------
// Request assembly
// ---------------------------------------------------------------------------

export const GRAPH_VERSION = 'v21.0';

// The path only. The host and the phone-number id are supplied by the caller from
// server-side env, so this module names no credential and no host.
export function sendPath(phoneNumberId) {
  if (typeof phoneNumberId !== 'string' || !/^[0-9]{1,32}$/.test(phoneNumberId)) return null;
  return `/${GRAPH_VERSION}/${phoneNumberId}/messages`;
}

export function buildTemplateSend({ toE164: to, templateName, languageCode, parameters }) {
  if (!/^[1-9][0-9]{7,14}$/.test(String(to || ''))) {
    return { ok: false, reason: 'recipient_invalid' };
  }
  // Meta template names are lowercase alphanumeric + underscore. Rejecting here
  // means a typo in the registry surfaces as a named refusal before we spend a
  // conversation, rather than as a 132001 after we have already been billed.
  if (!/^[a-z0-9_]{1,512}$/.test(String(templateName || ''))) {
    return { ok: false, reason: 'template_name_invalid' };
  }
  if (!/^[a-zA-Z]{2}(_[a-zA-Z]{2,4})?$/.test(String(languageCode || ''))) {
    return { ok: false, reason: 'language_code_invalid' };
  }
  const components = Array.isArray(parameters) && parameters.length > 0
    ? [{ type: 'body', parameters }]
    : [];
  return {
    ok: true,
    body: {
      messaging_product: 'whatsapp',
      recipient_type: 'individual',
      to: String(to),
      type: 'template',
      template: {
        name: templateName,
        language: { code: languageCode },
        ...(components.length > 0 ? { components } : {}),
      },
    },
  };
}

// ---------------------------------------------------------------------------
// Response classification
// ---------------------------------------------------------------------------

// Six dispositions, because "why was this not sent" has six genuinely different
// answers and they route to different people:
//
//   sent          - Meta accepted it; a wamid came back. Charge, await webhook.
//   retry         - transient. Back off and try again. Never charge twice.
//   undeliverable - this recipient will never receive it. Permanent, do NOT retry,
//                   do NOT charge, and tell the MERCHANT (only they can fix a number).
//   template_fault- our template is wrong, missing or unapproved. Permanent for this
//                   template. Tell PEEKAA, not the merchant — they cannot fix it.
//   config_fault  - token, permission or account-level problem. Every message for
//                   every tenant is about to fail. Tell PEEKAA loudly.
//   failed        - unclassified permanent. Keep the raw code so it can be triaged.
//
// A message that fails for a reason the merchant cannot act on must never appear
// in the merchant's failure count — that is how a dashboard trains people to
// ignore it.

const UNDELIVERABLE_CODES = new Set([
  131026, // recipient is not a WhatsApp user / cannot receive
  131052, // media download error on their side — treated as terminal for a template send
  1013,   // user is not valid
]);

const TEMPLATE_FAULT_CODES = new Set([
  132000, // number of parameters does not match
  132001, // template does not exist in this language
  132005, // translated text too long
  132007, // template format character policy violated
  132012, // parameter format mismatch
  132015, // template is paused
  132016, // template is disabled
  133010, // template not approved
]);

const CONFIG_FAULT_CODES = new Set([
  190,   // access token expired / invalid
  200,   // permission denied
  10,    // application does not have permission
  131031, // account has been locked
  131042, // business eligibility / payment problem
  368,   // temporarily blocked for policy violations
]);

const RETRY_CODES = new Set([
  130429, // rate limit hit
  131048, // spam rate limit
  131056, // pair rate limit
  80007,  // rate limit
  131000, // generic something went wrong
  1,      // API unknown
  2,      // API service temporarily unavailable
  4,      // API too many calls
]);

function metaError(body) {
  const error = body && typeof body === 'object' ? body.error : null;
  if (!error || typeof error !== 'object') return { code: null, subcode: null, message: '' };
  return {
    code: Number.isInteger(error.code) ? error.code : null,
    subcode: Number.isInteger(error.error_subcode) ? error.error_subcode : null,
    // Meta echoes the recipient number inside some messages. Never persist or log
    // the raw title/message; keep the machine-readable code and a bounded label.
    message: typeof error.type === 'string' ? error.type.slice(0, 64) : '',
  };
}

export function classifyMetaResponse(status, body, headers) {
  const messages = body && typeof body === 'object' ? body.messages : null;
  if (status >= 200 && status < 300) {
    const wamid = Array.isArray(messages) && typeof messages[0]?.id === 'string' ? messages[0].id : null;
    // A 2xx with no wamid is not a success we can track: the status webhook keys
    // on the wamid, so without one the message becomes unobservable. Treat it as
    // a fault rather than quietly marking it sent.
    return wamid
      ? { disposition: 'sent', wamid, code: null, retryAfterSeconds: null }
      : { disposition: 'failed', wamid: null, code: 'accepted_without_wamid', retryAfterSeconds: null };
  }

  const { code, subcode, message } = metaError(body);
  const label = code === null ? `http_${status}` : String(code);
  const retryAfter = parseRetryAfter(headers);

  if (code !== null) {
    if (CONFIG_FAULT_CODES.has(code)) {
      return { disposition: 'config_fault', wamid: null, code: label, subcode, metaType: message, retryAfterSeconds: null };
    }
    if (TEMPLATE_FAULT_CODES.has(code)) {
      return { disposition: 'template_fault', wamid: null, code: label, subcode, metaType: message, retryAfterSeconds: null };
    }
    if (UNDELIVERABLE_CODES.has(code)) {
      return { disposition: 'undeliverable', wamid: null, code: label, subcode, metaType: message, retryAfterSeconds: null };
    }
    if (RETRY_CODES.has(code)) {
      return { disposition: 'retry', wamid: null, code: label, subcode, metaType: message, retryAfterSeconds: retryAfter };
    }
  }

  // Fall back to the HTTP class. 429 and 5xx are transient by definition; an
  // unrecognised 4xx is permanent, because retrying a request Meta has already
  // rejected on its merits only burns quota.
  if (status === 429 || status >= 500) {
    return { disposition: 'retry', wamid: null, code: label, subcode, metaType: message, retryAfterSeconds: retryAfter };
  }
  return { disposition: 'failed', wamid: null, code: label, subcode, metaType: message, retryAfterSeconds: null };
}

export function parseRetryAfter(headers) {
  const raw = typeof headers?.get === 'function' ? headers.get('retry-after') : headers?.['retry-after'];
  if (raw === null || raw === undefined) return null;
  const seconds = Number(String(raw).trim());
  if (!Number.isFinite(seconds) || seconds < 0) return null;
  return Math.min(Math.trunc(seconds), 3600);
}

// A transport-level throw (DNS, TLS, timeout, aborted socket) is always transient.
// It is deliberately NOT 'failed': the message may in fact have reached Meta, so
// the send row must stay retryable and the idempotency key must stay stable.
export function classifyTransportError() {
  return { disposition: 'retry', wamid: null, code: 'transport_error', retryAfterSeconds: null };
}

export function isTerminal(disposition) {
  return ['sent', 'undeliverable', 'template_fault', 'config_fault', 'failed'].includes(disposition);
}

// Only 'sent' consumes quota or credit. Every other terminal disposition must
// release whatever was reserved — a merchant is never charged for a message
// Meta refused.
export function consumesQuota(disposition) {
  return disposition === 'sent';
}

// ---------------------------------------------------------------------------
// Backoff
// ---------------------------------------------------------------------------

export const MAX_ATTEMPTS = 5;

// Mirrors internal_customer_push_claim_v95: 15s doubling, capped at 300s, with
// Meta's own Retry-After winning when it asks for longer. Jitter is deterministic
// per delivery id, not random — the workflow runtime forbids Math.random, and a
// reproducible schedule is easier to reason about during an incident anyway.
export function nextAttemptDelaySeconds(attempt, retryAfterSeconds, jitterSeed = 0) {
  const base = Math.min(300, 15 * Math.pow(2, Math.max(0, attempt)));
  const floor = Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0
    ? Math.max(base, retryAfterSeconds)
    : base;
  const jitter = Math.abs(Math.trunc(jitterSeed)) % 7;
  return Math.min(3600, Math.trunc(floor) + jitter);
}

export function shouldRetry(disposition, attemptCount) {
  return disposition === 'retry' && attemptCount < MAX_ATTEMPTS;
}

// The final say on what a send row becomes. Kept here, beside the classifier, so
// the state machine is one readable function rather than scattered branches in
// the dispatcher.
export function resolveOutcome(classification, attemptCount) {
  const { disposition } = classification;
  if (disposition === 'sent') {
    return { status: 'sent', consumeQuota: true, retryInSeconds: null, code: null };
  }
  if (shouldRetry(disposition, attemptCount)) {
    return {
      status: 'retry',
      consumeQuota: false,
      retryInSeconds: nextAttemptDelaySeconds(attemptCount, classification.retryAfterSeconds, attemptCount),
      code: classification.code,
    };
  }
  // Retries exhausted collapses to a named permanent state rather than to a bare
  // 'failed', so the difference between "Meta kept refusing" and "we gave up" is
  // still readable a week later.
  const status = disposition === 'retry' ? 'failed_retries_exhausted' : disposition;
  return { status, consumeQuota: false, retryInSeconds: null, code: classification.code };
}
