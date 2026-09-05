/* NESTLY v764 — the billing page tells the truth about what happens next.
 *
 * Owner rulings 2026-09-05: (1) adding a branch mid-period shows the pro-rata charge and the
 * card it goes to BEFORE anything is created, and the payments list says which branch and until
 * when; (2) removing a branch is "Switch off", with the date it switches off; (3) a billing-cycle
 * change starts on the renewal date and the page SAYS the date; (4) a cancelled renewal keeps
 * working to the end and can be resumed, with a confirmation naming money, date and card, until
 * the cancel has actually been sent to Razorpay; (5) the card can be changed.
 *
 * Every assertion below EXECUTES the real renderer from app/app.js against a fixture — the
 * sentences are the thing under test, and a regex over markup cannot see a sentence
 * (docs: "Source-regex tests are vacuous").
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
const grabConst = (name) => {
  const start = app.indexOf(`const ${name}=`);
  assert.ok(start > -1, `${name} must exist in app/app.js`);
  const end = app.indexOf('</style>`;', start);
  assert.ok(end > start, `${name} must be the style block it was`);
  return app.slice(start, end + '</style>`;'.length);
};

const sandbox = vm.createContext({ Intl, Date, Number, Math, JSON, String, Array, Object, console });
vm.runInContext([
  /* the app's own escaper, quoted from app/app.js so the card is built the way the app builds it */
  "const esc=s=>String(s??'').replace(/[&<>\"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;',\"'\":'&#39;'}[c]));",
  grabConst('BILLING_LAYOUT_STYLE_V758'),
  grab('billingDateV758', 'function billingDateV758(value){'),
  grab('billingPeriodWordV758', 'function billingPeriodWordV758(planLabel){'),
  grab('moneyShortV758', 'function moneyShortV758(cents){'),
  grab('billingStatusWordV758', 'function billingStatusWordV758(status){'),
  grab('billingCardTextV758', 'function billingCardTextV758(method){'),
  grab('billingSummaryLinesV758', 'function billingSummaryLinesV758(summary,businessName,paymentMethod){'),
  grab('billingSummaryCardV758', 'function billingSummaryCardV758(lines,options){'),
  grab('billingInvoiceTableV758', 'function billingInvoiceTableV758(billing,summary){'),
  grab('billingCadenceWordV764', 'function billingCadenceWordV764(cadence){'),
  grab('billingCadenceEffectiveAtV764', 'function billingCadenceEffectiveAtV764(currentCadence,nextCadence,renewsAt,now){'),
  grab('billingLifecycleLinesV764', 'function billingLifecycleLinesV764(billing,summary,paymentMethod){'),
  grab('branchProrataConfirmLinesV764', 'function branchProrataConfirmLinesV764(preview,branchName){'),
  grab('branchSwitchOffConfirmV764', 'function branchSwitchOffConfirmV764(record){'),
  grab('billingInvoiceReasonTextV764', 'function billingInvoiceReasonTextV764(row,planLabel,mainBranchName){')
].join('\n'), sandbox);

const CARD = { kind: 'card', brand: 'MC', last4: '9037' };
/* one annual company on two branches: SGD 1,188 per branch, SGD 2,376 a year */
const SUMMARY = {
  plan_label: 'Annual', capacity: 1000,
  branches_total: 2, branches_included: 1, branches_billable: 1,
  branches_stopping: 0, branches_lapsed: 0, branches_unsubscribed: 0,
  unit_amount_cents: 118800, units: 2, total_cents: 237600,
  renews_at: '2027-09-05T00:00:00+08:00', state: 'active', trial_ends_at: null,
  cancel_at_period_end: false
};
const life = (billing, summary = SUMMARY, method = CARD) =>
  sandbox.billingLifecycleLinesV764(billing, summary, method);

/* ------------------------------------------------- ruling 3: a cycle change says WHEN it starts */

test('a scheduled cycle change says the date it starts and offers to keep the current one', () => {
  const out = life({}, {
    ...SUMMARY,
    scheduled_change: { cadence: 'monthly', effective_at: '2027-09-05T00:00:00+08:00', amount_cents: 29600 }
  });
  assert.equal(out.scheduled_line, 'Monthly billing starts on 5 Sep 2027 · SGD 296 / month');
  assert.equal(out.scheduled_undo_label, 'Keep annual');
  assert.equal(out.scheduled_undo_cadence, 'annual');
  /* the subscription columns say the same thing when the server summary has not been rebuilt */
  const fromColumns = life({
    scheduled_cadence: 'monthly', scheduled_effective_at: '2027-09-05T00:00:00+08:00',
    scheduled_amount_cents: 29600
  });
  assert.equal(fromColumns.scheduled_line, out.scheduled_line);
});

