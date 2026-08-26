import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const require=createRequire(import.meta.url);
const UI=require('../../app/revenue-truth.js');
const read=path=>readFile(new URL(`../../${path}`,import.meta.url),'utf8');

const truth=(overrides={})=>({
  contract_version:'v106.1',
  generated_at:'2026-07-30T01:00:00Z',
  as_of:'2026-07-30T01:00:00Z',
  status:'ok',
  scope:{
    business_id:'business-1',branch_id:null,business_name:'Demo Spa',branch_name:null,
    period:{from:'2026-07-01',to:'2026-07-31',interval:'[from,to)'},
    timezone:'Asia/Singapore',currency:'SGD'
  },
  totals:{
    known_revenue_minor:100000,identified_revenue_minor:75000,
    anonymous_revenue_minor:25000,completed_transactions:40,
    identified_transactions:30,anonymous_transactions:10,itemized_transactions:35
  },
  coverage:{
    identity_revenue_pct:75,identity_transaction_pct:75,
    itemization_transaction_pct:87.5,reconciled_transaction_pct:100
  },
  freshness:{latest_sale_occurred_at:'2026-07-30T00:50:00Z',reconciliation_conflicts:0},
  limitations:[],
  ...overrides
});

const lifecycle=(overrides={})=>({
  contract_version:'v107.1',
  status:'ok',
  metrics:{
    transacting_identified_customers:22,new_customers:6,
    existing_returning_customers:9,repeat_purchasers_in_period:7,
    reactivated_customers:2,existing_customer_share_pct:40.91,
    repeat_in_period_rate_pct:31.82,
    customer_cadence_classifications:14,fallback_classifications:8
  },
  definitions:{
    existing_returning_customer:'Bought before this period and bought again during it.',
    repeat_purchaser_in_period:'Made at least two eligible purchases inside this period.',
    reactivated_customer:'Bought again after passing the applicable lapse threshold.'
  },
  coverage:{identified_transaction_pct:75},
  ...overrides
});

const briefing=(overrides={})=>({
  contract_version:'growth_daily_briefing_v108',
  data_status:'ready',
  generated_at:'2026-07-30T01:00:00Z',
  top_action:{
    recommendation_id:'recommendation-1',type:'bring_back',status:'presented',
    title:'Invite overdue regulars back this week',
    finding:'12 regular customers are past their observed visit cadence.',
    evidence:[
      {label:'Eligible customers',value:'12'},
      {label:'Observed past revenue',value:'SGD 840.00'}
    ],
    audience:{eligible:12,excluded:4,treatment:10,holdout:2},
    expected_incremental_revenue:{low_cents:18000,high_cents:32000,currency:'SGD'},
    estimated_cost_cents:4800,
    confidence:{level:'medium',score_bps:6900,reasons:['Cadence is available for this group.']},
    action:{
      label:'Preview a 10% welcome-back offer',channel:'In-app',
      offer:'10% off one eligible service',expires_at:'2026-08-06T15:59:59Z'
    },
    measurement:{method:'Treatment and holdout comparison',attribution_days:30,minimum_sample:10,status:'planned'}
  },
  suppressions:[],
  ...overrides
});

test('renders exact SQL-shaped recorded revenue without calling it total business revenue',()=>{
  const view=UI.buildViewModel({truth:truth(),lifecycle:lifecycle(),briefing:briefing()});
  const html=UI.render(view);
  assert.match(html,/Peekaa recorded revenue/);
  assert.match(html,/Identified customer revenue/);
  assert.match(html,/Anonymous \/ unattributed revenue/);
  assert.match(html,/Customer revenue coverage/);
  assert.match(html,/SGD(?:\s|&nbsp;)*1,000\.00/);
  assert.match(html,/total business revenue remains unavailable/);
  assert.doesNotMatch(html,/>Total business revenue</);
});

test('partial reconciliation refuses to relabel the Peekaa ledger as total business revenue',()=>{
  const partialTruth=truth({
    status:'partial_coverage',
    coverage:{identity_revenue_pct:75,identity_transaction_pct:75,itemization_transaction_pct:87.5,reconciled_transaction_pct:null},
    limitations:['External POS sales are not reconciled.']
  });
  const view=UI.buildViewModel({truth:partialTruth,lifecycle:lifecycle(),briefing:briefing()});
  const html=UI.render(view);
  assert.equal(view.state,'partial');
  assert.match(html,/Peekaa recorded revenue/);
  assert.match(html,/SGD(?:\s|&nbsp;)*1,000\.00 is recorded in the Peekaa sales ledger/);
  assert.match(html,/total business revenue remains unavailable/);
  assert.doesNotMatch(html,/>Total business revenue</);
});

