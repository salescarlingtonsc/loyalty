/* NESTLY v758 — the billing page answers four questions before it is touched.
 *
 * Owner, 2026-09-04: "just show me what I subscribed to, how many branches, how much in total,
 * and the renew date." This EXECUTES the real renderer helpers lifted out of app/app.js — no
 * regex over markup, because the thing under test is what the four lines SAY (docs:
 * "Source-regex tests are vacuous"). Four fixtures: trial, active with one branch, active with
 * three branches one of which is stopping, and past due.
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
  /* the app's own money() helper, quoted exactly (app/app.js), with the workspace default
     currency — the renderer must go through it rather than formatting money itself. */
  money: (c) => 'SGD ' + ((c || 0) / 100).toFixed(2),
  branchBillingCountsV280: null
});
vm.runInContext([
  grab('billingDateV758', 'function billingDateV758(value){'),
  grab('billingPeriodWordV758', 'function billingPeriodWordV758(planLabel){'),
  grab('moneyShortV758', 'function moneyShortV758(cents){'),
  grab('billingStatusWordV758', 'function billingStatusWordV758(status){'),
  grab('billingCardTextV758', 'function billingCardTextV758(method){'),
  grab('billingSummaryLinesV758', 'function billingSummaryLinesV758(summary,businessName,paymentMethod){'),
  grab('branchBillingCountsV280', 'function branchBillingCountsV280(list){'),
  grab('billingSummaryFallbackV758', 'function billingSummaryFallbackV758(billing,branchRows){'),
  grab('billingBranchPillV758', 'function billingBranchPillV758(branch){')
].join('\n'), sandbox);

const lines = (summary, name, method) => sandbox.billingSummaryLinesV758(summary, name, method);

/* ------------------------------------------------------------------ fixture 1: free trial */

test('a trial says it is free, until when, and that no card is on file', () => {
  const out = lines({
    plan_label: null, capacity: 0,
    branches_total: 1, branches_included: 1, branches_billable: 0,
    branches_stopping: 0, branches_lapsed: 0, branches_unsubscribed: 0,
    unit_amount_cents: 0, units: 1, total_cents: 0,
    renews_at: null, state: 'trial', trial_ends_at: '2026-09-18T00:00:00+08:00',
    cancel_at_period_end: false
  }, 'Kopi Lab', null);
  assert.equal(out.title, 'Kopi Lab · Free trial');
  assert.equal(out.branches, '1 branch · 1 charged (first is in the plan price)');
  assert.equal(out.amount, 'SGD 0 until 18 Sep 2026');
  assert.equal(out.arithmetic, '');
  assert.equal(out.renewal, 'No renewal date yet · No card yet');
  assert.deepEqual({ ...out.pill }, { label: 'Trial', tone: 'new' });
});

/* -------------------------------------------------------- fixture 2: active, one branch */

test('one paid branch reads as one plan, one number, one date', () => {
  const out = lines({
    plan_label: 'Annual', capacity: 1000,
    branches_total: 1, branches_included: 1, branches_billable: 0,
    branches_stopping: 0, branches_lapsed: 0, branches_unsubscribed: 0,
    unit_amount_cents: 118800, units: 1, total_cents: 118800,
    renews_at: '2027-09-04T00:00:00+08:00', state: 'active', trial_ends_at: null,
    cancel_at_period_end: false
  }, 'Kopi Lab', { kind: 'card', brand: 'Visa', last4: '7820' });
  assert.equal(out.title, 'Kopi Lab · Annual plan · Up to 1,000 profiles');
  assert.equal(out.branches, '1 branch · 1 charged (first is in the plan price)');
  assert.equal(out.amount, 'SGD 1,188 / year');
  assert.equal(out.arithmetic, '1 branch × SGD 1,188 / year');
  assert.equal(out.renewal, 'Renews on 4 Sep 2027 · Visa ending 7820');
  assert.deepEqual({ ...out.pill }, { label: 'Active', tone: 'ok' });
});

/* ------------------------- fixture 3: active, three branches, one stopping at renewal */

const THREE_BRANCH_FIXTURE = {
  plan_label: 'Annual', capacity: 10000,
  branches_total: 3, branches_included: 1, branches_billable: 1,
  branches_stopping: 1, branches_lapsed: 0, branches_unsubscribed: 0,
  unit_amount_cents: 500000, units: 2, total_cents: 1000000,
  renews_at: '2027-09-04T00:00:00+08:00', state: 'active', trial_ends_at: null,
  cancel_at_period_end: false
};

test('three branches state the stopping one without hiding it in a dialog', () => {
  const out = lines(THREE_BRANCH_FIXTURE, 'Kopi Lab', { kind: 'card', brand: 'Visa', last4: '7820' });
  assert.equal(out.title, 'Kopi Lab · Annual plan · Up to 10,000 profiles');
  assert.equal(out.branches, '3 branches · 2 charged (first is in the plan price) · 1 stopping at renewal');
  assert.equal(out.amount, 'SGD 10,000 / year');
  assert.equal(out.arithmetic, '2 branches × SGD 5,000 / year');
  assert.equal(out.renewal, 'Renews on 4 Sep 2027 · Visa ending 7820');
  assert.deepEqual({ ...out.pill }, { label: 'Active', tone: 'ok' });
  /* a branch stopping at renewal is NOT counted as billable — that is the arithmetic the total
     depends on, so it is asserted here rather than assumed. */
  assert.equal(THREE_BRANCH_FIXTURE.total_cents,
    THREE_BRANCH_FIXTURE.unit_amount_cents * (1 + THREE_BRANCH_FIXTURE.branches_billable));
});