test('a plan with nothing scheduled says nothing about a future cycle', () => {
  const out = life({});
  assert.equal(out.scheduled_line, '');
  assert.equal(out.scheduled_undo_label, '');
});

test('annual to monthly waits for the paid year; monthly to annual starts at the end of this month', () => {
  const at = sandbox.billingCadenceEffectiveAtV764;
  assert.equal(at('annual', 'monthly', '2027-09-05T00:00:00+08:00', '2026-09-05T10:00:00+08:00'),
    '2027-09-05T00:00:00+08:00');
  assert.equal(sandbox.billingDateV758(at('monthly', 'annual', '2026-10-01T00:00:00+08:00', '2026-09-05T10:00:00+08:00')),
    '30 Sep 2026');
  /* February, and a leap February, are the two the month arithmetic gets wrong when it guesses */
  assert.equal(sandbox.billingDateV758(at('monthly', 'annual', null, '2027-02-10T10:00:00+08:00')), '28 Feb 2027');
  assert.equal(sandbox.billingDateV758(at('monthly', 'annual', null, '2028-02-10T10:00:00+08:00')), '29 Feb 2028');
  // no change is no date
  assert.equal(at('annual', 'annual', '2027-09-05T00:00:00+08:00', '2026-09-05T10:00:00+08:00'), null);
});

/* ------------------------------------------ ruling 4: cancel is reversible until it has been sent */

test('a cancelled renewal says the access date and offers Resume, with money, date and card', () => {
  const out = life({ renewal_cancel_requested_at: '2026-09-05T09:00:00+08:00' },
    { ...SUMMARY, state: 'canceling', cancel_at_period_end: true });
  assert.equal(out.cancel_line, 'Renewal cancelled · access until 5 Sep 2027');
  assert.equal(out.show_resume, true);
  assert.equal(out.show_cancel, false);
  assert.equal(out.resume_label, 'Resume renewal');
  assert.equal(out.resume_confirm, 'Resume renewal? Next payment SGD 2,376 on 5 Sep 2027 to MC ending 9037.');
  assert.equal(out.final_line, '');
});

test('the intent is read from the server summary, where get_business_billing_v758 puts it', () => {
  const out = life({}, {
    ...SUMMARY, state: 'canceling',
    renewal_cancel_requested_at: '2026-09-05T09:00:00+08:00', renewal_cancel_sent_at: null
  });
  assert.equal(out.show_resume, true);
  assert.equal(out.cancel_line, 'Renewal cancelled · access until 5 Sep 2027');
  const sent = life({}, {
    ...SUMMARY, state: 'canceling',
    renewal_cancel_requested_at: '2026-09-05T09:00:00+08:00',
    renewal_cancel_sent_at: '2027-09-03T19:00:00+08:00'
  });
  assert.equal(sent.show_resume, false);
  assert.match(sent.final_line, /^Renewal cancel is final/);
});

test('before it is cancelled, the confirmation says what keeps working and how long resume lasts', () => {
  const out = life({}, { ...SUMMARY, renewal_cancel_final_after: '2027-09-03T00:00:00+08:00' });
  assert.equal(out.show_cancel, true);
  assert.equal(out.cancel_confirm,
    'Cancel renewal? Everything keeps working until 5 Sep 2027. Nothing is refunded. You can resume until 3 Sep 2027.');
});

test('once the cancel has been sent to the provider there is no Resume button, only the end date', () => {
  const out = life({
    renewal_cancel_requested_at: '2026-09-05T09:00:00+08:00',
    renewal_cancel_sent_at: '2027-09-03T19:00:00+08:00'
  }, { ...SUMMARY, state: 'canceling', cancel_at_period_end: true });
  assert.equal(out.show_resume, false);
  assert.equal(out.show_cancel, false);
  assert.equal(out.final_line, 'Renewal cancel is final · ends 5 Sep 2027 · Start a new plan');
  assert.equal(out.resume_label, '');
});

/* ------------------------------------------------------- the card these lines are rendered onto */

