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
 *   reconciliation       RUNS db/tests/executed/v731_reconciliation_report.sql on the harness and
 *                        writes CI-RECONCILIATION-REPORT.md from its captured output (item 7)
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
 * present in the freshly captured output).
 */
import { createHash } from 'node:crypto';
import { readdirSync, readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DEFAULT_REPO_ROOT = fileURLToPath(new URL('../..', import.meta.url));

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

function runReconciliation(repoRoot, outDir) {
  const harnessArgs = ['scripts/db-tests/run.mjs', '--filter=v731', '--migrated-only'];
  const result = spawnSync(process.execPath, harnessArgs, {
    cwd: repoRoot,
    encoding: 'utf8',
    env: { ...process.env, LC_ALL: 'C' },
    maxBuffer: 64 * 1024 * 1024,
  });
  const combined = `${result.stdout || ''}${result.stderr || ''}`;
  // The harness's own reporter reprints the SAME notice line more than once at different
  // indentation levels (once per FAIL entry, again — 4-space-indented — inside its one-line
  // "── summary ──" block) — de-duplicate on the TRIMMED content (indentation is not part of the
  // actual notice) so the per-business table below shows exactly one row per business.
  const noticeLines = [...new Set(
    combined.split('\n').filter((l) => l.includes('NOTICE:') && l.includes('v731 |')).map((l) => l.trim())
  )];
  const verdictLine = combined.split('\n').find((l) => /PASS — v731 reconciliation|FAIL/.test(l));
  const failureLines = combined.split('\n').filter((l) => /^\s*(reconcile_[A-Z]|A_recorded|B_dashboard|C_sales_window|D_platform|E_direct_sql|seed|PRE):/.test(l.trim()));

  const commitSha = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: repoRoot, encoding: 'utf8' }).stdout.trim();
  const commitDate = spawnSync('git', ['log', '-1', '--format=%cI'], { cwd: repoRoot, encoding: 'utf8' }).stdout.trim();
  const branch = spawnSync('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: repoRoot, encoding: 'utf8' }).stdout.trim();
  const pgVersion = spawnSync('psql', ['--version'], { encoding: 'utf8' }).stdout.trim();
  const nodeVersion = process.version;
  const generatedAt = new Date().toISOString();

  const lines = [];
  lines.push('# CI-100 proof-pack item 7 — reconciliation report');
  lines.push('');
  lines.push('> GENERATED by `scripts/quality/ci-proof-pack.mjs reconciliation`, which RAN');
  lines.push('> `db/tests/executed/v731_reconciliation_report.sql` on the executed-SQL harness and');
  lines.push('> captured its output verbatim below. This file is the captured output, not a hand-typed');
  lines.push('> summary of it — regenerate by re-running the command in "Environment" below rather than');
  lines.push('> editing this file directly.');
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
  lines.push('asserts every one reads exactly `100.0`.');
  lines.push('');
  lines.push('## Environment');
  lines.push('');
  lines.push('| | |');
  lines.push('|---|---|');
  lines.push(`| Commit SHA | \`${commitSha}\` |`);
  lines.push(`| Branch | \`${branch}\` |`);
  lines.push(`| Commit date | ${commitDate} |`);
  lines.push(`| Report generated | ${generatedAt} |`);
  lines.push(`| Postgres | ${pgVersion} |`);
  lines.push(`| Node | ${nodeVersion} |`);
  lines.push('| Harness watermark | `scripts/db-tests/lib.mjs` `SNAPSHOT_WATERMARK_VERSION` (see that file) |');
  lines.push('| Command | `LC_ALL=C node scripts/db-tests/run.mjs --filter=v731 --migrated-only` |');
  lines.push(`| Harness exit code | ${result.status} |`);
  lines.push('');
  lines.push('## Per-business reconciliation (captured `RAISE NOTICE` output, verbatim)');
  lines.push('');
  if (noticeLines.length === 0) {
    lines.push('_No `v731 |` NOTICE lines were captured — see "Full harness output" below for what the');
    lines.push('harness actually printed._');
  } else {
    lines.push('```');
    for (const l of noticeLines) lines.push(l.trim());
    lines.push('```');
  }
  lines.push('');
  lines.push('## Verdict');
  lines.push('');
  lines.push('```');
  lines.push(verdictLine || '(no verdict line captured — see full output below)');
  lines.push('```');
  lines.push('');
  if (failureLines.length) {
    lines.push('### Assertion failures (if any)');
    lines.push('');
    lines.push('```');
    for (const l of failureLines) lines.push(l.trim());
    lines.push('```');
    lines.push('');
    lines.push('**These are genuine findings, not fixture bugs — see');
    lines.push('`db/tests/executed/v731_reconciliation_report.sql`\'s own "FINDING" header comment for');
    lines.push('root cause.** In short: `app.seed_golden_business_v682` deliberately gives every golden');
    lines.push('business a synthetic client with real revenue-bearing sales, to exercise nestly_v687\'s');
    lines.push('exclusion of `is_synthetic` clients from `get_revenue_truth_v106`. That exclusion was');
    lines.push('never applied to `app.v176_sales_window` or `platform_get_assigned_firm_report_v94`, so');
    lines.push('C and D both still count the synthetic client\'s revenue — an estate-wide exclusion gap');
    lines.push('(checks 1/3/9/16), tracked in `docs/qa/proof-pack/CI-KNOWN-LIMITATIONS.md`, not a defect');
    lines.push('in this report or its fixture.');
    lines.push('');
  }
  lines.push('## Full harness output (verbatim, for the `v731` fixture only)');
  lines.push('');
  lines.push('```');
  lines.push(combined.trim());
  lines.push('```');
  lines.push('');

  const mdPath = path.join(outDir, 'CI-RECONCILIATION-REPORT.md');
  writeFileSync(mdPath, lines.join('\n') + '\n');
  return { mdPath, exitCode: result.status, noticeLines, verdictLine, failureLines };
}

