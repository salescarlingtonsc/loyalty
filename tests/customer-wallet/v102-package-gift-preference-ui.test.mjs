import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const app=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');
const helperStart=app.indexOf('function giftCardAbilitiesV102');
const helperEnd=app.indexOf('function serviceDisplayName',helperStart);
assert.ok(helperStart>=0&&helperEnd>helperStart,'v102 UI contract helpers must exist');
const helpers=new Function(
  `${app.slice(helperStart,helperEnd)};return {giftCardAbilitiesV102,packageSaleResultV102,packageUseResultV102,checkoutPreferencesStateV102,packageUseAttemptKeyV102,checkoutPointsReceiptV102};`
)();
const section=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0&&to>from,`missing section ${start}`);
  return app.slice(from,to);
};

test('gift-card sale flag gates issuance only while existing-card redemption follows authority',()=>{
  const common={createSales:true,giftcardsReadable:true,giftcardsWritable:true};
  assert.deepEqual(helpers.giftCardAbilitiesV102({...common,businessEnabled:false}),{
    canIssue:false,canRedeem:true
  });
  assert.deepEqual(helpers.giftCardAbilitiesV102({...common,businessEnabled:null}),{
    canIssue:false,canRedeem:true
  });
  assert.deepEqual(helpers.giftCardAbilitiesV102({...common,businessEnabled:true}),{
    canIssue:true,canRedeem:true
  });
  assert.deepEqual(helpers.giftCardAbilitiesV102({...common,giftcardsWritable:false,businessEnabled:true}),{
    canIssue:false,canRedeem:false
  });
  const page=section('async function giftcardsPage','async function inventoryPage');
  assert.match(page,/const canIssue=abilities\.canIssue,canRedeem=abilities\.canRedeem/);
  assert.match(page,/canIssue&&\$\('gsell'\)/);
  assert.match(page,/canRedeem&&\$\('gredeem'\)/);
  assert.match(page,/Existing cards can still be redeemed/);
});

test('preference failure is unknown and fail-closed, never silently points-enabled',()=>{
  assert.deepEqual(helpers.checkoutPreferencesStateV102({error:{message:'offline'}}),{
    available:false,giftCardSalesEnabled:null,packageEarnsPoints:null
  });
  assert.deepEqual(helpers.checkoutPreferencesStateV102({data:{status:'unknown'}}),{
    available:false,giftCardSalesEnabled:null,packageEarnsPoints:null
  });
  assert.deepEqual(helpers.checkoutPreferencesStateV102({data:{
    status:'available',gift_card_sales_enabled:true
  }}),{
    available:false,giftCardSalesEnabled:null,packageEarnsPoints:null
  },'an available-shaped response with a missing boolean is still unknown');
  assert.deepEqual(helpers.checkoutPreferencesStateV102({data:{
    status:'available',gift_card_sales_enabled:true,package_earns_points:false
  }}),{available:true,giftCardSalesEnabled:true,packageEarnsPoints:false});

  const till=section('async function tillPage','async function salesPage');
  assert.doesNotMatch(till,/preferences\.error\?true/);
  assert.match(till,/Package points setting is unavailable/);
  const packages=section('async function packagesPage','async function branchesPage');
  assert.match(packages,/Package points setting unavailable/);
  assert.match(packages,/The setting control is hidden/);
  assert.match(packages,/S\.myRole==='owner'&&preferencesAvailable/);
});

