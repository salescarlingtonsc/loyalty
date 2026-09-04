import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';

const root = new URL('../..', import.meta.url).pathname;
const read = (path) => readFile(join(root, path), 'utf8');

test('scheduled billing reconciliation compares provider and Nestly payment truth', async () => {
  const [worker, config] = await Promise.all([
    read('supabase/functions/razorpay-billing-reconcile/index.ts'),
    read('supabase/config.toml'),
  ]);
  assert.match(worker, /razorpayClient/);
  assert.match(worker, /BILLING_RECONCILIATION_SECRET/);
  assert.match(worker, /x-nestly-reconciliation-secret/);
  assert.match(worker, /start_billing_reconciliation_v757/);
  assert.match(worker, /p_run_mode: 'scheduled'/);
  assert.match(worker, /billing_provider_subscriptions/);
  assert.match(worker, /razorpay\.getSubscription/);
  assert.match(worker, /billing_provider_invoices/);
  assert.match(worker, /razorpay\.getPayment/);
  assert.match(worker, /billing_reconciliation_items/);
  assert.match(worker, /finish_billing_reconciliation_v77/);
  assert.match(worker, /'missing_provider'/);
  assert.match(worker, /LOCAL_OBJECTS_PER_PAGE = 100/);
  assert.match(worker, /PROVIDER_OBJECTS_PER_PAGE = 100/);
  assert.match(worker, /MAX_PAGES_PER_STREAM = 1/);
  assert.match(worker, /drainBoundedKeysetPages/);
  // v755: the provider-side sweep is not a cursor-based (keyset) page like Stripe's list — the
  // Razorpay Subscriptions/Payments list APIs only offer count/skip, so the offset-paged helper
  // replaces drainBoundedProviderPages here.
  assert.match(worker, /drainBoundedOffsetPages/);
  assert.match(worker, /razorpay\.listSubscriptions/);
  assert.match(worker, /razorpay\.listPayments/);
  assert.match(worker, /'missing_local'/);
  assert.match(worker, /provider_subscriptions_complete/);
  assert.match(worker, /provider_invoices_complete/);
  assert.match(worker, /p_status: status/);
  assert.match(worker, /'partial'/);
  assert.match(worker, /priorCursor/);
  assert.doesNotMatch(worker, /capped:/);
  assert.match(
    config,
    /\[functions\.razorpay-billing-reconcile\]\nverify_jwt = false/,
  );
});

test('billing reconciliation never fabricates paid state or repairs projections directly', async () => {
  const worker = await read(
    'supabase/functions/razorpay-billing-reconcile/index.ts',
  );
  assert.doesNotMatch(worker, /\.from\('subscriptions'\)\.(?:insert|update|upsert)/);
  assert.doesNotMatch(
    worker,
    /\.from\('billing_provider_invoices'\)\.(?:insert|update|upsert)/,
  );
  assert.doesNotMatch(worker, /apply_razorpay_billing_event_v755/);
  // A CAPTURED Razorpay payment is the settled-money analogue of Stripe's invoice.status==='paid':
  // only that status is treated as revenue reconciliation should expect a local invoice for.
  assert.match(worker, /payment\.status === 'captured'/);
});
