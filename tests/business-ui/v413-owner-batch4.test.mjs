/* nestly_v413 — the owner's fourth annotated batch, business side.

   PHOTO 3 (Rewards Programme -> Overview). "Stamp Card ?" written across the Point system row's
   name, and "Point system off, why still here?" beside it. The row was right to be there — the
   firm IS accruing — but it was named for the wrong engine AND reported the other engine's
   customer count, directly above a Setting column reading "SGD 5.00 spent -> 1 stamp".

   PHOTO 1 (Rewards & Offer -> Overview, the usage table). A brace down the ten gift rows filed
   under Point system: "if under point system, then minimise under Point System", and a second
   brace on the lone Birthday benefit gift: "minimise".

   Both are EXECUTED here rather than matched in the source. tests/business-ui/v271-... pins the
   same earning row by regex and could not have caught either fault: the string it asserted was
   the defect. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const appJs = readFileSync(join(root, 'app', 'app.js'), 'utf8');
const html = readFileSync(join(root, 'app', 'index.html'), 'utf8');

const statement = (start, end, source = appJs) => {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing statement ${start} … ${end}`);
  return source.slice(from, to + end.length);
};
const esc = value => String(value ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* ---------------------------------------------------- 1. the earning row (photo 3) ---------- */

/* The whole growProgrammeEntriesV271 IIFE, evaluated exactly as it ships. Everything it reads is
   injected, because the question this suite answers is what the row says for a GIVEN firm. */
const entriesHarness = ({ model, spineOn, usage, rewards = [] }) => new Function(
  'rewardJourney', 'programmeSpineOnV314', 'growUsageV271', 'snapshot', 'growFirstPublishedV271',
  'growEarnRateTextV271', 'GROW_PROGRAMME_PARENT_NAMES_V375', 'growRewardParentNameV375',
  'growRewardParentKindV385', 'growRewardUsageV271', 'growRetentionUsageV271',
  'retentionOverviewState', 'welcomeOfferStatusV215', 'promotionLifecycleV186',
  'growPointsWordV322', 'growPlanUsageV271', `
  ${statement('const growProgrammeEntriesV271=(()=>{', '\n  })();')}
  return growProgrammeEntriesV271;`)(
  { earning: { model, availableToCustomers: true }, milestones: [], birthday: null, unit: model === 'stamps' ? 'stamps' : 'points' },
  kind => spineOn[kind] ?? null,
  usage,
  { rewards, retention: [], promotions: [], memberships: [], referral: null },
  '2026-07-21T00:00:00+08:00',
  () => 'SGD 5.00 spent → 1 stamp',
  Object.freeze({ points: 'Point system', stamps: 'Stamp card', tiers: 'Tier membership' }),
  reward => ({ points: 'Point system', stamps: 'Stamp card' })[reward.spineKind] || null,
  reward => reward.spineKind || null,
  new Map(), new Map(), () => ({ status: 'Live' }), null, () => ({ state: 'live' }),
  n => `${n} points`, new Map());

/* V468 (owner photo 4: "It should be number of times, not how many customers used"). The server
   publishes 'uses' beside 'customers' and this block reads uses. These fixtures carry BOTH, with
   uses deliberately different from customers, so a silent fall-back to the distinct-customer
   count would change every number below instead of passing unnoticed. */
const USAGE = { point_system: { customers: 2, uses: 3 }, stamp_card: { customers: 7, uses: 11 }, rewards: [] };

test('v413 the earning row is named for the engine the firm actually runs', () => {
  const stamps = entriesHarness({ model: 'stamps', spineOn: { stamps: true, points: false }, usage: USAGE });
  assert.equal(stamps[0].name, 'Stamp card', 'photo 3: the row said "Point system" on a stamp card');
  assert.equal(stamps[0].type, 'Stamp card');
  const points = entriesHarness({ model: 'points', spineOn: { points: true }, usage: USAGE });
  assert.equal(points[0].name, 'Point system', 'a points firm is unchanged');
  assert.equal(points[0].type, 'Point system');
});

test('v413 the earning row reports its OWN engine\'s customer count', () => {
  const stamps = entriesHarness({ model: 'stamps', spineOn: { stamps: true, points: false }, usage: USAGE });
  assert.equal(stamps[0].usageScopeV386, 'stamp_card');
  assert.equal(stamps[0].uses, 11, 'it was printing 3 — whoever had ever touched POINTS');
  const points = entriesHarness({ model: 'points', spineOn: { points: true }, usage: USAGE });
  assert.equal(points[0].usageScopeV386, 'point_system');
  assert.equal(points[0].uses, 3);
});

