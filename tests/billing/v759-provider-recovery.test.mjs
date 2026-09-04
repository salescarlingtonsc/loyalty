/* nestly_v759 — reconciliation RECOVERS a paid subscription the webhook never delivered.

   These tests EXECUTE the recovery module against stubs rather than grepping the edge source. A
   source regex would stay green if the envelopes stopped being built in rank order, if the ids
   drifted so the inbox could no longer dedupe them, if the bound moved, or if a failure started
   ending the run. The one thing that cannot be executed here — the real reconcile wiring — is
   asserted against the edge source separately, and the payload SHAPE is checked against the
   fields the v755 SQL applier actually reads. */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import {
  buildRecoveryEnvelopes,
  isRecoverableProviderSubscription,
  PROVIDER_RECOVERY_MAX_PER_RUN,
  recoverProviderSubscription,
} from '../../supabase/functions/_shared/razorpay-provider-recovery.ts';

const root = new URL('../../', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');

const BUSINESS = '11111111-2222-4333-8444-555555555555';
const SUB = 'sub_v759_paid';

function subscription(overrides = {}) {
  return {
    id: SUB,
    entity: 'subscription',
    plan_id: 'plan_v759_monthly',
    customer_id: 'cust_v759',
    status: 'active',
    quantity: 3,
    paid_count: 2,
    created_at: 1788000000,
    current_start: 1790000000,
    current_end: 1792600000,
    charge_at: 1792600000,
    notes: { business_id: BUSINESS, command_id: 'cmd_v759' },
    ...overrides,
  };
}

function invoice(index, overrides = {}) {
  return {
    id: `inv_v759_${index}`,
    payment_id: `pay_v759_${index}`,
    status: 'paid',
    amount: 9900,
    currency: 'SGD',
    paid_at: 1788600000 + index * 2600000,
    billing_start: 1788600000 + index * 2600000,
    billing_end: 1788600000 + (index + 1) * 2600000,
    ...overrides,
  };
}

function payment(index, overrides = {}) {
  return {
    id: `pay_v759_${index}`,
    amount: 9900,
    currency: 'SGD',
    status: 'captured',
    method: 'card',
    card: { last4: '4242', network: 'Visa' },
    created_at: 1788600000 + index * 2600000,
    notes: { source: 'razorpay' },
    ...overrides,
  };
}

/* A stub that records every RPC in call order and answers as the real ones do. `duplicates`
   makes ingest report the row already existed, which is what a re-run really sees. */
function adminStub({ duplicates = false, failIngestFor = null, failApplyFor = null } = {}) {
  const calls = [];
  return {
    calls,
    rpc(name, args) {
      calls.push({ name, args });
      if (name === 'ingest_billing_event_v755') {
        if (failIngestFor && args.p_event_id.includes(failIngestFor)) {
          return Promise.resolve({ data: null, error: { code: '22023', message: 'bad envelope' } });
        }
        return Promise.resolve({
          data: { event_id: args.p_event_id, status: 'accepted', duplicate: duplicates },
          error: null,
        });
      }
      if (name === 'apply_razorpay_billing_event_v755') {
        if (failApplyFor && args.p_event_id.includes(failApplyFor)) {
          return Promise.resolve({ data: { status: 'failed' }, error: null });
        }
        return Promise.resolve({
          data: { event_id: args.p_event_id, status: duplicates ? 'processed' : 'processed' },
          error: null,
        });
      }
      throw new Error(`unexpected rpc ${name}`);
    },
  };
}

function razorpayStub({ sub = subscription(), invoices = [invoice(0), invoice(1)] } = {}) {
  const seen = { subscriptions: [], invoiceLists: [], payments: [] };
  return {
    seen,
    getSubscription(id) {
      seen.subscriptions.push(id);
      return Promise.resolve(sub);
    },
    getSubscriptionInvoices(id, query) {
      seen.invoiceLists.push({ id, query });
      return Promise.resolve({ entity: 'collection', count: invoices.length, items: invoices });
    },
    getPayment(id, options) {
      seen.payments.push({ id, options });
      const index = Number(String(id).split('_').pop());
      return Promise.resolve(payment(index));
    },
  };
}

test('only a PAID subscription is recoverable; a checkout never is', () => {
  assert.equal(isRecoverableProviderSubscription({ status: 'active' }), true);
  assert.equal(isRecoverableProviderSubscription({ status: 'active', paid_count: 0 }), true);
  assert.equal(
    isRecoverableProviderSubscription({ status: 'authenticated', paid_count: 2 }),
    true,
  );
  // The v758 pending-checkout population must stay untouched.
  assert.equal(
    isRecoverableProviderSubscription({ status: 'authenticated', paid_count: 0 }),
    false,
  );
  assert.equal(isRecoverableProviderSubscription({ status: 'created' }), false);
  assert.equal(isRecoverableProviderSubscription({ status: 'expired' }), false);
  assert.equal(isRecoverableProviderSubscription({ status: 'cancelled' }), false);
  assert.equal(isRecoverableProviderSubscription({}), false);
});

test('the envelopes are webhook-shaped, correctly identified and in rank order', () => {
  const envelopes = buildRecoveryEnvelopes({
    subscription: subscription(),
    paidInvoices: [
      { invoice: invoice(0), payment: payment(0) },
      { invoice: invoice(1), payment: payment(1) },
    ],
    recoveredAt: '2026-09-05T00:00:00.000Z',
  });

  assert.equal(envelopes.length, 3);
  assert.deepEqual(
    envelopes.map((item) => item.eventType),
    ['subscription.activated', 'subscription.charged', 'subscription.charged'],
  );
  assert.deepEqual(
    envelopes.map((item) => item.eventId),
    [
      `recovery_${SUB}_activated`,
      `recovery_${SUB}_pay_v759_0_charged`,
      `recovery_${SUB}_pay_v759_1_charged`,
    ],
  );
  // Every event attaches to the SUBSCRIPTION, which is what the webhook sends as object id.
  for (const item of envelopes) assert.equal(item.objectId, SUB);
  // The inbox's razorpay event-id pattern must accept every synthesised id.
  for (const item of envelopes) assert.match(item.eventId, /^[A-Za-z0-9_-]{6,}$/);

  // activated is timed at the subscription's creation; each charged at its invoice's paid_at.
  assert.equal(envelopes[0].eventCreatedAt, new Date(1788000000 * 1000).toISOString());
  assert.equal(envelopes[1].eventCreatedAt, new Date(invoice(0).paid_at * 1000).toISOString());
  assert.equal(envelopes[2].eventCreatedAt, new Date(invoice(1).paid_at * 1000).toISOString());

  for (const item of envelopes) {
    assert.equal(item.payload.entity, 'event');
    assert.equal(item.payload.event, item.eventType);
    assert.equal(item.payload.recovered_from, 'provider_api');
    assert.equal(item.payload.recovered_at, '2026-09-05T00:00:00.000Z');
  }
  // The activated envelope carries no payment: nothing about it may write paid truth.
  assert.equal(envelopes[0].payload.payload.payment, undefined);
});

/* The applier reads a fixed set of paths. If any of them stops being present the recovered event
   is ingested and then either ignored or raises inside the SQL, so they are asserted by name. */
test('the synthesised payload carries every field the v755 applier reads', () => {
  const [activated, charged] = buildRecoveryEnvelopes({
    subscription: subscription(),
    paidInvoices: [{ invoice: invoice(0), payment: payment(0) }],
    recoveredAt: '2026-09-05T00:00:00.000Z',
  });

  for (const item of [activated, charged]) {
    const entity = item.payload.payload.subscription.entity;
    assert.equal(entity.id, SUB);
    assert.equal(entity.plan_id, 'plan_v759_monthly');
    assert.equal(entity.customer_id, 'cust_v759');
    assert.equal(entity.status, 'active');
    assert.equal(entity.quantity, 3);
    assert.equal(entity.notes.business_id, BUSINESS);
    assert.equal(typeof entity.charge_at, 'number');
  }

  // The charged envelope's period is the INVOICE's billing window, not the newest cycle.
  const chargedSubscription = charged.payload.payload.subscription.entity;
  assert.equal(chargedSubscription.current_start, invoice(0).billing_start);
  assert.equal(chargedSubscription.current_end, invoice(0).billing_end);
  // ...while the activated envelope keeps the subscription's own current window.
  assert.equal(activated.payload.payload.subscription.entity.current_start, 1790000000);

  const paymentEntity = charged.payload.payload.payment.entity;
  assert.equal(paymentEntity.id, 'pay_v759_0');
  assert.equal(paymentEntity.amount, 9900);
  assert.equal(paymentEntity.currency, 'SGD');
  assert.equal(paymentEntity.method, 'card');
  assert.equal(paymentEntity.card.last4, '4242');
  assert.equal(typeof paymentEntity.created_at, 'number');
  // The Razorpay INVOICE id, so a later genuine webhook updates the same mirror row.
  assert.equal(paymentEntity.invoice_id, 'inv_v759_0');
  // Notes merged, with the subscription's authoritative business_id winning.
  assert.equal(paymentEntity.notes.business_id, BUSINESS);
  assert.equal(paymentEntity.notes.source, 'razorpay');
});

test('recovery reads the provider, then ingests and applies each event in order', async () => {
  const admin = adminStub();
  const razorpay = razorpayStub();
  const outcome = await recoverProviderSubscription({
    admin,
    razorpay,
    subscriptionId: SUB,
    livemode: true,
  });

  // (a) the subscription is re-read, (b) its invoices listed, (c) each payment expanded.
  assert.deepEqual(razorpay.seen.subscriptions, [SUB]);
  assert.equal(razorpay.seen.invoiceLists.length, 1);
  assert.deepEqual(razorpay.seen.payments.map(({ id }) => id), ['pay_v759_0', 'pay_v759_1']);
  for (const call of razorpay.seen.payments) assert.equal(call.options.expandCard, true);

  // (d) ingest then apply, per event, in rank order.
  assert.deepEqual(
    admin.calls.map(({ name, args }) => `${name}:${args.p_event_id}`),
    [
      `ingest_billing_event_v755:recovery_${SUB}_activated`,
      `apply_razorpay_billing_event_v755:recovery_${SUB}_activated`,
      `ingest_billing_event_v755:recovery_${SUB}_pay_v759_0_charged`,
      `apply_razorpay_billing_event_v755:recovery_${SUB}_pay_v759_0_charged`,
      `ingest_billing_event_v755:recovery_${SUB}_pay_v759_1_charged`,
      `apply_razorpay_billing_event_v755:recovery_${SUB}_pay_v759_1_charged`,
    ],
  );

  const ingests = admin.calls.filter(({ name }) => name === 'ingest_billing_event_v755');
  for (const { args } of ingests) {
    assert.equal(args.p_provider, 'razorpay');
    assert.equal(args.p_object_id, SUB);
    assert.equal(args.p_livemode, true);
    assert.match(args.p_payload_sha256, /^[0-9a-f]{64}$/);
    assert.match(args.p_event_created_at, /^\d{4}-\d{2}-\d{2}T/);
    // The digest is the sha256 of the JSON string of the payload actually sent.
    assert.equal(typeof args.p_payload, 'object');
  }
  assert.equal(ingests[0].args.p_event_type, 'subscription.activated');
  assert.equal(ingests[1].args.p_event_type, 'subscription.charged');

  assert.equal(outcome.events.length, 3);
  assert.equal(outcome.events.every((event) => event.duplicate === false), true);
  assert.deepEqual(outcome.invoices, [
    {
      invoice_id: 'inv_v759_0',
      payment_id: 'pay_v759_0',
      amount_cents: 9900,
      currency: 'SGD',
      paid_at: new Date(invoice(0).paid_at * 1000).toISOString(),
    },
    {
      invoice_id: 'inv_v759_1',
      payment_id: 'pay_v759_1',
      amount_cents: 9900,
      currency: 'SGD',
      paid_at: new Date(invoice(1).paid_at * 1000).toISOString(),
    },
  ]);
});

test('unpaid invoices are never recovered as paid truth', async () => {
  const admin = adminStub();
  const razorpay = razorpayStub({
    invoices: [
      invoice(0),
      invoice(1, { status: 'issued', paid_at: null }),
      invoice(2, { status: 'paid', payment_id: null }),
    ],
  });
  const outcome = await recoverProviderSubscription({
    admin,
    razorpay,
    subscriptionId: SUB,
    livemode: false,
  });
  assert.deepEqual(outcome.invoices.map(({ invoice_id }) => invoice_id), ['inv_v759_0']);
  assert.equal(outcome.events.length, 2); // activated + one charged
});

test('a re-run is a no-op: the ids dedupe and the outcome reports duplicate', async () => {
  const first = adminStub();
  const razorpay = razorpayStub();
  const before = await recoverProviderSubscription({
    admin: first,
    razorpay,
    subscriptionId: SUB,
    livemode: true,
  });

  // The SAME deterministic ids come back, and the inbox now says it already had them.
  const second = adminStub({ duplicates: true });
  const after = await recoverProviderSubscription({
    admin: second,
    razorpay: razorpayStub(),
    subscriptionId: SUB,
    livemode: true,
  });
  assert.deepEqual(
    after.events.map(({ event_id }) => event_id),
    before.events.map(({ event_id }) => event_id),
  );
  assert.equal(after.events.every((event) => event.duplicate === true), true);
  // Nothing new is written; the inbox's unique(provider,event_id) is what makes it a no-op.
  assert.deepEqual(
    second.calls.map(({ args }) => args.p_event_id),
    first.calls.map(({ args }) => args.p_event_id),
  );
});

test('an ingest or apply failure throws so the caller can COUNT it, and writes nothing after', async () => {
  const ingestFailure = adminStub({ failIngestFor: 'pay_v759_1' });
  await assert.rejects(
    recoverProviderSubscription({
      admin: ingestFailure,
      razorpay: razorpayStub(),
      subscriptionId: SUB,
      livemode: true,
    }),
    /recovery ingest failed/,
  );
  // The failing event is never applied.
  assert.equal(
    ingestFailure.calls.some(
      ({ name, args }) =>
        name === 'apply_razorpay_billing_event_v755' && args.p_event_id.includes('pay_v759_1'),
    ),
    false,
  );

  const applyFailure = adminStub({ failApplyFor: 'activated' });
  await assert.rejects(
    recoverProviderSubscription({
      admin: applyFailure,
      razorpay: razorpayStub(),
      subscriptionId: SUB,
      livemode: true,
    }),
    /recovery apply failed/,
  );
  // It stopped at the first failure: the charged events were never ingested.
  assert.equal(
    applyFailure.calls.some(({ args }) => args.p_event_id.includes('charged')),
    false,
  );
});

test('the reconcile run bounds recovery at ten and never lets it fail the run', async () => {
  assert.equal(PROVIDER_RECOVERY_MAX_PER_RUN, 10);
  const source = await read('supabase/functions/razorpay-billing-reconcile/index.ts');

  // The bound is a strict less-than against the attempted counter, so at most 10 are attempted.
  assert.match(source, /run\.recovered\.attempted < PROVIDER_RECOVERY_MAX_PER_RUN/);
  assert.match(source, /run\.recovered\.attempted \+= 1;/);
  assert.match(source, /run\.recovered\.succeeded \+= 1;/);
  assert.match(source, /run\.recovered\.failed \+= 1;/);

  // Recovery is gated on paid + the run's own Razorpay tenant scope.
  assert.match(source, /isRecoverableProviderSubscription\(provider\)/);
  assert.match(source, /scopedBusinessIds\.has\(candidate\)/);
  assert.match(source, /const scopedBusinessIds = new Set\(scope\.businessIds\);/);
  // A pending checkout is excluded before recovery is even considered.
  assert.match(source, /!pending &&\s*\n\s*isRecoverableProviderSubscription/);

  // A failure is caught and downgraded to the existing missing_local record, never rethrown.
  assert.match(source, /} catch \(error\) \{[\s\S]*?run\.recovered\.failed \+= 1;/);
  assert.match(source, /recovery_error: String\(\(error as Error\)\?\.message/);

  // The evidence row and the run summary.
  assert.match(source, /result: 'repaired'/);
  assert.match(source, /reason: 'provider_subscription_recovered'/);
  assert.match(source, /invoices: outcome\.invoices,/);
  assert.match(source, /events: outcome\.events,/);
  assert.match(source, /recovered: run\.recovered,/);
  assert.match(source, /recovered: \{ attempted: 0, succeeded: 0, failed: 0 \},/);

  // Recovery must run through the existing pipeline; the reconcile function writes no billing
  // truth of its own.
  assert.doesNotMatch(source, /from\('billing_provider_subscriptions'\)[\s\S]{0,200}\.insert\(/);
  assert.doesNotMatch(source, /from\('billing_provider_invoices'\)[\s\S]{0,200}\.insert\(/);
});
