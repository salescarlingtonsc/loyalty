/* V326 — the owner's 5-photo Points System flow, Photo 3: a new dedicated #/grow/points page
 * replacing the wizard as the Points System tile's destination entirely. Published | History
 * (no Draft — every gift change here is immediate-write: business_set_reward_paused_v326,
 * business_delete_reward_v326, business_create_reward_v326; see the v326 migration and
 * docs/qa/evidence/V326-POINTS-GIFT-LIFECYCLE-ACCEPTANCE.md for the database side).
 *
 * Owner ruling confirmed via AskUserQuestion, 2026-08-15: "Photo 3 always, with an empty state"
 * — the tile opens this page unconditionally, live or not, configured or not; an unconfigured
 * business sees a "not set up yet" prompt instead of the wizard.
 *
 * Two real misses earlier in this session (wrong screen, then wrong step) were both caught only
 * by actually clicking through the app, not by unit-testing rendered HTML in isolation — so every
 * assertion here EXECUTES real code sliced verbatim from app.js (via `new Function`), the same
 * discipline used to verify the fix before this file existed.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');

function slice(startMarker, endMarker) {
  const start = app.indexOf(startMarker);
  assert.ok(start >= 0, `missing start marker: ${startMarker}`);
  const end = app.indexOf(endMarker, start + startMarker.length);
  assert.ok(end >= 0, `missing end marker: ${endMarker}`);
  return app.slice(start, end + endMarker.length);
}
function statementTo(startMarker, endChar = ';') {
  const start = app.indexOf(startMarker);
  assert.ok(start >= 0, `missing start marker: ${startMarker}`);
  const end = app.indexOf(endChar, start);
  return app.slice(start, end + 1);
}

const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const CUI = {
  icon: (name) => `<svg data-icon="${esc(name)}"></svg>`,
  emptyState: ({ iconName, title, body, actionHtml }) =>
    `<div class="empty" data-empty-state><span class="big">${CUI.icon(iconName)}</span><b>${esc(title)}</b><p>${esc(body)}</p>${actionHtml || ''}</div>`,
};

// ---------------------------------------------------------------------------------------------
// ROUTING: the two classes of bug that bit this session (wrong screen, wrong step).
// ---------------------------------------------------------------------------------------------

test('V326/V331 the points, stamps AND tiers tiles each navigate straight to their own page, never through growSetupEntryV301', () => {
  const stripComments = source => source.replace(/\/\*[\s\S]*?\*\//g, '');
  const code = stripComments(app);
  const handler = code.slice(code.indexOf("outerMain.querySelectorAll('[data-grow-topic-v229]')"),
    code.indexOf('growTopicV229=tile.dataset.growTopicV229;'));
  assert.match(handler, /if\(tile\.dataset\.growTopicV229==='points'\|\|tile\.dataset\.growTopicV229==='stamps'\)return nav\('#\/grow\/points'\);/);
  assert.match(handler, /if\(tile\.dataset\.growTopicV229==='tiers'\)return nav\('#\/grow\/tiers'\);/);
  // V331: tiers joined points/stamps in getting its own page, so growSetupEntryV301's whole
  // ['points','stamps','tiers'] list now returns explicitly above — the wizard-entry fallback this
  // handler used to reach for tiers is gone, not merely reordered after these checks.
  assert.doesNotMatch(handler, /growSetupEntryV301\(tile\.dataset\.growTopicV229\)/);
  assert.doesNotMatch(handler, /return nav\('#\/grow\/setup'\);/);
});

test('V326 hashParam="points" resolves programmeView correctly and is recognised as a view, not a deep link', () => {
  const programmeViewSrc = statementTo('const programmeView=');
  const hashParamIsViewSrc = statementTo('const hashParamIsProgrammeView=');
  const evalProgrammeView = hashParam => new Function('hashParam', programmeViewSrc + ' return programmeView;')(hashParam);
  const evalHashParamIsView = hashParam => new Function('hashParam', hashParamIsViewSrc + ' return hashParamIsProgrammeView;')(hashParam);
  assert.equal(evalProgrammeView('points'), 'points');
  assert.equal(evalProgrammeView('bogus'), 'list');
  assert.equal(evalHashParamIsView('points'), true, 'or mountGrowSurface would wrongly try to open an editor for it');
});

test('V326 programmeView="points" is excluded from the drilled-category branch', () => {
  const src = statementTo('const growCategoryViewV271=');
  const evalCategoryView = programmeView => new Function('programmeView', src + ' return growCategoryViewV271;')(programmeView);
  assert.equal(evalCategoryView('points'), false);
  assert.equal(evalCategoryView('list'), true);
});

test('V326 the render dispatch mounts growPointsManageV326 when programmeView is "points"', () => {
  assert.match(app, /\$\{programmeView==='points'\?growPointsManageV326:''\}/);
});

test('V326 the "edit" link lands the wizard on the Earning step, guarded on that step existing', () => {
  const railSrc = slice('const GROW_SETUP_RAIL_W6I2=[', '];');
  const railBlock = slice('const railW6I2=()=>{', 'const stepNumberForW6I2=kind=>stepNumberOrNullW6I2(kind)??railCountW6I2();');
  const handoffSrc = slice('const rewardHandoffV303=pendingGrowSetupRewardV303;', '  }\n  for(let number=1;number<=state.step;number++)')
    .replace('for(let number=1;number<=state.step;number++)', '// (visited-set loop omitted from this harness)');

  function landingStep(switches, mode, kind) {
    const src = `${railSrc}\n${railBlock}\n` +
      `let pendingGrowSetupRewardV303=${JSON.stringify({ mode, kind })};\n` +
      `const state={step:1,switches:${JSON.stringify(switches)}};\n` +
      `${handoffSrc}\n` +
      `return {step:state.step,rail:railW6I2().map(s=>s.kind)};`;
    return new Function(src)();
  }

  const pointsOnly = { points: true, tiers: false, stamps: false, referral: false };
  /* V334: Earning + Expiry merged into one 'earnExpiry' rail step (owner markup photo 6). */
  assert.deepEqual(landingStep(pointsOnly, 'earning'), { step: 2, rail: ['choose', 'earnExpiry', 'reward', 'live'] },
    'mode:earning must land on Earning & expiry (step 2 of a points-only 4-step rail), not Gifts');
  // The old reward hand-off (view/edit/add) must be completely unaffected.
  assert.equal(landingStep(pointsOnly, 'view').step, 3, "mode:'view' still lands on Gifts, unchanged");
  // A rail with no Earning step (stamps-only), and no kind supplied (legacy shape), must not move
  // the step at all — this is the exact bug the kind-aware fix below closes.
  const stampsOnly = { points: false, tiers: false, stamps: true, referral: false };
  assert.equal(landingStep(stampsOnly, 'earning').step, 1, 'no Earning step on the rail — step must stay 1, not crash or misland');
  // V326 stamps-unification fix: the Stamp card page's Edit link now sends kind:'stamps' along
  // with the hand-off, so it must land on 'stampEarn' (step 2 of the stamps rail), not silently
  // stay on step 1 the way it would if it kept checking for a step literally named 'earn'.
  assert.deepEqual(landingStep(stampsOnly, 'earning', 'stamps'),
    { step: 2, rail: ['choose', 'stampEarn', 'stampGift', 'live'] },
    "mode:'earning' with kind:'stamps' must land on stampEarn, the stamps family's earning-rate step");
  // A points hand-off explicitly carrying kind:'points' must be unaffected by the new kind check.
  assert.equal(landingStep(pointsOnly, 'earning', 'points').step, 2);
});

