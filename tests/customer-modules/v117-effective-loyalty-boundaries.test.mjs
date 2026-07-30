import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');
const sourcePath='db/migrations/20260730_nestly_v117_effective_loyalty_boundaries.sql';
const mirrorPath='supabase/migrations/20260730140000_nestly_v117_effective_loyalty_boundaries.sql';

test('v117 source and deploy migration are exact safe mirrors',async()=>{
  const [source,mirror]=await Promise.all([read(sourcePath),read(mirrorPath)]);
  assert.equal(source,mirror);
  assert.match(source,/^-- NESTLY v117 — EFFECTIVE LOYALTY AND BRANCH WRITER BOUNDARIES/m);
  assert.doesNotMatch(
    source,
    /drop\s+(?:table|schema)|disable\s+row\s+level\s+security/i
  );
});

test('customer module projection resolves v94 firm and branch overrides',async()=>{
  const source=await read(sourcePath);
  assert.match(
    source,
    /create or replace function app\.business_module_enabled_at_v117\([\s\S]*?app\.effective_platform_module_mode_v94/
  );
  assert.match(
    source,
    /create or replace function app\.business_module_writable_at_v117\([\s\S]*?resolved\.mode='rw'/
  );
  assert.match(
    source,
    /create or replace function app\.v89_business_module_enabled\([\s\S]*?app\.business_module_writable_at_v117/
  );
  assert.match(
    source,
    /create or replace function app\.v32_customer_wallet_context\([\s\S]*?app\.business_module_enabled_at_v117/
  );
  const staffAggregate=source.slice(
    source.indexOf(
      'create or replace function app.staff_module_mode_at_or_any_v117'
    ),
    source.indexOf(
      'revoke all on function app.staff_module_mode_at_or_any_v117'
    )
  );
  assert.match(
    staffAggregate,
    /not exists\([\s\S]*?branch\.active\s*\)\s*union all/
  );
  assert.doesNotMatch(
    staffAggregate,
    /branch\.active\s+and app\.can_see_branch[\s\S]*?\)\s*union all/
  );
  assert.match(staffAggregate,/union all[\s\S]*?app\.can_see_branch/);
});

test('merchant redemption requires exact branch-effective Loyalty and retires v93',async()=>{
  const source=await read(sourcePath);
  assert.match(
    source,
    /create or replace function public\.merchant_scan_redemption_qr_v117\([\s\S]*?app\.can_module_write_at_v94\(p_business,p_branch,'loyalty'\)/
  );
  assert.match(
    source,
    /app\.redeem_points_v40_internal\([\s\S]*?app\.redeem_reward_core\(/
  );
  assert.doesNotMatch(
    source,
    /v_result:=public\.(?:redeem_points|redeem_reward_at_context)\(/
  );
  assert.match(
    source,
    /revoke all on function public\.merchant_scan_redemption_qr_v93\([\s\S]*?from public,anon,authenticated/
  );
  assert.match(
    source,
    /grant execute on function public\.merchant_scan_redemption_qr_v117\([\s\S]*?to authenticated/
  );
});

test('gift issuance is branch-aware while existing liability redemption uses Till authority',async()=>{
  const source=await read(sourcePath);
  assert.match(
    source,
    /create table if not exists public\.gift_card_redeem_operations_v117[\s\S]*?unique \(business_id,idempotency_key\)/
  );
  assert.match(
    source,
    /alter table public\.gift_card_redeem_operations_v117[\s\S]*?enable row level security[\s\S]*?revoke all privileges on table public\.gift_card_redeem_operations_v117/
  );
  assert.match(
    source,
    /create trigger gift_card_redeem_operations_v117_immutable_guard[\s\S]*?app\.v41_operation_immutable_guard/
  );
  assert.match(
    source,
    /create or replace function public\.issue_gift_card_at_branch_v117\([\s\S]*?app\.can_module_write_at_v94\(\s*p_business,p_branch,'giftcards'\s*\)/
  );
  assert.match(
    source,
    /insert into public\.sales\([\s\S]*?branch_id[\s\S]*?p_branch/
  );
  assert.match(
    source,
    /create or replace function public\.redeem_gift_card_at_branch_v117\([\s\S]*?app\.can_module_write_at_v94\(p_business,p_branch,'till'\)/
  );
  assert.match(source,/p_idempotency_key uuid[\s\S]*?pg_advisory_xact_lock/);
  assert.match(
    source,
    /from public\.gift_card_redeem_operations_v117 operation[\s\S]*?jsonb_build_object\('replayed',true\)/
  );
  assert.match(
    source,
    /drop function if exists public\.redeem_gift_card_at_branch_v117\(\s*uuid,uuid,text,uuid,integer\s*\)/
  );
  assert.match(
    source,
    /create or replace function public\.business_has_active_gift_liability_v117\([\s\S]*?balance_cents>0/
  );
  assert.match(
    source,
    /revoke all on function public\.issue_gift_card\(uuid,integer,uuid,text,uuid\)[\s\S]*?revoke all on function public\.redeem_gift_card_v41\(uuid,text,uuid,integer\)/
  );
});

test('merchant UI consumes only v117 branch-bound writers and hides absent liabilities',async()=>{
  const app=await read('app/index.html');
  const till=app.slice(
    app.indexOf('async function tillPage(){'),
    app.indexOf('async function salesPage(){')
  );
  const giftCards=app.slice(
    app.indexOf('async function giftcardsPage(){'),
    app.indexOf('/* ---------- billing (read-only) ---------- */')
  );
  assert.match(till,/business_has_active_gift_liability_v117[\s\S]*?p_branch:tillBranchId/);
  assert.match(till,/hasActiveGiftLiability\?`<div class="permission-banner"[\s\S]*?<b>Redeem an existing gift card/);
  assert.match(till,/redeem_gift_card_at_branch_v117[\s\S]*?p_branch:tillBranchId/);
  assert.match(till,/redeem_gift_card_at_branch_v117[\s\S]*?p_idempotency_key:writeAttemptKey/);
  assert.match(till,/issue_gift_card_at_branch_v117[\s\S]*?p_branch:tillBranchId/);
  assert.doesNotMatch(till,/sb\.rpc\('issue_gift_card'/);
  assert.doesNotMatch(till,/sb\.rpc\('redeem_gift_card(?:_v41)?'/);
  assert.match(giftCards,/get_my_modules_at_v115[\s\S]*?p_branch:branch\.id/);
  assert.match(giftCards,/issue_gift_card_at_branch_v117[\s\S]*?p_branch:giftBranchId/);
  assert.match(giftCards,/redeem_gift_card_at_branch_v117[\s\S]*?p_branch:giftBranchId/);
  assert.match(giftCards,/redeem_gift_card_at_branch_v117[\s\S]*?p_idempotency_key:writeAttemptKey/);
});

test('390px acceptance harness cannot add outer overflow or clip the application viewport',async()=>{
  const harness=await read('tests/browser/v117-effective-loyalty-mobile.html');
  assert.match(harness,/body\.single-view\s*\{[\s\S]*?width:\s*100vw[\s\S]*?padding:\s*0[\s\S]*?overflow:\s*hidden/);
  assert.match(harness,/body\.single-view iframe\s*\{[\s\S]*?width:\s*100vw[\s\S]*?height:\s*100vh/);
  assert.match(harness,/document\.body\.classList\.add\('single-view'\)/);
});

test('writer registry retires superseded browser gift and QR entry points',async()=>{
  const registry=JSON.parse(await read('docs/design/ps0/writer-registry.json'));
  const byId=new Map(registry.writers.map((writer)=>[writer.id,writer]));
  for(const id of[
    'db.fn:public.redeem_gift_card_v41/4',
    'db.fn:public.redeem_gift_card/4',
    'db.fn:public.merchant_scan_redemption_qr_v93/4'
  ]){
    const writer=byId.get(id);
    assert.ok(writer,`missing ${id}`);
    assert.match(`${writer.entry_point} ${writer.callers} ${writer.kernel}`,/(retired|internal historical)/i);
    assert.doesNotMatch(writer.callers,/browser Quick earn QR scanner|which the UI calls/i);
  }
});

test('rollback acceptance covers denied module overrides and persistent no-mutation checks',async()=>{
  const sql=await read('db/tests/v117_effective_loyalty_boundaries.sql');
  assert.match(sql,/^begin;/m);
  assert.match(sql,/^rollback;/m);
  assert.match(sql,/firm-disabled Loyalty exposed customer capability/i);
  assert.match(sql,/firm-disabled Loyalty created a redemption intent/i);
  assert.match(sql,/read-only Loyalty advertised an unfulfillable QR/i);
  assert.match(sql,/read-only Loyalty created an unfulfillable QR/i);
  assert.match(sql,/unassigned front desk inherited firm or branch modules/i);
  assert.match(sql,/obsolete redemption execution remained available to a browser role/i);
  assert.match(sql,/branch-disabled Loyalty changed redemption state/i);
  assert.match(sql,/branch-enabled Loyalty replay changed economic state/i);
  assert.match(sql,/branch-disabled gift-card issuance created value/i);
  assert.match(sql,/existing gift liability was not redeemable through Till/i);
  assert.match(sql,/gift-card redemption replay changed economic state/i);
});
