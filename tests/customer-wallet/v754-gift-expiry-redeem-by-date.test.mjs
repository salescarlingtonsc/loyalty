/* nestly_v754 — a points gift's "Expires after" is the date it stops being redeemable, not a
 * post-claim countdown.
 *
 * Owner ruling 2026-09-04 (verbatim): "the expiry should be example 90 days — means after 90
 * days the reward would not be available to redeem with points (will not be shown in the
 * customer app for redemption) and customer will see exactly when the reward will expire &
 * after expiry, customer will use their points to redeem other rewards."
 *
 * These EXECUTE the shipped code lifted verbatim out of app/app.js, rather than grepping for it:
 *   - growPointsExpiryDaysFromUntilV754 / growPointsExpiryPreviewDateV754 — the day-count <->
 *     date round trip the points quick-add editor uses for its live preview and its edit prefill.
 *   - the customer redeem button's intentError branch — the "this gift has expired" message and
 *     the catalogue reload, for a customer who taps a card the server has already stopped
 *     offering (customer_create_redemption_intent_v89's 22023 'reward is unavailable').
 *
 * The server-side contract (claim_available_until pinned at publish time, enforced by
 * customer_create_redemption_intent_v89 / app.redeem_reward_core / app.reward_availability_v432)
 * is proved against a real Postgres by db/tests/v754_gift_expiry_is_a_redeem_by_date.sql.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../../app/app.js', import.meta.url), 'utf8');

const block = (start, end) => {
  const i = app.indexOf(start);
  assert.ok(i >= 0, `missing block: ${start}`);
  const j = app.indexOf(end, i);
  assert.ok(j > i, `missing end marker for ${start}`);
  return app.slice(i, j + end.length);
};

const walletDateSrc = block('function walletDate(value,withTime=false){', "return date.toLocaleString('en-SG',{timeZone:'Asia/Singapore',dateStyle:'medium',...(withTime?{timeStyle:'short'}:{})});\n}");
const expiryDaysFromUntilSrc = block(
  'const growPointsExpiryDaysFromUntilV754=value=>{',
  "return days>0?String(days):'';\n};"
);
const expiryPreviewSrc = block(
  'const growPointsExpiryPreviewDateV754=rawDays=>{',
  'return walletDate(new Date(Date.now()+days*86400000).toISOString());\n};'
);

/* Both helpers are plain functions with no page-scope dependencies beyond walletDate, so they can
   be evaluated together in isolation — exactly what they are at runtime, not a re-implementation. */
const { growPointsExpiryDaysFromUntilV754, growPointsExpiryPreviewDateV754 } = new Function(
  `${walletDateSrc}\n${expiryDaysFromUntilSrc}\n${expiryPreviewSrc}\nreturn {growPointsExpiryDaysFromUntilV754,growPointsExpiryPreviewDateV754};`
)();

test('v754 growPointsExpiryPreviewDateV754 previews a real future date for a positive day count', () => {
  const preview = growPointsExpiryPreviewDateV754('90');
  assert.notEqual(preview, '');
  // walletDate formats in en-SG medium style — sanity-check it round-trips to ~90 days out.
  const parsed = Date.parse(preview);
  assert.ok(Number.isFinite(parsed), `expected a parseable date, got ${preview}`);
  const days = Math.round((parsed - Date.now()) / 86400000);
  assert.ok(Math.abs(days - 90) <= 1, `expected ~90 days out, got ${days}`);
});

test('v754 growPointsExpiryPreviewDateV754 previews nothing for blank, zero or negative input', () => {
  assert.equal(growPointsExpiryPreviewDateV754(''), '');
  assert.equal(growPointsExpiryPreviewDateV754('0'), '');
  assert.equal(growPointsExpiryPreviewDateV754('-5'), '');
  assert.equal(growPointsExpiryPreviewDateV754('not a number'), '');
});

test('v754 growPointsExpiryDaysFromUntilV754 round-trips a future claim_available_until back to whole days', () => {
  const until = new Date(Date.now() + 90 * 86400000).toISOString();
  const days = growPointsExpiryDaysFromUntilV754(until);
  // Rounded UP (ceil), per the comment: reopening the editor a few hours later must not
  // visibly shrink a day count the owner is sure they set.
  assert.ok(Number(days) >= 90 && Number(days) <= 91, `expected 90 or 91, got ${days}`);
});

