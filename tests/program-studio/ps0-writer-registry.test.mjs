// PS-0 writer-registry exhaustiveness guard.
//
// Re-runs the static discovery tool (scripts/ps0/discover-writers.mjs) and diffs
// its identity set against the curated registry (docs/design/ps0/writer-registry.json).
//
//   * Any writer surface present IN CODE but ABSENT from the registry FAILS the
//     test — this is the repeatable-exhaustiveness contract from PS-0 §17: the
//     audit "never stops at a predetermined count", so a newly-added value writer
//     cannot land without being curated (into `writers`) or explicitly excused
//     (into `allowlist`, with justification).
//   * Any id in the registry that no longer exists in code also FAILS, so the
//     registry cannot rot: a removed/renamed writer must be reconciled.
//   * The discovery output must be deterministic (byte-identical on re-run).
//   * The "no stored value yet" claim is asserted (PS-0 precondition for PS-2).
//
// Read-only: the discovery tool never touches a database.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO = join(__dirname, '..', '..');
const DISCOVERY = join(REPO, 'scripts', 'ps0', 'discover-writers.mjs');
const REGISTRY = join(REPO, 'docs', 'design', 'ps0', 'writer-registry.json');

function runDiscovery() {
  const out = execFileSync(process.execPath, [DISCOVERY], { cwd: REPO, maxBuffer: 64 * 1024 * 1024 });
  return { text: out.toString(), json: JSON.parse(out.toString()) };
}

const first = runDiscovery();
const registry = JSON.parse(readFileSync(REGISTRY, 'utf8'));

test('discovery output is deterministic', () => {
  const second = runDiscovery();
  assert.equal(first.text, second.text, 'discover-writers.mjs must produce byte-identical output on re-run');
});

test('every discovered writer identity is accounted for in the registry', () => {
  const discovered = new Set(first.json.discovered_identities.map((i) => i.id));
  const known = new Set([
    ...registry.writers.map((w) => w.id),
    ...registry.allowlist.map((a) => a.id),
  ]);

  const missing = [...discovered].filter((id) => !known.has(id)).sort();
  assert.deepEqual(
    missing, [],
    `New writer surface(s) found in code but not in docs/design/ps0/writer-registry.json.\n` +
    `Curate each into "writers" (with kernel_migratability) or, if genuinely benign, into "allowlist" with justification:\n  - ${missing.join('\n  - ')}`,
  );
});

test('registry has no stale identities that no longer exist in code', () => {
  const discovered = new Set(first.json.discovered_identities.map((i) => i.id));
  const known = [
    ...registry.writers.map((w) => w.id),
    ...registry.allowlist.map((a) => a.id),
  ];
  const stale = known.filter((id) => !discovered.has(id)).sort();
  assert.deepEqual(
    stale, [],
    `Registry lists identities that discovery no longer finds (removed/renamed writers). Reconcile:\n  - ${stale.join('\n  - ')}`,
  );
});

test('registry writers and allowlist ids are unique and disjoint', () => {
  const writerIds = registry.writers.map((w) => w.id);
  const allowIds = registry.allowlist.map((a) => a.id);
  assert.equal(new Set(writerIds).size, writerIds.length, 'duplicate ids in registry.writers');
  assert.equal(new Set(allowIds).size, allowIds.length, 'duplicate ids in registry.allowlist');
  const overlap = writerIds.filter((id) => allowIds.includes(id));
  assert.deepEqual(overlap, [], `ids appear in both writers and allowlist: ${overlap.join(', ')}`);
});

test('every value-impacting discovered identity is a curated writer (not merely allowlisted), except run-once backfills', () => {
  const allowSet = new Set(registry.allowlist.map((a) => a.id));
  const writerSet = new Set(registry.writers.map((w) => w.id));
  // Value writes are either runtime writers (must be in writers[]) or one-time
  // migration backfills (id prefix db.backfill:, allowed in allowlist).
  const offenders = first.json.discovered_identities
    .filter((i) => i.value_impact && !i.id.startsWith('db.backfill:'))
    .filter((i) => !writerSet.has(i.id))
    .map((i) => i.id)
    .sort();
  assert.deepEqual(
    offenders, [],
    `Value-impacting runtime writers must be curated in "writers" (with kernel_migratability), not only allowlisted:\n  - ${offenders.join('\n  - ')}`,
  );
  // sanity: allowlisted value backfills really are backfills
  for (const i of first.json.discovered_identities) {
    if (i.value_impact && allowSet.has(i.id)) {
      assert.ok(i.id.startsWith('db.backfill:'), `only db.backfill ids may be value-impacting and allowlisted, got ${i.id}`);
    }
  }
});

test('no stored-value tables exist yet (PS-0 precondition for PS-2)', () => {
  assert.deepEqual(first.json.stored_value_tables_present, [], 'a stored-value table appeared; the PS-0 "no stored value yet" claim is falsified');
  assert.equal(registry.stored_value_absent_confirmed, true);
});

test('the named kernel candidate and the minimum inspection set are present as writers', () => {
  const ids = new Set(registry.writers.map((w) => w.id));
  // Minimum inspection set from PS-0 §9 + the task brief (each must have been discovered).
  const required = [
    'db.fn:public.record_quick_sale/9',
    'db.fn:public.record_cart_sale/7',
    'db.fn:public.record_sale_by_phone/9',
    'db.trigger:sales:trg_sale_recorded',
    'db.fn:public.sell_package/3',
    'db.fn:public.sell_package/4',
    'db.fn:public.use_package_session/3',
    'db.fn:public.enroll_membership/3',
    'db.fn:public.enroll_membership_v41/4',
    'db.fn:app.run_membership_renewals/0',
    'db.fn:public.issue_gift_card/5',
    'db.fn:public.redeem_gift_card/4',
    'db.fn:public.record_credit_tender/5',
    'db.fn:public.record_payment/12',
    'db.fn:public.redeem_points/3',
    'db.fn:public.redeem_reward_at_context/7',
    'db.fn:app.redeem_reward_core/7',
    'db.fn:public.reverse_sale/6',
    'db.fn:public.reverse_sale_v20_base/6',
    'db.fn:public.reverse_loyalty_redemption/4',
    'db.fn:public.reclassify_sale_policy/3',
    'db.fn:public.customer_activate_birthday_benefit/2',
    'db.fn:public.issue_campaign_offer/6',
    'db.trigger:sales:trg_sale_stock_deduct',
  ];
  const absent = required.filter((id) => !ids.has(id));
  assert.deepEqual(absent, [], `minimum inspection-set writers missing from registry: ${absent.join(', ')}`);
});