test('v413 a scope the server did not answer stays Not tracked, never zero', () => {
  /* The V271 honesty rule, re-proved through the new indirection: business_programme_usage_v271
     deliberately returns a null stamp_card for a firm not running stamps. */
  const rows = entriesHarness({ model: 'stamps', spineOn: { stamps: true },
    usage: { point_system: { customers: 2, uses: 3 }, stamp_card: { customers: null, uses: null } } });
  assert.equal(rows[0].uses, null, 'a null must not be laundered into a 0');
});

/* ---------------------------------------------------- 2. the usage table (photo 1) ---------- */

const usageHarness = () => new Function('esc', `
  ${statement('const growOverviewChildRowV324=', "row.type==='Reward';")}
  ${statement('const growAnalyticsCategoryV385=', "(entry.type||'Programme');")}
  /* V470: the bucket builder tags each row with the EVENT its figure counted — the engines count
     earns, the gifts count redemptions — so the harness needs the map, pulled from source rather
     than restated here. */
  ${statement('const GROW_USAGE_VERBS_V470=Object.freeze({', '});')}
  /* nestly_v471: the engine scopes this card deliberately stops measuring. Pulled from source for
     the same reason the verb map is — the harness must not restate the set it is testing. */
  ${statement('const GROW_USAGE_UNTRACKED_SCOPES_V471=Object.freeze([', ']);')}
  ${statement('const growUsageUntrackedScopeV471=', ');')}
  ${statement('const growUsageForEntryV386=', '\n  };')}
  ${statement('const growUsageGroupKeyV413=', "||'group';")}
  const growCountCellV271=(value,verbV470)=>value==null
    ?'<span class="muted">Not tracked</span>'
    :esc(String(Number(value)))+(verbV470?' <span class="muted">'+esc(verbV470)+'</span>':'');
  return (entries,usage,openGroups)=>{
    const growProgrammeEntriesV271=entries;
    ${statement('const growAnalyticsRowsFromUsageV386=', '\n    return out;\n  };')}
    const rows=growAnalyticsRowsFromUsageV386(usage);
    const growUsageOpenGroupsV413=openGroups;
    const markup=${statement('rows.map(row=>{', "}).join('')", statement('${growAnalyticsRowsV375.map(row=>{', "}).join('')").replace('${growAnalyticsRowsV375.map(row=>{', 'rows.map(row=>{'))};
    return {rows,markup};
  };`)(esc);

const GIFT = (name, spineKind, uses) => ({
  name, type: 'Reward', usageScopeV386: 'reward', usageIdV386: name,
  parent: { points: 'Point system', stamps: 'Stamp card' }[spineKind], parentKind: spineKind,
  uses, state: 'live'
});
/* The owner's own table: a stamps firm still carrying ten gifts from its points era, plus the two
   that hang off the stamp card, plus the birthday gift the second brace was drawn on. */
const OWNER_ENTRIES = [
  { name: 'Stamp card', type: 'Stamp card', usageScopeV386: 'stamp_card' },
  ...['Free Lotion', 'Free facial add-on', 'Free Facial cream', 'Abc', 'Free drink',
      'Free Lolipop', 'Free lotion sunscreen', 'Free Moisturiser', 'Free Shampoo', 'moisturizer']
    .map(name => GIFT(name, 'points', 0)),
  GIFT('Free Massage Oil', 'stamps', 1),
  { name: 'Birthday treat', type: 'Birthday benefit', usageScopeV386: 'birthday' },
  { ...GIFT('Free lotion', 'points', 0), parent: 'Birthday benefit' }
];
const OWNER_USAGE = { stamp_card: { customers: 7, uses: 11 }, point_system: { customers: 2, uses: 3 },
  birthday: { customers: 0, uses: 0 }, rewards: [{ reward_id: 'Free Massage Oil', customers: 1, uses: 1 }] };

