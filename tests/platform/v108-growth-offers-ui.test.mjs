import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const require=createRequire(import.meta.url);
const UI=require('../../app/growth-offers.js');
const read=path=>readFile(new URL(`../../${path}`,import.meta.url),'utf8');

test('growth actions never use Math.random for authoritative request identifiers',async()=>{
  const source=await read('app/growth-offers.js');
  assert.doesNotMatch(source,/Math\.random/);
  assert.match(source,/crypto\.randomUUID/);
  assert.match(source,/crypto\.getRandomValues/);
});

const ownerAction=()=>({
  briefing:{
    action:{
      id:'recommendation-1',
      title:'Invite overdue regulars back',
      audience:{eligible:12,excluded:4,treatment:10,holdout:2},
      estimatedCostCents:5000,
      action:{
        offer:'SGD 5 welcome-back credit',
        valueCents:500,
        currency:'SGD',
        requiresOwnerApproval:true
      }
    }
  }
});

test('owner surface starts with audience preview and no autonomous send control',()=>{
  const model=UI.normalizeOwnerAction(ownerAction());
  const html=UI.renderOwnerAction({model,state:{mode:'idle'}});
  assert.match(html,/Preview audience/);
  assert.match(html,/Nothing is sent until/);
  assert.match(html,/Dismiss/);
  assert.doesNotMatch(html,/Confirm &amp; send in app|Confirm & send in app/);
});

test('missing locked value or currency never becomes a plausible zero-value offer',()=>{
  const missingValue=ownerAction();
  delete missingValue.briefing.action.action.valueCents;
  assert.equal(UI.normalizeOwnerAction(missingValue),null);
  const missingCurrency=ownerAction();
  delete missingCurrency.briefing.action.action.currency;
  assert.equal(UI.normalizeOwnerAction(missingCurrency),null);
  assert.equal(UI.money(null,'SGD'),'Not supplied');
  assert.equal(UI.money('', 'SGD'),'Not supplied');
  assert.equal(UI.money(0,'SGD'),'SGD 0.00');
});

test('owner preview calls the exact v108 contract and normalizes audience evidence',async()=>{
  const calls=[];
  const rpc=async(name,args)=>{
    calls.push({name,args});
    return {data:{
      recommendation_id:'recommendation-1',status:'presented',
      eligible_count:12,excluded_count:4,
      eligible:[{client_id:'client-1',evidence:{past_visits:4}}],
      excluded_by_reason:{frequency_cap:3,consent_withdrawn:1}
    },error:null};
  };
  const controller=UI.createOwnerController({
    rpc,businessId:'business-1',recommendationId:'recommendation-1'
  });
  const preview=await controller.preview();
  assert.deepEqual(calls,[{
    name:'preview_growth_recommendation_v108',
    args:{p_business:'business-1',p_recommendation:'recommendation-1',p_limit:100}
  }]);
  assert.equal(preview.eligibleCount,12);
  assert.equal(preview.excludedByReason.frequency_cap,3);
});

test('approval requires a separate review step and double-click shares one idempotent request',async()=>{
  const calls=[];
  let release;
  const pending=new Promise(resolve=>{release=resolve});
  const rpc=async(name,args)=>{
    calls.push({name,args});
    await pending;
    return {data:{
      execution_id:'execution-1',
      delivery:{queued:8,scheduled:0,held_out:2,suppressed:0},
      estimated_cost_cents:4000,replayed:false
    },error:null};
  };
  const controller=UI.createOwnerController({
    rpc,businessId:'business-1',recommendationId:'recommendation-1',
    offerTemplate:'welcome_back',
    makeId:()=> '11111111-1111-4111-8111-111111111111'
  });
  assert.equal(controller.beginApprove({
    valueCents:500,template:'welcome_back'
  }).ok,true);
  assert.equal(calls.length,0,'review step must not call approval RPC');
  const first=controller.confirmApprove();
  const second=controller.confirmApprove();
  assert.equal(calls.length,1);
  release();
  await first;
  assert.deepEqual(calls[0],{
    name:'approve_growth_recommendation_v108',
    args:{
      p_business:'business-1',
      p_recommendation:'recommendation-1',
      p_offer_value_cents:500,
      p_offer_label:'welcome_back',
      p_idempotency_key:'11111111-1111-4111-8111-111111111111'
    }
  });
});

