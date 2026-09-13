/* nestly_v888 — `npm run test:browser` must also run the node:test files that skip without a driver.
 *
 * Why this file exists: tests/business-ui/v750-tier-dialog-alignment.test.mjs skips itself when no
 * Playwright driver resolves, which is how `npm test` runs in CI — so it reported green while
 * timing out on an empty page for anyone who did attach a browser. The runner now executes those
 * files with the driver in the environment. These tests guard the two properties that make that
 * worth anything: the list is DISCOVERED rather than written down, and an empty discovery FAILS.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { readdirSync } from 'node:fs';
import { join } from 'node:path';

const runnerPath = new URL('../../scripts/quality/run-browser-checks.mjs', import.meta.url);
const runner = readFileSync(runnerPath, 'utf8');
const repoRoot = new URL('../../', import.meta.url);

/* The same scan the runner performs, re-implemented here so the expectation is derived from the
   tree rather than copied from the runner — a test that restated the runner's own list would pass
   even if both were wrong together. */
function driverDependentTests() {
  const testsRoot = join(repoRoot.pathname, 'tests');
  return readdirSync(testsRoot, { recursive: true })
    .filter(entry => String(entry).endsWith('.test.mjs'))
    .filter(entry => /PLAYWRIGHT_MODULE|playwright-core/
      .test(readFileSync(join(testsRoot, String(entry)), 'utf8')))
    .map(entry => join('tests', String(entry)))
    .sort();
}

test('there are driver-dependent test files, and they are the ones that silently skip', () => {
  const found = driverDependentTests();
  assert.ok(found.length >= 1, 'the scan found nothing — either tests/ moved or the scan is wrong');
  assert.ok(found.includes('tests/business-ui/v750-tier-dialog-alignment.test.mjs'),
    'the file whose silent skip prompted all of this must be among them');
});

test('the runner discovers them instead of carrying a written-down list', () => {
  assert.match(runner, /async function discoverDriverDependentTests\(\)/);
  assert.match(runner, /PLAYWRIGHT_MODULE\|playwright-core/,
    'discovery keys off the driver reference itself, so a new browser test is picked up for free');
  /* A hardcoded list is the same defect one level up: the next such test would be added, skip
     forever, and nobody would notice. */
  for (const file of driverDependentTests()) {
    assert.ok(!runner.includes(`'${file}'`),
      `${file} is named literally in the runner — the list must be discovered, not written down`);
  }
});

test('an empty discovery is a failure, never "all passed"', () => {
  const guard = runner.slice(runner.indexOf('if (!driverTests.length)'));
  assert.match(guard.slice(0, 400), /failed \+= 1/,
    'a scan that finds nothing means the runner stopped covering what it exists to cover');
});

test('the discovered files run with the driver in their environment', () => {
  assert.match(runner, /runNodeTest\(driverTests, \{ \.\.\.process\.env, PLAYWRIGHT_MODULE: driver\.specifier \}\)/);
});

test('the harness server resolves assets from production’s docroot too', () => {
  /* app/ is the docroot in production, so the page asks for /media/…. Serving only the repo root
     404s those, which reads as a console error and fails an unrelated assertion. */
  assert.match(runner, /const DOCROOTS = \[repoRoot, join\(repoRoot, 'app'\)\]/);
});

test('a missing driver still skips loudly and does not block the build', () => {
  assert.match(runner, /BROWSER CHECKS SKIPPED — NOT PASSED\./);
  assert.match(runner, /report green by not running at all/,
    'the banner must say that a green npm test does not cover these');
  assert.match(runner, /process\.exit\(0\)/, 'a machine without Chromium must not fail the build');
});
