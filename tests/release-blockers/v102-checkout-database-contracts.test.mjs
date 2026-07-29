import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const migrationUrl=new URL(
  '../../supabase/migrations/20260729150000_nestly_v102_package_checkout_entitlements.sql',
  import.meta.url
);
const rollbackUrl=new URL(
  '../../db/cutover/v102_package_checkout_entitlements.rollback.sql',
  import.meta.url
);

const functionBlock=(sql,name,nextName)=>{
  const start=sql.indexOf(`create or replace function public.${name}`);
  const end=nextName
    ?sql.indexOf(`create or replace function public.${nextName}`,start+1)
    :sql.length;
  assert.ok(start>=0&&end>start,`missing ${name}`);
  return sql.slice(start,end);
};

test('v102 freezes package money/history with bigint snapshots and clone-on-edit',async()=>{
  const sql=await readFile(migrationUrl,'utf8');
  assert.match(sql,/list_unit_cents_snapshot bigint/);
  assert.match(sql,/list_value_cents_snapshot bigint/);
  assert.match(sql,/price_cents_snapshot bigint/);
  assert.match(sql,/service_duration_min_snapshot integer/);
  assert.match(sql,/v_service\.price_cents::bigint\*p_sessions::bigint/);
  assert.match(sql,/version_no integer not null default 1/);
  assert.match(sql,/supersedes_plan_id uuid references public\.package_plans/);
  const save=functionBlock(sql,'save_package_plan_v102','sell_package_v102');
  assert.match(save,/insert into public\.package_plans[\s\S]*v_previous\.version_no\+1,v_previous\.id/);
  assert.match(save,/update public\.package_plans[\s\S]*set active=false/);
  assert.doesNotMatch(sql,/create policy package_plans_write_v102/);
  assert.match(sql,/revoke insert,update,delete,truncate on table public\.package_plans[\s\S]*authenticated/);
});

test('v102 package sale and session writers are branch-bound and replay exact persisted results',async()=>{
  const sql=await readFile(migrationUrl,'utf8');
  const sale=functionBlock(sql,'sell_package_v102','use_package_session_v102');
  assert.match(sale,/p_branch uuid/);
  assert.match(sale,/'branch_id',p_branch/);
  assert.match(sale,/return v_existing\.result/);
  assert.match(sale,/'sale_id',v_sale_id/);
  assert.match(sale,/ledger\.sale_id=v_sale_id/);
  assert.match(sale,/'points_earned',v_points_earned/);
  assert.match(sale,/'points_total',v_points_total/);
  assert.match(sale,/insert into public\.sale_intent_operations/);

  const session=functionBlock(sql,'use_package_session_v102','issue_gift_card');
  assert.match(session,/p_branch uuid/);
  assert.match(session,/'branch_id',p_branch/);
  assert.match(session,/return v_existing\.result/);
  assert.match(session,/remaining_before,remaining_after,result/);
  assert.match(session,/'points_earned',0/);
  assert.match(session,/ledger\.business_id=p_business and ledger\.client_id=v_package\.client_id/);

  assert.match(sql,/revoke all on function public\.sell_package\(uuid,uuid,uuid\)/);
  assert.match(sql,/revoke all on function public\.sell_package\(uuid,uuid,uuid,uuid\)/);
  assert.match(sql,/revoke all on function public\.use_package_session\(uuid,uuid,text\)/);
});

test('v102 gift-card switch is below completed replay and above every new issuance write',async()=>{
  const sql=await readFile(migrationUrl,'utf8');
  const gift=functionBlock(sql,'issue_gift_card');
  const replay=gift.indexOf("return jsonb_build_object(");
  const disabled=gift.indexOf("raise exception 'gift_card_sales_disabled'");
  const guard=gift.indexOf("perform app.sv_legacy_issue_guard");
  const write=gift.indexOf('insert into public.gift_cards');
  assert.ok(replay>=0&&replay<disabled,'completed replay must precede switch');
  assert.ok(disabled<guard&&guard<write,'new issuance must be gated before every write');
  assert.doesNotMatch(gift,/redeem_gift_card|gift_card_redempt/);
});

test('v102 ships behavioural SQL, ACL coverage and a non-destructive rollback',async()=>{
  const [sql,rollback]=await Promise.all([
    readFile(new URL('../../db/tests/v102_package_checkout_entitlements.sql',import.meta.url),'utf8'),
    readFile(rollbackUrl,'utf8')
  ]);
  assert.match(sql,/v102 points-off package sale awarded or replay drifted/);
  assert.match(sql,/v102 points-on package sale\/replay is not exact ledger truth/);
  assert.match(sql,/v102 completed package receipt drifted after later points/);
  assert.match(sql,/v102 points-on lost-response replay double-earned/);
  assert.match(sql,/v102 package session earned points a second time/);
  assert.match(sql,/v102 authenticated caller executed legacy package sale overload/);
  assert.match(sql,/a legacy sell_package overload remains Data API executable/);
  assert.match(sql,/v102 package sale key accepted changed branch payload/);
  assert.match(sql,/v102 branch session earned again or did not replay exact result/);
  assert.match(sql,/disabled gift-card switch broke exact completed replay/);
  assert.match(sql,/authenticated still has direct package_plans write access/);
  assert.match(rollback,/preserves additive history\/snapshot columns/);
  assert.match(rollback,/drop function if exists public\.sell_package_v102/);
  assert.match(rollback,/alter column plan_name_snapshot drop not null/);
  assert.ok(
    rollback.indexOf('alter column plan_name_snapshot drop not null')
      <rollback.indexOf('grant execute on function public.sell_package(uuid,uuid,uuid,uuid)'),
    'rollback must relax snapshot requirements before restoring the legacy /4 wrapper'
  );
  assert.match(rollback,/revoke all on function public\.sell_package\(uuid,uuid,uuid\)/);
  assert.doesNotMatch(rollback,/drop column|truncate|delete from public\./i);
});
