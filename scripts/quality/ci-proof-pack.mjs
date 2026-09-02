#!/usr/bin/env node
/* CI-100 proof-pack generator — docs/qa/CI-100-CHECKLIST.md, required-proof-pack items 4/5/7/14.
 *
 * WHY THIS EXISTS. docs/qa/CI-PROOF-EVIDENCE-MAP-2026-09-02.md audited all 100 checks and named
 * four required proof-pack artifacts that did not exist yet:
 *   4  Synthetic corpus manifest      -> docs/qa/proof-pack/CI-CORPUS-MANIFEST.{md,json}
 *   5  Expected-answer file           -> docs/qa/proof-pack/CI-EXPECTED-ANSWERS.md
 *   7  Reconciliation report          -> docs/qa/proof-pack/CI-RECONCILIATION-REPORT.md
 *   14 Known-limitations register     -> docs/qa/proof-pack/CI-KNOWN-LIMITATIONS.md
 * Every one of them is GENERATED from the repository (or, for #7, from a real harness run) by
 * this single script rather than hand-authored, so it cannot drift out of sync with the fixtures,
 * migrations and validator it describes. tests/phase0-foundation/ci-proof-pack.test.mjs
 * regenerates all four to a temp directory and asserts byte-identity with the committed copies.
 *
 * SUBCOMMANDS
 *   corpus-manifest      writes CI-CORPUS-MANIFEST.md + .json (item 4)
 *   expected-answers     writes CI-EXPECTED-ANSWERS.md (item 5)
 *   known-limitations    writes CI-KNOWN-LIMITATIONS.md (item 14)
 *   reconciliation       RUNS db/tests/executed/v731_reconciliation_report.sql via
 *                        scripts/db-tests/lib.mjs's own primitives (same baseline snapshot +
 *                        pending-migration replay scripts/db-tests/run.mjs uses) and writes
 *                        CI-RECONCILIATION-REPORT.md from psql's OWN captured stdout/stderr —
 *                        see the "CAPTURE FIX" note on runReconciliation() below for why the
 *                        previous approach (scraping run.mjs's own console output) read empty
 *                        even on a clean pass (item 7).
 *   all                  runs all four, in the order above
 *
 * FLAGS
 *   --out-dir=<dir>   output directory, default docs/qa/proof-pack (relative to repo root)
 *   --repo-root=<dir> repo root to read/generate from, default the real repo root (this file's
 *                     own ../.. ) — overridable so the test suite can point this at an isolated
 *                     temp copy of the tree without touching the committed artefacts.
 *
 * Every artefact is deterministic given the same repository state EXCEPT `reconciliation`, which
 * embeds the harness's own timing and a fresh business per run (app.seed_golden_business_v682 is
 * itself deterministic per (index, sector), but wall-clock timing and generated UUIDs are not) —
 * that one is explicitly excluded from the byte-identity re-generation test; see its own test for
 * the weaker property it actually proves (the harness runs clean and every reconciliation line is
 * present in the freshly captured output, and — since nestly_v734/v737/v740/v742 closed the
 * estate-wide synthetic-client exclusion gap v731 was written to expose — every ratio now reads
 * exactly 100.0; there is no longer a "known B/C/D gap" to pin).
 */
