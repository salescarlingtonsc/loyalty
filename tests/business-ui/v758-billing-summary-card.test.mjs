/* NESTLY v758 → v784/v786 — the Subscription page is a card per branch.
 *
 * Owner, 2026-09-05: the mockup — one card per branch (name, Main branch / Active / Payment issue,
 * "SGD 99 / month" with "Billed annually" under it, the renewal date, one button), tabs Branches /
 * Payment history, no summary card ("dont need to show full amount etc."), no trials ("all are
 * paid plans OR Demo account"), and — the ruling that reversed "one card for all" — every new
 * branch on its OWN Razorpay subscription with its own card, cycle and renewal date.
 *
 * This EXECUTES the real line builders lifted out of app/app.js — no regex over markup, because
 * the thing under test is what the card SAYS (docs: "Source-regex tests are vacuous").
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const app = readFileSync(resolve(root, 'app/app.js'), 'utf8');

const grab = (name, signature) => {
  const start = app.indexOf(signature);
  assert.ok(start > -1, `${name} must exist in app/app.js`);
  const end = app.indexOf('\n}\n', start);
  assert.ok(end > start, `${name} must be a top-level function`);
  return app.slice(start, end + 3);
};

const sandbox = vm.createContext({
  Intl, Date, Number, Math, JSON, String, Array, Object, console,
  /* the app's own escaper and icon helper, stubbed the way the renderer calls them */
  esc: (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])),
  CUI: { icon: (name) => `<i data-icon="${name}"></i>` },
  branchBillingCountsV280: null
});
vm.runInContext([
  grab('billingDateV758', 'function billingDateV758(value){'),
  grab('billingPeriodWordV758', 'function billingPeriodWordV758(planLabel){'),
  grab('moneyShortV758', 'function moneyShortV758(cents){'),
  grab('billingStatusWordV758', 'function billingStatusWordV758(status){'),
  grab('billingCardTextV758', 'function billingCardTextV758(method){'),
  grab('billingBranchCardLinesV784', 'function billingBranchCardLinesV784(branch,summary,billing,paymentMethod,options){'),
  grab('subscriptionBranchCardsV784', 'function subscriptionBranchCardsV784(cards){'),
  grab('billingAddBranchStepsV784', 'function billingAddBranchStepsV784(){'),
  grab('branchBillingCountsV280', 'function branchBillingCountsV280(list){'),
  grab('billingSummaryFallbackV758', 'function billingSummaryFallbackV758(billing,branchRows){'),
  grab('billingBranchPillV758', 'function billingBranchPillV758(branch){')
].join('\n'), sandbox);

const card = (branch, summary, billing, method, options) =>
  sandbox.billingBranchCardLinesV784(branch, summary, billing, method, options);
/* values cross the vm realm boundary: copy them into this realm before a deep comparison */
const labels = (out) => Array.from(out.pills, (p) => p.label);

const CARD = { kind: 'card', brand: 'Visa', last4: '7820' };
/* one annual company plan: SGD 1,188 per branch */
const ANNUAL = {
  plan_label: 'Annual', capacity: 10000, unit_amount_cents: 118800, units: 1, total_cents: 118800,
  renews_at: '2026-10-14T00:00:00+08:00', state: 'active', trial_ends_at: null, cancel_at_period_end: false
};
const FLAT = { flat_price: { annual_cents: 118800, monthly_cents: 14800, annual_available: true, monthly_available: true } };
const MAIN = { id: 'b-main', name: 'Cubbly · Orchard', is_default: true, active: true, billing_state: 'included', billing_mode: 'shared' };

/* ------------------------------------------------------------ the mockup, line by line */

test('the main branch on an annual plan reads as the mockup: 99 a month, billed annually, renews on', () => {
  const out = card(MAIN, ANNUAL, FLAT, CARD);
  assert.equal(out.name, 'Cubbly · Orchard');
  assert.deepEqual(labels(out), ['Main branch', 'Active']);
  assert.equal(out.note, 'Includes your core Peekaa plan');
  assert.equal(out.price, 'SGD 99 / month');
  assert.equal(out.billed, 'Billed annually');
  assert.equal(out.when, 'Renews on 14 Oct 2026');
  assert.equal(out.when_tone, 'muted');
  assert.deepEqual({ ...out.action }, { kind: 'manage', label: 'Manage' });
  assert.equal(out.card, 'Visa ending 7820');
  assert.equal(out.mode, 'shared');
});

