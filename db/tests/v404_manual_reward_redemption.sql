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

/* Each of the three carries its ROLE in the address. Selecting them back by created_at was
   ambiguous — all three are inserted in one statement and tie on the timestamp. */
do $users$
declare v_c record; v_who text; v_id uuid; v_tag text;
begin
  select * into v_c from _c limit 1;
  v_tag := substr(md5(random()::text),1,8);
  foreach v_who in array array['owner','mgr','staff'] loop
    v_id := gen_random_uuid();
    insert into auth.users(id,instance_id,aud,role,email,encrypted_password,
      email_confirmed_at,created_at,updated_at)
    values (v_id,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
      'zz-v404-'||v_who||'-'||v_tag||'@example.test','x',now(),now(),now());
    if v_who='owner' then update _c set owner_u=v_id;
    elsif v_who='mgr' then update _c set mgr_u=v_id;
    else update _c set staff_u=v_id; end if;
  end loop;
end $users$;

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
on conflict (business_id) do update set approval_status='approved',
  decided_by=excluded.decided_by, decided_at=excluded.decided_at,
  decision_reason=excluded.decision_reason;
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
/* app.can_manual_redeem_v404 is INTERNAL: the browser must not be able to call it, and check 03b
   below proves that. It is evaluated here from the privileged session with the caller's JWT claim
   set, because auth.uid() reads the claim rather than the database role — so this still asks the
   question "what would this person get?" without granting the browser a probe. The observable
   behaviour through the public RPC is covered by checks 04 onwards, which DO run as authenticated. */
do $matrix$
declare v_c record; v_owner boolean; v_mgr boolean; v_staff boolean;
begin
  select * into v_c from _c limit 1;
  perform pg_temp.as_v404(v_c.owner_u);
  v_owner := app.can_manual_redeem_v404(v_c.biz, v_c.br);
  perform pg_temp.as_v404(v_c.mgr_u);
  v_mgr := app.can_manual_redeem_v404(v_c.biz, v_c.br);
  perform pg_temp.as_v404(v_c.staff_u);
  v_staff := app.can_manual_redeem_v404(v_c.biz, v_c.br);
  insert into _r values ('01 owner may redeem manually by role',
    case when v_owner then 'PASS' else 'FAIL owner was refused' end);
  insert into _r values ('02 manager may redeem manually by role',
    case when v_mgr then 'PASS' else 'FAIL manager was refused' end);
  insert into _r values ('03 other staff may NOT without a grant',
    case when v_staff then 'FAIL staff was allowed without a grant' else 'PASS' end);
end $matrix$;

-- 03b — and the browser cannot call that internal permission probe at all.
do $internal$
declare v_c record;
begin
  select * into v_c from _c limit 1;
  perform pg_temp.as_v404(v_c.staff_u); set local role authenticated;
  begin
    perform app.can_manual_redeem_v404(v_c.biz, v_c.br);
    insert into _r values ('03b the internal permission probe is not browser-callable','FAIL it was callable');
  exception when insufficient_privilege then
    insert into _r values ('03b the internal permission probe is not browser-callable','PASS');
  end;
  reset role;
end $internal$;

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
  perform pg_temp.as_v404(v_c.staff_u);
  v_after := app.can_manual_redeem_v404(v_c.biz, v_c.br);
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
/* The core refuses a reward whose programme is switched off ('catalog redemption is inactive'),
   which is v371's rule and not something this suite should work around — the points programme is
   simply turned ON, the way a firm running a gift catalogue has it. */
update public.business_programmes set active=true where id=(select prog from _c);

/* business_create_reward_v326 refuses until the firm has a PUBLISHED loyalty configuration, so
   the fixture walks the same draft -> publish path the workspace does before it can offer a gift. */
do $mkreward$
declare v_c record; v_ver uuid; v_out jsonb;
begin
  select * into v_c from _c limit 1;
  perform pg_temp.as_v404(v_c.owner_u); set local role authenticated;
  reset role;
  /* The workspace reaches a published config through the draft/publish RPCs, which need a base
     configuration this bare fixture business has never had. What business_create_reward_v326 and
     redeem_reward_core actually require is one PUBLISHED firm_config_versions row that
     businesses.active_config_version_id points at, so the fixture seeds exactly that and nothing
     more — it is not exercising the publish flow, which has its own coverage. */
  /* One insert does both jobs: redeem_reward_core refuses with 'catalog redemption is inactive'
     until the firm has a loyalty_programs row, and inserting that row fires
     seed_loyalty_config_version(), which writes the published firm_config_versions row that
     business_create_reward_v326 requires. Seeding the version by hand collided with that trigger. */
  insert into public.loyalty_programs(business_id,kind,active,loyalty_model,configuration_status)
  values (v_c.biz,'points',true,'classic','published');
  select id into v_ver from public.firm_config_versions
   where business_id=v_c.biz and status='published' order by version_no desc limit 1;
  if v_ver is null then
    raise exception 'v404 fixture: no published config version was seeded';
  end if;
  update public.businesses set active_config_version_id=v_ver
   where id=v_c.biz and active_config_version_id is null;
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

/* Definer + granted, so the measurements can be taken from inside the authenticated stretches
   without RLS narrowing the very rows being counted. Same shape v381 uses for its pot reader. */
create or replace function pg_temp.ops_v404() returns integer language sql security definer as $$
  select count(*)::integer from public.loyalty_operations
   where business_id=(select biz from _c) and operation_type='redeem_reward' $$;
create or replace function pg_temp.bal_v404() returns integer language sql security definer as $$
  select coalesce(sum(points),0)::integer from public.points_ledger
   where business_id=(select biz from _c) and client_id=(select cli from _c) $$;
grant execute on function pg_temp.ops_v404() to authenticated;
grant execute on function pg_temp.bal_v404() to authenticated;

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
