import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const require=createRequire(import.meta.url);
const UI=require('../../app/sector-economics.js');
const read=path=>readFile(new URL(`../../${path}`,import.meta.url),'utf8');

test('V134 converts the actual V109 policy payload before the UI renders it',async()=>{
  const [v109,v134]=await Promise.all([
    read('db/migrations/20260729_nestly_v109_economics_driver_sector_policy.sql'),
    read('db/migrations/20260802_nestly_v134_peekaa_brand_legal.sql')
  ]);
  assert.equal((v109.match(/Nestly pilot starting policy/g)||[]).length,6);
  assert.match(v134,/'Nestly pilot starting policy',\s*\n\s*'Peekaa pilot starting policy'/);
  assert.match(v134,/unexpected legacy row count/);
});

test('economics overrides never use Math.random for authoritative request identifiers',async()=>{
  const source=await read('app/sector-economics.js');
  assert.doesNotMatch(source,/Math\.random/);
  assert.match(source,/crypto\.randomUUID/);
  assert.match(source,/crypto\.getRandomValues/);
});

const economics=(overrides={})=>({
  contract_version:'period_economics_v109',
  status:'ready',
  period:{start:'2026-07-01T00:00:00Z',end:'2026-08-01T00:00:00Z'},
  coverage:{
    eligible_sales:10,covered_sales:10,transaction_coverage_bps:10000,
    eligible_revenue_cents:100000,covered_revenue_cents:100000,
    revenue_coverage_bps:10000,traceable_cost_coverage_passes:true
  },
  profit:{
    currency:'SGD',revenue_cents:100000,traceable_cogs_cents:60000,
    gross_profit_cents:40000
  },
  roi:null,
  unavailable_reasons:['traceable_investment_not_provided'],
  limitations:[
    'gross profit is returned only at complete traceable cost coverage',
    'this period result is descriptive and is not a causal increment claim'
  ],
  ...overrides
});

const drivers=(overrides={})=>({
  contract_version:'revenue_driver_decomposition_v109',
  status:'ready',
  unavailable_reason:null,
  periods:{
    comparison:{
      revenue_cents:90000,identified_customers:8,identified_transactions:12,
      transactions:12,itemized_transactions:6,itemized_revenue_cents:45000
    },
    current:{
      revenue_cents:91000,identified_customers:9,identified_transactions:14,
      transactions:14,itemized_transactions:12,itemized_revenue_cents:72800
    }
  },
  coverage:{
    comparison_identified_revenue_bps:9000,
    current_identified_revenue_bps:9100,
    comparison_itemized_transaction_bps:5000,
    current_itemized_transaction_bps:8571,
    comparison_itemized_revenue_bps:5000,
    current_itemized_revenue_bps:8000,
    anonymous_revenue_is_separate_driver:true
  },
  line_item_analysis:{
    status:'coverage_only',
    price_volume_mix_status:'not_claimed',
    reason:'line-level price and mix effects require complete itemization and a versioned taxonomy',
    causal_claim:false
  },
  drivers:{
    identified_customer_count_cents:500,
    purchase_frequency_cents:400,
    average_transaction_value_cents:300,
    anonymous_revenue_cents:-100,
    rounding_residual_cents:-100
  },
  reconciliation:{
    period_revenue_delta_cents:1000,
    sum_driver_contributions_cents:1000,
    rounding_residual_cents:-100,
    reconciles:true
  },
  method:{deterministic:true,causal_claim:false},
  ...overrides
});

const policy=(overrides={})=>({
  contract_version:'effective_sector_policy_v109',
  business_id:'business-1',
  requested_sector:'facial',
  resolved_sector:'facial',
  used_fallback_sector:false,
  policy_key:'lapse_detection',
  base_policy:{
    id:'policy-1',version_no:1,effective_from:'2026-07-29T00:00:00Z',
    evidence_basis:[
      'Peekaa pilot starting policy; treatment intervals must be checked against each firm',
      'No universal salon or spa churn threshold is asserted'
    ],
    parameters:{
      minimum_prior_visits:3,cadence_multiplier:1.5,
      minimum_lapse_days:30,minimum_audience:20
    },
    fallback_policy:{
      when:'individual_cadence_unavailable',
      action:'suppress_until_service_history_is_sufficient'
    },
    suppression_rules:[
      'insufficient_history','unknown_service_cadence',
      'low_identity_coverage','audience_below_minimum'
    ],
    limitations:['service plans and treatment cycles differ','owner must review before activation']
  },
  owner_override:null,
  effective_parameters:{
    minimum_prior_visits:3,cadence_multiplier:1.5,
    minimum_lapse_days:30,minimum_audience:20
  },
  universal_churn_number:null,
  requires_local_evidence:true,
  ...overrides
});

