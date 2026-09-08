/* nestly_v829 — the eight counter-facing defects in the merchant redemption scanner (W4C).
 *
 * Every test below EXECUTES the shipped source: the blocks are lifted verbatim out of app/app.js
 * and run against stubs, because this repo's rule is that a source regex stays green while the
 * behaviour underneath it is dead. Where a test can only be written as a source assertion it says
 * so and explains why, and it is paired with an executed assertion that carries the behaviour.
 *
 * The eight findings, and what proves each:
 *   F-W4C-1  the minimum-spend refusal never reached the counter. The scanner tested
 *            `.includes('qualifying sale')` (a SPACE) while production raises
 *            welcome_offer_requires_qualifying_sale / welcome_offer_min_spend_not_met
 *            (UNDERSCORES), so a customer who was simply short of the threshold was told the gift
 *            "may have expired, already been used, or belong to another business". The till
 *            keypad's own copy of the rule used /qualifying[ _]sale|min[ _]spend/i and was right.
 *            Proved by running merchantGiftRefusalTextV829 — the ONE map both arms now call — and
 *            by running the scanner's real error ternary.
 *   F-W4C-2  closing the panel mid-request spent the voucher silently. Proved by driving the real
 *            openMerchantRedemptionScanner: press ✕ while the RPC is in flight, then let it
 *            answer, and assert the receipt, the toast and onComplete all still happen.
 *   F-W4C-3  the camera re-submitted the same refused QR every frame. Proved by pumping the real
 *            requestAnimationFrame loop and counting sb.rpc calls.
 *   F-W4C-4  41 of production's ~50 redemption refusals reached the counter as raw database
 *            English. Proved by feeding every RAISE string read off production through the
 *            mappers and asserting a counter sentence comes back.
 *   F-W4C-5  every free gift receipt said "Points spent 0". Proved by running the real
 *            merchantRedemptionReceiptView / merchantRedemptionReceiptHtml on a
 *            staff_scan_gift_qr_v515-shaped payload.
 *   F-W4C-6  a server status that is not an error printed as a machine word. Proved by resolving
 *            the real scanner with {status:'expired'}.
 *   F-W4C-7  the "Reward voucher ready" banner was squeezed at counter width. Proved by executing
 *            the shipped template and checking the class it emits against the rule app.css
 *            actually defines for that class.
 *   F-W4C-8  a decoder-load failure was blamed on the camera or on the customer's photo. Proved
 *            by rejecting loadScannerLibrary on both the camera and the image path.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appJs = await readFile(path.join(root, 'app/app.js'), 'utf8');
const appCss = await readFile(path.join(root, 'app/app.css'), 'utf8');

/* Slice [from, end-of-`to`] — the end marker is INCLUDED, unlike w4b1's helper. */
const block = (from, to) => {
  const a = appJs.indexOf(from);
  assert.ok(a > -1, `missing block start: ${from}`);
  const b = appJs.indexOf(to, a);
  assert.ok(b > a, `missing block end: ${to}`);
  return appJs.slice(a, b + to.length);
};

const flush = () => new Promise(resolve => setImmediate(resolve));

/* ------------------------------------------------------------------ the refusal maps */

/* One slice carries MERCHANT_REDEMPTION_INVARIANT_V829, merchantSupportReferenceV829,
   merchantRedemptionRefusalTextV060, merchantGiftRefusalTextV829, MERCHANT_SCAN_STATUS_COPY_V829
   and merchantScanStatusTextV829 — i.e. every sentence the counter can be shown. */
const upTo = (from, to) => {
  const a = appJs.indexOf(from);
  assert.ok(a > -1, `missing block start: ${from}`);
  const b = appJs.indexOf(to, a);
  assert.ok(b > a, `missing block end: ${to}`);
  return appJs.slice(a, b);
};
/* Every extraction below is LAZY on purpose: a file that throws while it is being imported tells
   you only that something moved, and gives no signal about which of the eight findings regressed.
   Built once per run and memoised. */
const buildMaps = () => {
  const mapSrc = upTo('/* F060: merchant_scan_redemption_qr_v117',
    '\nfunction openMerchantRedemptionScanner(');
  const names = ['humanErrorV295', 'money'];
  const values = [
    /* The shipped humanErrorV295 hands a MACHINE code (no whitespace) to the fallback and passes
       a human sentence straight through. Reproduced exactly, so "raw DB English reached the
       counter" is reproducible here rather than hidden by an over-helpful stub. */
    (error, fallback) => {
      const raw = String(error?.message ?? error ?? '').trim();
      if (!raw) return fallback;
      return (!/\s/.test(raw) || /^[a-z0-9_]+$/.test(raw)) ? fallback : raw;
    },
    cents => `SGD ${(Number(cents || 0) / 100).toFixed(2)}`
  ];
  return new Function(...names, `${mapSrc}
    return {merchantRedemptionRefusalTextV060,merchantGiftRefusalTextV829,merchantScanStatusTextV829};`)(...values);
};

let mapsCache = null;
const M = () => (mapsCache ||= buildMaps());
const GENERIC_CLASSIC = 'This redemption could not be confirmed. It may be expired, already used, or for another business.';
const GENERIC_GIFT = 'This gift could not be given. It may have expired, already been used, or belong to another business.';

/* ---------------------------------------------------------------- F-W4C-1 */

