/* v504 — Meta WhatsApp Cloud API webhook foundation.
 *
 * These execute the real functions the deployed edge function imports; they do
 * not grep source. The only thing stubbed is Deno.env (index.ts is not imported
 * at all — its plumbing is exercised live against the deployed URL instead, and
 * that evidence is in the migration note).
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

import {
  MIN_VERIFY_TOKEN_LENGTH,
  hmacSha256Hex,
  secretEquals,
  sha256Hex,
  signatureValid,
  summariseEnvelope,
  verificationOutcome,
} from '../../supabase/functions/_shared/whatsapp-webhook-boundaries.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const TOKEN = 'a'.repeat(48);
const APP_SECRET = 'meta-app-secret-fixture';

const q = (pairs) => new URLSearchParams(pairs);

/* ------------------------------------------------------------------ GET ---- */

test('GET verification returns the challenge when mode and token both match', () => {
  const outcome = verificationOutcome(
    q({ 'hub.mode': 'subscribe', 'hub.verify_token': TOKEN, 'hub.challenge': '1158201444' }),
    TOKEN,
  );
  assert.deepEqual(outcome, { ok: true, challenge: '1158201444' });
});

test('GET verification rejects a wrong token with 403 and no challenge', () => {
  const outcome = verificationOutcome(
    q({ 'hub.mode': 'subscribe', 'hub.verify_token': 'b'.repeat(48), 'hub.challenge': 'x' }),
    TOKEN,
  );
  assert.equal(outcome.ok, false);
  assert.equal(outcome.status, 403);
  assert.equal(outcome.error, 'verify_token_mismatch');
  assert.equal(outcome.challenge, undefined);
});

test('GET verification rejects a token of the right value but wrong length', () => {
  // Guards the constant-time compare: a prefix must not pass.
  const outcome = verificationOutcome(
    q({ 'hub.mode': 'subscribe', 'hub.verify_token': TOKEN.slice(0, 40), 'hub.challenge': 'x' }),
    TOKEN,
  );
  assert.equal(outcome.error, 'verify_token_mismatch');
});

test('GET verification refuses a mode other than subscribe', () => {
  const outcome = verificationOutcome(
    q({ 'hub.mode': 'unsubscribe', 'hub.verify_token': TOKEN, 'hub.challenge': 'x' }),
    TOKEN,
  );
  assert.equal(outcome.status, 403);
  assert.equal(outcome.error, 'unsupported_hub_mode');
});

test('GET verification is 503 (ours), not 403 (theirs), when no token is configured', () => {
  for (const weak of ['', 'short', 'a'.repeat(MIN_VERIFY_TOKEN_LENGTH - 1)]) {
    const outcome = verificationOutcome(
      q({ 'hub.mode': 'subscribe', 'hub.verify_token': weak, 'hub.challenge': 'x' }), weak,
    );
    assert.equal(outcome.status, 503, `weak token "${weak}" must not verify`);
    assert.equal(outcome.error, 'verify_token_unconfigured');
  }
});

test('GET verification will not reflect an arbitrary challenge body', () => {
  const outcome = verificationOutcome(
    q({ 'hub.mode': 'subscribe', 'hub.verify_token': TOKEN, 'hub.challenge': '<script>x</script>' }),
    TOKEN,
  );
  assert.equal(outcome.status, 400);
  assert.equal(outcome.error, 'invalid_hub_challenge');
});

/* ------------------------------------------------------- signature -------- */

test('a signature Meta actually produced verifies', async () => {
  const body = JSON.stringify({ object: 'whatsapp_business_account', entry: [] });
  const header = `sha256=${await hmacSha256Hex(APP_SECRET, body)}`;
  assert.equal(await signatureValid(header, body, APP_SECRET), true);
});

test('a body altered by one byte fails, even with the original signature', async () => {
  const body = JSON.stringify({ object: 'whatsapp_business_account', entry: [] });
  const header = `sha256=${await hmacSha256Hex(APP_SECRET, body)}`;
  assert.equal(await signatureValid(header, `${body} `, APP_SECRET), false);
});

