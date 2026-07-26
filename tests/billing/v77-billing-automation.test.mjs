import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';

const root = new URL('../..', import.meta.url).pathname;
const read = (path) => readFile(join(root, path), 'utf8');

test('scheduled billing reconciliation compares provider and Nestly payment truth', async () => {
  const [worker, config] = await Promise.all([
    read('supabase/functions/stripe-billing-reconcile/index.ts'),
    read('supabase/config.toml'),
  ]);
  assert.match(worker, /npm:stripe@18\.5\.0/);
  assert.match(worker, /BILLING_RECONCILIATION_SECRET/);
  assert.match(worker, /x-nestly-reconciliation-secret/);
  assert.match(worker, /start_billing_reconciliation_v77/);
  assert.match(worker, /p_run_mode: 'scheduled'/);
  assert.match(worker, /billing_provider_subscriptions/);
  assert.match(worker, /stripe\.subscriptions\.retrieve/);
  assert.match(worker, /billing_provider_invoices/);
  assert.match(worker, /stripe\.invoices\.retrieve/);
  assert.match(worker, /billing_reconciliation_items/);
  assert.match(worker, /finish_billing_reconciliation_v77/);
  assert.match(worker, /'missing_provider'/);
  assert.match(worker, /LOCAL_OBJECTS_PER_PAGE = 100/);
  assert.match(worker, /PROVIDER_OBJECTS_PER_PAGE = 100/);
  assert.match(worker, /MAX_PAGES_PER_STREAM = 1/);
  assert.match(worker, /drainBoundedKeysetPages/);
  assert.match(worker, /drainBoundedProviderPages/);
  assert.match(worker, /stripe\.subscriptions\.list/);
  assert.match(worker, /stripe\.invoices\.list/);
  assert.match(worker, /'missing_local'/);
  assert.match(worker, /provider_subscriptions_complete/);
  assert.match(worker, /provider_invoices_complete/);
  assert.match(worker, /p_status: status/);
  assert.match(worker, /'partial'/);
  assert.match(worker, /priorCursor/);
  assert.doesNotMatch(worker, /capped:/);
  assert.match(
    config,
    /\[functions\.stripe-billing-reconcile\]\s+verify_jwt = false/,
  );
});

test('billing reconciliation never fabricates paid state or repairs projections directly', async () => {
  const worker = await read(
    'supabase/functions/stripe-billing-reconcile/index.ts',
  );
  assert.doesNotMatch(worker, /\.from\('subscriptions'\)\.(?:insert|update|upsert)/);
  assert.doesNotMatch(
    worker,
    /\.from\('billing_provider_invoices'\)\.(?:insert|update|upsert)/,
  );
  assert.doesNotMatch(worker, /apply_stripe_billing_event_v77/);
  assert.match(worker, /invoice\.status === 'paid'/);
});
