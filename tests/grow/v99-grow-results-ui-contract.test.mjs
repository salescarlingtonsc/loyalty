import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));
const sql=await readFile(
  new URL('../../supabase/migrations/20260729130000_nestly_v99_campaign_truth.sql',import.meta.url),
  'utf8'
);
const from=app.indexOf('function pbResultsHtml');
const to=app.indexOf('async function pbRecordReturns',from);
assert.ok(from>=0&&to>from,'pbResultsHtml source must exist');
const source=app.slice(from,to);
const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({
  '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
})[char]);
const render=new Function('esc','walletDate','CUI',`${source};return pbResultsHtml;`)(
  esc,
  value=>value?`SGT:${value}`:'',
  {icon:()=>'<svg></svg>'}
);

const awaitingFixture={
  campaign_id:'10000000-0000-4000-8000-000000000001',
  business_id:'20000000-0000-4000-8000-000000000001',
  campaign_status:'active',
  measurement_status:'awaiting_verified_exposure',
  claimability:'no_lift_or_roi_claim',
  delivery_provider_status:'not_configured',
  treatment:{
    members:4,grant_records:4,verified_exposures:2,
    legacy_or_unverified_grants:2,returned:null,return_rate_bps:null,revenue_cents:null
  },
  holdout:{members:2,returned:null,return_rate_bps:null,revenue_cents:null},
  observed_return_rate_difference_bps:null,
  net_lift_bps:null,incremental_returns:null,incremental_revenue_cents:null,
  legacy_v50_return_evidence_used:false,
  measurement_note:'Seal only after every treatment member has a linked reward and verified exposure.'
};
const collectingFixture={
  ...awaitingFixture,
  measurement_status:'collecting',
  claimability:'descriptive_observation_not_causal_proof',
  measurement_started_at:'2026-07-29T01:00:00Z',
  measurement_ends_at:'2026-08-28T01:00:00Z',
  minimum_sample_per_arm:30,
  minimum_sample_met:true,
  treatment:{
    members:40,grant_records:40,verified_exposures:40,
    legacy_or_unverified_grants:0,returned:8,return_rate_bps:2000,revenue_cents:80000
  },
  holdout:{members:40,returned:6,return_rate_bps:1500,revenue_cents:60000},
  observed_return_rate_difference_bps:500,
  observed_revenue_difference_cents:20000,
  measurement_note:'Observed differences are descriptive. No lift, ROI, or statistical-significance claim is made.'
};

test('v99 result response fields are consumed directly by the Grow renderer',()=>{
  for(const field of [
    'campaign_status','measurement_status','grant_records','verified_exposures',
    'legacy_or_unverified_grants','measurement_started_at','measurement_ends_at',
    'minimum_sample_per_arm','observed_return_rate_difference_bps','measurement_note'
  ]){
    assert.match(sql,new RegExp(`'${field}'`),`${field} must be returned by v99`);
    assert.match(source,new RegExp(field),`${field} must be consumed by the UI`);
  }
});

test('awaiting exposure state shows manual evidence progress and no return action',()=>{
  const html=render(awaitingFixture,{isOwner:true});
  assert.match(html,/Measurement not started/);
  assert.match(html,/2 of 4 treatment customers/);
  assert.match(html,/Campaign grant records[\s\S]*>4</);
  assert.match(html,/Manual receipt confirmations[\s\S]*2\/4/);
  assert.match(html,/not a provider delivery receipt/);
  assert.doesNotMatch(html,/Refresh observed returns|Treatment observed return rate|Mark complete/);
});

test('sealed collecting state renders descriptive observations and permits refresh only',()=>{
  const html=render(collectingFixture,{isOwner:true});
  assert.match(html,/Collecting observed returns/);
  assert.match(html,/Treatment observed return rate[\s\S]*20\.0%/);
  assert.match(html,/Held-back observed return rate[\s\S]*15\.0%/);
  assert.match(html,/Observed return-rate difference[\s\S]*\+5\.0 points/);
  assert.match(html,/Descriptive only/);
  assert.match(html,/Refresh observed returns/);
  assert.match(html,/Mark complete/);
  assert.doesNotMatch(html,/incremental return|incremental sales|caused by|provider delivered/i);
});

test('completed minimum-sample state stays inconclusive and read-only for non-owner',()=>{
  const html=render({
    ...collectingFixture,
    campaign_status:'completed',
    measurement_status:'inconclusive_minimum_sample',
    minimum_sample_met:false
  },{isOwner:false});
  assert.match(html,/Inconclusive — sample too small/);
  assert.doesNotMatch(html,/Refresh observed returns/);
});

test('Grow UI uses the exact entitlement, manual attestation, then seal RPC contract',()=>{
  const issueStart=app.indexOf('function pbOpenIssueModal');
  const issueEnd=app.indexOf('function pbProgressBar',issueStart);
  const issue=app.slice(issueStart,issueEnd);
  const sealStart=app.indexOf('async function pbSealMeasurement');
  const sealEnd=app.indexOf('async function pbComplete',sealStart);
  const seal=app.slice(sealStart,sealEnd);

  assert.match(issue,/sb\.rpc\('issue_campaign_offer'/);
  for(const request of [
    /p_business:S\.biz\.id/,/p_campaign:c\.campaign_id/,/p_client:t\.client_id/,
    /p_idempotency_key:'v99-entitlement:'/,/p_offer_cost_cents:null/,/p_reward_grant_id:null/
  ])assert.match(issue,request);
  for(const response of [
    /campaign_grant_id/,/reward_grant_id/,/entitlement_status!=='granted'/,
    /!data\?\.fulfillment_kind/,/customer_history_visible!==true/,
    /economic_value_posted!==false/,/delivery_provider_status!=='not_configured'/,
    /redemption_mode!=='merchant_fulfilment_pending'/,
    /\['awaiting_manual_attestation','verified'\]\.includes\(data\?\.exposure_status\)/
  ])assert.match(issue,response);

  assert.match(issue,/sb\.rpc\('attest_campaign_exposure_v99'/);
  for(const request of [
    /p_campaign_grant:row\.campaignGrantId/,/p_channel:attempt\.channel/,
    /p_confirmed:true/,/p_idempotency_key:attempt\.key/,/p_exposed_at:null/,
    /p_evidence_context:\{entry_point:'owner_confirmation'\}/
  ])assert.match(issue,request);
  assert.doesNotMatch(issue,/sb\.rpc\('record_campaign_exposure_v99'/);
  assert.match(issue,/actually received the reward/);
  assert.match(issue,/not a provider delivery receipt/);
  assert.match(issue,/does not add spendable points or store credit/);
  assert.match(issue,/merchant fulfilment remains pending/);

  assert.match(seal,/sb\.rpc\('seal_campaign_measurement_v99'/);
  assert.match(seal,/p_idempotency_key:attempt/);
  assert.match(seal,/Every treatment customer has a manual receipt attestation/);
});

test('active campaign has one state-aware prepare action and cannot complete before sealing',()=>{
  const bodyStart=app.indexOf('function pbBuildBody');
  const bodyEnd=app.indexOf('async function pbRecordReturns',bodyStart);
  const body=app.slice(bodyStart,bodyEnd);
  assert.doesNotMatch(body,/data-pb-issue/);
  assert.equal((body.match(/data-pb-prepare/g)||[]).length,2,
    'one renderer and one event binding should define the state-aware prepare action');
  assert.match(source,/const canComplete=ctx\.isOwner&&hasWindow&&campaignStatus==='active'/);
  assert.match(source,/\$\{canComplete\?`<button[^`]+data-pb-complete/);
});