test('v413 every gift sits in a group, and every group starts minimised', () => {
  const build = usageHarness();
  const { rows, markup } = build(OWNER_ENTRIES, OWNER_USAGE, new Set());
  const gifts = rows.filter(row => row.childV410);
  assert.equal(gifts.length, 12);
  assert.ok(gifts.every(row => row.groupV413), 'photo 1: a gift with no group is a flat orphan row');
  /* Hidden is the DEFAULT: the braces said "minimise", so a fresh render shows headers only. */
  const hiddenRows = markup.match(/<tr hidden/g) || [];
  assert.equal(hiddenRows.length, 12, 'every gift row must ship hidden until its group is opened');
  assert.match(markup, /aria-expanded="false"/);
  assert.doesNotMatch(markup, /aria-expanded="true"/);
});

test('v413 a gift whose programme has no row of its own still gets a header', () => {
  /* This is the case v413 CREATED and has to answer: the firm runs stamps, so only the stamp card
     is pushed as an engine row, and ten points gifts would otherwise have had no parent at all. */
  const build = usageHarness();
  const { rows } = build(OWNER_ENTRIES, OWNER_USAGE, new Set());
  const header = rows.find(row => row.category === 'Point system');
  assert.ok(header, 'the ten points gifts must have somewhere to sit');
  assert.equal(header.synthV413, true);
  assert.equal(header.childCountV413, 10);
  assert.equal(header.uses, null,
    'a synthesised header was never measured — summing its gifts would count one customer twice');
  const kids = rows.filter(row => row.groupV413 === header.groupV413 && row.childV410);
  assert.equal(kids.length, 10);
  /* And it never claims to be a programme in its own right. */
  const { markup } = build(OWNER_ENTRIES, OWNER_USAGE, new Set());
  assert.match(markup, /Not counted as a programme of its own/);
});

/* nestly_v471 reversed half of what this test pinned. The owner's ruling on photo 4 is that an
   engine's earn count is not wanted on this card at all, so a REAL engine row now carries no
   figure — but it is still a real row, not a synthesised header, and it still adopts its own
   gifts. Both of those are what this test is actually here to protect, and both still hold. */
test('v471 a real engine row is unmeasured but still adopts its own gifts', () => {
  const build = usageHarness();
  const { rows } = build(OWNER_ENTRIES, OWNER_USAGE, new Set());
  const card = rows.find(row => row.category === 'Stamp card');
  assert.equal(card.synthV413, undefined, 'this one IS a real programme row, not a synthesised header');
  assert.equal(card.untrackedV471, true, 'the engine is deliberately not counted here any more');
  assert.equal(card.uses, null, 'v470 printed 11 earns; the owner asked for no figure at all');
  assert.equal(card.childCountV413, 1);
  const birthday = rows.find(row => row.category === 'Birthday benefit');
  assert.equal(birthday.childCountV413, 1, 'the second brace in photo 1');
});

test('v413 opening one group reveals only that group', () => {
  const build = usageHarness();
  const shut = build(OWNER_ENTRIES, OWNER_USAGE, new Set());
  const key = shut.rows.find(row => row.category === 'Point system').groupV413;
  const { markup } = build(OWNER_ENTRIES, OWNER_USAGE, new Set([key]));
  const visible = [...markup.matchAll(/<tr(?! hidden)[^>]*data-grow-usage-child-v413/g)];
  assert.equal(visible.length, 10, 'exactly the opened group, and none of the other two');
  assert.equal((markup.match(/<tr hidden/g) || []).length, 2);
  assert.match(markup, /aria-expanded="true"/);
});

test('v413 a group with no gifts is plain text, not a button that opens onto nothing', () => {
  const build = usageHarness();
  const { markup } = build([{ name: 'Referrals', type: 'Referrals', usageScopeV386: 'referrals' }],
    { referrals: { customers: 0, uses: 0 } }, new Set());
  assert.doesNotMatch(markup, /grow-usage-disclosure-v413/);
  assert.match(markup, /<b data-merchant-content>Referrals<\/b>/);
});

test('v413 the disclosure is styled as the row name, not as a button dropped in a cell', () => {
  /* A bordered/padded control here would shift the name off the column edge every other parent
     row aligns to — measured in v401b and kept. */
  const rule = html.slice(html.indexOf('.grow-usage-disclosure-v413{'));
  assert.match(rule.slice(0, 260), /background:none/);
  assert.match(rule.slice(0, 260), /border:0/);
  assert.match(rule.slice(0, 260), /padding:0/);
  assert.match(html, /\.grow-usage-disclosure-v413:focus-visible\{outline:/,
    'it is a real button and must show a focus ring');
});