test('a monthly plan prints its real monthly price and says so', () => {
  const out = card(MAIN, { ...ANNUAL, plan_label: 'Monthly', unit_amount_cents: 14800 }, FLAT, CARD);
  assert.equal(out.price, 'SGD 148 / month');
  assert.equal(out.billed, 'Billed monthly');
});

test('a larger annual tier prints its own divided figure, never a hardcoded 99', () => {
  const out = card(MAIN, { ...ANNUAL, unit_amount_cents: 168800 }, FLAT, CARD);
  assert.equal(out.price, 'SGD 140.67 / month');
  assert.equal(out.billed, 'Billed annually');
});

test('a failed company payment reads Payment issue / Payment unsuccessful / Fix payment', () => {
  const out = card(MAIN, { ...ANNUAL, state: 'past_due' }, FLAT, CARD);
  assert.deepEqual(labels(out), ['Main branch', 'Payment issue']);
  assert.equal(out.when, 'Payment unsuccessful');
  assert.equal(out.when_tone, 'no');
  assert.deepEqual({ ...out.action }, { kind: 'fix', label: 'Fix payment' });
});

test('a shared branch whose own payment lapsed reads the same way, whatever the company says', () => {
  const out = card({ id: 'b-abc', name: 'abc', active: false, billing_state: 'suspended', billing_mode: 'shared' }, ANNUAL, FLAT, CARD);
  assert.deepEqual(labels(out), ['Payment issue']);
  assert.equal(out.when, 'Payment unsuccessful');
  assert.deepEqual({ ...out.action }, { kind: 'fix', label: 'Fix payment' });
});

/* ---------------------------------------------------------------- no trial, ever */

test('a firm that has not paid is told so — never "Free trial" — and offered the plan choice', () => {
  const trial = { plan_label: null, unit_amount_cents: 0, units: 1, total_cents: 0, renews_at: null,
    state: 'trial', trial_ends_at: '2026-09-14T15:59:59+00:00', cancel_at_period_end: false };
  const out = card(MAIN, trial, { ...FLAT, capacity_tiers: [] }, null);
  assert.deepEqual(labels(out), ['Main branch', 'Not paid yet']);
  assert.equal(out.when, 'No payment yet');
  /* the price is still said, from the flat price, so the card is never blank */
  assert.equal(out.price, 'SGD 99 / month');
  assert.equal(out.billed, 'Billed annually');
  assert.deepEqual({ ...out.action }, { kind: 'choose', label: 'Choose plan' });
  assert.equal(out.card, 'No card yet');
  for (const line of [out.when, out.price, out.billed, ...labels(out)]) {
    assert.doesNotMatch(line, /trial/i, `the word trial reached the owner: ${line}`);
  }
});

/* ------------------------------------------------------- a branch on its own subscription */

const OWN = { id: 'b-east', name: 'East Coast', is_default: false, active: true, billing_state: 'active', billing_mode: 'own' };
const OWN_SUB = {
  branch_id: 'b-east', provider_subscription_id: 'sub_x', status: 'active', payment_status: 'paid',
  cadence: 'monthly', plan_label: 'Monthly', unit_amount_cents: 14800,
  renews_at: '2026-11-02T00:00:00+08:00', state: 'active', cancel_at_period_end: false,
  payment_method: { kind: 'card', brand: 'Mastercard', last4: '1881' }
};

test('an own-billed branch is priced, dated and carded by ITS subscription, not the company', () => {
  const out = card(OWN, ANNUAL, { ...FLAT, branch_subscriptions: [OWN_SUB] }, CARD);
  assert.equal(out.mode, 'own');
  assert.equal(out.price, 'SGD 148 / month');
  assert.equal(out.billed, 'Billed monthly');
  assert.equal(out.when, 'Renews on 2 Nov 2026');
  assert.equal(out.card, 'Mastercard ending 1881');
  assert.equal(out.note, 'Billed on its own card');
  assert.deepEqual(labels(out), ['Active']);
  assert.deepEqual({ ...out.action }, { kind: 'manage', label: 'Manage' });
});

test('an own-billed branch that has not paid yet offers Pay now, at the flat price of its cycle', () => {
  const out = card({ ...OWN, active: false, billing_state: 'pending_payment' }, ANNUAL, { ...FLAT, branch_subscriptions: [] }, CARD);
  assert.deepEqual(labels(out), ['Not paid yet']);
  assert.equal(out.price, 'SGD 99 / month');
  assert.equal(out.billed, 'Billed annually');
  assert.deepEqual({ ...out.action }, { kind: 'pay', label: 'Pay now' });
  assert.equal(out.card, 'No card yet');
});

