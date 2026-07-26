import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';

const root = new URL('../..', import.meta.url).pathname;
const read = path => readFile(join(root, path), 'utf8');
const sourcePath = 'db/migrations/20260726_nestly_v83_customer_intelligence.sql';
const canonicalPath = 'supabase/migrations/20260726180000_nestly_v83_customer_intelligence.sql';
const functionBlock = (sql,name) =>
  sql.match(new RegExp(`create or replace function public\\.${name}[\\s\\S]+?\\n\\$\\$;`,'i'))?.[0] || '';

test('v83 source and canonical customer intelligence migrations are byte-identical', async () => {
  const [source,canonical] = await Promise.all([read(sourcePath),read(canonicalPath)]);
  assert.equal(canonical,source);
  assert.match(source,/^-- NESTLY v83/m);
});

test('v83 is tenant, branch, Singapore-date and cutoff scoped', async () => {
  const sql = await read(sourcePath);
  const fn = functionBlock(sql,'get_customer_intelligence_v83');
  assert.match(fn,/app\.has_perm\(p_business,'view_finance'\)/i);
  assert.match(fn,/app\.can_see_branch\(p_business,p_branch\)/i);
  assert.match(fn,/branch\.id=p_branch and branch\.business_id=p_business/i);
  assert.match(fn,/now\(\) at time zone 'Asia\/Singapore'/i);
  assert.match(fn,/report_window_exceeds_five_years/i);
  assert.match(fn,/limit_must_be_between_1_and_500/i);
  assert.match(fn,/snapshot_cannot_be_in_the_future/i);
  assert.match(fn,/sale\.created_at<=v_snapshot_at/i);
  assert.match(fn,/payment\.created_at<=v_snapshot_at/i);
  assert.match(sql,/grant execute on function public\.get_customer_intelligence_v83[\s\S]+?to authenticated/i);
});

