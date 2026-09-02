/* CI-100-CHECKLIST proof-pack items 11/12 — the checked-in HTML pages under tests/browser/ci-proof/
 * must be byte-identical to a fresh regeneration from scripts/quality/ci-proof-screenshots.mjs's
 * exported buildCiProofPages() (same posture as v181-onboarding-board-fixture-parity.test.mjs and
 * reward-overview-fixture-parity.test.mjs: a page can only drift arbitrarily far from
 * app/app.js / app/platform-console.js if nothing diffs it against a fresh build).
 *
 * This test does NOT regenerate or compare PNGs — screenshots are Chrome-rendered binaries, not
 * something a fresh Node process can rebuild byte-identically (font hinting/AA are platform-
 * dependent even before considering that the driver may be unavailable in this environment at
 * all — see the script's own header). Instead it asserts every PNG named in the committed index
 * (docs/qa/proof-pack/SCREENSHOTS.md) exists on disk and is over 5 KB, the same floor
 * CI-100-CHECKLIST's own scoring rule uses ("Missing the UI/runtime proof" scores zero) to reject
 * an accidentally-blank capture.
 *
 * WHEN THIS FAILS ON THE HTML CHECK: app/app.js, app/platform-console.js, app/index.html,
 * app/app.css, app/revenue-truth.css or app/platform-console.css changed and the checked-in pages
 * no longer match. Refresh with: node scripts/quality/ci-proof-screenshots.mjs
 *
 * WHEN THIS FAILS ON THE PNG CHECK: the screenshots have not been captured yet in this
 * environment (playwright-core/playwright unavailable — the index's "Screenshot capture" line
 * will say PENDING), or a capture regressed. Re-run the same command with a Playwright driver
 * available; see the script header for how it locates one (PLAYWRIGHT_MODULE env override, else
 * playwright-core then playwright).
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { buildCiProofPages, notRenderable } from '../../scripts/quality/ci-proof-screenshots.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

test('CI proof-pack: every HTML page under tests/browser/ci-proof/ is byte-identical to a fresh build', () => {
  const manifest = buildCiProofPages();
  assert.ok(manifest.length > 0, 'buildCiProofPages() must return at least one state');
  for (const state of manifest) {
    assert.ok(existsSync(state.filePath), `missing committed page for state "${state.id}": ${state.filePath}`);
    const committed = readFileSync(state.filePath, 'utf8');
    assert.equal(
      committed, state.html,
      `stale page for state "${state.id}" — regenerate with: node scripts/quality/ci-proof-screenshots.mjs`
    );
  }
});

test('CI proof-pack: the state list covers both answer states and failure/abstention states', () => {
  const manifest = buildCiProofPages();
  const ids = manifest.map((s) => s.id);
  // Answer states (checklist item 11).
  for (const id of [
    'funnel-conversion-mature', 'demographics-cells', 'behaviour-weekday',
    'opportunities-extended', 'category-mix-whale', 'visit-day-drilldown',
    'dashboard-revenue-tile', 'consultative-brief-ok'
  ]) {
    assert.ok(ids.includes(id), `answer state "${id}" must be present`);
  }
  // Failure/abstention states (checklist item 12).
  for (const id of [
    'rpc-42501-refusal', 'panel-rpc-error', 'opportunities-abstention-only',
    'opportunities-rpc-error', 'category-mix-below-floor', 'consultative-brief-unavailable'
  ]) {
    assert.ok(ids.includes(id), `failure/abstention state "${id}" must be present`);
  }
});

test('CI proof-pack: the documented not-renderable gap is still accurately grepped against current source', () => {
  assert.ok(notRenderable.some((g) => g.id === 'stale-freshness-envelope'));
  const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');
  const appBusiness = existsSync(join(root, 'app', 'app-business.js'))
    ? readFileSync(join(root, 'app', 'app-business.js'), 'utf8') : '';
  const consoleJs = readFileSync(join(root, 'app', 'platform-console.js'), 'utf8');
  const readsFreshnessKey = /\bfreshness\.[a-z_]+|\.freshness\b(?!\s*[=:]\s*(?:jsonb_build_object|null))/i;
  for (const [label, src] of [['app.js', app], ['app-business.js', appBusiness], ['platform-console.js', consoleJs]]) {
    assert.ok(
      !/payload\.freshness|report\.freshness|\.freshness\.(?:stale|data_as_of|age_hours|note)/.test(src),
      `${label} now appears to read the v722 freshness envelope — the "stale-freshness-envelope" ` +
      'state is no longer a documented gap and should be built as a real screenshot instead'
    );
  }
});

/* -------------------------------------------------------------------------------------------
   PNG existence/size/integrity — every screenshot named in the committed index must exist, be
   over 5 KB (CI-100-CHECKLIST's own floor for rejecting an accidentally-blank capture), and
   have the sha256 the index claims for it. The capture step (scripts/quality/ci-proof-
   screenshots.mjs's CLI path, via a Playwright driver) is not itself re-run here — this test
   only proves the committed evidence is real and internally consistent.
   ------------------------------------------------------------------------------------------- */
const indexPath = join(root, 'docs', 'qa', 'proof-pack', 'SCREENSHOTS.md');

test('CI proof-pack: the screenshot index reports a completed (non-PENDING) capture', () => {
  assert.ok(existsSync(indexPath), 'docs/qa/proof-pack/SCREENSHOTS.md must exist — run node scripts/quality/ci-proof-screenshots.mjs');
  const indexMd = readFileSync(indexPath, 'utf8');
  assert.doesNotMatch(indexMd, /Screenshot capture: PENDING/,
    'the index still reports PENDING — capture the PNGs with a Playwright driver ' +
    '(PLAYWRIGHT_MODULE=<install>/node_modules/playwright-core/index.js node scripts/quality/ci-proof-screenshots.mjs) ' +
    'before this proof pack can close checklist items 11/12');
});

test('CI proof-pack: every state x viewport has a PNG row in the index, and every PNG exists, is over 5 KB, and matches its claimed sha256', () => {
  const indexMd = readFileSync(indexPath, 'utf8');
  const manifest = buildCiProofPages();
  const rowPattern = /\|\s*([a-z0-9-]+)\s*\|[^|]*\|[^|]*\|\s*([a-z0-9-]+)\s*\|\s*(docs\/qa\/proof-pack\/screenshots\/[a-z0-9.-]+\.png)\s*\|\s*([0-9a-f]{64})\s*\|/g;
  const rows = new Map();
  for (const [, stateId, viewport, relPath, sha] of indexMd.matchAll(rowPattern)) {
    rows.set(`${stateId}|${viewport}`, { relPath, sha });
  }
  assert.ok(rows.size > 0, 'the index must list at least one PNG row with a 64-hex-char sha256');

  for (const state of manifest) {
    for (const viewport of ['mobile-390x844', 'desktop-1280x800']) {
      const row = rows.get(`${state.id}|${viewport}`);
      assert.ok(row, `index is missing a row for ${state.id} (${viewport})`);
      const pngPath = join(root, row.relPath);
      assert.ok(existsSync(pngPath), `${state.id} (${viewport}): PNG missing at ${row.relPath}`);
      assert.ok(statSync(pngPath).size > 5 * 1024, `${state.id} (${viewport}): PNG at ${row.relPath} is 5 KB or smaller`);
      const actualSha = createHash('sha256').update(readFileSync(pngPath)).digest('hex');
      assert.equal(actualSha, row.sha, `${state.id} (${viewport}): PNG contents no longer match the sha256 recorded in the index`);
    }
  }
});