test('v754 growPointsExpiryDaysFromUntilV754 reads blank for no date, and for a date already past', () => {
  assert.equal(growPointsExpiryDaysFromUntilV754(null), '');
  assert.equal(growPointsExpiryDaysFromUntilV754(''), '');
  const past = new Date(Date.now() - 86400000).toISOString();
  assert.equal(growPointsExpiryDaysFromUntilV754(past), '',
    'a gift already past its deadline must reopen the editor blank, not negative');
});

/* The customer redeem button's error branch — the stale-gift message and reload. */
const redeemHandlerSrc = block(
  "    [...host.querySelectorAll('[data-customer-redeem]'),",
  '\n    });'
);

const makeRedeemButton = () => {
  const span = { textContent: 'Redeem' };
  return {
    disabled: false, isConnected: true,
    dataset: { customerRedeem: 'catalog:reward-1' },
    querySelector: () => span,
    onclick: null
  };
};

const runRedeemHandler = ({ error }) => {
  const button = makeRedeemButton();
  const toasts = [];
  let loadRewardsCalls = 0;
  const reward = { action_key: 'catalog:reward-1', id: 'reward-1', customer_name: 'V754 Ninety Day Gift' };
  const scope = {
    host: { querySelectorAll: sel => (sel === '[data-customer-redeem]' ? [button] : []) },
    heroRootV397: { querySelectorAll: () => [] },
    rewards: [reward],
    redemptionAttempt: null,
    businessId: 'biz-1',
    b: { name: 'V754 Fixture' },
    sb: { rpc: () => Promise.resolve({ data: null, error }) },
    crypto: { randomUUID: () => 'key-1' },
    isWalletSectionCurrent: () => true,
    toast: message => toasts.push(String(message)),
    loadRewards: () => { loadRewardsCalls++; },
    loadTransactions: () => {},
    customerCounterMomentV468: async () => {},
    customerHoldWalletScrollV748: () => () => {},
    customerRedemptionIntentArgsV89: () => ({}),
    showPendingRedemptionQr: () => {},
    CUSTOMER_REDEMPTION_STATUS_COPY: {}
  };
  const names = Object.keys(scope);
  new Function(...names, redeemHandlerSrc)(...names.map(n => scope[n]));
  return { button, toasts, getLoadRewardsCalls: () => loadRewardsCalls };
};

test('v754 a customer tapping an expired gift sees the expiry sentence, not the generic retry copy', async () => {
  const rig = runRedeemHandler({
    error: { code: '22023', message: 'reward is unavailable' }
  });
  await rig.button.onclick();
  assert.equal(rig.toasts.length, 1);
  assert.match(rig.toasts[0], /expired and can no longer be redeemed with points/i);
  assert.equal(rig.getLoadRewardsCalls(), 1,
    'the catalogue must be reloaded so the stale card is gone, not tappable again');
});

test('v754 a real server outage still gets the generic retry copy, not the expiry sentence', async () => {
  const rig = runRedeemHandler({
    error: { code: '08006', message: 'connection failure' }
  });
  await rig.button.onclick();
  assert.equal(rig.toasts.length, 1);
  assert.match(rig.toasts[0], /could not be prepared/i);
  assert.doesNotMatch(rig.toasts[0], /expired/i);
  assert.equal(rig.getLoadRewardsCalls(), 0,
    'a generic failure must not silently drop the card the customer was looking at');
});

test('v754 an unrelated 22023 (e.g. a malformed idempotency key) does not get mislabelled as expired', async () => {
  const rig = runRedeemHandler({
    error: { code: '22023', message: 'idempotency key must contain at least 8 characters' }
  });
  await rig.button.onclick();
  assert.doesNotMatch(rig.toasts[0], /expired/i,
    'only the specific "unavailable" wording should read as a stale gift');
  assert.equal(rig.getLoadRewardsCalls(), 0);
});
