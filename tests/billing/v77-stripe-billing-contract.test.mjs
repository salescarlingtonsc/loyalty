import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';

const root = new URL('../..', import.meta.url).pathname;
const read = (path) => readFile(join(root, path), 'utf8');
const sourcePath = 'db/migrations/20260726_nestly_v77_stripe_billing.sql';
const canonicalPath = 'supabase/migrations/20260726120000_nestly_v77_stripe_billing.sql';

const functionBlock = (sql, schema, name) =>
  sql.match(
    new RegExp(
      `create or replace function ${schema}\\.${name}[\\s\\S]+?\\n\\$\\$;`,
      'i',
    ),
  )?.[0] || '';

test('v77 source and canonical migration are byte-identical', async () => {
  const [source, canonical] = await Promise.all([
    read(sourcePath),
    read(canonicalPath),
  ]);
  assert.equal(canonical, source);
  assert.match(source, /^-- NESTLY v77/m);
  assert.match(source, /commit;\s*$/);
});

test('v77 canonicalizes the three requested cadences and keeps GST separate', async () => {
  const sql = await read(sourcePath);
  for (const cadence of ['quarterly', 'half_yearly', 'annual']) {
    assert.match(sql, new RegExp(`'${cadence}'`));
  }
  assert.match(
    sql,
    /cadence = 'quarterly' and cadence_months = 3[\s\S]+cadence = 'half_yearly' and cadence_months = 6[\s\S]+cadence = 'annual' and cadence_months = 12/i,
  );
  assert.match(
    sql,
    /p_interval = 'year' and p_count = 1[\s\S]+p_interval = 'month' and p_count = 12[\s\S]+then 'annual'/i,
  );
  assert.match(
    sql,
    /v_cadence_months := case v_cadence[\s\S]+when 'annual' then 12/i,
  );
  assert.match(
    sql,
    /interval_count smallint check \(interval_count is null or interval_count > 0\)/i,
  );
  assert.match(
    sql,
    /interval_name text check \(interval_name is null or interval_name in \('month','year'\)\)/i,
  );
  assert.match(
    sql,
    /subtotal_ex_tax_cents integer not null[\s\S]+tax_cents integer not null[\s\S]+total_cents integer not null/i,
  );
  assert.match(sql, /total_cents = subtotal_ex_tax_cents \+ tax_cents/i);
});

test('v77 has the complete provider and operations record set with no browser table grants', async () => {
  const sql = await read(sourcePath);
  for (const table of [
    'billing_price_catalog',
    'billing_provider_customers',
    'billing_provider_subscriptions',
    'billing_provider_subscription_items',
    'billing_provider_invoices',
    'billing_payment_attempts',
    'billing_provider_events',
    'billing_commands',
    'billing_adjustments',
    'billing_evidence',
    'billing_reconciliation_runs',
    'billing_reconciliation_items',
    'billing_automation_runs',
  ]) {
    assert.match(sql, new RegExp(`create table public\\.${table}\\b`, 'i'));
    assert.match(
      sql,
      new RegExp(`alter table public\\.${table} enable row level security`, 'i'),
    );
    assert.match(
      sql,
      new RegExp(
        `revoke all privileges on table public\\.${table} from public, anon, authenticated`,
        'i',
      ),
    );
  }
  assert.doesNotMatch(
    sql,
    /grant\s+(?:select|insert|update|delete|all)\s+on\s+public\.billing_/i,
  );
});

test('v77 durable inbox is exact-replay idempotent and rejects changed envelopes', async () => {
  const sql = await read(sourcePath);
  const ingest = functionBlock(sql, 'public', 'ingest_stripe_billing_event_v77');
  assert.match(ingest, /unique[\s\S]*provider,event_id|on conflict\(provider,event_id\)/i);
  assert.match(ingest, /payload_sha256/i);
  assert.match(ingest, /conflicts with a different envelope/i);
  assert.match(ingest, /'duplicate',true/i);
  assert.match(
    sql,
    /billing event envelope is immutable[\s\S]+before update or delete on public\.billing_provider_events/i,
  );
});

