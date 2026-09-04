/* nestly_v758 — the reconciliation run backfills the stored card label.

   These tests EXECUTE the backfill against stubs rather than grepping the edge source: a source
   regex would stay green if the loop stopped calling the RPC, or if the bound moved, or if a
   failure started propagating. The one thing that cannot be executed here (the real HTTP query
   string) is proven by driving the actual razorpay client against a stubbed fetch. */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import {
  backfillPaymentMethods,
  mapPaymentMethod,
  PAYMENT_METHOD_BACKFILL_MAX_TENANTS,
} from '../../supabase/functions/_shared/billing-payment-method-backfill.ts';
import { razorpayClient } from '../../supabase/functions/_shared/razorpay-client.ts';

const root = new URL('../../', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');

function uuid(index) {
  return `0000000${index}`.slice(-8) + '-0000-4000-8000-000000000000';
}

/* A minimal PostgREST-shaped stub: every filter method returns `this`, and the terminal await
   resolves whatever the table handler produced. It records the calls so the tests can assert the
   query the module actually built (provider, livemode, null last4, bound). */
function adminStub({ customers, invoices, onRpc }) {
  const calls = { tables: [], filters: [], rpc: [] };
  function builder(table) {
    const state = { table, eq: {}, is: {}, limit: null };
    const chain = {
      select: () => chain,
      eq: (column, value) => {
        state.eq[column] = value;
        return chain;
      },
      is: (column, value) => {
        state.is[column] = value;
        return chain;
      },
      not: () => chain,
      in: (column, value) => {
        state.eq[column] = value;
        return chain;
      },
      order: () => chain,
      limit: (value) => {
        state.limit = value;
        return chain;
      },
      then: (resolve, reject) => {
        calls.filters.push(state);
        const result =
          table === 'billing_provider_customers'
            ? customers(state)
            : invoices(state);
        return Promise.resolve(result).then(resolve, reject);
      },
    };
    return chain;
  }
  return {
    calls,
    from(table) {
      calls.tables.push(table);
      return builder(table);
    },
    async rpc(fn, args) {
      calls.rpc.push({ fn, args });
      return onRpc ? await onRpc(fn, args) : { error: null };
    },
  };
}

const scope = { livemode: true, businessIds: Array.from({ length: 60 }, (_, i) => uuid(i)) };

function cardPayment(id) {
  return { id, method: 'card', card: { last4: '4242', network: 'Visa' } };
}

test('the backfill is bounded to 25 tenants per run', async () => {
  const rows = Array.from({ length: 60 }, (_, i) => ({ business_id: uuid(i) }));
  const admin = adminStub({
    customers: (state) => ({ data: rows.slice(0, state.limit), error: null }),
    invoices: (state) => ({
      data: [{ provider_payment_intent_id: `pay_${state.eq.business_id}`, paid_at: '2026-09-01T00:00:00Z' }],
      error: null,
    }),
  });
  const seen = [];
  const counts = await backfillPaymentMethods({
    admin,
    scope,
    razorpay: {
      getPayment: async (id) => {
        seen.push(id);
        return cardPayment(id);
      },
    },
  });
  assert.equal(PAYMENT_METHOD_BACKFILL_MAX_TENANTS, 25);
  const customerQuery = admin.calls.filters.find((f) => f.table === 'billing_provider_customers');
  assert.equal(customerQuery.limit, 25);
  assert.equal(seen.length, 25);
  assert.deepEqual(counts, { attempted: 25, updated: 25, failed: 0 });
});

test('a caller cannot raise the bound above 25', async () => {
  const rows = Array.from({ length: 60 }, (_, i) => ({ business_id: uuid(i) }));
  const admin = adminStub({
    customers: (state) => ({ data: rows.slice(0, state.limit ?? rows.length), error: null }),
    invoices: () => ({ data: [{ provider_payment_intent_id: 'pay_1' }], error: null }),
  });
  const counts = await backfillPaymentMethods({
    admin,
    scope,
    limit: 500,
    razorpay: { getPayment: async (id) => cardPayment(id) },
  });
  assert.equal(counts.attempted, 25);
});

test('only unfilled rows of this provider and mode are candidates', async () => {
  const admin = adminStub({
    customers: () => ({ data: [], error: null }),
    invoices: () => ({ data: [], error: null }),
  });
  await backfillPaymentMethods({ admin, scope, razorpay: { getPayment: async () => cardPayment('x') } });
  const query = admin.calls.filters[0];
  assert.equal(query.eq.provider, 'razorpay');
  assert.equal(query.eq.livemode, true);
  assert.equal(query.is.payment_method_last4, null);
  assert.deepEqual(query.eq.business_id, scope.businessIds);
});

test('a card payment is written through set_billing_payment_method_v758', async () => {
  const admin = adminStub({
    customers: () => ({ data: [{ business_id: uuid(1) }], error: null }),
    invoices: () => ({ data: [{ provider_payment_intent_id: 'pay_ABC' }], error: null }),
  });
  const counts = await backfillPaymentMethods({
    admin,
    scope,
    razorpay: { getPayment: async (id, options) => {
      assert.deepEqual(options, { expandCard: true });
      return cardPayment(id);
    } },
  });
  assert.deepEqual(admin.calls.rpc, [{
    fn: 'set_billing_payment_method_v758',
    args: {
      p_business: uuid(1),
      p_payment_id: 'pay_ABC',
      p_kind: 'card',
      p_brand: 'Visa',
      p_last4: '4242',
    },
  }]);
  assert.deepEqual(counts, { attempted: 1, updated: 1, failed: 0 });
});

test('paynow maps to a kind with no brand or last4; other methods write nothing', () => {
  assert.deepEqual(mapPaymentMethod({ id: 'p', method: 'paynow' }), {
    kind: 'paynow',
    brand: null,
    last4: null,
  });
  assert.equal(mapPaymentMethod({ id: 'p', method: 'netbanking' }), null);
  assert.equal(mapPaymentMethod({ id: 'p', method: 'card', card: { last4: '42' } }), null);
  assert.equal(mapPaymentMethod(null), null);
});

test('every failure is counted and none of them throws', async () => {
  const admin = adminStub({
    customers: () => ({ data: [{ business_id: uuid(1) }, { business_id: uuid(2) }, { business_id: uuid(3) }], error: null }),
    invoices: (state) =>
      state.eq.business_id === uuid(3)
        ? { data: null, error: { message: 'boom' } }
        : { data: [{ provider_payment_intent_id: `pay_${state.eq.business_id}` }], error: null },
    onRpc: (_fn, args) =>
      args.p_business === uuid(2) ? { error: { message: 'rejected' } } : { error: null },
  });
  const counts = await backfillPaymentMethods({
    admin,
    scope,
    razorpay: {
      getPayment: async (id) => {
        if (id === `pay_${uuid(1)}`) throw new Error('razorpay unavailable');
        return cardPayment(id);
      },
    },
  });
  assert.deepEqual(counts, { attempted: 3, updated: 0, failed: 3 });
});

test('a candidate query failure is counted, not thrown', async () => {
  const admin = adminStub({
    customers: () => ({ data: null, error: { message: 'down' } }),
    invoices: () => ({ data: [], error: null }),
  });
  const counts = await backfillPaymentMethods({
    admin,
    scope,
    razorpay: { getPayment: async () => cardPayment('x') },
  });
  assert.deepEqual(counts, { attempted: 0, updated: 0, failed: 1 });
});

test('the razorpay client requests the payment with expand[]=card', async () => {
  const requested = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    requested.push(String(url));
    return new Response(JSON.stringify({ id: 'pay_1', method: 'card' }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  };
  try {
    const client = razorpayClient({ keyId: 'rzp_test_x', keySecret: 's' });
    await client.getPayment('pay_1', { expandCard: true });
    await client.getPayment('pay_1');
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(new URL(requested[0]).pathname, '/v1/payments/pay_1');
  assert.deepEqual(new URL(requested[0]).searchParams.getAll('expand[]'), ['card']);
  assert.equal(new URL(requested[1]).search, '');
});

test('the reconcile run reports the backfill and runs it after the invoice streams', async () => {
  const source = await read('supabase/functions/razorpay-billing-reconcile/index.ts');
  const backfillAt = source.indexOf('await backfillPaymentMethods({');
  const providerInvoicesAt = source.indexOf('const providerInvoicePage = await reconcileProviderInvoices({');
  const finishAt = source.indexOf("admin.rpc('finish_billing_reconciliation_v77'");
  assert.ok(providerInvoicesAt > 0 && backfillAt > providerInvoicesAt, 'backfill must follow the invoice stream');
  assert.ok(finishAt > backfillAt, 'backfill must precede the run finish');
  assert.match(source, /payment_method_backfill: paymentMethodBackfill,/);
});

/* v758 follow-up — an abandoned hosted checkout is not a mismatch. */
import {
  classifyProviderSubscriptionAbsence,
  PENDING_AUTHENTICATED_WINDOW_MS,
} from '../../supabase/functions/_shared/razorpay-subscription-absence.ts';

const NOW = Date.parse('2026-09-04T12:00:00Z');
const secondsAgo = (ms) => Math.floor((NOW - ms) / 1000);

test('unpaid and expired checkouts classify as pending, active gaps stay missing_local', () => {
  assert.equal(classifyProviderSubscriptionAbsence({ status: 'created' }, NOW), 'pending_checkout');
  assert.equal(classifyProviderSubscriptionAbsence({ status: 'expired' }, NOW), 'pending_checkout');
  // The live finding: Cubbly's opened-but-unpaid checkout.
  assert.equal(
    classifyProviderSubscriptionAbsence(
      { status: 'created', paid_count: 0, created_at: secondsAgo(3 * 86400 * 1000) },
      NOW,
    ),
    'pending_checkout',
  );
  // Money is moving with no mirror — that is exactly what reconciliation exists to catch.
  assert.equal(
    classifyProviderSubscriptionAbsence({ status: 'active', paid_count: 1 }, NOW),
    'missing_local',
  );
  assert.equal(classifyProviderSubscriptionAbsence({ status: 'halted' }, NOW), 'missing_local');
  assert.equal(classifyProviderSubscriptionAbsence({}, NOW), 'missing_local');
});

test('authenticated with no charge is pending for 24h only', () => {
  const inFlight = { status: 'authenticated', paid_count: 0, created_at: secondsAgo(60 * 60 * 1000) };
  assert.equal(classifyProviderSubscriptionAbsence(inFlight, NOW), 'pending_checkout');
  const stale = {
    status: 'authenticated',
    paid_count: 0,
    created_at: secondsAgo(PENDING_AUTHENTICATED_WINDOW_MS + 60_000),
  };
  assert.equal(classifyProviderSubscriptionAbsence(stale, NOW), 'missing_local');
  const charged = { status: 'authenticated', paid_count: 1, created_at: secondsAgo(60_000) };
  assert.equal(classifyProviderSubscriptionAbsence(charged, NOW), 'missing_local');
});

test('the pending result value stays inside the items CHECK constraint', async () => {
  const migration = await read('db/migrations/20260726_nestly_v77_stripe_billing.sql');
  const check = migration.match(/result text not null check \(result in \(([^)]*)\)\)/);
  assert.ok(check, 'billing_reconciliation_items result CHECK not found');
  const allowed = check[1].split(',').map((value) => value.trim().replace(/'/g, ''));
  assert.ok(!allowed.includes('pending_checkout'), 'constraint changed — revisit the encoding');
  const source = await read('supabase/functions/razorpay-billing-reconcile/index.ts');
  const written = [...source.matchAll(/result: pending \? '([a-z_]+)' : '([a-z_]+)'/g)];
  assert.equal(written.length, 1, 'pending encoding not found exactly once');
  assert.deepEqual([written[0][1], written[0][2]], ['match', 'missing_local']);
  for (const value of [written[0][1], written[0][2]]) assert.ok(allowed.includes(value));
  // A pending checkout must not land in the discrepancy counters that raise a mismatch run.
  assert.match(source, /recordResult\(cursor, run, pending \? 'match' : 'missing_local'\);/);
  assert.match(source, /reason: 'provider_subscription_unpaid_checkout',/);
  assert.match(source, /command_id: provider\.notes\?\.command_id \|\| null,/);
  assert.match(source, /pending_checkout: run\.pending_checkout,/);
});