test('economics withholds profit and ROI unless complete traceable cost coverage passes',()=>{
  const partial=economics({
    status:'insufficient_cost_coverage',
    coverage:{
      eligible_sales:10,covered_sales:7,transaction_coverage_bps:7000,
      eligible_revenue_cents:100000,covered_revenue_cents:70000,
      revenue_coverage_bps:7000,traceable_cost_coverage_passes:false
    },
    profit:null,roi:null,
    unavailable_reasons:['incomplete_traceable_cost_coverage','traceable_investment_not_provided']
  });
  const view=UI.buildViewModel({economics:partial,drivers:drivers(),policy:policy(),role:'owner'});
  const html=UI.render(view);
  assert.equal(view.economics.profit.available,false);
  assert.equal(view.economics.roi.available,false);
  assert.match(html,/Profit and ROI are unavailable/);
  assert.match(html,/Peekaa will not estimate missing costs/);
  assert.match(html,/70%/);
  assert.doesNotMatch(html,/Gross profit with complete cost coverage/);
});

test('missing cost-coverage counts remain unavailable instead of becoming zero',()=>{
  const missing=economics({
    status:'insufficient_cost_coverage',
    coverage:{
      eligible_sales:10,covered_sales:null,transaction_coverage_bps:null,
      eligible_revenue_cents:100000,covered_revenue_cents:null,
      revenue_coverage_bps:null,traceable_cost_coverage_passes:false
    },
    profit:null,roi:null,
    unavailable_reasons:['incomplete_traceable_cost_coverage']
  });
  const html=UI.render(UI.buildViewModel({
    economics:missing,drivers:drivers(),policy:policy(),role:'owner'
  }));
  assert.match(html,/Coverage not available/);
  assert.match(html,/Not available/);
  assert.doesNotMatch(html,/0 of 10 eligible sales/);
});

test('gross profit may render after coverage passes while ROI remains explicitly unavailable',()=>{
  const view=UI.buildViewModel({economics:economics(),drivers:drivers(),policy:policy()});
  const html=UI.render(view);
  assert.equal(view.economics.profit.available,true);
  assert.equal(view.economics.roi.available,false);
  assert.match(html,/Gross profit with complete cost coverage/);
  assert.match(html,/SGD 400\.00/);
  assert.match(html,/Period ROI/);
  assert.match(html,/Unavailable/);
  assert.doesNotMatch(html,/return on investment is positive|profitable campaign/i);
});

test('the three largest quantified drivers plus residual reconcile exactly',()=>{
  const normalized=UI.normalizeDrivers(drivers());
  assert.equal(normalized.available,true);
  assert.deepEqual(normalized.topDrivers.map(item=>item.cents),[500,400,300]);
  assert.equal(normalized.residual.cents,-200);
  assert.equal(
    normalized.topDrivers.reduce((sum,item)=>sum+item.cents,0)+normalized.residual.cents,
    normalized.deltaCents
  );
  const html=UI.render(UI.buildViewModel({
    economics:economics(),drivers:drivers(),policy:policy()
  }));
  assert.match(html,/1\. Identified customer base/);
  assert.match(html,/2\. Purchase frequency/);
  assert.match(html,/3\. Spend per transaction/);
  assert.match(html,/Residual/);
  assert.match(html,/equal[\s\S]*exactly/);
  assert.match(html,/not proof that one factor caused another/);
});

