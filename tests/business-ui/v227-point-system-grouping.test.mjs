/* V227 — "all points reward in this tab".
   The owner drew arrows from the milestone rewards, "Add another reward" and "Start from a
   template" onto the Point system row. Everything earned and spent in POINTS belongs together,
   so the scheme reads as one thing; rewards that have nothing to do with a points balance — a
   welcome offer for a first visit, a birthday benefit, a bring-back for someone who has
   drifted — are a separate group. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

const pointsStart = app.indexOf('Point system</div>');
const otherStart = app.indexOf('Other rewards</div>');
const growthStart = app.indexOf('Promotions &amp; growth</div>') >= 0
  ? app.indexOf('Promotions &amp; growth</div>')
  : app.indexOf('Promotions & growth</div>');
const points = app.slice(pointsStart, otherStart);
const other = app.slice(otherStart, growthStart);

test('V227 everything earned and spent in points is in one group', () => {
  assert.ok(pointsStart > 0 && otherStart > pointsStart && growthStart > otherStart,
    'the two groups must exist, in order, before Promotions & growth');
  for (const part of ['rewardJourney.earning', 'rewardJourney.classicReward',
    'rewardJourney.milestones', 'Add another reward', 'growTemplatesOpen', 'archivedRewards']) {
    assert.ok(points.includes(part), `Point system group is missing ${part}`);
  }
  // The old single "Loyalty & rewards" heading is gone, which is what mixed them.
  assert.doesNotMatch(app, /programme-category-title">Loyalty &amp; rewards</);
});

test('V227 rewards that do not use a points balance are their own group', () => {
  for (const part of ['welcomeOfferRowV215', 'rewardJourney.birthday', "kind:'bringback'"]) {
    assert.ok(other.includes(part), `Other rewards group is missing ${part}`);
  }
  // No leakage either way — that is the whole point of the split.
  assert.ok(!points.includes('welcomeOfferRowV215'));
  assert.ok(!other.includes('rewardJourney.milestones'));
});

test('V227 the regrouping did not unbalance the markup', () => {
  const segment = app.slice(pointsStart, growthStart);
  assert.equal((segment.match(/<div/g) || []).length, (segment.match(/<\/div>/g) || []).length,
    'the two category wrappers must each open and close');
});