test('F-W4C-1 the underscored minimum-spend refusals production actually raises reach the counter', () => {
  const needsSale = M().merchantGiftRefusalTextV829({ code: '22023', message: 'welcome_offer_requires_qualifying_sale' });
  const notEnough = M().merchantGiftRefusalTextV829({ code: '22023', message: 'welcome_offer_min_spend_not_met' });

  assert.notEqual(needsSale, GENERIC_GIFT, 'a min-spend gift is not "expired, used or another business"');
  assert.notEqual(notEnough, GENERIC_GIFT);
  assert.match(needsSale, /ring the sale up first/i);
  assert.match(needsSale, /minimum spend/i);
  assert.match(notEnough, /not spent enough/i);
  assert.notEqual(needsSale, notEnough,
    'nothing rung up yet and a sale under the threshold are different problems with different remedies');
});

test('F-W4C-1 the space-spelled refusal the OLD scanner tested for still maps, so nothing regressed', () => {
  assert.match(M().merchantGiftRefusalTextV829({ message: 'this gift needs a qualifying sale' }),
    /ring the sale up first/i);
});

test('F-W4C-1 the shortfall is named when — and only when — the server quoted one', () => {
  const withQuote = M().merchantGiftRefusalTextV829(
    { code: '22023', message: 'welcome_offer_min_spend_not_met' }, { minSpendCents: 1500 });
  assert.match(withQuote, /SGD 15\.00/, 'staff_scan_gift_qr_to_till_v666 returns min_spend_cents — say it');
  const withoutQuote = M().merchantGiftRefusalTextV829({ code: '22023', message: 'welcome_offer_min_spend_not_met' });
  assert.doesNotMatch(withoutQuote, /SGD/, 'an amount is never invented when the caller has none');
  assert.doesNotMatch(
    M().merchantGiftRefusalTextV829({ message: 'welcome_offer_min_spend_not_met' }, { minSpendCents: 0 }),
    /SGD 0\.00/, 'a zero minimum is not a minimum');
});

test('F-W4C-1 the sentence comes from ONE function, so the scanner arm and the till arm cannot drift', () => {
  /* Executed: the scanner's real error ternary is lifted out and run. It is an expression inside
     a 900-line closure, so it is executed here with its four free names bound rather than by
     booting the whole till. */
  const armSrc = block('if(error){sayV829(', ':merchantRedemptionRefusalTextV060(error));return}');
  const said = [];
  const arm = new Function('error', 'payload', 'sayV829',
    'merchantGiftRefusalTextV829', 'merchantRedemptionRefusalTextV060', armSrc);
  const run = (error, kind) => {
    said.length = 0;
    arm(error, { kind }, s => said.push(s), M().merchantGiftRefusalTextV829, M().merchantRedemptionRefusalTextV060);
    return said[0];
  };
  assert.equal(run({ code: '22023', message: 'welcome_offer_min_spend_not_met' }, 'gift'),
    M().merchantGiftRefusalTextV829({ code: '22023', message: 'welcome_offer_min_spend_not_met' }),
    'the scanner arm must produce exactly what the shared map produces');
  assert.equal(run({ code: '22023', message: 'redemption QR is no longer pending' }, 'classic'),
    M().merchantRedemptionRefusalTextV060({ code: '22023', message: 'redemption QR is no longer pending' }));
  assert.match(run({ code: 'PGRST202', message: 'nope' }, 'gift'), /latest Peekaa service update/,
    'the missing-RPC branch is untouched');

  /* Source-level, and deliberately so: this asserts the ABSENCE of a second implementation, which
     no execution can demonstrate. It is paired with the executed equality above. */
  const tillArm = block('if(giveErrorV681)return toast(merchantGiftRefusalTextV829(',
    'givenV681?.reward_label||labelV666));');
  assert.match(tillArm, /merchantGiftRefusalTextV829\(giveErrorV681,\{minSpendCents:data\?\.min_spend_cents\}\)/,
    'the till keypad calls the shared map and passes the server-quoted minimum');
  assert.doesNotMatch(armSrc, /includes\('qualifying sale'\)/,
    'the space-spelled test that never matched production must be gone from the scanner arm');
  assert.doesNotMatch(tillArm, /qualifying\[ _\]sale\|min\[ _\]spend/,
    'and the till keypad no longer keeps its own second copy of the rule');
});

/* ---------------------------------------------------------------- F-W4C-4 */

/* Read off production 2026-09-08 with pg_get_functiondef over merchant_scan_redemption_qr_v117,
   staff_scan_gift_qr_v515, app.redeem_reward_core, app.redeem_points_v40_internal,
   customer_create_redemption_intent_v89, staff_manual_redeem_reward_v404 and the four redeemers
   v515 routes into (staff_redeem_welcome_offer_v215, staff_redeem_bringback_v361,
   staff_redeem_referral_v420, staff_issue_tier_benefit_v365, staff_confirm_birthday_free_item_v752).
   `%` placeholders are shown expanded, as a counter would see them.

   nestly_v830: the SQLSTATE column is now every raise's REAL `using errcode`, re-read off
   production, not a guess and not `null` for anything that ships one. It matters: PostgREST hands
   the browser {code, message} together, and v829's map tested the code before it tested the
   message, so a fixture that dropped the code could not see that two of its own sentences were
   unreachable. `null` below now means the raise genuinely has no errcode clause (PostgreSQL
   defaults it to P0001), which the app never keys on. */
