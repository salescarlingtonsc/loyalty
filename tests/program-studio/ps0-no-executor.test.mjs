// PS-1A no-executor static guard — proves the AUTHORING/PROJECTION/VALIDATION set
// is permitted while EVERY Program-Studio financial-EXECUTION surface stays absent,
// and turns "someone landed executor schema" into a red test.
//
// The guard is driven by the machine-readable marker docs/design/ps0/PS-GATES.md:
//   - it reads which phases are AUTHORIZED,
//   - it reads the PS-1A AUTHORING ARTIFACTS (program_rules*, benefit_registry,
//     rule_schema_versions, allowlist tables) — permitted once PS-1A is authorized,
//   - it reads the PS-1B+ EXECUTOR ARTIFACTS / guard scopes,
//   - and it asserts that any artifact whose phase is NOT authorized is ABSENT from
//     supabase/migrations/ AND db/migrations/.
//
// Owner authorization of record: PS-0 and PS-1A are authorized (PS-1A = authoring/
// projection/validation only, no executor). PS-1B+ remain unauthorized, so every
// EXECUTOR artifact must be absent, no studio-executor ledger-guard scope may exist,
// and no migration may mutate a legacy benefit-family's execution authority. The
// moment an engineer lands executor schema without flipping the PS-gate marker for
// its phase, this test fails — the documented tripwire.

import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (rel) => readFile(new URL(rel, root), 'utf8');

async function readMigrationCorpus() {
  const dirs = ['supabase/migrations', 'db/migrations'];
  const files = [];
  for (const dir of dirs) {
    let entries;
    try {
      entries = await readdir(new URL(`${dir}/`, root), { withFileTypes: true });
    } catch {
      continue;
    }
    for (const ent of entries) {
      if (ent.isFile() && ent.name.endsWith('.sql')) {
        files.push(`${dir}/${ent.name}`);
      }
    }
  }
  const corpus = {};
  for (const f of files) corpus[f] = await read(f);
  return corpus;
}

// --- tiny markdown-table parser for the PS-GATES marker ---
function parseGateTable(md, heading) {
  const lines = md.split('\n');
  const start = lines.findIndex((l) => l.trim().toUpperCase().startsWith(`## ${heading.toUpperCase()}`));
  assert.notEqual(start, -1, `PS-GATES.md is missing the '## ${heading}' section`);
  const rows = [];
  let seenHeader = false;
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.startsWith('## ')) break;               // next section
    if (!line.startsWith('|')) continue;
    const cells = line.split('|').slice(1, -1).map((c) => c.trim());
    if (cells.every((c) => /^:?-+:?$/.test(c))) continue; // separator row
    if (!seenHeader) { seenHeader = true; continue; }     // header row
    if (cells.length >= 2) rows.push(cells);
  }
  return rows;
}

test('PS-GATES marker authorizes PS-0/PS-1A/PS-1B/PS-1C/PS-2 (PS-3+ still gated)', async () => {
  const md = await read('docs/design/ps0/PS-GATES.md');
  const phases = Object.fromEntries(
    parseGateTable(md, 'AUTHORIZED PHASES').map(([phase, auth]) => [phase, auth.toLowerCase()]),
  );
  assert.equal(phases['PS-0'], 'yes', 'PS-0 must be authorized');
  assert.equal(phases['PS-1A'], 'yes',
    'PS-1A is authorized for authoring/projection/validation only (no executor)');
  assert.equal(phases['PS-1B'], 'yes',
    'PS-1B is authorized for the event envelope + entitlement PROMISE execution (no customer-value movement)');
  assert.equal(phases['PS-1C'], 'yes',
    'PS-1C is authorized for the unified checkout kernel (server-owned token + synchronous discount apply)');
  assert.equal(phases['PS-2'], 'yes',
    'PS-2 is authorized for the PS-2A stored-value FOUNDATION only (mint + authority; no spend, no cutover, no real value)');
  for (const p of ['PS-3', 'PS-4', 'PS-5']) {
    assert.equal(phases[p], 'no',
      `${p} must remain unauthorized until the owner approves it — flipping this is a deliberate act`);
  }
});