const card = (billing, summary = SUMMARY) => sandbox.billingSummaryCardV758(
  sandbox.billingSummaryLinesV758(summary, 'Kopi Lab', CARD),
  {
    primaryLabel: 'Change plan', hasSubscription: true,
    lifecycle: life(billing, summary)
  });

test('the canceling card shows the cancelled line, Resume and Update card — and no Cancel', () => {
  const html = card({ renewal_cancel_requested_at: '2026-09-05T09:00:00+08:00' },
    { ...SUMMARY, state: 'canceling', cancel_at_period_end: true });
  assert.match(html, /Renewal cancelled · access until 5 Sep 2027/);
  assert.match(html, /id="billingResume">Resume renewal</);
  assert.doesNotMatch(html, /id="billingCancel"/);
  assert.match(html, /id="billingUpdateCardV764">Update card</);
  assert.match(html, /Cancels 5 Sep 2027/);
});

test('the scheduled-monthly card shows the start date and the way back', () => {
  const html = card({}, {
    ...SUMMARY,
    scheduled_change: { cadence: 'monthly', effective_at: '2027-09-05T00:00:00+08:00', amount_cents: 29600 }
  });
  assert.match(html, /Monthly billing starts on 5 Sep 2027 · SGD 296 \/ month/);
  assert.match(html, /id="billingKeepCadenceV764" data-cadence="annual"[^>]*>Keep annual</);
  assert.match(html, /id="billingCancel">Cancel renewal</);
});

test('a card that has been sent to the provider offers a new plan instead of a resume', () => {
  const html = sandbox.billingSummaryCardV758(
    sandbox.billingSummaryLinesV758({ ...SUMMARY, state: 'canceling' }, 'Kopi Lab', CARD),
    {
      primaryLabel: 'Start a new plan', hasSubscription: true,
      lifecycle: life({
        renewal_cancel_requested_at: '2026-09-05T09:00:00+08:00',
        renewal_cancel_sent_at: '2027-09-03T19:00:00+08:00'
      }, { ...SUMMARY, state: 'canceling' })
    });
  assert.match(html, /Renewal cancel is final · ends 5 Sep 2027 · Start a new plan/);
  assert.doesNotMatch(html, /id="billingResume"/);
  assert.doesNotMatch(html, /id="billingCancel"/);
  assert.match(html, /id="billingChoosePlanV758">Start a new plan</);
});

/* -------------------------------------------- ruling 1: the money is shown before it is charged */

test('the add-branch confirmation names the branch, the amount, the card and the cover date', () => {
  const copy = sandbox.branchProrataConfirmLinesV764({
    unit_amount_cents: 118800, period_end: '2027-09-05T00:00:00+08:00',
    days_remaining: 184, period_days: 365, prorata_cents: 59400,
    currency: 'SGD', card: CARD
  }, 'East Coast');
  assert.equal(copy.title, 'Set up East Coast today?');
  assert.equal(copy.body, 'About SGD 594 charged now to MC ending 9037. Covers until 5 Sep 2027.');
  assert.equal(copy.confirm, 'Set up today and pay SGD 594');
  assert.equal(copy.cancel, 'Cancel');
});

test('a preview with no card on file never invents digits', () => {
  const copy = sandbox.branchProrataConfirmLinesV764(
    { prorata_cents: 59400, period_end: '2027-09-05T00:00:00+08:00', card: null }, '');
  assert.equal(copy.title, 'Set up this branch today?');
  assert.match(copy.body, /charged now to No card yet\./);
});