test('supported v113 line-item evidence shows current and comparison transaction and revenue coverage',()=>{
  const supported=drivers({
    line_item_analysis:{
      status:'supported',
      price_volume_mix_status:'supported',
      reason:'',
      causal_claim:false
    }
  });
  const normalized=UI.normalizeDrivers(supported);
  assert.deepEqual(normalized.lineItemCoverage.current,{
    transactions:14,
    itemizedTransactions:12,
    transactionCoverageBps:8571,
    revenueCents:91000,
    itemizedRevenueCents:72800,
    revenueCoverageBps:8000
  });
  assert.equal(normalized.lineItemAnalysis.status,'supported');
  assert.equal(normalized.lineItemAnalysis.priceVolumeMixStatus,'supported');
  const html=UI.render(UI.buildViewModel({
    economics:economics(),drivers:supported,policy:policy()
  }));
  assert.match(html,/Itemized transaction and revenue coverage/);
  assert.match(html,/Current period[\s\S]*85\.71%[\s\S]*12 of 14 transactions itemized/);
  assert.match(html,/SGD 728\.00 of SGD 910\.00 revenue itemized/);
  assert.match(html,/Comparison period[\s\S]*50%[\s\S]*6 of 12 transactions itemized/);
  assert.match(html,/SGD 450\.00 of SGD 900\.00 revenue itemized/);
  assert.match(html,/record completeness[\s\S]*does not by itself establish why revenue changed/);
});

test('zero-activity v113 line-item evidence renders an explicit empty state without a false zero percent',()=>{
  const zero=drivers({
    status:'unavailable',
    unavailable_reason:'current_period_has_no_revenue',
    periods:{
      comparison:{
        revenue_cents:0,identified_customers:0,identified_transactions:0,
        transactions:0,itemized_transactions:0,itemized_revenue_cents:0
      },
      current:{
        revenue_cents:0,identified_customers:0,identified_transactions:0,
        transactions:0,itemized_transactions:0,itemized_revenue_cents:0
      }
    },
    coverage:{
      comparison_identified_revenue_bps:null,
      current_identified_revenue_bps:null,
      comparison_itemized_transaction_bps:null,
      current_itemized_transaction_bps:null,
      comparison_itemized_revenue_bps:null,
      current_itemized_revenue_bps:null,
      anonymous_revenue_is_separate_driver:true
    },
    drivers:null,
    reconciliation:{
      period_revenue_delta_cents:0,
      sum_driver_contributions_cents:null,
      rounding_residual_cents:null,
      reconciles:null
    }
  });
  const html=UI.render(UI.buildViewModel({
    economics:economics(),drivers:zero,policy:policy()
  }));
  assert.match(html,/Current period[\s\S]*No activity[\s\S]*No recorded transactions/);
  assert.match(html,/No recorded revenue/);
  assert.match(html,/Comparison period[\s\S]*No activity/);
  assert.doesNotMatch(html,/0%|0 of 0/);
});

test('v113 not_claimed line-item state explicitly withholds product price, volume and mix attribution',()=>{
  const html=UI.render(UI.buildViewModel({
    economics:economics(),drivers:drivers(),policy:policy()
  }));
  assert.match(
    html,
    /Product price, volume and mix are not attributed for this comparison\./
  );
  assert.match(
    html,
    /does not\s+show that a product, price, volume or mix change caused the revenue change/
  );
  assert.doesNotMatch(
    html,
    /product mix (?:caused|drove|explains)|price change (?:caused|drove|explains)/i
  );
});

test('a non-reconciling backend bridge is withheld rather than repaired in the browser',()=>{
  const broken=drivers({
    reconciliation:{
      period_revenue_delta_cents:1001,
      sum_driver_contributions_cents:1000,
      rounding_residual_cents:-100,
      reconciles:false
    }
  });
  const view=UI.buildViewModel({economics:economics(),drivers:broken,policy:policy()});
  assert.equal(view.drivers.available,false);
  assert.match(UI.render(view),/Revenue drivers are unavailable/);
  assert.doesNotMatch(UI.render(view),/1\. Identified customer base/);
});

