import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

/* v322 — the owner's four switches and the customer's four cards, checked against EACH OTHER.
 *
 * W6 increment 1 inverted the switchboard: the owner turns a programme on, the spine records it,
 * and `customer_portal_capabilities` projects a `customer_visible` flag per programme. Two suites
 * already guard the halves — v314 the switchboard, v310 the card stack — and neither of them can
 * see the join, which is where the customer-side review found its worst defect: a card stack that
 * showed a stamp card and a points card at the same firm and handed both the same figure.
 *
 * This suite runs the REAL customer stack against the spine rows the REAL switchboard produces,
 * so a switch the owner flips and a card the customer sees can never drift apart. It also pins the
 * one rule the client is not allowed to re-derive: visibility comes from `customer_visible`, never
 * from `active` alone (an active points programme with no reward configured is a real state, and
 * the pre-v310 bundle never showed a card for it).
 */

const appJs = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');
const section = (start, end) => {
  const from = appJs.indexOf(start), to = appJs.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `missing section ${start} … ${end}`);
  return appJs.slice(from, to);
};

const esc = value => String(value ?? '').replace(/[&<>"']/g,
  c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));

/* The customer half: the stack, its copy tables, its collaborators — as it ships. */
const customer = new Function('esc', 'CUI', 'walletDate', 'localStorage', 'document', 'window', '$', `
  ${section('const CUSTOMER_COPY=Object.freeze({', 'const normalizeCustomerLocale=')}
  let customerLocale='en';
  ${section('function ct(key,vars={}){', 'function customerMediaUrlV95')}
  ${section('function customerPointTotalV103(', 'const CUSTOMER_SEEN_OFFERS_KEY_V167')}
  ${section('function customerRewardProgressMarkupV167(', 'function customerTierHasProgressV103')}
  ${section('function customerTierRungIconV195(', 'function customerProgrammeSummaryTabsV194')}
  ${section('const programmeStackV310=', 'function customerMerchantExperienceMarkupV95')}
  return {customerProgrammeStackV310,programmeStackV310,programmeStackCardVisibleV310};`)(
  esc, {icon: name => `<svg data-icon="${name}"></svg>`}, () => '1 Jan 2026',
  {getItem: () => null, setItem() {}}, {querySelector: () => null, querySelectorAll: () => []}, {},
  () => null);

/* The owner half: the switch list and the projection the switchboard writes. */
const owner = new Function(`
  ${section('const PROGRAMME_SWITCHES_V314={', 'const PRODUCT_INTERACTION_EVENTS_V100=')}
  return {PROGRAMME_SWITCHES_V314,programmeSwitchesForPublishV314,applyPublishedProgrammeSwitchesV314};`)();

/* What the server does with those switches, written once here from the shipped SQL contract:
   customer_visible is `active` for stamps and referral, and `active AND configured` for points and
   tiers (a points programme needs a reward, a tier programme needs rungs). */
const projectSpine = (switches, {rewardConfigured = true, tiersConfigured = true} = {}) =>
  ['points', 'tiers', 'stamps', 'referral'].map(kind => {
    const active = switches[kind] === true;
    const visible = kind === 'points' ? active && rewardConfigured
      : kind === 'tiers' ? active && tiersConfigured : active;
    return {kind, active, customer_visible: visible,
      running_since: active ? '2026-02-01T00:00:00Z' : null, paused_since: null,
      balance_scope: 'business_pot'};
  });

const TIER = {basis: 'visits', metric: 17, progress_percent: 70,
  current: {label: 'Pioneer', threshold: 10}, next: {label: 'Voyager', threshold: 30},
  tiers: [{label: 'Pioneer', threshold: 10, current: true, achieved: true},
    {label: 'Voyager', threshold: 30}]};
const render = (programmes, extra = {}) => customer.customerProgrammeStackV310({
  programmes, tier: TIER, loyalty: {enabled: true, balance: 240, unit: 'points'},
  presentation: {unit: 'points', balance: 240},
  reward: {name: 'Free flat white', cost_units: 300, remaining_units: 60, available_now: false},
  rewardsHost: true, ...extra});
const cardsIn = html => [...html.matchAll(/data-programme-card="([a-z]+)"/g)].map(match => match[1]);

