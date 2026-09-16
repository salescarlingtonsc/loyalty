/* nestly_v995 — which wire a WhatsApp message goes out on, decided from config, never from code.
 *
 * OWNER, 2026-09-16: "go for the best method to help me scale with ease, and not costly."
 *
 * WHY THIS EXISTS. On 2026-09-14 Meta permanently disabled Peekaa's business portfolio and both
 * its WhatsApp Business Accounts, and upheld it on review, without ever naming the activity. The
 * working theory (PK-RUL-060) is structural: a platform sending on behalf of client businesses
 * from one WABA it owns needs Tech Provider or BSP status. The way out is a Business Solution
 * Provider — and the OTP lane needs only ONE Peekaa-owned WABA under that provider, because a
 * sign-up code is Peekaa speaking to its own user ("{{1}} is your verification code", no business
 * name anywhere in it). So the day a BSP says yes, the OTP send must be a config change, not a
 * deployment. This module is that config change.
 *
 * Every transport yields the SAME message body. buildOtpTemplateSend (v894) produces Meta's
 * Cloud API JSON, and 360dialog's /messages endpoint and Gupshup's Partner v3 endpoint accept it verbatim — that is the whole
 * reason it is first. What differs is only the URL and the auth header, so that is all this
 * module decides.
 *
 * NOTHING HERE LOGS, and describeTransport is the only thing a caller may log: the transport
 * name and host, never the headers, which carry the credential.
 */
import { classifyMetaResponse, sendPath } from './whatsapp-send-boundaries.mjs';

export const WHATSAPP_TRANSPORTS = Object.freeze(['meta_cloud', '360dialog', 'gupshup', 'gupshup_selfserve']);

/* nestly_v997 — a transport is the wire AND the two translations at its ends.
 *
 * Until v997 every wire took Meta's JSON and answered Meta's shape, so the sender could
 * JSON.stringify and hand the reply to classifyMetaResponse itself. Gupshup's SELF-SERVE tier
 * (the one the owner signed up to on 2026-09-16, app PeekaaSignupOTP, sandbox first) does
 * neither: it wants application/x-www-form-urlencoded with the template addressed by ID and
 * the variables as a flat params list, and it answers { status: 'success', messageId }. So a
 * resolved transport now carries encodeBody(cloudBody) and readReply(status, payload, headers),
 * and the sender calls those instead of choosing. The three JSON wires get the identity pair,
 * which is exactly what the sender did before — proven by the v995 tests still passing.
 *
 * The self-serve params layout is config (GUPSHUP_TEMPLATE_PARAMS, comma-separated, `{code}`
 * substituted) because the sandbox's pre-approved common_otp has THREE variables
 * ("Your OTP for {{1}} is {{2}}. This is valid for {{3}}.") while our own template has one
 * plus a copy-code button (code twice). Default is the production layout, code twice.
 */
const jsonWire = Object.freeze({
  encodeBody: (cloudBody) => JSON.stringify(cloudBody),
  readReply: (status, payload, headers) => classifyMetaResponse(status, payload, headers),
});

const META_CLOUD_HOST = 'https://graph.facebook.com';
const DIALOG360_URL = 'https://waba-v2.360dialog.io/messages';
/* nestly_v996 — Gupshup's Partner v3 endpoint takes the Cloud API body verbatim too. The app
 * token is a non-expiring `sk_…` credential sent RAW in Authorization (no Bearer prefix — their
 * docs, 2026-09-16). The app id is a path segment, so it is validated as one. */
const GUPSHUP_HOST = 'https://partner.gupshup.io';
const GUPSHUP_APP_ID = /^[A-Za-z0-9-]{8,64}$/;
const GUPSHUP_SELFSERVE_URL = 'https://api.gupshup.io/wa/api/v1/template/msg';
const GUPSHUP_SOURCE = /^[0-9]{8,15}$/;
const GUPSHUP_APP_NAME = /^[A-Za-z0-9_]{6,64}$/;
const GUPSHUP_DEFAULT_PARAMS = '{code},{code}';

/* The one field of Meta's body a flat-params wire needs back out: the OTP code. It sits in the
 * body component's first text parameter (buildOtpTemplateSend puts it there and on the button).
 * Anything else — and no code — is refused, never sent as a blank OTP. */
function codeFromCloudBody(cloudBody) {
  const components = cloudBody?.template?.components;
  if (!Array.isArray(components)) return null;
  const body = components.find((c) => c?.type === 'body');
  const text = body?.parameters?.[0]?.text;
  return typeof text === 'string' && /^[0-9]{4,8}$/.test(text) ? text : null;
}