test('sector policy is plain-language, versioned, evidence-based and owner override is progressive',()=>{
  const view=UI.buildViewModel({
    economics:economics(),drivers:drivers(),policy:policy(),role:'owner'
  });
  const html=UI.render(view);
  assert.match(html,/When to consider a customer overdue/);
  assert.match(html,/Version 1/);
  assert.match(html,/Minimum prior visits/);
  assert.match(html,/3 visits/);
  assert.match(html,/When a customer’s usual visit interval cannot be calculated/);
  assert.match(html,/When Peekaa suppresses this/);
  assert.match(html,/Peekaa does not supply a universal churn number/);
  assert.match(html,/<details class="sector-policy-override">/);
  assert.match(html,/Reason for this change/);

  const manager=UI.render(UI.buildViewModel({
    economics:economics(),drivers:drivers(),policy:policy(),role:'manager'
  }));
  assert.doesNotMatch(manager,/Customize this starting policy/);
});

test('massage is treated as a supported sector and existing owner override is clearly disclosed',()=>{
  const view=UI.buildViewModel({
    economics:economics(),
    drivers:drivers(),
    policy:policy({
      requested_sector:'massage',resolved_sector:'massage',used_fallback_sector:false,
      owner_override:{
        id:'override-1',version_no:2,reason:'Observed 45-day treatment cycle',
        effective_from:'2026-07-30T00:00:00Z'
      },
      effective_parameters:{
        minimum_prior_visits:4,cadence_multiplier:2,
        minimum_lapse_days:45,minimum_audience:20
      }
    }),
    role:'owner'
  });
  const html=UI.render(view);
  assert.doesNotMatch(html,/No reviewed policy matched/);
  assert.match(html,/Owner override version 2/);
  assert.match(html,/Observed 45-day treatment cycle/);
});

test('unknown-sector fallback renders the exact server suppression reason without inventing a benchmark',()=>{
  const view=UI.buildViewModel({
    economics:economics(),
    drivers:drivers(),
    policy:policy({
      requested_sector:'pet_grooming',
      resolved_sector:'other',
      used_fallback_sector:true,
      base_policy:{
        ...policy().base_policy,
        suppression_rules:[
          {code:'sector_not_specialized',reason:'sector_not_specialized'}
        ],
        parameters:{
          minimum_prior_visits:3,
          cadence_multiplier:1.5,
          minimum_lapse_days:30,
          minimum_audience:20
        }
      },
      effective_parameters:{
        minimum_prior_visits:3,
        cadence_multiplier:1.5,
        minimum_lapse_days:30,
        minimum_audience:20
      }
    }),
    role:'owner'
  });
  const html=UI.render(view);
  assert.match(html,/No reviewed policy matched “pet_grooming”/);
  assert.match(html,/Unavailable<\/strong>\s*—\s*No reviewed policy exists for this sector yet/);
  assert.match(html,/<code>sector_not_specialized<\/code>/);
  assert.doesNotMatch(html,/café|salon benchmark/i);
});

test('disabled, permission, branch, error and empty states fail closed',()=>{
  const cases=[
    {
      error:{code:'0A000',message:'v109 economics and sector policy is not enabled'},
      state:'disabled',copy:/not enabled yet/
    },
    {
      error:{code:'42501',message:'finance access required'},
      state:'permission',copy:/Finance access is required/
    },
    {
      error:{code:'22023',message:'branch does not belong to business'},
      state:'branch',copy:/Choose a branch you can access/
    },
    {
      error:{code:'503',message:'timeout'},
      state:'error',copy:/Try again/
    }
  ];
  for(const item of cases){
    const view=UI.buildViewModel({
      economics:null,drivers:null,policy:null,errors:[item.error],role:'owner'
    });
    const html=UI.render(view);
    assert.equal(view.state,item.state);
    assert.match(html,item.copy);
    assert.doesNotMatch(html,/SGD 400\.00|Save policy change/);
  }

  const emptyEconomics=economics({
    status:'no_data',
    coverage:{
      eligible_sales:0,covered_sales:0,transaction_coverage_bps:null,
      eligible_revenue_cents:0,covered_revenue_cents:0,
      revenue_coverage_bps:null,traceable_cost_coverage_passes:false
    },
    profit:null,roi:null,unavailable_reasons:['no_eligible_sales']
  });
  const emptyDrivers=drivers({
    status:'unavailable',
    unavailable_reason:'current_period_has_no_revenue',
    drivers:null,
    reconciliation:{
      period_revenue_delta_cents:0,
      sum_driver_contributions_cents:null,
      rounding_residual_cents:null,reconciles:null
    }
  });
  const emptyView=UI.buildViewModel({
    economics:emptyEconomics,drivers:emptyDrivers,policy:policy(),role:'owner'
  });
  assert.equal(emptyView.state,'empty');
  const emptyHtml=UI.render(emptyView);
  assert.match(emptyHtml,/There is no period economics to calculate yet/);
  assert.match(emptyHtml,/When to consider a customer overdue/);
  assert.doesNotMatch(emptyHtml,/Gross profit with complete cost coverage/);
});

