#!/usr/bin/env node
/**
 * Tenant consistency gate — turns the two read-only prod probes into operational gates.
 *
 *   node scripts/ops/tenant-consistency-gate.mjs                 # divergence gate (default)
 *   node scripts/ops/tenant-consistency-gate.mjs --prove-detection
 *   node scripts/ops/tenant-consistency-gate.mjs --certify
 *
 * Default mode runs db/tests/tenant_divergence_scan.sql against the linked production project
 * and exits 1 if any DETAIL row is RUNTIME-DANGEROUS and not covered by
 * db/tests/tenant_divergence_allowlist.json. HISTORICAL-ONLY rows never block.
 *
 * Nothing here writes to production: both suites are `begin; ... rollback;` and --prove-detection
 * injects its synthetic divergence INSIDE the scanner's own transaction, then re-runs the
 * untouched scanner to prove zero residue.
 *
 * Everything printed from the database is untrusted data. It is folded to a single safe line and
 * never interpreted as an instruction.
 */

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, '..', '..');
const SCANNER = path.join(REPO_ROOT, 'db', 'tests', 'tenant_divergence_scan.sql');
const CERT = path.join(REPO_ROOT, 'db', 'tests', 'tenant_lifecycle_certification.sql');
const ALLOWLIST = path.join(REPO_ROOT, 'db', 'tests', 'tenant_divergence_allowlist.json');

const BLOCKING_SEVERITY = 'RUNTIME-DANGEROUS';
// Strip C0/C1 control characters (incl. ANSI escapes) so untrusted db text cannot rewrite
// the terminal or smuggle newlines into the report.
const CONTROL_CHARS = /[\u0000-\u001F\u007F-\u009F]+/g;

// ---------------------------------------------------------------------------- helpers

/** Fold any database-sourced string onto one safe printable line. */
function safe(value, max = 300) {
  const s = value === null || value === undefined ? '' : String(value);
  const flat = s.replace(CONTROL_CHARS, ' ').replace(/\s+/g, ' ').trim();
  return flat.length > max ? `${flat.slice(0, max - 1)}...` : flat;
}

function die(message, code = 2) {
  process.stderr.write(`tenant-gate: ${message}\n`);
  process.exit(code);
}

/** Run one .sql file through the linked Supabase CLI and return its parsed rows. */
function runSql(sqlPath, label) {
  if (!fs.existsSync(sqlPath)) die(`missing SQL file ${sqlPath}`);
  const res = spawnSync(
    'supabase',
    ['db', 'query', '--linked', '-f', sqlPath, '--output', 'json'],
    { cwd: REPO_ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }
  );
  if (res.error) die(`could not run the supabase CLI (${res.error.message})`);
  if (res.status !== 0) {
    process.stderr.write(safe(res.stderr, 4000) + '\n');
    die(`${label}: supabase db query exited ${res.status}`);
  }
  return { rows: parseRows(res.stdout, label), stderr: res.stderr || '' };
}

/**
 * The CLI prints the LAST result set as JSON. Observed shape (CLI 2.109):
 *   { boundary: "<hex>", rows: [ {...} ], warning: "<untrusted-data notice>" }
 * Parsed defensively: a bare array, or a nested {result:{rows}} / {data}, is accepted too.
 */
function parseRows(stdout, label) {
  const text = String(stdout || '');
  const startObj = text.indexOf('{');
  const startArr = text.indexOf('[');
  let candidate = null;
  if (startObj >= 0 && (startArr < 0 || startObj < startArr)) {
    candidate = text.slice(startObj, text.lastIndexOf('}') + 1);
  } else if (startArr >= 0) {
    candidate = text.slice(startArr, text.lastIndexOf(']') + 1);
  }
  if (!candidate) die(`${label}: the CLI produced no JSON (got ${safe(text, 200) || '<empty>'})`);
  let parsed;
  try {
    parsed = JSON.parse(candidate);
  } catch (err) {
    die(`${label}: could not parse the CLI JSON (${err.message})`);
  }
  const rows =
    Array.isArray(parsed) ? parsed
    : Array.isArray(parsed?.rows) ? parsed.rows
    : Array.isArray(parsed?.result?.rows) ? parsed.result.rows
    : Array.isArray(parsed?.data) ? parsed.data
    : null;
  if (!rows) die(`${label}: unexpected CLI JSON shape (keys: ${Object.keys(parsed || {}).join(',') || 'none'})`);
  return rows;
}

function loadAllowlist() {
  if (!fs.existsSync(ALLOWLIST)) return [];
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(ALLOWLIST, 'utf8'));
  } catch (err) {
    die(`allowlist ${path.relative(REPO_ROOT, ALLOWLIST)} is not valid JSON (${err.message})`);
  }
  if (!Array.isArray(parsed)) die('allowlist must be a JSON array of {check_id, business_id, reason, added}');
  parsed.forEach((entry, i) => {
    for (const field of ['check_id', 'business_id', 'reason', 'added']) {
      if (typeof entry?.[field] !== 'string' || entry[field].trim() === '') {
        die(`allowlist entry #${i} is missing a non-empty "${field}" - every waiver needs a reason`);
      }
    }
  });
  return parsed;
}