/* ------------------------------------------------------------------ fixture 4: past due */

test('a failed payment says so, and says we will retry', () => {
  const out = lines({
    plan_label: 'Monthly', capacity: 1000,
    branches_total: 2, branches_included: 1, branches_billable: 1,
    branches_stopping: 0, branches_lapsed: 1, branches_unsubscribed: 0,
    unit_amount_cents: 14800, units: 2, total_cents: 29600,
    renews_at: '2026-10-01T00:00:00+08:00', state: 'past_due', trial_ends_at: null,
    cancel_at_period_end: false
  }, 'Kopi Lab', { kind: 'card', brand: 'Mastercard', last4: '4242' });
  assert.equal(out.title, 'Kopi Lab · Monthly plan · Up to 1,000 profiles');
  assert.equal(out.branches, '2 branches · 2 charged (first is in the plan price) · 1 payment lapsed');
  assert.equal(out.amount, 'SGD 296 / month');
  assert.equal(out.arithmetic, '2 branches × SGD 148 / month');
  assert.equal(out.renewal, 'Payment failed · we will retry · Mastercard ending 4242');
  assert.deepEqual({ ...out.pill }, { label: 'Payment failed', tone: 'no' });
});

/* --------------------------------------------------------------------------- edges */

test('a subscription that will not renew says the date it ends, not the date it renews', () => {
  const out = lines({ ...THREE_BRANCH_FIXTURE, state: 'canceling', cancel_at_period_end: true },
    'Kopi Lab', { kind: 'card', brand: 'Visa', last4: '7820' });
  assert.equal(out.renewal, 'Ends on 4 Sep 2027 · will not renew · Visa ending 7820');
  assert.deepEqual({ ...out.pill }, { label: 'Cancels 4 Sep 2027', tone: 'off' });
});

test('a card we cannot name is never invented, and a non-card method is not called a card', () => {
  assert.equal(sandbox.billingCardTextV758({ kind: 'card', brand: 'Visa', last4: '7820' }), 'Visa ending 7820');
  assert.equal(sandbox.billingCardTextV758({ kind: 'card' }), 'Card on file');
  assert.equal(sandbox.billingCardTextV758({ kind: 'paynow' }), 'Payment method on file');
  assert.equal(sandbox.billingCardTextV758(null), 'No card yet');
});

test('every line stays inside the owner-facing copy rules', () => {
  const banned = /\b(tier|cadence|unit|units|provider|proration|prorated)\b/i;
  for (const fixture of [
    { s: THREE_BRANCH_FIXTURE, m: { kind: 'card', brand: 'Visa', last4: '7820' } },
    { s: { ...THREE_BRANCH_FIXTURE, state: 'past_due' }, m: null },
    { s: { ...THREE_BRANCH_FIXTURE, state: 'canceling', cancel_at_period_end: true }, m: null }
  ]) {
    const out = lines(fixture.s, 'Kopi Lab', fixture.m);
    for (const line of [out.title, out.branches, out.amount, out.arithmetic, out.renewal, out.pill.label]) {
      if (!line) continue;
      assert.doesNotMatch(line, banned, `owner-facing jargon in: ${line}`);
      const words = line.split(/\s+/).filter((w) => w && w !== '\u00b7');
      /* Line 2 carries the parenthetical the design review asked for ("2 charged (first is in
         the plan price)"), which is 14 words. Every other line stays inside 12. */
      const budget = line === out.branches ? 16 : 12;
      assert.ok(words.length <= budget, `over ${budget} words: ${line}`);
    }
  }
});

/* The server owns this arithmetic (get_business_billing_v758). The fallback exists only for a
   workspace whose database has not been migrated yet, and it must agree with the server. */
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
  assert.equal(summary.branches_stopping, 1);
  assert.equal(summary.units, 2);
  assert.equal(summary.total_cents, 1000000);
  assert.equal(summary.state, 'active');
  assert.equal(lines(summary, 'Kopi Lab', { kind: 'card', brand: 'Visa', last4: '7820' }).amount,
    'SGD 10,000 / year');
});

test('money on this page is a headline, not a receipt', () => {
  assert.equal(sandbox.moneyShortV758(1000000), 'SGD 10,000');
  assert.equal(sandbox.moneyShortV758(118800), 'SGD 1,188');
  assert.equal(sandbox.moneyShortV758(168850), 'SGD 1,688.50');
  assert.equal(sandbox.moneyShortV758(0), 'SGD 0');
  assert.equal(sandbox.moneyShortV758(null), 'SGD 0');
  // it is this page's formatter only — the shared money() helper is untouched
  assert.match(app, /const money=c=>\(S\.biz\?\.currency\|\|'SGD'\)\+' '\+\(\(c\|\|0\)\/100\)\.toFixed\(2\)/);
});

