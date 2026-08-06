import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));
const sql=await readFile(
  new URL('../../db/migrations/20260729_nestly_v99_campaign_truth.sql',import.meta.url),
  'utf8'
);
const helperStart=app.indexOf('function campaignEntitlementDisplayV99');
const helperEnd=app.indexOf('function customerRedemptionIntentArgsV89',helperStart);
assert.ok(helperStart>=0&&helperEnd>helperStart,'campaign entitlement display helper must exist');
const helperSource=app.slice(helperStart,helperEnd);
const display=new Function(`${helperSource};return campaignEntitlementDisplayV99;`)();
const section=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing ${start}`);
  return app.slice(from,to);
};

test('customer wallet campaign entitlement hides granted/economic language and value',()=>{
  const view=display({
    is_campaign_entitlement:true,
    campaign_id:'campaign-1',
    title:'SGD 50 comeback credit granted',
    reward_label:'Comeback reward',
    display_label:'Offer awaiting merchant fulfilment',
    status:'granted',
    reward_value:5000,
    redemption_mode:'merchant_fulfilment_pending',
    economic_value_posted:false,
    reward_value_hidden:true
  });
  assert.deepEqual(view,{
    pending:true,
    title:'Offer awaiting merchant fulfilment',
    status:'Merchant fulfilment pending',
    detail:'No wallet value was posted. The business must fulfil this reward before it can be used.',
    showValue:false
  });
  const rendered=JSON.stringify(view);
  assert.doesNotMatch(rendered,/\bgranted\b|\bearned\b|5000|SGD 50/i);
});

test('v99 customer and staff projections expose only display-safe campaign economics',()=>{
  for(const field of [
    'is_campaign_entitlement','entitlement_status','fulfillment_status',
    'redemption_mode','economic_value_posted','fulfillment_kind','reward_label',
    'reward_value_hidden','display_label','display_amount_cents'
  ])assert.match(sql,new RegExp(`'${field}'`),field);
  assert.match(sql,/create or replace function public\.customer_get_loyalty_details/);
  assert.match(sql,/create or replace function public\.staff_get_reward_entitlements_v99/);
  assert.match(sql,/'Offer awaiting merchant fulfilment'/);
  assert.match(sql,/'No wallet value has been posted\. Ask the business to fulfil this offer\.'/);
  assert.match(sql,/'display_amount_cents',case[\s\S]+reward\.campaign_id is null/);
});

test('Customer 360 campaign grant uses the same pending no-wallet-value truth',()=>{
  const view=display({
    campaign_id:'campaign-2',
    reward_label:'Return visit reward',
    display_label:'Offer awaiting merchant fulfilment',
    status:'granted',
    fulfillment_kind:'credit',
    reward_value:2500,
    reward_value_hidden:true
  });
  assert.equal(view.pending,true);
  assert.equal(view.status,'Merchant fulfilment pending');
  assert.equal(view.showValue,false);
  assert.match(view.detail,/No wallet value was posted/);
  assert.doesNotMatch(JSON.stringify(view),/\bgranted\b|\bearned\b|2500|credit/i);
});

test('both customer activity and Customer 360 render pending campaign truth without a value',()=>{
  const wallet=section('const activityState={items:[]','const transactionState=');
  assert.match(wallet,/campaignEntitlementDisplayV99\(item\)/);
  assert.match(wallet,/campaign\.pending\?'<span class="pill off">Pending with business<\/span>'/);

  const customer360=section('async function clientDetail','/* ---------- quick earn');
  assert.match(customer360,/staff_get_reward_entitlements_v99/);
  assert.match(customer360,/campaignEntitlementDisplayV99\(g\)/);
  assert.match(customer360,/Merchant fulfilment pending/);
  assert.match(customer360,/No wallet value was posted/);
  assert.doesNotMatch(customer360,/<b>Retention rewards earned<\/b>/);

  const timeline=section('function renderHistPage','/* ---------- quick earn');
  assert.match(timeline,/campaignEntitlementDisplayV99\(h\)/);
  assert.match(timeline,/Campaign reward pending/);
  assert.ok(
    timeline.indexOf('if(campaign.pending)')<timeline.indexOf("const value=h.fulfillment_kind==='credit'"),
    'pending campaign branch must return before any economic value is formatted'
  );
});

test('ordinary fulfilled non-campaign retention rewards keep their historical display path',()=>{
  const view=display({
    reward_label:'Visit goal reward',
    status:'redeemed',
    detail:'Used at counter'
  });
  assert.equal(view.pending,false);
  assert.equal(view.showValue,true);
  assert.equal(view.status,'redeemed');
});
