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
import { sendPath } from './whatsapp-send-boundaries.mjs';

export const WHATSAPP_TRANSPORTS = Object.freeze(['meta_cloud', '360dialog', 'gupshup']);

const META_CLOUD_HOST = 'https://graph.facebook.com';
const DIALOG360_URL = 'https://waba-v2.360dialog.io/messages';
/* nestly_v996 — Gupshup's Partner v3 endpoint takes the Cloud API body verbatim too. The app
 * token is a non-expiring `sk_…` credential sent RAW in Authorization (no Bearer prefix — their
 * docs, 2026-09-16). The app id is a path segment, so it is validated as one. */
const GUPSHUP_HOST = 'https://partner.gupshup.io';
const GUPSHUP_APP_ID = /^[A-Za-z0-9-]{8,64}$/;

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