test('captured_messages can never carry a non-synthetic recipient (no real delivery)', async () => {
  const corpus = await readMigrationCorpus();
  const defs = Object.entries(corpus).filter(([, sql]) => /create\s+table\s+(?:if\s+not\s+exists\s+)?(?:public\.)?captured_messages\b/i.test(sql));
  assert.ok(defs.length >= 1, 'captured_messages must be defined once PS-1B lands');
  for (const [file, sql] of defs) {
    // The recipient column CHECK must constrain to synthetic patterns ONLY, so a
    // real address/number is structurally UNINSERTABLE.
    assert.match(sql, /recipient\s+text\s+not\s+null\s+check[\s\S]{0,240}?@example\.test/i,
      `${file}: captured_messages.recipient must be synthetic-only (%@example.test)`);
    assert.match(sql, /\+65990000%/, `${file}: captured_messages must restrict SG numbers to the synthetic range`);
  }
  // No migration may write a captured_messages row with a hard-coded real recipient.
  for (const [file, sql] of Object.entries(corpus)) {
    for (const m of sql.matchAll(/insert\s+into\s+(?:public\.)?captured_messages\b/gi)) {
      const block = sql.slice(m.index, m.index + 1200);
      assert.doesNotMatch(block, /'[^']*@(?:gmail|yahoo|hotmail|outlook|icloud)\.[a-z]+'/i,
        `${file}: a captured_messages insert must never carry a real recipient literal`);
    }
  }
});

test('PS-1A AUTHORING artifacts are permitted and present once PS-1A is authorized', async () => {
  const md = await read('docs/design/ps0/PS-GATES.md');
  const authorized = Object.fromEntries(
    parseGateTable(md, 'AUTHORIZED PHASES').map(([phase, auth]) => [phase, auth.toLowerCase() === 'yes']),
  );
  const authoring = parseGateTable(md, 'AUTHORING ARTIFACTS').map(([artifact, phase]) => ({ artifact, phase }));
  assert.deepEqual(
    authoring.map((a) => a.artifact).sort(),
    ['benefit_registry', 'program_rules', 'program_rules_compiled',
      'rule_condition_allowlist', 'rule_effect_allowlist', 'rule_schema_versions'],
    'the PS-1A authoring artifact set must be exactly these execution-free surfaces',
  );
  for (const { phase } of authoring) assert.equal(phase, 'PS-1A', 'authoring artifacts belong to PS-1A');
  assert.equal(authorized['PS-1A'], true, 'PS-1A must be authorized for the authoring set to land');

  // Permitted AND present: each authoring table exists in the migration corpus. If
  // PS-1A is ever de-authorized, this and the marker must be reverted together.
  const corpus = await readMigrationCorpus();
  for (const { artifact } of authoring) {
    const createRe = new RegExp(`create\\s+table\\s+(if\\s+not\\s+exists\\s+)?(public\\.)?${artifact}\\b`, 'i');
    const present = Object.values(corpus).some((sql) => createRe.test(sql));
    assert.ok(present, `authoring artifact '${artifact}' must be present once PS-1A has landed`);
  }
});

test('no executor TABLE exists in the migration set while its phase is unauthorized', async () => {
  const md = await read('docs/design/ps0/PS-GATES.md');
  const authorized = Object.fromEntries(
    parseGateTable(md, 'AUTHORIZED PHASES').map(([phase, auth]) => [phase, auth.toLowerCase() === 'yes']),
  );
  const artifacts = parseGateTable(md, 'EXECUTOR ARTIFACTS').map(([artifact, phase]) => ({ artifact, phase }));
  assert.ok(artifacts.length >= 10, 'the marker must enumerate the executor artifacts');

  const corpus = await readMigrationCorpus();
  assert.ok(Object.keys(corpus).length > 50, 'expected the real migration corpus to be present');

  for (const { artifact, phase } of artifacts) {
    if (authorized[phase]) continue; // an authorized phase MAY land its schema
    // match `create table [if not exists] [public.]<artifact>` and bare identifier use.
    const createRe = new RegExp(`create\\s+table\\s+(if\\s+not\\s+exists\\s+)?(public\\.)?${artifact}\\b`, 'i');
    const identRe = new RegExp(`\\b${artifact}\\b`, 'i');
    const offenders = [];
    for (const [file, sql] of Object.entries(corpus)) {
      if (createRe.test(sql) || identRe.test(sql)) offenders.push(file);
    }
    assert.deepEqual(offenders, [],
      `executor artifact '${artifact}' (phase ${phase}, unauthorized) must not appear in migrations; ` +
      `to land it, authorize ${phase} in docs/design/ps0/PS-GATES.md`);
  }
});