test('an own-billed branch whose card failed is a Payment issue of its own', () => {
  const out = card(OWN, ANNUAL, { ...FLAT, branch_subscriptions: [{ ...OWN_SUB, state: 'past_due', payment_status: 'failed' }] }, CARD);
  assert.deepEqual(labels(out), ['Payment issue']);
  assert.equal(out.when, 'Payment unsuccessful');
  assert.deepEqual({ ...out.action }, { kind: 'fix', label: 'Fix payment' });
});

test('an own-billed branch that is stopping says the date it ends', () => {
  const out = card({ ...OWN, billing_state: 'canceling', billing_cancel_at: '2026-11-02T00:00:00+08:00' }, ANNUAL,
    { ...FLAT, branch_subscriptions: [{ ...OWN_SUB, state: 'canceling', cancel_at_period_end: true }] }, CARD);
  assert.deepEqual(labels(out), ['Switches off 2 Nov 2026']);
  assert.equal(out.when, 'Ends on 2 Nov 2026');
});

/* ------------------------------------------------------------------- the rendered cards */

test('the cards render each line and one button, and the empty state says so', () => {
  const html = sandbox.subscriptionBranchCardsV784([
    card(MAIN, ANNUAL, FLAT, CARD),
    card({ id: 'b-abc', name: 'abc', active: false, billing_state: 'suspended', billing_mode: 'shared' }, ANNUAL, FLAT, CARD)
  ]);
  assert.match(html, /Cubbly · Orchard/);
  assert.match(html, /Includes your core Peekaa plan/);
  assert.match(html, /SGD 99 \/ month/);
  assert.match(html, /Billed annually/);
  assert.match(html, /Renews on 14 Oct 2026/);
  assert.match(html, /data-branch-card-action-v784="manage" data-branch-id-v784="b-main">Manage/);
  assert.match(html, /Payment unsuccessful/);
  assert.match(html, /data-branch-card-action-v784="fix" data-branch-id-v784="b-abc">Fix payment/);
  assert.match(sandbox.subscriptionBranchCardsV784([]), /No branches yet/);
});

test('the adding-a-branch strip has the three steps in the mockup\'s words', () => {
  const html = sandbox.billingAddBranchStepsV784();
  assert.match(html, /Adding a new branch/);
  assert.match(html, /It only takes a few steps to get your new branch up and running\./);
  for (const step of ['Enter branch details', 'Confirm monthly price', 'Branch goes live']) assert.match(html, new RegExp(step));
});

/* --------------------------------------------------------------------------- copy rules */

test('every card line stays inside the owner-facing copy rules', () => {
  const banned = /\b(tier|cadence|unit|units|provider|proration|prorated|trial)\b/i;
  for (const [branch, summary, billing] of [
    [MAIN, ANNUAL, FLAT],
    [MAIN, { ...ANNUAL, state: 'past_due' }, FLAT],
    [OWN, ANNUAL, { ...FLAT, branch_subscriptions: [OWN_SUB] }],
    [{ ...OWN, billing_state: 'pending_payment' }, ANNUAL, { ...FLAT, branch_subscriptions: [] }]
  ]) {
    const out = card(branch, summary, billing, CARD);
    for (const line of [out.note, out.price, out.billed, out.when, out.action.label, ...labels(out)]) {
      if (!line) continue;
      assert.doesNotMatch(line, banned, `owner-facing jargon in: ${line}`);
      assert.ok(line.split(/\s+/).length <= 10, `over 10 words: ${line}`);
    }
  }
});

/* -------------------------------------------------------------------- unchanged helpers */

test('the client fallback reproduces the server summary from the same rows', () => {
  const summary = sandbox.billingSummaryFallbackV758({
    status: 'active', payment_status: 'paid', cancel_at_period_end: false,
    next_payment_at: '2027-09-04T00:00:00+08:00',
    terms: { cadence: 'annual', customer_capacity: 10000 },
    capacity_tiers: [
      { cadence: 'annual', capacity_ceiling: 1000, amount_cents: 118800 },
      { cadence: 'annual', capacity_ceiling: 10000, amount_cents: 500000 },
      { cadence: 'monthly', capacity_ceiling: 10000, amount_cents: 49900 }
    ]
  }, [
    { billing_state: 'included' }, { billing_state: 'active' }, { billing_state: 'canceling' }
  ]);
  assert.equal(summary.plan_label, 'Annual');
  assert.equal(summary.branches_total, 3);
  assert.equal(summary.branches_billable, 1);
  assert.equal(summary.units, 2);
  assert.equal(summary.total_cents, 1000000);
  assert.equal(summary.state, 'active');
});

