import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');

test('v93 merchant scan requires an active visible branch and preserves canonical redemption', async () => {
  const migration = await read(
    'db/migrations/20260728_nestly_v93_branch_scoped_merchant_redemption.sql',
  );
  assert.match(
    migration,
    /create or replace function public\.merchant_scan_redemption_qr_v93\(\s*p_business uuid,\s*p_branch uuid,/i,
  );
  assert.match(migration, /branch\.business_id=p_business[\s\S]*?branch\.active/i);
  assert.match(migration, /app\.can_see_branch\(p_business,p_branch\)/i);
  assert.match(migration, /public\.redeem_reward_at_context\([\s\S]*?p_branch/i);
  assert.match(migration, /public\.redeem_points\(/i);
  assert.match(migration, /'branch_id',p_branch/i);
  assert.match(
    migration,
    /grant execute on function public\.merchant_scan_redemption_qr_v93\(\s*uuid,uuid,text,uuid\s*\) to authenticated/i,
  );
  assert.match(
    migration,
    /revoke execute on function public\.merchant_scan_redemption_qr_v89\(\s*uuid,text,uuid\s*\) from public,anon,authenticated/i,
  );
});

test('Quick Earn sends the selected accessible till branch to the current scanner', async () => {
  const app = ((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  const scanner = app.slice(
    app.indexOf('function openMerchantRedemptionScanner'),
    app.indexOf('function renderMerchantRedemptionComplete', app.indexOf('function openMerchantRedemptionScanner')),
  );
  const till = app.slice(
    app.indexOf('async function tillPage'),
    app.indexOf('async function appointmentsPage', app.indexOf('async function tillPage')),
  );
  assert.match(
    scanner,
    /function openMerchantRedemptionScanner\(\{\s*businessId,branchId,/,
  );
  assert.match(
    scanner,
    /sb\.rpc\('merchant_scan_redemption_qr_v117',\{[\s\S]*?p_business:businessId,p_branch:branchId,/,
  );
  assert.match(
    till,
    /assignedTillBranches=\(tillBranches\|\|\[\]\)\.filter\(branch=>canSeeAllTillBranches\|\|tillAssignedBranchIds\.has\(branch\.id\)\)/,
  );
  assert.match(
    till,
    /accessibleTillBranches=assignedTillBranches\.filter\(branch=>\s*branchCanWrite\(branch\.id,'till'\)&&branchCanRead\(branch\.id,'clients'\)\s*\)/,
  );
  assert.match(
    till,
    /let tillBranchId=accessibleTillBranches\.some\(branch=>branch\.id===selectedBranchId\)\?selectedBranchId:/,
  );
  assert.match(
    till,
    /tillBranchId=\$\('tBranch'\)\.value;selectedBranchId=tillBranchId;/,
  );
  assert.equal(
    (till.match(/openMerchantRedemptionScanner\(\{\s*businessId:S\.biz\.id,branchId:tillBranchId,/g)||[]).length,
    4,
    'the header, selected-customer, standard receipt, and cart receipt scanners must use the active accessible branch',
  );
});

test('completed-sale receipt scanners preserve branch scope and missing branch fails before RPC', async () => {
  const app = ((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  const scanner = app.slice(
    app.indexOf('function openMerchantRedemptionScanner'),
    app.indexOf('function renderMerchantRedemptionComplete', app.indexOf('function openMerchantRedemptionScanner')),
  );
  const till = app.slice(
    app.indexOf('async function tillPage'),
    app.indexOf('async function appointmentsPage', app.indexOf('async function tillPage')),
  );
  /* V290 retarget: the branch requirement is now stated positively as the kind that needs it.
     'growth' was already exempt (it scopes through the completed sale); 'promotion' is exempt for
     the same reason — it records an acceptance, not a branch-scoped reward. The invariant this
     test exists to hold is that a CLASSIC reward redemption never reaches the RPC without one. */
  assert.match(
    scanner,
    /payload\.kind==='classic'&&!branchId[\s\S]*Choose an accessible branch before confirming this reward\.[\s\S]*return;/,
  );
  assert.match(
    till,
    /id="tRedeemOffer"[\s\S]*openMerchantRedemptionScanner\(\{\s*businessId:S\.biz\.id,branchId:tillBranchId,\s*saleId:doneInfo\.saleId/,
  );
  assert.match(
    till,
    /id="tRedeemOffer"[\s\S]*openMerchantRedemptionScanner\(\{\s*businessId:S\.biz\.id,branchId:tillBranchId,\s*saleId:d\.saleId/,
  );
});

test('rollback-only v117 campaign proves exact branch denial and no-mutation boundaries', async () => {
  const campaign = await read('db/tests/v117_effective_loyalty_boundaries.sql');
  assert.match(campaign, /^begin;/m);
  assert.match(campaign, /^rollback;/m);
  assert.match(campaign, /firm-disabled Loyalty exposed customer capability/i);
  assert.match(campaign, /firm-disabled Loyalty created a redemption intent/i);
  assert.match(campaign, /branch-disabled Loyalty changed redemption state/i);
  assert.match(campaign, /branch-enabled Loyalty scanner did not complete once/i);
  assert.match(campaign, /branch-disabled gift-card issuance created value/i);
  assert.match(campaign, /existing gift liability was not redeemable through Till/i);
});
