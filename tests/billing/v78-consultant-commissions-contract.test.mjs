import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';

const root = new URL('../..', import.meta.url).pathname;
const read = (path) => readFile(join(root, path), 'utf8');
const sourcePath =
  'db/migrations/20260726_nestly_v78_consultant_commissions.sql';
const canonicalPath =
  'supabase/migrations/20260726130000_nestly_v78_consultant_commissions.sql';

const functionBlock = (sql, schema, name) =>
  sql.match(
    new RegExp(
      `create or replace function ${schema}\\.${name}[\\s\\S]+?\\n\\$\\$;`,
      'i',
    ),
  )?.[0] || '';

test('v78 source and canonical migrations are byte-identical', async () => {
  const [source, canonical] = await Promise.all([
    read(sourcePath),
    read(canonicalPath),
  ]);
  assert.equal(canonical, source);
  assert.match(source, /^-- NESTLY v78/m);
  assert.match(source, /commit;\s*$/);
});

test('v78 seeds exact base, retained-service bonus and renewal rules', async () => {
  const sql = await read(sourcePath);
  assert.match(
    sql,
    /\('senior',1,'-infinity',3000,1000,1500,[\s\S]+\('junior',1,'-infinity',2000,500,500/i,
  );
  assert.match(sql, /net_cash_collected_ex_gst_refunds_chargebacks/i);
  assert.match(sql, /setup_fee_included boolean not null default true/i);
  assert.match(
    sql,
    /v_invoice\.paid_at\s*<\s*v_attribution\.onboarding_started_at\+interval '12 months'/i,
  );
});

test('v78 is isolated from merchant tender and staff-sale commission domains', async () => {
  const sql = await read(sourcePath);
  assert.doesNotMatch(sql, /public\.sale_commission|public\.payments|public\.staff\b/i);
  assert.match(sql, /public\.billing_provider_invoices/i);
  assert.match(sql, /v_invoice\.net_cash_ex_tax_cents/i);
});

test('v78 attribution has a revoked internal core and an SA public wrapper for v79', async () => {
  const sql = await read(sourcePath);
  const core = functionBlock(sql, 'app', 'attribute_consultant_core_v78');
  const wrapper = functionBlock(sql, 'public', 'attribute_consultant_v78');
  assert.match(
    core,
    /prospect\.assigned_consultant_id=p_consultant[\s\S]+prospect\.converted_business_id=p_business/i,
  );
  assert.match(
    core,
    /consultant\.active[\s\S]+consultant\.departed_at is null/i,
  );
  assert.match(core, /consultant attribution conflicts with immutable history/i);
  assert.doesNotMatch(core, /app\.is_super_admin/i);
  assert.match(
    sql,
    /revoke all on function app\.attribute_consultant_core_v78[\s\S]+from public,anon,authenticated/i,
  );
  assert.match(wrapper, /app\.is_super_admin\(\)/i);
  assert.match(wrapper, /app\.attribute_consultant_core_v78\(/i);
});

test('v78 splits first-year cash into payable base and deferred anniversary components', async () => {
  const sql = await read(sourcePath);
  const accrue = functionBlock(sql, 'app', 'accrue_consultant_invoice_v78');
  assert.match(accrue, /paid_normalized and paid_at is not null/i);
  assert.match(accrue, /net_cash_ex_tax_cents/i);
  assert.match(accrue, /on conflict\(invoice_id,commission_phase\) do nothing/i);
  assert.match(accrue, /'first_year_base'/i);
  assert.match(accrue, /'anniversary_bonus'/i);
  assert.match(accrue, /v_attribution\.onboarding_started_at\+interval '12 months'/i);
  assert.match(accrue, /'renewal'/i);
  assert.match(accrue, /v_policy\.first_year_bps/i);
  assert.match(accrue, /v_policy\.anniversary_bonus_bps/i);
  assert.match(accrue, /v_policy\.renewal_bps/i);
  assert.match(sql, /consultant accrual snapshot is immutable/i);
});

test('v78 refund and chargeback corrections are capped append-only negatives', async () => {
  const sql = await read(sourcePath);
  const adjust = functionBlock(sql, 'app', 'adjust_consultant_commission_v78');
  assert.match(adjust, /adjustment_type in \('refund','chargeback'\)/i);
  assert.match(adjust, /for v_accrual in/i);
  assert.match(adjust, /greatest\(v_accrual\.basis_cents-v_prior_basis,0\)/i);
  assert.match(adjust, /greatest\(v_accrual\.commission_cents-v_prior_commission,0\)/i);
  assert.match(adjust, /-v_basis[\s\S]+-v_commission/i);
  assert.match(sql, /consultant_commission_adjustments_append_only/i);
});

test('v78 reversals append exact positive commission compensation', async () => {
  const sql = await read(sourcePath);
  const adjust = functionBlock(sql, 'app', 'adjust_consultant_commission_v78');
  assert.match(adjust, /adjustment_type in \('refund','chargeback','reversal'\)/i);
  assert.match(
    adjust,
    /commission_adjustment\.billing_adjustment_id=v_adjustment\.reversal_of/i,
  );
  assert.match(
    adjust,
    /'reversal',-v_reversed\.basis_adjustment_cents[\s\S]+-v_reversed\.commission_adjustment_cents/i,
  );
  assert.match(
    sql,
    /adjustment_type='reversal'[\s\S]+reversal_of is not null[\s\S]+basis_adjustment_cents > 0/i,
  );
});

test('v78 only approves anniversary bonus after one year and active employment recheck', async () => {
  const sql = await read(sourcePath);
  const approve = functionBlock(
    sql,
    'public',
    'approve_consultant_accrual_v78',
  );
  assert.match(
    approve,
    /consultant\.active and consultant\.departed_at is null[\s\S]+now\(\)>=accrual\.eligible_at/i,
  );
  assert.match(
    approve,
    /commission_phase<>'anniversary_bonus'[\s\S]+consultant_anniversary_qualified_v78/i,
  );
  const qualification = functionBlock(
    sql,
    'app',
    'consultant_anniversary_qualified_v78',
  );
  assert.match(qualification, /billing_provider='stripe'[\s\S]+paid_normalized/i);
  assert.match(qualification, /invoice\.paid_at>=p_anniversary/i);
  assert.match(qualification, /else subscription\.status='active'/i);
  assert.match(
    sql,
    /'anniversary_bonus'[\s\S]+v_attribution\.onboarding_started_at\+interval '12 months'/i,
  );
  assert.match(sql, /pending_anniversary_cents/i);
});

test('v78 departure atomically forfeits unpaid work while leaving paid history final', async () => {
  const sql = await read(sourcePath);
  const forfeit = functionBlock(sql, 'app', 'forfeit_consultant_core_v78');
  const compatibility = functionBlock(
    sql,
    'public',
    'platform_upsert_consultant_v75',
  );
  assert.match(
    sql,
    /active and departed_at is null[\s\S]+not active and departed_at is not null/i,
  );
  assert.match(forfeit, /set active=false,[\s\S]+departed_at=coalesce/i);
  assert.match(
    forfeit,
    /where consultant_id=p_consultant and status in \('accrued','approved'\)/i,
  );
  assert.match(forfeit, /'previously_paid_final',true/i);
  assert.match(
    compatibility,
    /if p_active is false then[\s\S]+app\.forfeit_consultant_core_v78/i,
  );
  assert.match(
    compatibility,
    /when p_active is true then null[\s\S]+when p_active is false then coalesce\(departed_at,now\(\)\)/i,
  );
});

test('v78 payout lines and partial payments are bounded by current net payable', async () => {
  const sql = await read(sourcePath);
  const addLine = functionBlock(
    sql,
    'public',
    'add_consultant_payout_line_v78',
  );
  const record = functionBlock(
    sql,
    'public',
    'record_consultant_payout_v78',
  );
  assert.match(addLine, /accrual\.status in \('approved','paid'\)/i);
  assert.match(addLine, /consultant\.active and consultant\.departed_at is null/i);
  assert.match(addLine, /p_amount_cents>greatest\(v_net-v_allocated,0\)/i);
  assert.match(record, /p_amount_cents>v_line\.amount_cents-v_line_paid/i);
  assert.match(record, /p_amount_cents>greatest\(v_net-v_accrual_paid,0\)/i);
  assert.match(record, /payment_reference/i);
  assert.match(record, /set status='paid'/i);
  assert.match(sql, /consultant_payout_payments_append_only/i);
});

test('v78 exposes only finite SA readers and RPC mutation surfaces', async () => {
  const sql = await read(sourcePath);
  for (const reader of [
    'get_consultant_commission_policies_v78',
    'get_consultant_commission_dashboard_v78',
  ]) {
    const block = functionBlock(sql, 'public', reader);
    assert.match(block, /app\.is_super_admin\(\)/i);
    assert.match(block, /returns jsonb/i);
  }
  assert.match(sql, /p_limit not between 1 and 250/i);
  assert.match(sql, /limit 50/i);
  assert.match(sql, /'payout_lines'/i);
  assert.match(sql, /paid_amount_cents/i);
  assert.match(sql, /remaining_cents/i);
  assert.match(sql, /recordable/i);
  assert.match(sql, /approval_eligible/i);
  assert.match(sql, /eligible_at/i);
  assert.match(
    sql,
    /revoke all privileges on table public\.consultant_commission_accruals from public, anon, authenticated/i,
  );
});

test('v78 rollback acceptance covers duplicate, anniversary, refund, chargeback, partial pay and forfeiture', async () => {
  const rollback = await read('db/tests/v78_consultant_commissions.sql');
  assert.match(rollback, /^begin;/m);
  assert.match(rollback, /^rollback;/m);
  for (const evidence of [
    'first-year senior base accrual was not 30% of net cash ex GST',
    'senior anniversary accrual was not deferred 10%',
    'duplicate paid invoice changed the two-component accrual',
    '12-month anniversary did not use the 15% renewal rate',
    'refund did not reduce the first-year base component',
    'refund did not reduce the deferred anniversary component',
    'refund reversal did not append exact positive commission compensation',
    'chargeback did not cap both commission components',
    'dashboard omitted recordable partial payout line',
    'partial payout exceeded or skipped bounded lifecycle',
    'v75 deactivation bypassed consultant forfeiture',
    'previously paid consultant commission was not final',
    'future paid invoice was not forfeited to Nestly',
  ]) {
    assert.match(rollback, new RegExp(evidence.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
});