test('money on this page is a headline, not a receipt', () => {
  assert.equal(sandbox.moneyShortV758(1000000), 'SGD 10,000');
  assert.equal(sandbox.moneyShortV758(118800), 'SGD 1,188');
  assert.equal(sandbox.moneyShortV758(168850), 'SGD 1,688.50');
  assert.equal(sandbox.moneyShortV758(0), 'SGD 0');
  assert.equal(sandbox.moneyShortV758(null), 'SGD 0');
  assert.match(app, /const money=c=>\(S\.biz\?\.currency\|\|'SGD'\)\+' '\+\(\(c\|\|0\)\/100\)\.toFixed\(2\)/);
});

test('a payment status is written the way a person reads it', () => {
  assert.equal(sandbox.billingStatusWordV758('paid'), 'Paid');
  assert.equal(sandbox.billingStatusWordV758('past_due'), 'Past Due');
  assert.equal(sandbox.billingStatusWordV758(null), '—');
});

test('a card we cannot name is never invented, and a non-card method is not called a card', () => {
  assert.equal(sandbox.billingCardTextV758({ kind: 'card', brand: 'Visa', last4: '7820' }), 'Visa ending 7820');
  assert.equal(sandbox.billingCardTextV758({ kind: 'card' }), 'Card on file');
  assert.equal(sandbox.billingCardTextV758({ kind: 'paynow' }), 'Payment method on file');
  assert.equal(sandbox.billingCardTextV758(null), 'No card yet');
});

/* ------------------------------------------------------- wiring, asserted structurally */

test('the page reads get_business_billing_v786 and falls back to the reads it wraps', () => {
  assert.match(app, /async function fetchBusinessBillingV758\(businessId\)\{/);
  assert.match(app, /sb\.rpc\('get_business_billing_v786',\{p_business:businessId\}\)/);
  assert.match(app, /sb\.rpc\('get_business_billing_v758',\{p_business:businessId\}\)/);
  assert.match(app, /sb\.rpc\('get_business_billing_v125',\{p_business:businessId\}\)/);
  const fnStart = app.indexOf('async function loadBillingConfig(){');
  const fnEnd = app.indexOf('\n/* ---------- customer sign-up QR ---------- */');
  const fn = app.slice(fnStart, fnEnd);
  assert.match(fn, /fetchBusinessBillingV758\(S\.biz\.id\)/);
  // two tabs, the cards then the strip, the payments table in the other panel, one status line
  assert.match(fn, /tabButton\('branches','branch','Branches'\)/);
  assert.match(fn, /tabButton\('payments','wallet','Payment history'\)/);
  assert.ok(fn.indexOf('subscriptionBranchCardsV784(cardsV784)') < fn.indexOf('billingAddBranchStepsV784()'));
  assert.ok(fn.indexOf('id="billingPanelPaymentsV784"') < fn.indexOf('billingInvoiceTableV758(b,summaryV758)'));
  assert.match(fn, /id="billingCommandStatus"/);
  // the summary card, the Change plan drawer and the Details expander are gone from the page
  assert.doesNotMatch(fn, /billingSummaryCardV758\(/);
  assert.doesNotMatch(fn, /id="billingChangePlanV758"/);
  assert.doesNotMatch(fn, /Free trial/);
  // the money paths are the existing ones: business commands through v124, branch commands through v786
  assert.match(fn, /sb\.rpc\('request_billing_command_v124'/);
  assert.match(fn, /sb\.rpc\('request_branch_billing_command_v786'/);
  assert.match(fn, /sb\.functions\.invoke\('razorpay-billing-command'/);
  // a demo account is named as one, and nothing else about it differs
  assert.match(fn, /S\.biz\?\.is_demo\?'<span class="pill new">Demo account<\/span>':''/);
});

test('the shared-branch actions are still the v665 RPCs, with the confirmation unchanged', () => {
  assert.match(app, /sb\.rpc\(kind==='stop'\?'business_unsubscribe_branch_v665':'business_resubscribe_branch_v665'/);
  assert.match(app, /function branchSwitchOffConfirmV764\(record\)\{/);
  assert.match(app, /It keeps working until then\. Not charged after\./);
  assert.match(app, /Nothing is refunded, and its customers, sales and bookings stay in your reports\./);
  assert.match(app, /data-branch-stop-v758/);
  assert.match(app, /data-branch-keep-v758/);
  // an own-billed branch stops through its OWN renewal intent, never the company's
  assert.match(app, /sb\.rpc\('set_branch_renewal_intent_v786',\{p_business:S\.biz\.id,p_branch:branchId,p_cancel:cancel\}\)/);
});