function selfServeWire({ source, appName, templateId, paramsLayout }) {
  return Object.freeze({
    encodeBody: (cloudBody) => {
      const code = codeFromCloudBody(cloudBody);
      const to = String(cloudBody?.to ?? '').replace(/^\+/, '');
      if (!code || !/^[0-9]{8,15}$/.test(to)) return null;
      const params = paramsLayout.split(',').map((p) => p.trim().replaceAll('{code}', code));
      const form = new URLSearchParams();
      form.set('channel', 'whatsapp');
      form.set('source', source);
      form.set('destination', to);
      form.set('src.name', appName);
      form.set('template', JSON.stringify({ id: templateId, params }));
      return form.toString();
    },
    /* Gupshup's shape: 202 { status: 'success', messageId } on accept; { status: 'error',
     * message } otherwise. The messageId is Gupshup's, not a wamid — our status webhook does
     * not key on it, so it is recorded as the send handle and nothing more. */
    readReply: (status, payload) => {
      const id = payload && typeof payload === 'object' ? payload.messageId : null;
      if (status >= 200 && status < 300 && typeof id === 'string' && id) {
        return { disposition: 'sent', wamid: id, code: null, retryAfterSeconds: null };
      }
      const message = payload && typeof payload === 'object' && typeof payload.message === 'string'
        ? payload.message.slice(0, 80) : null;
      const label = status >= 200 && status < 300 ? 'accepted_without_id' : `http_${status}`;
      if (status === 401 || status === 403) {
        return { disposition: 'config_fault', wamid: null, code: label, subcode: null, metaType: message, retryAfterSeconds: null };
      }
      if (status === 429 || status >= 500) {
        return { disposition: 'retry', wamid: null, code: label, subcode: null, metaType: message, retryAfterSeconds: null };
      }
      return { disposition: 'failed', wamid: null, code: label, subcode: null, metaType: message, retryAfterSeconds: null };
    },
  });
}

/* Resolve the outbound transport from an environment-shaped object ({ NAME: value }).
 *
 * Returns { ok: true, transport, url, headers } or { ok: false, reason }. A missing credential is
 * refused BY NAME so a half-configured function never looks like an idle one — the v282 lesson,
 * restated for the third time in this lane. An unrecognised WHATSAPP_TRANSPORT is refused rather
 * than defaulted: a typo in a secret must not silently route production traffic to Meta.
 *
 * Default is meta_cloud so that deploying this changes nothing until WHATSAPP_TRANSPORT is set.
 */
export function resolveWhatsappTransport(env) {
  const read = (name) => String(env?.[name] ?? '').trim();
  const transport = (read('WHATSAPP_TRANSPORT') || 'meta_cloud').toLowerCase();

  if (transport === 'meta_cloud') {
    const token = read('WHATSAPP_ACCESS_TOKEN');
    const path = sendPath(read('WHATSAPP_PHONE_NUMBER_ID'));
    if (!token || !path) return { ok: false, reason: 'send_credentials_unconfigured' };
    return {
      ok: true,
      transport,
      url: `${META_CLOUD_HOST}${path}`,
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      ...jsonWire,
    };
  }

  if (transport === '360dialog') {
    const key = read('D360_API_KEY');
    if (!key) return { ok: false, reason: 'send_credentials_unconfigured' };
    return {
      ok: true,
      transport,
      url: DIALOG360_URL,
      headers: { 'D360-API-KEY': key, 'content-type': 'application/json' },
      ...jsonWire,
    };
  }

  if (transport === 'gupshup') {
    const appId = read('GUPSHUP_APP_ID');
    const token = read('GUPSHUP_APP_TOKEN');
    if (!token || !GUPSHUP_APP_ID.test(appId)) return { ok: false, reason: 'send_credentials_unconfigured' };
    return {
      ok: true,
      transport,
      url: `${GUPSHUP_HOST}/partner/app/${appId}/v3/message`,
      headers: { authorization: token, accept: 'application/json', 'content-type': 'application/json' },
      ...jsonWire,
    };
  }

  if (transport === 'gupshup_selfserve') {
    const apiKey = read('GUPSHUP_API_KEY');
    const source = read('GUPSHUP_SOURCE');
    const appName = read('GUPSHUP_APP_NAME');
    const templateId = read('GUPSHUP_TEMPLATE_ID');
    const paramsLayout = read('GUPSHUP_TEMPLATE_PARAMS') || GUPSHUP_DEFAULT_PARAMS;
    if (!apiKey || !GUPSHUP_SOURCE.test(source) || !GUPSHUP_APP_NAME.test(appName)
      || !GUPSHUP_APP_ID.test(templateId) || !paramsLayout.includes('{code}')) {
      return { ok: false, reason: 'send_credentials_unconfigured' };
    }
    return {
      ok: true,
      transport,
      url: GUPSHUP_SELFSERVE_URL,
      headers: { apikey: apiKey, 'content-type': 'application/x-www-form-urlencoded' },
      ...selfServeWire({ source, appName, templateId, paramsLayout }),
    };
  }

  return { ok: false, reason: 'transport_unrecognised' };
}

/* The only shape of a resolved transport that may reach a log line. */
export function describeTransport(resolved) {
  if (!resolved?.ok) return { transport: null, host: null };
  let host = null;
  try { host = new URL(resolved.url).host; } catch { host = null; }
  return { transport: resolved.transport, host };
}
