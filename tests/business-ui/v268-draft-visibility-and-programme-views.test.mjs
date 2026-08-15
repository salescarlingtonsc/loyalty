import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

/* V268 — two owner reports on the Programmes surface.

   A. On the POINT SYSTEM view, with four reward cards circled: "why inside after edit does not
      updated". The owner opens a reward, changes its numbers, comes back, and the card still
      shows the old value. V198 answered this with a banner at the top of the page, but a banner
      cannot say WHICH card was edited, so the owner hit it repeatedly and read the app as broken.
      The versioning guarantee is not negotiable — this list answers "what can my customers use
      right now" — so the published value stays exactly where it is and the pending value is added
      beside it, on the cards that genuinely differ and nowhere else.

   B. "all programmes interface when clicked in each categories" — drilling into a category must
      show, the same way every time, the category name and the items under it with their status. */

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(resolve(repoRoot, 'app/app.js'), 'utf8');
const styles = readFileSync(resolve(repoRoot, 'app/index.html'), 'utf8');

const section = (from, to) => {
  const start = app.indexOf(from);
  assert.ok(start > 0, `missing anchor ${from}`);
  const end = app.indexOf(to, start);
  assert.ok(end > start, `missing anchor ${to}`);
  return app.slice(start, end);
};

/* ---------------- A. the pending edit is visible ---------------- */