import { createHash } from 'node:crypto';
import { readdirSync, readFileSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DEFAULT_REPO_ROOT = fileURLToPath(new URL('../..', import.meta.url));

// LAZY, not a static top-level import: scripts/db-tests/lib.mjs is needed only by the
// `reconciliation`/`isolation` subcommands (and the harness watermark line in `frozen`) — a
// STATIC import here would make `../db-tests/lib.mjs` resolvable a hard requirement for EVERY
// subcommand, including `corpus-manifest`/`expected-answers`/`known-limitations`, which the test
// suite's own isolatedProofPackRepo() runs against a temp copy that deliberately does NOT include
// scripts/db-tests/ (those subcommands never touch it in the real repo either). A static import
// broke all three with `ERR_MODULE_NOT_FOUND` the first time this file started using lib.mjs at
// all; dynamic import(), called only from the functions that actually need it, keeps the
// unrelated subcommands working against an isolated tree exactly as before.
let dbTestsLibPromise = null;
function loadDbTestsLib() {
  if (!dbTestsLibPromise) dbTestsLibPromise = import('../db-tests/lib.mjs');
  return dbTestsLibPromise;
}

function parseArgs(argv) {
  const out = { subcommand: null, outDir: null, repoRoot: null };
  for (const arg of argv) {
    if (arg.startsWith('--out-dir=')) out.outDir = arg.slice('--out-dir='.length);
    else if (arg.startsWith('--repo-root=')) out.repoRoot = arg.slice('--repo-root='.length);
    else if (!out.subcommand) out.subcommand = arg;
    else throw new Error(`ci-proof-pack: unrecognised argument ${arg}`);
  }
  return out;
}

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

/* ------------------------------------------------------------ item 4: corpus manifest -------- */

// Every executed corpus/acceptance fixture in scope for the CI-100 proof pack: the
// db/tests/executed/v6[6-9]*_corpus*.sql and v7*_corpus*.sql families the task names by pattern,
// plus the five named-but-not-"corpus"-suffixed files the task calls out explicitly by version.
const EXPLICIT_FIXTURES = new Set([
  'v667_ci_access_boundaries.sql',
  'v106_corpus_revenue_truth.sql',
  'v629_corpus_acquisition_demographics.sql',
  'v651_corpus_cadence.sql',
  'v652_corpus_statistics.sql',
]);

function isInScopeFixture(filename) {
  if (EXPLICIT_FIXTURES.has(filename)) return true;
  const m = filename.match(/^v(\d+)_.*corpus.*\.sql$/i);
  if (!m) return false;
  const n = Number(m[1]);
  return (n >= 660 && n <= 699) || n >= 700;
}

function listCorpusFixtures(repoRoot) {
  const dir = path.join(repoRoot, 'db/tests/executed');
  return readdirSync(dir)
    .filter((f) => f.endsWith('.sql') && isInScopeFixture(f))
    .sort();
}

// Migration paths the fixture's own header/body names, e.g. "db/migrations/2026...sql".
function extractMigrationRefs(text) {
  const re = /db\/migrations\/[A-Za-z0-9_.\-]+\.sql/g;
  return [...new Set(text.match(re) || [])].sort();
}

// "check 5", "checks 21-30", "checklist item 10", "checklist items 35 ... 36 ... 60" -> the set
// of individual check numbers named anywhere in the file (1-100 only; the harness/version numbers
// in this codebase run past 700 and must not be swept in by a bare \d+ match).
function extractCheckNumbers(text) {
  const nums = new Set();
  const re = /check(?:list\s+item)?s?\s+((?:\d{1,3}(?:\s*[-–]\s*\d{1,3})?)(?:\s*(?:,|and|&|\/)\s*\d{1,3}(?:\s*[-–]\s*\d{1,3})?)*)/gi;
  let m;
  while ((m = re.exec(text)) !== null) {
    const chunk = m[1];
    for (const piece of chunk.split(/,|and|&|\//i)) {
      const range = piece.trim().match(/^(\d{1,3})\s*[-–]\s*(\d{1,3})$/);
      if (range) {
        const [lo, hi] = [Number(range[1]), Number(range[2])];
        if (lo >= 1 && hi <= 100 && lo <= hi && hi - lo < 100) {
          for (let n = lo; n <= hi; n++) nums.add(n);
        }
        continue;
      }
      const single = piece.trim().match(/^(\d{1,3})$/);
      if (single) {
        const n = Number(single[1]);
        if (n >= 1 && n <= 100) nums.add(n);
      }
    }
  }
  return [...nums].sort((a, b) => a - b);
}

function countOccurrences(text, re) {
  const m = text.match(re);
  return m ? m.length : 0;
}

function buildCorpusManifest(repoRoot) {
  const files = listCorpusFixtures(repoRoot);
  const items = files.map((filename) => {
    const relPath = path.posix.join('db/tests/executed', filename);
    const bytes = readFileSync(path.join(repoRoot, relPath));
    const text = bytes.toString('utf8');
    const stem = filename.replace(/\.sql$/, '');
    return {
      file: relPath,
      migrations: extractMigrationRefs(text),
      checks: extractCheckNumbers(text),
      businesses_seeded: countOccurrences(text, /insert\s+into\s+public\.businesses\b/gi),
      clients_seeded: countOccurrences(text, /insert\s+into\s+public\.clients\b/gi),
      sha256: sha256(bytes),
      harness_command: `LC_ALL=C node scripts/db-tests/run.mjs --filter=${stem} --migrated-only`,
    };
  });
  return { schemaVersion: 1, generatedBy: 'scripts/quality/ci-proof-pack.mjs corpus-manifest', itemCount: items.length, items };
}

function renderCorpusManifestMarkdown(manifest) {
  const lines = [];
  lines.push('# CI-100 proof-pack item 4 — synthetic corpus manifest');
  lines.push('');
  lines.push('> GENERATED by `scripts/quality/ci-proof-pack.mjs corpus-manifest`. Do not hand-edit —');
  lines.push('> regenerate. `tests/phase0-foundation/ci-proof-pack.test.mjs` asserts this file is');
  lines.push('> byte-identical to a fresh regeneration of the committed tree.');
  lines.push('');
  lines.push('Every `db/tests/executed/v6[6-9]*_corpus*.sql` / `v7*_corpus*.sql` fixture, plus the');
  lines.push('v667/v106/v629/v651/v652 fixtures named explicitly by the task even though their own');
  lines.push('filenames do not carry the literal string `corpus`. For each: the migration(s) its own');
  lines.push('header/body names, the checklist check numbers it cites (`check NN` / `checks NN-MM`),');
  lines.push('a count of `insert into public.businesses` / `public.clients` statements (the corpus');
  lines.push('population it seeds directly — some fixtures seed through an RPC instead and show 0/0');
  lines.push('here by design; see the fixture itself), the raw-byte SHA-256 of the file, and the exact');
  lines.push('harness command that runs it.');
  lines.push('');
  lines.push(`Fixture count: **${manifest.itemCount}**.`);
  lines.push('');
  lines.push('| File | Migration(s) proved | Checks cited | Businesses seeded (literal INSERT) | Clients seeded (literal INSERT) | SHA-256 | Harness command |');
  lines.push('|---|---|---:|---:|---:|---|---|');
  for (const it of manifest.items) {
    const migCell = it.migrations.length
      ? it.migrations.map((m) => `\`${m}\``).join('<br>')
      : '_(none named by path in this file — see checks/domain notes in the file\'s own header)_';
    const checksCell = it.checks.length ? it.checks.join(', ') : '_(none)_';
    lines.push(`| \`${it.file}\` | ${migCell} | ${checksCell} | ${it.businesses_seeded} | ${it.clients_seeded} | \`${it.sha256}\` | \`${it.harness_command}\` |`);
  }
  lines.push('');
  lines.push('## Notes');
  lines.push('');
  lines.push('* "Businesses seeded" / "clients seeded" counts literal `insert into public.businesses`');
  lines.push('  / `public.clients` statements textually present in the fixture file. A fixture that');
  lines.push('  seeds its population through an RPC (e.g. `app.seed_golden_business_v682`, called in a');
  lines.push('  loop) shows 0 here even though it provisions many businesses at run time — that is a');
  lines.push('  property of grepping the SQL text, not of the fixture\'s actual population; the fixture');
  lines.push('  itself is the source of truth for its own seeded count (see its own header/truth table).');
  lines.push('* "Checks cited" is extracted by regex over the fixture\'s own comments and code — a');
  lines.push('  fixture that proves a check without ever writing the literal words "check NN" shows no');
  lines.push('  entry here; cross-reference `docs/qa/CI-PROOF-EVIDENCE-MAP-2026-09-02.md` for the');
  lines.push('  checklist\'s own authoritative check-to-artefact mapping, which this manifest does not');
  lines.push('  attempt to replace.');
  lines.push('');
  return lines.join('\n') + '\n';
}

function runCorpusManifest(repoRoot, outDir) {
  const manifest = buildCorpusManifest(repoRoot);
  const jsonPath = path.join(outDir, 'CI-CORPUS-MANIFEST.json');
  const mdPath = path.join(outDir, 'CI-CORPUS-MANIFEST.md');
  writeFileSync(jsonPath, JSON.stringify(manifest, null, 2) + '\n');
  writeFileSync(mdPath, renderCorpusManifestMarkdown(manifest));
  return { jsonPath, mdPath, manifest };
}

/* ------------------------------------------------------------ item 5: expected answers -------- */

function extractTruthTable(text) {
  const lines = text.split('\n');
  const markerIdx = lines.findIndex((l) => /truth table/i.test(l));
  if (markerIdx === -1) return null;
  let endIdx = lines.length;
  for (let i = markerIdx + 1; i < lines.length; i++) {
    if (/^\s*\\set\b/i.test(lines[i]) || /^\s*begin;\s*$/i.test(lines[i])) {
      endIdx = i;
      break;
    }
  }
  return lines.slice(markerIdx + 1, endIdx).join('\n').replace(/\n+$/, '');
}

function buildExpectedAnswers(repoRoot) {
  const files = listCorpusFixtures(repoRoot);
  const entries = files.map((filename) => {
    const relPath = path.posix.join('db/tests/executed', filename);
    const text = readFileSync(path.join(repoRoot, relPath), 'utf8');
    const truthTable = extractTruthTable(text);
    return { file: relPath, truthTable };
  });
  return entries;
}

function renderExpectedAnswersMarkdown(entries) {
  const lines = [];
  lines.push('# CI-100 proof-pack item 5 — expected-answer file');
  lines.push('');
  lines.push('> GENERATED by `scripts/quality/ci-proof-pack.mjs expected-answers`. Do not hand-edit —');
  lines.push('> regenerate. `tests/phase0-foundation/ci-proof-pack.test.mjs` asserts this file is');
  lines.push('> byte-identical to a fresh regeneration of the committed tree.');
  lines.push('');
  lines.push('Per fixture: the predetermined truth table extracted VERBATIM from its own header comment');
  lines.push('block — every line between the first `truth table` / `TRUTH TABLE` marker and the first');
  lines.push('`\\set` or `begin;` that follows it. Nothing here is retyped or summarised; each block is');
  lines.push('a literal slice of the committed fixture file, so the expected answers a reviewer checks');
  lines.push('against live in exactly one place (the fixture itself) and this document, not two places');
  lines.push('that can drift apart.');
  lines.push('');
  const missing = entries.filter((e) => e.truthTable === null);
  const present = entries.filter((e) => e.truthTable !== null);
  lines.push(`Fixtures with an extracted truth table: **${present.length}**. Flagged (no truth-table`);
  lines.push(`marker found): **${missing.length}**.`);
  lines.push('');
  if (missing.length) {
    lines.push('## Flagged — no truth-table marker found');
    lines.push('');
    lines.push('These fixtures contain no line matching `/truth table/i`, so no verbatim block could be');
    lines.push('extracted. This does not necessarily mean the fixture lacks predetermined expected');
    lines.push('values — some state them inline without that exact heading — only that this generator\'s');
    lines.push('extraction rule found nothing to lift. Read the fixture directly for its own expected');
    lines.push('values.');
    lines.push('');
    for (const e of missing) lines.push(`* \`${e.file}\``);
    lines.push('');
  }
  lines.push('## Truth tables, verbatim');
  lines.push('');
  for (const e of present) {
    lines.push(`### \`${e.file}\``);
    lines.push('');
    lines.push('```');
    lines.push(e.truthTable);
    lines.push('```');
    lines.push('');
  }
  return lines.join('\n') + '\n';
}

function runExpectedAnswers(repoRoot, outDir) {
  const entries = buildExpectedAnswers(repoRoot);
  const mdPath = path.join(outDir, 'CI-EXPECTED-ANSWERS.md');
  writeFileSync(mdPath, renderExpectedAnswersMarkdown(entries));
  return { mdPath, entries };
}

/* ------------------------------------------------------------ item 14: known limitations ------ */

// Pull the full comment paragraph around each line matching /HONEST LIMIT|declared limit/i out of
// validate.mjs: walk backward/forward while the line (trimmed) starts with `//`, so the whole
// contiguous prose block is captured, not just the one matching line.
function extractValidatorLimits(text) {
  const lines = text.split('\n');
  const isCommentLine = (l) => /^\s*\/\//.test(l);
  const hits = [];
  // Word-boundary singular match: "HONEST LIMIT," / "declared limit —" are the file's own literal
  // tag conventions. \bLIMIT\b deliberately excludes the plural "honest limits are written down"
  // meta-sentence in the file's header (line ~38) — that sentence explains the convention, it is
  // not itself one of the per-heuristic declarations, and matching it would pull the whole
  // contiguous file-header comment block in as a spurious "limit".
  for (let i = 0; i < lines.length; i++) {
    if (/\bhonest limit\b|\bdeclared limit\b/i.test(lines[i])) hits.push(i);
  }
  const blocks = [];
  const claimed = new Set();
  for (const hitLine of hits) {
    if (claimed.has(hitLine)) continue;
    let start = hitLine;
    while (start > 0 && isCommentLine(lines[start - 1])) start--;
    let end = hitLine;
    while (end < lines.length - 1 && isCommentLine(lines[end + 1])) end++;
    for (let i = start; i <= end; i++) claimed.add(i);
    const blockText = lines.slice(start, end + 1).join('\n');
    const checkMatch = blockText.match(/checks?\s+(\d{1,3})/i);
    blocks.push({ startLine: start + 1, endLine: end + 1, text: blockText, check: checkMatch ? Number(checkMatch[1]) : null });
  }
  return blocks;
}

// The lifecycle legend table near the top of the ledger has its own "| `BLOCKED` | A named
// external input... |" row — a definition of the STATE, not an issue. Its first cell is exactly
// one of the lifecycle keywords, never a real issue ID (which always looks like `SOME-NAME-001`).
// Excluding rows whose ID *is* a lifecycle keyword keeps that legend row out of the extraction.
const LEDGER_LIFECYCLE_STATES = new Set([
  'CAPTURED', 'REPRODUCED', 'IMPLEMENTED_UNVERIFIED', 'VERIFIED_LOCAL', 'VERIFIED_BROWSER',
  'VERIFIED_DATABASE', 'VERIFIED_PRODUCTION', 'DEFERRED_OWNER', 'BLOCKED', 'SUPERSEDED', 'CLOSED',
]);

function extractLedgerBlocked(repoRoot) {
  const ledgerPath = path.join(repoRoot, 'docs/qa/OWNER-ISSUE-LEDGER.md');
  const text = readFileSync(ledgerPath, 'utf8');
  const rows = [];
  for (const line of text.split('\n')) {
    if (!line.startsWith('| `')) continue;
    if (!/\|\s*`BLOCKED`\s*\|/.test(line)) continue;
    const idMatch = line.match(/^\|\s*`([^`]+)`\s*\|/);
    if (!idMatch) continue;
    if (LEDGER_LIFECYCLE_STATES.has(idMatch[1])) continue; // the legend table's own state row
    const checkMatch = line.match(/checks?\s+(\d{1,3})/i);
    const snippet = line.replace(/^\|\s*`[^`]+`\s*\|/, '').slice(0, 400).trim();
    rows.push({ id: idMatch[1], check: checkMatch ? Number(checkMatch[1]) : null, snippet: snippet + '…' });
  }
  return rows;
}

function buildKnownLimitations(repoRoot) {
  const validatorPath = path.join(repoRoot, 'supabase/functions/ai-firm-reports/validate.mjs');
  const validatorText = readFileSync(validatorPath, 'utf8');
  const validatorLimits = extractValidatorLimits(validatorText);
  const ledgerBlocked = extractLedgerBlocked(repoRoot);
  const manualPath = path.join(repoRoot, 'scripts/quality/ci-proof-pack.known-limitations.json');
  const manual = JSON.parse(readFileSync(manualPath, 'utf8'));
  return { validatorLimits, ledgerBlocked, manual: manual.items };
}

function renderKnownLimitationsMarkdown({ validatorLimits, ledgerBlocked, manual }) {
  const lines = [];
  lines.push('# CI-100 proof-pack item 14 — known-limitations register');
  lines.push('');
  lines.push('> GENERATED by `scripts/quality/ci-proof-pack.mjs known-limitations`. The validator and');
  lines.push('> ledger sections are extracted automatically; do not hand-edit them — regenerate. The');
  lines.push('> manual section is authored by hand in');
  lines.push('> `scripts/quality/ci-proof-pack.known-limitations.json` (edit that file, then');
  lines.push('> regenerate this one). `tests/phase0-foundation/ci-proof-pack.test.mjs` asserts this');
  lines.push('> file is byte-identical to a fresh regeneration of the committed tree.');
  lines.push('');
  lines.push('Compiled from three sources, per `docs/qa/CI-100-CHECKLIST.md` required proof-pack item 14:');
  lines.push('');
  lines.push('1. `supabase/functions/ai-firm-reports/validate.mjs`\'s own `HONEST LIMIT` / `declared`');
  lines.push('   `limit` comment blocks — the validator\'s stated convention of writing each heuristic\'s');
  lines.push('   honest limits down next to it.');
  lines.push('2. `docs/qa/OWNER-ISSUE-LEDGER.md` rows whose lifecycle state is `BLOCKED`.');
  lines.push('3. A hand-maintained register');
  lines.push('   (`scripts/quality/ci-proof-pack.known-limitations.json`) for items with no code');
  lines.push('   anchor a generator could extract on its own.');
  lines.push('');
  lines.push('Each entry below carries: check number(s) (where named), whether it is one of the');
  lines.push('checklist\'s own hard-gate categories (tenant leakage, fabricated data, unsupported');
  lines.push('causality, misleading coverage, small-sample overconfidence, incorrect financial truth —');
  lines.push('"Even at 99/100, the claim is not permitted if..."), status and owner.');
  lines.push('');
  lines.push(`Per this generation: **${validatorLimits.length}** validator-declared limits, `);
  lines.push(`**${ledgerBlocked.length}** BLOCKED ledger rows, **${manual.length}** manually-registered`);
  lines.push('items with no code anchor.');
  lines.push('');
  lines.push('---');
  lines.push('');
  lines.push('## 1. Validator-declared limits (`supabase/functions/ai-firm-reports/validate.mjs`)');
  lines.push('');
  lines.push('| Check(s) | Hard gate | Status | Owner | Lines | Detail (verbatim comment block) |');
  lines.push('|---:|---|---|---|---|---|');
  for (const b of validatorLimits) {
    const checkCell = b.check ? String(b.check) : '_(not stated in this block)_';
    lines.push(`| ${checkCell} | yes (fabricated data / unsupported causality) | DECLARED (by design, not a defect) | engineering (validate.mjs maintainer) | ${b.startLine}-${b.endLine} | <details><summary>show</summary>\n\n\`\`\`\n${b.text}\n\`\`\`\n\n</details> |`);
  }
  lines.push('');
  lines.push('## 2. `BLOCKED` rows (`docs/qa/OWNER-ISSUE-LEDGER.md`)');
  lines.push('');
  lines.push('| ID | Check(s) mentioned | Hard gate | Status | Owner | Snippet |');
  lines.push('|---|---:|---|---|---|---|');
  for (const r of ledgerBlocked) {
    const checkCell = r.check ? String(r.check) : '_(none named)_';
    lines.push(`| \`${r.id}\` | ${checkCell} | not asserted here — see \`docs/qa/OWNER-ISSUE-LEDGER.md\` | BLOCKED | owner (named external ruling required) | ${r.snippet.replace(/\|/g, '\\|')} |`);
  }
  lines.push('');
  lines.push('## 3. Manually-registered items with no code anchor');
  lines.push('');
  lines.push('| ID | Check(s) | Hard gate | Status | Owner | Detail |');
  lines.push('|---|---:|---|---|---|---|');
  for (const it of manual) {
    lines.push(`| \`${it.id}\` | ${it.checks.join(', ')} | ${it.hard_gate ? 'yes' : 'no'} (${it.hard_gate_reason.replace(/\|/g, '\\|')}) | ${it.status} | ${it.owner} | ${it.detail.replace(/\|/g, '\\|')} |`);
  }
  lines.push('');
  return lines.join('\n') + '\n';
}

function runKnownLimitations(repoRoot, outDir) {
  const data = buildKnownLimitations(repoRoot);
  const mdPath = path.join(outDir, 'CI-KNOWN-LIMITATIONS.md');
  writeFileSync(mdPath, renderKnownLimitationsMarkdown(data));
  return { mdPath, data };
}

/* ------------------------------------------------------------ item 7: reconciliation report --- */

// CAPTURE FIX (2026-09-02). The previous implementation shelled out to
// `scripts/db-tests/run.mjs --filter=v731 --migrated-only` and grepped ITS OWN console output
// for `v731 |` NOTICE lines. That always came back empty, on a pass, for a reason that has
// nothing to do with which stream (stdout vs stderr) psql writes NOTICEs to: run.mjs's
// runExecutedSuite() calls `await cluster.psqlFile(db, test.path)` and, on success, only ever
// writes its own one-line `  ok    <name>  (Nms)` status to console — the psql child's captured
// {stdout, stderr} is held in a local variable inside lib.mjs's #spawnPsql() and simply never
// printed anywhere when the run passes. (On a FAILURE it DOES get surfaced, via `e.stderr` on
// the thrown error — which is exactly why the old code "worked" back when v731 was failing, and
// silently stopped working the moment nestly_v734/v737/v740/v742 fixed the underlying gap and
// the fixture started passing.)
//
// The fix does not touch scripts/db-tests/* (out of scope for this task — a governance agent
// owns migrations/plans/manifests/supabase/, and run.mjs's behaviour is deliberate for its own
// purpose: a pass is supposed to be quiet there). Instead this function drives
// scripts/db-tests/lib.mjs's own exported primitives DIRECTLY — the same ScratchCluster,
// baseline snapshot and pending-migration replay run.mjs itself uses — and calls
// `cluster.psqlFile(db, fixturePath, { quiet: false })` for the v731 fixture ONLY, capturing the
// resolved (or rejected) {stdout, stderr} itself. No console-scraping, no reliance on what any
// other script chooses to print. This also picks up the fixture's own machine-readable
// `select ... from _report order by seq` result (plain aligned psql table output on stdout),
// embedded verbatim below alongside the RAISE NOTICE lines (stderr) — the "select output" the
// fixture's own trailing comment says exists precisely for a generator to lift.
async function runReconciliationHarness(repoRoot) {
  const {
    ScratchCluster, applyBootstrap, discoverPendingMigrations, requirePostgresBinaries,
    isolatedWorkdir, pickFreePort, SNAPSHOT_PATH, BASELINE_GRANTS_PATH, SNAPSHOT_WATERMARK_VERSION,
  } = await loadDbTestsLib();
  requirePostgresBinaries();
  const { dir: workDir, ephemeral } = isolatedWorkdir('peekaa-ci-proof-pack-reconciliation');
  const port = await pickFreePort();
  const cluster = new ScratchCluster({
    dataDir: path.join(workDir, 'data'), port, logFile: path.join(workDir, 'server.log'),
  });
  const BASELINE_DB = 'peekaa_proofpack_baseline';
  const MIGRATED_DB = 'peekaa_proofpack_migrated';
  const TEST_DB = 'peekaa_proofpack_v731';
  let pending = [];
  let migrationFailure = null;
  let fixtureResult = null;
  let fixtureFailed = false;
  let serverVersion = null;
  cluster.init({ fresh: true });
  cluster.start();
  try {
    cluster.createDatabase(BASELINE_DB);
    await applyBootstrap(cluster, BASELINE_DB);
    await cluster.psqlFile(BASELINE_DB, SNAPSHOT_PATH);
    await cluster.psqlFile(BASELINE_DB, BASELINE_GRANTS_PATH);
    cluster.createDatabase(MIGRATED_DB, { template: BASELINE_DB });
    pending = discoverPendingMigrations();
    for (const m of pending) {
      try {
        await cluster.psqlFile(MIGRATED_DB, m.path);
      } catch (e) {
        migrationFailure = { migration: m, error: (e.stderr || e.message || '').trim() };
        break;
      }
    }
    if (!migrationFailure) {
      cluster.createDatabase(TEST_DB, { template: MIGRATED_DB });
      serverVersion = cluster.scalar(TEST_DB, 'select version()');
      const fixturePath = path.join(repoRoot, 'db/tests/executed/v731_reconciliation_report.sql');
      try {
        fixtureResult = await cluster.psqlFile(TEST_DB, fixturePath, { quiet: false });
      } catch (e) {
        fixtureFailed = true;
        fixtureResult = { stdout: e.stdout || '', stderr: e.stderr || '', error: e.message || String(e) };
      }
      cluster.dropDatabase(TEST_DB);
    }
  } finally {
    cluster.stop();
    if (ephemeral) rmSync(workDir, { recursive: true, force: true });
  }
  return {
    pendingMigrationCount: pending.length, migrationFailure, fixtureResult, fixtureFailed, serverVersion,
    harnessWatermark: SNAPSHOT_WATERMARK_VERSION,
  };
}

// Extract `psql:<file>:<line>: NOTICE:  <text>` -> `<text>`, filtered to the fixture's own
// `v731 |` tag, de-duplicated (psql would only ever print each NOTICE once per statement, but
// de-duping on trimmed content is cheap insurance against a future rerun-inside-loop change).
function extractV731NoticeLines(stderrText) {
  const lines = [];
  for (const raw of (stderrText || '').split('\n')) {
    const m = raw.match(/NOTICE:\s*(.*)$/);
    if (!m) continue;
    const text = m[1].trim();
    if (text.includes('v731 |')) lines.push(text);
  }
  return [...new Set(lines)];
}

async function runReconciliation(repoRoot, outDir) {
  const harness = await runReconciliationHarness(repoRoot);
  const { fixtureResult, fixtureFailed, migrationFailure, pendingMigrationCount, serverVersion, harnessWatermark } = harness;

  const stdout = fixtureResult ? fixtureResult.stdout || '' : '';
  const stderr = fixtureResult ? fixtureResult.stderr || '' : '';
  const combined = `${stdout}${stderr}`;
  const noticeLines = extractV731NoticeLines(stderr);
  const allRatios100 = noticeLines.length > 0 && noticeLines.every((l) => {
    const m = l.match(/pct_B=([\d.]+) pct_C=([\d.]+) pct_D=([\d.]+) pct_E=([\d.]+)/);
    return m && m.slice(1, 5).every((v) => Number(v) === 100.0);
  });
  const verdict = migrationFailure
    ? 'ERROR — a pending migration failed to apply; see "Migration failure" below'
    : fixtureFailed
      ? 'FAIL — the fixture raised (see "Full harness output" below); the reconciliation bar was not met'
      : allRatios100
        ? 'PASS — v731 reconciliation: recorded revenue (get_revenue_truth_v106) reconciles exactly '
          + '(100.0%) to the dashboard summary, the AI sales window, the platform consultant report '
          + 'and a direct-SQL sum, for every seeded business'
        : 'INCONCLUSIVE — the fixture completed without raising but no parseable v731 NOTICE lines '
          + 'were captured; see "Full harness output" below';

  const commitSha = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: repoRoot, encoding: 'utf8' }).stdout.trim();
  const commitDate = spawnSync('git', ['log', '-1', '--format=%cI'], { cwd: repoRoot, encoding: 'utf8' }).stdout.trim();
  const branch = spawnSync('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: repoRoot, encoding: 'utf8' }).stdout.trim();
  const nodeVersion = process.version;
  const generatedAt = new Date().toISOString();

  const lines = [];
  lines.push('# CI-100 proof-pack item 7 — reconciliation report');
  lines.push('');
  lines.push('> GENERATED by `scripts/quality/ci-proof-pack.mjs reconciliation`, which RAN');
  lines.push('> `db/tests/executed/v731_reconciliation_report.sql` directly through');
  lines.push('> `scripts/db-tests/lib.mjs`\'s own ScratchCluster (the same baseline snapshot and');
  lines.push('> pending-migration replay `scripts/db-tests/run.mjs` uses) and captured psql\'s actual');
  lines.push('> stdout/stderr for that one call itself — see the CAPTURE FIX comment on');
  lines.push('> `runReconciliationHarness()` in the generator for why the previous approach (scraping');
  lines.push('> run.mjs\'s own console output) always read empty on a pass. This file is the captured');
  lines.push('> output, not a hand-typed summary of it — regenerate rather than editing directly.');
  lines.push('');
  lines.push('## Scope');
  lines.push('');
  lines.push('Seeds the v682 golden-business shape (`app.seed_golden_business_v682`) for 3 sectors');
  lines.push('(fnb, salon, retail), then for each business reads FIVE independent revenue figures over');
  lines.push('the same window and reconciles all four against the first:');
  lines.push('');
  lines.push('* **A — recorded revenue.** `public.get_revenue_truth_v106` `totals.known_revenue_minor`.');
  lines.push('* **B — dashboard summary.** `public.get_dashboard_summary_v155` `kpis.revenue_cents`.');
  lines.push('* **C — AI sales window.** `app.v176_sales_window` `net_revenue_cents`.');
  lines.push('* **D — platform consultant report.** `public.platform_get_assigned_firm_report_v94`');
  lines.push('  `kpis.net_revenue_cents`, called as a real Google-SSO super admin.');
  lines.push('* **E — direct SQL.** `sum(sales.amount_cents)` over the same qualifying-sale predicate,');
  lines.push('  hand-written, no RPC.');
  lines.push('');
  lines.push('Reconciliation percentage = `round(100.0 * X / A, 1)` for X in {B, C, D, E}; the fixture');
  lines.push('asserts every one reads exactly `100.0`. As of nestly_v734/v737/v740/v742 (2026-09-02),');
  lines.push('every reader in this estate excludes an `is_synthetic` client\'s sales from reported');
  lines.push('revenue the same way `get_revenue_truth_v106` does, so all five figures reconcile');
  lines.push('exactly for every seeded business — there is no known gap left for this fixture to pin.');
  lines.push('');
  lines.push('## Environment');
  lines.push('');
  lines.push('| | |');
  lines.push('|---|---|');
  lines.push(`| Commit SHA | \`${commitSha}\` |`);
  lines.push(`| Branch | \`${branch}\` |`);
  lines.push(`| Commit date | ${commitDate} |`);
  lines.push(`| Report generated | ${generatedAt} |`);
  lines.push(`| Postgres (scratch harness server) | ${serverVersion || '(not reached — see Migration failure below)'} |`);
  lines.push(`| Node | ${nodeVersion} |`);
  lines.push(`| Harness watermark (\`scripts/db-tests/lib.mjs\` \`SNAPSHOT_WATERMARK_VERSION\`) | ${harnessWatermark} |`);
  lines.push(`| Pending migrations replayed on top of the watermark | ${pendingMigrationCount} |`);
  lines.push('| Command (equivalent) | `LC_ALL=C node scripts/db-tests/run.mjs --filter=v731_reconciliation_report --migrated-only` |');
  lines.push('');
  if (migrationFailure) {
    lines.push('## Migration failure');
    lines.push('');
    lines.push(`A pending migration failed to apply before the fixture could run: \`${migrationFailure.migration.name}\`.`);
    lines.push('');
    lines.push('```');
    lines.push(migrationFailure.error);
    lines.push('```');
    lines.push('');
  }
  lines.push('## Per-business reconciliation (captured `RAISE NOTICE` output, verbatim)');
  lines.push('');
  if (noticeLines.length === 0) {
    lines.push('_No `v731 |` NOTICE lines were captured — see "Full harness output" below for what the');
    lines.push('harness actually printed._');
  } else {
    lines.push('```');
    for (const l of noticeLines) lines.push(l);
    lines.push('```');
  }
  lines.push('');
  lines.push('## Machine-readable per-business table (fixture\'s own `select ... from _report`, verbatim)');
  lines.push('');
  lines.push('The fixture\'s trailing `select seq, business_index, sector, business_id, a_recorded,');
  lines.push('b_dashboard, c_sales_window, d_platform, e_direct_sql, pct_b, pct_c, pct_d, pct_e from');
  lines.push('_report order by seq` result, captured from psql\'s own stdout exactly as printed —');
  lines.push('the machine-readable counterpart to the NOTICE lines above.');
  lines.push('');
  lines.push('```');
  lines.push(stdout.trim() || '(no stdout captured)');
  lines.push('```');
  lines.push('');
  lines.push('## Verdict');
  lines.push('');
  lines.push('```');
  lines.push(verdict);
  lines.push('```');
  lines.push('');
  lines.push('## Full harness output (verbatim, for the `v731` fixture only)');
  lines.push('');
  lines.push('### stdout');
  lines.push('');
  lines.push('```');
  lines.push(stdout.trim() || '(empty)');
  lines.push('```');
  lines.push('');
  lines.push('### stderr');
  lines.push('');
  lines.push('```');
  lines.push(stderr.trim() || '(empty)');
  lines.push('```');
  lines.push('');

  const mdPath = path.join(outDir, 'CI-RECONCILIATION-REPORT.md');
  writeFileSync(mdPath, lines.join('\n') + '\n');
  return {
    mdPath, exitCode: migrationFailure || fixtureFailed ? 1 : 0, noticeLines, verdict, allRatios100,
    fixtureFailed, migrationFailure, combined,
  };
}