const PRODUCTION_REFUSALS = [
  // ---- merchant_scan_redemption_qr_v117
  ['redemption QR is no longer pending', '22023', /already been used/i],
  ['redemption QR is invalid', '22023', /not a redemption QR/i],
  ['invalid redemption QR scan', '22023', /not a redemption QR/i],
  ['catalog redemption terms changed; create a new QR', '23514', /fresh QR/i],
  ['classic redemption terms changed; create a new QR', '23514', /fresh QR/i],
  ['redemption configuration changed; create a new QR', '23514', /fresh QR/i],
  ['customer redemption is disabled for this business', '42501', /turned off for this business/i],
  ['merchant loyalty redemption access is required', '42501', /permission/i],
  ['redemption branch scope is not permitted', '42501', /branch you are allowed to serve/i],
  ['reward is not eligible at this branch', '23514', /not available at this branch/i],
  ['an active business branch is required', '22023', /branch you are allowed to serve/i],
  ['canonical catalog redemption was not recorded', 'XX001', /PK-RDM-XX001/],
  ['canonical redemption operation was not recorded', 'XX001', /PK-RDM-XX001/],
  // ---- app.redeem_reward_core
  ['insufficient proven points', '23514', /enough points/i],
  ['not enough stamps yet', '23514', /enough stamps/i],
  ['reward usage limit reached', '23514', /usage limit/i],
  ['reward requires a higher membership tier', '23514', /higher membership tier/i],
  ['reward is currently paused', '22023', /paused right now/i],
  ['reward not eligible at branch', null, /not available at this branch/i],
  ['reward not eligible for service', null, /on that service/i],
  ['reward not eligible for product', null, /on that item/i],
  ['reward not found in this business', null, /no longer in this business/i],
  ['reward not found or inactive', null, /no longer in this business/i],
  ['reward unavailable', null, /not available yet/i],
  ['reward expired', null, /expired/i],
  ['this reward has expired and can no longer be claimed', '23514', /expired/i],
  ['this reward expired on 01 Jan 2026', '23514', /expired on 01 Jan 2026/],
  ['this stamp gift has already been claimed on this card', '23505', /already claimed on this stamp card/i],
  ['this stamp card has no length set', '23514', /stamp card is not set up/i],
  ['this business is not running a stamp card', 'XX001', /stamp card is not set up/i],
  ['this gift sits past the end of the stamp card', '23514', /more stamps than the card holds/i],
  ['catalog redemption is inactive', null, /switched off for this programme/i],
  ['redemption already in progress', '55P03', /already being confirmed/i],
  ['idempotency conflict', '23505', /clashed with another redemption/i],
  ['not authorized', '42501', /permission/i],
  ['active staff authorization required', '42501', /permission/i],
  ['reward programme does not belong to this business', '42501', /does not belong to this business/i],
  ['branch does not belong to business', null, /does not belong to this business/i],
  ['product does not belong to business', null, /does not belong to this business/i],
  ['service does not belong to business', null, /does not belong to this business/i],
  ['client does not belong to this business', null, /does not belong to this business/i],
  ['reward programme is not resolvable for this business', 'XX001', /PK-RDM-XX001/],
  ['reward batch delta does not reconcile', 'XX001', /PK-RDM-XX001/],
  ['reward batch drain was incomplete', 'XX001', /PK-RDM-XX001/],
  ['reward drain provenance does not conserve value', 'XX001', /PK-RDM-XX001/],
  ['idempotency key must contain at least 8 characters', '22023', /PK-RDM-22023/],
  // ---- app.redeem_points_v40_internal
  ['insufficient points: 120 < 400', null, /enough points/i],
  ['points redemption batch delta does not reconcile', 'XX001', /PK-RDM-XX001/],
  ['points redemption batch drain was incomplete', 'XX001', /PK-RDM-XX001/],
  ['points batches 120 cannot prove redemption 400', 'XX001', /PK-RDM-XX001/],
  ['active staff authorization changed while redeeming points', '42501', /permission/i],
  ['idempotency key was already used for another redemption request', '22023', /clashed with another redemption/i],
  ['matching redemption is still reserved; retry shortly', '40001', /already being confirmed/i],
  ['no active redeemable points program with positive points and credit values', null, /no points programme is set up/i],
  ['points are redeemed for gifts, not for store credit', '22023', /redeems points for gifts/i],
  ['this business redeems points through its reward catalog; use redeem_reward', null, /redeems points for gifts/i],
  ['redemption programme is not resolvable for this business', 'XX001', /PK-RDM-XX001/],
  ['you do not have permission to redeem points in this business (create_sales)', '42501', /permission/i],
  // ---- customer_create_redemption_intent_v89
  ['loyalty redemption is unavailable', '22023', /switched off for this programme/i],
  ['catalog redemption is unavailable', '22023', /switched off for this programme/i],
  ['classic points redemption is unavailable', '22023', /switched off for this programme/i],
  ['customer QR redemption is unavailable', '0A000', /switched off for this business/i],
  ['verified customer link required', '42501', /signed in/i],
  ['context-restricted rewards require staff-assisted redemption', '22023', /given by staff at the counter/i],
  ['idempotency key conflicts with another redemption intent', '23505', /clashed with another redemption/i],
  ['idempotency key is required', '22023', /PK-RDM-22023/],
  ['redemption kind and reward do not match', '22023', /does not match the reward/i],
  ['reward is unavailable', '22023', /not available yet/i],
  ['this business is not running a programme you can redeem from', '0A000', /not running a programme/i],
  ["this reward's programme is not running right now", '0A000', /not running/i],
  ['unsupported redemption kind', '22023', /PK-RDM-22023/],
  // ---- staff_manual_redeem_reward_v404
  ['authenticated staff required', '42501', /permission/i],
  ['manual redemption operation was not recorded', '40001', /PK-RDM-40001/],
  ['manual_redeem_quantity_out_of_range', '22023', /quantity/i],
  ['manual_redeem_reason_note_required', '22023', /reason/i],
  ['manual_redeem_reason_required', '22023', /reason/i],
  ['manual_reward_redemption is not permitted for this staff member or branch', '42501', /permission/i]
];