test('re-serialised JSON fails — the RAW body is what is signed', async () => {
  // The classic mistake. Same object, different bytes (key order), so the
  // signature must not verify. This is why index.ts hashes req.text().
  const raw = '{"object":"whatsapp_business_account","entry":[]}';
  const reserialised = JSON.stringify({ entry: [], object: 'whatsapp_business_account' });
  const header = `sha256=${await hmacSha256Hex(APP_SECRET, raw)}`;
  assert.notEqual(raw, reserialised);
  assert.equal(await signatureValid(header, reserialised, APP_SECRET), false);
});

test('a signature from a different app secret fails', async () => {
  const body = '{}';
  const header = `sha256=${await hmacSha256Hex('someone-elses-secret', body)}`;
  assert.equal(await signatureValid(header, body, APP_SECRET), false);
});

test('malformed, absent and unconfigured signature inputs all fail closed', async () => {
  const body = '{}';
  const good = await hmacSha256Hex(APP_SECRET, body);
  const cases = [
    [null, APP_SECRET, 'absent header'],
    ['', APP_SECRET, 'empty header'],
    [good, APP_SECRET, 'missing sha256= prefix'],
    ['sha256=nothex', APP_SECRET, 'non-hex digest'],
    [`sha256=${good.slice(0, 63)}`, APP_SECRET, 'truncated digest'],
    [`sha256=${good}`, '', 'no app secret configured'],
  ];
  for (const [header, secret, label] of cases) {
    assert.equal(await signatureValid(header, body, secret), false, label);
  }
});

test('an uppercase hex digest from Meta still verifies', async () => {
  const body = '{}';
  const header = `sha256=${(await hmacSha256Hex(APP_SECRET, body)).toUpperCase()}`;
  assert.equal(await signatureValid(header, body, APP_SECRET), true);
});

/* ------------------------------------------------------- idempotency ------ */

test('byte-identical retries share a digest; any difference does not', async () => {
  // This is the whole idempotency contract: the ingest RPC dedupes on this
  // value, and Meta retries by re-POSTing the same bytes.
  const body = '{"object":"whatsapp_business_account","entry":[{"id":"1"}]}';
  assert.equal(await sha256Hex(body), await sha256Hex(body));
  assert.notEqual(await sha256Hex(body), await sha256Hex(`${body}`.replace('"1"', '"2"')));
  assert.match(await sha256Hex(body), /^[0-9a-f]{64}$/);
});

/* ------------------------------------------------------- envelope --------- */

const STATUS_ENVELOPE = {
  object: 'whatsapp_business_account',
  entry: [{
    id: '111111111111111',
    changes: [{
      field: 'messages',
      value: {
        messaging_product: 'whatsapp',
        metadata: { display_phone_number: '6582088809', phone_number_id: '222222222222222' },
        statuses: [
          { id: 'wamid.AAA', status: 'sent', timestamp: '1787000000', recipient_id: '6582088809' },
          { id: 'wamid.BBB', status: 'delivered', timestamp: '1787000001', recipient_id: '6582088809' },
        ],
      },
    }],
  }],
};

test('a status callback yields its ids for troubleshooting', () => {
  const summary = summariseEnvelope(STATUS_ENVELOPE);
  assert.equal(summary.wabaId, '111111111111111');
  assert.equal(summary.phoneNumberId, '222222222222222');
  assert.deepEqual(summary.entryKinds, ['statuses']);
  assert.deepEqual(summary.metaMessageIds, ['wamid.AAA', 'wamid.BBB']);
});

test('an inbound message and a status in one delivery are both named', () => {
  const summary = summariseEnvelope({
    entry: [{
      id: '9',
      changes: [
        { value: { metadata: { phone_number_id: '5' }, messages: [{ id: 'wamid.IN' }] } },
        { value: { statuses: [{ id: 'wamid.OUT' }] } },
      ],
    }],
  });
  assert.deepEqual(summary.entryKinds.sort(), ['messages', 'statuses']);
  assert.deepEqual(summary.metaMessageIds.sort(), ['wamid.IN', 'wamid.OUT']);
});