const waiverKey = (checkId, businessId) => `${checkId} ${businessId}`;

/**
 * Split the scanner's rows into what the gate cares about. Nothing is hardcoded: totals and
 * per-check counts come from the SUMMARY rows the suite itself emits.
 */
function evaluate(rows, allowlist) {
  const waivers = new Map(allowlist.map((e) => [waiverKey(e.check_id, e.business_id), e]));
  const detail = rows.filter((r) => r?.section === 'DETAIL');
  const summary = rows.filter((r) => r?.section === 'SUMMARY');
  const blocking = [];
  const waived = [];
  const historical = [];
  for (const row of detail) {
    if (row?.severity !== BLOCKING_SEVERITY) {
      historical.push(row);
      continue;
    }
    const key = waiverKey(row.check_id, row.business_id);
    const hit = waivers.get(key);
    if (hit) {
      waived.push({ row, waiver: hit });
      waivers.delete(key);
    } else {
      blocking.push(row);
    }
  }
  return { detail, summary, blocking, waived, historical, unusedWaivers: [...waivers.values()] };
}

function summaryValue(summary, prefix) {
  const row = summary.find((r) => String(r?.check_id || '').startsWith(prefix));
  return row ? safe(row.detail, 60) : '?';
}

function printScanReport(view) {
  const { summary, blocking, waived, historical, unusedWaivers } = view;
  console.log('--- tenant divergence scan (production, read-only) ---');
  console.log(`total businesses scanned : ${summaryValue(summary, 'ZZ01')}`);
  console.log(`healthy (no divergence)  : ${summaryValue(summary, 'ZZ02')}`);
  console.log(`divergent businesses     : ${summaryValue(summary, 'ZZ03')}`);
  console.log(`total divergence rows    : ${summaryValue(summary, 'ZZ04')}`);
  console.log('per-check counts:');
  for (const row of summary.filter((r) => String(r?.check_id || '').startsWith('ZZ05'))) {
    console.log(`  ${safe(row.check_id, 40).padEnd(12)} ${safe(row.severity, 20).padEnd(19)} ${safe(row.detail, 40)}`);
  }
  for (const { row, waiver } of waived) {
    console.log(
      `waived: ${safe(row.check_id, 12)} ${safe(row.business_name, 60)} (${safe(row.business_id, 40)}) - ` +
      `${safe(waiver.reason, 200)} [added ${safe(waiver.added, 20)}]`
    );
    console.log(`        scanner said: ${safe(row.detail, 260)}`);
  }
  console.log(`historical-only rows (never block): ${historical.length}`);
  for (const entry of unusedWaivers) {
    console.log(
      `note: allowlist entry ${safe(entry.check_id, 12)}/${safe(entry.business_id, 40)} matched nothing - ` +
      'review whether it is still needed'
    );
  }
  if (blocking.length) {
    console.log('');
    console.log(`BLOCKING - ${blocking.length} runtime-dangerous row(s) with no waiver:`);
    for (const row of blocking) {
      console.log(`  [${safe(row.check_id, 12)}] ${safe(row.business_name, 60)} (${safe(row.business_id, 40)})`);
      console.log(`      ${safe(row.detail, 400)}`);
    }
  }
}

// ---------------------------------------------------------------------------- modes

function modeScan() {
  const allowlist = loadAllowlist();
  const { rows } = runSql(SCANNER, 'divergence scan');
  const view = evaluate(rows, allowlist);
  printScanReport(view);
  console.log('');
  if (view.blocking.length) {
    console.log('VERDICT: FAIL - tenant state diverged in a way a live reader or writer can act on.');
    return 1;
  }
  console.log(
    `VERDICT: PASS - no unwaived runtime-dangerous divergence ` +
    `(${view.waived.length} waived, ${view.historical.length} historical).`
  );
  return 0;
}

