import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');
const sourcePath='db/migrations/20260729_nestly_v109_economics_driver_sector_policy.sql';
const mirrorPath='supabase/migrations/20260729171100_nestly_v109_economics_driver_sector_policy.sql';

test('v109 source and canonical migrations are exact forward-only mirrors',async()=>{
  const [source,mirror]=await Promise.all([read(sourcePath),read(mirrorPath)]);
  assert.equal(source,mirror);
  assert.match(source,/^-- NESTLY v109 — TRACEABLE ECONOMICS/m);
  assert.doesNotMatch(
    source,
    /drop\s+(?:table|function|schema)|disable\s+row\s+level\s+security/i
  );
  assert.match(
    source,
    /values\('economics_driver_policy_v109',false\)[\s\S]*on conflict\(feature_key\) do nothing/i
  );
});

test('v109 cost rules are effective-dated, source referenced and finance gated',async()=>{
  const source=await read(sourcePath);
  for(const field of[
    'cost_method','cost_value','source_type','source_reference','evidence',
    'effective_from','effective_to','version_no','created_by','idempotency_key'
  ]){
    assert.match(source,new RegExp(`\\b${field}\\b`,'i'),field);
  }
  assert.match(source,/app\.v109_require_finance\(p_business\)/i);
  assert.match(source,/app\.has_perm\(p_business,'view_finance'\)/i);
  assert.match(source,/cost rules must be appended in effective-time order/i);
  assert.match(source,/SET_EFFECTIVE_COST_RULE_V109/i);
  assert.match(source,/supplier_invoice[\s\S]*supplier_contract[\s\S]*accounting_import/i);
});

test('profit and ROI fail closed until traceable coverage and investment pass',async()=>{
  const source=await read(sourcePath);
  const fn=source.match(
    /create or replace function public\.get_period_economics_v109[\s\S]+?\nend \$\$;/i
  )?.[0]||'';
  assert.match(fn,/v_covered_sales=v_sales/i);
  assert.match(fn,/v_covered_revenue=v_revenue/i);
  assert.match(fn,/incomplete_traceable_cost_coverage/i);
  assert.match(fn,/'profit',case when v_coverage_passes/i);
  assert.match(fn,/'roi',case when v_roi_bps is not null/i);
  assert.match(fn,/traceable_investment_not_provided/i);
  assert.match(fn,/positive_traceable_investment_required/i);
  assert.match(fn,/descriptive and is not a causal increment claim/i);
  assert.match(fn,/p_from date[\s\S]*p_to date[\s\S]*p_as_of timestamptz/i);
  assert.match(fn,/app\.v106_reporting_contract/i);
  assert.match(fn,/created_at<=p_as_of/i);
  assert.match(fn,/at time zone contract\.timezone\)::date>=p_from/i);
  assert.match(fn,/app\.v106_sale_residual_minor\(s\.id,p_as_of\)/i);
  assert.match(fn,/cross-currency reporting periods are not supported/i);
});

test('driver decomposition is deterministic and explicitly reconciles rounding',async()=>{
  const source=await read(sourcePath);
  const fn=source.match(
    /create or replace function public\.get_revenue_driver_decomposition_v109[\s\S]+?\nend \$\$;/i
  )?.[0]||'';
  assert.match(fn,/identified_customer_count_cents/i);
  assert.match(fn,/purchase_frequency_cents/i);
  assert.match(fn,/average_transaction_value_cents/i);
  assert.match(fn,/anonymous_revenue_cents/i);
  assert.match(fn,/d_residual:=d_total-d_customer-d_frequency-d_aov-d_anonymous/i);
  assert.match(fn,/sum_driver_contributions_cents/i);
  assert.match(fn,/'reconciles',case when v_available then d_sum=d_total else null end/i);
  assert.match(fn,/'deterministic',true/i);
  assert.match(fn,/'causal_claim',false/i);
  assert.match(fn,/comparison_period_has_no_identified_customer_base/i);
  assert.match(fn,/p_current_from date[\s\S]*p_comparison_from date[\s\S]*p_as_of timestamptz/i);
  assert.match(fn,/app\.v106_reporting_contract/i);
  assert.match(fn,/app\.v106_sale_residual_minor\(s\.id,p_as_of\)/i);
  assert.match(fn,/cross-currency driver comparisons are not supported/i);
});