test('V268 (a) the page actually READS the draft — it could not have shown a pending edit before', () => {
  // The overview used to fetch the published catalogue plus the draft's header row only.
  assert.match(app, /sb\.rpc\('get_loyalty_reward_draft',\{p_config_version:draftHeaderV268\.id\}\)/);
  assert.match(app, /draftDetail:draftDetailV268,/);
  assert.match(app, /draftDetailError:Boolean\(draftDetailErrorV268\),/);
  // Owner-gated (the RPC raises 42501 otherwise) and fail-soft.
  assert.match(app, /if\(draftHeaderV268\?\.id&&canSetupGrow\)\{/);
  assert.match(app, /draftDetailV268=draftDetailError\?null:draftDetail\|\|null;/);
});

test('V268 (a) only a reward whose draft genuinely differs is marked', () => {
  /* V291 retarget (not a deletion): the three-field comparison this section pinned moved into
     growRewardPendingChangesV291, a top-level function the publish gate reads too. The rule this
     test protects — only a reward that GENUINELY differs is marked — is unchanged, so the
     section moves to the function that now decides it. */
  const diff = section('function growRewardPendingChangesV291(', 'function growRetentionPendingChangesV291(');
  // Matched by the reward's own id against the published row, field by field.
  assert.match(diff, /const live=liveById\.get\(id\);/);
  assert.match(diff, /fields\.forEach\(field=>\{/);
  assert.match(diff, /if\(before!==after\)changes\.push\(/);
  // Nothing is recorded when nothing changed — a marker on every card would be worthless.
  assert.match(diff, /if\(changes\.length\)changed\.set\(id,changes\);/);
  /* V291 additions: the fields that used to publish silently. */
  const fields = section('function growRewardDiffFieldsV291(', 'function growRewardDiffOptionsFromSnapshotV291(');
  for (const label of ['Name', 'Cost', 'Offered', 'Store credit', 'Expires after',
    'Uses per customer', 'Who can redeem', 'Branches', 'Services']) {
    assert.match(fields, new RegExp(`label:'${label}'`), `${label} must be compared`);
  }
  assert.match(app, /const growPendingRewardsV268=growRewardDiffV291\.changed;/);
  assert.match(app, /const growPendingBlockV268=changes=>!changes\|\|!changes\.length\?''/);
});

test('V268 (a) a changed card shows the live value AND the pending value, live first', () => {
  assert.match(app, /<s data-merchant-content>\$\{esc\(change\.live\)\}<\/s> → <b data-merchant-content>\$\{esc\(change\.pending\)\}<\/b>/);
  assert.match(app, /class="pill new grow-pending-pill-v268">Edited · not live yet<\/span>/);
  // The pending block is appended AFTER the published name and cost, never in their place.
  const card = section('const rewardCardHtmlV250=', 'const rewardCardsV250=');
  assert.match(card, /<b class="reward-card-name-v250" data-merchant-content>\$\{esc\(name\)\}<\/b>/);
  assert.match(card, /<span class="reward-card-cost-v250" data-merchant-content>\$\{esc\(`\$\{cost\} \$\{unit\}`\)\}<\/span>\$\{growPendingBlockV268\(pending\)\}/);
});

test('V268 (a) the published catalogue is still what the cards are built from', () => {
  // The regression that would break customers' current reality: sourcing the grid from the draft.
  assert.match(app, /const rewardJourney=ownerRewardJourneyV122\(\{\s*\r?\n?\s*rewards:snapshot\.rewards/);
  const cards = section('const rewardCardsV250=[', 'const rewardCardGridV250=');
  assert.ok(!cards.includes('snapshot.draftDetail'), 'the card list must be built from published rewards');
  assert.match(cards, /pending:growPendingRewardsV268\.get\(String\(milestone\.id\)\)\|\|null/);
  assert.match(cards, /pending:growPendingRewardsV268\.get\(String\(reward\.id\)\)\|\|null/);
});

test('V268 (a) a reward that exists only in the draft is never rendered as live', () => {
  assert.match(app, /class="pill new">Not live yet<\/span>/);
  assert.match(app, /Customers see this once you publish\./);
  // It is an article, not an edit button masquerading as a published reward card.
  assert.match(app, /<article class="reward-card-v250 reward-card-pending-new-v268"/);
});

test('V268 (a) the earning row carries the same treatment, and does not break the Ongoing filter', () => {
  assert.match(app, /\$\{esc\(earningOverviewCopy\)\}<\/p>\$\{growPendingBlockV268\(growPendingEarningV268\)\}<\/div>/);
  // The pending pill sits ahead of the status pill on that row; the Ongoing/Pending filter and
  // the suggestion strips both judge a row by its STATUS pill, so it must be excluded by name.
  assert.match(app, /row\.querySelector\('\.pill:not\(\.grow-pending-pill-v268\)'\)/);
  assert.ok(!/querySelector\('\.pill'\)/.test(app), 'no bare .pill lookup may survive');
});

test('V268 (a) when the draft cannot be read, the banner says so instead of implying nothing changed', () => {
  assert.match(app, /Your pending edits could not be loaded, so nothing below is marked as edited\./);
  assert.match(app, /Anything you have edited is marked with what it becomes\./);
  // V198's sentence — the reason the list shows published values — is untouched.
  assert.match(app, /You have unpublished changes\. The names and numbers below are what customers see today/);
});

test('V268 (a) the marker is legible at 390px', () => {
  // One change per line, wrapping inside the 150px card column the V250 grid can drop to.
  assert.match(styles, /\.grow-pending-v268\{display:flex;flex-direction:column;[^}]*width:100%/);
  assert.match(styles, /\.grow-pending-line-v268\{[^}]*overflow-wrap:anywhere\}/);
});

/* ---------------- B. every programme category drills in the same way ---------------- */

test('V268 (b) drilling into a category shows where you are, for every category', () => {
  assert.match(app, /const growBreadcrumbV268=topic=>!topic\?''/);
  assert.match(app, /class="grow-breadcrumb-current-v268">\$\{esc\(topic\.title\)\}/);
  // Rendered from the ACTIVE topic, so no category can be missing its trail.
  /* V319 renamed the module and the kicker followed it. V324 (owner markup 2026-08-14) struck
     the kicker out: it printed "REWARDS & OFFER" directly beneath an <h1> already reading
     "Rewards & Offer", so the not-drilled-in branch was restating the heading rather than
     naming a level above it. What this test protects is the DRILLED-IN half — a breadcrumb
     whenever there is an active topic — and that is unchanged, so it is asserted here directly
     instead of through the ternary's other arm. */
  assert.match(app, /\$\{growActiveTopicV229\?growBreadcrumbV268\(growActiveTopicV229\):''\}/);
  assert.doesNotMatch(app, /<p class="customer-quest-kicker">Rewards &amp; Offer<\/p>/);
  // One back control, not two: the trail keeps the existing id and handler.
  assert.equal(app.split('id="growTopicBackV229"').length - 1, 1);
  assert.match(app, /if\(growTopicBack\)growTopicBack\.onclick=\(\)=>\{growTopicV229='';/);
});

test('V268 (b) the category heading and its blurb stay with the item list', () => {
  /* V334: the Points System heading now leads with a star icon (owner markup photo 4) — the
     rest of the heading/blurb pairing this test protects is unchanged. */
  assert.match(app, /<h2 id="rewardJourneyTitle">\$\{programmeView==='points'\?`\$\{CUI\.icon\('star',\{size:18\}\)\} `:''\}\$\{growActiveTopicV229\?esc\(growActiveTopicV229\.title\)/);
  assert.match(app, /\$\{growActiveTopicV229\?`<p class="muted small">\$\{esc\(growActiveTopicV229\.blurb\)\}<\/p>`:''\}/);
});

test('V268 (b) Tiered membership is a category like the others, not a drill-only orphan', () => {
  // It used to render on `growActiveTopicV229?.key==='tiers'` alone, so the flat Ongoing and
  // Pending setup views listed every other category and silently omitted this one.
  assert.match(app, /\$\{topicOnV229\('tiers'\)\?`<div class="programme-category" data-programme-category-v268="tiers">/);
  assert.ok(!app.includes("growActiveTopicV229?.key==='tiers'?`<div class=\"programme-category\""),
    'the tiers category must not be gated on the drilled topic alone');
  // Its model chooser is disclosed on the drill-in only, exactly like the Point system category.
  assert.match(app, /\$\{growActiveTopicV229\?`<div class="grow-programme-row points-mode-row-v229">\$\{growPointsModeChooserV229\(\)\}<\/div>`:''\}/);
});

test('V268 (b) every programme category carries its topic key, so the pattern is one shape', () => {
  const keys = [...app.matchAll(/data-programme-category-v268="([a-z]+)"/g)].map(match => match[1]);
  assert.deepEqual(keys.sort(), ['lifestyle', 'points', 'promotions', 'recurring', 'referrals', 'tiers']);
  /* V334 (owner markup, photo 3: "delete this tab"): the Promotions TILE is gone from the
     Ongoing programmes grid, but its category div (growLimitedOfferCategoryHtmlV319, reached
     from the Limited Offer page) is untouched — hence 'promotions' still appears in `keys`
     above but not in the tile list below. */
  // Every drillable tile resolves to one of those categories — no tile is a dead end.
  const tiles = section('const growTopicDefsV229=[', 'const growActiveTopicV229=');
  const tileKeys = [...tiles.matchAll(/\{key:'([a-z]+)',icon:/g)].map(match => match[1]);
  assert.deepEqual(tileKeys.sort(), ['lifestyle', 'points', 'recurring', 'referrals', 'stamps', 'tiers']);
  // 'stamps' is a third VIEW of the point engine (V235), which is why it has no category of its own.
  assert.match(app, /const growTopicSectionV235=growActiveTopicV229\?\.key==='stamps'\?'points'/);
});