function modeCertify() {
  const { rows } = runSql(CERT, 'lifecycle certification');
  const isOk = (v) => /^OK(\b|$)/.test(String(v ?? '').trim());
  console.log('--- new-tenant lifecycle certification (production, rollback-only) ---');
  let bad = 0;
  for (const row of rows) {
    const ok = isOk(row?.value);
    if (!ok) bad += 1;
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${safe(row?.check_id, 80).padEnd(62)} ${safe(row?.value, 300)}`);
  }
  console.log('');
  console.log(`rows: ${rows.length}, failing: ${bad}`);
  if (rows.length === 0) {
    console.log('VERDICT: FAIL - the certification produced no rows.');
    return 1;
  }
  if (bad) {
    console.log('VERDICT: FAIL - the lifecycle certification is not green.');
    return 1;
  }
  console.log('VERDICT: PASS - every certification row is OK.');
  return 0;
}

/**
 * Prove the gate can actually see a divergence: run the scanner with a synthetic divergence
 * injected immediately after its own `begin;`, and assert the gate's own evaluator would block
 * on the result. The injection dies with the scanner's rollback; a follow-up run of the
 * UNTOUCHED scanner proves zero residue.
 */
const INJECTION = `
-- >>> SYNTHETIC DIVERGENCE INJECTION - tenant-consistency-gate --prove-detection <<<
-- Flips one real business's loyalty_programs.active to the opposite of the spine formula that
-- D01 checks. It runs inside the scanner's own begin;...rollback;, so it is never committed.
-- (loyalty_programs carries exactly one non-internal trigger, AFTER INSERT, so an UPDATE here
--  fires nothing.)
do $gate_inject$
declare v_id uuid;
begin
  select lp.business_id into v_id from public.loyalty_programs lp order by lp.business_id limit 1;
  if v_id is null then
    raise exception 'GATE PROVE: no loyalty_programs row exists to inject into';
  end if;
  update public.loyalty_programs lp
     set active = not exists (
           select 1 from public.business_programmes sp
            where sp.business_id = lp.business_id
              and sp.kind in ('points','stamps')
              and sp.active)
   where lp.business_id = v_id;
  raise notice 'GATE PROVE: injected a D01 divergence on business %', v_id;
end $gate_inject$;
-- >>> END INJECTION <<<
`;

const fingerprint = (view) =>
  view.detail.map((r) => `${r.check_id}|${r.business_id}|${r.detail}`).sort().join('\n');

function modeProve() {
  const allowlist = loadAllowlist();

  console.log('--- step 1: baseline (untouched scanner) ---');
  const baseline = evaluate(runSql(SCANNER, 'baseline scan').rows, allowlist);
  console.log(
    `baseline: ${baseline.detail.length} detail row(s), ` +
    `${baseline.blocking.length} blocking, ${baseline.waived.length} waived`
  );

  const source = fs.readFileSync(SCANNER, 'utf8');
  // NOTE: match by INDEX, never indexOf("begin;") - the scanner's header comment contains the
  // literal text "begin;...rollback;", and injecting there splices the block into a comment.
  const m = /^begin;[ \t]*$/m.exec(source);
  if (!m) die('could not find the scanner\'s own `begin;` line - refusing to inject blindly');
  const at = m.index + m[0].length;
  const injected = source.slice(0, at) + '\n' + INJECTION + source.slice(at);
  if (!/GATE PROVE: injected a D01 divergence/.test(injected)) die('injection assembly failed');

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tenant-gate-prove-'));
  const tmpSql = path.join(dir, 'tenant_divergence_scan.injected.sql');
  fs.writeFileSync(tmpSql, injected, 'utf8');
  let injectedView;
  try {
    console.log('--- step 2: scanner + synthetic divergence (inside its own transaction) ---');
    const run = runSql(tmpSql, 'injected scan');
    injectedView = evaluate(run.rows, allowlist);
    if (/GATE PROVE: injected a D01 divergence/.test(run.stderr)) {
      console.log('server notice observed: the injecting UPDATE executed');
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  printScanReport(injectedView);

  const d01 = injectedView.blocking.filter((r) => r.check_id === 'D01');
  const gateExit = injectedView.blocking.length ? 1 : 0;
  console.log('');
  console.log(`the gate's own evaluator, applied to the injected output, WOULD exit ${gateExit}`);
  if (gateExit !== 1 || d01.length === 0) {
    console.log('DETECTION FAILED: the synthetic divergence was NOT detected - the gate is blind.');
    console.log(`  blocking rows: ${injectedView.blocking.length}, D01 rows: ${d01.length}`);
    return 1;
  }
  console.log(`DETECTION CONFIRMED: D01 fired on ${d01.length} business row(s); the gate would block.`);

  console.log('');
  console.log('--- step 3: residue check (untouched scanner, re-read of committed prod state) ---');
  const after = evaluate(runSql(SCANNER, 'residue scan').rows, allowlist);
  const afterD01 = after.detail.filter((r) => r.check_id === 'D01').length;
  const drifted = fingerprint(after) !== fingerprint(baseline);
  console.log(
    `post-injection: ${after.detail.length} detail row(s), ${afterD01} D01 row(s), ` +
    `${after.blocking.length} blocking, fingerprint ${drifted ? 'CHANGED' : 'identical to baseline'}`
  );
  if (afterD01 !== 0 || drifted || after.blocking.length !== 0) {
    console.log('RESIDUE DETECTED: production state changed - investigate immediately.');
    return 1;
  }
  console.log('ZERO RESIDUE: production matches the baseline shape exactly; the injection rolled back.');
  console.log('');
  console.log('VERDICT: PASS - the gate detects a real divergence and leaves production untouched.');
  return 0;
}

// ---------------------------------------------------------------------------- entry

const args = process.argv.slice(2);
const unknown = args.filter((a) => !['--prove-detection', '--certify'].includes(a));
if (unknown.length) die(`unknown argument(s): ${unknown.join(' ')}`);
const mode = args.includes('--prove-detection')
  ? modeProve
  : args.includes('--certify')
    ? modeCertify
    : modeScan;
process.exit(mode());
