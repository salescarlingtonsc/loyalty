// Regression floor for scripts/quality/ci-proof-pack.mjs — the CI-100 proof-pack generator
// (docs/qa/CI-100-CHECKLIST.md required-proof-pack items 4, 5, 7, 14).
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
// here instead RUNS the real harness (scripts/db-tests/run.mjs --filter=v731 --migrated-only, the
// same command the generator itself shells out to) and pins the numbers it produces — including
// the honest FAIL: db/tests/executed/v731_reconciliation_report.sql's own header records a real,
// found discrepancy (get_dashboard_summary_v155 / app.v176_sales_window /
// platform_get_assigned_firm_report_v94 do not exclude an is_synthetic client's revenue the way
// get_revenue_truth_v106 does since nestly_v687), and this test pins THAT truth rather than a
// fabricated pass. If the underlying gap is ever fixed, this test's own numbers must be updated
// deliberately — a silent flip from FAIL to PASS here is itself worth noticing, not something to
// paper over with a loose assertion.
//
// This test spawns a real (throwaway) Postgres cluster via scripts/db-tests/run.mjs and can take
// several minutes; it is intentionally not run as part of a fast/default test filter — invoke it
// directly (`node --test tests/phase0-foundation/ci-proof-pack.test.mjs`) or via the harness's own
// CI job, the same way other tests/*db-tests* files are run.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, cp } from 'node:fs/promises';
import { existsSync } from 'node:fs';
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

test('reconciliation: a real harness run of v731 reconciles A and E exactly and pins the known B/C/D gap', { timeout: 600_000 }, async (t) => {
  const root = await isolatedProofPackRepo(t);
  // The reconciliation subcommand needs the actual product schema/RPCs, not just the isolated
  // fixture copy above — point it at the REAL repo root (read-only: it only spawns
  // scripts/db-tests/run.mjs, which itself only ever writes to its own throwaway Postgres
  // cluster) so `app.seed_golden_business_v682`, `get_revenue_truth_v106` and friends exist.
  const outDir = path.join(root, 'docs/qa/proof-pack');
  await mkdir(outDir, { recursive: true });
  const result = spawnSync(process.execPath, [
    path.join(repoRoot, generatorRelPath), 'reconciliation', `--repo-root=${repoRoot}`, `--out-dir=${outDir}`,
  ], { cwd: repoRoot, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 600_000 });
  assert.equal(result.status, 0, `generator process itself should exit 0 even when the harness reports a fixture FAIL: ${result.stderr}`);

  const report = await readFile(path.join(outDir, 'CI-RECONCILIATION-REPORT.md'), 'utf8');

  // Three businesses, one per seeded sector, each with a captured NOTICE line — scoped to the
  // dedicated "Per-business reconciliation" section only. The same lines are ALSO reproduced
  // (more than once — once inside the harness's FAIL block, once in its one-line summary) inside
  // the "Full harness output" verbatim dump further down the same report, so counting matches
  // over the WHOLE file overcounts; this section is the report's own single source for the
  // parsed, one-row-per-business table.
  const sectionStart = report.indexOf('## Per-business reconciliation');
  const sectionEnd = report.indexOf('## Verdict', sectionStart);
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
    // A (get_revenue_truth_v106) and E (direct SQL built to the SAME contract, excluding an
    // is_synthetic client's sales) must reconcile exactly — that is the entire point of E.
    assert.equal(p.e, p.a, `biz#${p.biz}(${p.sector}): E should equal A exactly`);
    assert.equal(p.pctE, 100.0, `biz#${p.biz}(${p.sector}): pct_E should read exactly 100.0`);

    // B (dashboard), C (AI sales window) and D (platform report) all still include the seeded
    // synthetic client's revenue — pinning the KNOWN, DOCUMENTED gap (see the fixture's own
    // "FINDING" header) rather than a fabricated 100.0. If a future migration closes this gap,
    // this assertion must be updated deliberately, not silently relaxed.
    assert.equal(p.b, p.c, `biz#${p.biz}(${p.sector}): B and C should currently read the same (both uncorrected)`);
    assert.equal(p.c, p.d, `biz#${p.biz}(${p.sector}): C and D should currently read the same (both uncorrected)`);
    assert.ok(p.b > p.a, `biz#${p.biz}(${p.sector}): B should currently exceed A (synthetic-client revenue included)`);
    assert.notEqual(p.pctB, 100.0, `biz#${p.biz}(${p.sector}): pct_B should NOT read 100.0 yet — this gap is not fixed`);
  }

  const verdictStart = report.indexOf('## Verdict');
  const verdictSection = report.slice(verdictStart, verdictStart + 300);
  assert.match(verdictSection, /FAIL/, `expected the Verdict section to record the honest FAIL:\n${verdictSection}`);
});
