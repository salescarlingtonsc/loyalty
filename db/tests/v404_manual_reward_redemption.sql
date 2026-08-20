-- Rollback-only acceptance for v404 — manual (no-QR) reward redemption.
--   supabase db query --linked -f db/tests/v404_manual_reward_redemption.sql
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- Owner ruling 2026-08-21 (photo 1): "Redeem = manual staff redemption without customer QR",
-- owner/manager by default, every other staff member only by an explicit grant, quantity like
-- Record Sale, and an audit trail carrying method='manual_no_qr'.
--
-- The point of this suite is the PERMISSION MATRIX and the DOUBLE-REDEMPTION guard. Eligibility,
-- balance and the ledger belong to app.redeem_reward_core, which has its own coverage; what is
-- new here is who may call it without a QR, how many times, and what evidence that leaves.

begin;

create temp table _r(k text, v text) on commit drop;
create temp table _c(biz uuid, br uuid, slug text, cli uuid,
                     owner_u uuid, mgr_u uuid, staff_u uuid, staff_s uuid, owner_s uuid) on commit drop;
grant select,insert,update,delete on _r,_c to authenticated;
insert into _c(slug) values ('zz-v404-'||substr(md5(random()::text),1,8));

with i as (insert into public.businesses(name,slug,enabled_modules)
  select 'ZZ V404',slug,array['loyalty','clients'] from _c returning id)
update _c set biz=(select id from i);
with i as (insert into public.branches(business_id,name) select biz,'Main' from _c returning id)
update _c set br=(select id from i);

do $users$
declare v_c record; v_id uuid;
begin
  select * into v_c from _c limit 1;
  foreach v_id in array array[gen_random_uuid(),gen_random_uuid(),gen_random_uuid()] loop
    insert into auth.users(id,instance_id,aud,role,email,encrypted_password,
      email_confirmed_at,created_at,updated_at)
    values (v_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'zz-v404-'||substr(v_id::text,1,8)||'@example.test','x',now(),now(),now());
  end loop;
end $users$;
update _c set owner_u=(select id from auth.users where email like 'zz-v404-%' order by created_at limit 1);
update _c set mgr_u  =(select id from auth.users where email like 'zz-v404-%' order by created_at offset 1 limit 1);
update _c set staff_u=(select id from auth.users where email like 'zz-v404-%' order by created_at offset 2 limit 1);

with i as (insert into public.staff(business_id,user_id,role,active,access_state,full_name)
  select biz,owner_u,'owner',true,'approved','ZZ V404 Owner' from _c returning id)
update _c set owner_s=(select id from i);
insert into public.staff(business_id,user_id,role,active,access_state,full_name)
  select biz,mgr_u,'manager',true,'approved','ZZ V404 Manager' from _c;
with i as (insert into public.staff(business_id,user_id,role,active,access_state,full_name)
  select biz,staff_u,'staff',true,'approved','ZZ V404 Staff' from _c returning id)
update _c set staff_s=(select id from i);

insert into public.business_workspace_controls_v94(business_id,approval_status,decided_by,decided_at,decision_reason)
select biz,'approved',owner_u,now(),'v404 fixture' from _c
on conflict (business_id) do update set approval_status='approved';
insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
select biz,false from _c on conflict (business_id) do update set workspace_paused=false;
insert into public.staff_branches(business_id,staff_id,branch_id) select biz,staff_s,br from _c
on conflict do nothing;

with i as (insert into public.clients(business_id,full_name,phone)
  select biz,'ZZ V404 Customer','8'||substr((random()*90000000+10000000)::bigint::text,1,7) from _c returning id)
update _c set cli=(select id from i);

create or replace function pg_temp.as_v404(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_user,'role','authenticated')::text, true);
end $$;