test('package session retries retain one key per exact package and branch',()=>{
  const attempts=new Map();
  let made=0;
  const create=()=>`key-${++made}`;
  const first=helpers.packageUseAttemptKeyV102(attempts,'cp-1','branch-a',create);
  const ambiguousRetry=helpers.packageUseAttemptKeyV102(attempts,'cp-1','branch-a',create);
  const otherBranch=helpers.packageUseAttemptKeyV102(attempts,'cp-1','branch-b',create);
  assert.deepEqual(first,ambiguousRetry);
  assert.equal(made,2);
  assert.notEqual(otherBranch.key,first.key);
  assert.deepEqual(helpers.packageUseResultV102({
    status:'completed',replayed:false,consumption_id:'consume-1',sale_id:'sale-1',
    client_package_id:'cp-1',client_id:'client-1',branch_id:'branch-a',
    remaining_before:4,remaining_after:3,points_earned:0,points_total:240
  }),{
    consumptionId:'consume-1',saleId:'sale-1',clientPackageId:'cp-1',
    branchId:'branch-a',remainingBefore:4,remainingAfter:3,
    pointsEarned:0,pointsTotal:240,replayed:false
  });
  assert.equal(helpers.packageUseResultV102({
    status:'completed',sale_id:'sale-1',client_package_id:'cp-1',
    branch_id:'branch-a',remaining_after:3,points_earned:0,points_total:240
  }),null,'an incomplete success is ambiguous and must retain its retry key');

  for(const source of [
    section('async function tillPage','async function salesPage'),
    section('async function packagesPage','async function branchesPage')
  ]){
    assert.match(source,/sb\.rpc\('use_package_session_v102'/);
    assert.match(source,/p_client_package:/);
    assert.match(source,/p_branch:/);
    assert.match(source,/p_idempotency_key:attempt\.key/);
    assert.match(source,/packageUseResultV102\(data\)/);
    assert.doesNotMatch(source,/sb\.rpc\('use_package_session'/);
  }
});

test('package sale UI accepts only authoritative v102 receipt IDs and exact points',()=>{
  assert.deepEqual(helpers.packageSaleResultV102({
    status:'completed',sale_id:'sale-1',client_package_id:'cp-1',
    points_earned:17,points_total:240,replayed:true
  }),{
    saleId:'sale-1',clientPackageId:'cp-1',pointsEarned:17,pointsTotal:240,replayed:true
  });
  assert.equal(helpers.packageSaleResultV102({
    status:'completed',client_package_id:'cp-1',points_earned:17,points_total:240
  }),null);
  const appPackageCalls=[...app.matchAll(/sb\.rpc\('sell_package_v102'/g)];
  assert.equal(appPackageCalls.length,2,'Quick Earn and standalone Packages must use v102');
  assert.doesNotMatch(app,/sb\.rpc\('sell_package'/);
  assert.match(app,/p_branch:tillBranchId/);
  assert.match(app,/p_branch:\$\('kSaleBranch'\)\.value/);
  assert.match(app,/packageSaleResultV102\(res\.data\)/);
  assert.match(app,/packageSaleResultV102\(data\)/);
  assert.doesNotMatch(app,/pointsTotal\s*:\s*[^,}\n]*(?:balance|before|after)/i);
});

test('Quick Earn receipt sums operation receipts and never attributes concurrent ledger movement',()=>{
  const result=helpers.checkoutPointsReceiptV102({
    saleResult:{pointsEarned:5,pointsTotal:null},
    packageResults:[
      {pointsEarned:10,pointsTotal:210},
      {pointsEarned:3,pointsTotal:213}
    ],
    // Another operation moved the ledger after checkout. This must not become “points earned”.
    refreshedPoints:313
  });
  assert.equal(result.pointsEarned,18);
  assert.equal(result.pointsTotal,213,'the last writer receipt is the checkout balance snapshot');
  assert.equal(result.balanceConsistent,false);
  assert.deepEqual(result.operations.map(item=>[item.kind,item.pointsEarned]),[
    ['sale',5],['package',10],['package',3]
  ]);

  assert.deepEqual(helpers.checkoutPointsReceiptV102({
    saleResult:{pointsEarned:5,pointsTotal:null},
    packageResults:[],
    refreshedPoints:155
  }),{
    pointsEarned:5,
    pointsTotal:155,
    balanceConsistent:true,
    operations:[{kind:'sale',pointsEarned:5,pointsTotal:null}]
  },'a refreshed balance is only a total fallback, never an earned-points delta');

  const unavailable=helpers.checkoutPointsReceiptV102({
    saleResult:{pointsEarned:5,pointsTotal:null},packageResults:[],refreshedPoints:null
  });
  assert.equal(unavailable.pointsEarned,5);
  assert.equal(unavailable.pointsTotal,null,'never infer the balance from a stale client value');

  const till=section('async function tillPage','async function salesPage');
  assert.match(till,/checkoutPointsReceiptV102\(/);
  assert.match(till,/line\.type==='package'&&line\._status==='done'&&line\._packageResult/);
  assert.match(till,/pointsEarned:l\.type==='package'\?Number\(l\._packageResult\?\.pointsEarned/);
  assert.doesNotMatch(till,/refreshedPoints-beforePoints/);
  assert.doesNotMatch(till,/Math\.max\(0,refreshedPoints/);
});

test('package authoring is clone/version based and sold history uses frozen snapshots',()=>{
  const packages=section('async function packagesPage','async function branchesPage');
  assert.match(packages,/Create new version/);
  assert.match(packages,/Save new version/);
  assert.match(packages,/workspaceTemplateTextV97\('packageVersionCreated'/);
  assert.match(app,/packageVersionCreated:Object\.freeze\(\{en:'New package version v\{version\} created; prior version archived'/);
  assert.match(packages,/This version is frozen/);
  assert.match(packages,/Existing customer purchases keep their original price, sessions and service snapshot/);
  assert.match(packages,/staff_list_package_entitlements_v102/);
  assert.match(packages,/plan_version/);
  assert.match(packages,/price_cents/);
  assert.doesNotMatch(packages,/client_packages'\)\.select\('\*, clients/);
});

test('Customer 360 package history reads the purchase snapshot, never the mutable plan',()=>{
  const customer=section('async function clientDetail','async function tillPage');
  assert.match(customer,/plan_name_snapshot/);
  assert.match(customer,/sessions_snapshot/);
  assert.match(customer,/plan_version_snapshot/);
  assert.match(customer,/price_cents_snapshot/);
  assert.match(customer,/service_name_snapshot/);
  assert.match(customer,/list_value_cents_snapshot/);
  assert.match(customer,/plan:k\.plan_name_snapshot/);
  assert.match(customer,/sessions:k\.sessions_snapshot/);
  assert.doesNotMatch(customer,/client_packages'\)\.select\('[^']*package_plans/);
  assert.doesNotMatch(customer,/k\.package_plans\?\./);
});
