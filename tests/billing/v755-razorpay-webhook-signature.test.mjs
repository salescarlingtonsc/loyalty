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
