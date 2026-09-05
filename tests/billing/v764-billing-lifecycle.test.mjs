/* nestly_v764 — the subscription lifecycle paths Razorpay does not deliver as events.

   Every test here EXECUTES the shared lifecycle module against PostgREST-shaped stubs. The three
   things a source grep would have let through, and that these assertions catch:
   - the update charge (a branch added mid-period) being PATCHed but never mirrored, so the branch
     never switches on and the payments history has no row for money that left the card;
   - remaining_count missing or carrying the CURRENT cadence's count, which Razorpay rejects
     outright for a cross-period plan change;
   - an owner's "Cancel renewal" reaching Razorpay, which cannot be undone and would make the
     Resume button we promise them a lie.

   The edge wiring that cannot be executed in Node (Deno.serve) is asserted against the command
   source as extracted BRANCH BLOCKS, never as loose substrings of a 700-line file. */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import {
  branchIdentityForCommand,
  captureUpdateCharge,
  commandLooksSystemOriginated,
  healMissingUpdateCharges,
  normalizeDueRenewalCancels,
  refreshPaymentMethodFromProvider,
  remainingCountForCadence,
  REMAINING_COUNT_ANNUAL,
  REMAINING_COUNT_MONTHLY,
  remainingCountFromCapError,
  runDueRenewalCancels,
  unmirroredPaidInvoices,
  UPDATE_CHARGE_POLL_DELAYS_MS,
} from '../../supabase/functions/_shared/razorpay-billing-lifecycle.ts';

