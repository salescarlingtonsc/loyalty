/* nestly_v995 — the wire a WhatsApp message goes out on is config, never code.
 *
 * These EXECUTE the resolver the OTP sender imports. The bias: a misconfiguration must be
 * refused by name, never defaulted into routing production traffic somewhere by accident.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

import {
  WHATSAPP_TRANSPORTS,
  describeTransport,
  resolveWhatsappTransport,
} from '../../supabase/functions/_shared/whatsapp-transport-boundaries.mjs';
import { buildOtpTemplateSend } from '../../supabase/functions/_shared/whatsapp-otp-boundaries.mjs';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const readRepoFile = (relative) => readFileSync(resolve(repoRoot, relative), 'utf8');

const META = { WHATSAPP_ACCESS_TOKEN: 'tok_abc', WHATSAPP_PHONE_NUMBER_ID: '123456789012345' };
const D360 = { WHATSAPP_TRANSPORT: '360dialog', D360_API_KEY: 'd360_key_abc' };

test('unset transport means Meta Cloud, so deploying this changes nothing', () => {
  const r = resolveWhatsappTransport(META);
  assert.equal(r.ok, true);
  assert.equal(r.transport, 'meta_cloud');
  assert.equal(r.url, 'https://graph.facebook.com/v21.0/123456789012345/messages');
  assert.deepEqual(r.headers, { authorization: 'Bearer tok_abc', 'content-type': 'application/json' });
});

test('360dialog is one URL and one header, same body', () => {
  const r = resolveWhatsappTransport(D360);
  assert.equal(r.ok, true);
  assert.equal(r.transport, '360dialog');
  assert.equal(r.url, 'https://waba-v2.360dialog.io/messages');
  assert.deepEqual(r.headers, { 'D360-API-KEY': 'd360_key_abc', 'content-type': 'application/json' });
  // Case and whitespace in the switch are the operator's, not ours.
  assert.equal(resolveWhatsappTransport({ ...D360, WHATSAPP_TRANSPORT: '  360Dialog ' }).transport, '360dialog');
});

test('the message body is transport-independent — the adapter never touches it', () => {
  const built = buildOtpTemplateSend({
    toE164: '6581863833', templateName: 'peekaa_signup_otp', languageCode: 'en', code: '123456',
  });
  assert.equal(built.ok, true);
  // Neither resolver output carries or alters a body; the body v894 builds is what both wires
  // accept verbatim. This pins that no transport quietly grows a body rewrite.
  for (const env of [META, D360]) {
    const r = resolveWhatsappTransport(env);
    assert.equal(r.body, undefined);
    assert.ok(!('template' in r));
  }
});

test('a missing credential is refused by name, for every transport', () => {
  assert.deepEqual(resolveWhatsappTransport({}), { ok: false, reason: 'send_credentials_unconfigured' });
  assert.deepEqual(resolveWhatsappTransport({ WHATSAPP_ACCESS_TOKEN: 'tok' }),
    { ok: false, reason: 'send_credentials_unconfigured' }, 'meta needs the phone number id too');
  assert.deepEqual(resolveWhatsappTransport({ WHATSAPP_PHONE_NUMBER_ID: 'not-digits', WHATSAPP_ACCESS_TOKEN: 'tok' }),
    { ok: false, reason: 'send_credentials_unconfigured' }, 'a malformed phone number id is not a path');
  assert.deepEqual(resolveWhatsappTransport({ WHATSAPP_TRANSPORT: '360dialog' }),
    { ok: false, reason: 'send_credentials_unconfigured' });
  assert.deepEqual(resolveWhatsappTransport({ WHATSAPP_TRANSPORT: '360dialog', D360_API_KEY: '   ' }),
    { ok: false, reason: 'send_credentials_unconfigured' }, 'whitespace is not a key');
});

test('an unrecognised transport is refused, never defaulted to Meta', () => {
  // A typo in a secret must not route production traffic to graph.facebook.com by surprise —
  // least of all while that account is disabled.
  const r = resolveWhatsappTransport({ ...META, WHATSAPP_TRANSPORT: 'twilio' });
  assert.deepEqual(r, { ok: false, reason: 'transport_unrecognised' });
  assert.deepEqual(resolveWhatsappTransport({ ...META, WHATSAPP_TRANSPORT: 'meta-cloud' }),
    { ok: false, reason: 'transport_unrecognised' }, 'close is not equal');
  // The full registry is pinned by the newest transport's own test; v995 pins its two.
  for (const t of ['meta_cloud', '360dialog']) assert.ok(WHATSAPP_TRANSPORTS.includes(t));
});

test('describeTransport is the only loggable shape and it carries no credential', () => {
  for (const env of [META, D360]) {
    const d = describeTransport(resolveWhatsappTransport(env));
    const text = JSON.stringify(d);
    assert.ok(!text.includes('tok_abc') && !text.includes('d360_key_abc'), 'no credential may reach a log');
    assert.ok(!text.includes('Bearer') && !text.includes('D360-API-KEY'));
    assert.ok(d.host === 'graph.facebook.com' || d.host === 'waba-v2.360dialog.io');
  }
  assert.deepEqual(describeTransport({ ok: false, reason: 'x' }), { transport: null, host: null });
  assert.deepEqual(describeTransport(null), { transport: null, host: null });
});

test('the OTP sender routes through the resolver and holds no host of its own', () => {
  /* Wiring only — behaviour is proven above by execution. */
  const source = readRepoFile('supabase/functions/whatsapp-otp-start/index.ts');
  assert.match(source, /resolveWhatsappTransport\(/, 'the sender must ask the resolver');
  assert.ok(!/graph\.facebook\.com/.test(source), 'no hard-coded Meta host may survive in the sender');
  assert.ok(!/WHATSAPP_ACCESS_TOKEN|WHATSAPP_PHONE_NUMBER_ID|D360_API_KEY/.test(source),
    'the sender must not read transport credentials directly');
  assert.match(source, /describeTransport\(/, 'only the loggable shape reaches the log');
});
