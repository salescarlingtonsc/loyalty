import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const require=createRequire(import.meta.url);
const UI=require('../../app/sector-economics.js');
const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');
const sourcePath='db/migrations/20260730_nestly_v114_traceable_growth_costs.sql';
const mirrorPath='supabase/migrations/20260729211122_nestly_v114_traceable_growth_costs.sql';
const rollbackPath='db/tests/v114_traceable_growth_costs.sql';
const concurrencyPath='db/tests/v114_traceable_growth_costs_concurrency.sh';

test('v114 source and deploy migrations are exact forward-only mirrors',async()=>{
  const [source,mirror]=await Promise.all([read(sourcePath),read(mirrorPath)]);
  assert.equal(source,mirror);
  assert.match(source,/^-- NESTLY v114 — TRACEABLE BENEFIT AND DELIVERY ECONOMICS/m);
  assert.doesNotMatch(
    source,
    /drop\s+(?:table|function|schema)|disable\s+row\s+level\s+security/i
  );
});

test('v114 growth cost rules are effective-dated, sourced, branch-aware and RPC-only',async()=>{
  const source=await read(sourcePath);
  for(const field of[
    'cost_class','scope_key','cost_method','cost_value','source_type',
    'source_reference','evidence','effective_from','effective_to','version_no',
    'created_by','idempotency_key','request_hash'
  ]){
    assert.match(source,new RegExp(`\\b${field}\\b`,'i'),field);
  }
  assert.match(source,/cost_class in \('benefit','delivery'\)/i);
  assert.match(source,/provider_invoice[\s\S]*provider_contract/i);
  assert.match(source,/app\.v109_require_finance_scope\(p_business,p_branch\)/i);
  assert.match(source,/growth_cost_rules_v114_branch_business_fk/i);
  assert.match(source,/alter table public\.growth_cost_rules_v114 enable row level security/i);
  assert.match(source,/revoke all privileges on table public\.growth_cost_rules_v114[\s\S]*authenticated/i);
  assert.match(source,/grant execute on function public\.set_growth_cost_rule_v114[\s\S]*to authenticated/i);
  assert.doesNotMatch(source,/grant execute[\s\S]{0,300}to anon/i);
});

