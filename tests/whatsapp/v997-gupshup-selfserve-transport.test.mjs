/* nestly_v997 — the first wire that is not "same body": Gupshup self-serve.
 *
 * Owner signed up to Gupshup's self-serve tier on 2026-09-16 (app PeekaaSignupOTP, sandbox).
 * That tier is form-encoded, addresses the template by ID, takes flat params, and answers
 * { status, messageId }. These EXECUTE the encoder and the reply reader against the real
 * Cloud body v894 builds, so the sandbox test is a credentials flip and not a guess.
 */
import test from 'node:test';
import assert from 'node:assert/strict';

import { describeTransport, resolveWhatsappTransport, WHATSAPP_TRANSPORTS } from '../../supabase/functions/_shared/whatsapp-transport-boundaries.mjs';
import { buildOtpTemplateSend } from '../../supabase/functions/_shared/whatsapp-otp-boundaries.mjs';

const ENV = {
  WHATSAPP_TRANSPORT: 'gupshup_selfserve',
  GUPSHUP_API_KEY: 'gs_key_abc',
  GUPSHUP_SOURCE: '917834811114',
  GUPSHUP_APP_NAME: 'PeekaaSignupOTP',
  GUPSHUP_TEMPLATE_ID: 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d',
};
const cloud = () => buildOtpTemplateSend({
  toE164: '6581863833', templateName: 'peekaa_signup_otp', languageCode: 'en', code: '482913',
}).body;

test('every wire carries an encoder and a reader, and the JSON wires are the identity pair', () => {
  assert.deepEqual([...WHATSAPP_TRANSPORTS], ['meta_cloud', '360dialog', 'gupshup', 'gupshup_selfserve']);
  const meta = resolveWhatsappTransport({ WHATSAPP_ACCESS_TOKEN: 't', WHATSAPP_PHONE_NUMBER_ID: '123456789012345' });
  assert.equal(meta.encodeBody(cloud()), JSON.stringify(cloud()), 'meta sends the Cloud body verbatim');
  const ok = meta.readReply(200, { messages: [{ id: 'wamid.X' }] }, new Headers());
  assert.equal(ok.disposition, 'sent');
  assert.equal(ok.wamid, 'wamid.X');
});

test('self-serve encodes the Cloud body as Gupshup form fields, code twice by default', () => {
  const r = resolveWhatsappTransport(ENV);
  assert.equal(r.ok, true);
  assert.equal(r.url, 'https://api.gupshup.io/wa/api/v1/template/msg');
  assert.deepEqual(r.headers, { apikey: 'gs_key_abc', 'content-type': 'application/x-www-form-urlencoded' });
  const form = new URLSearchParams(r.encodeBody(cloud()));
  assert.equal(form.get('channel'), 'whatsapp');
  assert.equal(form.get('source'), '917834811114');
  assert.equal(form.get('destination'), '6581863833', 'no plus sign on the wire');
  assert.equal(form.get('src.name'), 'PeekaaSignupOTP');
  assert.deepEqual(JSON.parse(form.get('template')), { id: ENV.GUPSHUP_TEMPLATE_ID, params: ['482913', '482913'] });
});

test('the params layout is config, so the sandbox common_otp (three variables) needs no code', () => {
  const r = resolveWhatsappTransport({ ...ENV, GUPSHUP_TEMPLATE_PARAMS: 'Peekaa sign-up, {code} ,5 minutes' });
  const form = new URLSearchParams(r.encodeBody(cloud()));
  assert.deepEqual(JSON.parse(form.get('template')).params, ['Peekaa sign-up', '482913', '5 minutes']);
});

test('a body without a code is refused, never sent as a blank OTP', () => {
  const r = resolveWhatsappTransport(ENV);
  assert.equal(r.encodeBody({ to: '6581863833', template: { components: [] } }), null);
  assert.equal(r.encodeBody({ to: 'not-a-number', template: cloud().template }), null);
  assert.equal(r.encodeBody(null), null);
});

test('the reply reader speaks Gupshup: messageId is the send handle, errors are named', () => {
  const r = resolveWhatsappTransport(ENV);
  const sent = r.readReply(202, { status: 'success', messageId: 'gs-msg-1' }, new Headers());
  assert.equal(sent.disposition, 'sent');
  assert.equal(sent.wamid, 'gs-msg-1');
  assert.equal(r.readReply(202, { status: 'success' }).code, 'accepted_without_id');
  assert.equal(r.readReply(202, { status: 'success' }).disposition, 'failed');
  const auth = r.readReply(401, { status: 'error', message: 'Authentication Failed' });
  assert.equal(auth.disposition, 'config_fault');
  assert.equal(auth.code, 'http_401');
  assert.equal(auth.metaType, 'Authentication Failed');
  assert.equal(r.readReply(400, { status: 'error', message: 'Invalid Destination' }).disposition, 'failed');
  assert.equal(r.readReply(429, null).disposition, 'retry');
  assert.equal(r.readReply(503, 'not json').disposition, 'retry');
});

test('a missing or malformed self-serve credential is refused by name', () => {
  const refused = { ok: false, reason: 'send_credentials_unconfigured' };
  assert.deepEqual(resolveWhatsappTransport({ WHATSAPP_TRANSPORT: 'gupshup_selfserve' }), refused);
  assert.deepEqual(resolveWhatsappTransport({ ...ENV, GUPSHUP_API_KEY: ' ' }), refused);
  assert.deepEqual(resolveWhatsappTransport({ ...ENV, GUPSHUP_SOURCE: '+917834811114' }), refused, 'digits only');
  assert.deepEqual(resolveWhatsappTransport({ ...ENV, GUPSHUP_APP_NAME: 'Peekaa Signup' }), refused, 'their own naming rule');
  assert.deepEqual(resolveWhatsappTransport({ ...ENV, GUPSHUP_TEMPLATE_ID: '' }), refused);
  assert.deepEqual(resolveWhatsappTransport({ ...ENV, GUPSHUP_TEMPLATE_PARAMS: 'a,b' }), refused, 'a layout with no {code} sends no code');
});

test('the credential never reaches the loggable shape', () => {
  const d = describeTransport(resolveWhatsappTransport(ENV));
  assert.deepEqual(d, { transport: 'gupshup_selfserve', host: 'api.gupshup.io' });
  assert.ok(!JSON.stringify(d).includes('gs_key_abc'));
});