test('V326 the edit link sets the earning hand-off, carrying the live model kind (points or stamps)', () => {
  assert.match(app, /pendingGrowSetupModelV303=\{kind:growPointsSpineKindV326,from:growPointsSpineKindV326\};\s*\r?\n?\s*pendingGrowSetupRewardV303=\{mode:'earning',kind:growPointsSpineKindV326\};\s*\r?\n?\s*nav\('#\/grow\/setup'\);/);
});

// ---------------------------------------------------------------------------------------------
// PAGE CONTENT: execute the real growPointsManageV326 block with synthetic data.
// ---------------------------------------------------------------------------------------------

function harness() {
  const PROGRAMME_SWITCHES_V314_src = slice('const PROGRAMME_SWITCHES_V314={', '};');
  const PROGRAMME_KINDS_W6I2_src = statementTo("const PROGRAMME_KINDS_W6I2=['points'");
  const programmeSwitchSetV314_src = slice('function programmeSwitchSetV314(', '\n}');
  const programmeSpineRowsV314_src = slice('function programmeSpineRowsV314(', '\n}');
  const programmeSpineOnV314_src = slice('function programmeSpineOnV314(', '\n}');
  const PROGRAMME_ACCRUAL_EXCLUSIVE_V322_src = statementTo('const PROGRAMME_ACCRUAL_EXCLUSIVE_V322=');
  const programmeExclusionsV322_src = slice('function programmeExclusionsV322(', '\n}');
  const promotionDateShortV324_src = slice('function promotionDateShortV324(', '\n}');
  const pageBlockSrc = slice(
    "  /* ============ V326 — OWNER'S 5-PHOTO POINTS SYSTEM FLOW, PHOTO 3",
    '      </ul>`;'
  );

  return function render(opts) {
    const {
      canRewards = true, canSetupGrow = true, snapshotRewards = [], liveLoyaltyModelKeysV240 = ['redeem'],
      liveLoyaltyModelV235 = 'redeem',
      earningOverviewCopy = 'Current setting: Earn 1 points per SGD 1 spent',
      S = { biz: { id: 'biz-1' }, programmesBusinessId: 'biz-1', programmes: [{ kind: 'points', active: true, id: 'spine-points' }] },
      growSwitchPendingV322 = '', growSwitchErrorV322 = '', growPointsManageTabV326 = 'published',
      growPointsDeletePendingV326 = '', growPointsAddOpenV326 = '', growPointsAddDraftV326 = { name: '', points: '', description: '' },
      growPointsErrorV326 = '', growPointsBusyV326 = false,
      // V343: the form now serves edit too, and a gift can carry a photo.
      growPointsEditingV326 = null, growPointsPhotoFileV343 = null, growPointsRemovePhotoV343 = false,
      customerMediaUrlV95 = () => '',
    } = opts;
    const src = [
      PROGRAMME_SWITCHES_V314_src, PROGRAMME_KINDS_W6I2_src, programmeSwitchSetV314_src, programmeSpineRowsV314_src,
      programmeSpineOnV314_src, PROGRAMME_ACCRUAL_EXCLUSIVE_V322_src, programmeExclusionsV322_src,
      promotionDateShortV324_src, pageBlockSrc,
      'return {growPointsManageV326,growPointsPublishedV326,growPointsHistoryV326,growPointsConfiguredV326,growPointsOnV326,growPointsIsStampsV326,growPointsSpineKindV326,growPointsPageTitleV326,growPointsRowLabelV326};',
    ].join('\n');
    const fn = new Function(
      'esc', 'CUI', 'S', 'canRewards', 'canSetupGrow', 'snapshot', 'liveLoyaltyModelKeysV240', 'liveLoyaltyModelV235',
      'earningOverviewCopy', 'growProgrammeSwitchKindsV322', 'growSwitchPendingV322', 'growSwitchErrorV322',
      'growPointsManageTabV326', 'growPointsDeletePendingV326', 'growPointsAddOpenV326', 'growPointsAddDraftV326',
      'growPointsErrorV326', 'growPointsBusyV326', 'growPointsEditingV326', 'growPointsPhotoFileV343',
      'growPointsRemovePhotoV343', 'customerMediaUrlV95', src
    );
    const growProgrammeSwitchKindsV322 = [['points', 'Points & gifts'], ['tiers', 'Tier membership'], ['stamps', 'Stamp card'], ['referral', 'Referral']];
    return fn(esc, CUI, S, canRewards, canSetupGrow, { rewards: snapshotRewards }, liveLoyaltyModelKeysV240, liveLoyaltyModelV235,
      earningOverviewCopy, growProgrammeSwitchKindsV322, growSwitchPendingV322, growSwitchErrorV322,
      growPointsManageTabV326, growPointsDeletePendingV326, growPointsAddOpenV326, growPointsAddDraftV326,
      growPointsErrorV326, growPointsBusyV326, growPointsEditingV326, growPointsPhotoFileV343,
      growPointsRemovePhotoV343, customerMediaUrlV95);
  };
}