test('v114 writer locks request and scope before exact immutable receipt replay',async()=>{
  const source=await read(sourcePath);
  const fn=source.match(
    /create or replace function public\.set_growth_cost_rule_v114[\s\S]+?\nend \$\$;/i
  )?.[0]||'';
  const lockPair=fn.indexOf('app.v112_lock_pair');
  const receiptRead=fn.indexOf('app.v112_get_receipt');
  const receiptWrite=fn.indexOf('app.v112_put_receipt');
  assert.ok(lockPair>=0);
  assert.ok(receiptRead>lockPair);
  assert.ok(receiptWrite>receiptRead);
  assert.match(fn,/v114-growth-cost-request:/i);
  assert.match(fn,/v114-growth-cost-scope/i);
  assert.match(fn,/v_identity:=app\.v112_hash/i);
  assert.match(fn,/return v_receipt/i);
  assert.match(fn,/replayed',false/i);
  assert.doesNotMatch(fn,/replayed',true/i);
  assert.match(fn,/SET_GROWTH_COST_RULE_V114/i);
});

test('v114 concurrent writer regression proves one exact receipt and conflicts changed payloads',async()=>{
  const source=await read(concurrencyPath);
  assert.match(source,/V114_CONFIRM_DISPOSABLE_DB/);
  assert.match(source,/127\.0\.0\.1:54322/);
  assert.match(source,/cmp -s "\$work_dir\/first\.out" "\$work_dir\/replay\.out"/);
  assert.match(source,/"replayed": false/);
  assert.match(source,/count\(\*\) from public\.growth_cost_rules_v114/i);
  assert.match(source,/count\(\*\) from public\.concurrent_operation_receipts_v112/i);
  assert.match(source,/23505: idempotency key reused with a different request/i);
  assert.match(source,/V114 CONCURRENCY PASS/);
});

test('v114 line cost scopes admit product, service and package evidence',async()=>{
  const source=await read(sourcePath);
  assert.match(
    source,
    /scope_kind in \('sale_kind','product','service','package'\)/i
  );
  assert.match(
    source,
    /p_scope_kind not in \('sale_kind','product','service','package'\)/i
  );
  assert.match(source,/set_effective_cost_rule_v109_v112_inner/i);
  assert.match(source,/line cost scope must be a valid item UUID/i);
});

test('period economics is half-open and costs true sale_items without guessing',async()=>{
  const source=await read(sourcePath);
  const fn=source.match(
    /create or replace function public\.get_period_economics_v109[\s\S]+?\nend \$\$;/i
  )?.[0]||'';
  assert.match(
    fn,
    /app\.v106_sale_residual_minor\(\s*sale\.id,p_to,p_as_of\s*\)/i
  );
  assert.match(fn,/from public\.sale_items item/i);
  assert.match(fn,/item\.item_type='retail'[\s\S]*then 'product'/i);
  assert.match(fn,/item\.item_type='service'[\s\S]*then 'service'/i);
  assert.match(fn,/item\.item_type='package'[\s\S]*then 'package'/i);
  assert.match(fn,/allocation_remainder/i);
  assert.match(fn,/remainder_to_assign/i);
  assert.match(fn,/order by itemized_base\.allocation_remainder desc/i);
  assert.match(fn,/item\.line_cents>0/i);
  assert.match(fn,/sale\.amount_cents as sale_original_cents/i);
  assert.match(fn,/sale\.residual_cents as sale_residual_cents/i);
  assert.match(
    fn,
    /cost_value\*qty\*sale_residual_cents::numeric[\s\S]*greatest\(sale_original_cents,1\)/i
  );
  assert.doesNotMatch(
    fn,
    /cost_value\*qty\*allocated_cents[\s\S]{0,100}source_line_cents/i
  );
  assert.match(fn,/where not sale\.is_itemized/i);
  assert.match(fn,/ambiguous_traceable_sale_cost_rules/i);
  assert.match(fn,/'eligible_sale_lines',v_sale_lines/i);
  assert.match(fn,/'covered_sale_lines',v_covered_sale_lines/i);
  assert.match(fn,/'ambiguous_sale_lines',v_ambiguous_sale_lines/i);
  assert.match(fn,/from public\.growth_entitlements_v108 entitlement/i);
  assert.match(fn,/entitlement\.redeemed_at<=p_as_of/i);
  assert.match(fn,/entitlement\.reversed_at is null[\s\S]*entitlement\.reversed_at>p_as_of/i);
  assert.match(
    fn,
    /from public\.growth_entitlement_events_v108 event_row[\s\S]*event_row\.event_type='reversed'/i
  );
  assert.match(fn,/reversal_sale\.reversal_of=entitlement\.redeemed_sale_id/i);
  assert.match(fn,/event_row\.created_at<=p_as_of/i);
  assert.match(fn,/reversal_sale\.created_at<=p_as_of/i);
  assert.match(
    fn,
    /reversal_evidence\.occurred_at[\s\S]*at time zone reversal_contract\.timezone[\s\S]*::date>=p_to/i
  );
  assert.match(fn,/from public\.growth_delivery_dispatches_v110 dispatch/i);
  assert.match(fn,/dispatch\.delivered_at<=p_as_of/i);
  assert.match(fn,/candidate\.cost_class='benefit'/i);
  assert.match(fn,/candidate\.cost_class='delivery'/i);
  assert.match(fn,/sale_cost_coverage_passes/i);
  assert.match(fn,/benefit_cost_coverage_passes/i);
  assert.match(fn,/delivery_cost_coverage_passes/i);
  assert.match(fn,/incomplete_traceable_benefit_cost_coverage/i);
  assert.match(fn,/incomplete_traceable_delivery_cost_coverage/i);
  assert.match(fn,/contribution_after_growth_costs_cents/i);
  assert.match(fn,/traceable_growth_investment_cents/i);
  assert.match(fn,/descriptive and is not a causal increment claim/i);
});

test('v114 rollback fixtures prove discounted fixed COGS and period-aware benefit reversal',async()=>{
  const source=await read(rollbackPath);
  assert.match(source,/'Gross product line',1,10000,10000/i);
  assert.match(
    source,
    /'studio_discount'[\s\S]{0,160}'Discount: NDP 20 percent'[\s\S]{0,80}-2000,-2000/i
  );
  assert.match(source,/'fixed_per_unit',4000/i);
  assert.match(source,/traceable_cogs_cents[\s\S]{0,40}bigint<>4000/i);
  assert.match(source,/gross_profit_cents[\s\S]{0,40}bigint<>4000/i);
  assert.match(
    source,
    /post-period entitlement reversal rewrote prior economics/i
  );
  assert.match(
    source,
    /v_post_period_reversal[\s\S]*'2026-08-01 01:00\+00'/i
  );
  assert.match(
    source,
    /v_in_period_reversal[\s\S]*'2026-07-30 03:00\+00'/i
  );
  assert.match(source,/raise sqlstate 'ZX001'/i);
  assert.match(source,/eligible_redeemed_benefits[\s\S]{0,40}integer<>0/i);
  assert.match(source,/unavailable_reasons' \? 'no_eligible_sales'/i);
});

const v114Economics=(overrides={})=>({
  contract_version:'period_economics_v109',
  cost_contract_version:'growth_costs_v114',
  status:'ready',
  period:{from:'2026-07-01',to:'2026-08-01',basis:'business_local_date'},
  coverage:{
    cost_contract_version:'growth_costs_v114',
    eligible_sales:10,covered_sales:10,
    eligible_sale_lines:25,covered_sale_lines:25,ambiguous_sale_lines:0,
    transaction_coverage_bps:10000,
    eligible_revenue_cents:100000,covered_revenue_cents:100000,
    revenue_coverage_bps:10000,sale_cost_coverage_passes:true,
    eligible_redeemed_benefits:2,covered_redeemed_benefits:2,
    benefit_cost_coverage_bps:10000,benefit_cost_coverage_passes:true,
    eligible_deliveries:3,covered_deliveries:3,
    delivery_cost_coverage_bps:10000,delivery_cost_coverage_passes:true,
    traceable_cost_coverage_passes:true
  },
  profit:{
    currency:'SGD',revenue_cents:100000,traceable_cogs_cents:60000,
    gross_profit_before_growth_costs_cents:40000,
    traceable_benefit_cost_cents:1200,
    traceable_delivery_cost_cents:30,
    traceable_growth_cost_cents:1230,
    total_traceable_cost_cents:61230,
    contribution_after_growth_costs_cents:38770,
    gross_profit_cents:40000
  },
  roi:{
    investment_cents:1230,
    traceable_growth_investment_cents:1230,
    additional_investment_cents:0,
    investment_reference:'v114 traceable benefit and delivery cost rules',
    net_return_cents:38770,
    return_on_investment_bps:315203
  },
  unavailable_reasons:[],
  limitations:['this period result is descriptive and is not a causal increment claim'],
  ...overrides
});

test('v114 UI separates sale, benefit and delivery costs and shows contribution',()=>{
  const economics=UI.normalizeEconomics(v114Economics());
  assert.equal(economics.growthCostContract,true);
  assert.equal(economics.profit.available,true);
  assert.equal(economics.profit.traceableBenefitCostCents,1200);
  assert.equal(economics.profit.traceableDeliveryCostCents,30);
  assert.equal(economics.profit.contributionAfterGrowthCostsCents,38770);
  const html=UI.render(UI.buildViewModel({
    economics:v114Economics(),
    drivers:{},
    policy:{},
    requestState:'ready',
    currency:'SGD'
  }));
  assert.match(html,/Contribution with complete cost coverage/);
  assert.match(html,/Redeemed benefit cost/);
  assert.match(html,/Delivered message cost/);
  assert.match(html,/Contribution after growth costs/);
  assert.match(html,/2 of 2 redeemed benefits have traceable costs/);
  assert.match(html,/3 of 3 delivered messages have traceable provider costs/);
});

test('v114 UI withholds all financial conclusions when benefit or delivery coverage is incomplete',()=>{
  const payload=v114Economics({
    status:'insufficient_cost_coverage',
    coverage:{
      ...v114Economics().coverage,
      covered_redeemed_benefits:1,
      benefit_cost_coverage_bps:5000,
      benefit_cost_coverage_passes:false,
      covered_deliveries:2,
      delivery_cost_coverage_bps:6667,
      delivery_cost_coverage_passes:false,
      traceable_cost_coverage_passes:false
    },
    profit:null,
    roi:null,
    unavailable_reasons:[
      'incomplete_traceable_benefit_cost_coverage',
      'incomplete_traceable_delivery_cost_coverage'
    ]
  });
  const normalized=UI.normalizeEconomics(payload);
  assert.equal(normalized.profit.available,false);
  assert.equal(normalized.roi.available,false);
  const html=UI.render(UI.buildViewModel({
    economics:payload,drivers:{},policy:{},requestState:'ready',currency:'SGD'
  }));
  assert.match(html,/Profit and ROI are unavailable/);
  assert.match(html,/Every redeemed customer benefit needs an effective/);
  assert.match(html,/Every delivered message needs an effective provider-cost rule/);
  assert.doesNotMatch(html,/Contribution after growth costs/);
});