test('approval retry reuses the same key and exposes stale and permission states',async()=>{
  const keys=[];
  let attempt=0;
  const controller=UI.createOwnerController({
    businessId:'business-1',recommendationId:'recommendation-1',
    offerTemplate:'simple_saving',
    makeId:()=> '22222222-2222-4222-8222-222222222222',
    rpc:async(_name,args)=>{
      keys.push(args.p_idempotency_key);
      attempt+=1;
      if(attempt===1)return {data:null,error:{code:'503',message:'timeout'}};
      return {data:{execution_id:'execution-1',replayed:true},error:null};
    }
  });
  controller.beginApprove({
    valueCents:700,
    template:'arbitrary owner-written claim'
  });
  await assert.rejects(controller.confirmApprove());
  await controller.confirmApprove();
  assert.deepEqual(keys,[
    '22222222-2222-4222-8222-222222222222',
    '22222222-2222-4222-8222-222222222222'
  ]);
  assert.equal(controller.snapshot().result.replayed,true);
  assert.equal(controller.snapshot().result.execution_id,'execution-1');
  assert.equal(UI.classifyError({code:'42501',message:'owner only'}).kind,'permission');
  assert.equal(UI.classifyError({
    code:'42501',message:'recommendation is no longer executable'
  }).kind,'stale');
});

test('approval receipt never claims delivery before live execution evidence is loaded',()=>{
  const model=UI.normalizeOwnerAction(ownerAction());
  const html=UI.renderOwnerAction({
    model,
    state:{
      mode:'approved',replayed:false,estimated_cost_cents:5000,
      result:{estimated_cost_cents:5000,delivery:{delivered:10}}
    }
  });
  assert.match(html,/Approval recorded/);
  assert.match(html,/Delivery is not confirmed/);
  assert.doesNotMatch(html,/offers delivered|measured bring-back has started/i);
});

test('dismissal is explicit and idempotent under double-click',async()=>{
  let release;
  const pending=new Promise(resolve=>{release=resolve});
  const calls=[];
  const controller=UI.createOwnerController({
    businessId:'business-1',recommendationId:'recommendation-1',
    makeId:()=> '33333333-3333-4333-8333-333333333333',
    rpc:async(name,args)=>{
      calls.push({name,args});await pending;
      return {data:{recommendation_id:'recommendation-1',decision:'dismissed',replayed:false}};
    }
  });
  controller.beginDismiss('Not suitable this week');
  const first=controller.confirmDismiss();
  const second=controller.confirmDismiss();
  assert.equal(calls.length,1);
  release();await first;
  assert.equal(calls[0].name,'dismiss_growth_recommendation_v108');
  assert.equal(calls[0].args.p_reason,'Not suitable this week');
});

test('recommendation refresh is branch-exact and shares one request under double-click',async()=>{
  const calls=[];
  let release;
  const pending=new Promise(resolve=>{release=resolve});
  const controller=UI.createRecommendationRefreshController({
    businessId:'business-1',branchId:'branch-1',
    rpc:async(name,args)=>{
      calls.push({name,args});await pending;
      return {data:{recommendation_id:'recommendation-1',status:'presented',replayed:false}};
    }
  });
  const first=controller.refresh();
  const second=controller.refresh();
  assert.equal(first,second);
  assert.equal(calls.length,1);
  assert.equal(controller.snapshot().mode,'loading');
  release();
  await first;
  assert.deepEqual(calls,[{
    name:'refresh_growth_recommendation_v108',
    args:{p_business:'business-1',p_branch:'branch-1'}
  }]);
  assert.equal(controller.snapshot().mode,'success');
});

test('recommendation refresh renders disabled, permission, branch and retryable errors truthfully',async()=>{
  const cases=[
    [{code:'0A000',message:'growth closed loop is not enabled'},'disabled',/not enabled/],
    [{code:'42501',message:'owner only'},'permission',/permission/],
    [{code:'22023',message:'branch is outside actor scope'},'branch',/branch is outside actor scope/],
    [{code:'503',message:'timeout'},'error',/Try recommendation refresh again/]
  ];
  for(const [error,kind,copy] of cases){
    const controller=UI.createRecommendationRefreshController({
      businessId:'business-1',branchId:'branch-1',
      rpc:async()=>({data:null,error})
    });
    await assert.rejects(controller.refresh());
    const state=controller.snapshot();
    assert.equal(state.mode,kind);
    assert.match(UI.renderRecommendationRefresh(state),copy);
  }
});