/* ---------------------------------------------------------- item 1: frozen commit record ------ */

// Required proof-pack item 1: "Frozen commit SHA and migration ledger version." Regenerated on
// every commit of the proof pack (its own header says so), so the SHA/date lines are EXPECTED to
// move every time — the byte-identity test for this one (unlike corpus-manifest/expected-answers/
// known-limitations) strips those specific lines before comparing, and separately re-checks the
// extracted SHA against a live `git rev-parse HEAD` so the test is green at any HEAD as long as
// the manifests/watermark/migration count match. See FROZEN_SHA_LINE_RE / FROZEN_DATE_LINE_RE
// (exported) for the exact lines the test strips.
const FROZEN_SHA_LINE_RE = /^\| HEAD SHA \| `[0-9a-f]{40}` \|$/m;
const FROZEN_BRANCH_LINE_RE = /^\| Branch \| `[^`]*` \|$/m;
const FROZEN_DATE_LINE_RE = /^\| Record generated \| .* \|$/m;

async function buildFrozenCommit(repoRoot) {
  const { SNAPSHOT_WATERMARK_VERSION } = await loadDbTestsLib();
  const headSha = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: repoRoot, encoding: 'utf8' }).stdout.trim();
  const branch = spawnSync('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: repoRoot, encoding: 'utf8' }).stdout.trim();
  const commitDate = spawnSync('git', ['log', '-1', '--format=%cI'], { cwd: repoRoot, encoding: 'utf8' }).stdout.trim();
  const generatedAt = new Date().toISOString();
  const pgVersion = spawnSync('psql', ['--version'], { encoding: 'utf8' }).stdout.trim();

  const dbManifestSha256Path = 'db/migrations/migration-order.manifest.json.sha256';
  const supabaseManifestSha256Path = 'supabase/canonical-migration-order.manifest.json.sha256';
  const dbManifestSha256 = readFileSync(path.join(repoRoot, dbManifestSha256Path), 'utf8').trim();
  const supabaseManifestSha256 = readFileSync(path.join(repoRoot, supabaseManifestSha256Path), 'utf8').trim();

  // Re-derived independently (not just echoing the .sha256 file) so a stale/hand-edited .sha256
  // checksum file is caught rather than trusted blindly.
  const dbManifestBytes = readFileSync(path.join(repoRoot, 'db/migrations/migration-order.manifest.json'));
  const supabaseManifestBytes = readFileSync(path.join(repoRoot, 'supabase/canonical-migration-order.manifest.json'));
  const dbManifestActualSha256 = sha256(dbManifestBytes);
  const supabaseManifestActualSha256 = sha256(supabaseManifestBytes);
  const dbManifestShaMatches = dbManifestSha256.startsWith(dbManifestActualSha256);
  const supabaseManifestShaMatches = supabaseManifestSha256.startsWith(supabaseManifestActualSha256);

  const migrationsDir = path.join(repoRoot, 'db/migrations');
  const migrations20260902 = readdirSync(migrationsDir)
    .filter((f) => f.startsWith('20260902_') && f.endsWith('.sql'))
    .sort();

  return {
    headSha, branch, commitDate, generatedAt, pgVersion,
    dbManifestSha256Path, supabaseManifestSha256Path, dbManifestSha256, supabaseManifestSha256,
    dbManifestActualSha256, supabaseManifestActualSha256, dbManifestShaMatches, supabaseManifestShaMatches,
    migrations20260902, harnessWatermark: SNAPSHOT_WATERMARK_VERSION,
  };
}

function renderFrozenCommitMarkdown(data) {
  const {
    headSha, branch, commitDate, generatedAt, pgVersion,
    dbManifestSha256Path, supabaseManifestSha256Path, dbManifestSha256, supabaseManifestSha256,
    dbManifestActualSha256, supabaseManifestActualSha256, dbManifestShaMatches, supabaseManifestShaMatches,
    migrations20260902, harnessWatermark,
  } = data;
  const lines = [];
  lines.push('# CI-100 proof-pack item 1 — frozen commit record');
  lines.push('');
  lines.push('> GENERATED by `scripts/quality/ci-proof-pack.mjs frozen`. This record is regenerated');
  lines.push('> on EVERY commit of the proof pack — the HEAD SHA, branch and "Record generated"');
  lines.push('> timestamp below are therefore expected to change on every regeneration, by design.');
  lines.push('> `tests/phase0-foundation/ci-proof-pack.test.mjs` compares this file to a fresh');
  lines.push('> regeneration MODULO those three lines (it strips and separately re-checks them — the');
  lines.push('> HEAD SHA line against a live `git rev-parse HEAD`) so the test is green at any HEAD as');
  lines.push('> long as the manifests, migration count and harness watermark match. Do not hand-edit —');
  lines.push('> regenerate.');
  lines.push('');
  lines.push('## Identity');
  lines.push('');
  lines.push('| | |');
  lines.push('|---|---|');
  lines.push(`| HEAD SHA | \`${headSha}\` |`);
  lines.push(`| Branch | \`${branch}\` |`);
  lines.push(`| Commit date | ${commitDate} |`);
  lines.push(`| Record generated | ${generatedAt} |`);
  lines.push(`| Postgres (local client) | ${pgVersion} |`);
  lines.push(`| Harness watermark (\`scripts/db-tests/lib.mjs\` \`SNAPSHOT_WATERMARK_VERSION\`) | ${harnessWatermark} |`);
  lines.push(`| Migrations dated 2026-09-02 (\`db/migrations/20260902_*.sql\`) | ${migrations20260902.length} |`);
  lines.push('');
  lines.push('## Migration ledger — canonical manifest checksums');
  lines.push('');
  lines.push('The two manifests that jointly define migration order for this repo, and the');
  lines.push('checksum files that pin them. Both are re-derived independently below (not merely');
  lines.push('echoed) so a stale or hand-edited `.sha256` file is caught rather than trusted blindly.');
  lines.push('');
  lines.push('| Manifest | `.sha256` file contents | Independently recomputed SHA-256 | Match |');
  lines.push('|---|---|---|---|');
  lines.push(`| \`db/migrations/migration-order.manifest.json\` | \`${dbManifestSha256}\` | \`${dbManifestActualSha256}\` | ${dbManifestShaMatches ? 'MATCH' : 'MISMATCH — see below'} |`);
  lines.push(`| \`supabase/canonical-migration-order.manifest.json\` | \`${supabaseManifestSha256}\` | \`${supabaseManifestActualSha256}\` | ${supabaseManifestShaMatches ? 'MATCH' : 'MISMATCH — see below'} |`);
  lines.push('');
  if (!dbManifestShaMatches || !supabaseManifestShaMatches) {
    lines.push('**MISMATCH DETECTED.** At least one committed `.sha256` file does not match its');
    lines.push('manifest\'s actual content — the manifest was edited without regenerating its');
    lines.push('checksum, or vice versa. This is a real finding, not a generator defect; regenerate');
    lines.push(`the affected checksum file (\`${dbManifestSha256Path}\` / \`${supabaseManifestSha256Path}\`) and`);
    lines.push('re-run this generator.');
    lines.push('');
  }
  lines.push('## Migrations dated 2026-09-02');
  lines.push('');
  lines.push(`**${migrations20260902.length}** files, filename order:`);
  lines.push('');
  for (const f of migrations20260902) lines.push(`* \`db/migrations/${f}\``);
  lines.push('');
  return lines.join('\n') + '\n';
}

