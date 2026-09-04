import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import {
  constantTimeEqual,
  hmacSha256Hex,
  livemodeFromKey,
  razorpayPlanMatchesCatalogue,
  RazorpayApiError,
  verifyCheckoutSignature,
  verifyWebhookSignature,
} from '../../supabase/functions/_shared/razorpay-client.ts';

const root = new URL('../../', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');

/* The oracle is node:crypto, an INDEPENDENT implementation. Comparing the helper against a digest
   it computed itself would prove only that it is deterministic. */
const oracle = (secret, message) =>
  createHmac('sha256', secret).update(message, 'utf8').digest('hex');

const SECRET = 'v755_webhook_secret_fixture';
const BODY = JSON.stringify({
  entity: 'event',
  account_id: 'acc_fixture',
  event: 'subscription.charged',
  contains: ['subscription', 'payment'],
  payload: {
    subscription: { entity: { id: 'sub_fixture', status: 'active', quantity: 2 } },
    payment: { entity: { id: 'pay_fixture', amount: 9900, currency: 'SGD', status: 'captured' } },
  },
  created_at: 1788000000,
});

test('the webhook HMAC helper agrees with an independent SHA-256 implementation', async () => {
  assert.equal(await hmacSha256Hex(SECRET, BODY), oracle(SECRET, BODY));
  assert.equal(await hmacSha256Hex(SECRET, ''), oracle(SECRET, ''));
  assert.match(await hmacSha256Hex(SECRET, BODY), /^[0-9a-f]{64}$/);
});

test('a genuine Razorpay webhook signature verifies and a tampered one does not', async () => {
  const signature = oracle(SECRET, BODY);
  assert.equal(await verifyWebhookSignature(BODY, signature, SECRET), true);
  assert.equal(await verifyWebhookSignature(BODY, ` ${signature} `, SECRET), true);

  // Tampered BODY: the amount is doubled and the original signature is replayed.
  const tamperedBody = BODY.replace('"amount":9900', '"amount":19800');
  assert.notEqual(tamperedBody, BODY);
  assert.equal(await verifyWebhookSignature(tamperedBody, signature, SECRET), false);

  // Tampered SIGNATURE: one hex character flipped.
  const tamperedSignature = (signature[0] === 'a' ? 'b' : 'a') + signature.slice(1);
  assert.equal(await verifyWebhookSignature(BODY, tamperedSignature, SECRET), false);

  // Wrong secret, truncated signature, and the empty cases must all fail closed.
  assert.equal(await verifyWebhookSignature(BODY, oracle('other_secret', BODY), SECRET), false);
  assert.equal(await verifyWebhookSignature(BODY, signature.slice(0, 32), SECRET), false);
  assert.equal(await verifyWebhookSignature(BODY, '', SECRET), false);
  assert.equal(await verifyWebhookSignature(BODY, signature, ''), false);
});

test('signature comparison is constant time: no early exit on a matching prefix', () => {
  const expected = 'a'.repeat(64);
  assert.equal(constantTimeEqual(expected, expected), true);
  // Differs in the LAST byte only — an early-exit compare would still return false, but it must
  // have examined every byte to do so; the guard below is that the loop has no `return` inside.
  assert.equal(constantTimeEqual(expected, `${'a'.repeat(63)}b`), false);
  // Differs in the FIRST byte only.
  assert.equal(constantTimeEqual(expected, `b${'a'.repeat(63)}`), false);
  // A correct PREFIX of the right digest must not verify.
  assert.equal(constantTimeEqual(expected, 'a'.repeat(32)), false);
  assert.equal(constantTimeEqual(expected, `${expected}a`), false);
  assert.equal(constantTimeEqual('', ''), true);
});

test('the constant-time compare accumulates instead of returning early', async () => {
  const source = await read('supabase/functions/_shared/razorpay-client.ts');
  const body = source.slice(
    source.indexOf('export function constantTimeEqual'),
    source.indexOf('export async function verifyWebhookSignature'),
  );
  const loopStart = body.indexOf('for (let index');
  const loop = body.slice(loopStart, body.indexOf('\n  }', loopStart));
  // Executing the function proves the verdict; this proves HOW it reaches it. A `return` or a
  // `break` inside the comparison loop reintroduces the timing oracle without changing any
  // assertion above.
  assert.doesNotMatch(loop, /\breturn\b|\bbreak\b/);
  assert.match(loop, /difference \|=/);
  assert.doesNotMatch(body, /expected === supplied|expectedBytes\.length !== suppliedBytes\.length\s*\)\s*return/);
});