test('the ledger write-guard carries NO studio-executor scope while unauthorized', async () => {
  const md = await read('docs/design/ps0/PS-GATES.md');
  const authorized = Object.fromEntries(
    parseGateTable(md, 'AUTHORIZED PHASES').map(([phase, auth]) => [phase, auth.toLowerCase() === 'yes']),
  );
  const scopes = parseGateTable(md, 'EXECUTOR LEDGER-GUARD SCOPES').map(([scope, phase]) => ({ scope, phase }));
  assert.ok(scopes.length >= 3, 'the marker must enumerate the guard scopes');

  const corpus = await readMigrationCorpus();
  // only inspect files that actually define the guard, to avoid incidental token hits.
  const guardFiles = Object.entries(corpus).filter(([, sql]) => /loyalty_ledger_write_guard/i.test(sql));
  assert.ok(guardFiles.length >= 1, 'expected the ledger write-guard to be defined in the corpus');

  for (const { scope, phase } of scopes) {
    if (authorized[phase]) continue;
    for (const [file, sql] of guardFiles) {
      // a guard scope literal appears as a quoted string, e.g. v_scope = 'studio_executor'.
      const re = new RegExp(`'${scope}'`, 'i');
      assert.ok(!re.test(sql),
        `guard scope '${scope}' (phase ${phase}, unauthorized) must not appear in ${file}`);
    }
  }
});

test('no not-yet-authorized executor RPC / function surface exists (PS-2 SPEND path stays gated)', async () => {
  const corpus = await readMigrationCorpus();
  // Entry points that only a NOT-yet-authorized increment would introduce. PS-1C is
  // authorized, so public.evaluate_checkout is permitted. PS-2A (v61) is authorized for
  // the stored-value FOUNDATION, so sv_topup + the sv_lot_movements authority now
  // legitimately exist and are NOT forbidden here. The stored-value SPEND/REFUND surface
  // (Increment C, unbuilt) stays forbidden: sv_spend_allocation + refund_sv_operation.
  // There is also no separate 'consume_checkout_evaluation' — the token is finalised
  // through the record_cart_sale overload, never a bespoke consume RPC.
  const forbiddenFns = [
    'consume_checkout_evaluation', 'execute_rule_effect',
    'sv_spend_allocation', 'refund_sv_operation',
    'record_domain_event', 'deliver_outbox',
  ];
  for (const fn of forbiddenFns) {
    const re = new RegExp(`function\\s+(public|app)\\.${fn}\\b`, 'i');
    const offenders = Object.entries(corpus).filter(([, sql]) => re.test(sql)).map(([f]) => f);
    assert.deepEqual(offenders, [], `executor function '${fn}' must not exist while its increment is gated`);
  }
});

test('no migration function can set sv_authority to live or ready_for_cutover (PS-2A: cutover is unreachable)', async () => {
  const corpus = await readMigrationCorpus();
  const svFiles = Object.entries(corpus).filter(([, sql]) => /\bsv_authority\b/i.test(sql));
  assert.ok(svFiles.length >= 1, 'PS-2A must define sv_authority');
  for (const [file, sql] of svFiles) {
    // An UPDATE that sets sv_authority.state to a forbidden state literal.
    assert.doesNotMatch(
      sql,
      /update\s+(?:public\.)?sv_authority\b[\s\S]{0,600}?\bstate\b[\s\S]{0,80}?=\s*'(?:live|ready_for_cutover)'/i,
      `${file}: no UPDATE may set sv_authority.state to live/ready_for_cutover`);
    // A plpgsql assignment of the forbidden states (e.g. new.state := 'live').
    assert.doesNotMatch(
      sql,
      /\bstate\s*:=\s*'(?:live|ready_for_cutover)'/i,
      `${file}: no assignment may set state := live/ready_for_cutover`);
    // An INSERT into sv_authority carrying a forbidden state literal.
    for (const m of sql.matchAll(/insert\s+into\s+(?:public\.)?sv_authority\b/gi)) {
      const block = sql.slice(m.index, m.index + 600);
      assert.doesNotMatch(
        block,
        /'(?:live|ready_for_cutover)'/i,
        `${file}: no INSERT into sv_authority may carry a live/ready_for_cutover literal`);
    }
  }
});