async function runFrozenCommit(repoRoot, outDir) {
  const data = await buildFrozenCommit(repoRoot);
  const mdPath = path.join(outDir, 'CI-FROZEN-COMMIT.md');
  writeFileSync(mdPath, renderFrozenCommitMarkdown(data));
  return { mdPath, data };
}

/* -------------------------------------------- item 9: AI factuality / causal-language report -- */

// One-line purpose per RULES key, hand-authored from validate.mjs's own comments (the file's rule
// comments are prose paragraphs of varying length, not one-per-rule one-liners, so this is a
// curated summary rather than a mechanical extraction) — but MECHANICALLY CROSS-CHECKED against
// the live file below (buildAiFactuality throws if a RULES key or its named function goes
// missing), so a rename or a rule added/removed without updating this map fails loudly instead of
// silently going stale.
const AI_RULE_PURPOSES = {
  NUMERIC: { checkFn: 'groundNumbers', checks: [83], purpose: 'Every number in the narrative must ground against the evidence pack (a literal figure, a valid derived percentage, or a legitimate date/ratio) — an ungroundable number is a fabricated claim.' },
  POPULATION: { checkFn: 'checkPopulation', checks: [84], purpose: 'Cohort, period and branch labels named in prose must match the evidence pack\'s own population labels — a narrative cannot describe a different scope than the data it was given.' },
  CAUSAL: { checkFn: 'checkCausal', checks: [85], purpose: 'Causal verbs and constructions ("caused", "generated", "leads to", "will increase") are blocked unless the caller\'s causalEvidence flag explicitly permits them — currently always shut in production.' },
  CONFIDENCE: { checkFn: 'checkConfidenceTier', checks: [86], purpose: 'Generated certainty language ("clearly", "a strong pattern", "definitely") cannot exceed the server-calculated confidence tier (insufficient / early_signal / strong_pattern).' },
  LIMITATION: { checkFn: 'checkLimitations', checks: [87], purpose: 'Every section the pack marks unavailable in evidence_completeness must be acknowledged in the narrative — a material limitation cannot be silently omitted.' },
  ENTITY: { checkFn: 'checkEntities', checks: [88], purpose: 'Every person or entity named in the narrative must appear in the evidence pack — blocks an invented customer, staff member or business name.' },
  STRUCTURE: { checkFn: 'checkStructure', checks: [82], purpose: 'Output must use only the headings the prompt asked for, at the heading level asked for — blocks the model inventing its own report structure.' },
  COHORT: { checkFn: 'checkCohortContradiction', checks: [89], purpose: 'A cohort count claimed in prose that provably belongs to a DIFFERENT cohort in the pack is blocked as a hard contradiction, not merely an unsupported claim.' },
  CAUSAL_BINDING: { checkFn: 'checkAssociationCausalBinding', checks: [85], purpose: 'A causal construction used for a finding the pack itself marks ASSOCIATION (never CAUSAL) is blocked, even when no CAUSAL-rule verb alone would have fired.' },
  ASSOCIATION_MARKER: { checkFn: 'checkAssociationPositiveMarker', checks: [85], purpose: 'A sentence referencing an ASSOCIATION finding\'s own vocabulary must positively carry an approved hedge/association marker — silence is treated as a failure, not a pass, closing the laundering gap CAUSAL_BINDING alone left open.' },
};

