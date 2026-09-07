/* nestly_v822 — the Stripe reconciler's digest compares instants, not their spelling.

   Production's first real reconciliation run (2026-09-07 17:10 UTC, run b3e84a97) reported
   result=mismatch on 2 items whose detail.nestly and detail.provider were value-identical:
   `current_period_end` on a subscription and `paid_at` on an invoice. The local snapshot read
   PostgREST's `2026-09-06T07:38:46+00:00` straight through; the Stripe-side snapshot built
   `2026-09-06T07:38:46.000Z` from a Unix epoch. Same instant, different bytes, and `digest()`
   hashes bytes. `canonicalInstant` (supabase/functions/_shared/billing-reconciliation.ts) is now
   applied to every timestamp field on both sides before it is digested. */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { canonicalInstant } from '../../supabase/functions/_shared/billing-reconciliation.ts';

const root = new URL('../../', import.meta.url);
const reconcileSource = await readFile(
  new URL('supabase/functions/stripe-billing-reconcile/index.ts', root),
  'utf8',
);

test('the PostgREST and epoch spellings of one instant canonicalise equal', () => {
  assert.equal(
    canonicalInstant('2026-09-06T07:38:46+00:00'),
    canonicalInstant('2026-09-06T07:38:46.000Z'),
  );
  assert.equal(canonicalInstant('2026-09-06T07:38:46+00:00'), '2026-09-06T07:38:46.000Z');
  assert.equal(canonicalInstant('2026-09-06T07:38:46.000Z'), '2026-09-06T07:38:46.000Z');
});

test('epoch seconds canonicalise to the same instant as the equivalent ISO string', () => {
  const epochSeconds = Math.floor(Date.UTC(2026, 8, 6, 7, 38, 46) / 1000);
  assert.equal(canonicalInstant(epochSeconds), canonicalInstant('2026-09-06T07:38:46+00:00'));
  assert.equal(canonicalInstant(epochSeconds), '2026-09-06T07:38:46.000Z');
});

test('null and undefined stay null', () => {
  assert.equal(canonicalInstant(null), null);
  assert.equal(canonicalInstant(undefined), null);
});

test('a +08:00 offset converts to the correct UTC instant', () => {
  assert.equal(canonicalInstant('2026-09-06T15:38:46+08:00'), '2026-09-06T07:38:46.000Z');
});

test('a garbage value throws instead of silently digesting as null or as itself', () => {
  assert.throws(() => canonicalInstant('not-a-date'));
  assert.throws(() => canonicalInstant(''));
  assert.throws(() => canonicalInstant(Number.NaN));
  assert.throws(() => canonicalInstant(Number.POSITIVE_INFINITY));
});

test('a genuinely different instant still differs after canonicalisation', () => {
  assert.notEqual(
    canonicalInstant('2026-09-06T07:38:46+00:00'),
    canonicalInstant('2026-09-06T07:38:47+00:00'),
  );
});

/* Reproduces the exact production shapes from run b3e84a97. digest() itself is not importable
   from Node (it calls sha256Hex from billing-service.ts, which imports the npm:-specifier
   supabase-js client) — so this hashes the canonicalised snapshot with the same generic
   sort-keys-then-sha256 recipe `digest()` uses. The recipe is generic and not the bug under
   test; the canonicalisation applied to each snapshot's timestamp field is the real code path,
   imported above, not a reimplementation. */
function canonicalDigest(value) {
  const entries = Object.entries(value).sort(([left], [right]) => left.localeCompare(right));
  return createHash('sha256').update(JSON.stringify(Object.fromEntries(entries))).digest('hex');
}

test('the real production subscription mismatch digests equal once current_period_end is canonicalised', () => {
  const nestly = {
    items: [{ price_id: 'price_1UCX6vLjvwAsL93HeHolEaDC', quantity: 1 }],
    status: 'active',
    current_period_end: '2026-10-06T07:38:43+00:00',
    cancel_at_period_end: false,
  };
  const provider = {
    items: [{ price_id: 'price_1UCX6vLjvwAsL93HeHolEaDC', quantity: 1 }],
    status: 'active',
    current_period_end: '2026-10-06T07:38:43.000Z',
    cancel_at_period_end: false,
  };
  const canonicalise = (snapshot) => ({
    ...snapshot,
    current_period_end: canonicalInstant(snapshot.current_period_end),
  });
  assert.equal(
    canonicalDigest(canonicalise(nestly)),
    canonicalDigest(canonicalise(provider)),
  );
});

test('the real production invoice mismatch digests equal once paid_at is canonicalised', () => {
  const nestly = {
    status: 'paid',
    paid_at: '2026-09-06T07:38:46+00:00',
    tax_cents: 0,
    total_cents: 100,
    paid_normalized: true,
    amount_paid_cents: 100,
    subtotal_ex_tax_cents: 100,
    amount_remaining_cents: 0,
  };
  const provider = {
    status: 'paid',
    paid_at: '2026-09-06T07:38:46.000Z',
    tax_cents: 0,
    total_cents: 100,
    paid_normalized: true,
    amount_paid_cents: 100,
    subtotal_ex_tax_cents: 100,
    amount_remaining_cents: 0,
  };
  const canonicalise = (snapshot) => ({
    ...snapshot,
    paid_at: canonicalInstant(snapshot.paid_at),
  });
  assert.equal(
    canonicalDigest(canonicalise(nestly)),
    canonicalDigest(canonicalise(provider)),
  );
});

test('the reconciler imports canonicalInstant from the shared module and applies it to every digested timestamp field', () => {
  assert.match(
    reconcileSource,
    /import \{[\s\S]*?canonicalInstant[\s\S]*?\} from '\.\.\/_shared\/billing-reconciliation\.ts';/,
  );
  assert.match(reconcileSource, /current_period_end: canonicalInstant\(subscription\.current_period_end\)/);
  assert.match(reconcileSource, /paid_at: canonicalInstant\(invoice\.paid_at\)/);
  assert.match(
    reconcileSource,
    /function epoch\(value: unknown\): string \| null \{\s*return typeof value === 'number' \? canonicalInstant\(value\) : null;/,
  );
});