test('error retry binding calls the supplied refresh path',()=>{
  let handler=null,retries=0;
  const retryButton={
    addEventListener:(event,callback)=>{assert.equal(event,'click');handler=callback},
    removeEventListener:()=>{}
  };
  const container={
    querySelectorAll:selector=>{
      assert.equal(selector,'[data-sector-action="retry"]');
      return [retryButton];
    },
    querySelector:()=>null
  };
  UI.bind(container,{onRetry:()=>{retries+=1}});
  handler();
  assert.equal(retries,1);
});

test('owner override is bounded, idempotent under double-click and retries with the same key',async()=>{
  const calls=[];
  let release;
  const pending=new Promise(resolve=>{release=resolve});
  const controller=UI.createOverrideController({
    rpc:async(name,args)=>{
      calls.push({name,args});
      await pending;
      return {data:{override_id:'override-1',version_no:2,replayed:false},error:null};
    },
    businessId:'business-1',
    makeId:()=> '11111111-1111-4111-8111-111111111111',
    now:()=> '2026-07-30T00:00:00.000Z'
  });
  const input={
    parameters:{
      minimum_prior_visits:3,cadence_multiplier:1.5,
      minimum_lapse_days:45,minimum_audience:20
    },
    reason:'Observed treatment cycle'
  };
  const first=controller.submit(input);
  const second=controller.submit(input);
  assert.equal(calls.length,1);
  release();
  await Promise.all([first,second]);
  assert.deepEqual(calls[0],{
    name:'set_business_sector_policy_override_v109',
    args:{
      p_business:'business-1',
      p_policy_key:'lapse_detection',
      p_override_parameters:input.parameters,
      p_reason:'Observed treatment cycle',
      p_effective_from:'2026-07-30T00:00:00.000Z',
      p_idempotency_key:'11111111-1111-4111-8111-111111111111'
    }
  });
});

test('a failed override retry keeps its idempotency key and validation prevents invalid writes',async()=>{
  const keys=[];
  let attempt=0;
  const controller=UI.createOverrideController({
    rpc:async(_name,args)=>{
      keys.push(args.p_idempotency_key);
      attempt+=1;
      if(attempt===1)return {data:null,error:{code:'503',message:'timeout'}};
      return {data:{override_id:'override-1',version_no:2,replayed:true},error:null};
    },
    businessId:'business-1',
    makeId:()=> '22222222-2222-4222-8222-222222222222',
    now:()=> '2026-07-30T00:00:00.000Z'
  });
  const input={
    parameters:{
      minimum_prior_visits:3,cadence_multiplier:1.5,
      minimum_lapse_days:45,minimum_audience:20
    },
    reason:'Observed treatment cycle'
  };
  await assert.rejects(controller.submit(input));
  const result=await controller.submit(input);
  assert.equal(result.replayed,true);
  assert.deepEqual(keys,[
    '22222222-2222-4222-8222-222222222222',
    '22222222-2222-4222-8222-222222222222'
  ]);
  assert.equal(UI.validateOverride({
    parameters:{...input.parameters,minimum_lapse_days:500},
    reason:input.reason,effectiveFrom:'2026-07-30T00:00:00Z'
  }).ok,false);
});