// Mechanical extraction of the RULES object's own key/value pairs — `export const RULES = { KEY:
// 'VALUE', ... };` — independent of AI_RULE_PURPOSES above, so the cross-check below is real.
function extractRulesObject(text) {
  const m = text.match(/export const RULES = \{([\s\S]*?)\n\};/);
  if (!m) throw new Error('ai-factuality: could not find "export const RULES = { ... };" in validate.mjs');
  const body = m[1];
  const entries = [];
  const re = /^\s*([A-Z_]+):\s*'([^']+)',?\s*$/gm;
  let em;
  while ((em = re.exec(body)) !== null) entries.push({ key: em[1], value: em[2] });
  return entries;
}

function buildAiFactuality(repoRoot) {
  const validatorPath = path.join(repoRoot, 'supabase/functions/ai-firm-reports/validate.mjs');
  const validatorText = readFileSync(validatorPath, 'utf8');
  const rulesEntries = extractRulesObject(validatorText);
  for (const { key } of rulesEntries) {
    const info = AI_RULE_PURPOSES[key];
    if (!info) throw new Error(`ai-factuality: RULES.${key} has no entry in AI_RULE_PURPOSES — add one`);
    if (!new RegExp(`\\bfunction ${info.checkFn}\\(`).test(validatorText)) {
      throw new Error(`ai-factuality: AI_RULE_PURPOSES.${key}.checkFn '${info.checkFn}' not found in validate.mjs — rename drifted`);
    }
  }
  for (const key of Object.keys(AI_RULE_PURPOSES)) {
    if (!rulesEntries.some((e) => e.key === key)) {
      throw new Error(`ai-factuality: AI_RULE_PURPOSES has '${key}' but validate.mjs's RULES object does not — stale entry`);
    }
  }
  const honestLimits = extractValidatorLimits(validatorText);

  const enforcePath = path.join(repoRoot, 'supabase/functions/ai-firm-reports/enforce.mjs');
  const enforceText = readFileSync(enforcePath, 'utf8');
  const outcomeContractM = enforceText.match(/\/\/\s*(decideNarrativeOutcome\([^)]*\)\s*->[\s\S]*?)\n\/\/\s*\n/);
  const failureContractM = enforceText.match(/\/\/\s*(decideGenerationFailure\([^)]*\)\s*->[\s\S]*?)\n\/\/\s*\n/);
  const hasOutcomeFn = /export function decideNarrativeOutcome\(/.test(enforceText);
  const hasFailureFn = /export function decideGenerationFailure\(/.test(enforceText);
  if (!hasOutcomeFn || !hasFailureFn) {
    throw new Error('ai-factuality: enforce.mjs is missing decideNarrativeOutcome or decideGenerationFailure');
  }

  const indexTsPath = path.join(repoRoot, 'supabase/functions/ai-firm-reports/index.ts');
  const indexTsText = readFileSync(indexTsPath, 'utf8');
  const promptVersionM = indexTsText.match(/PROMPT_VERSION\s*=\s*'([^']+)'/);
  const promptVersion = promptVersionM ? promptVersionM[1] : null;
  if (!promptVersion) throw new Error('ai-factuality: could not read PROMPT_VERSION from index.ts');

  const goldenGate = spawnSync(process.execPath, ['scripts/quality/ai-report-golden-gate.mjs'], {
    cwd: repoRoot, encoding: 'utf8',
  });

  const aiReportsDir = path.join(repoRoot, 'tests/ai-reports');
  const testFiles = readdirSync(aiReportsDir)
    .filter((f) => f.endsWith('.test.mjs'))
    .sort()
    .map((f) => path.posix.join('tests/ai-reports', f));
  // NODE_TEST_CONTEXT / NODE_TEST_WORKER_ID are set by Node's own `node --test` runner on every
  // process it spawns, and inherited here by spawnSync's default env passthrough — when THIS
  // generator is itself invoked from inside `node --test` (exactly what
  // tests/phase0-foundation/ci-proof-pack.test.mjs's own 'ai-factuality' test does), those two
  // vars leak into this child and Node's recursion guard silently skips every file ("node:test
  // run() is being called recursively within a test file. skipping running files.") — a SILENT
  // no-op, not an error, so testCombined would otherwise come back empty and every count below
  // null. Stripping them is the fix; the child gets a clean, first-generation `node --test`.
  const { NODE_TEST_CONTEXT: _ntc, NODE_TEST_WORKER_ID: _ntw, ...cleanEnv } = process.env;
  const testRun = spawnSync(process.execPath, ['--test', ...testFiles], {
    cwd: repoRoot, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, env: cleanEnv,
  });
  const testCombined = `${testRun.stdout || ''}${testRun.stderr || ''}`;
  const countOf = (label) => {
    const m = testCombined.match(new RegExp(`^# ?${label} (\\d+)`, 'm')) || testCombined.match(new RegExp(`^ℹ ${label} (\\d+)`, 'm'));
    return m ? Number(m[1]) : null;
  };
  const testCounts = {
    tests: countOf('tests'), pass: countOf('pass'), fail: countOf('fail'),
    cancelled: countOf('cancelled'), skipped: countOf('skipped'), todo: countOf('todo'),
  };
  if (testCounts.tests === null || testCounts.tests === 0) {
    throw new Error(
      'ai-factuality: could not parse a tests/pass/fail summary out of `node --test '
      + 'tests/ai-reports/*.test.mjs` output (tests=' + testCounts.tests + ') — this reads as '
      + 'silent-empty far more often than as a real 0-test run; see testCombined for the actual '
      + `captured output. First/last 400 chars:\n${testCombined.slice(0, 400)}\n...\n${testCombined.slice(-400)}`
    );
  }

  return {
    rulesEntries, honestLimits, promptVersion, testFiles, testCombined, testCounts,
    testExitCode: testRun.status,
    goldenGateStdout: goldenGate.stdout || '', goldenGateStderr: goldenGate.stderr || '', goldenGateExitCode: goldenGate.status,
    outcomeContract: outcomeContractM ? outcomeContractM[1].replace(/^\/\/\s?/gm, '').trim() : '(comment shape changed — see enforce.mjs directly)',
    failureContract: failureContractM ? failureContractM[1].replace(/^\/\/\s?/gm, '').trim() : '(comment shape changed — see enforce.mjs directly)',
  };
}

