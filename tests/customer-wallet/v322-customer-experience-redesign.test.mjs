import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

/* v322 — the customer-experience redesign, pinned by BEHAVIOUR.
 *
 * The measured browser review of 2026-08-14 found nineteen things wrong with the shop page a
 * customer opens at a counter. Seven of them were invisible to the suites that already existed,
 * because those suites assert on the SOURCE: a regex stays green while the screen says the wrong
 * number, in the wrong language, under the wrong heading. So everything here runs the real
 * renderers and asserts on what they produce, and the wiring tests fire the control a thumb would
 * hit and check what leaves the browser.
 *
 * What is pinned, by the brief's own item numbers:
 *   A1/B7  no two cards print the same figure or name the same target
 *   A2     a stamp card never says "points"
 *   A3     the gift catalogue lives with the balance that pays for it
 *   A6     a silent repaint carries the hydrated sections across instead of re-emitting shells
 *   A7     an idle tick asks ONE question; the envelope's timestamp is not mistaken for a change
 *   B1     "Ready now" is a control that reaches the reward's QR
 *   B2     the bring-back credit reaches the top strip
 *   B3     no earn rate is invented, and the honest line renders the moment the field exists
 *   B4     the shop page states expiry from the payload it already holds
 *   B5     every sentence the surface writes is ct()-routed, in four languages
 *   B6     one pictogram per programme
 *   C1/C3  one hero number, in the strip; a tier card with no rail
 */