test('successful owner form submission refreshes evidence after the audited write',async()=>{
  const handlers={};
  const button={disabled:false,textContent:'Save policy change'};
  const status={textContent:''};
  const form={
    addEventListener:(event,callback)=>{handlers[event]=callback},
    removeEventListener:()=>{},
    querySelector:selector=>selector==='[data-sector-policy-save]'?button:status
  };
  const container={
    querySelectorAll:()=>[],
    querySelector:selector=>selector==='[data-sector-policy-override-form]'?form:null
  };
  const values={
    minimum_prior_visits:'3',cadence_multiplier:'1.5',
    minimum_lapse_days:'45',minimum_audience:'20',
    reason:'Observed treatment cycle'
  };
  const priorFormData=globalThis.FormData;
  globalThis.FormData=class{
    get(key){return values[key]}
  };
  let refreshes=0;
  try{
    UI.bind(container,{
      role:'owner',businessId:'business-1',
      rpc:async()=>({data:{override_id:'override-1',version_no:2,replayed:false}}),
      makeId:()=> '33333333-3333-4333-8333-333333333333',
      now:()=> '2026-07-30T00:00:00.000Z',
      onRefresh:async()=>{refreshes+=1}
    });
    await handlers.submit({preventDefault(){}});
  }finally{
    globalThis.FormData=priorFormData;
  }
  assert.equal(refreshes,1);
  assert.match(status.textContent,/saved and added to the audit history/);
});

test('375px CSS has no horizontal overflow, one-column forms, 48px targets and reduced motion',async()=>{
  const css=await read('app/sector-economics.css');
  assert.match(css,/@media\(max-width:620px\)/);
  assert.match(css,/\.sector-economics\{[\s\S]*overflow-x:clip/);
  assert.match(css,/\.sector-policy-form-grid\{grid-template-columns:1fr/);
  assert.match(css,/\.sector-policy-save,[\s\S]*min-height:48px/);
  assert.match(css,/@media\(prefers-reduced-motion:reduce\)/);
});

test('customer intelligence integrates the exact migration RPC signatures and branch scope',async()=>{
  const [index,module]=await Promise.all([
    Promise.all([read('app/index.html'),read('app/app.js')]).then(f=>f.join('\n')),
    read('app/sector-economics.js')
  ]);
  assert.match(index,/sector-economics\.css/);
  assert.match(index,/sector-economics\.js/);
  assert.match(index,/get_period_economics_v109/);
  assert.match(index,/p_from:fromDate/);
  assert.match(index,/p_to:shiftSingaporeDate\(toDate,1\)/);
  assert.match(index,/p_investment_cents:null/);
  assert.match(index,/p_investment_reference:null/);
  assert.match(index,/get_revenue_driver_decomposition_v109/);
  assert.match(index,/p_current_from:fromDate/);
  assert.match(index,/p_current_to:shiftSingaporeDate\(toDate,1\)/);
  assert.match(index,/p_comparison_from:comparisonFromDate/);
  assert.match(index,/p_comparison_to:fromDate/);
  assert.match(index,/get_effective_sector_policy_v109/);
  assert.match(index,/p_policy_key:'lapse_detection'/);
  assert.match(index,/p_as_of:reportAsOf/);
  assert.match(index,/p_to:shiftSingaporeDate\(toDate,1\)/);
  assert.match(index,/const reportAsOf=new Date\(\)\.toISOString\(\)/);
  assert.match(index,/currency:String\(truthResponse\.data\?\.scope\?\.currency\|\|economicsResponse\.data\?\.profit\?\.currency\|\|''\)\.toUpperCase\(\)/);
  assert.match(module,/set_business_sector_policy_override_v109/);
  assert.doesNotMatch(index,/p_coverage_gate_bps|p_currency/);
  assert.doesNotMatch(module,/p_coverage_gate_bps|p_currency/);
  assert.match(index,/branchName/);
});

test('customer intelligence owns the only page h1 and embedded evidence modules use h2',async()=>{
  const [index,revenue,sector]=await Promise.all([
    Promise.all([read('app/index.html'),read('app/app.js')]).then(f=>f.join('\n')),
    read('app/revenue-truth.js'),
    read('app/sector-economics.js')
  ]);
  const page=index.slice(
    index.indexOf('async function customerIntelligencePage()'),
    index.indexOf('async function reportsPage()')
  );
  assert.equal((page.match(/<h1/g)||[]).length,1);
  assert.equal((revenue.match(/<h1/g)||[]).length,0);
  assert.equal((sector.match(/<h1/g)||[]).length,0);
});
