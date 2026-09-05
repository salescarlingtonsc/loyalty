/* nestly_v767 — the reconciliation digest compares instants, not their spelling.

   Observed 2026-09-05 04:06Z: every subscription and invoice in the run was reported as a
   mismatch while both sides held identical values — PostgREST said `+00:00`, the provider
   snapshot said `.000Z`. The digest hashes bytes, so the spelling has to be unified first. */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { isoInstant } from '../../supabase/functions/_shared/billing-instant.ts';

const root = new URL('../../', import.meta.url);
const reconcileSource = await readFile(
  new URL('supabase/functions/razorpay-billing-reconcile/index.ts', root),
  'utf8',
);

test('the PostgREST and epoch spellings of one instant normalise to the same string', () => {
  assert.equal(isoInstant('2027-09-04T16:00:00+00:00'), '2027-09-04T16:00:00.000Z');
  assert.equal(isoInstant('2027-09-04T16:00:00.000Z'), '2027-09-04T16:00:00.000Z');
  assert.equal(isoInstant(new Date(Date.UTC(2027, 8, 4, 16))), '2027-09-04T16:00:00.000Z');
  assert.equal(isoInstant('2026-09-05T03:46:02+00:00'), isoInstant('2026-09-05T03:46:02.000Z'));
});

test('null stays null, and an unparseable value is returned untouched so it still mismatches', () => {
  assert.equal(isoInstant(null), null);
  assert.equal(isoInstant(undefined), null);
  assert.equal(isoInstant(''), null);
  assert.equal(isoInstant('not-a-date'), 'not-a-date');
});

test('a different instant still differs after normalisation', () => {
  assert.notEqual(isoInstant('2027-09-04T16:00:00+00:00'), isoInstant('2027-09-04T16:00:01+00:00'));
});

test('every timestamp the reconciler digests passes through isoInstant', () => {
  assert.match(reconcileSource, /current_period_end: isoInstant\(epoch\(subscription\.current_end\)\)/);
  assert.match(reconcileSource, /current_period_end: isoInstant\(subscription\.current_period_end\)/);
  assert.match(reconcileSource, /paid_at: payment\.status === 'captured' \? isoInstant\(epoch\(payment\.created_at\)\) : null/);
  assert.match(reconcileSource, /paid_at: isoInstant\(invoice\.paid_at\)/);
});
