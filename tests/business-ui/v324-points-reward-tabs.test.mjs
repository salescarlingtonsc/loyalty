/* V324 — Point system's own reward catalogue gets the same Published/Draft/History split as
 * Limited Offer (owner: "do the same for the individual programs").
 *
 * The three buckets are NOT new logic — rewardCardsV250, growPendingNewRewardsV268 and
 * rewardHistoryCardsV294 are pre-existing, already tested elsewhere (v227/v229/v250/v268/v271)
 * and untouched by this change. This file only tests the NEW filter strip built on top of them:
 * it must show exactly one bucket's cards, must not touch the network on tab switch, and must not
 * trip growPage's own "no peer tabs" guard.
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
const programmeStatus = (label, tone) => `<span class="pill ${tone||'off'}">${esc(label)}</span>`;

const rewardCardStatusSrc = statement('const rewardCardStatusV250=milestone=>', "['Paused','warn'];");
const rewardCardHtmlSrc = statement('const rewardCardHtmlV250=({name,cost,unit,status,tone,editKind,rewardId,pending=null})=>{', '};');
const gridBody = statement('const rewardTabStripV324=`<div class="v150-segment" role="group"', "</div>`:''}`;");

const build = new Function('esc', 'CUI', 'growPendingBlockV268', 'programmeStatus', 'canSetupGrow', 'canRewards',
  'rewardJourney', 'rewardCardsV250', 'growPendingNewRewardsV268', 'rewardHistoryCardsV294', 'growPointsRewardTabV324',
  `${rewardCardStatusSrc}\n${rewardCardHtmlSrc}\n${gridBody}\nreturn rewardCardGridV250;`);

const call = (tab, {rewardCards = [], pendingNew = [], history = [], canSetupGrow = true, canRewards = true} = {}) =>
  build(esc, {icon: () => ''}, () => '', programmeStatus, canSetupGrow, canRewards,
    {unit: 'points'}, rewardCards, pendingNew, history, tab);

const LIVE = {name: 'Free drink', cost: 300, unit: 'points', status: 'Live', tone: 'on', editKind: 'catalogue', rewardId: 'r1'};
const SCHEDULED = {name: 'Free Moisturiser', cost: 150, unit: 'points', status: 'Scheduled', tone: 'off', editKind: 'catalogue', rewardId: 'r2'};
const DRAFT_NEW = {id: 'r3', name: 'Free lotion sunscreen', cost: 250};
const RETIRED = {name: 'Free Lotion', cost: 5, unit: 'points', status: 'Retired', tone: 'off', editKind: 'catalogue', rewardId: 'r4'};

test('V324 the Published tab shows only rewardCardsV250\'s own cards, plus Add', () => {
  const html = call('published', {rewardCards: [LIVE, SCHEDULED], pendingNew: [DRAFT_NEW], history: [RETIRED]});
  assert.match(html, /Free drink/);
  assert.match(html, /Free Moisturiser/);
  assert.doesNotMatch(html, /Free lotion sunscreen/, 'a draft-only reward must not appear on Published');
  assert.doesNotMatch(html, /Free Lotion</, 'a retired reward must not appear on Published');
  assert.match(html, /reward-card-add-v250/);
});

test('V324 the Draft tab shows only growPendingNewRewardsV268, never a published card', () => {
  const html = call('draft', {rewardCards: [LIVE], pendingNew: [DRAFT_NEW], history: [RETIRED]});
  assert.match(html, /Free lotion sunscreen/);
  assert.match(html, /Not live yet/);
  assert.doesNotMatch(html, /Free drink/);
  assert.doesNotMatch(html, /reward-card-add-v250/, 'Add reward belongs on Published, not Draft');
});

test('V324 the History tab shows only rewardHistoryCardsV294, and keeps the wizard-bypass attribute', () => {
  const html = call('history', {rewardCards: [LIVE], pendingNew: [DRAFT_NEW], history: [RETIRED]});
  assert.match(html, /Free Lotion/);
  assert.doesNotMatch(html, /Free drink/);
  assert.doesNotMatch(html, /Free lotion sunscreen/);
  /* V301's click handler explicitly routes anything inside [data-reward-history-v294] to the deep
     editor rather than the wizard's quick-edit form — "Those cards therefore keep the full
     editor, which is where un-archiving lives." Moving History into its own tab must not drop
     that attribute, or a retired reward's Edit would silently start opening the wrong screen. */
  assert.match(html, /data-reward-history-v294/);
});

test('V324 empty buckets say so', () => {
  assert.match(call('draft', {}), /No draft reward yet/);
  assert.match(call('history', {}), /Nothing has ended yet/);
});

test('V324 counts appear on the tab labels and the active tab is pressed', () => {
  const html = call('draft', {rewardCards: [LIVE, SCHEDULED], pendingNew: [DRAFT_NEW], history: [RETIRED]});
  assert.match(html, /Published \(2\)/);
  assert.match(html, /Draft \(1\)/);
  assert.match(html, /History \(1\)/);
  assert.match(html, /aria-pressed="true" data-grow-points-tab-v324="draft"/);
  assert.match(html, /aria-pressed="false" data-grow-points-tab-v324="published"/);
});

test('V324 role="group", not "tablist" — this filters one card list, not growPage\'s modules', () => {
  const html = call('published', {rewardCards: [LIVE]});
  assert.match(html, /role="group"/);
  assert.doesNotMatch(html, /role="tablist"|role="tab"/);
});

test('V324 a read-only viewer sees the same three tabs with no Add card', () => {
  const html = call('published', {rewardCards: [LIVE], canSetupGrow: false});
  assert.match(html, /Free drink/);
  assert.doesNotMatch(html, /reward-card-add-v250/);
});

/* ---------------------------------------------------------------- click wiring ---------------- */

test('V324 switching reward tabs never touches the network', () => {
  const handler = code.slice(code.indexOf("outerMain.querySelectorAll('[data-grow-points-tab-v324]')"),
    code.indexOf("outerMain.querySelectorAll('[data-grow-points-tab-v324]')") + 400);
  assert.doesNotMatch(handler, /sb\.rpc|sb\.from/, 'switching tabs must never touch the network');
  assert.match(handler, /growPointsRewardTabV324=tab/);
  assert.match(handler, /growRerenderV322\(\)/);
});

test('V324 the symbol rewardCardGridV250 still appears exactly twice — declared once, used once', () => {
  /* V229's own pin. The grid is now built from a tab strip plus three filtered sections, but it
     is still ONE declaration consumed by ONE ${rewardCardGridV250} inside the points topic —
     restructuring its insides must not turn it into two separate call sites. */
  assert.equal((app.match(/rewardCardGridV250\b/g) || []).length, 2);
});

test("V324 growPointsRewardTabV324 resets to 'published' on route change, same as the other module-level tab flags", () => {
  const resetLine = app.split('\n').find(line => line.includes("growOffersTabV324='published';growPointsRewardTabV324='published';"));
  assert.ok(resetLine, 'the router reset must clear the points reward tab alongside growTopicV229 and growOffersTabV324');
});
