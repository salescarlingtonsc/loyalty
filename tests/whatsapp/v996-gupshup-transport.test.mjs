/* nestly_v996 — Gupshup as a third wire for the OTP send.
 *
 * Owner, 2026-09-16: Gupshup is the BSP to ask first (no platform fee; 360dialog's Starter tier
 * only pays off past ~32 businesses). These EXECUTE the resolver so that the day Gupshup says yes,
 * going live is two secrets, not a deployment — the v995 promise, kept for a second provider.
 */
import test from 'node:test';
import assert from 'node:assert/strict';

import { describeTransport, resolveWhatsappTransport } from '../../supabase/functions/_shared/whatsapp-transport-boundaries.mjs';

const GUPSHUP = {
  WHATSAPP_TRANSPORT: 'gupshup',
  GUPSHUP_APP_ID: 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d',
  GUPSHUP_APP_TOKEN: 'sk_gupshup_token_abc',
};

test('gupshup is the partner v3 message URL and a raw app token, same body', () => {
  const r = resolveWhatsappTransport(GUPSHUP);
  assert.equal(r.ok, true);
  assert.equal(r.transport, 'gupshup');
  assert.equal(r.url, 'https://partner.gupshup.io/partner/app/a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d/v3/message');
  // Their docs send the sk_ token bare — a Bearer prefix would be refused upstream.
  assert.equal(r.headers.authorization, 'sk_gupshup_token_abc');
  assert.equal(r.headers['content-type'], 'application/json');
  assert.equal(r.body, undefined, 'the adapter never grows a body rewrite');
  assert.equal(resolveWhatsappTransport({ ...GUPSHUP, WHATSAPP_TRANSPORT: ' Gupshup ' }).transport, 'gupshup');
});

test('a missing or malformed gupshup credential is refused by name', () => {
  const refused = { ok: false, reason: 'send_credentials_unconfigured' };
  assert.deepEqual(resolveWhatsappTransport({ WHATSAPP_TRANSPORT: 'gupshup' }), refused);
  assert.deepEqual(resolveWhatsappTransport({ ...GUPSHUP, GUPSHUP_APP_TOKEN: '  ' }), refused, 'whitespace is not a token');
  assert.deepEqual(resolveWhatsappTransport({ ...GUPSHUP, GUPSHUP_APP_ID: '' }), refused, 'the app id is a path segment');
  assert.deepEqual(resolveWhatsappTransport({ ...GUPSHUP, GUPSHUP_APP_ID: 'x/../../partner/account' }), refused,
    'an app id can never rewrite the path');
  assert.deepEqual(resolveWhatsappTransport({ ...GUPSHUP, GUPSHUP_APP_ID: 'short' }), refused);
});

test('gupshup credentials never reach the loggable shape', () => {
  const d = describeTransport(resolveWhatsappTransport(GUPSHUP));
  assert.deepEqual(d, { transport: 'gupshup', host: 'partner.gupshup.io' });
  assert.ok(!JSON.stringify(d).includes('sk_gupshup_token_abc'));
});