test('a payment status is written the way a person reads it', () => {
  assert.equal(sandbox.billingStatusWordV758('paid'), 'Paid');
  assert.equal(sandbox.billingStatusWordV758('failed'), 'Failed');
  assert.equal(sandbox.billingStatusWordV758('refunded'), 'Refunded');
  assert.equal(sandbox.billingStatusWordV758('past_due'), 'Past Due');
  assert.equal(sandbox.billingStatusWordV758(null), '—');
});

test('the main branch is labelled, never offered a one-tap switch-off', () => {
  const start = app.indexOf('function subscriptionBranchListV758(billing,summary){');
  const fn = app.slice(start, app.indexOf('\n}\n', start));
  // the guard sits BEFORE the stop button is ever built
  assert.ok(fn.indexOf("if(branch.is_default===true)return '';") <
    fn.indexOf('data-branch-stop-v758'), 'the main branch must be excluded before the stop action');
  assert.match(fn, /is_default===true\?'<span class="pill off">Main branch<\/span>':''/);
  // and a branch already stopping can still be kept, main or not
  assert.ok(fn.indexOf('data-branch-keep-v758') < fn.indexOf("if(branch.is_default===true)return '';"));
});

test('each branch row says which of the six states it is in', () => {
  const label = (state, extra) => sandbox.billingBranchPillV758({ billing_state: state, ...extra }).label;
  assert.equal(label('included'), 'Included');
  assert.equal(label('active'), 'Billed');
  assert.equal(label('pending_payment'), 'Awaiting payment');
  /* nestly_v764 (owner ruling 2): the act is "Switch off", so the row says when it switches off. */
  assert.equal(label('canceling', { billing_cancel_at: '2027-09-04T00:00:00+08:00' }), 'Switches off 4 Sep 2027');
  assert.equal(label('unsubscribed'), 'Unsubscribed');
  assert.equal(label('suspended'), 'Payment lapsed');
});

/* ------------------------------------------------------- wiring, asserted structurally */

test('the page reads get_business_billing_v758 and falls back to the read it wraps', () => {
  assert.match(app, /async function fetchBusinessBillingV758\(businessId\)\{/);
  assert.match(app, /sb\.rpc\('get_business_billing_v758',\{p_business:businessId\}\)/);
  assert.match(app, /sb\.rpc\('get_business_billing_v125',\{p_business:businessId\}\)/);
  const fnStart = app.indexOf('async function loadBillingConfig(){');
  const fnEnd = app.indexOf('\n/* ---------- customer sign-up QR ---------- */');
  const fn = app.slice(fnStart, fnEnd);
  assert.match(fn, /fetchBusinessBillingV758\(S\.biz\.id\)/);
  // the summary card is the first thing drawn, above the branches and the drawer
  assert.ok(fn.indexOf('billingSummaryCardV758(') < fn.indexOf('subscriptionBranchListV758('));
  assert.ok(fn.indexOf('subscriptionBranchListV758(') < fn.indexOf('billingInvoiceTableV758('));
  assert.ok(fn.indexOf('billingInvoiceTableV758(') < fn.indexOf('id="billingChangePlanV758"'));
  // the existing money paths are untouched: the drawer still drives request_billing_command_v124
  assert.match(fn, /sb\.rpc\('request_billing_command_v124'/);
  assert.match(fn, /sb\.functions\.invoke\('razorpay-billing-command'/);
  // and the summary card's primary button only OPENS the drawer — it never charges
  assert.match(fn, /billingChoosePlanV758'\)\.onclick=\(\)=>\{[\s\S]{0,200}drawer\.open=true/);
});

test('the branch actions are still the v665 RPCs, with the confirmation unchanged', () => {
  assert.match(app, /sb\.rpc\(kind==='stop'\?'business_unsubscribe_branch_v665':'business_resubscribe_branch_v665'/);
  /* nestly_v764 (owner ruling 2): the same two RPCs and the same three promises — it keeps
     working until the date, it is not charged after, nothing is refunded — said as "Switch off". */
  assert.match(app, /function branchSwitchOffConfirmV764\(record\)\{/);
  assert.match(app, /It keeps working until then\. Not charged after\./);
  assert.match(app, /Nothing is refunded, and its customers, sales and bookings stay in your reports\./);
  assert.match(app, /data-branch-stop-v758/);
  assert.match(app, /data-branch-keep-v758/);
  // the company-level rows are gone from the per-branch dialog
  const dialogStart = app.indexOf('function openSubscriptionBranchDetailV628(payload){');
  const dialog = app.slice(dialogStart, app.indexOf('\n}\n', dialogStart));
  assert.doesNotMatch(dialog, /Payment frequency|Billed until|'Payment method'/);
  assert.match(dialog, /\['Address',record\.address\]/);
  assert.match(dialog, /\['Phone',record\.phone\]/);
});