test('the checkout redirect signature is payment_id|subscription_id under the API key secret', async () => {
  const keySecret = 'v755_key_secret_fixture';
  const paymentId = 'pay_fixture';
  const subscriptionId = 'sub_fixture';
  const signature = oracle(keySecret, `${paymentId}|${subscriptionId}`);
  assert.equal(
    await verifyCheckoutSignature(paymentId, subscriptionId, signature, keySecret),
    true,
  );
  // The two ids are ORDERED and separated: swapping them must not verify.
  assert.equal(
    await verifyCheckoutSignature(subscriptionId, paymentId, signature, keySecret),
    false,
  );
  // A different subscription cannot borrow this payment's signature.
  assert.equal(
    await verifyCheckoutSignature(paymentId, 'sub_other', signature, keySecret),
    false,
  );
  // The WEBHOOK secret must not verify a checkout redirect.
  assert.equal(
    await verifyCheckoutSignature(paymentId, subscriptionId, signature, SECRET),
    false,
  );
  assert.equal(await verifyCheckoutSignature('', subscriptionId, signature, keySecret), false);
});

test('livemode is derived from the key prefix and an unknown prefix disables the check', () => {
  assert.equal(livemodeFromKey('rzp_live_ABC123'), true);
  assert.equal(livemodeFromKey('rzp_test_ABC123'), false);
  assert.equal(livemodeFromKey('rzp_partner_ABC123'), null);
  assert.equal(livemodeFromKey(''), null);
});

test('a plan whose shape differs from the reviewed catalogue is refused', () => {
  const plan = {
    id: 'plan_annual',
    period: 'yearly',
    interval: 1,
    item: { amount: 118800, currency: 'SGD' },
  };
  const expected = { cadence: 'annual', amountCents: 118800, currency: 'SGD' };
  assert.equal(razorpayPlanMatchesCatalogue(plan, expected), true);
  assert.equal(razorpayPlanMatchesCatalogue({ ...plan, period: 'monthly' }, expected), false);
  assert.equal(razorpayPlanMatchesCatalogue({ ...plan, interval: 2 }, expected), false);
  assert.equal(
    razorpayPlanMatchesCatalogue({ ...plan, item: { amount: 9900, currency: 'SGD' } }, expected),
    false,
  );
  assert.equal(
    razorpayPlanMatchesCatalogue({ ...plan, item: { amount: 118800, currency: 'INR' } }, expected),
    false,
  );
  assert.equal(razorpayPlanMatchesCatalogue(null, expected), false);
  // Monthly cadence maps to Razorpay's 'monthly' period.
  assert.equal(
    razorpayPlanMatchesCatalogue(
      { id: 'plan_monthly', period: 'monthly', interval: 1, item: { amount: 9900, currency: 'sgd' } },
      { cadence: 'monthly', amountCents: 9900, currency: 'SGD' },
    ),
    true,
  );
});

test('only a 4xx that is not a 429 proves the provider did not execute', () => {
  assert.equal(new RazorpayApiError(400, 'BAD_REQUEST_ERROR', 'x').nonExecutionProven, true);
  assert.equal(new RazorpayApiError(404, 'NOT_FOUND', 'x').nonExecutionProven, true);
  // A rate limit, a gateway error and a timeout leave the outcome genuinely unknown.
  assert.equal(new RazorpayApiError(429, 'RATE_LIMIT', 'x').nonExecutionProven, false);
  assert.equal(new RazorpayApiError(500, 'SERVER_ERROR', 'x').nonExecutionProven, false);
  assert.equal(new RazorpayApiError(502, 'SERVER_ERROR', 'x').nonExecutionProven, false);
});