test('F-W4C-4 every refusal production can raise arrives as a counter sentence, not database English', () => {
  const leaks = [];
  for (const [message, code, expected] of PRODUCTION_REFUSALS) {
    const error = code ? { message, code } : { message };
    const sentence = M().merchantRedemptionRefusalTextV060(error);
    if (sentence === message) { leaks.push(`RAW: ${message}`); continue }
    if (sentence === GENERIC_CLASSIC) { leaks.push(`GENERIC: ${message}`); continue }
    if (!expected.test(sentence)) leaks.push(`WRONG: ${message} -> ${sentence}`);
  }
  assert.deepEqual(leaks, [], 'each production refusal must have its own counter-appropriate sentence');
});

test('F-W4C-4 a 42501 that is not about staff permission is not called a permission problem', () => {
  /* nestly_v830. Production raises 42501 for six refusals in the redemption family that have
     nothing to do with what this staff member may do — read off prod with pg_get_functiondef:
     customer_create_redemption_intent_v89 and merchant_scan_redemption_qr_v117 both raise
     'customer redemption is disabled for this business' with errcode='42501', and
     merchant_scan_redemption_qr_v117, app.redeem_reward_core and reverse_loyalty_redemption all
     raise 'redemption branch scope is not permitted' the same way. v829 tested the CODE second
     and the messages after it, so both of its own sentences for those were unreachable and the
     counter was told "You don't have permission to confirm this redemption." — which sends staff
     to ask for a permission change that would not have fixed either one. */
  const cases = [
    ['customer redemption is disabled for this business', /turned off for this business/i],
    ['redemption branch scope is not permitted', /branch you are allowed to serve/i],
    ['verified customer link required', /signed in to their own Peekaa account/i],
    ['reward programme does not belong to this business', /does not belong to this business/i],
    ['redemption client does not belong to this business', /does not belong to this business/i]
  ];
  for (const [message, expected] of cases) {
    const sentence = M().merchantRedemptionRefusalTextV060({ code: '42501', message });
    assert.match(sentence, expected, `42501 + "${message}" must keep its own sentence`);
    assert.doesNotMatch(sentence, /don't have permission/i,
      'the blanket 42501 rule must not answer for a refusal the map has a real sentence for');
  }
});

