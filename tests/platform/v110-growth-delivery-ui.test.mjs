import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const require=createRequire(import.meta.url);
const UI=require('../../app/growth-offers.js');
const read=path=>readFile(new URL(`../../${path}`,import.meta.url),'utf8');

const sqlPayload=()=>({
  contract_version:'growth_delivery_lifecycle_v110',
  execution_id:'execution-1',
  business_id:'business-1',
  branch_id:'branch-1',
  counts:{
    queued:1,scheduled:1,delivering:1,delivered:1,
    held_out:1,suppressed:1,failed:1,cancelled:1
  },
  deliveries:[
    {
      dispatch_id:'queued-1',delivery_id:'delivery-1',status:'queued',
      provider:'in_app',scheduled_for:'2026-07-30T03:00:00Z',
      attempt_count:0,delivered_at:null,failure_code:null,
      cancelled_at:null,updated_at:'2026-07-30T02:00:00Z'
    },
    {
      dispatch_id:'failed-1',delivery_id:'delivery-2',status:'failed',
      provider:'in_app',scheduled_for:'2026-07-30T03:00:00Z',
      attempt_count:2,delivered_at:null,failure_code:'provider_timeout',
      cancelled_at:null,updated_at:'2026-07-30T02:00:00Z'
    },
    {
      dispatch_id:'delivered-1',delivery_id:'delivery-3',status:'delivered',
      provider:'in_app',scheduled_for:'2026-07-30T03:00:00Z',
      attempt_count:1,delivered_at:'2026-07-30T03:01:00Z',
      failure_code:null,cancelled_at:null,updated_at:'2026-07-30T03:01:00Z',
      entitlement_status:'issued',entitlement_suppressed:false,
      suppression_reason:null
    },
    {
      dispatch_id:'delivered-2',delivery_id:'delivery-4',status:'delivered',
      provider:'in_app',scheduled_for:'2026-07-30T03:00:00Z',
      attempt_count:1,delivered_at:'2026-07-30T03:02:00Z',
      failure_code:null,cancelled_at:null,updated_at:'2026-07-30T03:02:00Z',
      entitlement_status:'suppressed',entitlement_suppressed:true,
      suppression_reason:'execution_expired'
    }
  ]
});

const activeExecution=()=>({
  execution_id:'execution-1',
  recommendation_id:'recommendation-1',
  branch_id:'branch-1',
  currency:'SGD',
  status:'running',
  started_at:'2026-07-30T01:00:00Z',
  ends_at:'2026-08-07T01:00:00Z',
  governed_copy:{
    schema:'nestly.growth_offer_copy',
    version:1,
    title:'A welcome-back offer is waiting',
    body:'We saved SGD 5.00 in credit for your next eligible visit.',
    cta_label:'Redeem now',
    cta_destination:'customer_growth_offer_qr',
    conditions:{
      expires_at:'2026-08-06T15:59:59Z',
      timezone:'Asia/Singapore'
    },
    locked_facts:{
      template_id:'welcome_back',
      offer_value_cents:500,
      currency:'SGD',
      expires_at:'2026-08-06T15:59:59Z',
      timezone:'Asia/Singapore',
      branch_id:'branch-1',
      recommendation_id:'recommendation-1',
      cta_label:'Redeem now',
      cta_destination:'customer_growth_offer_qr'
    }
  },
  delivery:{
    queued:2,scheduled:1,delivering:1,delivered:5,
    held_out:2,suppressed:1,failed:1,cancelled:0
  },
  arms:{treatment:9,holdout:2},
  provisional_measurement:{
    measurement_status:'provisional',
    method:'randomized_intent_to_treat_holdout',
    arms:{
      treatment:{
        members:9,buyers:3,conversion_rate_bps:3333,
        associated_revenue_cents:9000
      },
      holdout:{
        members:2,buyers:0,conversion_rate_bps:0,
        associated_revenue_cents:0
      }
    },
    estimated_incremental_revenue:{
      currency:'SGD',point_estimate_cents:800,
      low_cents:-200,high_cents:1800,
      confidence_level:'approximate_95_percent'
    },
    incremental_gross_profit:null,
    cost:{
      estimated_offer_cost_cents:500,
      actual_redeemed_cost_cents:0,
      reversed_offer_cost_cents:0
    },
    limitations:[
      'revenue result is not gross profit',
      'confidence interval uses a transparent normal approximation'
    ]
  }
});

