/* nestly_v767 — a subscription's invoices are fetched from the Invoices API, filtered by
   subscription_id. Razorpay has no /subscriptions/:id/invoices route; the client used to call it
   and every added branch stayed "Awaiting payment" (404 on the update-charge capture) while the
   reconcile heal reported failed=attempted. Executes the real client against a stubbed fetch. */
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { razorpayClient, RazorpayApiError } from '../../supabase/functions/_shared/razorpay-client.ts';

function withFetch(handler, run) {
  const original = globalThis.fetch;
  globalThis.fetch = handler;
  return run().finally(() => {
    globalThis.fetch = original;
  });
}

test('getSubscriptionInvoices calls GET /v1/invoices?subscription_id=… with the extra query kept', async () => {
  const seen = [];
  await withFetch(
    (url, init) => {
      seen.push({ url: String(url), method: init?.method });
      return Promise.resolve(
        new Response(JSON.stringify({ entity: 'collection', count: 0, items: [] }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        }),
      );
    },
    async () => {
      const client = razorpayClient({ keyId: 'rzp_test_sg_x', keySecret: 's' });
      const page = await client.getSubscriptionInvoices('sub_v767', { count: 100 });
      assert.deepEqual(page.items, []);
    },
  );
  assert.equal(seen.length, 1);
  const url = new URL(seen[0].url);
  assert.equal(seen[0].method, 'GET');
  assert.equal(url.origin + url.pathname, 'https://api.razorpay.com/v1/invoices');
  assert.equal(url.searchParams.get('subscription_id'), 'sub_v767');
  assert.equal(url.searchParams.get('count'), '100');
  assert.ok(!seen[0].url.includes('/subscriptions/sub_v767/invoices'), 'the phantom route must not be called');
});

test('a rejected call names its method and path so a 404 is diagnosable from the log line', async () => {
  await withFetch(
    () =>
      Promise.resolve(
        new Response(JSON.stringify({ error: { code: 'BAD_REQUEST_ERROR', description: 'The requested URL was not found on the server.' } }), {
          status: 404,
          headers: { 'content-type': 'application/json' },
        }),
      ),
    async () => {
      const client = razorpayClient({ keyId: 'rzp_test_sg_x', keySecret: 's' });
      await assert.rejects(
        client.getPayment('pay_v767', { expandCard: true }),
        (error) => error instanceof RazorpayApiError && /\(GET \/payments\/pay_v767\)$/.test(error.message),
      );
    },
  );
});