test('the webhook verifies before writing, dedupes on the event id and derives livemode', async () => {
  const source = await read('supabase/functions/razorpay-billing-webhook/index.ts');
  const verifyAt = source.indexOf('verifyWebhookSignature(');
  const ingestAt = source.indexOf('ingest_billing_event_v755');
  assert.ok(verifyAt > 0 && ingestAt > verifyAt, 'signature must be verified before any write');
  assert.match(source, /req\.text\(\)/);
  assert.doesNotMatch(source.slice(0, verifyAt), /JSON\.parse/);
  assert.match(source, /x-razorpay-event-id/);
  assert.match(source, /p_provider: 'razorpay'/);
  assert.match(source, /livemodeFromKey\(requiredEnv\('RAZORPAY_KEY_ID'\)\)/);
  assert.match(source, /apply_razorpay_billing_event_v755/);
  assert.match(source, /eventType === 'subscription\.charged'/);
  assert.match(source, /x-v156-dispatch-secret/);
  // No Stripe code path survives. (Comments may still cite the Stripe-era reasoning, so the
  // check is on imports and identifiers, not on prose.)
  assert.doesNotMatch(source, /from '[^']*stripe[^']*'/i);
  assert.doesNotMatch(source, /\bstripe[A-Za-z_.]*\s*\(/);
  assert.doesNotMatch(source, /stripe_billing|stripe-signature|ingest_stripe/i);
});

/* Returns the argument text of every logging call in the webhook: the `rejected(...)` helper and
   any direct console.warn/info/error. Balanced-paren scan, because these arguments are nested
   object literals and a regex would stop at the first ')'. */
function loggedArguments(source) {
  const calls = [];
  const pattern = /(?:\brejected|console\.(?:warn|info|error))\s*\(/g;
  let match;
  while ((match = pattern.exec(source)) !== null) {
    let depth = 1;
    let index = pattern.lastIndex;
    while (index < source.length && depth > 0) {
      if (source[index] === '(') depth += 1;
      else if (source[index] === ')') depth -= 1;
      index += 1;
    }
    calls.push({ start: match.index, text: source.slice(pattern.lastIndex, index - 1) });
  }
  return calls;
}

test('every rejection path names its reason in the log and in the response body', async () => {
  const source = await read('supabase/functions/razorpay-billing-webhook/index.ts');
  /* The 2026-09 incident: Razorpay retried a real payment's subscription.activated/charged/
     authenticated and got 400 every time, with nothing in the logs but "booted". Four distinct
     faults share that status code, so a silent 400 is indistinguishable from the other three —
     and Razorpay disables an endpoint after 24h of failures. */
  const logged = loggedArguments(source);
  assert.ok(logged.length >= 5, 'the webhook must log its outcomes');

  const reasons = logged
    .map(({ text }) => text.match(/^\s*'([a-z_]+)'|reason:\s*'([a-z_]+)'/))
    .filter(Boolean)
    .map((match) => match[1] || match[2]);
  for (const reason of [
    'invalid_signature',
    'invalid_event_object',
    'event_envelope_rejected',
    'event_processing_failed',
    'accepted',
  ]) {
    assert.ok(reasons.includes(reason), `no log line for ${reason}`);
  }

  // Structured, not prose: each line must carry the delivery identity Razorpay sent.
  const bySignature = logged.filter(({ text }) => text.includes("'invalid_signature'"));
  assert.ok(bySignature.length >= 2, 'absent and mismatched signatures must log separately');
  for (const { text } of bySignature) {
    assert.match(text, /event_id:/);
    assert.match(text, /body_bytes:/);
    assert.match(text, /sig_len:/);
  }
  const envelope = logged.find(({ text }) => text.includes("'event_envelope_rejected'"));
  assert.match(envelope.text, /code: inboxError\.code/);
  assert.match(envelope.text, /message: inboxError\.message/);
  const processing = logged.find(({ text }) => text.includes("'event_processing_failed'"));
  assert.match(processing.text, /status: applied\?\.status/);
  assert.match(processing.text, /error: applied\?\.error/);
  const accepted = logged.find(({ text }) => text.includes("'accepted'"));
  assert.match(accepted.text, /event_type/);
  assert.match(accepted.text, /duplicate/);

  // The reason also reaches the caller, so a replay from the Razorpay dashboard is diagnosable
  // without log access.
  assert.match(source, /error: 'invalid_signature', reason: 'signature_header_absent'/);
  assert.match(source, /error: 'invalid_signature', reason: 'signature_mismatch'/);
  assert.match(source, /error: 'invalid_event_object',\s*\n?\s*reason:/);
  assert.match(source, /error: 'event_envelope_rejected', reason: inboxError\.code/);
  assert.match(source, /reason: applyError\?\.code \|\| applied\?\.error \|\| 'apply_failed'/);
});

test('no log line can leak the body, the signature or a secret', async () => {
  const source = await read('supabase/functions/razorpay-billing-webhook/index.ts');
  for (const { text } of loggedArguments(source)) {
    // The body is customer billing data and the payload is the whole of it.
    assert.doesNotMatch(text, /\brawBody\b/, `a log line references rawBody: ${text}`);
    assert.doesNotMatch(text, /\bevent\b(?!_)/, `a log line references the parsed event: ${text}`);
    assert.doesNotMatch(text, /p_payload|payloadDigest/, `a log line references the payload: ${text}`);
    // Secrets: neither the webhook secret nor the API key, under any spelling.
    assert.doesNotMatch(text, /RAZORPAY_[A-Z_]*(?:SECRET|KEY)/, `a log line references a secret: ${text}`);
    assert.doesNotMatch(text, /requiredEnv|Deno\.env/, `a log line reads the environment: ${text}`);
    assert.doesNotMatch(text, /dispatchSecret|SUPABASE_/, `a log line references a secret: ${text}`);
    /* The signature itself must never be printed — only its LENGTH, which is what separates an
       absent header from a truncated one from a wrong-secret digest. */
    assert.doesNotMatch(
      text,
      /\bsignature\b(?!\.length)/,
      `a log line references the signature value: ${text}`,
    );
  }
  // And the whole file must never print the secret, logged or otherwise.
  assert.doesNotMatch(source, /console\.[a-z]+\([^)]*(?:rawBody|RAZORPAY_WEBHOOK_SECRET)/);
});