-- 01/02/03 — the matrix the owner specified, before any grant exists.
do $matrix$
declare v_c record; v_owner boolean; v_mgr boolean; v_staff boolean;
begin
  select * into v_c from _c limit 1;
  perform pg_temp.as_v404(v_c.owner_u); set local role authenticated;
  v_owner := app.can_manual_redeem_v404(v_c.biz, v_c.br);
  reset role;
  perform pg_temp.as_v404(v_c.mgr_u);   set local role authenticated;
  v_mgr := app.can_manual_redeem_v404(v_c.biz, v_c.br);
  reset role;
  perform pg_temp.as_v404(v_c.staff_u); set local role authenticated;
  v_staff := app.can_manual_redeem_v404(v_c.biz, v_c.br);
  reset role;
  insert into _r values ('01 owner may redeem manually by role',
    case when v_owner then 'PASS' else 'FAIL owner was refused' end);
  insert into _r values ('02 manager may redeem manually by role',
    case when v_mgr then 'PASS' else 'FAIL manager was refused' end);
  insert into _r values ('03 other staff may NOT without a grant',
    case when v_staff then 'FAIL staff was allowed without a grant' else 'PASS' end);
end $matrix$;

-- 04 — a plain staff member cannot grant the capability to themselves.
do $selfgrant$
declare v_c record;
begin
  select * into v_c from _c limit 1;
  perform pg_temp.as_v404(v_c.staff_u); set local role authenticated;
  begin
    perform public.set_staff_capability_v404(v_c.biz, v_c.staff_s, 'manual_reward_redemption', true);
    insert into _r values ('04 staff cannot self-grant','FAIL the self-grant succeeded');
  exception when insufficient_privilege then
    insert into _r values ('04 staff cannot self-grant','PASS');
  end;
  reset role;
end $selfgrant$;

-- 05/06 — a manager grants it, and the same staff member may then redeem.
do $grant$
declare v_c record; v_after boolean;
begin
  select * into v_c from _c limit 1;
  perform pg_temp.as_v404(v_c.mgr_u); set local role authenticated;
  perform public.set_staff_capability_v404(v_c.biz, v_c.staff_s, 'manual_reward_redemption', true);
  reset role;
  perform pg_temp.as_v404(v_c.staff_u); set local role authenticated;
  v_after := app.can_manual_redeem_v404(v_c.biz, v_c.br);
  reset role;
  insert into _r values ('05 a manager may grant the capability','PASS');
  insert into _r values ('06 the granted staff member may now redeem',
    case when v_after then 'PASS' else 'FAIL still refused after the grant' end);
end $grant$;

-- 07 — the grant is auditable.
insert into _r select '07 the grant is written to audit_log',
  case when exists(select 1 from public.audit_log
                    where business_id=(select biz from _c) and action='capability.granted'
                      and detail->>'capability'='manual_reward_redemption')
  then 'PASS' else 'FAIL no audit row' end;

-- 08 — quantity is bounded server-side.
do $qty$
declare v_c record;
begin
  select * into v_c from _c limit 1;
  perform pg_temp.as_v404(v_c.owner_u); set local role authenticated;
  begin
    perform public.staff_manual_redeem_reward_v404(
      v_c.biz, v_c.cli, gen_random_uuid(), 21, v_c.br, 'customer_unable_to_show_qr', null,
      'zzv404-qty-'||substr(md5(random()::text),1,8));
    insert into _r values ('08 quantity above the cap is refused','FAIL 21 was accepted');
  exception
    when sqlstate '22023' then insert into _r values ('08 quantity above the cap is refused','PASS');
    when others then insert into _r values ('08 quantity above the cap is refused','FAIL '||sqlstate||' '||sqlerrm);
  end;
  reset role;
end $qty$;

