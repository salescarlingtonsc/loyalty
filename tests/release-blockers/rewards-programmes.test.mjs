/**
 * RELEASE BLOCKER — the seven Rewards programmes still render, and a paused one still doesn't.
 *
 * WHY THIS FILE IS IN release-blockers/ AND NOT IN grow/ OR customer-wallet/
 * tests/release-blockers/ held three files, none of which touched Rewards, while Rewards is the
 * product. A mutation test in August 2026 planted two real Rewards defects and 3297 tests stayed
 * green. This is the floor under that: seven programmes, each with a business-side projection
 * and a customer-side render, each with at least one NEGATIVE assertion. It is a gate, not a
 * platform — the exhaustive per-programme suites live in tests/grow/ and tests/customer-wallet/.
 *
 * EVERY ASSERTION EXECUTES REAL PRODUCT CODE. The functions are lifted out of app/app.js by
 * source slice and instantiated with `new Function`, the technique proven by
 * tests/customer-wallet/v323-stamp-quest.test.mjs and used across this repo. Nothing here is a
 * regex over source: a grep stays green while the behaviour underneath it dies, which is exactly
 * how the planted defects survived. If a slice stops resolving, this file fails loudly at import
 * rather than quietly asserting nothing.
 *
 * THE NEGATIVES ARE THE POINT. A programme the firm has PAUSED must not present to the customer
 * as if it were accruing, and a programme with no configuration must not paint a card claiming
 * one. Those are the mutations that slipped through.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(join(root, 'app', 'app.js'), 'utf8');

/** Slice a top-level declaration out of app/app.js, from its `function`/`const` to a marker. */
const topLevel = (name, endMarker) => {
  const start = app.search(new RegExp(`^(?:const|function) ${name}\\b`, 'm'));
  assert.ok(start >= 0, `missing top-level declaration: ${name}`);
  const end = app.indexOf(endMarker, start);
  assert.ok(end > start, `missing end marker for ${name}: ${endMarker}`);
  return app.slice(start, end);
};

/** Slice a block out of the middle of a closure, by its opening line and a following marker. */
const closure = (head, endMarker) => {
  const start = app.indexOf(head);
  assert.ok(start >= 0, `missing closure block: ${head}`);
  const end = app.indexOf(endMarker, start);
  assert.ok(end > start, `missing end marker for block: ${endMarker}`);
  return app.slice(start, end);
};

/* ---------------------------------------------------------------- shared stubs */

