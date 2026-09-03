// Regression floor for scripts/quality/ci-proof-pack.mjs — the CI-100 proof-pack generator
// (docs/qa/CI-100-CHECKLIST.md required-proof-pack items 1, 4, 5, 7, 9, 10, 14).
//
// WHY THIS EXISTS. All four artefacts under docs/qa/proof-pack/ (CI-CORPUS-MANIFEST.{md,json},
// CI-EXPECTED-ANSWERS.md, CI-KNOWN-LIMITATIONS.md, CI-RECONCILIATION-REPORT.md) are GENERATED,
// not hand-authored, specifically so they cannot drift out of sync with the fixtures, migrations
// and validator they describe. A generated artefact that nobody re-generates and diffs is exactly
// as driftable as a hand-authored one — this file is what keeps the promise real.
//
// THREE OF FOUR are deterministic given the same repository state (corpus-manifest,
// expected-answers, known-limitations): this file regenerates them to an isolated temp copy of
// the relevant tree and asserts byte-identity with the committed copies under docs/qa/proof-pack/.
// A change to any input file (a new/edited corpus fixture, the validator's HONEST LIMIT comments,
// the owner-issue ledger, or the hand-maintained known-limitations JSON) that is not accompanied
// by re-running the generator now fails this test loudly, instead of shipping a stale document.
//
// THE FOURTH (reconciliation) is explicitly NOT byte-identity-tested — ci-proof-pack.mjs's own
// header explains why: it embeds real harness timing and fresh gen_random_uuid() business IDs on
// every run, which are never identical across two runs even with nothing else changed. Testing it
// here instead RUNS the real harness (db/tests/executed/v731_reconciliation_report.sql, driven
// directly through scripts/db-tests/lib.mjs's own ScratchCluster — the same one the generator
// itself now uses; see the CAPTURE FIX comment on runReconciliationHarness()) and pins the numbers
// it produces.
//
// UPDATED 2026-09-02: this test used to pin an honest, found FAIL — get_dashboard_summary_v155,
// app.v176_sales_window and platform_get_assigned_firm_report_v94 did not exclude an
// is_synthetic client's revenue the way get_revenue_truth_v106 did since nestly_v687. That gap is
// now CLOSED (nestly_v734/v737/v740/v742, landed 2026-09-02, swept the estate) — v731 itself now
// passes, and this test asserts the new truth: every one of B/C/D/E reconciles to A at exactly
// 100.0 for every seeded business. A regression back to a gap must fail this test loudly, not be
// silently re-tolerated.
//
// This test spawns a real (throwaway) Postgres cluster via scripts/db-tests/run.mjs and can take
// several minutes; it is intentionally not run as part of a fast/default test filter — invoke it
// directly (`node --test tests/phase0-foundation/ci-proof-pack.test.mjs`) or via the harness's own
// CI job, the same way other tests/*db-tests* files are run.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, cp } from 'node:fs/promises';
import { existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const repoRoot = fileURLToPath(new URL('../..', import.meta.url));
const generatorRelPath = 'scripts/quality/ci-proof-pack.mjs';

async function isolatedProofPackRepo(t) {
  const root = await mkdtemp(path.join(tmpdir(), 'peekaa-ci-proof-pack-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));

  await mkdir(path.join(root, 'db/tests'), { recursive: true });
  await mkdir(path.join(root, 'docs/qa'), { recursive: true });
  await mkdir(path.join(root, 'scripts/quality'), { recursive: true });
  await mkdir(path.join(root, 'supabase/functions/ai-firm-reports'), { recursive: true });

  await cp(path.join(repoRoot, 'db/tests/executed'), path.join(root, 'db/tests/executed'), { recursive: true });
  await cp(path.join(repoRoot, 'docs/qa/OWNER-ISSUE-LEDGER.md'), path.join(root, 'docs/qa/OWNER-ISSUE-LEDGER.md'));
  await cp(
    path.join(repoRoot, 'supabase/functions/ai-firm-reports/validate.mjs'),
    path.join(root, 'supabase/functions/ai-firm-reports/validate.mjs')
  );
  await cp(path.join(repoRoot, generatorRelPath), path.join(root, generatorRelPath));
  await cp(
    path.join(repoRoot, 'scripts/quality/ci-proof-pack.known-limitations.json'),
    path.join(root, 'scripts/quality/ci-proof-pack.known-limitations.json')
  );

  return root;
}

function runGenerator(root, subcommand) {
  const outDir = path.join(root, 'docs/qa/proof-pack');
  return spawnSync(process.execPath, [generatorRelPath, subcommand, `--repo-root=${root}`, `--out-dir=${outDir}`], {
    cwd: root,
    encoding: 'utf8',
  });
}

async function assertByteIdentical(subcommand, generatedPath, committedRelPath) {
  const [generated, committed] = await Promise.all([
    readFile(generatedPath, 'utf8'),
    readFile(path.join(repoRoot, committedRelPath), 'utf8'),
  ]);
  assert.equal(generated, committed, `${committedRelPath} is stale — regenerate with ` +
    `node scripts/quality/ci-proof-pack.mjs ${subcommand}`);
}

test('corpus-manifest regenerates byte-identical to the committed CI-CORPUS-MANIFEST.md/.json', async (t) => {
  const root = await isolatedProofPackRepo(t);
  const result = runGenerator(root, 'corpus-manifest');
  assert.equal(result.status, 0, result.stderr);

  await assertByteIdentical('corpus-manifest', path.join(root, 'docs/qa/proof-pack/CI-CORPUS-MANIFEST.md'), 'docs/qa/proof-pack/CI-CORPUS-MANIFEST.md');
  await assertByteIdentical('corpus-manifest', path.join(root, 'docs/qa/proof-pack/CI-CORPUS-MANIFEST.json'), 'docs/qa/proof-pack/CI-CORPUS-MANIFEST.json');

  // Sanity on the JSON shape, independent of the exact committed content: every item names a
  // real fixture file, a well-formed SHA-256, and a harness command that would actually run it.
  const manifest = JSON.parse(await readFile(path.join(root, 'docs/qa/proof-pack/CI-CORPUS-MANIFEST.json'), 'utf8'));
  assert.ok(manifest.itemCount >= 40, `expected a healthy number of corpus fixtures, got ${manifest.itemCount}`);
  for (const item of manifest.items) {
    assert.match(item.sha256, /^[a-f0-9]{64}$/, item.file);
    assert.ok(existsSync(path.join(repoRoot, item.file)), `${item.file} does not exist in the real repo`);
    assert.match(item.harness_command, /^LC_ALL=C node scripts\/db-tests\/run\.mjs --filter=.+ --migrated-only$/);
  }
});

test('expected-answers regenerates byte-identical to the committed CI-EXPECTED-ANSWERS.md', async (t) => {
  const root = await isolatedProofPackRepo(t);
  const result = runGenerator(root, 'expected-answers');
  assert.equal(result.status, 0, result.stderr);
  await assertByteIdentical('expected-answers', path.join(root, 'docs/qa/proof-pack/CI-EXPECTED-ANSWERS.md'), 'docs/qa/proof-pack/CI-EXPECTED-ANSWERS.md');
});

test('known-limitations regenerates byte-identical to the committed CI-KNOWN-LIMITATIONS.md', async (t) => {
  const root = await isolatedProofPackRepo(t);
  const result = runGenerator(root, 'known-limitations');
  assert.equal(result.status, 0, result.stderr);
  await assertByteIdentical('known-limitations', path.join(root, 'docs/qa/proof-pack/CI-KNOWN-LIMITATIONS.md'), 'docs/qa/proof-pack/CI-KNOWN-LIMITATIONS.md');
});

test('known-limitations extraction does not pick up the ledger\'s own lifecycle legend row', async (t) => {
  const root = await isolatedProofPackRepo(t);
  const result = runGenerator(root, 'known-limitations');
  assert.equal(result.status, 0, result.stderr);
  const md = await readFile(path.join(root, 'docs/qa/proof-pack/CI-KNOWN-LIMITATIONS.md'), 'utf8');
  // The ledger's lifecycle table has a row "| `BLOCKED` | A named external input or authority is
  // required. |" describing the STATE, not an issue — regression-guard against extracting it as
  // if `BLOCKED` were itself an issue ID.
  assert.doesNotMatch(md, /\| `BLOCKED` \|/, 'the extractor picked up the ledger legend row, not a real issue');
});

test('known-limitations does not swallow a plural "honest limits" meta-sentence into a giant block', async (t) => {
  const root = await isolatedProofPackRepo(t);
  const result = runGenerator(root, 'known-limitations');
  assert.equal(result.status, 0, result.stderr);
  const md = await readFile(path.join(root, 'docs/qa/proof-pack/CI-KNOWN-LIMITATIONS.md'), 'utf8');
  // validate.mjs's file header says "...and each one's honest limits are written down next to
  // it..." (plural, describing the file's OWN convention) a few lines above its real header
  // banner ("WHY THIS EXISTS..."). A word-boundary regression: if the extractor's \b guard around
  // "limit" ever regresses to a bare substring match, that sentence pulls the entire ~39-line file
  // banner in as a spurious "declared limit" block; assert no captured block is implausibly large.
  const blockLineCounts = [...md.matchAll(/```\n([\s\S]*?)\n```/g)].map((m) => m[1].split('\n').length);
  assert.ok(blockLineCounts.length > 0, 'expected at least one extracted validator block');
  for (const count of blockLineCounts) {
    assert.ok(count < 60, `an extracted HONEST LIMIT block is ${count} lines — looks like the word-boundary guard regressed and swallowed the file's header banner`);
  }
});

test('reconciliation: a real harness run of v731 reconciles A/B/C/D/E exactly (100.0) for every business', { timeout: 600_000 }, async (t) => {
  const root = await isolatedProofPackRepo(t);
  // The reconciliation subcommand needs the actual product schema/RPCs, not just the isolated
  // fixture copy above — point it at the REAL repo root (read-only from this test's point of
  // view: runReconciliationHarness() only spins up its own throwaway ScratchCluster, via
  // scripts/db-tests/lib.mjs, and never touches production) so `app.seed_golden_business_v682`,
  // `get_revenue_truth_v106` and friends exist.
  const outDir = path.join(root, 'docs/qa/proof-pack');
  await mkdir(outDir, { recursive: true });
  const result = spawnSync(process.execPath, [
    path.join(repoRoot, generatorRelPath), 'reconciliation', `--repo-root=${repoRoot}`, `--out-dir=${outDir}`,
  ], { cwd: repoRoot, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 600_000 });
  assert.equal(result.status, 0, `generator process should exit 0 on a clean v731 pass: ${result.stderr}`);

  const report = await readFile(path.join(outDir, 'CI-RECONCILIATION-REPORT.md'), 'utf8');

  // Three businesses, one per seeded sector, each with a captured NOTICE line — scoped to the
  // dedicated "Per-business reconciliation" section only. The same lines are ALSO reproduced
  // inside the "Full harness output" verbatim dump further down the same report (stderr, again
  // in full), so counting matches over the WHOLE file overcounts; this section is the report's
  // own single source for the parsed, one-row-per-business table.
  const sectionStart = report.indexOf('## Per-business reconciliation');
  const sectionEnd = report.indexOf('## Machine-readable per-business table', sectionStart);
  assert.ok(sectionStart !== -1 && sectionEnd !== -1, 'report is missing its own section markers');
  const section = report.slice(sectionStart, sectionEnd);
  const noticeLines = section.split('\n').filter((l) => l.includes('v731 | biz='));
  assert.equal(noticeLines.length, 3, section);

  const parsed = noticeLines.map((line) => {
    const m = line.match(
      /biz=(\d+) sector=(\w+) business_id=([0-9a-f-]+) \| A_recorded=(\d+) B_dashboard=(\d+) C_sales_window=(\d+) D_platform=(\d+) E_direct_sql=(\d+) \| pct_B=([\d.]+) pct_C=([\d.]+) pct_D=([\d.]+) pct_E=([\d.]+)/
    );
    assert.ok(m, `unparseable NOTICE line: ${line}`);
    return {
      biz: Number(m[1]), sector: m[2], a: Number(m[4]), b: Number(m[5]), c: Number(m[6]), d: Number(m[7]),
      e: Number(m[8]), pctB: Number(m[9]), pctC: Number(m[10]), pctD: Number(m[11]), pctE: Number(m[12]),
    };
  });

  assert.deepEqual(parsed.map((p) => p.sector), ['fnb', 'salon', 'retail']);

  for (const p of parsed) {
    // Every reader now excludes an is_synthetic client's revenue the same way
    // get_revenue_truth_v106 does (nestly_v687/v734/v737/v740/v742) — A, B, C, D and E must all
    // agree exactly, and every reconciliation percentage must read exactly 100.0. This is the
    // hard bar the checklist itself sets ("every discrepancy explained and fixed" — Section A);
    // a regression back to a partial exclusion must fail this test, not be re-tolerated.
    assert.equal(p.b, p.a, `biz#${p.biz}(${p.sector}): B should equal A exactly`);
    assert.equal(p.c, p.a, `biz#${p.biz}(${p.sector}): C should equal A exactly`);
    assert.equal(p.d, p.a, `biz#${p.biz}(${p.sector}): D should equal A exactly`);
    assert.equal(p.e, p.a, `biz#${p.biz}(${p.sector}): E should equal A exactly`);
    assert.equal(p.pctB, 100.0, `biz#${p.biz}(${p.sector}): pct_B should read exactly 100.0`);
    assert.equal(p.pctC, 100.0, `biz#${p.biz}(${p.sector}): pct_C should read exactly 100.0`);
    assert.equal(p.pctD, 100.0, `biz#${p.biz}(${p.sector}): pct_D should read exactly 100.0`);
    assert.equal(p.pctE, 100.0, `biz#${p.biz}(${p.sector}): pct_E should read exactly 100.0`);
  }

  // The fixture's own machine-readable `select ... from _report` table is embedded verbatim too
  // — assert its section exists and carries the same three business_ids the NOTICE lines named,
  // so the two representations (RAISE NOTICE and SELECT) are proven consistent, not just present.
  const tableSectionStart = report.indexOf('## Machine-readable per-business table');
  const tableSectionEnd = report.indexOf('## Verdict', tableSectionStart);
  assert.ok(tableSectionStart !== -1 && tableSectionEnd !== -1, 'report is missing the machine-readable table section');
  const tableSection = report.slice(tableSectionStart, tableSectionEnd);
  for (const p of parsed) {
    assert.ok(tableSection.includes(p.sector), `machine-readable table section missing sector ${p.sector}`);
  }
  assert.match(tableSection, /\(3 rows\)/, 'expected the _report select to report exactly 3 rows');

  const verdictStart = report.indexOf('## Verdict');
  const verdictSection = report.slice(verdictStart, verdictStart + 400);
  assert.match(verdictSection, /^PASS — v731 reconciliation/m,
    `expected the Verdict section to record a clean PASS:\n${verdictSection}`);
  assert.doesNotMatch(verdictSection, /FAIL/, `Verdict section should not mention FAIL on a clean run:\n${verdictSection}`);

  // Environment table sanity: commit SHA, Postgres version and harness watermark are all present
  // and well-formed (item 1's frozen-record test cross-checks the SHA against git independently;
  // here we only need proof this report itself carries them, not a fixed value).
  assert.match(report, /\| Commit SHA \| `[0-9a-f]{7,40}` \|/, 'report is missing a well-formed commit SHA row');
  assert.match(report, /\| Postgres \(scratch harness server\) \| PostgreSQL \d/, 'report is missing a Postgres version row');
  assert.match(report, /\| Harness watermark \(`scripts\/db-tests\/lib\.mjs` `SNAPSHOT_WATERMARK_VERSION`\) \| \d+ \|/, 'report is missing the harness watermark row');
});

// Strip the three lines CI-FROZEN-COMMIT.md's own header says are EXPECTED to change on every
// regeneration (HEAD SHA, Branch, Record generated) so two regenerations minutes apart — or a
// regeneration on a different commit whose manifests/watermark/migration-count are unchanged —
// can still be compared for everything else.
function stripFrozenVariableLines(text) {
  return text
    .replace(/^\| HEAD SHA \| `[0-9a-f]{40}` \|$/m, '| HEAD SHA | `<stripped>` |')
    .replace(/^\| Branch \| `[^`]*` \|$/m, '| Branch | `<stripped>` |')
    .replace(/^\| Commit date \| .* \|$/m, '| Commit date | <stripped> |')
    .replace(/^\| Record generated \| .* \|$/m, '| Record generated | <stripped> |');
}

test('frozen: regenerates equal to the committed CI-FROZEN-COMMIT.md modulo its own declared-variable lines', { timeout: 120_000 }, async (t) => {
  const root = await isolatedProofPackRepo(t);
  // item 1 needs git (rev-parse HEAD/branch/commit date) and the real db/migrations +
  // supabase/ manifests, none of which isolatedProofPackRepo copies — point at the real repo,
  // same as the reconciliation test above.
  const outDir = path.join(root, 'docs/qa/proof-pack');
  await mkdir(outDir, { recursive: true });
  const result = spawnSync(process.execPath, [
    path.join(repoRoot, generatorRelPath), 'frozen', `--repo-root=${repoRoot}`, `--out-dir=${outDir}`,
  ], { cwd: repoRoot, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);

  const generated = await readFile(path.join(outDir, 'CI-FROZEN-COMMIT.md'), 'utf8');
  const committed = await readFile(path.join(repoRoot, 'docs/qa/proof-pack/CI-FROZEN-COMMIT.md'), 'utf8');
  assert.equal(
    stripFrozenVariableLines(generated), stripFrozenVariableLines(committed),
    'CI-FROZEN-COMMIT.md is stale — regenerate with node scripts/quality/ci-proof-pack.mjs frozen ' +
    '(comparison excludes HEAD SHA/Branch/Commit date/Record generated, which are expected to move)'
  );

  // The three lines just stripped are not unchecked: HEAD SHA must equal a live `git rev-parse
  // HEAD` right now, so the test is green at any HEAD (not pinned to one commit) while still
  // proving the generator reads the real repo rather than echoing a stale value.
  const liveSha = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: repoRoot, encoding: 'utf8' }).stdout.trim();
  const shaMatch = generated.match(/\| HEAD SHA \| `([0-9a-f]{40})` \|/);
  assert.ok(shaMatch, 'generated report is missing a well-formed HEAD SHA row');
  assert.equal(shaMatch[1], liveSha, 'generated HEAD SHA does not match a live git rev-parse HEAD');

  // Both manifest checksums must read MATCH — a MISMATCH is a real finding (a manifest edited
  // without regenerating its .sha256, or vice versa), not something this test should tolerate.
  assert.doesNotMatch(generated, /MISMATCH/, 'a manifest .sha256 does not match its own manifest content');
  assert.match(generated, /\| `db\/migrations\/migration-order\.manifest\.json` \|.*\| MATCH \|/, 'db manifest checksum row missing/mismatched');
  assert.match(generated, /\| `supabase\/canonical-migration-order\.manifest\.json` \|.*\| MATCH \|/, 'supabase manifest checksum row missing/mismatched');

  // The 2026-09-02 migration count is cross-checked against an independent readdirSync of the
  // real db/migrations directory, not merely "some number was printed".
  const actualCount = readdirSync(path.join(repoRoot, 'db/migrations'))
    .filter((f) => f.startsWith('20260902_') && f.endsWith('.sql')).length;
  const countMatch = generated.match(/Migrations dated 2026-09-02 \(`db\/migrations\/20260902_\*\.sql`\) \| (\d+) \|/);
  assert.ok(countMatch, 'generated report is missing the 2026-09-02 migration count row');
  assert.equal(Number(countMatch[1]), actualCount, 'generated migration count disagrees with an independent readdirSync');
  assert.equal(new Set(generated.match(/^\* `db\/migrations\/20260902_[^`]+\.sql`$/gm) || []).size, actualCount,
    'the listed migration filenames do not agree with the header count');
});

test('ai-factuality: rule list, enforcement path and live golden-gate/test-suite results are all captured', { timeout: 180_000 }, async (t) => {
  const root = await isolatedProofPackRepo(t);
  // Needs the real enforce.mjs, index.ts, golden-gate script and tests/ai-reports/*.test.mjs —
  // none of which isolatedProofPackRepo copies — point at the real repo.
  const outDir = path.join(root, 'docs/qa/proof-pack');
  await mkdir(outDir, { recursive: true });
  const result = spawnSync(process.execPath, [
    path.join(repoRoot, generatorRelPath), 'ai-factuality', `--repo-root=${repoRoot}`, `--out-dir=${outDir}`,
  ], { cwd: repoRoot, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 180_000 });
  assert.equal(result.status, 0, `expected a clean run (golden gate clean, every ai-reports test passing): ${result.stderr}`);

  const report = await readFile(path.join(outDir, 'CI-AI-FACTUALITY-REPORT.md'), 'utf8');

  // All 10 RULES entries validate.mjs currently declares must be named, each with its checking
  // function — this is the generator's own cross-check (buildAiFactuality throws if it can't find
  // a RULES key's function, or a curated entry with no matching RULES key), so a passing run here
  // already proves the map has not drifted; this just proves it made it into the document.
  for (const key of [
    'NUMERIC', 'POPULATION', 'CAUSAL', 'CONFIDENCE', 'LIMITATION', 'ENTITY', 'STRUCTURE',
    'COHORT', 'CAUSAL_BINDING', 'ASSOCIATION_MARKER',
  ]) {
    assert.match(report, new RegExp('`RULES\\.' + key + '`'), `rule list missing RULES.${key}`);
  }

  // Prompt version cross-checked against an independent read of index.ts.
  const indexTs = await readFile(path.join(repoRoot, 'supabase/functions/ai-firm-reports/index.ts'), 'utf8');
  const promptVersion = indexTs.match(/PROMPT_VERSION\s*=\s*'([^']+)'/)[1];
  assert.match(report, new RegExp('\\*\\*`' + promptVersion + '`\\*\\*'), 'report does not name the live PROMPT_VERSION');

  // Enforcement path: both entry points named.
  assert.match(report, /decideNarrativeOutcome/);
  assert.match(report, /decideGenerationFailure/);

  // Golden gate ran live and came back clean.
  assert.match(report, /ai-report-golden-gate: OK — 6\/6 packs clean/, 'golden-gate output missing or not clean');
  assert.match(report, /Exit code: \*\*0\*\*/);

  // Test counts: fail must be exactly 0, and tests/pass must both be a real positive number and
  // agree with each other (a clean run), read from the table row this generator itself renders.
  const counts = report.match(/\| (\d+) \| (\d+) \| (\d+) \| (\d+) \| (\d+) \| (\d+) \|/);
  assert.ok(counts, 'report is missing its own tests/pass/fail/cancelled/skipped/todo table row');
  const [, tests, pass, fail] = counts.map(Number);
  assert.ok(tests > 0, 'expected a positive test count');
  assert.equal(fail, 0, 'expected zero failing tests in tests/ai-reports/*.test.mjs');
  assert.equal(pass, tests, 'expected every test to have passed');
  assert.match(report, /Process exit code: \*\*0\*\*/);
});

test('isolation: all seven access-boundary fixtures run live and reconcile to PASS', { timeout: 600_000 }, async (t) => {
  const root = await isolatedProofPackRepo(t);
  // Needs the full product schema/migrations and the seven db/tests/executed fixtures — point at
  // the real repo, same as reconciliation. Spins its own ScratchCluster (throwaway, own temp
  // dir/port) via scripts/db-tests/lib.mjs — no production access.
  const outDir = path.join(root, 'docs/qa/proof-pack');
  await mkdir(outDir, { recursive: true });
  const result = spawnSync(process.execPath, [
    path.join(repoRoot, generatorRelPath), 'isolation', `--repo-root=${repoRoot}`, `--out-dir=${outDir}`,
  ], { cwd: repoRoot, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 600_000 });
  assert.equal(result.status, 0, `expected every isolation fixture to run and PASS: ${result.stderr}`);

  const report = await readFile(path.join(outDir, 'CI-ISOLATION-REPORT.md'), 'utf8');

  const fixtures = [
    'v667_ci_access_boundaries.sql', 'v713_corpus_evidence_pack.sql',
    'v720_corpus_evidence_pack_grants.sql', 'v721_corpus_one_ci_gate.sql',
    'v725_corpus_time_basis_shadow_gate.sql', 'v736_corpus_small_cell_principals.sql',
    'v741_corpus_roster_read_audit.sql',
  ];
  for (const f of fixtures) {
    assert.match(report, new RegExp('## `db/tests/executed/' + f + '`'), `report is missing a section for ${f}`);
  }

  // Every fixture's own section must carry a captured live verdict starting with PASS — never
  // the "no verdict line matched" fallback (a regression guard: an earlier version of this
  // generator's extraction regex missed v720/v736, which spell the dash after PASS as a literal
  // "--" rather than an em dash, and silently fell through to that fallback text).
  const sections = report.split(/^## `db\/tests\/executed\//m).slice(1);
  assert.equal(sections.length, fixtures.length);
  for (const section of sections) {
    const verdictIdx = section.indexOf('**Live harness verdict:**');
    assert.ok(verdictIdx !== -1, 'a fixture section is missing its Live harness verdict block');
    const verdictBlock = section.slice(verdictIdx, verdictIdx + 400);
    assert.doesNotMatch(verdictBlock, /no verdict line matched/, `verdict extraction fell through:\n${verdictBlock}`);
    assert.doesNotMatch(verdictBlock, /did not run/, `fixture did not run:\n${verdictBlock}`);
    assert.match(verdictBlock, /```\nPASS\b/, `expected a captured PASS verdict:\n${verdictBlock}`);
  }

  // Regression guard for the principal x reader matrix null-byte / line-boundary bug found while
  // building this report: at least one matrix cell across the whole report must be non-empty
  // (some principal was actually credited with at least one reader call), not every row reading
  // blank the way it did when the extractor's per-line regex never matched a multi-line
  // set_config(...) / json_build_object('sub', ...) split.
  assert.match(report, /\| `u_[a-zA-Z0-9_]+` \| [^|]*\d[^|]*\|/, 'no principal x reader matrix cell carries a non-zero count anywhere in the report');

  assert.match(report, /^PASS — every isolation fixture in scope ran and reconciled to PASS$/m,
    'expected the derived Section J scorer outcome to read PASS');
});
