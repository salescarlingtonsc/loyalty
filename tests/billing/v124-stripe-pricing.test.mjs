import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');

test('v124 defines the exact launch prices and customer-capacity model', async () => {
  const sql = await read('supabase/migrations/20260731164709_nestly_v124_stripe_launch_pricing.sql');
  assert.match(sql, /create table public\.billing_plan_catalog_v124/i);
  assert.match(sql, /base_amount_cents[^;]+14900/is);
  assert.match(sql, /base_amount_cents[^;]+118800/is);
  assert.match(sql, /capacity_block_amount_cents[^;]+1000/is);
  assert.match(sql, /capacity_block_amount_cents[^;]+12000/is);
  assert.match(sql, /included_customer_capacity[^;]+1000/is);
  assert.match(sql, /customer_capacity[^;]+%\s*1000\s*=\s*0/is);
  assert.match(sql, /current_customer_count/i);
  assert.match(sql, /staff access is included/i);
});

test('v124 checkout commands bind cadence and capacity to one idempotent fingerprint', async () => {
  const sql = await read('supabase/migrations/20260731164709_nestly_v124_stripe_launch_pricing.sql');
  assert.match(sql, /request_billing_command_v124\s*\([\s\S]+p_customer_capacity integer/i);
  assert.match(sql, /p_business::text[\s\S]+p_command_type[\s\S]+p_cadence[\s\S]+p_customer_capacity/i);
  assert.match(sql, /claim_billing_command_v124/i);
  assert.match(sql, /extra_capacity_blocks/i);
  assert.match(sql, /provider_capacity_price_id/i);
  assert.match(sql, /billing_catalog_id_v124 uuid/i);
  assert.match(sql, /catalog\.id=v_command\.billing_catalog_id_v124/i);
  assert.match(sql, /app\.is_salon_owner\(p_business\)/i);
  assert.match(sql, /set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
});

test('v124 first-paid money-back request window is immutable and exact', async () => {
  const sql = await read('supabase/migrations/20260731164709_nestly_v124_stripe_launch_pricing.sql');
  assert.match(sql, /first_paid_at/i);
  assert.match(sql, /money_back_request_until/i);
  assert.match(sql, /new\.paid_at\s*\+\s*interval '30 days'/i);
  assert.match(sql, /excluded\.first_paid_at[\s\S]+<\s*billing_money_back_windows_v124\.first_paid_at/i);
  assert.match(sql, /money-back request/i);
});

test('Stripe executor uses base plus capacity-block items and proration for upgrades', async () => {
  const edge = await read('supabase/functions/stripe-billing-command/index.ts');
  assert.match(edge, /claim_billing_command_v130/i);
  assert.match(edge, /extra_capacity_blocks/i);
  assert.match(edge, /provider_capacity_price_id/i);
  assert.match(edge, /requested_customer_capacity/i);
  assert.match(edge, /stripePendingUpdateParamsV125\(items, metadata\)/i);
  assert.match(edge, /verifiedSubscription\.pending_update/);
  assert.match(edge, /p_status:\s*'uncertain'/);
  assert.match(edge, /provider_confirmation_pending/);
  assert.doesNotMatch(edge, /const extraSeats = Number\(data\.extra_seats/);
});

test('V124 rejects customer-capacity decreases through every subscription-change command', async () => {
  const sql = await read('supabase/migrations/20260731164709_nestly_v124_stripe_launch_pricing.sql');
  assert.match(
    sql,
    /p_command_type\s+in\s*\('change_cadence','change_capacity'\)[\s\S]+p_customer_capacity\s*<\s*v_existing_capacity/i,
  );
  assert.match(
    sql,
    /v_command\.command_type\s+in\s*\('change_cadence','change_capacity'\)[\s\S]+v_capacity\s*<\s*v_terms\.customer_capacity/i,
  );
  assert.match(
    sql,
    /v_command\.command_type='change_capacity'[\s\S]+v_capacity=v_terms\.customer_capacity[\s\S]+not v_recovery_required/i,
  );
});

test('Stripe reconciliation detects price and customer-capacity quantity drift', async () => {
  const worker = await read('supabase/functions/stripe-billing-reconcile/index.ts');
  assert.match(worker, /billing_provider_subscription_items/);
  assert.match(worker, /provider_price_id,quantity/);
  assert.match(worker, /price_id:\s*item\.price\.id/);
  assert.match(worker, /quantity:\s*Number\(item\.quantity\s*\|\|\s*0\)/);
  assert.match(worker, /itemsBySubscription\.get\(local\.provider_subscription_id\)/);
});

test('processed Stripe subscription snapshots remove provider items absent from the latest event', async () => {
  const sql = await read('supabase/migrations/20260731164709_nestly_v124_stripe_launch_pricing.sql');
  assert.match(sql, /prune_billing_provider_items_v124/);
  assert.match(sql, /processing_status='processed'/);
  assert.match(sql, /provider_item_id\s+not\s+in/i);
  assert.match(sql, /provider_event_created_at[\s\S]+provider_event_rank/);
});

test('money-back windows are scoped to the matching V124 provider subscription and backfilled', async () => {
  const sql = await read('supabase/migrations/20260731164709_nestly_v124_stripe_launch_pricing.sql');
  assert.match(sql, /billing_subscription_terms_v124[\s\S]+provider_subscription_id text not null/i);
  assert.match(sql, /terms\.provider_subscription_id\s*=\s*new\.provider_subscription_id/i);
  assert.match(sql, /backfill_money_back_window_v124/);
  assert.match(sql, /order by invoice\.paid_at,invoice\.provider_event_created_at/i);
});

test('owner checkout defaults annual and explains price, capacity, modules, staff and guarantee', async () => {
  const app = await read('app/index.html');
  assert.match(app, /get_business_billing_v125/);
  assert.match(app, /value="annual"[^>]+checked/);
  assert.match(app, /SGD 1,188/);
  assert.match(app, /SGD 149/);
  assert.match(app, /1,000 customer profiles/);
  assert.match(app, /Staff access included/);
  assert.match(app, /AI-assisted promotion copy/);
  assert.match(app, /30-day money-back request/);
  assert.match(app, /request_billing_command_v124/);
  assert.match(app, /billingAttemptSlot/);
  assert.match(app, /sessionStorage\.setItem\(billingAttemptSlot/);
  assert.match(app, /attempt\.command_id/);
  assert.match(app, /\['failed','canceled'\]\.includes\(result\.status\)/);
  assert.match(app, /Stripe did not complete this billing request/);
  assert.doesNotMatch(app, /Your current subscription is unchanged; try again\./);
});

test('public legal surfaces use the supplied company identity and business mailbox', async () => {
  for (const path of ['app/privacy.html', 'app/terms.html', 'app/data-request.html']) {
    const page = await read(path);
    assert.match(page, /NESTLY TECHNOLOGIES PTE\. LTD\./);
    assert.match(page, /202634502E/);
    assert.match(page, /nestlyasia@gmail\.com/);
    assert.doesNotMatch(page, /nestly\.asia@gmail\.com|leechuanseng\.biz@gmail\.com/);
  }
});

test('V124 publishes the exact live Terms and Privacy digests without rewriting acceptance history', async () => {
  const [sql, terms, privacy] = await Promise.all([
    read('supabase/migrations/20260731164709_nestly_v124_stripe_launch_pricing.sql'),
    read('app/terms.html'),
    read('app/privacy.html'),
  ]);
  for (const page of [terms, privacy]) {
    const digest = createHash('sha256').update(page).digest('hex');
    assert.match(sql, new RegExp(digest));
  }
  assert.match(sql, /document_version='2026-08-01'/);
  assert.doesNotMatch(sql, /(?:delete from|truncate)\s+(?:app\.)?customer_legal_documents/i);
  assert.doesNotMatch(sql, /(?:insert into|update|delete from|truncate)\s+public\.customer_legal_acceptances/i);
});

test('Stripe catalogue bootstrap is idempotent, exact and live guarded', async () => {
  const setup = await read('scripts/stripe/setup-v124-catalog.mjs');
  assert.match(setup, /--apply/);
  assert.match(setup, /--allow-live/);
  assert.match(setup, /sk_live_/);
  assert.match(setup, /nestly_v124_monthly_base_sgd/);
  assert.match(setup, /nestly_v124_annual_capacity_1000_sgd/);
  for (const cents of ['14900', '118800', '1000', '12000']) {
    assert.match(setup, new RegExp(`unitAmount: ${cents}`));
  }
  assert.doesNotMatch(setup, /console\.log\(secret|process\.stdout\.write\([^\n]*secret/);
});