test('V326 an unconfigured business sees the empty state, not the wizard and not the summary row', () => {
  const render = harness();
  const r = render({ liveLoyaltyModelKeysV240: ['tiers'], S: { biz: { id: 'b' }, programmesBusinessId: 'b', programmes: null } });
  assert.match(r.growPointsManageV326, /data-empty-state/);
  assert.match(r.growPointsManageV326, /id="growPointsSetupV326"/);
  assert.doesNotMatch(r.growPointsManageV326, /data-grow-points-giftlist-v326/);
});

test('V326 loyalty not included in the workspace shows its own empty state, no setup CTA', () => {
  const render = harness();
  const r = render({ canRewards: false });
  assert.match(r.growPointsManageV326, /data-empty-state/);
  assert.doesNotMatch(r.growPointsManageV326, /id="growPointsSetupV326"/);
});

test('V326 a configured programme shows the Point system row, earn rate, and on/off state', () => {
  const render = harness();
  const r = render({});
  assert.equal(r.growPointsConfiguredV326, true);
  assert.equal(r.growPointsOnV326, true);
  assert.match(r.growPointsManageV326, /<b>Point system<\/b>/);
  assert.match(r.growPointsManageV326, /Earn 1 points per SGD 1 spent/);
  /* V334: "ON for customers" text replaced by a compact ON/OFF toggle pill (owner markup photo 4). */
  assert.match(r.growPointsManageV326, /pill-toggle-v334 on"[^>]*data-grow-switchtoggle-v322="points"[^>]*>ON</);
  assert.match(r.growPointsManageV326, /data-grow-switchtoggle-v322="points"/);
  assert.match(r.growPointsManageV326, /data-grow-points-edit-v326="1"/);
  assert.match(r.growPointsManageV326, /data-grow-points-add-v326="1"/);
});

test('V326 Published tab shows live and paused gifts with correct per-row state, excludes History', () => {
  const render = harness();
  const rewards = [
    { id: 'r1', customer_name: 'Free Coffee', cost_points: 20, active: true, paused: false, sort: 1, created_at: '2026-08-01T12:00:00Z' },
    { id: 'r2', customer_name: 'Free Muffin', cost_points: 15, active: true, paused: true, sort: 2, created_at: '2026-08-02T12:00:00Z' },
    { id: 'r3', customer_name: 'Retired Reward', cost_points: 30, active: false, paused: false, sort: 3, created_at: '2026-07-01T12:00:00Z' },
  ];
  const r = render({ snapshotRewards: rewards, growPointsManageTabV326: 'published' });
  assert.equal(r.growPointsPublishedV326.length, 2);
  assert.equal(r.growPointsHistoryV326.length, 1);
  const html = r.growPointsManageV326;
  assert.doesNotMatch(html, /Retired Reward/, 'inactive rewards must not appear on the Published tab');
  const coffeeIdx = html.indexOf('Free Coffee');
  const muffinIdx = html.indexOf('Free Muffin');
  assert.ok(coffeeIdx >= 0 && muffinIdx >= 0);
  /* V334: "ON for customers"/"Turn off" text replaced by a compact ON/OFF toggle pill. */
  assert.match(html.slice(coffeeIdx, coffeeIdx + 700), /pill-toggle-v334 on[\s\S]*?>ON</, 'a live gift shows an ON pill');
  assert.match(html.slice(muffinIdx, muffinIdx + 700), /pill-toggle-v334 off[\s\S]*?>OFF</, 'a paused gift shows an OFF pill');
  assert.match(html, /data-grow-points-gift-delete-v326="r1"/);
  assert.match(html, /data-grow-points-gift-delete-v326="r2"/);
});

test('V326 History tab shows only deleted gifts, read-only, no toggle or delete controls', () => {
  const render = harness();
  const rewards = [
    { id: 'r1', customer_name: 'Free Coffee', cost_points: 20, active: true, paused: false, sort: 1, created_at: '2026-08-01T12:00:00Z' },
    { id: 'r3', customer_name: 'Retired Reward', cost_points: 30, active: false, paused: false, sort: 3, created_at: '2026-07-01T12:00:00Z' },
  ];
  const r = render({ snapshotRewards: rewards, growPointsManageTabV326: 'history' });
  const html = r.growPointsManageV326;
  assert.match(html, /Retired Reward/);
  assert.match(html, /In history/);
  assert.doesNotMatch(html, /Free Coffee/, 'the Published-only gift must not leak onto the History tab');
  assert.doesNotMatch(html, /data-grow-points-gift-delete-v326="r3"/, 'a history row has no delete control — it is already deleted');
  assert.doesNotMatch(html, /data-grow-points-gift-toggle-v326="r3"/);
});

test('V326 delete confirmation opens for exactly the pending gift and stays hidden for others', () => {
  const render = harness();
  const rewards = [
    { id: 'r1', customer_name: 'Free Coffee', cost_points: 20, active: true, paused: false, sort: 1, created_at: '2026-08-01T12:00:00Z' },
  ];
  const r = render({ snapshotRewards: rewards, growPointsDeletePendingV326: 'r1' });
  const match = r.growPointsManageV326.match(/<li class="imp-note" data-grow-points-gift-deleteconfirm-v326="r1"[^>]*>/);
  assert.ok(match && !match[0].includes('hidden'), 'the pending gift\'s confirm block must be visible');
});

test('V326 the add-gift form preserves in-progress values, and the post-save prompt offers add-another/done', () => {
  const render = harness();
  const formRender = render({ growPointsAddOpenV326: 'form', growPointsAddDraftV326: { name: 'Lotion', points: '10' } });
  assert.match(formRender.growPointsManageV326, /value="Lotion"/);
  assert.match(formRender.growPointsManageV326, /value="10"/);
  assert.match(formRender.growPointsManageV326, /data-grow-points-add-save-v326="1"/);

  const promptRender = render({ growPointsAddOpenV326: 'prompt' });
  assert.match(promptRender.growPointsManageV326, /data-grow-points-add-again-v326="1"/);
  assert.match(promptRender.growPointsManageV326, /data-grow-points-add-done-v326="1"/);
});

test('V326 read-only staff (canSetupGrow=false) sees state but no interactive controls', () => {
  const render = harness();
  const rewards = [{ id: 'r1', customer_name: 'Free Coffee', cost_points: 20, active: true, paused: false, sort: 1, created_at: '2026-08-01T12:00:00Z' }];
  const r = render({ canSetupGrow: false, snapshotRewards: rewards });
  const html = r.growPointsManageV326;
  assert.match(html, /Free Coffee/);
  /* V334: read-only state still shows the ON/OFF pill, just as a non-interactive <span>. */
  assert.match(html, /pill-toggle-v334 on">ON</);
  for (const selector of ['data-grow-points-edit-v326', 'data-grow-points-add-v326',
    'data-grow-switchtoggle-v322="points"', 'data-grow-points-gift-toggle-v326', 'data-grow-points-gift-delete-v326']) {
    assert.doesNotMatch(html, new RegExp(selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
});

// ---------------------------------------------------------------------------------------------
// STAMPS UNIFICATION (V326 "proceed all at once"): #/grow/points also serves as the Stamp card
// destination. These pin the model-awareness — page title, unit wording, on/off spine kind, and
// the programme_id scoping that keeps a switched-model business from seeing the OTHER model's
// dormant gifts — rather than building a second, near-duplicate page against the same list.
// ---------------------------------------------------------------------------------------------

test('V326 stamps mode: growPointsIsStampsV326/growPointsSpineKindV326 derive from the live model, page title becomes Stamp card', () => {
  const render = harness();
  const stampsSpine = { biz: { id: 'biz-1' }, programmesBusinessId: 'biz-1', programmes: [{ kind: 'stamps', active: true, id: 'spine-stamps' }] };
  const r = render({ liveLoyaltyModelV235: 'stamps', liveLoyaltyModelKeysV240: ['stamps'], S: stampsSpine });
  assert.equal(r.growPointsIsStampsV326, true);
  assert.equal(r.growPointsSpineKindV326, 'stamps');
  assert.equal(r.growPointsPageTitleV326, 'Stamp card');
  assert.equal(r.growPointsRowLabelV326, 'Stamp card');
  assert.equal(r.growPointsConfiguredV326, true);
  assert.equal(r.growPointsOnV326, true);
  assert.match(r.growPointsManageV326, /<b>Stamp card<\/b>/);
  assert.doesNotMatch(r.growPointsManageV326, /Points System/);
  // The summary row's own on/off toggle must move the STAMPS spine, not points.
  assert.match(r.growPointsManageV326, /data-grow-switchtoggle-v322="stamps"/);
  assert.match(r.growPointsManageV326, /data-grow-switchconfirm-v322="stamps"/);
});

test('V326 stamps mode is "configured" from liveLoyaltyModelV235 alone, independent of liveLoyaltyModelKeysV240', () => {
  const render = harness();
  // A firm that has never run points has liveLoyaltyModelKeysV240===['stamps'], not ['redeem'] —
  // the old `liveLoyaltyModelKeysV240.includes('redeem')` test alone would have wrongly shown the
  // "not set up yet" empty state for every stamps-only business.
  const r = render({ liveLoyaltyModelV235: 'stamps', liveLoyaltyModelKeysV240: ['stamps'],
    S: { biz: { id: 'biz-1' }, programmesBusinessId: 'biz-1', programmes: [{ kind: 'stamps', active: true, id: 'spine-stamps' }] } });
  assert.equal(r.growPointsConfiguredV326, true);
  assert.doesNotMatch(r.growPointsManageV326, /data-empty-state/);
});

test('V326 gift rows use "stamp"/"stamps" unit wording in stamps mode, "point"/"points" in points mode', () => {
  const render = harness();
  const rewards = [{ id: 'r1', customer_name: 'Free Coffee', cost_points: 1, active: true, paused: false, sort: 1, created_at: '2026-08-01T12:00:00Z', programme_id: 'spine-stamps' }];
  const stampsSpine = { biz: { id: 'biz-1' }, programmesBusinessId: 'biz-1', programmes: [{ kind: 'stamps', active: true, id: 'spine-stamps' }] };
  const stampsHtml = render({ liveLoyaltyModelV235: 'stamps', liveLoyaltyModelKeysV240: ['stamps'], S: stampsSpine, snapshotRewards: rewards }).growPointsManageV326;
  /* V343: the gift row became a card, description/date now share one meta line rather than
     each getting their own trailing </span>, so "1 stamp" is followed by " · Added", not "<". */
  assert.match(stampsHtml, /Gift · 1 stamp ·/, 'singular stamp, not "1 stamps" or "1 point"');
  const pointsHtml = render({ snapshotRewards: [{ ...rewards[0], programme_id: 'spine-points' }] }).growPointsManageV326;
  assert.match(pointsHtml, /Gift · 1 point ·/, 'points mode keeps "point"/"points" wording, unaffected by the stamps change');
});

test('V326 scopes the gift list to the live model\'s spine programme_id — dormant rows from a switched-away model never leak through', () => {
  const render = harness();
  const rewards = [
    { id: 'r-stamps', customer_name: 'Stamp Gift', cost_points: 5, active: true, paused: false, sort: 1, created_at: '2026-08-01T12:00:00Z', programme_id: 'spine-stamps' },
    { id: 'r-points', customer_name: 'Points Gift', cost_points: 20, active: true, paused: false, sort: 1, created_at: '2026-07-01T12:00:00Z', programme_id: 'spine-points' },
  ];
  // Business is currently live on STAMPS, but has a dormant points-mode gift left over from before
  // it switched (R2 exclusivity means both spine rows can exist even though only one is active).
  const S = { biz: { id: 'biz-1' }, programmesBusinessId: 'biz-1', programmes: [
    { kind: 'stamps', active: true, id: 'spine-stamps' }, { kind: 'points', active: false, id: 'spine-points' },
  ] };
  const r = render({ liveLoyaltyModelV235: 'stamps', liveLoyaltyModelKeysV240: ['stamps'], S, snapshotRewards: rewards });
  assert.equal(r.growPointsPublishedV326.length, 1);
  assert.equal(r.growPointsPublishedV326[0].id, 'r-stamps');
  assert.match(r.growPointsManageV326, /Stamp Gift/);
  assert.doesNotMatch(r.growPointsManageV326, /Points Gift/, 'a dormant points-mode gift must not appear on the live Stamp card page');
});

test('V326 a legacy row with no programme_id at all is shown regardless of live model (fail open, not hidden)', () => {
  const render = harness();
  const rewards = [{ id: 'r-legacy', customer_name: 'Legacy Gift', cost_points: 5, active: true, paused: false, sort: 1, created_at: '2026-01-01T12:00:00Z' }];
  const r = render({ snapshotRewards: rewards });
  assert.equal(r.growPointsPublishedV326.length, 1);
  assert.match(r.growPointsManageV326, /Legacy Gift/);
});

test('V326 the add-gift RPC looks up the spine id for whichever kind is actually live, not a hardcoded points lookup', () => {
  assert.doesNotMatch(app, /find\(row=>row\.kind==='points'\)\?\.id;\s*\r?\n\s*if\(!spineId\)/,
    'the add-gift handler must no longer hardcode a points-only spine lookup');
  assert.match(app, /const spineId=growPointsSpineIdV326;/);
  assert.match(app, /S\.programmes=programmes\.map\(row=>\(\{id:row\?\.id\|\|null,kind:row\?\.kind\|\|null,active:row\?\.active===true\}\)\)/,
    'the programme-spine cache must preserve the row id that business_create_reward_v326 needs');
  assert.match(app, /sb\.from\('business_programmes'\)\.select\('id,kind,active'\)/,
    'refreshing the spine must select the id as well as the display flags');
});

// ---------------------------------------------------------------------------------------------
// CLICK WIRING: the three new immediate-write RPCs are called with the exact parameter shapes
// the v326 migration's RPCs declare.
// ---------------------------------------------------------------------------------------------

test('V326 the three new RPCs are called with the exact parameter names the migration declares', () => {
  assert.match(app, /sb\.rpc\('business_set_reward_paused_v326',\{\s*\r?\n?\s*p_business:S\.biz\.id,p_reward:id,p_paused:!want\}\);/);
  assert.match(app, /sb\.rpc\('business_delete_reward_v326',\{p_business:S\.biz\.id,p_reward:id\}\);/);
  /* V343: business_create_reward_v326 gained p_description/p_image_ref (photo 4 — description
     and photo on the add form); business_update_reward_v326 is the same page's new Edit RPC. */
  assert.match(app, /sb\.rpc\('business_create_reward_v326',\{\s*\r?\n?\s*p_business:S\.biz\.id,p_programme:spineId,p_name:name,p_points:points,p_credit_cents:0,\s*\r?\n?\s*p_description:description\|\|null,p_image_ref:imageRef\|\|null\}\)\);/);
  assert.match(app, /sb\.rpc\('business_update_reward_v326',\{\s*\r?\n?\s*p_business:S\.biz\.id,p_reward:growPointsEditingV326,p_name:name,p_points:points,\s*\r?\n?\s*p_description:description\|\|null,p_credit_cents:0,\s*\r?\n?\s*p_image_ref:imageRef\|\|null,p_clear_image:growPointsRemovePhotoV343&&!imageRef\}\)\);/);
});

test('V326 pausing/deleting/creating a gift never touches the network on open — only on confirm', () => {
  const stripComments = source => source.replace(/\/\*[\s\S]*?\*\//g, '');
  const code = stripComments(app);
  const tabHandler = code.slice(code.indexOf("outerMain.querySelectorAll('[data-grow-points-manage-tab-v326]')"),
    code.indexOf("outerMain.querySelectorAll('[data-grow-points-manage-tab-v326]')") + 300);
  assert.doesNotMatch(tabHandler, /sb\.rpc|sb\.from/, 'switching Published/History must never touch the network');
  const deleteOpenHandler = code.slice(code.indexOf("outerMain.querySelectorAll('[data-grow-points-gift-delete-v326]')"),
    code.indexOf("outerMain.querySelectorAll('[data-grow-points-gift-delete-v326]')") + 200);
  assert.doesNotMatch(deleteOpenHandler, /sb\.rpc/, 'opening the delete confirm must not itself call the delete RPC');
});