test('branch-correct active execution renders locked copy and provisional truth',()=>{
  const normalized=UI.normalizeActiveExecution(activeExecution(),{
    expectedBranchId:'branch-1'
  });
  assert.equal(normalized.templateId,'welcome_back');
  assert.equal(normalized.delivery.delivered,5);
  assert.equal(normalized.provisionalMeasurement.status,'provisional');
  const html=UI.renderActiveExecution(activeExecution(),{
    expectedBranchId:'branch-1'
  });
  assert.match(html,/A welcome-back offer is waiting/);
  assert.match(html,/Redeem now/);
  assert.match(html,/<strong>5<\/strong> delivered; <strong>4<\/strong> queued or in progress/);
  assert.match(html,/Directional signal — not a final revenue or profit result/);
  assert.match(html,/3 buyers \/ 9 members/);
  assert.match(html,/SGD -2\.00–SGD 18\.00/);
  assert.match(html,/Asia\/Singapore/);
});

test('active execution fails closed for branch or governed-copy drift',()=>{
  assert.equal(UI.renderActiveExecution(activeExecution(),{
    expectedBranchId:'branch-2'
  }),'');
  const wrongCta=activeExecution();
  wrongCta.governed_copy.cta_label='Claim now';
  assert.equal(UI.normalizeActiveExecution(wrongCta,{
    expectedBranchId:'branch-1'
  }),null);
  const unknownTemplate=activeExecution();
  unknownTemplate.governed_copy.locked_facts.template_id='invented_copy';
  assert.equal(UI.normalizeActiveExecution(unknownTemplate,{
    expectedBranchId:'branch-1'
  }),null);
});

test('v110 SQL-shaped status normalizes every durable lifecycle without provider invention',()=>{
  const data=UI.normalizeDeliveryStatus(sqlPayload());
  assert.equal(data.contractVersion,'growth_delivery_lifecycle_v110');
  assert.equal(data.branchId,'branch-1');
  assert.deepEqual(Object.keys(data.counts),[
    'queued','scheduled','delivering','delivered',
    'held_out','suppressed','failed','cancelled'
  ]);
  const html=UI.renderDeliveryStatus({mode:'ready',data});
  assert.match(html,/Queued/);
  assert.match(html,/Scheduled/);
  assert.match(html,/Delivering/);
  assert.match(html,/Delivered/);
  assert.match(html,/Measurement holdout/);
  assert.match(html,/Suppressed by safeguards/);
  assert.match(html,/Needs attention/);
  assert.match(html,/Cancelled/);
  assert.match(html,/A queued or delivering item is not a delivered offer/);
  assert.match(html,/Message delivered; offer issued\./);
  assert.match(
    html,
    /Message delivered; offer not issued — The campaign ended before provider confirmation\./
  );
  assert.doesNotMatch(html,/provider_timeout|provider message/i);
});

test('delivery suppression truth fails closed for unknown backend reasons',()=>{
  const payload=sqlPayload();
  payload.deliveries.at(-1).suppression_reason='provider_secret_reason';
  const data=UI.normalizeDeliveryStatus(payload);
  const suppressed=data.deliveries.at(-1);
  assert.equal(suppressed.entitlementSuppressed,true);
  assert.equal(suppressed.suppressionReason,'');
  const html=UI.renderDeliveryStatus({mode:'ready',data});
  assert.match(
    html,
    /Message delivered; offer issuance status unavailable\./
  );
  assert.doesNotMatch(html,/provider_secret_reason/);
  assert.equal(
    (html.match(/Message delivered; offer issued\./g)||[]).length,
    1,
    'only the explicitly issued delivery may render the issued-success claim'
  );
});

test('status load calls the exact v110 owner RPC and shares one request',async()=>{
  const calls=[];
  let release;
  const waiting=new Promise(resolve=>{release=resolve});
  const controller=UI.createDeliveryController({
    businessId:'business-1',executionId:'execution-1',
    rpc:async(name,args)=>{
      calls.push({name,args});await waiting;
      return {data:sqlPayload(),error:null};
    }
  });
  const first=controller.load();
  const second=controller.load();
  assert.equal(calls.length,1);
  release();
  await first;
  assert.deepEqual(calls,[{
    name:'get_growth_delivery_status_v110',
    args:{p_business:'business-1',p_execution:'execution-1'}
  }]);
});