const appJs = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');
const section = (start, end, source = appJs) => {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing section ${start} … ${end}`);
  return source.slice(from, to);
};

/* The real renderers, the real copy tables, nothing about the sentences stubbed. */
const esc = value => String(value ?? '').replace(/[&<>"']/g,
  c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
const icons = {star: 'STAR', crown: 'CROWN', check: 'CHECK', giftcard: 'GIFT', redeem: 'REDEEM',
  scan: 'SCAN', forward: 'FWD', referrals: 'REF'};

const build = ({localStorageStub = null, documentStub = null, windowStub = null, $stub = null} = {}) =>
  new Function('esc', 'CUI', 'walletDate', 'localStorage', 'document', 'window', '$', 'CSS', `
  ${section('const CUSTOMER_COPY=Object.freeze({', 'const normalizeCustomerLocale=')}
  let customerLocale='en';
  ${section('function ct(key,vars={}){', 'function customerMediaUrlV95')}
  ${section('function customerPointTotalV103(', 'const CUSTOMER_SEEN_OFFERS_KEY_V167')}
  ${section('function customerRewardProgressMarkupV167(', 'function customerTierHasProgressV103')}
  ${section('function customerTierRungIconV195(', 'function customerProgrammeSummaryTabsV194')}
  ${section('const programmeStackV310=', 'function customerMerchantExperienceMarkupV95')}
  ${section('const CUSTOMER_WALLET_LIVE_NODES_V322=', 'function customerWalletSilentPaintV319')}
  ${section('function customerWalletProbeFactsV322(', 'function customerWalletForgetSurfaceCacheV322')}
  ${section('function customerWalletHoldScrollV322(', '/* v322 (A7). A tick cost ELEVEN reads')}
  return {customerProgrammeStackV310,customerWalletStripMarkupV322,customerNextUpMarkupV322,
    customerFirstVisitMomentMarkupV322,customerWireClaimShortcutsV322,customerWalletStripOfferActionV322,
    customerExpiryLineV322,customerEarnRateLineV322,programmePotKindV322,customerStampTargetV310,
    CUSTOMER_WALLET_LIVE_NODES_V322,customerWalletProbeFactsV322,customerWalletHoldScrollV322,
    ct,setLocale:value=>{customerLocale=value}};`)(
    esc,
    {icon: name => `<svg data-icon="${icons[name] || name}"></svg>`},
    value => new Date(value).toLocaleDateString('en-SG', {timeZone: 'Asia/Singapore', dateStyle: 'medium'}),
    localStorageStub || {getItem: () => null, setItem() {}},
    documentStub || {querySelector: () => null, querySelectorAll: () => []},
    windowStub || {},
    $stub || (() => null),
    {escape: value => String(value)});

const harness = build();

const spine = overrides => ['points', 'tiers', 'stamps', 'referral'].map(kind => ({
  kind, active: false, customer_visible: false, running_since: null, paused_since: null,
  balance_scope: 'business_pot', ...(overrides[kind] || {})}));
const RUN = {active: true, customer_visible: true, running_since: '2026-02-01T00:00:00Z'};
const TIER = {basis: 'visits', metric: 17, progress_percent: 70, points_mode: 'both',
  current: {label: 'Pioneer', threshold: 10}, next: {label: 'Voyager', threshold: 30},
  tiers: [{label: 'Explorer', threshold: 3, achieved: true}, {label: 'Pioneer', threshold: 10, current: true, achieved: true},
    {label: 'Voyager', threshold: 30}, {label: 'Legend', threshold: 60}]};
/* The shape the review measured: a POINTS pot at a firm whose spine also runs stamps. */
const POINTS_POT = {enabled: true, balance: 240, unit: 'points'};
const REWARD = {name: 'Free flat white', cost_units: 300, remaining_units: 60, available_now: false};
const STAMP_POT = {enabled: true, balance: 6, unit: 'stamps'};
const STAMP_REWARD = {name: 'Free pastry', cost_units: 10, remaining_units: 4, available_now: false};

const stack = (programmes, extra = {}) => harness.customerProgrammeStackV310({
  programmes, tier: TIER, loyalty: POINTS_POT, presentation: {unit: 'points', balance: 240},
  reward: REWARD, rewardsHost: true, ...extra});
const cardOf = (kind, html) => {
  const at = html.indexOf(`data-programme-card="${kind}"`);
  assert.ok(at >= 0, `no card ${kind}`);
  /* Back up to the element's own opening tag, so textOf() strips the whole tag rather than
     leaving its attributes behind as "text" the assertions would then read. */
  const from = html.lastIndexOf('<', at);
  const rest = html.slice(at + 1);
  const next = rest.search(/data-programme-card="|id="walletReferralSlot"/);
  const end = next < 0 ? html.length : html.lastIndexOf('<', at + 1 + next);
  return html.slice(from, end);
};
/* What a customer READS: tags out, entities back, whitespace collapsed. */
const textOf = html => html.replace(/<[^>]*>/g, ' ')
  .replace(/&amp;/g, '&').replace(/&#39;/g, "'").replace(/&quot;/g, '"')
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
  .replace(/\s+/g, ' ').trim();
const numbersIn = html => [...textOf(html).matchAll(/\b\d[\d,]*\b/g)].map(m => m[0]);

/* ------------------------------------------------------- A1 / B7 · one pot, one card speaks it */

test('the two accruing cards never print the same figure at a multi-programme shop', () => {
  const html = stack(spine({points: RUN, tiers: RUN, stamps: RUN, referral: RUN}));
  const stamps = numbersIn(cardOf('stamps', html)), points = numbersIn(cardOf('points', html));
  const shared = stamps.filter(value => points.includes(value));
  assert.deepEqual(shared, [], `both cards printed ${JSON.stringify(shared)}`);
  /* And the measured symptom itself: the pot's balance, printed twice. */
  assert.equal((html.match(/\b240\b/g) || []).length, 0,
    'the balance belongs to the wallet strip now, not to a card');
});

test('only the card that owns the pot names the reward as its target', () => {
  const html = stack(spine({points: RUN, tiers: RUN, stamps: RUN, referral: RUN}));
  assert.match(textOf(cardOf('points', html)) + textOf(harness.customerNextUpMarkupV322(
    {loyalty: POINTS_POT, presentation: {unit: 'points'}, reward: REWARD})), /Free flat white/);
  assert.doesNotMatch(textOf(cardOf('stamps', html)), /Free flat white/,
    'a stamps card at a points-pot firm names no target it cannot count toward');
});

test('the pot kind is read from the server answer, never guessed', () => {
  assert.equal(harness.programmePotKindV322({loyalty: {model: 'stamps', unit: 'stamps'}}), 'stamps');
  assert.equal(harness.programmePotKindV322({loyalty: {model: 'classic', unit: 'points'}}), 'points');
  assert.equal(harness.programmePotKindV322({loyalty: {}, presentation: {unit: 'stamps'}}), 'stamps');
  assert.equal(harness.programmePotKindV322({}), 'points', 'an empty answer is the points default');
});

/* ------------------------------------------------------------------- A2 · stamps speak stamps */

test('a stamp card at a points-pot firm prints no points figure and no points word', () => {
  const stamps = cardOf('stamps', stack(spine({points: RUN, stamps: RUN})));
  assert.doesNotMatch(textOf(stamps), /\bpoints?\b/i, 'measured: "Stamp card — 240 points"');
  assert.deepEqual(numbersIn(stamps), []);
  assert.match(textOf(stamps), /Stamps are added at the counter/);
});

test('a stamp card at a stamps-pot firm speaks in stamps whatever the reward costs', () => {
  const cheap = cardOf('stamps', stack(spine({stamps: RUN}),
    {loyalty: STAMP_POT, presentation: {unit: 'stamps', balance: 6}, reward: STAMP_REWARD}));
  assert.match(cheap, /customer-programme-stamp-rings/, '10 rings for a 10-stamp card');
  assert.match(textOf(cheap), /4 more stamps/);
  /* Past the ring limit the row cannot be read at 390px, so the count stands in — in STAMPS. */
  const dear = cardOf('stamps', stack(spine({stamps: RUN}),
    {loyalty: {enabled: true, balance: 40, unit: 'stamps'}, presentation: {unit: 'stamps', balance: 40},
      reward: {name: 'Free hamper', cost_units: 60, remaining_units: 20, available_now: false}}));
  assert.doesNotMatch(dear, /customer-programme-stamp-rings/);
  assert.match(textOf(dear), /40 stamps/);
  assert.doesNotMatch(textOf(dear), /\bpoints\b/i);
  assert.equal(harness.customerStampTargetV310({cost_units: 60}), 0, 'never invents an N');
});

/* --------------------------------------------------------------------- A3 · where gifts live */

test('the gift catalogue hangs off the card that speaks the pot it is priced in', () => {
  const bothLive = stack(spine({points: RUN, tiers: RUN, stamps: RUN}));
  assert.equal((bothLive.match(/id="walletRewards"/g) || []).length, 1, 'never two hosts');
  assert.match(cardOf('points', bothLive), /id="walletRewards"/, 'a points pot ⇒ Points & gifts');
  assert.doesNotMatch(cardOf('stamps', bothLive), /id="walletRewards"/);

  const stampsFirm = stack(spine({points: RUN, tiers: RUN, stamps: RUN}),
    {loyalty: STAMP_POT, presentation: {unit: 'stamps', balance: 6}, reward: STAMP_REWARD});
  assert.match(cardOf('stamps', stampsFirm), /id="walletRewards"/, 'a stamps pot ⇒ the stamp card');
  assert.doesNotMatch(cardOf('points', stampsFirm), /id="walletRewards"/);

  const noPointsCard = stack(spine({stamps: RUN}),
    {loyalty: STAMP_POT, presentation: {unit: 'stamps'}, reward: STAMP_REWARD});
  assert.match(noPointsCard, /id="walletRewards"/, 'a catalogue is never orphaned');
});

/* ------------------------------------------------------------------------ B6 · one glyph each */

test('every programme card wears a different pictogram', () => {
  const html = stack(spine({points: RUN, tiers: RUN, stamps: RUN, referral: RUN}));
  const glyphs = ['tiers', 'stamps', 'points']
    .map(kind => cardOf(kind, html).match(/<svg data-icon="([^"]+)"/)?.[1]);
  assert.equal(glyphs.filter(Boolean).length, 3);
  assert.equal(new Set(glyphs).size, 3, `measured: tiers and stamps shared one glyph (${glyphs})`);
});

/* ------------------------------------------------------ C1/C3 · one hero, and a tier with no rail */

test('the hero number lives in the wallet strip, and no card repeats it', () => {
  const strip = harness.customerWalletStripMarkupV322({business: {name: 'Hougang ABC Cafe'},
    presentation: {unit: 'points', balance: 240}, loyalty: POINTS_POT, reward: REWARD, rewardsAvailable: true});
  const html = stack(spine({points: RUN, tiers: RUN, stamps: RUN, referral: RUN}));
  assert.equal(((strip + html).match(/class="customer-programme-balance"/g) || []).length, 1);
  assert.match(textOf(strip), /Hougang ABC Cafe 240 points/);
  assert.match(strip, /data-cux-see-rewards-v322/, 'one action, and it is useful when nothing is ready');
  const ready = harness.customerWalletStripMarkupV322({business: {name: 'Hougang ABC Cafe'},
    presentation: {unit: 'points', balance: 320}, loyalty: {enabled: true, balance: 320, unit: 'points'},
    reward: {...REWARD, remaining_units: 0, available_now: true}, rewardsAvailable: true});
  assert.match(ready, /data-cux-claim-v322="reward" data-cux-claim-label-v322="Free flat white"/);
  assert.equal((ready.match(/class="btn sm/g) || []).length, 1, 'exactly one solid action');
});

test('the tier card is a badge, one bar and a sentence — no rail on a phone', () => {
  const nine = {...TIER, tiers: ['Essentia', 'Bronze', 'Silver', 'Gold', 'Platinum', 'Diamond', 'Obsidian', 'Meridian', 'Founder']
    .map((label, index) => ({label, threshold: index * 12, current: index === 3, achieved: index <= 3}))};
  const card = cardOf('tiers', stack(spine({tiers: RUN, points: RUN}), {tier: nine}));
  assert.equal((card.match(/class="customer-tier-milestone/g) || []).length, 0,
    'measured: nine markers on a 324px track, the last one hanging 11px off the end');
  assert.match(card, /customer-tier-badge-v322">Pioneer</);
  assert.equal((card.match(/customer-tier-bar-track/g) || []).length, 1, 'one bar, to the next rung');
  assert.match(card, /customer-tier-rungs is-vertical-v322/, 'the full ladder is a vertical list');
  assert.match(textOf(card), /9 tiers/);
});

/* ---------------------------------------------------------------------- B4 · expiry, B3 · earning */

test('the shop page states expiry from the payload it already holds, and nothing when there is none', () => {
  const line = harness.customerExpiryLineV322({presentation: {unit: 'points'},
    expiry: {mode: 'fixed', expiring_units: 60, next_expiry_at: '2026-09-30T00:00:00Z'}});
  assert.match(line, /^60 points expire on /);
  assert.equal(harness.customerExpiryLineV322({presentation: {unit: 'points'},
    expiry: {mode: 'none', expiring_units: 0, next_expiry_at: null}}), '',
    'a firm with no expiry is not told its points expire');
  const block = harness.customerNextUpMarkupV322({loyalty: POINTS_POT, presentation: {unit: 'points'},
    reward: REWARD, expiry: {expiring_units: 60, next_expiry_at: '2026-09-30T00:00:00Z'}});
  assert.match(textOf(block), /60 more for Free flat white\./);
  assert.match(textOf(block), /60 points expire on /);
});

test('no earn rate is invented, and the honest line renders the moment the server carries one', () => {
  assert.equal(harness.customerEarnRateLineV322({loyalty: POINTS_POT, presentation: {unit: 'points'}}), '',
    'today the payload has no earn field — silence is the only honest answer');
  assert.equal(harness.customerEarnRateLineV322({loyalty: {...POINTS_POT, earn: {}}, presentation: {unit: 'points'}}), '',
    'an empty earn object states nothing either');
  assert.equal(harness.customerEarnRateLineV322({loyalty: {...POINTS_POT, earn: {points_per_dollar: 10}},
    presentation: {unit: 'points'}}), '10 points for every SGD 1 you spend.');
  assert.equal(harness.customerEarnRateLineV322({loyalty: {enabled: true, unit: 'stamps', earn: {stamp_per_cents: 1500}},
    presentation: {unit: 'stamps'}}), '1 stamps for every SGD 15 you spend.');
});

/* ------------------------------------------------------------------------- B5 · four languages */

test('nothing the surface writes on the tier card is English on a Chinese, Malay or Tamil phone', () => {
  const english = /You're now at|Visits move you up|Points stay yours to spend|All tiers and what they unlock|\btiers\b|Not yet yours|Reached|Your tier|Benefits not published yet|From \d/;
  for (const locale of ['zh-CN', 'ms', 'ta']) {
    harness.setLocale(locale);
    const html = stack(spine({points: RUN, tiers: RUN, stamps: RUN, referral: RUN}));
    const text = textOf(cardOf('tiers', html));
    assert.doesNotMatch(text, english, `${locale}: ${text.slice(0, 140)}`);
    /* And it is not merely blank: the sentence is there, in that language. */
    assert.ok(text.length > 40, `${locale} tier card is empty`);
  }
  harness.setLocale('en');
});

test('the four locale tables carry every key the redesign introduced', () => {
  const keys = ['walletBalanceLabel', 'showQr', 'seeRewards', 'useOffer', 'claimShow', 'nextUpTitle',
    'expiryLine', 'earnRateSpend', 'tierNowLabel', 'tierNotYet', 'tierBothVisits', 'tierLadderTitle',
    'tierLadderCount', 'tierRungCurrent', 'tierRungReached', 'tierRungLocked', 'tierFromFirst',
    'tierFromVisits', 'tierToGoVisits', 'tierNoBenefits', 'stampsAtCounter', 'rewardsLede',
    'rewardReadyChip', 'rewardToGo', 'rewardTierLock', 'rewardValidEverywhere', 'rewardHowToUse',
    'rewardTermsTitle', 'rewardUseWithin', 'rewardsUncheckedTitle', 'rewardsUncheckedBody',
    'firstVisitTitle', 'firstVisitDistance', 'firstVisitNoReward', 'firstVisitGotIt'];
  for (const locale of ['en', 'zh-CN', 'ms', 'ta']) {
    harness.setLocale(locale);
    for (const key of keys) {
      const value = harness.ct(key);
      assert.notEqual(value, key, `${locale} is missing ${key}`);
      assert.ok(String(value).trim().length > 0);
    }
  }
  /* A key that exists in every table but says the same English everywhere is not translated. */
  harness.setLocale('ta');
  const tamil = harness.ct('tierLadderTitle');
  harness.setLocale('en');
  assert.notEqual(tamil, harness.ct('tierLadderTitle'));
});

/* ------------------------------------------------------------- the first-visit moment, Part D */

test('the first-visit moment names the real reward, fires once, and never invents one', () => {
  const store = new Map();
  const once = build({localStorageStub: {getItem: key => store.get(key) ?? null,
    setItem: (key, value) => store.set(key, value)}});
  const args = {business: {id: 'biz-1', slug: 'hougang-abc'}, presentation: {unit: 'points'},
    loyalty: {enabled: true, balance: 0, unit: 'points'},
    reward: {name: 'Free flat white', cost_units: 300, remaining_units: 300, available_now: false}};
  const first = once.customerFirstVisitMomentMarkupV322(args);
  assert.match(textOf(first), /How rewards work here Collect 300 points here and Free flat white is yours\./);
  /* And it is worn BY the next-up block rather than repeating its number one line above it. */
  const block = once.customerNextUpMarkupV322({loyalty: args.loyalty, presentation: args.presentation,
    reward: args.reward, firstVisitV322: first});
  assert.match(block, /data-first-visit-v322="true"/);
  assert.equal((textOf(block).match(/300/g) || []).length, 1, 'the distance is stated once');
  assert.doesNotMatch(textOf(block), /Next up/);
  assert.equal(store.get('peekaa.customer.first-visit.v322.biz-1'), 'shown');
  /* Same page, a background repaint: the moment must not vanish mid-sentence. */
  assert.equal(once.customerFirstVisitMomentMarkupV322(args), first);
  /* A NEW page (a fresh module state) with the same storage: never again. */
  const later = build({localStorageStub: {getItem: key => store.get(key) ?? null, setItem: () => {}}});
  assert.equal(later.customerFirstVisitMomentMarkupV322(args), '');

  const bare = build({localStorageStub: {getItem: () => null, setItem: () => {}}});
  const honest = bare.customerFirstVisitMomentMarkupV322({...args, business: {id: 'biz-2'}, reward: null});
  assert.match(textOf(honest), /has not set a reward yet/);
  assert.doesNotMatch(textOf(honest), /\d/, 'nothing in reach means no number at all');
});

/* --------------------------------------------------------------- B1 · Ready now reaches the QR */

/* The smallest DOM these two functions actually touch, with real element identity so a test can
   see WHICH reward's control was pressed. */
const makeRow = (name, ready, redeem) => ({
  dataset: {rewardRowV322: `catalog:${name}`, rewardReadyV322: ready ? 'true' : 'false', rewardNameV322: name},
  open: false, scrollIntoView() {},
  querySelector: selector => selector === '[data-customer-redeem]' && ready ? redeem : null});
const makeButton = dataset => ({dataset, onclick: null, scrollIntoView() {}});

test('a tap on a Ready row opens that reward’s QR through the catalogue’s own control', () => {
  const pressed = [];
  const rows = [makeRow('Free croissant', false, null),
    makeRow('Free flat white', true, {click: () => pressed.push('Free flat white')}),
    makeRow('Free cold brew', true, {click: () => pressed.push('Free cold brew')})];
  const readyRow = makeButton({cuxClaimV322: 'reward', cuxClaimLabelV322: 'Free flat white'});
  const documentStub = {
    querySelectorAll: selector => selector === '[data-reward-row-v322]' ? rows
      : selector === '[data-cux-claim-v322]' ? [readyRow] : [],
    querySelector: () => null};
  const wired = build({documentStub, $stub: () => null});
  wired.customerWireClaimShortcutsV322();
  assert.equal(typeof readyRow.onclick, 'function', 'the row is a control, not a label');
  readyRow.onclick();
  assert.deepEqual(pressed, ['Free flat white'], 'the tap reaches the reward it named');
  assert.equal(rows[1].open, true, 'and the row it opens is that reward’s own row');
});

test('a Ready row whose catalogue has not hydrated yet takes the customer to the rewards, never nowhere', () => {
  const scrolled = [];
  const readyRow = makeButton({cuxClaimV322: 'reward', cuxClaimLabelV322: 'Free flat white'});
  const rewardsHost = {scrollIntoView: () => scrolled.push('walletRewards')};
  const wired = build({
    documentStub: {querySelectorAll: selector => selector === '[data-cux-claim-v322]' ? [readyRow] : [],
      querySelector: () => null},
    $stub: id => id === 'walletRewards' ? rewardsHost : null});
  wired.customerWireClaimShortcutsV322();
  readyRow.onclick();
  assert.deepEqual(scrolled, ['walletRewards']);
});

test('the birthday row goes to the section that activates it, not to a reward QR', () => {
  const scrolled = [];
  const birthdayRow = makeButton({cuxClaimV322: 'birthday', cuxClaimLabelV322: 'Birthday treat'});
  const wired = build({
    documentStub: {querySelectorAll: selector => selector === '[data-cux-claim-v322]' ? [birthdayRow] : [],
      querySelector: () => null},
    $stub: id => id === 'walletBirthdayParticipation'
      ? {scrollIntoView: () => scrolled.push('birthday')} : null});
  wired.customerWireClaimShortcutsV322();
  birthdayRow.onclick();
  assert.deepEqual(scrolled, ['birthday']);
});

/* ----------------------------------------------------------- B2 · the bring-back credit's place */

test('the welcome-back credit reaches the strip and presses the offer’s own redeem control', () => {
  const pressed = [];
  let added = '';
  const stripButton = {dataset: {cuxStripOfferV322: 'ent-1'}, onclick: null};
  const slot = {
    querySelector: selector => selector === '[data-cux-claim-v322]' ? null : null,
    querySelectorAll: selector => selector === '[data-cux-strip-offer-v322]' ? [stripButton] : [],
    insertAdjacentHTML: (position, html) => {added = html}};
  const growthControl = {click: () => pressed.push('growth')};
  const wired = build({
    $stub: id => id === 'customerWalletStripSlotV322' ? slot : null,
    documentStub: {querySelector: selector => /data-entitlement-id="ent-1"/.test(selector) ? growthControl : null,
      querySelectorAll: () => []},
    windowStub: {NestlyGrowthOffers: {money: (cents, currency) => `${currency} ${(cents / 100).toFixed(2)}`}}});
  wired.customerWalletStripOfferActionV322([{entitlementId: 'ent-1', valueCents: 500, currency: 'SGD',
    label: 'Welcome-back credit'}]);
  assert.match(added, /data-cux-strip-offer-v322="ent-1"/);
  assert.match(textOf(added), /Use SGD 5\.00/);
  stripButton.onclick();
  assert.deepEqual(pressed, ['growth'], 'one redemption path, not two');
});

test('an empty growth answer changes the strip not at all', () => {
  let touched = false;
  const slot = {querySelector: () => null, querySelectorAll: () => [],
    insertAdjacentHTML: () => {touched = true}};
  const wired = build({$stub: () => slot});
  wired.customerWalletStripOfferActionV322([]);
  wired.customerWalletStripOfferActionV322(null);
  assert.equal(touched, false);
});

/* --------------------------------------------------- A6/A7 · the refresh, and what it costs */

test('the referral card is carried across a silent repaint by the SLOT the new markup emits', () => {
  const pairs = harness.CUSTOMER_WALLET_LIVE_NODES_V322.map(entry => entry.join('→'));
  assert.ok(pairs.includes('walletReferral→walletReferralSlot'),
    'a live referral card matched by its own id would be dropped and re-fetched — the page collapse');
  assert.ok(pairs.includes('walletSections→walletSections'));
  assert.ok(pairs.includes('walletRewards→walletRewards'));
});

test('the probe signature is taken over the card, never over the envelope that carries a timestamp', () => {
  const first = harness.customerWalletProbeFactsV322({as_of: '2026-08-14T10:00:00Z', card: {balance: 240}});
  const second = harness.customerWalletProbeFactsV322({as_of: '2026-08-14T10:00:20Z', card: {balance: 240}});
  assert.deepEqual(first, second, 'statement_timestamp() would make every tick look like a change');
  assert.deepEqual(harness.customerWalletProbeFactsV322({cards: [{balance: 1}]}), [{balance: 1}]);
  assert.equal(harness.customerWalletProbeFactsV322(null), null);
});

test('a clamped scroll is corrected back, and a customer who scrolls on is never pulled back', () => {
  const run = frames => {
    const calls = [];
    let now = 0;
    const scroller = {isConnected: true, scrollTop: frames[0].scrollTop, scrollHeight: frames[0].scrollHeight};
    let step = 0;
    const raf = callback => {
      if (step >= frames.length) return;
      const frame = frames[step++];
      scroller.scrollTop = frame.scrollTop; scroller.scrollHeight = frame.scrollHeight;
      now += 16;
      callback();
      calls.push(scroller.scrollTop);
    };
    const wired = build({});
    const previousRaf = globalThis.requestAnimationFrame;
    globalThis.requestAnimationFrame = raf;
    try {wired.customerWalletHoldScrollV322(scroller, 1237)} finally {
      globalThis.requestAnimationFrame = previousRaf;
    }
    return calls;
  };
  /* The measured failure: the document is briefly 370px shorter and the browser clamps the
     restored offset to 1072 — a 165px jump for someone reading the bottom of the page. */
  const corrected = run([{scrollTop: 1072, scrollHeight: 1865}, {scrollTop: 1072, scrollHeight: 2235}]);
  assert.deepEqual(corrected, [1237, 1237], 'the reader is put back where they were, and held there');
  /* And a customer who scrolled further down themselves keeps their place. */
  assert.deepEqual(run([{scrollTop: 1500, scrollHeight: 2235}]), [1500]);
  /* A page still too short to hold the offset is left alone rather than fought. */
  assert.deepEqual(run([{scrollTop: 300, scrollHeight: 900}]), [300]);
});
