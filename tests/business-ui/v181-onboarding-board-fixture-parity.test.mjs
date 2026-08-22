/**
 * The Onboarding board browser fixture must be byte-identical to a fresh regeneration.
 *
 * WHEN THIS FAILS: app/platform-console.js, app/platform-console.css or app/customer-ui.css
 * changed and the checked-in fixture no longer matches. That is the intended signal, not a bug.
 * Refresh it with ONE command from the repo root:
 *
 *     node tests/browser/generate-v181-onboarding-board-visual.mjs
 *
 * (or `node scripts/quality/regen-visual-fixtures.mjs` to refresh every fixture at once).
 *
 * WHY IT EXISTS (nestly_v448, closes the second half of REG-009). regen-visual-fixtures.mjs's
 * own header comment named this exact gap: "tests/browser/v181-onboarding-board.html is
 * generated here too and still has no byte-equality test. That is a smaller version of the same
 * gap [as the Rewards owner page] and is worth closing next." Without this test, the fixture
 * could drift arbitrarily far behind app/platform-console.js — a real change to the onboarding
 * board's markup or drag wiring — and nothing would say so; the fixture would simply keep
 * showing whatever it showed the day it was last hand-regenerated. This mirrors
 * reward-overview-fixture-parity.test.mjs, the sibling test that closed the same gap for the
 * Rewards owner page.
 */
import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import {
  buildOnboardingBoardVisualFixture,
  readOnboardingBoardSources,
} from '../browser/generate-v181-onboarding-board-visual.mjs';

const [{ consoleSource, consoleCss, baseCss }, fixture] = await Promise.all([
  readOnboardingBoardSources(),
  readFile(new URL('../browser/v181-onboarding-board.html', import.meta.url), 'utf8'),
]);

test('v181 onboarding board fixture is byte-identical to a fresh build from current production source', () => {
  assert.equal(
    fixture,
    buildOnboardingBoardVisualFixture(consoleSource, consoleCss, baseCss),
    'stale fixture — regenerate with: node tests/browser/generate-v181-onboarding-board-visual.mjs'
  );
});

test('the fixture carries the real platform-console kanban/list/detail renderers, not a hand-written copy', () => {
  // A hand-written mock would stay green forever; these anchor the fixture to functions that
  // actually exist in app/platform-console.js and that the build ran through vm, not stubbed.
  assert.match(consoleSource, /operationalLanes/);
  assert.match(consoleSource, /prospectCardHtml/);
  assert.match(consoleSource, /prospectListTableHtml/);
  assert.match(consoleSource, /typedDetailHtml/);
  assert.match(fixture, /platform-kanban/);
  assert.match(fixture, /data-lane-drop=/);
  assert.match(fixture, /platform-prospect-card-compact/, 'expects at least one rendered compact card');
});