function renderAiFactualityMarkdown(data) {
  const {
    rulesEntries, honestLimits, promptVersion, testFiles, testCombined, testCounts, testExitCode,
    goldenGateStdout, goldenGateExitCode, outcomeContract, failureContract,
  } = data;
  const lines = [];
  lines.push('# CI-100 proof-pack item 9 — AI factuality and causal-language report');
  lines.push('');
  lines.push('> GENERATED by `scripts/quality/ci-proof-pack.mjs ai-factuality`. The rule list and');
  lines.push('> honest-limits comments are extracted from');
  lines.push('> `supabase/functions/ai-firm-reports/validate.mjs`, cross-checked so a renamed/');
  lines.push('> removed rule fails the generator rather than shipping a stale document; the golden-');
  lines.push('> gate output and test counts below are from LIVE runs, not recorded numbers. Do not');
  lines.push('> hand-edit — regenerate.');
  lines.push('');
  lines.push(`Prompt version under test: **\`${promptVersion}\`** (read from`);
  lines.push('`supabase/functions/ai-firm-reports/index.ts`).');
  lines.push('');
  lines.push('## Validator rule list (`supabase/functions/ai-firm-reports/validate.mjs` `RULES`)');
  lines.push('');
  lines.push('| Key | Rule ID | Checklist check(s) | Checking function | Purpose |');
  lines.push('|---|---|---:|---|---|');
  for (const { key, value } of rulesEntries) {
    const info = AI_RULE_PURPOSES[key];
    lines.push(`| \`RULES.${key}\` | \`${value}\` | ${info.checks.join(', ')} | \`${info.checkFn}\` | ${info.purpose} |`);
  }
  lines.push('');
  lines.push('## Enforcement path (`supabase/functions/ai-firm-reports/enforce.mjs`)');
  lines.push('');
  lines.push('The PASS/FAIL decision `index.ts`\'s `processQueue` makes after generating a narrative —');
  lines.push('extracted so a Node test can execute it directly rather than only ever running inside a');
  lines.push('live Deno edge-function invocation.');
  lines.push('');
  lines.push('### `decideNarrativeOutcome` — judges a narrative the model DID return, against the evidence');
  lines.push('');
  lines.push('```');
  lines.push(outcomeContract);
  lines.push('```');
  lines.push('');
  lines.push('### `decideGenerationFailure` — judges whether the model call produced a narrative worth judging at all (check 98)');
  lines.push('');
  lines.push('```');
  lines.push(failureContract);
  lines.push('```');
  lines.push('');
  lines.push('## Honest-limits comments (`validate.mjs`\'s own `HONEST LIMIT` / `declared limit` blocks)');
  lines.push('');
  lines.push(`**${honestLimits.length}** declared limits found. Full text of each (also compiled into`);
  lines.push('`docs/qa/proof-pack/CI-KNOWN-LIMITATIONS.md` §1, alongside `BLOCKED` ledger rows and');
  lines.push('manually-registered items):');
  lines.push('');
  for (const b of honestLimits) {
    const checkCell = b.check ? `check ${b.check}` : '(check not stated in this block)';
    lines.push(`<details><summary>lines ${b.startLine}-${b.endLine} — ${checkCell}</summary>`);
    lines.push('');
    lines.push('```');
    lines.push(b.text);
    lines.push('```');
    lines.push('');
    lines.push('</details>');
    lines.push('');
  }
  lines.push('## Golden-gate output (`node scripts/quality/ai-report-golden-gate.mjs`, live run)');
  lines.push('');
  lines.push('Runs the real `validateNarrative` (no re-implementation) over a small corpus of packs,');
  lines.push('each paired with a KNOWN-GOOD narrative (must validate clean) and a KNOWN-BAD narrative');
  lines.push('(must NOT validate clean) — the end-to-end check that the rules above still agree with');
  lines.push('reality across the shapes of business this product serves, not merely with one hand-built');
  lines.push('fixture pack.');
  lines.push('');
  lines.push('```');
  lines.push(goldenGateStdout.trim() || '(no stdout captured)');
  lines.push('```');
  lines.push('');
  lines.push(`Exit code: **${goldenGateExitCode}** (0 = every pack clean).`);
  lines.push('');
  lines.push('## Test counts (`node --test tests/ai-reports/*.test.mjs`, live run)');
  lines.push('');
  lines.push(`Files run (${testFiles.length}):`);
  lines.push('');
  for (const f of testFiles) lines.push(`* \`${f}\``);
  lines.push('');
  lines.push('| tests | pass | fail | cancelled | skipped | todo |');
  lines.push('|---:|---:|---:|---:|---:|---:|');
  lines.push(`| ${testCounts.tests} | ${testCounts.pass} | ${testCounts.fail} | ${testCounts.cancelled} | ${testCounts.skipped} | ${testCounts.todo} |`);
  lines.push('');
  lines.push(`Process exit code: **${testExitCode}** (0 = every test passed).`);
  lines.push('');
  lines.push('<details><summary>Full `node --test` output</summary>');
  lines.push('');
  lines.push('```');
  lines.push(testCombined.trim());
  lines.push('```');
  lines.push('');
  lines.push('</details>');
  lines.push('');
  return lines.join('\n') + '\n';
}

