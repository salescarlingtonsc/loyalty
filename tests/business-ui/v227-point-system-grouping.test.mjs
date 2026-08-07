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

/* V229 renamed the non-points group to Lifestyle rewards (the owner's word), split Promotions
   and Referrals into their own categories, and put a Tiered membership drill between points and
   lifestyle. The grouping this file protects is unchanged; only the boundary names moved. */
const pointsStart = app.indexOf('programme-category-title">Point system</div>');
const tiersStart = app.indexOf('programme-category-title">Tiered membership</div>');
const otherStart = app.indexOf('programme-category-title">Lifestyle rewards</div>');
const growthStart = app.indexOf('programme-category-title">Promotions</div>');
const points = app.slice(pointsStart, tiersStart);
const other = app.slice(otherStart, growthStart);

test('V227 everything earned and spent in points is in one group', () => {
  assert.ok(pointsStart > 0 && tiersStart > pointsStart && otherStart > tiersStart && growthStart > otherStart,
    'the groups must exist in order: points, tiers, lifestyle, promotions');
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
