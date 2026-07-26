import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';

const root = new URL('../..', import.meta.url).pathname;
const read = path => readFile(join(root,path),'utf8');
const sourcePath='db/migrations/20260726_nestly_v82_enterprise_intelligence.sql';
const canonicalPath='supabase/migrations/20260726170000_nestly_v82_enterprise_intelligence.sql';
const functionBlock=(sql,name)=>
  sql.match(new RegExp(`create or replace function public\\.${name}[\\s\\S]+?\\n\\$\\$;`,'i'))?.[0]||'';

test('v82 source and canonical migrations are byte-identical',async()=>{
  const [source,canonical]=await Promise.all([read(sourcePath),read(canonicalPath)]);
  assert.equal(canonical,source);
  assert.match(source,/^-- NESTLY v82/m);
});

test('v82 exposes three super-admin-only snapshot read contracts',async()=>{
  const sql=await read(sourcePath);
  for(const name of [
    'platform_get_enterprise_hierarchy_v82',
    'platform_list_enterprise_customers_v82',
    'platform_generate_improvement_report_v82'
  ]){
    const fn=functionBlock(sql,name);
    assert.match(fn,/if not app\.is_super_admin\(\)/i);
    assert.match(fn,/v_snapshot_at timestamptz:=coalesce\(p_snapshot_at,clock_timestamp\(\)\)/i);
    assert.match(fn,/snapshot_cannot_be_in_the_future/i);
    assert.match(sql,new RegExp(`grant execute on function public\\.${name}[\\s\\S]+?to authenticated`,'i'));
  }
  assert.match(sql,/revoke all on function public\.platform_list_enterprise_customers_v82[\s\S]+?from public,anon,authenticated/i);
});

test('firm and customer lists have total, has-more and complete immutable keysets',async()=>{
  const sql=await read(sourcePath);
  const firms=functionBlock(sql,'platform_get_enterprise_hierarchy_v82');
  const customers=functionBlock(sql,'platform_list_enterprise_customers_v82');
  assert.match(firms,/\(business\.created_at,business\.id\)>\(p_after_created_at,p_after_business\)/i);
  assert.match(firms,/complete_firm_cursor_required/i);
  assert.match(firms,/'total_firms'/i);
  assert.match(firms,/'has_more'/i);
  assert.match(firms,/'next_cursor'/i);
  assert.doesNotMatch(firms,/p_customer_limit/i);
  assert.match(customers,/\(client\.created_at,client\.id\)>\(p_after_created_at,p_after_client\)/i);
  assert.match(customers,/complete_customer_cursor_required/i);
  assert.match(customers,/'total_customers'/i);
  assert.match(customers,/'has_more'/i);
  assert.match(customers,/'next_cursor'/i);
  assert.doesNotMatch(customers,/\boffset\b/i);
});

test('hierarchy branches expose active assigned staff and report firms expose returning customers',async()=>{
  const sql=await read(sourcePath);
  const firms=functionBlock(sql,'platform_get_enterprise_hierarchy_v82');
  const report=functionBlock(sql,'platform_generate_improvement_report_v82');
  assert.match(firms,/'staff_count',\(/i);
  assert.match(firms,/from public\.staff_branches staff_branch/i);
  assert.match(firms,/staff_branch\.business_id=business\.id/i);
  assert.match(firms,/staff_branch\.branch_id=branch\.id/i);
  assert.match(firms,/staff\.active/i);
  assert.match(firms,/staff\.created_at<=v_snapshot_at/i);
  assert.match(report,/business_metrics as materialized[\s\S]+?customer\.visit_count>=2\)::integer returning_customers/i);
});

test('one search rule scopes firm, branch, customer and transaction results',async()=>{
  const sql=await read(sourcePath);
  for(const name of [
    'platform_get_enterprise_hierarchy_v82',
    'platform_list_enterprise_customers_v82',
    'platform_generate_improvement_report_v82'
  ]){
    const fn=functionBlock(sql,name);
    assert.match(fn,/v_search text:=nullif\(btrim\(p_search\),''\)/i);
    assert.match(fn,/business\.name ilike '%'\\|\\|v_search\\|\\|'%'/i);
    assert.match(fn,/branch\.name ilike '%'\\|\\|v_search\\|\\|'%'/i);
    assert.match(fn,/client\.full_name ilike '%'\\|\\|v_search\\|\\|'%'/i);
    assert.match(fn,/search_all/i);
  }
  assert.match(functionBlock(sql,'platform_generate_improvement_report_v82'),/'search',v_search/i);
});

test('report never totals money across unlike currencies',async()=>{
  const report=functionBlock(await read(sourcePath),'platform_generate_improvement_report_v82');
  assert.match(report,/currency_metrics as materialized/i);
  assert.match(report,/'currency_mode'/i);
  assert.match(report,/'summary_by_currency'/i);
  assert.match(report,/case when \(select count\(\*\) from currency_metrics\)=1[\s\S]+?net_revenue_cents/i);
  assert.match(report,/'currency','money aggregates are calculated independently by currency'/i);
  assert.match(report,/monthly\.month_start,monthly\.currency|metric\.month_start,metric\.currency/i);
  assert.match(report,/revenue_momentum_by_currency/i);
});

test('period metrics and lifetime-as-of inactivity stay distinct',async()=>{
  const sql=await read(sourcePath);
  const customers=functionBlock(sql,'platform_list_enterprise_customers_v82');
  const report=functionBlock(sql,'platform_generate_improvement_report_v82');
  for(const fn of [customers,report]){
    assert.match(fn,/lifetime\.first_purchase_at/i);
    assert.match(fn,/lifetime\.last_purchase_at/i);
    assert.match(fn,/p_to-\(lifetime\.last_purchase_at at time zone 'Asia\/Singapore'\)::date/i);
    assert.match(fn,/sale\.occurred_at<v_to_ts/i);
  }
  assert.match(customers,/period_first_purchase_at/i);
  assert.match(customers,/period_last_purchase_at/i);
  assert.match(report,/'returning_rate_denominator','customers with at least one visit in the selected period'/i);
});

test('v82 uses Singapore defaults and report carries no truncated customer preview',async()=>{
  const sql=await read(sourcePath);
  assert.match(sql,/now\(\) at time zone 'Asia\/Singapore'/i);
  const report=functionBlock(sql,'platform_generate_improvement_report_v82');
  assert.match(report,/'customer_total'/i);
  assert.doesNotMatch(report,/'customers',coalesce/i);
  assert.doesNotMatch(report,/p_customer_limit/i);
});