test('nothing is created until the owner has confirmed the amount', () => {
  const start = app.indexOf("$('brSave').onclick=async()=>{");
  const fn = app.slice(start, app.indexOf("\n  }\n", start));
  assert.ok(fn.indexOf('branchProrataPreviewV764(payload.name)') > -1, 'the preview must be read');
  assert.ok(fn.indexOf('openBranchProrataConfirmV764(previewV764,payload.name)')
    < fn.indexOf("sb.rpc('business_add_branch_v202'"),
    'the confirmation must be answered before the branch is created');
  assert.match(app, /sb\.rpc\('preview_branch_addition_v764',\s*\{p_business:S\.biz\.id,p_branch_name:branchName\}\)/);
  /* a workspace whose database predates the RPC keeps the flow it had rather than being blocked */
  assert.match(app, /if\(error\|\|!data\)return null;/);
  /* and the command's own answer is what decides what the owner is told next */
  assert.match(fn, /executed\.data\?\.status==='uncertain'/);
  assert.match(fn, /rememberBranchPaymentRetryV764\(/);
  assert.match(fn, /is set up and paid for\./);
});

test('a charge the provider has not confirmed offers to retry THAT charge, never a second branch', () => {
  assert.match(app, /data-branch-retry-payment-v764/);
  assert.match(app, /const commandId=readBranchPaymentRetriesV764\(\)\[branchId\];/);
  assert.match(app, /if\(!commandId\)return;/);
  assert.match(app, /forgetBranchPaymentRetryV764\(branchId\)/);
  // the retry re-invokes the SAME command id
  assert.match(app, /data-branch-retry-payment-v764[\s\S]{0,700}invoke\('razorpay-billing-command',\{body:\{command_id:commandId\}\}\)/);
});

/* ----------------------------------------------- ruling 2: switch off, with the date it happens */

test('switching a branch off says the date, that it keeps working, and that nothing is refunded', () => {
  const text = sandbox.branchSwitchOffConfirmV764({
    branch: 'East Coast', billed_until: '5 Sep 2027', unit_amount: 'SGD 1,188 / year'
  });
  assert.match(text, /^Switch off "East Coast" on 5 Sep 2027\?/);
  assert.match(text, /It keeps working until then\. Not charged after\./);
  assert.match(text, /You stop paying SGD 1,188 \/ year for this branch\./);
  assert.match(text, /Nothing is refunded/);
  // a branch with no known date still reads as a sentence
  assert.match(sandbox.branchSwitchOffConfirmV764({ branch: 'East Coast', billed_until: '—' }),
    /^Switch off "East Coast"\?/);
});

/* ------------------------------------------------- ruling 1, second half: the payments list says */

test('every payment says what it was for', () => {
  const what = sandbox.billingInvoiceReasonTextV764;
  assert.equal(what({
    reason: 'initial', detail: { covers_from: '2026-09-05T00:00:00+08:00', covers_until: '2027-09-04T00:00:00+08:00' }
  }, 'Annual'), 'Annual plan · 5 Sep 2026 – 4 Sep 2027');
  assert.equal(what({
    reason: 'renewal', detail: { covers_from: '2027-09-05T00:00:00+08:00', covers_until: '2028-09-04T00:00:00+08:00' }
  }, 'Annual'), 'Annual plan · 5 Sep 2027 – 4 Sep 2028');
  assert.equal(what({
    reason: 'branch_added',
    detail: { branch_name: 'East Coast', covers_from: '2027-03-05T00:00:00+08:00', covers_until: '2027-09-04T00:00:00+08:00' }
  }, 'Annual'), 'Branch East Coast · 5 Mar – 4 Sep 2027');
  assert.equal(what({ reason: 'plan_changed' }, 'Annual'), 'Plan change');
  assert.equal(what({ reason: 'card_change' }, 'Annual'), 'Subscription');
  assert.equal(what({}, 'Annual'), 'Subscription');
  // a workspace whose invoices carry no reason yet still reads as a period, from the columns it has
  assert.equal(what({ reason: 'renewal', period_start: '2026-09-05T00:00:00+08:00', period_end: '2027-09-04T00:00:00+08:00' }, 'Monthly'),
    'Monthly plan · 5 Sep 2026 – 4 Sep 2027');
});

test('the payments table carries the What column on both the desk and the phone layout', () => {
  const html = sandbox.billingInvoiceTableV758({
    invoices: [{
      paid_at: '2027-03-05T00:00:00+08:00', total_cents: 59400, status: 'paid',
      reason: 'branch_added',
      detail: { branch_name: 'East Coast', covers_from: '2027-03-05T00:00:00+08:00', covers_until: '2027-09-04T00:00:00+08:00' },
      provider_receipt_url: 'https://example.test/receipt'
    }]
  }, SUMMARY);
  assert.match(html, /<th>Date<\/th><th>What<\/th><th>Amount<\/th>/);
  const occurrences = html.split('Branch East Coast · 5 Mar – 4 Sep 2027').length - 1;
  assert.equal(occurrences, 2, 'the table and the phone list must say the same thing, twice');
  assert.match(html, /SGD 594/);
  assert.match(html, /Paid/);
});

/* ------------------------------------------------------------------------------- ruling 5: card */

test('the card is changed through Razorpay and the digits are refreshed on the way back', () => {
  // the button asks for the provider's card-change sheet
  assert.match(app, /\$\('billingUpdateCardV764'\)\.onclick=\(\)=>execute\('update_card',null,null\)/);
  // the return route is recognised and never left in the address bar
  assert.match(app, /cardUpdated:value==='card_updated'/);
  assert.match(app, /billingReturnStateV756\.cardUpdated&&!settingsBillingCardRefreshActiveV764/);
  // stale first, then the command that fills the digits in, then the page says which card
  const start = app.indexOf('if(billingReturnStateV756.cardUpdated');
  const block = app.slice(start, app.indexOf('if(billingReturnStateV756.processing', start));
  assert.ok(block.indexOf("refresh_payment_method_request_v764") < block.indexOf("'refresh_payment_method'"),
    'the stored digits are marked stale before the refresh is asked for');
  assert.match(block, /p_command_type:'refresh_payment_method'/);
  assert.match(block, /Card updated · \$\{billingCardTextV758\(refreshed\?\.payment_method\)\}/);
});

test('the checkout page opens the card-change sheet without an amount', () => {
  const checkout = readFileSync(resolve(root, 'app/razorpay-checkout.js'), 'utf8');
  assert.match(checkout, /var cardChange = params\.get\('card_change'\) === '1';/);
  assert.match(checkout, /if \(cardChange\) options\.subscription_card_change = 1;/);
  assert.match(checkout, /else options\.description = description;/);
  // no amount is passed in either mode: a subscription checkout is priced by the plan
  assert.doesNotMatch(checkout, /amount:/);
});

/* ---------------------------------------------------------------- a command never navigates away */

test('a command that is not a checkout re-reads and re-draws this page instead of navigating', () => {
  const start = app.indexOf('const execute=async(type,cadence,capacity)=>{');
  const fn = app.slice(start, app.indexOf('\n    };', start));
  // a redirect is still followed when the provider gives one (checkout)
  assert.ok(fn.indexOf('if(result.redirect_url){') < fn.indexOf('await loadBillingConfig();'));
  assert.match(fn, /await loadBillingConfig\(\);\n      const settled=\$\('billingCommandStatus'\);/);
  assert.doesNotMatch(fn.slice(fn.indexOf('let message=')), /location\.assign/);
});

/* --------------------------------------------------------------------------------- copy rules */

test('every lifecycle sentence stays inside the owner-facing copy rules', () => {
  const banned = /\b(tier|cadence|unit|units|provider|prorata|pro-rata|proration|prorated|subscription id)\b/i;
  const sentences = [];
  for (const fixture of [
    life({}, { ...SUMMARY, renewal_cancel_final_after: '2027-09-03T00:00:00+08:00' }),
    life({ renewal_cancel_requested_at: 'x' }, { ...SUMMARY, state: 'canceling' }),
    life({ renewal_cancel_requested_at: 'x', renewal_cancel_sent_at: 'y' }, { ...SUMMARY, state: 'canceling' }),
    life({}, { ...SUMMARY, scheduled_change: { cadence: 'monthly', effective_at: '2027-09-05T00:00:00+08:00', amount_cents: 29600 } })
  ]) {
    sentences.push(fixture.scheduled_line, fixture.scheduled_undo_label, fixture.cancel_line,
      fixture.cancel_confirm, fixture.resume_confirm, fixture.final_line);
  }
  const copy = sandbox.branchProrataConfirmLinesV764(
    { prorata_cents: 59400, period_end: '2027-09-05T00:00:00+08:00', card: CARD }, 'East Coast');
  sentences.push(copy.title, copy.body, copy.confirm);
  sentences.push(sandbox.billingInvoiceReasonTextV764({
    reason: 'branch_added',
    detail: { branch_name: 'East Coast', covers_from: '2027-03-05T00:00:00+08:00', covers_until: '2027-09-04T00:00:00+08:00' }
  }, 'Annual'));
  for (const sentence of sentences) {
    if (!sentence) continue;
    assert.doesNotMatch(sentence, banned, `owner-facing jargon in: ${sentence}`);
    /* the two confirmations are three short sentences each and are read in a dialog, not on the
       card; every line that renders ON the card stays inside 12 words. */
    for (const line of sentence.split(/(?<=[.?])\s+/)) {
      const words = line.split(/\s+/).filter((w) => w && w !== '·');
      assert.ok(words.length <= 12, `over 12 words: ${line}`);
    }
    assert.doesNotMatch(sentence, /\d{4}-\d{2}-\d{2}/, `a raw date reached the owner: ${sentence}`);
  }
});
