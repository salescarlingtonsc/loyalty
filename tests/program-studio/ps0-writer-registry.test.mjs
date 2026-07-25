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
import { extractFileEvents, stripSqlComments } from '../../scripts/ps0/discover-writers.mjs';

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

// Regression: a comment apostrophe inside a function body must NOT desync the $$ body scanner.
// Before the hardening, `-- don't` flipped the comment-blind walker into string mode, truncated the
// body (dropping its real value-write) and could swallow the NEXT function's boundary — which is
// exactly how a kernel finaliser vanished from the writer set and its inserts were mis-read as a
// migration backfill. The scanner is the exhaustiveness oracle; it must be un-foolable by a comment.
test('body-scanner strips comments and is un-foolable by an apostrophe in a `-- don\'t` comment', () => {
  assert.equal(stripSqlComments("x -- don't touch\ny").replace(/\s+/g, ' ').trim(), 'x y',
    'stripSqlComments must remove a `--` comment containing an apostrophe');

  const sql = [
    "create or replace function public.demo_writer(p uuid)",
    "returns void language plpgsql security definer set search_path = public as $$",
    "begin",
    "  -- don't let this comment apostrophe desync the body scan",
    "  insert into public.credit_ledger(business_id, amount_cents) values (p, 1);",
    "end $$;",
    "create or replace function public.after_writer(q uuid)",
    "returns void language sql as $$ select 1 $$;",
  ].join('\n');

  const events = extractFileEvents(sql).filter((e) => e.kind === 'create');
  assert.deepEqual(events.map((e) => `${e.schema}.${e.name}/${e.arity}`),
    ['public.demo_writer/1', 'public.after_writer/1'],
    'both functions must be extracted; the odd apostrophe must not cascade past demo_writer');
  const demo = events.find((e) => e.name === 'demo_writer');
  assert.match(demo.bodyInner, /insert\s+into\s+public\.credit_ledger/i,
    'the real value-write after the `-- don\'t` comment must remain inside the extracted body');
});

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

// ---------------------------------------------------------------------------
// REGISTRY TRUTH (not merely registry EXHAUSTIVENESS).
//
// The tests above compare only the identity SET, which is why the curated
// `latest_file` / `rows_written` fields have silently rotted three times now
// (v67 rev-4 finding F3; v68a rev-2 finding D2). A registry that names the wrong
// defining migration, or omits a table the writer demonstrably inserts into, is
// worse than no registry: reviewers read it as fact. These fields are mechanically
// derivable from the discovery tool, so they are now mechanically checked.
//
// `rows_written` stays human prose (it carries per-kind notes discovery cannot
// know, and names untracked tables such as audit_log). The machine-checked part is
// the claims it makes about tables in the discovery tool's own VALUE_TABLES
// registry: those must be EXACTLY the direct writes discovery found. A write
// performed by a helper the writer calls is legitimate to document, but must be
// marked indirect with a `via` annotation - either `; via <fn>: t:OP, ...` or an
// inline `(via <fn>)` - so it is never mistaken for a direct write.
const trackedTables = new Set(Object.keys(first.json.value_table_registry));

function parseRowsWritten(text) {
  const claims = [];
  for (const clause of String(text || '').split(';')) {
    // Any `identifier:` is a boundary (so `audit_log:INSERT` terminates the
    // preceding table's op-spec), but only tracked tables become claims.
    const re = /\b([a-z_][a-z0-9_]*)\s*:/g;
    const hits = [];
    let m;
    while ((m = re.exec(clause))) hits.push({ table: m[1], start: m.index, end: re.lastIndex });
    const prefix = hits.length ? clause.slice(0, hits[0].start) : clause;
    const clauseIndirect = /\bvia\b/i.test(prefix);
    for (let i = 0; i < hits.length; i++) {
      if (!trackedTables.has(hits[i].table)) continue;
      const spec = clause.slice(hits[i].end, i + 1 < hits.length ? hits[i + 1].start : clause.length);
      const ops = [...new Set((spec.match(/\b(INSERT|UPDATE|DELETE)\b/gi) || []).map((o) => o.toUpperCase()))];
      claims.push({ table: hits[i].table, ops, indirect: clauseIndirect || /\bvia\b/i.test(spec) });
    }
  }
  return claims;
}

const discoveryById = new Map();
for (const w of [...first.json.db_writers, ...first.json.db_delegating_entrypoints]) {
  discoveryById.set(w.id, { latest_file: w.latest_file, writes: w.writes });
}
for (const t of first.json.triggers) discoveryById.set(t.id, { latest_file: t.file, writes: null });