function runAiFactuality(repoRoot, outDir) {
  const data = buildAiFactuality(repoRoot);
  const mdPath = path.join(outDir, 'CI-AI-FACTUALITY-REPORT.md');
  writeFileSync(mdPath, renderAiFactualityMarkdown(data));
  return { mdPath, data, exitCode: (data.goldenGateExitCode || 0) !== 0 || (data.testExitCode || 0) !== 0 ? 1 : 0 };
}

/* --------------------------------------- item 10: tenant/branch isolation report -------------- */

const ISOLATION_FIXTURES = [
  'v667_ci_access_boundaries.sql',
  'v713_corpus_evidence_pack.sql',
  'v720_corpus_evidence_pack_grants.sql',
  'v721_corpus_one_ci_gate.sql',
  'v725_corpus_time_basis_shadow_gate.sql',
  'v736_corpus_small_cell_principals.sql',
  'v741_corpus_roster_read_audit.sql',
];

// Authority/gate functions this estate's access-boundary fixtures are built around (see
// db/migrations/20260901_nestly_v667_ci_access_boundaries.sql and its successors) — a fixed,
// curated allowlist so the "gate function(s) referenced" column names the functions that actually
// DECIDE access, not every RPC the fixture happens to call along the way.
const ISOLATION_GATE_FUNCTIONS = [
  'app.ci_access_gate_v667', 'app.v176_can_read_firm_report', 'app.is_salon_member',
  'app.is_super_admin', 'app.can_module', 'app.has_perm', 'app.role_class', 'app.role_perms',
];

function extractLeadingComment(text) {
  const lines = text.split('\n');
  const out = [];
  for (const l of lines) {
    if (/^--/.test(l)) out.push(l.replace(/^--\s?/, ''));
    else if (l.trim() === '' && out.length > 0) out.push('');
    else break;
  }
  while (out.length && out[out.length - 1] === '') out.pop();
  return out.join('\n');
}

function extractFailAssertionIds(text) {
  const ids = new Set();
  const re = /insert into _fail values \('([^']+)'/g;
  let m;
  while ((m = re.exec(text)) !== null) ids.add(m[1]);
  return [...ids].sort();
}

// Principal x reader matrix: walk the file top to bottom, tracking the most recent principal set
// via `set_config('request.jwt.claims', json_build_object('sub', <ident>, ...` (or a reset to
// null, recorded as the literal principal 'service_role/none'), and count every subsequent call
// to a versioned app./public. function (`name_vNNN(`) against that principal until the next
// set_config. Mechanical and file-agnostic — no per-fixture hardcoding of which RPCs it tests.
function extractPrincipalReaderMatrix(text) {
  // Byte-offset sweep, NOT line-by-line: the fixtures consistently wrap
  // `set_config('request.jwt.claims',` onto its own line, with the
  // `json_build_object('sub', <ident>...` that actually names the principal starting on the NEXT
  // line — a per-line match finds nothing there. The `s` (dotAll) flag lets claimRe span that
  // newline; matching against the whole text (not line-by-line) and sorting all events by index
  // afterwards keeps the before/after ordering that determines "most recent principal" correct.
  const claimRe = /set_config\('request\.jwt\.claims',\s*(?:null|json_build_object\('sub',\s*([a-zA-Z_][a-zA-Z0-9_]*))/gs;
  const callRe = /\b((?:app|public)\.[a-z][a-z0-9_]*_v\d+)\(/g;

  const events = [];
  let m;
  while ((m = claimRe.exec(text)) !== null) {
    events.push({ index: m.index, type: 'claim', principal: m[1] || 'service_role/none' });
  }
  while ((m = callRe.exec(text)) !== null) {
    events.push({ index: m.index, type: 'call', reader: m[1] });
  }
  events.sort((a, b) => a.index - b.index);

  let currentPrincipal = '(none set yet)';
  const counts = new Map(); // `${principal} ${reader}` -> count
  const principals = new Set();
  const readers = new Set();
  for (const e of events) {
    if (e.type === 'claim') {
      currentPrincipal = e.principal;
      principals.add(currentPrincipal);
    } else {
      readers.add(e.reader);
      const key = `${currentPrincipal} ${e.reader}`;
      counts.set(key, (counts.get(key) || 0) + 1);
    }
  }
  return { principals: [...principals].sort(), readers: [...readers].sort(), counts };
}

function extractAuditRuleIds(text) {
  return [...new Set((text.match(/\b[A-Z][A-Z_]*_READ_V\d+\b/g) || []))].sort();
}

function extractDrainMentions(text) {
  const lines = text.split('\n');
  const hits = [];
  for (let i = 0; i < lines.length; i++) {
    if (/\bdrain_active\b|\binternal_drain\b/i.test(lines[i])) hits.push({ line: i + 1, text: lines[i].trim() });
  }
  return hits;
}

function extractVerdictTemplate(text) {
  const m = text.match(/select case when count\(\*\)\s*=?\s*0\s*\n?\s*then\s+'([^']+)'/);
  return m ? m[1] : null;
}

async function runFixtureAgainstTemplate(cluster, templateDb, dbName, fixturePath) {
  cluster.createDatabase(dbName, { template: templateDb });
  try {
    const result = await cluster.psqlFile(dbName, fixturePath, { quiet: false });
    return { failed: false, stdout: result.stdout, stderr: result.stderr };
  } catch (e) {
    return { failed: true, stdout: e.stdout || '', stderr: e.stderr || '', error: e.message || String(e) };
  } finally {
    cluster.dropDatabase(dbName);
  }
}

async function runIsolationHarness(repoRoot) {
  const {
    ScratchCluster, applyBootstrap, discoverPendingMigrations, requirePostgresBinaries,
    isolatedWorkdir, pickFreePort, SNAPSHOT_PATH, BASELINE_GRANTS_PATH,
  } = await loadDbTestsLib();
  requirePostgresBinaries();
  const { dir: workDir, ephemeral } = isolatedWorkdir('peekaa-ci-proof-pack-isolation');
  const port = await pickFreePort();
  const cluster = new ScratchCluster({
    dataDir: path.join(workDir, 'data'), port, logFile: path.join(workDir, 'server.log'),
  });
  const BASELINE_DB = 'peekaa_proofpack_iso_baseline';
  const MIGRATED_DB = 'peekaa_proofpack_iso_migrated';
  let pending = [];
  let migrationFailure = null;
  const results = [];
  cluster.init({ fresh: true });
  cluster.start();
  try {
    cluster.createDatabase(BASELINE_DB);
    await applyBootstrap(cluster, BASELINE_DB);
    await cluster.psqlFile(BASELINE_DB, SNAPSHOT_PATH);
    await cluster.psqlFile(BASELINE_DB, BASELINE_GRANTS_PATH);
    cluster.createDatabase(MIGRATED_DB, { template: BASELINE_DB });
    pending = discoverPendingMigrations();
    for (const m of pending) {
      try {
        await cluster.psqlFile(MIGRATED_DB, m.path);
      } catch (e) {
        migrationFailure = { migration: m, error: (e.stderr || e.message || '').trim() };
        break;
      }
    }
    if (!migrationFailure) {
      for (const [i, filename] of ISOLATION_FIXTURES.entries()) {
        const fixturePath = path.join(repoRoot, 'db/tests/executed', filename);
        const dbName = `peekaa_proofpack_iso_${i}`;
        const r = await runFixtureAgainstTemplate(cluster, MIGRATED_DB, dbName, fixturePath);
        results.push({ filename, ...r });
      }
    }
  } finally {
    cluster.stop();
    if (ephemeral) rmSync(workDir, { recursive: true, force: true });
  }
  return { migrationFailure, results };
}

function buildIsolationReport(repoRoot, harness) {
  const perFixture = ISOLATION_FIXTURES.map((filename) => {
    const relPath = path.posix.join('db/tests/executed', filename);
    const text = readFileSync(path.join(repoRoot, relPath), 'utf8');
    const header = extractLeadingComment(text);
    const assertionIds = extractFailAssertionIds(text);
    const matrix = extractPrincipalReaderMatrix(text);
    const gates = ISOLATION_GATE_FUNCTIONS.filter((fn) => new RegExp(fn.replace('.', '\\.') + '\\(').test(text));
    const drainMentions = extractDrainMentions(text);
    const auditRuleIds = extractAuditRuleIds(text);
    const verdictTemplate = extractVerdictTemplate(text);
    const run = harness.results.find((r) => r.filename === filename) || null;
    const stderr = run ? run.stderr || '' : '';
    const stdout = run ? run.stdout || '' : '';
    const combined = `${stdout}${stderr}`;
    // The data row of the fixture's own `select case when count(*)=0 then 'PASS ...' else 'FAIL'
    // end as verdict` — psql prints it aligned, leading whitespace and all. Fixtures spell the
    // dash after PASS inconsistently (an em dash "—" in most, a literal "--" in v720/v736), so
    // this matches on the word alone rather than a specific dash character.
    const capturedVerdictLine = combined.split('\n').map((l) => l.trim()).find((l) => /^PASS\b/.test(l) || l === 'FAIL');
    const passed = run ? !run.failed : null;
    return {
      filename, relPath, header, assertionIds, matrix, gates, drainMentions, auditRuleIds,
      verdictTemplate, run, capturedVerdictLine, passed,
    };
  });
  const allPassed = harness.migrationFailure ? false : perFixture.every((f) => f.passed === true);
  return { perFixture, migrationFailure: harness.migrationFailure, allPassed };
}

function renderIsolationMarkdown(data, repoRoot) {
  const { perFixture, migrationFailure, allPassed } = data;
  const commitSha = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: repoRoot, encoding: 'utf8' }).stdout.trim();
  const generatedAt = new Date().toISOString();
  const lines = [];
  lines.push('# CI-100 proof-pack item 10 — tenant/branch isolation report');
  lines.push('');
  lines.push('> GENERATED by `scripts/quality/ci-proof-pack.mjs isolation`. Fixture headers,');
  lines.push('> assertion IDs, the principal x reader matrix, gate-function references, drain-arm');
  lines.push('> mentions and audit-rule IDs are extracted mechanically from each fixture\'s own text;');
  lines.push('> the verdict for each is from a LIVE harness run (same ScratchCluster machinery as');
  lines.push('> `reconciliation`), not a recorded number. Do not hand-edit — regenerate.');
  lines.push('');
  lines.push(`Commit \`${commitSha}\`, generated ${generatedAt}.`);
  lines.push('');
  lines.push('## Scope');
  lines.push('');
  lines.push('The seven access-boundary fixtures the task names explicitly (v689 has no separate');
  lines.push('`db/tests/executed` file of its own — its assertions were folded into v667, see B1c');
  lines.push('in that fixture\'s own header — so it is not listed as an eighth row):');
  lines.push('');
  for (const f of perFixture) lines.push(`* \`${f.relPath}\``);
  lines.push('');
  if (migrationFailure) {
    lines.push('## Migration failure');
    lines.push('');
    lines.push(`A pending migration failed to apply before any fixture could run: \`${migrationFailure.migration.name}\`.`);
    lines.push('');
    lines.push('```');
    lines.push(migrationFailure.error);
    lines.push('```');
    lines.push('');
  }
  for (const f of perFixture) {
    lines.push(`## \`${f.relPath}\``);
    lines.push('');
    lines.push('<details><summary>Fixture header (verbatim)</summary>');
    lines.push('');
    lines.push('```');
    lines.push(f.header);
    lines.push('```');
    lines.push('');
    lines.push('</details>');
    lines.push('');
    lines.push(`**Assertion IDs** (${f.assertionIds.length}, from this fixture's own \`insert into _fail`);
    lines.push('values (\'ID\', ...)\` calls): ' + (f.assertionIds.length ? f.assertionIds.map((id) => `\`${id}\``).join(', ') : '_(none found)_'));
    lines.push('');
    lines.push(`**Gate/authority functions referenced:** ${f.gates.length ? f.gates.map((g) => `\`${g}\``).join(', ') : '_(none from the curated allowlist)_'}`);
    lines.push('');
    lines.push(`**Drain-arm mentions:** ${f.drainMentions.length ? '' : '_(none)_'}`);
    for (const d of f.drainMentions.slice(0, 6)) lines.push(`* line ${d.line}: \`${d.text}\``);
    lines.push('');
    lines.push(`**Audit-rule IDs referenced:** ${f.auditRuleIds.length ? f.auditRuleIds.map((a) => `\`${a}\``).join(', ') : '_(none)_'}`);
    lines.push('');
    lines.push('**Principal x reader matrix** (principal = the local variable bound as `sub` in the');
    lines.push('most recent `request.jwt.claims` before the call; `service_role/none` = claims reset');
    lines.push('to null, i.e. an unauthenticated/service-role context; cell = number of calls):');
    lines.push('');
    if (f.matrix.principals.length === 0 || f.matrix.readers.length === 0) {
      lines.push('_(no principal/reader calls matched the extraction pattern in this fixture)_');
    } else {
      lines.push(`| principal \\ reader | ${f.matrix.readers.map((r) => `\`${r}\``).join(' | ')} |`);
      lines.push(`|---|${f.matrix.readers.map(() => '---:').join('|')}|`);
      for (const p of f.matrix.principals) {
        const cells = f.matrix.readers.map((r) => f.matrix.counts.get(`${p} ${r}`) || '');
        lines.push(`| \`${p}\` | ${cells.join(' | ')} |`);
      }
    }
    lines.push('');
    lines.push('**Live harness verdict:**');
    lines.push('');
    lines.push('```');
    lines.push(f.capturedVerdictLine || (f.run ? (f.run.failed ? `FAIL — ${f.run.error}` : '(no verdict line matched — see full output)') : '(fixture did not run — see Migration failure above)'));
    lines.push('```');
    lines.push('');
  }
  lines.push('## Section J (checks 94 tenant isolation / 95 branch isolation) — derived scorer outcome');
  lines.push('');
  lines.push('Derived, not asserted independently: every one of the fixtures above must have run and');
  lines.push('read PASS for this line to read PASS. A single FAIL (or a migration that never let the');
  lines.push('fixtures run at all) makes the whole line FAIL — partial credit does not count as proof,');
  lines.push('per the checklist\'s own scoring rule.');
  lines.push('');
  lines.push('```');
  lines.push(allPassed ? 'PASS — every isolation fixture in scope ran and reconciled to PASS' : 'FAIL — see the per-fixture verdicts above');
  lines.push('```');
  lines.push('');
  return lines.join('\n') + '\n';
}