test('zero denominators are not rendered as zero percent',()=>{
  const emptyLifecycle=lifecycle({
    status:'no_data',
    metrics:{
      transacting_identified_customers:0,new_customers:0,existing_returning_customers:0,
      repeat_purchasers_in_period:0,reactivated_customers:0,
      existing_customer_share_pct:null,repeat_in_period_rate_pct:null,
      customer_cadence_classifications:0,fallback_classifications:0
    }
  });
  const html=UI.render(UI.buildViewModel({
    truth:truth({status:'no_data',totals:{known_revenue_minor:0,identified_revenue_minor:0,anonymous_revenue_minor:0}}),
    lifecycle:emptyLifecycle,briefing:briefing({data_status:'insufficient_data',top_action:null})
  }));
  assert.match(html,/Not enough data/);
  assert.doesNotMatch(html,/Existing customer share<\/span><strong>0%/);
});

test('SQL null and blank fields stay unavailable instead of coercing to zero',()=>{
  const view=UI.buildViewModel({
    truth:truth({
      totals:{
        known_revenue_minor:null,identified_revenue_minor:'',anonymous_revenue_minor:null,
        completed_transactions:0,identified_transactions:0,anonymous_transactions:0,
        itemized_transactions:0
      },
      coverage:{
        identity_revenue_pct:null,identity_transaction_pct:'',
        itemization_transaction_pct:null,reconciled_transaction_pct:null
      }
    }),
    lifecycle:lifecycle({
      metrics:{
        transacting_identified_customers:0,new_customers:0,
        existing_returning_customers:0,repeat_purchasers_in_period:0,
        reactivated_customers:0,existing_customer_share_pct:null,
        repeat_in_period_rate_pct:'',customer_cadence_classifications:0,
        fallback_classifications:0
      }
    }),
    briefing:briefing({data_status:'not_computed',top_action:null})
  });
  const html=UI.render(view);
  assert.equal(view.truth.totals.knownRevenueMinor,null);
  assert.equal(view.truth.totals.identifiedRevenueMinor,null);
  assert.equal(view.lifecycle.metrics.repeatInPeriodRatePct,null);
  assert.match(html,/Not available/);
  assert.match(html,/Not enough data/);
  assert.doesNotMatch(html,/SGD(?:\s|&nbsp;)*0\.00/);
  assert.doesNotMatch(html,/Existing customer share<\/span><strong>0%/);
});

test('states the returning meaning exactly, and defers the full analysis to Business Insights',()=>{
  /* nestly_v522 consolidation. This block used to render five lifecycle metric cards from
     get_customer_lifecycle_v107 — the same RPC and the same metrics that Business Insights ->
     Customer Retention renders, but laid out differently and without its period-on-period
     comparison. Two visually different answers from one RPC is exactly the ambiguity this test
     was written to prevent, so the cards are gone and a one-line summary points at the canonical
     screen. The original intent is unchanged and still asserted: say precisely what "returned"
     means, and never fall back on the bare "Returning customers" label. */
  const html=UI.render(UI.buildViewModel({truth:truth(),lifecycle:lifecycle(),briefing:briefing()}));
  assert.match(html,/identified customers who purchased in this period had bought before/);
  assert.match(html,/Repeat purchase rate this period/);
  assert.match(html,/href="#\/reports"/);
  assert.match(html,/Business Insights &rarr; Customer Retention/);
  assert.doesNotMatch(html,/>Returning customers</);
  /* The duplicated cards must not come back. */
  assert.doesNotMatch(html,/Reactivated customers/);
  assert.doesNotMatch(html,/Existing customer share/);
});

test('one ranked bring-back opportunity shows evidence, data quality, cost and a governed owner mount',()=>{
  const html=UI.render(UI.buildViewModel({truth:truth(),lifecycle:lifecycle(),briefing:briefing()}));
  assert.equal((html.match(/Top action/g)||[]).length,1);
  assert.match(html,/Invite overdue regulars back this week/);
  assert.match(html,/Why this is ranked first/);
  assert.match(html,/Moderate data quality/);
  assert.doesNotMatch(html,/>Confidence</);
  assert.match(html,/Estimated cost/);
  assert.match(html,/data-growth-owner-action-mount/);
  assert.doesNotMatch(html,/Confirm &amp; send|Confirm & send/);
  assert.doesNotMatch(html,/<canvas|chart/i);
});

