import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import test from 'node:test';

const root = resolve(new URL('../..', import.meta.url).pathname);
const executor = readFileSync(
  resolve(root, 'supabase/functions/stripe-billing-command/index.ts'), 'utf8');

/* The block that creates the subscription Checkout Session, isolated so an assertion cannot be
   satisfied by the string appearing somewhere else in the file. */
function checkoutSessionCreateBlock() {
  const start = executor.indexOf('const session = await stripe.checkout.sessions.create(');
  assert.ok(start > -1, 'the checkout session creation could not be found');
  const end = executor.indexOf('{ idempotencyKey },', start);
  assert.ok(end > start, 'the checkout session creation is not shaped as expected');
  return executor.slice(start, end);
}

test('subscription checkout offers cards only, never Link', () => {
  /* nestly_v796 (owner ruling 2026-09-06). A Link payment method is stored as type 'link' and
     carries NO brand and NO last4 — Stripe simply does not give them to the merchant. A firm that
     paid through Link could therefore never be shown which card renews its subscription: the
     Subscription page could only ever say "Payment method on file", and no refresh would improve
     it. Naming the payment method is worth more here than Link's one-tap convenience, so the
     Checkout Session pins the method list rather than inheriting the dashboard's automatic
     methods, which can be switched back on without a code change. */
  assert.match(checkoutSessionCreateBlock(), /payment_method_types: \['card'\]/,
    'the checkout session must pin card, or Stripe falls back to automatic methods incl. Link');
});

test('nothing else re-opens the payment method list for checkout', () => {
  /* automatic_payment_methods and payment_method_types are mutually exclusive on a Session; if a
     later change adds the former, Stripe silently ignores the latter and Link returns. */
  assert.doesNotMatch(checkoutSessionCreateBlock(), /automatic_payment_methods/,
    'automatic_payment_methods would override the pinned card-only list');
  const linkMentions = executor.match(/payment_method_types: \[[^\]]*'link'[^\]]*\]/g) || [];
  assert.equal(linkMentions.length, 0, 'no code path may add Link back to a checkout');
});