test('no sv_* table carries a mutable balance column (balances are derived from movements)', async () => {
  const corpus = await readMigrationCorpus();
  const seen = [];
  for (const [file, sql] of Object.entries(corpus)) {
    // Slice each `create table [public.]sv_<name> ( ... );` body and forbid a
    // balance / balance_cents column definition. The append-only sv_lot_movements ledger
    // is the sole authority; a cached mutable balance is the anti-pattern this forbids.
    for (const m of sql.matchAll(/create\s+table\s+(?:if\s+not\s+exists\s+)?(?:public\.)?(sv_[a-z_]+)\s*\(/gi)) {
      const bodyStart = m.index + m[0].length;
      const close = sql.indexOf('\n);', bodyStart);
      const body = sql.slice(bodyStart, close === -1 ? bodyStart + 4000 : close);
      seen.push(m[1]);
      assert.doesNotMatch(
        body,
        /(^|,)\s*balance(_cents)?\b/im,
        `${file}: sv table '${m[1]}' must not declare a mutable balance/balance_cents column`);
    }
  }
  assert.ok(seen.includes('sv_lot_movements') && seen.includes('sv_accounts'),
    'the PS-2A foundation tables must be present for the mutable-balance tripwire to be meaningful');
});

test('checkout_discount_lines is written ONLY by the kernel finaliser (record_cart_sale token path)', async () => {
  const corpus = await readMigrationCorpus();
  // PS-1C provenance integrity: every checkout discount line traces to a consumed
  // evaluation token, so the ONLY migration site that INSERTs into
  // checkout_discount_lines must be the kernel finaliser public.record_cart_sale
  // (the arity-9 token overload). Any other inserter — a second RPC, a trigger, a
  // backfill, a browser-reachable path — is a red test.
  const inserters = Object.entries(corpus)
    .filter(([, sql]) => /insert\s+into\s+(?:public\.)?checkout_discount_lines\b/i.test(sql));
  assert.ok(inserters.length >= 1, 'the kernel finaliser must write checkout_discount_lines');
  for (const [file, sql] of inserters) {
    // The finaliser lives in the v58 kernel migration and is CREATE-OR-REPLACE'd (with
    // its checkout_discount_lines insert) by the v59 PS-1C.1 cart-hardening increment.
    // No other migration may write the table.
    assert.match(file, /frenly_v5(8_ps1c_checkout_kernel|9_ps1c1_cart_hardening)/,
      `${file} must not insert into checkout_discount_lines outside the v58/v59 kernel migrations`);
    const finaliserAt = sql.search(/create\s+or\s+replace\s+function\s+public\.record_cart_sale\s*\(/i);
    const evalAt = sql.search(/create\s+or\s+replace\s+function\s+public\.evaluate_checkout\s*\(/i);
    assert.notEqual(finaliserAt, -1, `${file} must define the record_cart_sale finaliser`);
    for (const m of sql.matchAll(/insert\s+into\s+(?:public\.)?checkout_discount_lines\b/gi)) {
      assert.ok(m.index > finaliserAt,
        `${file}: every checkout_discount_lines insert must live inside record_cart_sale, not before it`);
      assert.ok(evalAt === -1 || m.index > evalAt,
        `${file}: evaluate_checkout must never insert checkout_discount_lines (it mints tokens only)`);
    }
  }
});

test('no migration mutates a legacy benefit-family execution authority (PS-1A metadata-only)', async () => {
  const corpus = await readMigrationCorpus();
  // benefit_registry is metadata-only in PS-1A: seeded once, then append-only.
  // Execution-authority transitions (legacy_trigger -> studio_executor) are future
  // PS-1B+ cutover migrations, not PS-1A. Any UPDATE of the authority column is the
  // tripwire for an out-of-phase cutover.
  for (const [file, sql] of Object.entries(corpus)) {
    assert.doesNotMatch(
      sql,
      /update\s+(public\.)?benefit_registry\s+set[\s\S]{0,240}?execution_authority/i,
      `${file}: benefit_registry.execution_authority must not be mutated while PS-1A is the highest authorized phase`,
    );
  }
});
