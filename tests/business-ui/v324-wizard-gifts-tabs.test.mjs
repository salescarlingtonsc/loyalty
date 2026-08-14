/* V324 — the wizard's Gifts step (stepThreeHtml) gets the same Published/Draft/History split as
 * everywhere else, on the REACHABLE screen this time.
 *
 * Points System (and the other two point-engine cards) route straight to this wizard,
 * unconditionally — growSetupEntryV301: "the wizard IS this module's UX, for the first set-up and
 * for editing, live or not" (V303, after three owner rounds rejecting the alternative). The first
 * build of this feature landed in growPage's drilled 'points' category, which that routing makes
 * unreachable for an owner. This file is the corrected build, on stepThreeHtml.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const app = readFileSync(new URL('../../app/app.js', import.meta.url), 'utf8');
const stripComments = source => source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
const code = stripComments(app);

const statement = (start, end) => {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing statement ${start}`);
  return app.slice(from, to + end.length);
};

const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const unitWord = (v, u) => `${v} ${u}`;

test('V324 growSetupEntryV301 still sends every point-engine card straight to the wizard', () => {
  /* The premise this whole file exists to serve — if this ever stops being true, the tabs built
     here belong back in growPage's drilled category instead. */
  assert.match(app, /const growSetupEntryV301=key=>canSetupGrow&&\['points','stamps','tiers'\]\.includes\(String\(key\|\|''\)\);/);
});

