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
  const app = await read('app/index.html');
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
    /accessibleTillBranches=assignedTillBranches\.filter\(branch=>\s*branchCanWrite\(branch\.id,'till'\)&&branchCanRead\(branch\.id,'clients'\)\s*\)/,
  );
  assert.match(
    till,
    /openMerchantRedemptionScanner\(\{\s*businessId:S\.biz\.id,branchId:tillBranchId,/,
  );
});

test('rollback-only campaign proves denial, branch provenance, replay, and zero residue', async () => {
  const campaign = await read('db/tests/v93_synthetic_e2e_campaign.sql');
  assert.match(campaign, /^begin;/m);
  assert.match(campaign, /^rollback;/m);
  assert.match(campaign, /front desk completed a redemption outside its assigned branch/i);
  assert.match(campaign, /front desk downgraded to the branchless v89 scanner/i);
  assert.match(campaign, /denied legacy scan changed redemption state/i);
  assert.match(campaign, /eligibility_snapshot#>>'\{selected,branch_id\}'/i);
  assert.match(campaign, /merchant QR replay produced another economic effect/i);
  assert.match(campaign, /synthetic campaign left database residue after rollback/i);
});