-- 09 — a reason is required, and 'other' needs a note.
do $reason$
declare v_c record; v_a text; v_b text;
begin
  select * into v_c from _c limit 1;
  perform pg_temp.as_v404(v_c.owner_u); set local role authenticated;
  begin
    perform public.staff_manual_redeem_reward_v404(v_c.biz, v_c.cli, gen_random_uuid(), 1, v_c.br,
      null, null, 'zzv404-nr-'||substr(md5(random()::text),1,8));
    v_a := 'FAIL a missing reason was accepted';
  exception when sqlstate '22023' then v_a := 'PASS'; when others then v_a := 'FAIL '||sqlstate;
  end;
  begin
    perform public.staff_manual_redeem_reward_v404(v_c.biz, v_c.cli, gen_random_uuid(), 1, v_c.br,
      'other', '   ', 'zzv404-nn-'||substr(md5(random()::text),1,8));
    v_b := 'FAIL a blank note on "other" was accepted';
  exception when sqlstate '22023' then v_b := 'PASS'; when others then v_b := 'FAIL '||sqlstate;
  end;
  reset role;
  insert into _r values ('09a a reason is required', v_a);
  insert into _r values ('09b "other" requires a note', v_b);
end $reason$;

-- 10 — the old browser redemption paths stay revoked.
insert into _r select '10 v94 revokes still hold for the browser',
  case when not has_function_privilege('authenticated','public.redeem_reward_at_context(uuid,uuid,uuid,text,uuid,uuid,uuid)','execute')
        and not has_function_privilege('authenticated','public.redeem_reward(uuid,uuid,uuid,text)','execute')
        and not has_function_privilege('authenticated','public.redeem_points(uuid,uuid,text)','execute')
  then 'PASS' else 'FAIL a legacy redemption path is executable by the browser again' end;

-- 11 — the evidence table takes no writes from the browser, only reads.
insert into _r select '11 the audit table has no write policy',
  case when not exists(select 1 from pg_policy
                        where polrelid='public.loyalty_manual_redemptions_v404'::regclass
                          and polcmd in ('a','w','d'))
        and not has_table_privilege('authenticated','public.loyalty_manual_redemptions_v404','insert')
  then 'PASS' else 'FAIL the evidence table is writable' end;

-- ===========================================================================
-- 12..15 — QUANTITY, proved end to end against a REAL reward and a REAL balance.
-- Owner, 2026-08-21: "I want the all-or-nothing transaction behaviour explicitly
-- proven." Check 13 is that proof: an order the balance cannot cover must leave
-- NOTHING behind — not one redeemed unit, not one spent point.
-- ===========================================================================
alter table _c add column reward uuid;
alter table _c add column prog uuid;
update _c set prog=(select id from public.business_programmes
  where business_id=(select biz from _c) and kind='points' order by sort,id limit 1);

do $mkreward$
declare v_c record; v_out jsonb;
begin
  select * into v_c from _c limit 1;
  perform pg_temp.as_v404(v_c.owner_u); set local role authenticated;
  v_out := public.business_create_reward_v326(v_c.biz, v_c.prog, 'ZZ V404 Reward', 10, 0, 'v404 fixture', null);
  reset role;
  update _c set reward=coalesce((v_out->>'reward_id')::uuid,(v_out->>'id')::uuid);
end $mkreward$;

-- 40 points: enough for four 10-point redemptions, so 5 is provably one too many.
do $seedpts$
declare v_c record; v_id uuid;
begin
  select * into v_c from _c limit 1;
  v_id := gen_random_uuid();
  perform set_config('app.points_ledger_insert_id',v_id::text,true);
  perform set_config('app.points_ledger_write_scope','referral_reward_points',true);
  insert into public.points_ledger(id,business_id,client_id,programme_id,entry_type,points)
  values (v_id,v_c.biz,v_c.cli,v_c.prog,'earn',40);
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
  insert into public.points_batches(business_id,client_id,programme_id,earned,remaining,earned_at)
  values (v_c.biz,v_c.cli,v_c.prog,40,40,now());
end $seedpts$;

create or replace function pg_temp.ops_v404() returns integer language sql as $$
  select count(*)::integer from public.loyalty_operations
   where business_id=(select biz from _c) and operation_type='redeem_reward' $$;