test('every curated writer names the migration that actually defines it (latest_file)', () => {
  const wrong = [];
  for (const w of registry.writers) {
    const disc = discoveryById.get(w.id);
    if (!disc) continue;   // browser.rpc / edge ids carry no defining migration
    if (w.latest_file !== disc.latest_file) {
      wrong.push(`${w.id}: registry says ${w.latest_file}, discovery says ${disc.latest_file}`);
    }
  }
  assert.deepEqual(
    wrong, [],
    'Curated latest_file disagrees with scripts/ps0/discover-writers.mjs. A later migration re-created\n' +
    'these writers and the registry was not updated (or a rename moved the body):\n  - ' + wrong.join('\n  - '),
  );
});

test('every curated writer names the value tables it actually writes (rows_written)', () => {
  const fmt = (map) => [...map.entries()]
    .map(([t, ops]) => `${t}:${[...ops].sort().join('/')}`).sort().join(', ') || '(none)';
  const wrong = [];
  for (const w of registry.writers) {
    const disc = discoveryById.get(w.id);
    if (!disc || !disc.writes) continue;   // triggers are checked by their function's entry
    const claimed = new Map();
    for (const c of parseRowsWritten(w.rows_written)) {
      if (c.indirect) continue;
      claimed.set(c.table, new Set([...(claimed.get(c.table) || []), ...c.ops]));
    }
    const found = new Map(disc.writes.map((x) => [x.table, new Set(x.ops)]));
    const a = fmt(claimed);
    const b = fmt(found);
    if (a !== b) wrong.push(`${w.id}\n      registry claims:  ${a}\n      discovery finds:  ${b}`);
  }
  assert.deepEqual(
    wrong, [],
    'Curated rows_written disagrees with scripts/ps0/discover-writers.mjs for tracked value tables.\n' +
    'Name every direct write; mark writes performed by a called helper with a `via` annotation:\n  - ' + wrong.join('\n  - '),
  );
});

test('the rows_written parser distinguishes direct writes from `via` helper writes', () => {
  // Guard the guard: if this parser silently stopped finding claims, both checks above
  // would pass vacuously — which is exactly how the fields rotted in the first place.
  const direct = parseRowsWritten('sv_operations:INSERT, sv_lot_movements:INSERT, audit_log:INSERT');
  assert.deepEqual(direct.map((c) => `${c.table}:${c.ops.join('/')}:${c.indirect}`),
    ['sv_operations:INSERT:false', 'sv_lot_movements:INSERT:false'],
    'a plain list must yield direct claims, and the untracked audit_log must not leak into the previous op-spec');
  const viaClause = parseRowsWritten('event_outbox:INSERT; via app.helper: program_entitlements:INSERT/UPDATE');
  assert.deepEqual(viaClause.map((c) => `${c.table}:${c.indirect}`),
    ['event_outbox:false', 'program_entitlements:true'], '`; via <fn>:` must mark the whole clause indirect');
  const viaInline = parseRowsWritten('sv_operations:INSERT (via app.sv_reserve_core)');
  assert.deepEqual(viaInline.map((c) => c.indirect), [true], 'an inline `(via ...)` must mark that claim indirect');
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

test('PS-2A stored-value FOUNDATION is present; the mutable-balance / alternate-naming tables stay absent', () => {
  // PS-2A (v61) builds the lot-based foundation, so the "no stored value yet" precondition
  // is deliberately lifted. What must NEVER appear is a single-balance stored_value table,
  // an sv_balances cache, or a gift_card_lots shadow — the mutable-balance anti-pattern the
  // discovery tool still guards (FORBIDDEN_STORED_VALUE_TABLES).
  assert.deepEqual(first.json.stored_value_tables_present, [],
    'a mutable-balance / alternate-naming stored-value table appeared; that anti-pattern is forbidden');
  assert.equal(registry.stored_value_absent_confirmed, false,
    'PS-2A introduced the stored-value foundation, so stored_value_absent_confirmed must be false');
  // v66 mint-path closure: the v61 sv_topup/sv_grant browser mint RPCs are RETIRED to fail-closed stubs
  // (execute revoked + raise, writing nothing), so discovery no longer finds them as value writers; the
  // sole authoritative stored-value mint is now record_sv_topup_sale (staff-assisted top-up sale).
  const ids = new Set(first.json.discovered_identities.map((i) => i.id));
  assert.ok(!ids.has('db.fn:public.sv_topup/4'), 'sv_topup is retired in v66 and must no longer be a discovered value writer');
  assert.ok(!ids.has('db.fn:public.sv_grant/5'), 'sv_grant is retired in v66 and must no longer be a discovered value writer');
  assert.ok(ids.has('db.fn:public.record_sv_topup_sale/6'), 'record_sv_topup_sale must be discovered as the stored-value mint writer');
  const writerIds = new Set(registry.writers.map((w) => w.id));
  assert.ok(writerIds.has('db.fn:public.record_sv_topup_sale/6'),
    'the authoritative top-up-sale mint RPC must be a curated writer (not merely allowlisted)');
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