test('cancel and retry use exact v110 contracts, stable keys, and backend-matching guards',async()=>{
  const calls=[];
  let retryAttempts=0;
  const controller=UI.createDeliveryController({
    businessId:'business-1',executionId:'execution-1',
    makeId:()=>{
      retryAttempts+=1;
      return retryAttempts===1
        ?'11111111-1111-4111-8111-111111111111'
        :'22222222-2222-4222-8222-222222222222';
    },
    rpc:async(name,args)=>{
      calls.push({name,args});
      if(name==='get_growth_delivery_status_v110'){
        return {data:sqlPayload(),error:null};
      }
      if(name==='retry_growth_delivery_v110'&&
        calls.filter(call=>call.name===name).length===1){
        return {data:null,error:{code:'503',message:'timeout'}};
      }
      return {
        data:name==='retry_growth_delivery_v110'
          ?{dispatch_id:'failed-1',status:'queued',attempt_count:2}
          :{dispatch_id:'queued-1',status:'cancelled'},
        error:null
      };
    }
  });
  await controller.load();
  await assert.rejects(controller.retry('failed-1'));
  await controller.retry('failed-1');
  await controller.cancel('queued-1','Owner paused this launch');
  const retryCalls=calls.filter(call=>call.name==='retry_growth_delivery_v110');
  assert.equal(retryCalls.length,2);
  assert.equal(
    retryCalls[0].args.p_idempotency_key,
    retryCalls[1].args.p_idempotency_key
  );
  assert.deepEqual(calls.at(-1),{
    name:'cancel_growth_delivery_v110',
    args:{
      p_business:'business-1',
      p_dispatch:'queued-1',
      p_reason:'Owner paused this launch',
      p_idempotency_key:'22222222-2222-4222-8222-222222222222'
    }
  });
  await assert.rejects(
    controller.retry('delivered-1'),
    /Only failed deliveries/
  );
  await assert.rejects(
    controller.cancel('delivered-1','No longer needed'),
    /Only pending, delivering, or failed/
  );
});

test('approved owner receipt mounts live v110 status rather than claiming delivery',()=>{
  const model=UI.normalizeOwnerAction({
    action:{
      id:'recommendation-1',
      audience:{treatment:2,holdout:1},
      action:{value_cents:500,currency:'SGD',offer_template:'welcome_back'}
    }
  });
  const html=UI.renderOwnerAction({
    model,
    state:{
      mode:'approved',
      result:{execution_id:'execution-1',estimated_cost_cents:1000}
    }
  });
  assert.match(html,/data-growth-delivery-status/);
  assert.match(html,/Delivery is not confirmed/);
  assert.doesNotMatch(html,/offers? (?:was|were|has been) delivered/i);
});

test('UI RPC names and lifecycle statuses stay aligned to the installed migration',async()=>{
  const [module,migration]=await Promise.all([
    read('app/growth-offers.js'),
    read('supabase/migrations/20260729171130_nestly_v110_growth_delivery_lifecycle.sql')
  ]);
  for(const rpc of [
    'get_growth_delivery_status_v110',
    'cancel_growth_delivery_v110',
    'retry_growth_delivery_v110'
  ]){
    assert.match(module,new RegExp(rpc));
    assert.match(migration,new RegExp(`function public\\.${rpc}`,'i'));
  }
  for(const status of [
    'queued','scheduled','delivering','delivered',
    'held_out','suppressed','failed','cancelled'
  ]){
    assert.match(module,new RegExp(`'${status}'`));
    assert.match(migration,new RegExp(`'${status}'`));
  }
});

test('active card stays aligned to the exact v108 briefing and governed-copy contract',async()=>{
  const [module,index,migration]=await Promise.all([
    read('app/growth-offers.js'),
    Promise.all([read('app/index.html'),read('app/app.js')]).then(f=>f.join('\n')),
    read('supabase/migrations/20260729171045_nestly_v108_measured_bringback_loop.sql')
  ]);
  for(const template of ['welcome_back','member_thank_you','simple_saving']){
    assert.match(module,new RegExp(`${template}:`));
    assert.match(migration,new RegExp(`'${template}'`));
  }
  for(const field of [
    'active_execution','provisional_measurement','governed_copy',
    'offer_timezone','offer_expires_at','locked_facts',
    'cta_destination','customer_growth_offer_qr'
  ]){
    assert.match(migration,new RegExp(field));
  }
  assert.match(migration,/branch_id is not distinct from p_branch/i);
  assert.match(index,/renderActiveExecution[\s\S]*expectedBranchId:selectedBranchId\|\|null/);
});