const root = new URL('../../', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const commandSource = await read('supabase/functions/razorpay-billing-command/index.ts');
const returnSource = await read('supabase/functions/razorpay-billing-return/index.ts');
const reconcileSource = await read('supabase/functions/razorpay-billing-reconcile/index.ts');

const BUSINESS = '11111111-2222-4333-8444-555555555555';
const BRANCH = '99999999-8888-4777-8666-555555555555';
const SUB = 'sub_v764';

function subscription(overrides = {}) {
  return {
    id: SUB,
    entity: 'subscription',
    plan_id: 'plan_annual',
    status: 'active',
    quantity: 2,
    paid_count: 1,
    created_at: 1788000000,
    current_start: 1788000000,
    current_end: 1819536000,
    notes: { business_id: BUSINESS, command_id: 'cmd_first' },
    ...overrides,
  };
}

function invoice(overrides = {}) {
  return {
    id: 'inv_update_1',
    payment_id: 'pay_update_1',
    status: 'paid',
    amount: 118800,
    currency: 'SGD',
    paid_at: 1790000000,
    billing_start: 1788000000,
    billing_end: 1819536000,
    ...overrides,
  };
}

function payment(overrides = {}) {
  return {
    id: 'pay_update_1',
    amount: 118800,
    currency: 'SGD',
    status: 'captured',
    method: 'card',
    card: { last4: '9037', network: 'MasterCard' },
    created_at: 1790000000,
    notes: { origin: 'razorpay' },
    ...overrides,
  };
}

/* A PostgREST-shaped stub: every filter returns the same lazy builder and awaiting it resolves
   {data,error}. supabase-js builders are thenables, not Promises — a stub that returned a plain
   object would let a missing await through. */
function table(rows, { error = null } = {}) {
  const state = { filters: [] };
  const builder = {
    state,
    select(columns) {
      state.columns = columns;
      return builder;
    },
    eq(column, value) {
      state.filters.push(['eq', column, value]);
      return builder;
    },
    in(column, values) {
      state.filters.push(['in', column, values]);
      return builder;
    },
    is(column, value) {
      state.filters.push(['is', column, value]);
      return builder;
    },
    not(column, operator, value) {
      state.filters.push(['not', column, operator, value]);
      return builder;
    },
    order(column, options) {
      state.order = { column, ...options };
      return builder;
    },
    limit(count) {
      state.limit = count;
      return builder;
    },
    maybeSingle() {
      return Promise.resolve({ data: error ? null : rows[0] ?? null, error });
    },
    then(resolve, reject) {
      return Promise.resolve({ data: error ? null : rows, error }).then(resolve, reject);
    },
  };
  return builder;
}

function adminStub({ tables = {}, rpcAnswers = {} } = {}) {
  const calls = [];
  const queries = [];
  return {
    calls,
    queries,
    from(name) {
      const builder = tables[name] ? tables[name]() : table([]);
      queries.push({ table: name, state: builder.state });
      return builder;
    },
    rpc(name, args) {
      calls.push({ name, args });
      if (Object.prototype.hasOwnProperty.call(rpcAnswers, name)) {
        return Promise.resolve(rpcAnswers[name]);
      }
      if (name === 'ingest_billing_event_v755') {
        return Promise.resolve({ data: { duplicate: false, status: 'accepted' }, error: null });
      }
      if (name === 'apply_razorpay_billing_event_v755') {
        return Promise.resolve({ data: { status: 'processed' }, error: null });
      }
      return Promise.resolve({ data: null, error: null });
    },
  };
}

function razorpayStub({ pages = [[invoice()]], sub = subscription(), payments = {} } = {}) {
  const seen = { invoiceLists: [], payments: [], cancels: [], subscriptions: [] };
  let page = 0;
  return {
    seen,
    getSubscription(id) {
      seen.subscriptions.push(id);
      return Promise.resolve(sub);
    },
    getSubscriptionInvoices(id, query) {
      seen.invoiceLists.push({ id, query });
      const items = pages[Math.min(page, pages.length - 1)];
      page += 1;
      return Promise.resolve({ items });
    },
    getPayment(id, options) {
      seen.payments.push({ id, options });
      return Promise.resolve(payments[id] || payment({ id }));
    },
    cancelSubscription(id, cycleEnd) {
      seen.cancels.push({ id, cycleEnd });
      return Promise.resolve({ id });
    },
  };
}

const noSleep = () => Promise.resolve();

/* ---------------------------------------------------------------- cadence (ruling 3) */

test('remaining_count is the TARGET cadence forever, and Razorpay is given one', () => {
  assert.equal(remainingCountForCadence('monthly'), REMAINING_COUNT_MONTHLY);
  assert.equal(remainingCountForCadence('annual'), REMAINING_COUNT_ANNUAL);
  /* v769: 99 years, not 100 — Razorpay's cap sits below the plain forever once a cycle has
     been used (observed cap 1198 on a change to monthly). */
  assert.equal(REMAINING_COUNT_MONTHLY, 1188);
  assert.equal(REMAINING_COUNT_ANNUAL, 99);
  // Anything unrecognised bills monthly-shaped, which is the safe (larger) cycle count.
  assert.equal(remainingCountForCadence(''), REMAINING_COUNT_MONTHLY);
});

test('change_cadence PATCHes remaining_count for the target and schedules at cycle end', () => {
  /* v769: the PATCH body is built once (patchBody) so the capped retry sends the same request. */
  const block = commandSource.slice(
    commandSource.indexOf('const patchBody = {'),
    commandSource.indexOf('const verified = await razorpay.getSubscription('),
  );
  assert.match(block, /schedule_change_at: scheduleChangeAt/);
  assert.match(block, /updated = await razorpay\.updateSubscription\(subscriptionId, patchBody\)/);
  assert.match(
    block,
    /commandType === 'change_cadence'\s*\n?\s*\? \{ remaining_count: remainingCountForCadence\(cadence\) \}/,
  );
  // A cadence change is always cycle_end — it must never rebase a paid period.
  assert.match(
    commandSource,
    /commandType === 'change_cadence'\)\s*\{\s*scheduleChangeAt = 'cycle_end';/,
  );
  // The effective date and price are recorded so the page can say them out loud.
  assert.match(commandSource, /record_billing_schedule_v764/);
  assert.match(commandSource, /p_kind: 'cadence'/);
  assert.match(commandSource, /p_target_cadence: cadence/);
  assert.match(commandSource, /p_target_plan_id: planId/);
  assert.match(commandSource, /verified\.change_scheduled_at \|\| verified\.current_end/);
  assert.match(
    commandSource,
    /p_amount_cents: Number\(data\.base_amount_cents \|\| 0\) \* planUnits/,
  );
});

test('asking for the plan already in force withdraws the schedule instead of PATCHing again', () => {
  const block = commandSource.slice(
    commandSource.indexOf("if (commandType === 'change_cadence' && String(current.plan_id) === planId)"),
    commandSource.indexOf('const patchBody = {'),
  );
  assert.ok(block.length > 0, 'undo branch missing');
  assert.match(block, /cancelScheduledChanges\(subscriptionId\)/);
  assert.match(block, /clear_billing_schedule_v764/);
  assert.doesNotMatch(block, /updateSubscription/);
});

/* ------------------------------------------------- update charge capture (ruling 1) */

test('a paid update invoice we do not hold is synthesized as subscription.charged', async () => {
  const admin = adminStub({ tables: { billing_provider_invoices: () => table([]) } });
  const razorpay = razorpayStub();
  const capture = await captureUpdateCharge({
    admin,
    razorpay,
    subscriptionId: SUB,
    businessId: BUSINESS,
    livemode: false,
    subscription: subscription(),
    extraNotes: { reason: 'branch_added', branch_id: BRANCH, branch_name: 'East Coast' },
    sleep: noSleep,
    now: () => new Date('2026-09-05T00:00:00.000Z'),
  });
  assert.equal(capture.invoices.length, 1);
  assert.equal(capture.polls, 1, 'a settled charge must not be polled for twice');
  assert.deepEqual(capture.invoices[0], {
    invoice_id: 'inv_update_1',
    payment_id: 'pay_update_1',
    amount_cents: 118800,
    currency: 'SGD',
    paid_at: new Date(1790000000 * 1000).toISOString(),
  });

  const ingest = admin.calls.find((call) => call.name === 'ingest_billing_event_v755');
  const apply = admin.calls.find((call) => call.name === 'apply_razorpay_billing_event_v755');
  assert.ok(ingest && apply, 'the charge must go through the EXISTING pipeline, not a new writer');
  assert.equal(ingest.args.p_event_id, `update_${SUB}_pay_update_1_charged`);
  assert.equal(apply.args.p_event_id, ingest.args.p_event_id);
  assert.equal(ingest.args.p_event_type, 'subscription.charged');
  assert.equal(ingest.args.p_object_id, SUB);
  assert.equal(ingest.args.p_livemode, false);
  assert.match(ingest.args.p_payload_sha256, /^[0-9a-f]{64}$/);

  const entity = ingest.args.p_payload.payload;
  assert.equal(entity.payment.entity.invoice_id, 'inv_update_1');
  // The subscription's own notes stay authoritative for the business mapping.
  assert.equal(entity.payment.entity.notes.business_id, BUSINESS);
  assert.deepEqual(
    {
      reason: entity.payment.entity.notes.reason,
      branch_id: entity.payment.entity.notes.branch_id,
      branch_name: entity.payment.entity.notes.branch_name,
      covers_from: entity.payment.entity.notes.covers_from,
      covers_until: entity.payment.entity.notes.covers_until,
    },
    {
      reason: 'branch_added',
      branch_id: BRANCH,
      branch_name: 'East Coast',
      covers_from: new Date(1788000000 * 1000).toISOString(),
      covers_until: new Date(1819536000 * 1000).toISOString(),
    },
  );
  // The cycle the invoice paid for, not the newest one.
  assert.equal(entity.subscription.entity.current_start, 1788000000);
  assert.equal(entity.subscription.entity.current_end, 1819536000);
});

test('an invoice already mirrored is never charged a second time', async () => {
  const admin = adminStub({
    tables: {
      billing_provider_invoices: () => table([{ provider_payment_intent_id: 'pay_update_1' }]),
    },
  });
  const razorpay = razorpayStub();
  const capture = await captureUpdateCharge({
    admin,
    razorpay,
    subscriptionId: SUB,
    businessId: BUSINESS,
    livemode: true,
    subscription: subscription(),
    sleep: noSleep,
  });
  assert.equal(capture.invoices.length, 0);
  assert.equal(capture.polls, UPDATE_CHARGE_POLL_DELAYS_MS.length);
  assert.equal(admin.calls.length, 0, 'nothing may be ingested for a charge we already hold');
});

test('an unreadable mirror never double-charges: the lookup fails closed', async () => {
  await assert.rejects(
    unmirroredPaidInvoices({
      admin: adminStub({
        tables: {
          billing_provider_invoices: () => table([], { error: { code: '42501' } }),
        },
      }),
      businessId: BUSINESS,
      livemode: false,
      invoices: [invoice()],
    }),
    /mirrored invoice lookup failed/,
  );
});

test('an unsettled card is polled twice and then reported uncertain, never failed', async () => {
  const admin = adminStub({ tables: { billing_provider_invoices: () => table([]) } });
  const razorpay = razorpayStub({ pages: [[invoice({ status: 'issued', payment_id: null })], []] });
  const capture = await captureUpdateCharge({
    admin,
    razorpay,
    subscriptionId: SUB,
    businessId: BUSINESS,
    livemode: false,
    subscription: subscription(),
    sleep: noSleep,
  });
  assert.equal(capture.invoices.length, 0);
  assert.equal(capture.polls, 2);
  assert.deepEqual(UPDATE_CHARGE_POLL_DELAYS_MS, [0, 3000]);

  // …and the command completes 'uncertain' with the named code, leaving the branch off.
  const pending = commandSource.slice(
    commandSource.indexOf('if (updateChargePending) {'),
    commandSource.indexOf('if (providerConfirmationPending) {'),
  );
  assert.match(pending, /p_status: 'uncertain'/);
  assert.match(pending, /p_error_code: 'provider_update_charge_pending'/);
  assert.match(pending, /p_redirect_url: null/);
  assert.match(pending, /billingCorsJson\(req, 202,/);
});

test('the second look finds a charge that settled a moment late', async () => {
  const admin = adminStub({ tables: { billing_provider_invoices: () => table([]) } });
  const razorpay = razorpayStub({ pages: [[], [invoice()]] });
  const capture = await captureUpdateCharge({
    admin,
    razorpay,
    subscriptionId: SUB,
    businessId: BUSINESS,
    livemode: false,
    subscription: subscription(),
    sleep: noSleep,
  });
  assert.equal(capture.polls, 2);
  assert.equal(capture.invoices.length, 1);
});

test('the branch a charge pays for is named from the command, else the pending branch', async () => {
  const named = await branchIdentityForCommand({
    admin: adminStub({
      tables: { branches: () => table([{ id: BRANCH, name: 'East Coast' }]) },
    }),
    businessId: BUSINESS,
    requestedBranchId: BRANCH,
  });
  assert.deepEqual(named, { branch_id: BRANCH, branch_name: 'East Coast' });

  const derived = await branchIdentityForCommand({
    admin: adminStub({
      tables: { branches: () => table([{ id: BRANCH, name: 'Tampines' }]) },
    }),
    businessId: BUSINESS,
    requestedBranchId: null,
  });
  assert.deepEqual(derived, { branch_id: BRANCH, branch_name: 'Tampines' });

  // A branch we cannot name still lets the charge be mirrored — identity is a label, not a gate.
  const missing = await branchIdentityForCommand({
    admin: adminStub({ tables: { branches: () => table([]) } }),
    businessId: BUSINESS,
    requestedBranchId: null,
  });
  assert.equal(missing, null);
});

test('the update-charge capture is wired into the "now" path for branch adds and capacity increases', () => {
  /* v775: a capacity increase is charged today too, so the same capture runs for it with its
     own reason and the from/to sizes. */
  const wiring = commandSource.slice(
    commandSource.indexOf("(commandType === 'change_branches' || commandType === 'change_capacity') &&"),
    commandSource.indexOf("} else if (!providerResolved && commandType === 'cancel_at_period_end')"),
  );
  assert.ok(wiring.length > 0, 'update-charge capture not wired');
  assert.match(wiring, /captureUpdateCharge\(\{/);
  assert.match(wiring, /reason: 'branch_added'/);
  assert.match(wiring, /reason: 'capacity_increase'/);
  assert.match(wiring, /capacity_from: String\(priorCapacityForNotes/);
  assert.match(wiring, /capacity_to: String\(data\.requested_customer_capacity/);
  assert.match(wiring, /updateChargePending = capture\.invoices\.length === 0/);
  // The command function must never write billing truth itself.
  assert.doesNotMatch(commandSource, /apply_razorpay_billing_event_v755|ingest_billing_event_v755/);
});

/* --------------------------------------------------- cancel renewal (ruling 4) */

test('an owner-originated cancel never reaches Razorpay', () => {
  const block = commandSource.slice(
    commandSource.indexOf("} else if (!providerResolved && commandType === 'cancel_at_period_end')"),
    commandSource.indexOf("} else if (!providerResolved && commandType === 'update_card')"),
  );
  assert.ok(block.length > 0, 'cancel branch missing');
  // The provider call is reachable ONLY under the system-originated gate.
  const gate = block.indexOf('if (!systemOriginated) {');
  const call = block.indexOf('razorpay.cancelSubscription(subscriptionId, 1)');
  assert.ok(gate > 0 && call > gate, 'cancel must sit behind the system gate');
  assert.match(block, /commandLooksSystemOriginated\(commandRowData\)/);
  assert.match(block, /listDueRenewalCancels\(admin\)/);
  assert.match(block, /mark_renewal_cancel_sent_v764/);
  // Marking happens after the provider call, never before.
  assert.ok(block.indexOf('mark_renewal_cancel_sent_v764') > call);
});

test('system origination is recognised from either signal', () => {
  assert.equal(commandLooksSystemOriginated({ requested_by: null }), true);
  assert.equal(commandLooksSystemOriginated({ system_initiated: true }), true);
  assert.equal(commandLooksSystemOriginated({ actor_kind: 'system' }), true);
  assert.equal(commandLooksSystemOriginated({ origin: 'SYSTEM' }), true);
  assert.equal(
    commandLooksSystemOriginated({ requested_by: '00000000-0000-4000-8000-000000000000' }),
    false,
  );
  assert.equal(commandLooksSystemOriginated(null), false);
});

test('the reconcile sweep cancels every due intent and marks only what it sent', async () => {
  const admin = adminStub({
    rpcAnswers: {
      list_due_renewal_cancels_v764: {
        data: [
          { business_id: BUSINESS, provider_subscription_id: SUB },
          { business_id: 'b2', provider_subscription_id: 'sub_two', branch_id: null },
          { business_id: 'b3', subscription_id: '' },
        ],
        error: null,
      },
      mark_renewal_cancel_sent_v764: { data: null, error: null },
    },
  });
  const razorpay = razorpayStub();
  const counts = await runDueRenewalCancels({ admin, razorpay });
  assert.deepEqual(counts, { attempted: 2, sent: 2, failed: 0 });
  assert.deepEqual(razorpay.seen.cancels, [
    { id: SUB, cycleEnd: 1 },
    { id: 'sub_two', cycleEnd: 1 },
  ]);
  const marks = admin.calls.filter((call) => call.name === 'mark_renewal_cancel_sent_v764');
  assert.deepEqual(marks.map((call) => call.args.p_business), [BUSINESS, 'b2']);
});

test('a provider failure is counted and left unmarked, so tomorrow retries it', async () => {
  const admin = adminStub({
    rpcAnswers: {
      list_due_renewal_cancels_v764: {
        data: [{ business_id: BUSINESS, provider_subscription_id: SUB, branch_id: null }],
        error: null,
      },
    },
  });
  const razorpay = {
    ...razorpayStub(),
    cancelSubscription: () => Promise.reject(new Error('razorpay 500')),
  };
  const counts = await runDueRenewalCancels({ admin, razorpay });
  assert.deepEqual(counts, { attempted: 1, sent: 0, failed: 1 });
  assert.equal(
    admin.calls.filter((call) => call.name === 'mark_renewal_cancel_sent_v764').length,
    0,
  );
});

test('the due list is read defensively', () => {
  assert.deepEqual(normalizeDueRenewalCancels(null), []);
  assert.deepEqual(
    normalizeDueRenewalCancels({ business_id: BUSINESS, subscription_id: SUB }),
    [{ business_id: BUSINESS, provider_subscription_id: SUB, branch_id: null }],
  );
});

/* --------------------------------------------- card change + refresh (ruling 5) */

test('update_card redirects to the checkout page in card-change mode', () => {
  const block = commandSource.slice(
    commandSource.indexOf("} else if (!providerResolved && commandType === 'update_card')"),
    commandSource.indexOf("} else if (!providerResolved && commandType === 'refresh_payment_method')"),
  );
  assert.ok(block.length > 0, 'update_card branch missing');
  assert.match(block, /cardChange: true/);
  // No provider mutation: the sheet does the work.
  assert.doesNotMatch(block, /razorpay\.\w+\(/);
  assert.match(commandSource, /\.\.\.\(cardChange \? \{ card_change: '1' \} : \{\}\)/);
  assert.match(commandSource, /cardChange \? '&mode=card' : ''/);
});

test('the card-change return routes to card_updated and still checks the signature', () => {
  assert.match(returnSource, /billing=card_updated/);
  assert.match(returnSource, /String\(fields\.mode \|\| ''\) === 'card'/);
  // The signature over payment_id|subscription_id is unchanged and unconditional.
  assert.match(returnSource, /verifyCheckoutSignature\(/);
  assert.match(returnSource, /if \(!verified\) \{\s*\n\s*return seeOther\(`\$\{target\.cancel\}&reason=signature`\);/);
  // A card change runs under a NEW command id, so the notes comparison must not reject it.
  assert.match(returnSource, /!cardChange && commandId && UUID\.test\(commandId\)/);
  // v774: no DIRECT writes; the paid-invoice synthesis goes through the shared recovery pipeline.
  assert.doesNotMatch(returnSource, /\.rpc\(|\.from\(|\.insert\(|\.update\(/ /* v774: the admin client may be handed to the recovery synthesis, never used directly */);
});

test('refresh_payment_method takes the latest settled payment and writes only the label', async () => {
  const admin = adminStub();
  const razorpay = razorpayStub({
    pages: [[
      invoice({ id: 'inv_old', payment_id: 'pay_old', paid_at: 1700000000 }),
      invoice({ id: 'inv_new', payment_id: 'pay_new', paid_at: 1800000000 }),
      invoice({ id: 'inv_unpaid', payment_id: null, status: 'issued', paid_at: 1900000000 }),
    ]],
    payments: {
      pay_new: payment({ id: 'pay_new', card: { last4: '4242', network: 'Visa' } }),
    },
  });
  const result = await refreshPaymentMethodFromProvider({
    admin,
    razorpay,
    businessId: BUSINESS,
    subscriptionId: SUB,
  });
  assert.deepEqual(razorpay.seen.payments, [{ id: 'pay_new', options: { expandCard: true } }]);
  assert.deepEqual(result, {
    refreshed: true,
    payment_id: 'pay_new',
    kind: 'card',
    brand: 'Visa',
    last4: '4242',
  });
  const write = admin.calls.find((call) => call.name === 'set_billing_payment_method_v758');
  assert.deepEqual(write.args, {
    p_business: BUSINESS,
    p_payment_id: 'pay_new',
    p_kind: 'card',
    p_brand: 'Visa',
    p_last4: '4242',
  });
  // No payment truth is written by this path.
  assert.equal(
    admin.calls.some((call) => call.name.includes('billing_event')),
    false,
  );
});

test('a subscription with nothing settled leaves the stored card alone', async () => {
  const admin = adminStub();
  const razorpay = razorpayStub({ pages: [[invoice({ status: 'issued', payment_id: null })]] });
  const result = await refreshPaymentMethodFromProvider({
    admin,
    razorpay,
    businessId: BUSINESS,
    subscriptionId: SUB,
  });
  assert.equal(result.refreshed, false);
  assert.equal(admin.calls.length, 0);
});

/* ------------------------------------------------------- reconcile wiring + heal */

test('reconcile heals a known subscription whose paid invoice was never mirrored', async () => {
  const admin = adminStub({
    tables: {
      billing_provider_subscriptions: () =>
        table([{ business_id: BUSINESS, provider_subscription_id: SUB }]),
      billing_provider_invoices: () => table([]),
    },
  });
  const razorpay = razorpayStub();
  const counts = await healMissingUpdateCharges({
    admin,
    razorpay,
    scope: { livemode: false, businessIds: [BUSINESS] },
  });
  assert.deepEqual(counts, { attempted: 1, recovered: 1, failed: 0 });
  const ingest = admin.calls.find((call) => call.name === 'ingest_billing_event_v755');
  assert.equal(ingest.args.p_event_id, `update_${SUB}_pay_update_1_charged`);
  /* v767: the mirror tables have no `provider` column. A filter on it made PostgREST reject the
     read and the heal counted itself failed on every real run (observed 2026-09-05: East Wing
     charged at Razorpay, never mirrored, reconcile "attempted 0"). */
  const lookup = admin.queries.find((query) => query.table === 'billing_provider_subscriptions');
  assert.ok(lookup, 'the heal reads billing_provider_subscriptions');
  const columns = lookup.state.filters.map(([, column]) => column);
  assert.ok(!columns.includes('provider'), `heal must not filter on a provider column: ${columns}`);
  assert.deepEqual(columns.sort(), ['business_id', 'livemode']);
});

test('the heal is a no-op with no tenants in scope and never throws on a bad row', async () => {
  assert.deepEqual(
    await healMissingUpdateCharges({
      admin: adminStub(),
      razorpay: razorpayStub(),
      scope: { livemode: false, businessIds: [] },
    }),
    { attempted: 0, recovered: 0, failed: 0 },
  );
  const failing = await healMissingUpdateCharges({
    admin: adminStub({
      tables: {
        billing_provider_subscriptions: () =>
          table([{ business_id: BUSINESS, provider_subscription_id: SUB }]),
        billing_provider_invoices: () => table([], { error: { code: '42501' } }),
      },
    }),
    razorpay: razorpayStub(),
    scope: { livemode: false, businessIds: [BUSINESS] },
  });
  assert.deepEqual(failing, { attempted: 1, recovered: 0, failed: 1 });
});

test('the reconciliation run reports both new counters in its summary', () => {
  assert.match(reconcileSource, /const updateCharges: UpdateChargeHealCounts = await healMissingUpdateCharges\(/);
  assert.match(reconcileSource, /const renewalCancels: RenewalCancelCounts = await runDueRenewalCancels\(/);
  assert.match(reconcileSource, /update_charges: updateCharges,/);
  assert.match(reconcileSource, /renewal_cancels: renewalCancels,/);
  // Both run AFTER the four reconciliation streams, so they only ever see settled projections.
  const streamsEnd = reconcileSource.indexOf('cursor.provider_invoices_complete = providerInvoicePage.complete;');
  assert.ok(reconcileSource.indexOf('await runDueRenewalCancels(') > streamsEnd);
  assert.ok(reconcileSource.indexOf('await healMissingUpdateCharges(') > streamsEnd);
});

test('in-place commands hand back no redirect', () => {
  const list = commandSource.slice(
    commandSource.indexOf('const NO_REDIRECT_COMMAND_TYPES = ['),
    commandSource.indexOf('function returnOrigin()'),
  );
  for (const type of [
    'change_branches',
    'change_cadence',
    'change_capacity',
    'cancel_at_period_end',
    'resume',
    'refresh_payment_method',
  ]) {
    assert.ok(list.includes(`'${type}'`), `${type} must not navigate the owner away`);
  }
  assert.ok(!list.includes("'update_card'"), 'update_card must carry the Razorpay sheet URL');
  assert.match(
    commandSource,
    /redirectUrl = NO_REDIRECT_COMMAND_TYPES\.includes\(commandType\)\s*\n?\s*\? null/,
  );
});


test('the due renewal-cancel list unwraps the {status, due:[...]} envelope the v765 RPC returns', async () => {
  const rows = normalizeDueRenewalCancels({ status: 'ok', due: [
    { business_id: 'b1', provider_subscription_id: 'sub_1' },
    { business_id: '', provider_subscription_id: 'sub_2' },
  ] });
  assert.deepEqual(rows, [{ business_id: 'b1', provider_subscription_id: 'sub_1', branch_id: null }]);
  assert.deepEqual(normalizeDueRenewalCancels([{ business_id: 'b2', subscription_id: 'sub_3' }]),
    [{ business_id: 'b2', provider_subscription_id: 'sub_3', branch_id: null }]);
});

/* ------------------------------------------------------- v769 remaining_count cap */

test('the remaining_count cap Razorpay names in its rejection is read back exactly', () => {
  assert.equal(
    remainingCountFromCapError(
      'Exceeds the maximum remaining_count (1198) allowed for the given period and interval (PATCH /subscriptions/sub_x)',
    ),
    1198,
  );
  assert.equal(remainingCountFromCapError('remaining_count should be present to update to new plan'), null);
  assert.equal(remainingCountFromCapError('maximum remaining_count (0) allowed'), null);
  assert.equal(remainingCountFromCapError(null), null);
});

test('the command retries the PATCH with the capped remaining_count and does not retry anything else', () => {
  assert.match(commandSource, /remainingCountFromCapError\(error\.message\)/);
  assert.match(commandSource, /remaining_count: cap,/);
  assert.match(commandSource, /if \(cap === null\) throw error;/);
});

/* ------------------------------------------------------- v774 immediate activation */

test('the return hop mirrors the paid invoice itself, after the signature check and never for a card change', () => {
  const verifiedAt = returnSource.indexOf('if (!verified) {');
  const synthesisAt = returnSource.indexOf('recoverProviderSubscription({');
  assert.ok(verifiedAt > 0 && synthesisAt > verifiedAt, 'synthesis must follow the signature check');
  /* nestly_v790: the hop also needs the account whose secret verified the redirect */
  assert.match(returnSource, /if \(subscriptionId && !cardChange && account\) \{/);
  assert.match(returnSource, /admin: billingAdminClient\(\)/);
  assert.match(returnSource, /livemode: account\.livemode,/);
  /* Best effort: a synthesis failure must not change the route. */
  assert.match(returnSource, /return_hop_synthesis_failed/);
  assert.ok(returnSource.indexOf('return seeOther(target.success);') > synthesisAt);
});