const esc = value => String(value ?? '').replace(/[&<>"]/g, ch =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[ch]));
const ct = key => String(key);
const money = cents => `$${((Number(cents) || 0) / 100).toFixed(2)}`;
const CUI = { icon: () => '' };
const walletDate = value => String(value);

/* ================================================================= 1 · POINTS */

const pointsSrc =
  topLevel('customerRewardProgressMarkupV310', 'function customerStampTargetV310') +
  topLevel('customerProgrammePointsPanelV230', 'function customerPointsExpiryLineV386');
const points = new Function(
  'esc', 'ct', 'CUI', 'customerPointTotalV103', 'customerProgrammePausedMarkupV310',
  'customerRewardProgressMarkupV167', 'customerPointsExpiryLineV386',
  `${pointsSrc}
   return {customerProgrammePointsPanelV230,customerRewardProgressMarkupV310};`
)(esc, ct, CUI, value => String(Number(value) || 0), () => '<p>PAUSED</p>', () => '', () => '');

test('POINTS · the customer panel states the balance the server sent, in its unit', () => {
  const html = points.customerProgrammePointsPanelV230({
    loyalty: { enabled: true, balance: 240 },
    presentation: { unit: 'points' },
    progressMarkupV310: '<i data-progress>Free coffee</i>',
  });
  assert.match(html, /240/, 'the balance the server sent must appear');
  assert.match(html, /points/, 'and the unit it is counted in');
  assert.match(html, /data-progress/, 'the progress meter the caller supplied must be rendered');
});

test('POINTS · NEGATIVE — a paused programme says so and shows no balance at all', () => {
  const html = points.customerProgrammePointsPanelV230({
    /* enabled===false is the server saying "nothing is being counted". The balance is still on
       the payload — a paused programme keeps what was already earned — so this is precisely the
       case where rendering the number would lie about the programme still accruing. */
    loyalty: { enabled: false, balance: 240 },
    presentation: { unit: 'points' },
    progressMarkupV310: '<i data-progress>Free coffee</i>',
  });
  assert.match(html, /Programme paused/, 'a programme that is off must say so');
  assert.doesNotMatch(html, /240/,
    'a paused programme must not present a balance as if it were still accruing');
  assert.doesNotMatch(html, /data-progress/,
    'and must not paint progress toward a reward it is not counting toward');
});

test('POINTS · NEGATIVE — readiness is the server\'s answer, never client arithmetic', () => {
  /* v145 forbids deriving "reward ready" in the browser. balance >= cost is TRUE here and
     available_now is false; the meter must follow the server. */
  const html = points.customerRewardProgressMarkupV310({
    loyalty: { balance: 500 },
    reward: { name: 'Free coffee', cost_units: 120, available_now: false },
  });
  assert.ok(html.length > 0, 'a reward with a cost still renders a progress meter');
  assert.doesNotMatch(html, /data-reward-ready="true"|reward-ready\b/,
    'balance >= cost must not by itself mark a reward ready — available_now is the only truth');
});

/* ================================================================== 2 · TIERS */

const tiersSrc =
  topLevel('customerTierUnitWordV310', 'function customerTierDistanceCountV310') +
  topLevel('customerTierPanelMarkupV194', 'function customerTierLadderMarkupV186');
const tiers = new Function(
  'esc', 'ct', 'CUI', 'customerTierRungsV333', 'customerTierRailCompactV333',
  'customerTierRailProgressV333', 'customerTierMilestonesMarkupV194',
  'customerTierRequirementTextV189', 'customerTierRemainingTextV186',
  'customerTierDistanceCountV310', 'customerTierHasProgressV103', 'customerTierLadderMarkupV186',
  `${tiersSrc}
   return {customerTierPanelMarkupV194,customerTierUnitWordV310};`
)(esc, ct, CUI, () => '', () => '', () => '', () => '',
  (threshold) => `needs ${threshold}`, (remaining) => `${remaining} to go`,
  (remaining) => String(remaining), tier => Number(tier?.progress_percent) > 0, () => '');

const tierPayload = (overrides = {}) => ({
  current: { label: 'Gold', threshold: 100 },
  next: { label: 'Platinum', threshold: 500 },
  basis: 'points_earned', metric: 200, progress_percent: 60,
  ...overrides,
});

test('TIERS · the customer panel names the resolved tier and the distance to the next', () => {
  const html = tiers.customerTierPanelMarkupV194(tierPayload());
  assert.match(html, /Gold/, 'the resolved tier name must appear');
  assert.match(html, /Platinum/, 'and the one being worked toward');
  assert.match(html, /300/, '500 minus a metric of 200 is the distance the server implies');
});

test('TIERS · NEGATIVE — a tier programme that is not running names no tier', () => {
  const html = tiers.customerTierPanelMarkupV194(tierPayload({ unavailable: 'not_running' }));
  assert.match(html, /not running a tier programme/);
  assert.doesNotMatch(html, /Gold/,
    'a tier programme the firm is not running must not name a tier the customer is "in"');
});

test('TIERS · NEGATIVE — a redeem-only firm shows no ladder at all', () => {
  /* v230, owner: "only 1 can be live at any go". A firm that redeems points for rewards is not
     also telling a tier story; showing both was the double narrative that was ruled out. */
  assert.equal(tiers.customerTierPanelMarkupV194(tierPayload({ points_mode: 'redeem' })), '');
});

/* ================================================================= 3 · STAMPS */

const stampsSrc =
  topLevel('stampQuestNormaliseV323', 'function customerStampQuestRingsV323') +
  topLevel('customerStampQuestRingsV323', 'function customerStampQuestBodyV323') +
  topLevel('customerStampQuestBodyV323', '/* 2 · POINTS & GIFTS');
const stamps = new Function(
  'esc', 'ct', 'customerPointTotalV103', 'PROGRAMME_STACK_RING_LIMIT_V310',
  `${stampsSrc}
   return {stampQuestNormaliseV323,customerStampQuestBodyV323};`
)(esc, ct, value => String(value), 24);

const stampCard = (overrides = {}) => ({
  enabled: true, contract: 'v323', unit: 'stamps', running: true,
  slots: 8, filled: 4, cycle_index: 1, lifetime: 22,
  milestones: [
    { slot: 3, reward_name: 'Free pastry', claimed: true },
    { slot: 5, reward_name: 'Free coffee', claimed: false },
    { slot: 8, reward_name: 'Free lunch', claimed: false },
  ],
  ...overrides,
});

test('STAMPS · the quest shows this cycle\'s progress, not the lifetime figure', () => {
  const html = stamps.customerStampQuestBodyV323(stamps.stampQuestNormaliseV323(stampCard()));
  assert.match(html, /\b4\b/, 'the current cycle count must appear');
  assert.doesNotMatch(html, /\b22\b/,
    'the lifetime total is not what a stamp card counts — that was a real v322-era defect');
});

test('STAMPS · NEGATIVE — a stamp card never speaks in points', () => {
  const html = stamps.customerStampQuestBodyV323(stamps.stampQuestNormaliseV323(stampCard()));
  assert.doesNotMatch(html, /\bpoints?\b/i,
    'a stamp programme printing a points figure is the v322 defect this rule exists for');
});

/* =============================================================== 4 · BIRTHDAY */

const birthday = new Function('esc', 'ct', 'CUI', 'walletDate', 'money',
  `${topLevel('birthdayBenefitMarkup', "const CUSTOMER_SURFACE_ACCENT_V375")}
   return {birthdayBenefitMarkup};`
)(esc, ct, CUI, walletDate, money);

test('BIRTHDAY · an available benefit renders with its label', () => {
  const html = birthday.birthdayBenefitMarkup({
    status: 'available', label: 'Birthday cake slice',
    valid_from: '2026-08-01T00:00:00+08:00', valid_until: '2026-09-01T00:00:00+08:00',
  });
  assert.match(html, /Birthday cake slice/);
});

test('BIRTHDAY · NEGATIVE — no benefit means no card', () => {
  assert.equal(birthday.birthdayBenefitMarkup(null), '',
    'a firm with no birthday programme must not paint a birthday card');
});

/* ============================================================== 5 · REFERRALS */

const referralSrc =
  topLevel('customerReferralMoneyV300', 'function customerReferralPointsV322') +
  topLevel('customerReferralPointsV322', 'function customerReferralCardMarkupV300') +
  topLevel('customerReferralCardMarkupV300', 'function customerPromotionCardV104');
const referrals = new Function('esc', 'ct', 'CUI', 'money', 'walletDate', 'copyTextV300',
  `${referralSrc}
   return {customerReferralCardMarkupV300};`
)(esc, ct, CUI, money, walletDate, () => {});

test('REFERRALS · an enabled referral card carries the customer\'s own code', () => {
  const html = referrals.customerReferralCardMarkupV300(
    { enabled: true, code: 'PEEK-8H3K', reward_points: 200, reward_kind: 'points',
      friend_reward_points: 100, referred_count: 2 },
    { name: 'Glow Atelier', slug: 'glow-atelier', currency: 'SGD' }
  );
  assert.match(html, /PEEK-8H3K/, 'the referral code is the whole point of the card');
});

test('REFERRALS · NEGATIVE — no code yet means no share controls to press', () => {
  const html = referrals.customerReferralCardMarkupV300(
    { enabled: true, code: '', reward_points: 200, reward_kind: 'points' },
    { name: 'Glow Atelier', slug: 'glow-atelier', currency: 'SGD' }
  );
  assert.doesNotMatch(html, /customerReferralCopy|customerReferralShare/,
    'offering copy/share before the server has minted a code shares an empty string');
  assert.match(html, /referralCodePending/);
});

test('REFERRALS · NEGATIVE — the friend\'s share is only promised when the server enables it', () => {
  /* v421 pays BOTH sides, which changes what the tenant is charged. The card must never promise
     the friend a reward the engine will not pay. */
  const off = referrals.customerReferralCardMarkupV300(
    { enabled: true, code: 'PEEK-8H3K', reward_points: 200, reward_kind: 'points',
      friend_enabled: false, friend_reward_points: 100 },
    { name: 'Glow Atelier', slug: 'glow-atelier', currency: 'SGD' }
  );
  assert.doesNotMatch(off, /referralFriendAlso/,
    'friend_enabled=false must remove the friend sentence, not just zero it');
});

/* ======================================================= 6 · WELCOME OFFER, 7 · BRING-BACK */

/* Both live on the till receipt rather than in the customer wallet, inside the entitlements
   banner block. The slice is taken verbatim so the eligibility wording, the minimum-spend
   branch and the redeem buttons are the shipped ones. */
const offerBannerSrc = closure(
  '    const welcomeOffer=catalog.customerWelcomeOffer||null;',
  '    const pendingVouchers='
);
const offers = new Function('esc', 'money', 'catalog',
  `${offerBannerSrc}
   return {welcomeBanner,bringbackBanner,referralBanner};`
);

test('WELCOME · a zero-minimum offer is redeemable straight from the till', () => {
  const { welcomeBanner } = offers(esc, money, {
    customerWelcomeOffer: { reward_label: 'Free brownie', min_spend_cents: 0 },
  });
  assert.match(welcomeBanner, /Free brownie/);
  assert.match(welcomeBanner, /tWelcomeRedeemV215/,
    'with no minimum spend the give-it-now button must be present');
});

test('WELCOME · NEGATIVE — a minimum-spend offer is NOT redeemable before the sale exists', () => {
  const { welcomeBanner } = offers(esc, money, {
    customerWelcomeOffer: { reward_label: 'Free brownie', min_spend_cents: 2000 },
  });
  assert.match(welcomeBanner, /Free brownie/);
  assert.doesNotMatch(welcomeBanner, /tWelcomeRedeemV215/,
    'a minimum spend is proved against a recorded sale — offering the button first gives the '
    + 'item away for free');
});

test('WELCOME · NEGATIVE — no configured offer means no banner', () => {
  const { welcomeBanner } = offers(esc, money, { customerWelcomeOffer: null });
  assert.equal(welcomeBanner, '');
});

test('BRING-BACK · a granted voucher is redeemable on sight and says why it was sent', () => {
  const { bringbackBanner } = offers(esc, money, {
    customerBringbackOffer: {
      grant_id: '11111111-1111-1111-1111-111111111111',
      reward_label: 'Free wash', away_days: 90,
    },
  });
  assert.match(bringbackBanner, /Free wash/);
  assert.match(bringbackBanner, /90/, 'the absence that earned it must be stated');
  assert.match(bringbackBanner, /tBringbackRedeemV362/);
});

test('BRING-BACK · NEGATIVE — no grant means no banner', () => {
  const { bringbackBanner } = offers(esc, money, { customerBringbackOffer: null });
  assert.equal(bringbackBanner, '',
    'a customer who was never sent a bring-back voucher must not be offered one');
});

/* =================================== BUSINESS-SIDE PROJECTION, ALL SEVEN AT ONCE */

const spineSrc =
  topLevel('programmeSpineRowsV314', 'function programmeSpineOnV314') +
  topLevel('programmeSpineOnV314', '/* "Is this firm') +
  topLevel('programmeSpineRunningV314', '/* The three-valued points model') +
  topLevel('programmePointsModeV314', '/* The LAST-RESORT selection');
const spine = state => new Function('S',
  `${spineSrc}
   return {programmeSpineOnV314,programmeSpineRunningV314,programmePointsModeV314};`
)(state);

const spineState = rows => ({
  programmes: rows,
  programmesBusinessId: 'biz-1',
  biz: { id: 'biz-1' },
});

test('BUSINESS · the owner\'s Live/Paused projection reads the programme spine', () => {
  const s = spine(spineState([
    { kind: 'points', active: true },
    { kind: 'tiers', active: true },
    { kind: 'stamps', active: false },
  ]));
  assert.equal(s.programmeSpineOnV314('points'), true);
  assert.equal(s.programmeSpineOnV314('stamps'), false);
  assert.equal(s.programmeSpineRunningV314(), true);
  assert.equal(s.programmePointsModeV314(), 'both');
});

test('BUSINESS · NEGATIVE — every programme off reads as not running, not as unknown', () => {
  const s = spine(spineState([
    { kind: 'points', active: false },
    { kind: 'tiers', active: false },
    { kind: 'stamps', active: false },
  ]));
  assert.equal(s.programmeSpineRunningV314(), false,
    'a firm running nothing must not show a Live pill');
});

test('BUSINESS · NEGATIVE — an unread spine is null, and null is not false', () => {
  /* The distinction is load-bearing: "we have not read the spine yet" must not render the same
     pill as "this firm runs nothing". A brand-new tenant went live with every spine row false
     because a reader collapsed the two. */
  const s = spine({ programmes: null, programmesBusinessId: null, biz: null });
  assert.equal(s.programmeSpineRunningV314(), null);
  assert.equal(s.programmeSpineOnV314('points'), null);
  assert.equal(s.programmePointsModeV314(), null);
});

test('BUSINESS · NEGATIVE — a spine read for ANOTHER business is not this business\'s answer', () => {
  const s = spine({
    programmes: [{ kind: 'points', active: true }],
    programmesBusinessId: 'biz-OTHER',
    biz: { id: 'biz-1' },
  });
  assert.equal(s.programmeSpineOnV314('points'), null,
    'a stale spine from a previously-open business must never answer for this one');
});

/* ============================================ CUSTOMER-SIDE VISIBILITY GATE (shared) */

const visibility = new Function('esc', 'ct', 'walletDate',
  `${topLevel('programmeStackEntryV310', 'function programmeStackCardVisibleV310')}
   ${topLevel('programmeStackCardVisibleV310', '/* One paused block')}
   return {programmeStackEntryV310,programmeStackCardVisibleV310};`
)(esc, ct, walletDate);

test('STACK · visibility obeys the server\'s customer_visible, not active', () => {
  assert.equal(visibility.programmeStackCardVisibleV310({ kind: 'points', customer_visible: true }), true);
  assert.equal(visibility.programmeStackCardVisibleV310({ kind: 'points', active: true }), false,
    'active without customer_visible is a real state (configured, nothing to spend) and must '
    + 'not grow a card');
  assert.equal(visibility.programmeStackCardVisibleV310(null), false);
});

test('STACK · NEGATIVE — a programme absent from the spine is not silently visible', () => {
  const programmes = [{ kind: 'points', customer_visible: true }];
  assert.equal(visibility.programmeStackEntryV310(programmes, 'stamps'), null);
  assert.equal(
    visibility.programmeStackCardVisibleV310(visibility.programmeStackEntryV310(programmes, 'stamps')),
    false
  );
});