test('v83 returns complete period facts and lifetime inactivity as of p_to', async () => {
  const fn = functionBlock(await read(sourcePath),'get_customer_intelligence_v83');
  for (const key of [
    "'known_customers'","'active_customers'","'returning_customers'",
    "'returning_rate_pct'","'net_revenue_cents'","'cash_collected_cents'",
    "'average_revenue_per_active_customer_cents'","'average_purchase_frequency_days'",
    "'customers_over_90_days_inactive'"
  ]) assert.match(fn,new RegExp(key));
  for (const field of [
    'purchase_count','visit_count','period_first_purchase_at','period_last_purchase_at',
    'first_purchase_at','last_purchase_at','days_since_last_purchase',
    'lifetime_purchase_count','average_revenue_per_purchase_cents',
    'average_days_between_purchases'
  ]) assert.match(fn,new RegExp(`\\b${field}\\b`));
  assert.match(fn,/valid_period_purchases as materialized/i);
  assert.match(fn,/valid_lifetime_purchases as materialized/i);
  assert.match(fn,/sale\.occurred_at<v_to_ts/i);
  assert.match(fn,/p_to-\(lifetime\.last_purchase_at at time zone 'Asia\/Singapore'\)::date/i);
  assert.match(fn,/'returning_rate_denominator','Active customers/i);
});

test('v83 interactive pages use one immutable cutoff and complete keyset cursor', async () => {
  const fn = functionBlock(await read(sourcePath),'get_customer_intelligence_v83');
  assert.match(fn,/\(p_after_created_at is null\)<>\(p_after_client is null\)/i);
  assert.match(fn,/complete_customer_cursor_required/i);
  assert.match(fn,/\(customer\.customer_since,customer\.client_id\)\s*>\(p_after_created_at,p_after_client\)/i);
  assert.match(fn,/order by customer_since,client_id\s+limit p_limit/i);
  assert.match(fn,/'snapshot_at',v_snapshot_at/i);
  assert.match(fn,/'total_customers'/i);
  assert.match(fn,/'has_more'/i);
  assert.match(fn,/'next_cursor'/i);
  assert.match(fn,/'customer_since',customer_since,'client_id',client_id/i);
  assert.doesNotMatch(fn,/\boffset\b\s+p_offset/i);
  assert.doesNotMatch(fn,/'next_offset'/i);
});

test('v83 refuses to present a forecast before all validity thresholds are met', async () => {
  const fn = functionBlock(await read(sourcePath),'get_customer_intelligence_v83');
  assert.match(fn,/v_history_days<90/i);
  assert.match(fn,/v_active_weeks<12/i);
  assert.match(fn,/v_completed_transactions<30/i);
  assert.match(fn,/v_cash_observation_weeks<8/i);
  assert.match(fn,/'status','insufficient_data'/i);
  assert.match(fn,/'unmet_thresholds',v_unmet/i);
  assert.match(fn,/'forecast_eligible',v_forecast_eligible/i);
});

test('v83 forecast excludes a partial Singapore week and reports observed p20/mean/p80', async () => {
  const fn = functionBlock(await read(sourcePath),'get_customer_intelligence_v83');
  assert.match(fn,/extract\(isodow from p_to\)::integer=7/i);
  assert.match(fn,/v_forecast_start_date:=v_forecast_end_date-91/i);
  assert.match(fn,/percentile_cont\(0\.20\)/i);
  assert.match(fn,/percentile_cont\(0\.80\)/i);
  assert.match(fn,/trailing_13_complete_singapore_calendar_weeks_p20_mean_p80/i);
  assert.match(fn,/'partial_report_end_week_excluded'/i);
  assert.match(fn,/from public\.payments payment/i);
  assert.match(fn,/payment\.method not in \('credit','gift_card'\)/i);
  assert.match(fn,/'next_90_days'/i);
  assert.match(fn,/generate_series\(1,3\)/i);
  for (const key of ['lower_cents','expected_cents','upper_cents'])
    assert.match(fn,new RegExp(`'${key}'`));
  assert.match(fn,/not a guarantee/i);
});

test('v83 complete export materialises one snapshot and pages immutable rows', async () => {
  const sql = await read(sourcePath);
  const createExport = functionBlock(sql,'create_customer_intelligence_export_v83');
  const pageExport = functionBlock(sql,'get_customer_intelligence_export_page_v83');
  assert.match(sql,/create table public\.customer_intelligence_exports_v83/i);
  assert.match(sql,/create table public\.customer_intelligence_export_rows_v83/i);
  assert.match(sql,/alter table public\.customer_intelligence_exports_v83 enable row level security/i);
  assert.match(sql,/revoke all on table public\.customer_intelligence_export_rows_v83/i);
  assert.match(createExport,/v_snapshot timestamptz:=clock_timestamp\(\)/i);
  assert.match(createExport,/insert into public\.customer_intelligence_exports_v83/i);
  assert.match(createExport,/insert into public\.customer_intelligence_export_rows_v83/i);
  assert.match(createExport,/p_business,p_branch,p_from,p_to,500,v_snapshot/i);
  assert.match(createExport,/\(v_cursor->>'customer_since'\)::timestamptz/i);
  assert.match(createExport,/\(v_cursor->>'client_id'\)::uuid/i);
  assert.match(pageExport,/export\.requested_by=v_actor/i);
  assert.match(pageExport,/row\.ordinal>p_after_ordinal/i);
  assert.match(pageExport,/'next_ordinal'/i);
  assert.match(sql,/grant execute on function public\.create_customer_intelligence_export_v83[\s\S]+?to authenticated/i);
  assert.match(sql,/grant execute on function public\.get_customer_intelligence_export_page_v83[\s\S]+?to authenticated/i);
});

test('v83 reversal validity is frozen at the selected end and generated-at cutoff', async () => {
  const fn = functionBlock(await read(sourcePath),'get_customer_intelligence_v83');
  const validityChecks = [...fn.matchAll(/reversal\.reversal_of=sale\.id/g)].length;
  const endChecks = [...fn.matchAll(/reversal\.occurred_at<v_to_ts/g)].length;
  const cutoffChecks = [...fn.matchAll(/reversal\.created_at<=v_snapshot_at/g)].length;
  assert.ok(validityChecks >= 3);
  assert.ok(endChecks >= 3);
  assert.equal(cutoffChecks,validityChecks);
});
