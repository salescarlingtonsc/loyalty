/**
 * The Rewards owner-page browser fixture must be byte-identical to a fresh regeneration.
 *
 * WHEN THIS FAILS: app/index.html, app/app.js or app/customer-ui.js changed and the checked-in
 * fixture no longer matches. That is the intended signal, not a bug. Refresh it with ONE
 * command from the repo root:
 *
 *     node tests/browser/generate-reward-overview-owner-visual.mjs
 *
 * (or `node scripts/quality/regen-visual-fixtures.mjs` to refresh every fixture at once, which
 * is what you want after a broad CSS change). Run `npm run bundle-stamp` first if you edited
 * app/app.js, so the generated surface bundles are current before the fixture is rebuilt.
 *
 * WHY IT EXISTS. tests/browser/reward-overview-owner-visual.html is the only executable
 * evidence that the Rewards owner page still renders. It had drifted 33 hunks behind
 * production, and the single test that referenced it read a SHA out of the STALE artifact and
 * checked that string appeared in some evidence markdown — so the suite passed while the
 * fixture was stale, and FAILED if anyone regenerated it. scripts/quality/regen-visual-
 * fixtures.mjs had a `git checkout --` line specifically to put it back. Six sibling fixtures
 * (v104, v129, v130, v131, v141, v145) already assert byte equality; this brings the Rewards
 * one in line with them, and the checkout line is gone.
 */
import assert from 'node:assert/strict';
import test from 'node:test';
import {readFile} from 'node:fs/promises';
import {buildRewardOverviewVisualFixture} from '../browser/generate-reward-overview-owner-visual.mjs';

const [app, componentLibrary, fixture] = await Promise.all([
  Promise.all([
    readFile(new URL('../../app/index.html', import.meta.url), 'utf8'),
    readFile(new URL('../../app/app.js', import.meta.url), 'utf8'),
  ]).then(parts => parts.join('\n')),
  readFile(new URL('../../app/customer-ui.js', import.meta.url), 'utf8'),
  readFile(new URL('../browser/reward-overview-owner-visual.html', import.meta.url), 'utf8'),
]);

test('reward overview fixture is byte-identical to a fresh build from current production source', () => {
  assert.equal(
    fixture,
    buildRewardOverviewVisualFixture(app, componentLibrary),
    'stale fixture — regenerate with: node tests/browser/generate-reward-overview-owner-visual.mjs'
  );
});

test('the fixture carries production source, not a hand-written copy of it', () => {
  assert.match(fixture, /name="production-source-sha256" content="[a-f0-9]{64}"/);
  /* The source hash must be of the CURRENT source. Recomputing it here would just restate the
     byte-equality test above; what this adds is that the fixture really did extract the
     production render path rather than embedding a mock of it. */
  assert.match(fixture, /async function growPage/);
  assert.match(fixture, /window\.__renderFromHashV421/);
});