test('F-W4C-4 an unrecognised 42501 IS still called a permission problem', () => {
  /* The control for the test above: demoting the blanket rule must not lose it. These are real
     42501 raises with no more specific sentence, plus the PostgREST/RLS shape. */
  for (const message of [
    'active staff authorization required', 'authenticated staff required', 'access denied',
    'you do not have permission to redeem points in this business (create_sales)',
    'permission denied for table clients'
  ]) {
    assert.match(M().merchantRedemptionRefusalTextV060({ code: '42501', message }),
      /don't have permission to confirm this redemption/i, message);
  }
  assert.match(M().merchantRedemptionRefusalTextV060({ message: 'permission denied for table clients' }),
    /don't have permission to confirm this redemption/i, 'the message alone is enough, code or not');
});

test('F-W4C-4 an internal invariant is apologised for with a quotable reference, never quoted at staff', () => {
  const drain = M().merchantRedemptionRefusalTextV060(
    { message: 'reward drain provenance does not conserve value', code: 'XX001' });
  assert.doesNotMatch(drain, /provenance|conserve|drain|reconcile|batch/i,
    'our own table vocabulary must never reach a counter');
  assert.match(drain, /something went wrong on our side/i);
  assert.match(drain, /PK-RDM-XX001/, 'the owner needs something to quote to support');
});

test('F-W4C-4 the branch-eligibility near-miss is closed: BOTH production spellings map', () => {
  assert.match(M().merchantRedemptionRefusalTextV060({ message: 'reward is not eligible at this branch' }),
    /not available at this branch/i);
  assert.match(M().merchantRedemptionRefusalTextV060({ message: 'reward not eligible at branch' }),
    /not available at this branch/i, 'redeem_reward_core raises the sibling wording');
});

test('F-W4C-4 the gift family gets its own vocabulary too', () => {
  const cases = [
    ['welcome_offer_already_redeemed', /already been given/i],
    ['welcome_offer_expired', /expired/i],
    ['welcome_offer_not_found', /no longer on this customer/i],
    ['welcome_offer_not_redeemable', /not waiting to be claimed/i],
    ['welcome_offer_branch_not_permitted', /at this branch/i],
    ['welcome_offer_qualifying_sale_not_found', /not on this customer/i],
    ['bringback_already_redeemed', /already been given/i],
    ['bringback_expired', /expired/i],
    ['bringback_grant_not_found', /no longer on this customer/i],
    ['bringback_not_redeemable', /not waiting to be claimed/i],
    ['referral_already_redeemed', /already been given/i],
    ['referral_expired', /expired/i],
    ['referral_grant_not_found', /no longer on this customer/i],
    ['tier_benefit_limit_reached', /as many times as their tier allows/i],
    ['tier_benefit_not_earned', /tier does not include this perk/i],
    ['tier_benefit_not_birthday_month', /birthday month/i],
    ['tier_benefit_birthday_unknown', /birthday month/i],
    ['tier_benefit_not_found', /no longer on this customer/i],
    ['this perk no longer exists', /no longer on this customer/i],
    ["this perk's period rolled over; ask the customer for a new QR", /rolled over/i],
    ['birthday benefit unavailable', /birthday gift is not available/i],
    ['gift QR is invalid', /not a reward QR from this business/i]
  ];
  const leaks = [];
  for (const [message, expected] of cases) {
    const sentence = M().merchantGiftRefusalTextV829({ message });
    if (sentence === message || sentence === GENERIC_GIFT) { leaks.push(`unmapped: ${message}`); continue }
    if (!expected.test(sentence)) leaks.push(`wrong: ${message} -> ${sentence}`);
  }
  assert.deepEqual(leaks, []);
});

/* ---------------------------------------------------------------- F-W4C-6 */

test('F-W4C-6 a returned status is a sentence, not a machine word in brackets', () => {
  assert.match(M().merchantScanStatusTextV829('expired'), /expired\. Ask the customer/i);
  assert.match(M().merchantScanStatusTextV829('cancelled'), /cancelled/i);
  assert.match(M().merchantScanStatusTextV829('not_pending'), /already been used/i);
  for (const status of ['expired', 'cancelled', 'not_pending', 'invalid', 'wrong_customer']) {
    assert.doesNotMatch(M().merchantScanStatusTextV829(status), /not completed \(/,
      'the old "Redemption was not completed (expired)." shape must be gone');
  }
  assert.match(M().merchantScanStatusTextV829('expired', 'Free latte'), /Free latte/,
    'the reward is named when the server sends it');
  assert.match(M().merchantScanStatusTextV829('some_new_enum'), /Ask the customer to open Redeem again/,
    'an unknown status still ends in a readable instruction');
});

/* ---------------------------------------------------------------- F-W4C-5 */

const buildReceipt = () => new Function('money', 'esc', 'CUI', `${upTo('function merchantRedemptionReceiptView(data={}){', '\nfunction customerRewardCanRedeem(')}
  return {merchantRedemptionReceiptView,merchantRedemptionReceiptHtml};`)(
  cents => `SGD ${(Number(cents || 0) / 100).toFixed(2)}`,
  value => String(value ?? ''),
  { icon: () => '' });

test('F-W4C-5 a free gift renders as a gift, not as a zero-point catalogue redemption', () => {
  const receipts = buildReceipt();
  /* Exactly what staff_scan_gift_qr_v515 returns: gift_kind, reward_label, customer_name,
     intent_id — and no redemption_kind and no points_spent at all. */
  const payload = {
    status: 'completed', gift_kind: 'welcome', reward_label: 'Free croissant',
    customer_name: 'Aisha Lim', intent_id: 'intent-1', grant_id: 'g-1', sale_id: 's-1'
  };
  const view = receipts.merchantRedemptionReceiptView(payload);
  assert.equal(view.kind, 'gift');
  assert.equal(view.rewardLabel, 'Free croissant');
  assert.match(view.fulfilment, /welcome gift/i);
  assert.match(view.fulfilment, /no points were spent/i);
  assert.doesNotMatch(view.fulfilment, /points redemption/i,
    'the catalogue wording claimed a points redemption that never happened');

  const html = receipts.merchantRedemptionReceiptHtml(payload);
  assert.doesNotMatch(html, /<dt>Points spent<\/dt>/, 'no "Points spent 0" on a free gift');
  assert.match(html, /Free croissant/);
  assert.match(html, /intent-1/, 'the operation reference still reaches the counter');
});

test('F-W4C-5 the remaining allowance the server sends is shown, and nothing is shown when it does not', () => {
  const receipts = buildReceipt();
  const withRemaining = receipts.merchantRedemptionReceiptHtml({
    gift_kind: 'tier_perk', reward_label: 'Free add-on', customer_name: 'Ben', intent_id: 'i-2', remaining: 2
  });
  assert.match(withRemaining, /<dt>Uses left<\/dt><dd>2<\/dd>/);
  assert.match(receipts.merchantRedemptionReceiptView({ gift_kind: 'tier_perk', remaining: 2 }).fulfilment,
    /2 uses left in this period/);
  const unlimited = receipts.merchantRedemptionReceiptHtml({
    gift_kind: 'tier_perk', reward_label: 'Free add-on', customer_name: 'Ben', intent_id: 'i-3', remaining: null
  });
  assert.doesNotMatch(unlimited, /<dt>Uses left<\/dt>/,
    'staff_issue_tier_benefit_v365 sends NULL for an unlimited perk — never draw a number for it');
});

test('F-W4C-5 the classic, catalogue, growth, promotion and package receipts are untouched', () => {
  const receipts = buildReceipt();
  const classic = receipts.merchantRedemptionReceiptView({
    redemption_kind: 'classic_points', points_spent: 800, credit_cents: 2000, customer_name: 'A'
  });
  assert.equal(classic.kind, 'classic_points');
  assert.equal(classic.pointsSpent, 800);
  assert.match(receipts.merchantRedemptionReceiptHtml({
    redemption_kind: 'catalog_reward', reward_label: 'Free coffee', points_spent: 120, operation_id: 'op'
  }), /<dt>Points spent<\/dt><dd>120<\/dd>/);
  assert.equal(receipts.merchantRedemptionReceiptView({ redemption_kind: 'growth_offer' }).kind, 'growth_offer');
  assert.equal(receipts.merchantRedemptionReceiptView({ redemption_kind: 'promotion_offer' }).kind, 'promotion_offer');
  assert.equal(receipts.merchantRedemptionReceiptView({ redemption_kind: 'package_session' }).kind, 'package_session');
});

/* ------------------------------------------------- the scanner itself, driven */

/* The smallest DOM the scanner actually touches. Elements are kept in one registry keyed by the
   selector that asks for them, so overlay.querySelector('#x') and panel.querySelector('#x') hand
   back the same object the shipped code wired. */
const makeScannerRig = ({
  camera = false, rpc = async () => ({ data: null, error: null }),
  isCurrent = () => true, loadScannerLibrary = async () => {}, jsQR = null
} = {}) => {
  const els = new Map();
  const removed = [];
  const toasts = [];
  const completed = [];
  const raf = [];
  const el = key => {
    if (!els.has(key)) {
      const node = {
        key, hidden: true, disabled: false, textContent: '', value: '', innerHTML: '',
        srcObject: null, files: [], style: {}, dataset: {},
        videoWidth: 640, videoHeight: 480, readyState: 4,
        onclick: null, onchange: null,
        setAttribute() {}, addEventListener() {}, focus() {},
        play: async () => {},
        remove() { removed.push(key) },
        querySelector: sel => el(sel)
      };
      els.set(key, node);
    }
    return els.get(key);
  };
  const overlay = el('<overlay>');
  overlay.querySelector = sel => el(sel);
  const canvas = { width: 0, height: 0, getContext: () => ({
    drawImage() {}, getImageData: () => ({ data: [], width: 8, height: 8 })
  }) };
  const scope = {
    document: { createElement: tag => (tag === 'canvas' ? canvas : overlay), body: { appendChild() {} } },
    CUI: { icon: () => '' },
    navigator: camera ? { mediaDevices: { getUserMedia: async () => ({ getTracks: () => [{ stop() {} }] }) } } : {},
    workspaceLocale: 'en',
    recordProductInteractionV100: undefined,
    redemptionPayloadFromQr: value => ({ kind: 'gift', token: String(value || '') }),
    packageUseResultV102: () => null,
    merchantRedemptionReceiptHtml: data => `<receipt kind="${data?.gift_kind || data?.redemption_kind || ''}">` +
      '<button id="merchantScannerReceiptClose"></button></receipt>',
    /* Deliberately MARKER stubs, not the real maps: this rig is about which sentence-producer the
       scanner reaches for and whether the sentence is surfaced at all. The wording itself is
       proved by the map tests above. Keeping the rig free of the real maps also means it still
       builds against a tree that has none of them, so these tests fail on BEHAVIOUR rather than
       on a missing name. */
    merchantGiftRefusalTextV829: error => `GIFT:${error?.message || ''}`,
    merchantRedemptionRefusalTextV060: error => `CLASSIC:${error?.message || ''}`,
    merchantScanStatusTextV829: (status, label) => `STATUS:${status}${label ? ` (${label})` : ''}`,
    loadScannerLibrary,
    toast: message => toasts.push(String(message)),
    crypto: { randomUUID: () => `key-${toasts.length}-${els.size}` },
    sb: { rpc: (name, args) => rpc(name, args) },
    requestAnimationFrame: cb => { raf.push(cb); return raf.length },
    cancelAnimationFrame: () => {},
    URL: { createObjectURL: () => 'blob:x', revokeObjectURL: () => {} },
    createImageBitmap: async () => ({ width: 8, height: 8, close() {} })
  };
  const names = Object.keys(scope);
  const scannerSrc = upTo('function openMerchantRedemptionScanner({',
    '\n// Customer-facing names for redemption intent statuses');
  const factory = new Function(...names, `
    let activeMerchantScannerCleanup=()=>{};
    ${scannerSrc}
    return {open:openMerchantRedemptionScanner,dispose:()=>activeMerchantScannerCleanup()};`);
  const api = factory(...names.map(n => scope[n]));
  const previousJsQr = globalThis.jsQR;
  if (jsQR) globalThis.jsQR = jsQR; else delete globalThis.jsQR;
  api.open({
    businessId: 'biz-1', branchId: 'branch-1', customerName: 'Aisha',
    isCurrent, onComplete: data => completed.push(data)
  });
  return {
    el, els, removed, toasts, completed, raf, dispose: api.dispose,
    restore: () => { if (previousJsQr) globalThis.jsQR = previousJsQr; else delete globalThis.jsQR },
    status: () => el('#merchantScannerStatus').textContent,
    pump: async n => {
      for (let i = 0; i < n; i += 1) {
        const cb = raf.shift();
        if (!cb) break;
        await cb();
        await flush();
      }
    },
    paste: value => { el('#merchantScannerToken').value = value; return el('#merchantScannerConfirm').onclick() },
    pressClose: () => el('#merchantScannerClose').onclick()
  };
};

/* ---------------------------------------------------------------- F-W4C-2 */

test('F-W4C-2 pressing ✕ while the redemption is in flight cannot spend the voucher silently', async () => {
  let settle;
  const rig = makeScannerRig({ rpc: () => new Promise(resolve => { settle = resolve }) });
  try {
    const pending = rig.paste('T'.repeat(40));
    await flush();
    rig.pressClose();                                   // the counter gives up on the scan
    assert.deepEqual(rig.removed, [], 'the panel is not torn down while the server is answering');
    settle({ data: { status: 'completed', gift_kind: 'welcome', reward_label: 'Free bun' }, error: null });
    await pending;
    assert.equal(rig.completed.length, 1, 'onComplete must still fire — the redemption HAPPENED');
    assert.deepEqual(rig.toasts, ['Redemption confirmed']);
    assert.match(rig.el('.modal-card').innerHTML, /<receipt kind="welcome">/,
      'the receipt is still shown, so the counter can read the operation reference');
  } finally { rig.restore() }
});

test('F-W4C-2 a refusal that lands after ✕ is still readable rather than discarded', async () => {
  let settle;
  const rig = makeScannerRig({ rpc: () => new Promise(resolve => { settle = resolve }) });
  try {
    const pending = rig.paste('T'.repeat(40));
    await flush();
    rig.pressClose();
    settle({ data: null, error: { code: '22023', message: 'welcome_offer_min_spend_not_met' } });
    await pending;
    assert.equal(rig.status(), 'GIFT:welcome_offer_min_spend_not_met',
      'the refusal is surfaced, and it comes from the shared gift map rather than a fixed guess');
    assert.equal(rig.completed.length, 0, 'nothing was redeemed, so nothing is reported as redeemed');
  } finally { rig.restore() }
});

test('F-W4C-2 a route change under a live request still reports what the server did', async () => {
  let settle;
  const rig = makeScannerRig({ rpc: () => new Promise(resolve => { settle = resolve }) });
  try {
    const pending = rig.paste('T'.repeat(40));
    await flush();
    /* disposeCurrentRoute() is not an operator decision and sweeps the overlay out of the DOM
       straight afterwards, so it tears down immediately — and the answer arrives as a toast. */
    rig.dispose();
    assert.ok(rig.removed.length >= 1, 'a forced teardown really does remove the overlay');
    settle({ data: { status: 'completed', gift_kind: 'referral', reward_label: 'Free tote' }, error: null });
    await pending;
    assert.deepEqual(rig.toasts, ['Redemption confirmed']);
    assert.equal(rig.completed.length, 1);
  } finally { rig.restore() }
});

test('F-W4C-2 the panel can still be closed normally when nothing is in flight', async () => {
  const rig = makeScannerRig();
  try {
    rig.pressClose();
    assert.ok(rig.removed.length >= 1, 'an ordinary close is untouched');
  } finally { rig.restore() }
});

/* ---------------------------------------------------------------- F-W4C-6 (driven) */

test('F-W4C-6 an expired gift QR reads as a sentence in the real scanner', async () => {
  const rig = makeScannerRig({
    rpc: async () => ({ data: { status: 'expired', gift_kind: 'welcome', reward_label: 'Free bun' }, error: null })
  });
  try {
    await rig.paste('T'.repeat(40));
    assert.doesNotMatch(rig.status(), /not completed \(expired\)/i,
      'the raw enum in brackets is what the counter used to be shown');
    assert.equal(rig.status(), 'STATUS:expired (Free bun)',
      'the status goes through the status map, which owns the sentence');
    assert.equal(rig.completed.length, 0);
  } finally { rig.restore() }
});

/* ---------------------------------------------------------------- F-W4C-3 */

test('F-W4C-3 a refused QR is not re-submitted by the camera on every frame', async () => {
  const calls = [];
  let token = 'A'.repeat(40);
  const rig = makeScannerRig({
    camera: true,
    jsQR: () => ({ data: token }),
    rpc: async (name, args) => {
      calls.push(args.p_qr_token);
      return { data: null, error: { code: '22023', message: 'welcome_offer_already_redeemed' } };
    }
  });
  try {
    await flush(); await flush(); await flush();       // let the camera start and queue frame 1
    await rig.pump(40);
    assert.equal(calls.length, 1,
      `the same refused QR must be sent once, not once per frame (was ${calls.length})`);
    assert.match(rig.status(), /^GIFT:welcome_offer_already_redeemed/, 'and the refusal stays readable');
    assert.match(rig.status(), /Scanning is paused for this code/,
      'staff are told why the camera stopped acting on it');

    token = 'B'.repeat(40);                            // a DIFFERENT customer presents a QR
    await rig.pump(5);
    assert.equal(calls.length, 2, 'a different code must still be scanned');
    assert.equal(calls[1], 'B'.repeat(40));
  } finally { rig.restore() }
});

test('F-W4C-3 the paste box is the deliberate retry and is never blocked', async () => {
  const calls = [];
  const rig = makeScannerRig({
    camera: true,
    jsQR: () => ({ data: 'A'.repeat(40) }),
    rpc: async (name, args) => {
      calls.push(args.p_qr_token);
      return { data: null, error: { code: '22023', message: 'welcome_offer_already_redeemed' } };
    }
  });
  try {
    await flush(); await flush(); await flush();
    await rig.pump(20);
    assert.equal(calls.length, 1);
    await rig.paste('A'.repeat(40));                   // same code, typed by a human
    assert.equal(calls.length, 2, 'a human retry of the same code must go through');
  } finally { rig.restore() }
});

test('F-W4C-3 the retry the status line promises actually happens when staff follow it', async () => {
  /* nestly_v830. v829 paused the camera on a refused code and told staff to "press Confirm
     redemption to try it again" — but nothing ever wrote the decoded value into
     #merchantScannerToken, so pressing Confirm exactly as instructed submitted an EMPTY box:
     redemptionPayloadFromQr('') yields {kind:'',token:''}, submit() bailed on `if(!token)` and
     the counter got "That is not a Peekaa redemption QR" — a different, wrong answer instead of
     the retry. The refused code is loaded into the box now, and the panel holding it is opened. */
  const calls = [];
  const rig = makeScannerRig({
    camera: true,
    jsQR: () => ({ data: 'A'.repeat(40) }),
    rpc: async (name, args) => {
      calls.push(args.p_qr_token);
      return { data: null, error: { code: '22023', message: 'welcome_offer_already_redeemed' } };
    }
  });
  try {
    await flush(); await flush(); await flush();
    await rig.pump(20);
    assert.equal(calls.length, 1, 'the camera sent it once');
    assert.match(rig.status(), /Confirm redemption/,
      'the status line still names the control staff are told to press');

    assert.equal(rig.el('#merchantScannerToken').value, 'A'.repeat(40),
      'the refused code must BE in the box the instruction points at');
    assert.equal(rig.el('#merchantScannerRetry').open, true,
      'and the panel holding it is open, so the instruction is followable');

    /* Press Confirm with nothing typed — precisely what the sentence asks for. */
    await rig.el('#merchantScannerConfirm').onclick();
    assert.equal(calls.length, 2, 'following the instruction must resend the refused code');
    assert.equal(calls[1], 'A'.repeat(40));
    assert.doesNotMatch(rig.status(), /not a Peekaa redemption QR/i,
      'an empty submit is the bug this closes, not the outcome');
  } finally { rig.restore() }
});

test('F-W4C-3 the retry prefill never overwrites what staff typed themselves', async () => {
  const calls = [];
  const rig = makeScannerRig({
    camera: true,
    jsQR: () => ({ data: 'A'.repeat(40) }),
    rpc: async (name, args) => {
      calls.push(args.p_qr_token);
      return { data: null, error: { code: '22023', message: 'welcome_offer_already_redeemed' } };
    }
  });
  try {
    rig.el('#merchantScannerToken').value = 'HALF-TYPED-BY-STAFF';
    await flush(); await flush(); await flush();
    await rig.pump(20);
    assert.equal(calls.length, 1);
    assert.equal(rig.el('#merchantScannerToken').value, 'HALF-TYPED-BY-STAFF',
      'a box someone is typing into is theirs — the camera must not take it over');
  } finally { rig.restore() }
});

/* ---------------------------------------------------------------- F-W4C-8 */

test('F-W4C-8 a decoder that failed to load is not reported as a camera problem', async () => {
  const rig = makeScannerRig({ camera: true, loadScannerLibrary: async () => { throw new Error('blocked cdn') } });
  try {
    await flush(); await flush(); await flush();
    assert.match(rig.status(), /QR reader could not load/i);
    assert.doesNotMatch(rig.status(), /Camera access was not available/,
      'the camera was never even asked for');
    assert.equal(rig.el('#merchantScannerCamera').disabled, false, 'the button stays a live retry');
  } finally { rig.restore() }
});

test('F-W4C-8 a decoder that failed to load is not blamed on the customer photo either', async () => {
  const rig = makeScannerRig({ loadScannerLibrary: async () => { throw new Error('blocked cdn') } });
  try {
    await rig.el('#merchantScannerImage').onchange({ target: { files: [{ name: 'qr.png' }] } });
    assert.match(rig.status(), /QR reader could not load/i);
    assert.doesNotMatch(rig.status(), /No Peekaa redemption QR was found in that image/,
      'the image path needs the same missing decoder — the picture was never the problem');
  } finally { rig.restore() }
});

test('F-W4C-8 an undecodable photo is still reported as an undecodable photo', async () => {
  /* The negative control for the two tests above: with the loader SUCCEEDING, a picture that
     carries no QR must still be reported as a picture problem, not as a loader problem. */
  const rig = makeScannerRig();
  try {
    await rig.el('#merchantScannerImage').onchange({ target: { files: [{ name: 'cat.png' }] } });
    assert.match(rig.status(), /No Peekaa redemption QR was found in that image/);
    assert.doesNotMatch(rig.status(), /QR reader could not load/i);
  } finally { rig.restore() }
});

/* ---------------------------------------------------------------- F-W4C-7 */

test('F-W4C-7 the "Reward voucher ready" banner emits the class that makes it a column', () => {
  /* Executed: the shipped template literal is lifted out and run with the same inputs the till
     gives it, so this asserts what the browser is actually handed. */
  const tplSrc = block('const pendingVouchers=(catalog.customerVouchers||[]).length',
    "id=\"tEntitlementScan\">${CUI.icon('scan',{size:16})} Scan reward QR</button>`:''}</div>`\n      :'';");
  const html = new Function('catalog', 'esc', 'canScanRedemption', 'tillUnitNounV430', 'CUI', `
    ${tplSrc}
    return pendingVouchers;`)(
    { customerVouchers: [{ reward_name: 'Free filter coffee', points_spent: 120 }] },
    v => String(v ?? ''), () => true, () => 'points', { icon: () => '' });

  const bannerClass = /<div class="([^"]+)"/.exec(html)?.[1] || '';
  assert.ok(bannerClass.split(/\s+/).includes('till-tier-benefits-v369'),
    `the banner must carry the class V399 gave its sibling (got "${bannerClass}")`);

  /* And that class must still be the thing that fixes it — a class name alone proves nothing. */
  const rule = /(?:^|\n)\.till-tier-benefits-v369\{([^}]*)\}/.exec(appCss)?.[1] || '';
  assert.match(rule, /flex-direction:column/, 'the class is what turns the flex row into a column');
  assert.match(appCss, /\.permission-banner\.till-tier-benefits-v369\{align-items:stretch\}/);

  /* The sibling this was copied from still has it, so the two banners in one card agree. */
  const sibling = /<div class="permission-banner welcome-offer-v215 till-tier-benefits-v369"[^>]*><b>Rewards this customer can claim/.test(appJs);
  assert.ok(sibling, 'the sibling gifts banner is the reference V399 established');
});