create or replace function pg_temp.bal_v404() returns integer language sql as $$
  select coalesce(sum(points),0)::integer from public.points_ledger
   where business_id=(select biz from _c) and client_id=(select cli from _c) $$;

do $quantity$
declare
  v_c record;
  v_ops0 integer; v_ops1 integer; v_ops2 integer; v_ops3 integer; v_ops4 integer;
  v_bal1 integer; v_bal2 integer; v_bal3 integer;
  v_key3 text := 'zzv404-q3-'||substr(md5(random()::text),1,10);
  v_refused boolean := false;
begin
  select * into v_c from _c limit 1;
  v_ops0 := pg_temp.ops_v404();
  perform pg_temp.as_v404(v_c.owner_u); set local role authenticated;

  -- 12: quantity 1 -> exactly one operation.
  perform public.staff_manual_redeem_reward_v404(v_c.biz,v_c.cli,v_c.reward,1,v_c.br,
    'customer_unable_to_show_qr',null,'zzv404-q1-'||substr(md5(random()::text),1,10));
  v_ops1 := pg_temp.ops_v404(); v_bal1 := pg_temp.bal_v404();

  -- 13: quantity 5 needs 50 of the 30 that are left. It must refuse and leave NOTHING.
  begin
    perform public.staff_manual_redeem_reward_v404(v_c.biz,v_c.cli,v_c.reward,5,v_c.br,
      'customer_unable_to_show_qr',null,'zzv404-q5-'||substr(md5(random()::text),1,10));
  exception when others then
    v_refused := true;
  end;
  v_ops2 := pg_temp.ops_v404(); v_bal2 := pg_temp.bal_v404();

  -- 14: quantity 3 -> exactly three more operations.
  perform public.staff_manual_redeem_reward_v404(v_c.biz,v_c.cli,v_c.reward,3,v_c.br,
    'customer_unable_to_show_qr',null,v_key3);
  v_ops3 := pg_temp.ops_v404();

  -- 15: replaying that same key adds nothing.
  perform public.staff_manual_redeem_reward_v404(v_c.biz,v_c.cli,v_c.reward,3,v_c.br,
    'customer_unable_to_show_qr',null,v_key3);
  v_ops4 := pg_temp.ops_v404(); v_bal3 := pg_temp.bal_v404();
  reset role;

  insert into _r values ('12 quantity 1 makes exactly 1 operation',
    case when v_ops1-v_ops0=1 then 'PASS' else 'FAIL made '||(v_ops1-v_ops0)::text end);
  insert into _r values ('13 an unaffordable quantity is refused with NO partial redemption',
    case when v_refused and v_ops2=v_ops1 and v_bal2=v_bal1
         then 'PASS'
         when not v_refused then 'FAIL it was accepted'
         else 'FAIL partial: ops '||v_ops1::text||'->'||v_ops2::text
              ||', balance '||v_bal1::text||'->'||v_bal2::text end);
  insert into _r values ('14 quantity 3 makes exactly 3 operations',
    case when v_ops3-v_ops2=3 then 'PASS' else 'FAIL made '||(v_ops3-v_ops2)::text end);
  insert into _r values ('15 replaying the same key makes 0 more operations',
    case when v_ops4=v_ops3 and v_bal3=pg_temp.bal_v404()
         then 'PASS' else 'FAIL made '||(v_ops4-v_ops3)::text||' more' end);
  insert into _r values ('16 the audit row records the quantity, not the units',
    case when (select quantity from public.loyalty_manual_redemptions_v404
                where business_id=v_c.biz and idempotency_key=v_key3)=3
          and (select array_length(operation_ids,1) from public.loyalty_manual_redemptions_v404
                where business_id=v_c.biz and idempotency_key=v_key3)=3
         then 'PASS' else 'FAIL' end);
end $quantity$;

select k as check, v as result from _r order by k;

rollback;