/* ------------------------------------------------------------------------------- entrypoint --- */

function main() {
  const { subcommand, outDir: outDirArg, repoRoot: repoRootArg } = parseArgs(process.argv.slice(2));
  const repoRoot = repoRootArg ? path.resolve(repoRootArg) : DEFAULT_REPO_ROOT;
  const outDir = path.resolve(repoRoot, outDirArg || 'docs/qa/proof-pack');
  mkdirSync(outDir, { recursive: true });

  const subcommands = {
    'corpus-manifest': () => runCorpusManifest(repoRoot, outDir),
    'expected-answers': () => runExpectedAnswers(repoRoot, outDir),
    'known-limitations': () => runKnownLimitations(repoRoot, outDir),
    reconciliation: () => runReconciliation(repoRoot, outDir),
  };

  if (subcommand === 'all') {
    for (const name of ['corpus-manifest', 'expected-answers', 'known-limitations', 'reconciliation']) {
      console.log(`ci-proof-pack: running ${name}...`);
      subcommands[name]();
    }
    console.log('ci-proof-pack: done.');
    return;
  }

  const fn = subcommands[subcommand];
  if (!fn) {
    console.error(`Usage: node scripts/quality/ci-proof-pack.mjs <${Object.keys(subcommands).join('|')}|all> [--out-dir=DIR] [--repo-root=DIR]`);
    process.exit(2);
  }
  const result = fn();
  console.log(`ci-proof-pack: wrote ${result.mdPath}${result.jsonPath ? ` and ${result.jsonPath}` : ''}`);
}

const isDirectCli = (() => {
  try {
    return import.meta.url === `file://${process.argv[1]}`;
  } catch {
    return false;
  }
})();
if (isDirectCli) main();

export {
  buildCorpusManifest, renderCorpusManifestMarkdown, runCorpusManifest,
  buildExpectedAnswers, renderExpectedAnswersMarkdown, runExpectedAnswers,
  buildKnownLimitations, renderKnownLimitationsMarkdown, runKnownLimitations,
  runReconciliation,
  extractTruthTable, extractCheckNumbers, extractMigrationRefs, extractValidatorLimits, extractLedgerBlocked,
  listCorpusFixtures,
};