test('V324 state.rewards and state.rewardsAllV324 come from ONE merge, not two independent ones', () => {
  /* If these ever diverge into separate mergeRewardsV302 calls, a Remove/Undo click on one would
     stop being visible from the other — exactly the bug a shared object reference exists to
     prevent. */
  const stateBlock = statement('const mergedRewardsV324=mergeRewardsV302(', 'rewardTabV324:\'published\',');
  assert.match(stateBlock, /rewards:mergedRewardsV324\.filter\(reward=>reward\.active!==false\),/);
  assert.match(stateBlock, /rewardsAllV324:mergedRewardsV324,/);
  assert.doesNotMatch(stateBlock, /rewards:mergeRewardsV302\(rewardListFrom/,
    'state.rewards must not go back to its own independent merge call');
});

/* Real bytes, lifted and evaluated. rewardRow is reused unchanged for Published/Draft/History —
   only the bucket that FEEDS it is new — so this harness exercises the actual row markup too. */
const rewardRowSrc = statement('const rewardRow=reward=>reward.active===false', '</span></li>`;');
const bucketsSrc = statement('const publishedRewardsV324=state.rewards.filter',
  "?rewardListHtmlV324(historyRewardsV324):'<p class=\"muted small\">Nothing has been removed yet.</p>');");
const rowMarkSrc = statement('const rowMarkTextV304=id=>', ';');
const rewardRowPointsTextSrc = statement('const rewardRowPointsTextV304=points=>', ';');

const build = new Function('esc', 'unitWord', 'rewardUnit', 'rewardAddedIdsV324', 'state',
  `${rewardRowPointsTextSrc}\n${rowMarkSrc}\n${rewardRowSrc}\n${bucketsSrc}\nreturn {rewardTabStripV324,rows,publishedRewardsV324,draftRewardsV324,historyRewardsV324};`);

const call = (rewards, rewardsAll, tab, addedIds = []) =>
  build(esc, unitWord, () => 'points', new Set(addedIds), {rewards, rewardsAllV324: rewardsAll, rewardTabV324: tab, editingV304: null});

const LIVE1 = {id: 'r1', name: 'Free drink', points: 300, active: true};
const LIVE2 = {id: 'r2', name: 'Free Facial cream', points: 1000, active: true};
const NEW_DRAFT = {id: 'r3', name: 'Free lotion sunscreen', points: 250, active: true};
const RETIRED_BEFORE = {id: 'r4', name: 'Free Lotion', points: 5, active: false};
const RETIRED_THIS_SESSION = {id: 'r5', name: 'Free Shampoo', points: 8, active: false};

test('V324 Published excludes anything only-in-draft', () => {
  const rewards = [LIVE1, LIVE2, NEW_DRAFT];
  const {publishedRewardsV324} = call(rewards, rewards, 'published', ['r3']);
  assert.deepEqual(publishedRewardsV324.map(r => r.id), ['r1', 'r2']);
});

test('V324 Draft is exactly the added-in-draft set, nothing else', () => {
  const rewards = [LIVE1, LIVE2, NEW_DRAFT];
  const {draftRewardsV324} = call(rewards, rewards, 'draft', ['r3']);
  assert.deepEqual(draftRewardsV324.map(r => r.id), ['r3']);
});

test('V324 History reads rewardsAllV324, not state.rewards — so a reward retired BEFORE this session still appears', () => {
  /* state.rewards never carried RETIRED_BEFORE at all (V304's own mount-time filter drops it) —
     only rewardsAllV324 (the unfiltered merge) has it. This is the exact case that would silently
     go missing if History were built from state.rewards like Published/Draft are. */
  const rewards = [LIVE1, NEW_DRAFT, RETIRED_THIS_SESSION];
  const rewardsAll = [LIVE1, NEW_DRAFT, RETIRED_THIS_SESSION, RETIRED_BEFORE];
  const {historyRewardsV324} = call(rewards, rewardsAll, 'history', ['r3']);
  assert.deepEqual(historyRewardsV324.map(r => r.id).sort(), ['r4', 'r5']);
});

test('V324 a reward with a pending edit but still live stays Published, is not moved to Draft', () => {
  /* Confirmed scope decision: only a reward that exists ONLY in the draft (never published) is
     Draft. A currently-live reward with an unpublished field edit is still what customers see
     today, so it stays Published — moving it would be inaccurate the moment it renders. */
  const rewards = [LIVE1];
  const {publishedRewardsV324, draftRewardsV324} = call(rewards, rewards, 'published', []);
  assert.deepEqual(publishedRewardsV324.map(r => r.id), ['r1']);
  assert.equal(draftRewardsV324.length, 0);
});

test('V324 the Draft-only row carries a "Not live yet" pill; Published rows do not', () => {
  const rewards = [LIVE1, NEW_DRAFT];
  const draftHtml = call(rewards, rewards, 'draft', ['r3']).rows;
  const publishedHtml = call(rewards, rewards, 'published', ['r3']).rows;
  assert.match(draftHtml, /Not live yet/);
  assert.doesNotMatch(publishedHtml, /Not live yet/);
});

test('V324 History rows are the exact same "· Removed" + Undo markup the wizard already shipped', () => {
  const rewardsAll = [RETIRED_BEFORE];
  const html = call([], rewardsAll, 'history', []).rows;
  assert.match(html, /is-removed-v304/);
  assert.match(html, /· Removed/);
  assert.match(html, /data-grow-setup-reward-undo-v304="r4"/);
  assert.doesNotMatch(html, /data-grow-setup-reward-remove-v304="r4"/, 'a retired row offers Undo, not Remove');
});

test('V324 tab counts and pressed state', () => {
  const rewards = [LIVE1, LIVE2, NEW_DRAFT];
  const rewardsAll = [...rewards, RETIRED_BEFORE];
  const {rewardTabStripV324} = call(rewards, rewardsAll, 'draft', ['r3']);
  assert.match(rewardTabStripV324, /Published \(2\)/);
  assert.match(rewardTabStripV324, /Draft \(1\)/);
  assert.match(rewardTabStripV324, /History \(1\)/);
  assert.match(rewardTabStripV324, /aria-pressed="true" data-grow-setup-reward-tab-v324="draft"/);
  assert.match(rewardTabStripV324, /aria-pressed="false" data-grow-setup-reward-tab-v324="published"/);
});

test('V324 role="group", not "tablist"', () => {
  const html = call([LIVE1], [LIVE1], 'published', []).rewardTabStripV324;
  assert.match(html, /role="group"/);
  assert.doesNotMatch(html, /role="tablist"|role="tab"/);
});

test('V324 empty buckets say so', () => {
  assert.match(call([], [], 'published', []).rows, /Nothing is published yet\./);
  assert.match(call([], [], 'draft', []).rows, /No draft reward yet/);
  assert.match(call([], [], 'history', []).rows, /Nothing has been removed yet\./);
});

/* ---------------------------------------------------------------- click wiring ---------------- */

test('V324 switching reward tabs in the wizard never touches the network', () => {
  const handler = code.slice(code.indexOf("host.querySelectorAll('[data-grow-setup-reward-tab-v324]')"),
    code.indexOf("host.querySelectorAll('[data-grow-setup-reward-remove-v304]')"));
  assert.ok(handler.length > 30, 'the tab handler was found and sliced');
  assert.doesNotMatch(handler, /sb\.rpc|sb\.from/, 'switching tabs must never touch the network');
  assert.match(handler, /state\.rewardTabV324=tab/);
  assert.match(handler, /render\(\)/);
});

test('V324 the reward-added-id diff reuses growRewardPendingChangesV291 — the same function Overview already tests', () => {
  const block = statement('const rewardAddedIdsV324=new Set(growRewardPendingChangesV291(', 'map(reward=>String(reward.id)));');
  assert.match(block, /liveRewards:rewardListFrom\(snapshot\?\.rewards\)/);
  assert.match(block, /draftRewards:rewardListFrom\(Array\.isArray\(snapshot\?\.draftDetail\?\.rewards\)/);
});