test('an undocumented payload shape degrades to other rather than throwing', () => {
  for (const payload of [
    {},
    { entry: [] },
    { entry: [{ id: '1', changes: [] }] },
    { entry: [{ id: '1', changes: [{ field: 'some_future_field', value: {} }] }] },
    null,
    { entry: 'not-an-array' },
    { entry: [{ changes: [{ value: { statuses: 'not-an-array' } }] }] },
  ]) {
    const summary = summariseEnvelope(payload);
    assert.deepEqual(summary.entryKinds, ['other'], JSON.stringify(payload));
    assert.deepEqual(summary.metaMessageIds, []);
  }
});

test('the summary never carries a phone number or message text', () => {
  const summary = summariseEnvelope({
    entry: [{
      id: '9',
      changes: [{
        value: {
          metadata: { display_phone_number: '6582088809', phone_number_id: '5' },
          messages: [{ id: 'wamid.IN', from: '6591234567', text: { body: 'my medical results' } }],
        },
      }],
    }],
  });
  const serialised = JSON.stringify(summary);
  assert.ok(!serialised.includes('6591234567'), 'a sender number must not reach the summary');
  assert.ok(!serialised.includes('medical'), 'message text must not reach the summary');
  assert.ok(!serialised.includes('6582088809'), 'the display number must not reach the summary');
});

test('a hostile envelope cannot make the observability arrays unbounded', () => {
  const summary = summariseEnvelope({
    entry: [{
      id: 'x'.repeat(500),
      changes: [{
        value: { statuses: Array.from({ length: 5000 }, (_, i) => ({ id: `wamid.${i}` })) },
      }],
    }],
  });
  assert.equal(summary.wabaId, null, 'an over-long id is dropped, not stored');
  assert.ok(summary.metaMessageIds.length <= 200);
  assert.ok(summary.entryKinds.length <= 8);
});

/* ------------------------------------------------------- secrets ---------- */

test('secretEquals rejects prefixes, suffixes, empties and non-strings', () => {
  assert.equal(secretEquals('abcdef', 'abcdef'), true);
  for (const [a, b] of [
    ['abcdef', 'abcde'], ['abcde', 'abcdef'], ['', ''], ['abc', 'abd'],
    ['abc', null], [null, 'abc'], ['abc', undefined],
  ]) {
    assert.equal(secretEquals(a, b), false, `${a} vs ${b}`);
  }
});

test('no WhatsApp secret name appears in any browser-served bundle', () => {
  // The owner's constraint: tokens are server-side only. app/*.js is what
  // Vercel serves; nothing in it may even name these variables.
  const names = [
    'WHATSAPP_ACCESS_TOKEN', 'WHATSAPP_APP_SECRET', 'WHATSAPP_WEBHOOK_VERIFY_TOKEN',
    'WHATSAPP_PHONE_NUMBER_ID', 'WHATSAPP_BUSINESS_ACCOUNT_ID',
  ];
  const bundles = [
    'app/app.js', 'app/app-core.js', 'app/app-business.js', 'app/app-customer.js',
    'app/app-auth.js', 'app/platform-console.js', 'app/index.html', 'app/runtime-config.js',
  ];
  for (const bundle of bundles) {
    const source = readFileSync(resolve(ROOT, bundle), 'utf8');
    for (const name of names) {
      assert.ok(!source.includes(name), `${name} must not appear in ${bundle}`);
    }
  }
});

test('the edge function is registered as public — Meta cannot present a JWT', () => {
  const config = readFileSync(resolve(ROOT, 'supabase/config.toml'), 'utf8');
  const block = config.match(/\[functions\.whatsapp-webhook\]\s*\nverify_jwt = (\w+)/);
  assert.ok(block, 'whatsapp-webhook must be declared in supabase/config.toml');
  assert.equal(block[1], 'false');
});

test('the endpoint never replies to a customer or calls the Meta send API', () => {
  // Phase scope, enforced rather than promised: this build receives only.
  const source = readFileSync(resolve(ROOT, 'supabase/functions/whatsapp-webhook/index.ts'), 'utf8');
  for (const forbidden of ['graph.facebook.com', '/messages', 'WHATSAPP_ACCESS_TOKEN']) {
    assert.ok(!source.includes(forbidden), `${forbidden} is out of scope for the webhook foundation`);
  }
});
