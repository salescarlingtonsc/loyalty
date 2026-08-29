-- Rollback-only acceptance for nestly_v601 — edit, switch off, take off sale.
-- Run: supabase db query --linked -f db/tests/v601_package_edit_retire_and_switch.sql
-- Any value starting FAIL is a failure. Nothing is committed.
--
-- Driven by the tenant in the owner's photo: Cubbly SPA, whose 5x facial is sold to real
-- customers with sessions still on it. The point of the wave is that taking such a package off
-- sale must never take those sessions away, so that is what the checks measure.
begin;

create temp table _r(id text, value text) on commit drop;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

create temp table _f as
select b.id as biz,
  (select s.user_id from public.staff s
    where s.business_id=b.id and s.role='owner' and s.user_id is not null limit 1) as owner_uid,
  (select p.id from public.package_plans p
    where p.business_id=b.id and exists(select 1 from public.client_packages cp where cp.plan_id=p.id)
    limit 1) as sold_plan
from public.businesses b where b.id='8492e8d6-8888-4383-ada0-7e1ed69f0caa';
grant select, insert on all tables in schema pg_temp to authenticated, anon;

-- a package nobody has bought, created for this transaction only
create temp table _fresh as
with made as (
  insert into public.package_plans(business_id,name,price_cents,sessions,active,version_no)
  select biz,'V601 Probe Package',12345,3,true,1 from _f returning id)
select (select id from made) as plan;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

insert into _r select '00 fixture',
  case when (select owner_uid from _f) is null then 'FAIL: no owner'
       when (select sold_plan from _f) is null then 'FAIL: no sold package to protect'
       else 'OK sold package present' end;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner_uid from _f),'role','authenticated')::text,true);

-- ── 01 a package nobody bought is still deleted outright ───────────────────
insert into _r select '01 an unsold package is deleted outright',
  case when (public.business_manage_package_plan_v193(
              (select biz from _f),(select plan from _fresh),'delete',null)->>'action')='delete'
       then 'OK' else 'FAIL' end;

reset role;
insert into _r select '01b and it is really gone',
  case when exists(select 1 from public.package_plans p,_fresh f where p.id=f.plan)
       then 'FAIL: still there' else 'OK' end;

-- ── 02 a SOLD package is taken off sale, never removed ─────────────────────
create temp table _before as
select (select count(*) from public.client_packages cp,_f f where cp.plan_id=f.sold_plan) as holders,
       (select coalesce(sum(remaining),0) from public.client_packages cp,_f f
         where cp.plan_id=f.sold_plan) as sessions_left;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

set local role authenticated;
create temp table _retire as
select public.business_manage_package_plan_v193(
  (select biz from _f),(select sold_plan from _f),'delete',null) as j;
grant select, insert on all tables in schema pg_temp to authenticated, anon;
reset role;

insert into _r select '02 deleting a sold package retires it instead',
  case when (select j->>'action' from _retire)<>'retire'
         then 'FAIL: '||(select j::text from _retire)
       when (select p.retired_at from public.package_plans p,_f f where p.id=f.sold_plan) is null
         then 'FAIL: no retirement recorded'
       when (select p.active from public.package_plans p,_f f where p.id=f.sold_plan)
         then 'FAIL: still active, so it can still be sold'
       else 'OK sold_to='||(select j->>'sold_to' from _retire) end;

insert into _r select '02b every customer keeps the sessions they paid for',
  case when (select count(*) from public.client_packages cp,_f f where cp.plan_id=f.sold_plan)
          <> (select holders from _before)
       then 'FAIL: a customer''s package row disappeared'
       when (select coalesce(sum(remaining),0) from public.client_packages cp,_f f
              where cp.plan_id=f.sold_plan) <> (select sessions_left from _before)
       then 'FAIL: sessions were taken away'
       else 'OK '||(select holders from _before)||' holders, '||(select sessions_left from _before)||' sessions untouched' end;

-- ── 03 the selling door is shut ────────────────────────────────────────────
do $$
declare v_msg text; v_client uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub',(select owner_uid from _f),'role','authenticated')::text,true);
  select cp.client_id into v_client from public.client_packages cp,_f f where cp.plan_id=f.sold_plan limit 1;
  begin
    -- sell_package_v102(business, client, plan, branch, idempotency_key)
    perform public.sell_package_v102((select biz from _f), v_client, (select sold_plan from _f),
      (select br.id from public.branches br,_f f where br.business_id=f.biz and br.active limit 1),
      gen_random_uuid());
    v_msg:='FAIL: a retired package was sold again';
  exception when others then
    v_msg:=case when sqlerrm like '%inactive%' or sqlerrm like '%not_found%' then 'OK refused: '||left(sqlerrm,48)
                else 'FAIL: wrong refusal: '||left(sqlerrm,80) end;
  end;
  insert into _r values('03 a retired package cannot be sold again', v_msg);
end $$;

-- ── 04 retirement is a decision, not a pause ───────────────────────────────
do $$
declare v_msg text;
begin
  begin
    perform public.business_set_package_active_v601((select biz from _f),(select sold_plan from _f),true);
    v_msg:='FAIL: a retired package was switched back on';
  exception when others then
    v_msg:=case when sqlerrm like '%cannot be switched back on%' then 'OK' else 'FAIL: '||left(sqlerrm,80) end;
  end;
  insert into _r values('04 a retired package cannot be switched back on', v_msg);
end $$;

-- ── 05 the on/off switch flips without minting a version ───────────────────
create temp table _switch as
with made as (
  insert into public.package_plans(business_id,name,price_cents,sessions,active,version_no)
  select biz,'V601 Switch Probe',9900,2,true,1 from _f returning id)
select (select id from made) as plan;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

create temp table _versions_before as
select count(*) as n from public.package_plans p,_f f where p.business_id=f.biz;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

set local role authenticated;
select public.business_set_package_active_v601((select biz from _f),(select plan from _switch),false);
reset role;

insert into _r select '05 switching a package off does not create a version',
  case when (select p.active from public.package_plans p,_switch s where p.id=s.plan)
         then 'FAIL: still on'
       when (select count(*) from public.package_plans p,_f f where p.business_id=f.biz)
            <> (select n from _versions_before)
         then 'FAIL: a new plan row appeared'
       else 'OK' end;

set local role authenticated;
select public.business_set_package_active_v601((select biz from _f),(select plan from _switch),true);
reset role;
insert into _r select '05b and a package that was only paused switches back on',
  case when (select p.active from public.package_plans p,_switch s where p.id=s.plan)
       then 'OK' else 'FAIL' end;

-- ── 06 renaming a sold package is still refused ────────────────────────────
do $$
declare v_msg text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub',(select owner_uid from _f),'role','authenticated')::text,true);
  begin
    perform public.business_manage_package_plan_v193((select biz from _f),(select sold_plan from _f),'rename','Renamed');
    v_msg:='FAIL: a sold package was renamed on its customers'' receipts';
  exception when others then
    v_msg:=case when sqlerrm like '%create a new version instead%' then 'OK' else 'FAIL: '||left(sqlerrm,80) end;
  end;
  insert into _r values('06 renaming a sold package is still refused', v_msg);
end $$;

reset role; select set_config('request.jwt.claims',NULL,true);
select id, value from _r order by id;
rollback;
