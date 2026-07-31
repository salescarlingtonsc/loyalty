import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const read=path=>readFile(new URL(`../../${path}`,import.meta.url),'utf8');
const between=(source,start,end)=>source.slice(source.indexOf(start),source.indexOf(end));

test('v106 and v107 UI requests match the migration signatures and share one non-null cutoff',async()=>{
  const [v106,v107,index,revenue]=await Promise.all([
    read('supabase/migrations/20260729171008_nestly_v106_revenue_truth_foundation.sql'),
    read('supabase/migrations/20260729171010_nestly_v107_customer_lifecycle_contract.sql'),
    read('app/index.html'),
    read('app/revenue-truth.js')
  ]);
  assert.match(v106,/get_revenue_truth_v106\(\s*p_business uuid,\s*p_from date,\s*p_to date,\s*p_branch uuid default null,\s*p_as_of timestamptz default clock_timestamp\(\)/s);
  assert.match(v107,/get_customer_lifecycle_v107\(\s*p_business uuid,\s*p_from date,\s*p_to date,\s*p_branch uuid default null,\s*p_as_of timestamptz default clock_timestamp\(\)/s);

  const page=between(
    index,
    'async function customerIntelligencePage()',
    'async function reportsPage()'
  );
  assert.match(page,/const reportAsOf=new Date\(\)\.toISOString\(\)/);
  assert.match(page,/const truthRequest=\{\s*p_business:S\.biz\.id,\s*p_from:fromDate,\s*p_to:shiftSingaporeDate\(toDate,1\),\s*p_branch:selectedBranchId\|\|null,\s*p_as_of:reportAsOf\s*\}/s);
  assert.match(page,/get_revenue_truth_v106',truthRequest/);
  assert.match(page,/get_customer_lifecycle_v107',truthRequest/);
  assert.doesNotMatch(page,/p_as_of\s*:\s*null/);

  for(const key of [
    'known_revenue_minor',
    'identified_revenue_minor',
    'anonymous_revenue_minor',
    'completed_transactions',
    'identified_transactions',
    'anonymous_transactions',
    'itemized_transactions'
  ]){
    assert.match(v106,new RegExp(`'${key}'`));
    assert.match(revenue,new RegExp(`totals\\.${key}`));
  }
  for(const key of [
    'existing_customer_share_pct',
    'repeat_in_period_rate_pct',
    'existing_returning_customers',
    'repeat_purchasers_in_period',
    'reactivated_customers'
  ]){
    assert.match(v107,new RegExp(`'${key}'`));
    assert.match(revenue,new RegExp(`metrics\\.${key}`));
  }
  assert.doesNotMatch(revenue,/totals\.known_revenue_cents|metrics\.existing_customer_percentage|metrics\.repeat_rate_pct/);
});

test('v108 refresh uses the exact branch-scoped RPC and every visible state is implemented',async()=>{
  const [migration,index,growth]=await Promise.all([
    read('supabase/migrations/20260729171045_nestly_v108_measured_bringback_loop.sql'),
    read('app/index.html'),
    read('app/growth-offers.js')
  ]);
  assert.match(migration,/refresh_growth_recommendation_v108\(\s*p_business uuid,\s*p_branch uuid default null\s*\)/s);
  assert.match(growth,/invokeRpc\(rpc,'refresh_growth_recommendation_v108',\{\s*p_business:businessId,\s*p_branch:text\(branchId\)\|\|null\s*\}\)/s);
  assert.match(index,/data-growth-recommendation-refresh-mount/);
  assert.match(index,/bindRecommendationRefresh\(recommendationRefreshMount,\{/);
  assert.match(index,/businessId:S\.biz\.id,\s*branchId:selectedBranchId\|\|null,\s*onRefresh:run/s);
  assert.match(growth,/if\(mode==='loading'\)/);
  assert.match(growth,/if\(mode==='success'\)/);
  assert.match(growth,/\['disabled','permission','branch','error','validation','stale'\]\.includes\(mode\)/);
  assert.match(growth,/mode==='disabled'/);
  assert.match(growth,/mode==='error'/);
});

test('v109 UI calls all migration parameters and uses the server currency without an SGD fallback',async()=>{
  const [migration,index,sector]=await Promise.all([
    read('supabase/migrations/20260729171100_nestly_v109_economics_driver_sector_policy.sql'),
    read('app/index.html'),
    read('app/sector-economics.js')
  ]);
  assert.match(migration,/get_period_economics_v109\(\s*p_business uuid,\s*p_from date,\s*p_to date,\s*p_branch uuid default null,\s*p_investment_cents bigint default null,\s*p_investment_reference text default null,\s*p_as_of timestamptz default statement_timestamp\(\)\s*\)/s);
  assert.match(migration,/get_revenue_driver_decomposition_v109\(\s*p_business uuid,\s*p_current_from date,\s*p_current_to date,\s*p_comparison_from date,\s*p_comparison_to date,\s*p_branch uuid default null,\s*p_as_of timestamptz default statement_timestamp\(\)\s*\)/s);
  assert.match(migration,/get_effective_sector_policy_v109\(\s*p_business uuid,\s*p_policy_key text default 'lapse_detection',\s*p_as_of timestamptz default statement_timestamp\(\)\s*\)/s);

  const page=between(
    index,
    'async function customerIntelligencePage()',
    'async function reportsPage()'
  );
  assert.match(page,/p_from:fromDate,\s*p_to:shiftSingaporeDate\(toDate,1\),\s*p_branch:selectedBranchId\|\|null,\s*p_investment_cents:null,\s*p_investment_reference:null,\s*p_as_of:reportAsOf/s);
  assert.match(page,/p_current_from:fromDate,\s*p_current_to:shiftSingaporeDate\(toDate,1\),\s*p_comparison_from:comparisonFromDate,\s*p_comparison_to:fromDate,\s*p_branch:selectedBranchId\|\|null,\s*p_as_of:reportAsOf/s);
  assert.match(page,/p_policy_key:'lapse_detection',\s*p_as_of:reportAsOf/s);
  assert.match(page,/currency:String\(truthResponse\.data\?\.scope\?\.currency\|\|economicsResponse\.data\?\.profit\?\.currency\|\|''\)\.toUpperCase\(\)/);
  assert.doesNotMatch(sector,/currency\s*=\s*['"]SGD['"]/);
});

test('branch and heading composition regressions fail closed',async()=>{
  const [index,revenue,sector]=await Promise.all([
    read('app/index.html'),
    read('app/revenue-truth.js'),
    read('app/sector-economics.js')
  ]);
  const page=between(
    index,
    'async function customerIntelligencePage()',
    'async function reportsPage()'
  );
  assert.equal((page.match(/<h1/g)||[]).length,1);
  assert.equal((revenue.match(/<h1/g)||[]).length,0);
  assert.equal((sector.match(/<h1/g)||[]).length,0);
  assert.match(page,/branch does not belong to business\|branch is outside actor scope/);
  assert.match(page,/The selected branch is outside your current access/);
});