test('v77 event application is stale-safe and invoice.paid alone creates paid truth', async () => {
  const sql = await read(sourcePath);
  const apply = functionBlock(sql, 'public', 'apply_stripe_billing_event_v77');
  assert.match(
    apply,
    /\(excluded\.provider_event_created_at,excluded\.provider_event_rank\)\s+>=/i,
  );
  assert.match(sql, /when 'invoice\.paid' then 100/i);
  assert.match(apply, /v_event\.event_type='invoice\.paid'/i);
  assert.match(
    apply,
    /paid_normalized=excluded\.paid_normalized[\s\S]+last_paid_invoice_id=case when v_event\.event_type='invoice\.paid'/i,
  );
  assert.match(
    apply,
    /set payment_status=case[\s\S]+payment_event_created_at=v_event\.event_created_at/i,
  );
  assert.doesNotMatch(
    apply,
    /update public\.subscriptions tenant_subscription\s+set status=case[\s\S]+invoice\.paid/i,
  );
  assert.doesNotMatch(
    apply,
    /v_object->>'status'\s*=\s*'paid'[\s\S]{0,120}paid_normalized/i,
  );
  assert.match(
    apply,
    /next_payment_at=case[\s\S]+invoice\.payment_failed[\s\S]+v_next_attempt/i,
  );
});

test('v77 service-only event and command completion RPCs expose finite owner/SA readers', async () => {
  const sql = await read(sourcePath);
  for (const signature of [
    'ingest_stripe_billing_event_v77',
    'apply_stripe_billing_event_v77',
    'claim_billing_command_v77',
    'complete_billing_command_v77',
    'append_billing_adjustment_v77',
    'start_billing_reconciliation_v77',
    'finish_billing_reconciliation_v77',
  ]) {
    assert.match(
      sql,
      new RegExp(`grant execute on function public\\.${signature}[\\s\\S]+?to service_role`, 'i'),
    );
  }
  for (const reader of [
    'get_business_billing_v77',
    'get_platform_billing_v77',
    'get_billing_reconciliation_v77',
  ]) {
    assert.match(
      sql,
      new RegExp(`create or replace function public\\.${reader}[\\s\\S]+?returns jsonb`, 'i'),
    );
  }
  assert.match(sql, /limit 20/i);
  assert.match(sql, /p_limit not between 1 and 250/i);
  assert.match(sql, /p_limit not between 1 and 200/i);
});

test('v77 price catalog is versioned through SA preview-confirm and reports readiness', async () => {
  const sql = await read(sourcePath);
  const preview = functionBlock(sql, 'public', 'preview_billing_price_catalog_v77');
  const confirm = functionBlock(sql, 'public', 'confirm_billing_price_catalog_v77');
  assert.match(preview, /app\.is_super_admin\(\)/i);
  assert.match(preview, /confirmation_hash/i);
  assert.match(preview, /base_amount_cents/i);
  assert.match(preview, /per_seat_amount_cents/i);
  assert.match(preview, /tax_behavior/i);
  assert.match(confirm, /confirmation hash does not match preview/i);
  assert.match(confirm, /pg_advisory_xact_lock/i);
  assert.match(confirm, /set active=false,effective_to=p_effective_from/i);
  assert.match(confirm, /BILLING_PRICE_CATALOG_ACTIVATED_V77/i);
  assert.match(sql, /catalog_ready_cadences/i);
  assert.match(sql, /catalog_missing_cadences/i);
});