test('withheld revenue range renders its exact server reason without an outcome claim',()=>{
  const source=briefing();
  source.top_action={
    ...source.top_action,
    expected_incremental_revenue:{
      low_cents:null,high_cents:null,currency:'SGD',
      unavailable_reason:'No calibrated outcome range is available for this cohort.'
    }
  };
  const html=UI.render(UI.buildViewModel({
    truth:truth(),lifecycle:lifecycle(),briefing:source
  }));
  assert.match(html,/Unavailable — No calibrated outcome range is available for this cohort/);
  assert.doesNotMatch(html,/Higher confidence|Moderate confidence|outcome confidence/i);
});

test('claim wording is fail-closed unless explicit backend state permits it',()=>{
  const unsafe=briefing({
    top_action:{
      ...briefing().top_action,
      finding:'We sent and delivered an incremental profit campaign.',
      claims:{sent:true,delivered:true,incremental_revenue:true,profit:true},
      execution:{state:'draft'},
      profit:{status:'missing_costs'},
      measurement:{status:'planned'}
    }
  });
  const html=UI.render(UI.buildViewModel({truth:truth(),lifecycle:lifecycle(),briefing:unsafe}));
  assert.doesNotMatch(html,/\bsent\b/i);
  assert.doesNotMatch(html,/\bdelivered\b/i);
  assert.doesNotMatch(html,/\bincremental\b/i);
  assert.doesNotMatch(html,/\bprofit\b/i);
  assert.match(html,/delivery not confirmed/);

  const allowed=UI.normalizeBriefing({
    data_status:'ready',
    top_action:{
      ...briefing().top_action,
      finding:'Provider delivered; measured incremental revenue and profit are ready.',
      claims:{sent:true,delivered:true,incremental_revenue:true,profit:true},
      execution:{state:'delivered'},
      profit:{status:'complete'},
      measurement:{status:'measured'}
    }
  });
  assert.match(allowed.action.finding,/delivered/);
  assert.match(allowed.action.finding,/incremental/);
  assert.match(allowed.action.finding,/profit/);
});

test('stale, retry, permission and branch states fail closed',()=>{
  const stale=UI.buildViewModel({
    truth:truth({status:'stale'}),lifecycle:lifecycle(),briefing:briefing()
  });
  const staleHtml=UI.render(stale);
  assert.equal(stale.actionAllowed,false);
  assert.match(staleHtml,/This briefing is stale/);
  assert.match(staleHtml,/data-revenue-truth-action="retry"/);
  assert.match(staleHtml,/No reliable action to recommend yet/);

  const denied=UI.buildViewModel({
    truth:truth({status:'permission_denied'}),lifecycle:lifecycle({status:'permission_denied'}),
    briefing:briefing({data_status:'permission_denied',top_action:null})
  });
  const deniedHtml=UI.render(denied);
  assert.match(deniedHtml,/Finance access is required/);
  assert.doesNotMatch(deniedHtml,/SGD(?:&nbsp;| )1,000\.00/);

  const branchView=UI.buildViewModel({
    truth:truth({scope:{...truth().scope,branch_id:'branch-1',branch_name:'Orchard'}}),
    lifecycle:lifecycle(),briefing:briefing()
  });
  assert.match(UI.render(branchView),/Selected branch/);
});

test('mobile CSS collapses all dense grids and preserves large touch actions',async()=>{
  const css=await read('app/revenue-truth.css');
  assert.match(css,/@media\(max-width:620px\)/);
  assert.match(css,/\.revenue-truth-metrics,[\s\S]*grid-template-columns:1fr/);
  assert.match(css,/\.revenue-opportunity-preview-button,[\s\S]*min-height:48px/);
  assert.match(css,/@media\(prefers-reduced-motion:reduce\)/);
});

test('index integrates v106, v107 and v108 through the modular truth renderer',async()=>{
  const source=((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  assert.match(source,/revenue-truth\.css/);
  assert.match(source,/revenue-truth\.js/);
  assert.match(source,/get_revenue_truth_v106/);
  assert.match(source,/get_customer_lifecycle_v107/);
  assert.match(source,/get_growth_daily_briefing_v108/);
  assert.match(source,/RevenueTruthUI\.buildViewModel/);
  assert.match(source,/RevenueTruthUI\.render/);
});