test('every programme the owner can switch on is a programme the card stack knows', () => {
  /* PROGRAMME_SWITCHES_V314 maps the owner's chosen MODE onto spine rows; the union of the rows
     those modes touch must be a subset of the kinds the customer stack can draw, or an owner could
     turn on a programme with nowhere to appear. */
  const touched = new Set();
  for (const row of Object.values(owner.PROGRAMME_SWITCHES_V314))
    for (const kind of Object.keys(row)) touched.add(kind);
  const drawable = new Set(['points', 'tiers', 'stamps', 'referral']);
  for (const kind of touched) assert.ok(drawable.has(kind), `${kind} has no card`);
  assert.ok(touched.has('points') && touched.has('tiers') && touched.has('stamps'));
});

test('every switch the owner turns on becomes a card, and every one off shows nothing', () => {
  const all = render(projectSpine({points: true, tiers: true, stamps: true, referral: true}));
  assert.deepEqual(cardsIn(all), ['tiers', 'stamps', 'points'],
    'tier first (v319), then the two accruing cards; referral is the slot below them');
  assert.match(all, /id="walletReferralSlot"/);

  const stampsOff = render(projectSpine({points: true, tiers: true, stamps: false, referral: true}));
  assert.deepEqual(cardsIn(stampsOff), ['tiers', 'points']);
  const onlyPoints = render(projectSpine({points: true, tiers: false, stamps: false, referral: false}));
  assert.deepEqual(cardsIn(onlyPoints), ['points']);
  const nothing = render(projectSpine({points: false, tiers: false, stamps: false, referral: false}));
  assert.deepEqual(cardsIn(nothing), [], 'no filler cards for programmes the firm does not run');
});

test('an ACTIVE programme the server has not made customer-visible grows no card', () => {
  /* The owner has switched points on but published no reward: the server says active, and
     customer_visible false, and the pre-v310 tab surface showed nothing. The stack must agree. */
  const spine = projectSpine({points: true, tiers: true, stamps: false, referral: false},
    {rewardConfigured: false});
  assert.equal(spine.find(row => row.kind === 'points').active, true);
  assert.deepEqual(cardsIn(render(spine)), ['tiers']);
  assert.equal(customer.programmeStackCardVisibleV310({kind: 'points', active: true, customer_visible: false}), false,
    'active alone is never a reason to draw a card');
  assert.equal(customer.programmeStackCardVisibleV310({kind: 'points', active: false, customer_visible: false,
    paused_since: '2026-07-01T00:00:00Z'}), true,
    'but a programme that PAUSED keeps its card and says so');
});

test('turning stamps on at a points firm never makes the two cards say the same thing', () => {
  /* This is the join the two existing suites could not see: the owner may run both switches, and
     the pot underneath is still one pot with one unit. */
  const html = render(projectSpine({points: true, tiers: true, stamps: true, referral: true}));
  const cut = kind => {
    const at = html.indexOf(`data-programme-card="${kind}"`);
    const rest = html.slice(at + 1);
    const next = rest.search(/data-programme-card="|id="walletReferralSlot"/);
    return html.slice(at, next < 0 ? html.length : at + 1 + next);
  };
  const numbers = kind => [...cut(kind).replace(/<[^>]*>/g, ' ').matchAll(/\b\d[\d,]*\b/g)].map(m => m[0]);
  const shared = numbers('stamps').filter(value => numbers('points').includes(value));
  assert.deepEqual(shared, [], 'one pot, one card that speaks it');
  assert.equal((html.match(/id="walletRewards"/g) || []).length, 1, 'and one gift catalogue');
});

test('the customer surface never writes the programme switches — it only reads them', () => {
  /* The switchboard owns set_programmes_v314 and businesses.points_mode; the customer bundle must
     contain no path that writes either. (The customer chunk is generated from this same file, so
     the check is over the surface's own region.) */
  const customerSurface = section('const programmeStackV310=', 'async function renderCustomerInAppInbox');
  assert.doesNotMatch(customerSurface, /set_programmes_v314/);
  assert.doesNotMatch(customerSurface, /\.update\(\{[^}]*points_mode/, 'no write of the firm’s own mode');
  assert.doesNotMatch(customerSurface, /from\('business_programmes'\)[\s\S]{0,80}(update|insert|upsert)/);
});