test('v77 synchronizes Stripe items and rejects cross-business provider relinking', async () => {
  const sql = await read(sourcePath);
  const apply = functionBlock(sql, 'public', 'apply_stripe_billing_event_v77');
  assert.match(apply, /provider_base_item_id=\(\s*select item\.provider_item_id/i);
  assert.match(apply, /provider_seat_item_id=\(/i);
  assert.match(apply, /provider_seat_quantity=coalesce\(\(/i);
  assert.match(apply, /Stripe customer is already linked to another business/i);
  assert.match(apply, /Stripe subscription is already linked to another business/i);
  assert.match(apply, /Stripe invoice is already linked to another business/i);
});

test('v77 billing commands use DB fingerprints and a real idempotent Stripe executor', async () => {
  const [sql, executor] = await Promise.all([
    read(sourcePath),
    read('supabase/functions/stripe-billing-command/index.ts'),
  ]);
  const request = functionBlock(sql, 'public', 'request_billing_command_v77');
  assert.match(request, /digest\(convert_to\(/i);
  assert.match(request, /idempotency key conflicts with another request/i);
  assert.match(executor, /authenticatedUserId\(req\)/);
  assert.match(executor, /billingPreflight\(req\)/);
  assert.match(executor, /billingCorsFor\(req\)/);
  assert.match(executor, /authentication_required/);
  assert.match(executor, /command_not_available/);
  assert.match(executor, /claim_billing_command_v130/);
  assert.match(executor, /provider_idempotency_key/);
  assert.match(executor, /stripe\.checkout\.sessions\.create/);
  assert.match(executor, /stripe\.billingPortal\.sessions\.create/);
  assert.doesNotMatch(executor, /stripe\.billingPortal\.sessions\.retrieve/);
  assert.match(executor, /portalRecoveryReplay/);
  assert.match(executor, /stripe\.subscriptions\.update/);
  assert.match(executor, /complete_billing_command_v77/);
  assert.match(executor, /proration_behavior: 'none'/);
  assert.doesNotMatch(executor, /invoice\.paid|paid_normalized/);
});

test('v77 webhook verifies the raw signed body before durable dispatch', async () => {
  const [webhook, shared, config] = await Promise.all([
    read('supabase/functions/stripe-billing-webhook/index.ts'),
    read('supabase/functions/_shared/billing-service.ts'),
    read('supabase/config.toml'),
  ]);
  assert.match(webhook, /npm:stripe@18\.5\.0/);
  assert.match(webhook, /const rawBody = await req\.text\(\)/);
  assert.match(webhook, /constructEventAsync\(\s*rawBody,\s*signature/i);
  assert.match(webhook, /STRIPE_WEBHOOK_SECRET/);
  assert.match(webhook, /ingest_stripe_billing_event_v77[\s\S]+apply_stripe_billing_event_v77/);
  assert.match(webhook, /durable: true/);
  assert.match(shared, /npm:@supabase\/supabase-js@2\.110\.7/);
  assert.match(shared, /SUPABASE_SECRET_KEYS[\s\S]+SUPABASE_SERVICE_ROLE_KEY/);
  assert.match(
    config,
    /\[functions\.stripe-billing-webhook\]\s+verify_jwt = false/,
  );
  assert.match(
    config,
    /\[functions\.stripe-billing-command\]\s+verify_jwt = true/,
  );
  assert.match(shared, /PUBLIC_GATEWAY_ALLOWED_ORIGINS/);
  assert.match(shared, /access-control-allow-origin/);
});

test('v77 adjustments and evidence are append-only compensating records', async () => {
  const sql = await read(sourcePath);
  assert.match(
    sql,
    /adjustment_type in \([\s\S]+'refund','chargeback'[\s\S]+'reversal'/i,
  );
  assert.match(sql, /reversal_of uuid references public\.billing_adjustments/i);
  assert.match(
    sql,
    /reversal must exactly compensate its referenced adjustment/i,
  );
  assert.match(
    sql,
    /billing_adjustments_one_reversal_uk/i,
  );
  assert.match(
    sql,
    /before update or delete on public\.billing_adjustments/i,
  );
  assert.match(sql, /before update or delete on public\.billing_evidence/i);
  assert.match(sql, /v_adjustment_total-v_adjustment_tax/i);
});

test('v77 rollback acceptance covers replay, stale delivery, paid truth, refund and command conflict', async () => {
  const rollback = await read('db/tests/v77_stripe_billing.sql');
  assert.match(rollback, /^begin;/m);
  assert.match(rollback, /^rollback;/m);
  for (const evidence of [
    'quarterly provider subscription was not normalized',
    'older subscription event regressed provider state',
    'annual Stripe year/1 cadence was not normalized to 12 months',
    'invoice.payment_failed created paid truth',
    'invoice.paid did not create normalized paid truth',
    'older failed event regressed normalized paid truth',
    'final paid invoice resurrected canceled subscription',
    'provider customer mismatch was not rejected',
    'exact event replay was not idempotent',
    'refund did not create separate GST-aware adjustment',
    'refund reversal did not restore the exact GST-aware amount',
    'price catalog confirmation did not activate a version',
    'billing command exact replay was not idempotent',
    'billing command changed replay was accepted',
  ]) {
    assert.match(rollback, new RegExp(evidence.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
});