async function runIsolation(repoRoot, outDir) {
  const harness = await runIsolationHarness(repoRoot);
  const data = buildIsolationReport(repoRoot, harness);
  const mdPath = path.join(outDir, 'CI-ISOLATION-REPORT.md');
  writeFileSync(mdPath, renderIsolationMarkdown(data, repoRoot));
  return { mdPath, data, exitCode: data.allPassed ? 0 : 1 };
}

/* ------------------------------------------------------------------------------- entrypoint --- */

async function main() {
  const { subcommand, outDir: outDirArg, repoRoot: repoRootArg } = parseArgs(process.argv.slice(2));
  const repoRoot = repoRootArg ? path.resolve(repoRootArg) : DEFAULT_REPO_ROOT;
  const outDir = path.resolve(repoRoot, outDirArg || 'docs/qa/proof-pack');
  mkdirSync(outDir, { recursive: true });

  const subcommands = {
    frozen: () => runFrozenCommit(repoRoot, outDir),
    'corpus-manifest': () => runCorpusManifest(repoRoot, outDir),
    'expected-answers': () => runExpectedAnswers(repoRoot, outDir),
    'known-limitations': () => runKnownLimitations(repoRoot, outDir),
    reconciliation: () => runReconciliation(repoRoot, outDir),
    'ai-factuality': () => runAiFactuality(repoRoot, outDir),
    isolation: () => runIsolation(repoRoot, outDir),
  };
  const ALL_ORDER = [
    'frozen', 'corpus-manifest', 'expected-answers', 'known-limitations',
    'reconciliation', 'ai-factuality', 'isolation',
  ];
  const EXIT_CODE_SUBCOMMANDS = new Set(['reconciliation', 'ai-factuality', 'isolation']);

  if (subcommand === 'all') {
    let anyNonZero = false;
    for (const name of ALL_ORDER) {
      console.log(`ci-proof-pack: running ${name}...`);
      const result = await subcommands[name]();
      if (EXIT_CODE_SUBCOMMANDS.has(name) && result.exitCode !== 0) anyNonZero = true;
    }
    console.log('ci-proof-pack: done.');
    if (anyNonZero) process.exitCode = 1;
    return;
  }

  const fn = subcommands[subcommand];
  if (!fn) {
    console.error(`Usage: node scripts/quality/ci-proof-pack.mjs <${Object.keys(subcommands).join('|')}|all> [--out-dir=DIR] [--repo-root=DIR]`);
    process.exit(2);
  }
  const result = await fn();
  console.log(`ci-proof-pack: wrote ${result.mdPath}${result.jsonPath ? ` and ${result.jsonPath}` : ''}`);
  if (EXIT_CODE_SUBCOMMANDS.has(subcommand) && result.exitCode !== 0) process.exitCode = 1;
}

const isDirectCli = (() => {
  try {
    return import.meta.url === `file://${process.argv[1]}`;
  } catch {
    return false;
  }
})();
if (isDirectCli) main().catch((e) => { console.error(e); process.exit(1); });

export {
  buildFrozenCommit, renderFrozenCommitMarkdown, runFrozenCommit,
  buildCorpusManifest, renderCorpusManifestMarkdown, runCorpusManifest,
  buildExpectedAnswers, renderExpectedAnswersMarkdown, runExpectedAnswers,
  buildKnownLimitations, renderKnownLimitationsMarkdown, runKnownLimitations,
  runReconciliation, runReconciliationHarness, extractV731NoticeLines,
  buildAiFactuality, renderAiFactualityMarkdown, runAiFactuality, extractRulesObject,
  runIsolationHarness, buildIsolationReport, renderIsolationMarkdown, runIsolation,
  extractLeadingComment, extractFailAssertionIds, extractPrincipalReaderMatrix,
  extractAuditRuleIds, extractDrainMentions, extractVerdictTemplate,
  extractTruthTable, extractCheckNumbers, extractMigrationRefs, extractValidatorLimits, extractLedgerBlocked,
  listCorpusFixtures,
};
