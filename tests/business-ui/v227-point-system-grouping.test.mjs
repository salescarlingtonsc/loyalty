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
/* V319 lifted the Promotions category out of the page template into
   growLimitedOfferCategoryHtmlV319, so that ONE definition serves both the drilled topic and the
   new Limited Offer rail child. Its markup therefore no longer sits after Lifestyle rewards in
   source order — but it still renders after it, which is what this file is about. The promotions
   boundary is taken from the render site rather than the markup, so the four groups are compared
   in the order the owner sees them. */
const pointsStart = app.indexOf('programme-category-title">Point system</div>');
const tiersStart = app.indexOf('programme-category-title">Tiered membership</div>');
/* V358 flattened the "Lifestyle rewards" grouping card: Welcome gift, Birthday benefit and
   Bring-back are peers of Point system now, each with its own tile and its own door. The property
   this file exists for is unaffected and is what the tests below still hold — a points-priced
   reward belongs to Point system, and a reward that costs no points never leaks into it. There is
   simply no longer a single contiguous "other" block to slice, so the non-points programmes are
   located by name instead. */
const growthStart = app.indexOf("topicOnV229('promotions')?growLimitedOfferCategoryHtmlV319");
const points = app.slice(pointsStart, tiersStart);

test('V227 everything earned and spent in points is in one group', () => {
  assert.ok(pointsStart > 0 && tiersStart > pointsStart && growthStart > tiersStart,
    'the groups must exist in order: points, tiers, promotions');
  assert.equal(app.indexOf('programme-category-title">Lifestyle rewards</div>'), -1,
    'the grouping card the owner struck out must not come back');
  /* V250 turned the reward ROWS into the card grid the owner drew, so the point-spending half
     of this group is now composed one step earlier in rewardCardGridV250 and rendered here. The
     grouping this file protects is unchanged: earning and every points-priced reward stay in
     Point system, and nothing lifestyle leaks in. "Add another reward" and the "Start from a
     template" row were struck out by the owner — the add path is the "+" card and the template
     flow is the link under the grid, both asserted in the V250 file. */
  for (const part of ['rewardJourney.earning', 'rewardCardGridV250']) {
    assert.ok(points.includes(part), `Point system group is missing ${part}`);
  }
  const grid = app.slice(app.indexOf('const rewardCardsV250=['), app.indexOf('const rewardCardGridV250='));
  /* V375 (owner, photo 3): the synthesized store-credit card is gone; the grid is the owner's
     own catalogue and its history, which is all it ever should have been. */
  for (const part of ['rewardJourney.milestones', 'archivedRewards']) {
    assert.ok(grid.includes(part), `the points reward grid is missing ${part}`);
  }
  assert.ok(app.slice(app.indexOf('const rewardCardGridV250='), pointsStart).includes('growTemplatesOpen'),
    'the template flow must stay attached to the points rewards');
  // The old single "Loyalty & rewards" heading is gone, which is what mixed them.
  assert.doesNotMatch(app, /programme-category-title">Loyalty &amp; rewards</);
});

test('V227 rewards that do not use a points balance stay out of the Point system group', () => {
  // Each still exists as its own surface, just no longer inside one shared grouping card.
  for (const part of ['welcomeOfferRowV215', 'rewardJourney.birthday', "key:'bringback'"]) {
    assert.ok(app.includes(part), `${part} must still be on the page`);
  }
  // No leakage into the points group — that is the whole point of the split.
  assert.ok(!points.includes('welcomeOfferRowV215'));
  assert.ok(!points.includes('rewardJourney.birthday'));
});

test('V227 the regrouping did not unbalance the markup', () => {
  /* V319: both ends are whole tags now. The old pair of boundaries both landed INSIDE a
     `<div class="programme-category-title">`, so two unopened `</div>` at the front were
     cancelled by two unclosed `<div` at the back and the count balanced for the wrong reason —
     it would have stayed balanced through a genuinely unbalanced edit. Anchoring the start on
     the category wrapper makes the assertion mean what it says. */
  const segment = app.slice(
    app.indexOf('<div class="programme-category" data-programme-category-v268="points"'), growthStart);
  assert.ok(segment.length > 0, 'the points category wrapper must be found');
  assert.equal((segment.match(/<div/g) || []).length, (segment.match(/<\/div>/g) || []).length,
    'every category wrapper between points and promotions must open and close');
  /* And the category lifted out to serve two entry points is balanced on its own. */
  const lifted = app.slice(app.indexOf('const growLimitedOfferCategoryHtmlV319='),
    app.indexOf('outerMain.innerHTML=`<div class="grow-overview"'));
  assert.equal((lifted.match(/<div/g) || []).length, (lifted.match(/<\/div>/g) || []).length,
    'the extracted promotions category must open and close');
});