test('sector policy registry covers required SME sectors, is evidence-led and never universal',async()=>{
  const source=await read(sourcePath);
  for(const sector of[
    'fnb','salon','facial','massage','fitness','retail','other'
  ]){
    assert.match(source,new RegExp(`'${sector}','lapse_detection'`,'i'),sector);
  }
  for(const field of[
    'evidence_basis','fallback_policy','suppression_rules','limitations',
    'effective_from','effective_to','version_no'
  ]){
    assert.match(source,new RegExp(`\\b${field}\\b`,'i'),field);
  }
  assert.match(source,/No universal salon or spa churn threshold is asserted/i);
  assert.match(source,/No universal massage or wellness churn threshold is inferred/i);
  assert.match(source,/No cross-sector churn number is supplied/i);
  assert.match(source,/'universal_churn_number',null/i);
  assert.match(source,/'requires_local_evidence',true/i);
  assert.match(source,/unknown_service_cadence/i);
  assert.match(source,/membership_state_unknown/i);
  assert.match(source,/product_cycle_unknown/i);
  assert.match(source,/sector_not_specialized/i);
  assert.match(source,/app\.v109_sector_source_availability/i);
  assert.match(source,/public\.appointments[\s\S]*appointment\.service_id is not null/i);
  assert.match(source,/public\.sale_items[\s\S]*item\.item_type='retail'/i);
  assert.match(source,/public\.memberships[\s\S]*membership\.status in/i);
});

test('owner overrides are bounded, versioned, idempotent and audited',async()=>{
  const source=await read(sourcePath);
  const fn=source.match(
    /create or replace function public\.set_business_sector_policy_override_v109[\s\S]+?\nend \$\$;/i
  )?.[0]||'';
  assert.match(fn,/app\.is_salon_owner\(p_business\)/i);
  assert.match(fn,/minimum_prior_visits[\s\S]*between 2 and 20/i);
  assert.match(fn,/cadence_multiplier[\s\S]*between 1\.10 and 5\.00/i);
  assert.match(fn,/minimum_lapse_days[\s\S]*between 3 and 365/i);
  assert.match(fn,/minimum_audience[\s\S]*between 10 and 5000/i);
  assert.match(fn,/jsonb_typeof\(p_override_parameters->'minimum_prior_visits'\)<>'number'/i);
  assert.match(fn,/jsonb_typeof\(p_override_parameters->'cadence_multiplier'\)<>'number'/i);
  assert.match(fn,/jsonb_typeof\(p_override_parameters->'minimum_lapse_days'\)<>'number'/i);
  assert.match(fn,/jsonb_typeof\(p_override_parameters->'minimum_audience'\)<>'number'/i);
  assert.match(fn,/idempotency_key=p_idempotency_key/i);
  assert.match(fn,/overrides must be appended in effective-time order/i);
  assert.match(fn,/SET_SECTOR_POLICY_OVERRIDE_V109/i);
});

test('browser mutation is RPC-only behind RLS and explicit grants',async()=>{
  const source=await read(sourcePath);
  for(const table of[
    'economic_cost_rules_v109',
    'sector_policy_versions_v109',
    'business_sector_policy_overrides_v109'
  ]){
    assert.match(
      source,
      new RegExp(`alter table public\\.${table} enable row level security`,'i'),
      table
    );
  }
  assert.match(
    source,
    /revoke all privileges on table[\s\S]*economic_cost_rules_v109[\s\S]*business_sector_policy_overrides_v109[\s\S]*from public,anon,authenticated/i
  );
  assert.match(source,/grant execute on function public\.get_period_economics_v109[\s\S]*to authenticated/i);
  assert.match(source,/grant execute on function public\.get_effective_sector_policy_v109[\s\S]*to authenticated/i);
  assert.doesNotMatch(source,/grant execute[\s\S]{0,300}to anon/i);
});