test('customer view shows only active issued treatment offers',()=>{
  const now=Date.parse('2026-07-30T00:00:00Z');
  const offers=UI.normalizeCustomerOffers({offers:[
    {
      entitlement_id:'issued',label:'SGD 5 credit',type:'credit_cents',
      value_cents:500,currency:'SGD',status:'issued',
      expires_at:'2026-08-01T00:00:00Z'
    },
    {
      entitlement_id:'expired',label:'Old',value_cents:500,status:'issued',
      expires_at:'2026-07-29T00:00:00Z'
    },
    {
      entitlement_id:'redeemed',label:'Used',value_cents:500,status:'redeemed',
      expires_at:'2026-08-01T00:00:00Z'
    },
    {
      entitlement_id:'missing-value',label:'Unknown',value_cents:null,currency:'SGD',
      status:'issued',expires_at:'2026-08-01T00:00:00Z'
    },
    {
      entitlement_id:'missing-currency',label:'Unknown',value_cents:500,
      status:'issued',expires_at:'2026-08-01T00:00:00Z'
    }
  ]},now);
  assert.deepEqual(offers.map(offer=>offer.entitlementId),['issued']);
  const html=UI.renderCustomerOffers({state:'ready',offers,businessName:'Demo Spa'});
  assert.match(html,/Just for you/);
  assert.match(html,/Redeem now/);
  assert.match(html,/SGD 5\.00/);
  assert.equal(UI.renderCustomerOffers({state:'empty',offers:[]}), '');
  assert.equal(UI.renderCustomerOffers({state:'holdout',offers:[]}), '');
  assert.equal(UI.renderCustomerOffers({state:'disabled',offers:[]}), '');
});

test('customer QR preparation is one idempotent request under double-click and retries',async()=>{
  const calls=[];
  let release;
  const pending=new Promise(resolve=>{release=resolve});
  const controller=UI.createCustomerController({
    makeId:()=> '44444444-4444-4444-8444-444444444444',
    rpc:async(name,args)=>{
      calls.push({name,args});await pending;
      return {data:{
        intent_id:'intent-1',token:'opaque-token',
        expires_at:'2026-07-30T00:05:00Z',replayed:false
      }};
    }
  });
  const first=controller.prepare('entitlement-1');
  const second=controller.prepare('entitlement-1');
  assert.equal(calls.length,1);
  release();
  const intent=await first;
  assert.equal(intent.token,'opaque-token');
  assert.deepEqual(calls[0],{
    name:'customer_prepare_growth_offer_qr_v108',
    args:{
      p_entitlement:'entitlement-1',
      p_idempotency_key:'44444444-4444-4444-8444-444444444444'
    }
  });
});

test('growth offer QR uses its own deep link and cannot collide with classic reward QR',()=>{
  const url=UI.buildGrowthRedeemUrl('opaque token',{
    origin:'https://www.nestly.asia',pathname:'/business'
  });
  assert.equal(url,'https://www.nestly.asia/business#/growth-redeem?token=opaque%20token');
  assert.doesNotMatch(url,/#\/redeem\?/);
});

test('error renderer keeps retry clear while empty/holdout render no offer shell',()=>{
  const html=UI.renderCustomerOffers({
    state:'error',businessName:'Demo Spa',
    error:{kind:'error',message:'Offers could not be loaded.'}
  });
  assert.match(html,/Try again/);
  assert.match(html,/role="alert"/);
});

test('mobile CSS uses one-column actions, 48px targets, and reduced motion',async()=>{
  const css=await read('app/growth-offers.css');
  assert.match(css,/@media\(max-width:620px\)/);
  assert.match(css,/\.growth-button,[\s\S]*min-height:48px/);
  assert.match(css,/\.growth-customer-offer-grid,[\s\S]*grid-template-columns:1fr/);
  assert.match(css,/@media\(prefers-reduced-motion:reduce\)/);
});

test('index integrates all v108 owner and customer RPCs without changing classic QR route',async()=>{
  const [index,module]=await Promise.all([
    read('app/index.html'),read('app/growth-offers.js')
  ]);
  assert.match(index,/growth-offers\.css/);
  assert.match(index,/growth-offers\.js/);
  assert.match(module,/preview_growth_recommendation_v108/);
  assert.match(module,/approve_growth_recommendation_v108/);
  assert.match(module,/dismiss_growth_recommendation_v108/);
  assert.match(index,/customer_get_growth_offers_v108/);
  assert.match(module,/customer_prepare_growth_offer_qr_v108/);
  assert.match(index,/#\/redeem\?token=/);
  assert.match(index,/showGrowthOfferQr/);
  assert.match(index,/buildGrowthRedeemUrl/);
});
