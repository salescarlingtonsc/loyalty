-- Rollback-only acceptance for v409 — one canonical programme-aware points balance,
-- proved across a full Points -> Stamps -> Points round trip.
--   supabase db query --linked -f db/tests/v409_points_stamps_points_balance.sql
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- Owner, 2026-08-21: merchant till showed "855 pts", customer app showed "97 points".
-- 97 (live points pot) + 758 (dormant stamps pot) = 855. The till was adding pots.
--
-- What this suite pins is the INVARIANT, not the arithmetic of one screen:
--   at every point in a points<->stamps round trip, every live current-balance reader
--   must return the SAME number, and that number must be the LIVE pot.
-- A reader that drifts back to summing every pot fails here rather than in a shop.

begin;

create temp table _r(k text, v text) on commit drop;
create temp table _c(biz uuid, br uuid, owner_u uuid, slug text, cli uuid,
                     prog_points uuid, prog_stamps uuid, ver uuid) on commit drop;
grant select,insert,update,delete on _r,_c to authenticated;
insert into _c(slug) values ('zz-v409-'||substr(md5(random()::text),1,8));

with i as (insert into public.businesses(name,slug,enabled_modules)
  select 'ZZ V409',slug,array['loyalty','clients','sales'] from _c returning id)
update _c set biz=(select id from i);
with i as (insert into public.branches(business_id,name) select biz,'Main' from _c returning id)
update _c set br=(select id from i);
with i as (insert into auth.users(id,instance_id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at)
  values (gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'zz-v409-'||substr(md5(random()::text),1,8)||'@example.test','x',now(),now(),now()) returning id)
update _c set owner_u=(select id from i);
insert into public.staff(business_id,user_id,role,active,access_state,full_name)
  select biz,owner_u,'owner',true,'approved','ZZ V409 Owner' from _c;
insert into public.business_workspace_controls_v94(business_id,approval_status,decided_by,decided_at,decision_reason)
select biz,'approved',owner_u,now(),'v409 fixture' from _c
on conflict (business_id) do update set approval_status='approved',
  decided_by=excluded.decided_by, decided_at=excluded.decided_at,
  decision_reason=excluded.decision_reason;
insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
select biz,false from _c on conflict (business_id) do update set workspace_paused=false;

with i as (insert into public.clients(business_id,full_name,phone)
  select biz,'ZZ V409 Customer','8'||substr((random()*90000000+10000000)::bigint::text,1,7) from _c returning id)
update _c set cli=(select id from i);

update _c set prog_points=(select id from public.business_programmes
  where business_id=(select biz from _c) and kind='points' order by sort,id limit 1);
update _c set prog_stamps=(select id from public.business_programmes
  where business_id=(select biz from _c) and kind='stamps' order by sort,id limit 1);
update public.business_programmes set active=(kind='points')
 where business_id=(select biz from _c) and kind in ('points','stamps');

-- A published loyalty configuration, seeded the way the trigger expects (see v404).
do $cfg$
declare v_c record;
begin
  select * into v_c from _c limit 1;
  insert into public.loyalty_programs(business_id,kind,active,loyalty_model,configuration_status)
  values (v_c.biz,'points',true,'classic','published');
  update _c set ver=(select id from public.firm_config_versions
    where business_id=v_c.biz and status='published' order by version_no desc limit 1);
  update public.businesses set active_config_version_id=(select ver from _c)
   where id=v_c.biz and active_config_version_id is null;
end $cfg$;

-- 500 points in the LIVE points pot, matched by a batch so the v312 safety switch
-- reports 'programme_pot' (an unmatched pot would legitimately force the legacy total).
do $seed$
declare v_c record; v_id uuid;
begin
  select * into v_c from _c limit 1;
  v_id := gen_random_uuid();
  perform set_config('app.points_ledger_insert_id',v_id::text,true);
  perform set_config('app.points_ledger_write_scope','referral_reward_points',true);
  insert into public.points_ledger(id,business_id,client_id,programme_id,entry_type,points)
  values (v_id,v_c.biz,v_c.cli,v_c.prog_points,'earn',500);
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
  insert into public.points_batches(business_id,client_id,programme_id,earned,remaining,earned_at)
  values (v_c.biz,v_c.cli,v_c.prog_points,500,500,now());
end $seed$;

create or replace function pg_temp.readers_v409()
returns table(reader text, value integer) language sql security definer as $$
  select 'helper', app.client_points_balance_v409((select biz from _c),(select cli from _c))
  union all
  select 'till lookup_client_by_phone',
         ((public.lookup_client_by_phone((select biz from _c),
            (select phone from public.clients where id=(select cli from _c))))::jsonb->>'points')::integer
$$;
grant execute on function pg_temp.readers_v409() to authenticated;

-- 01 — POINTS live: every reader agrees on the live pot.
do $step1$
declare v_c record; v_vals integer[]; v_scope text;
begin
  select * into v_c from _c limit 1;
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_c.owner_u,'role','authenticated')::text, true);
  set local role authenticated;
  select array_agg(value) into v_vals from pg_temp.readers_v409();
  reset role;
  v_scope := app.programme_balance_scope_v312(v_c.biz);
  insert into _r values ('01 points live: every reader reads the live pot (500)',
    case when v_scope='programme_pot' and v_vals = array[500,500]
         then 'PASS' else 'FAIL scope='||v_scope||' values='||v_vals::text end);
end $step1$;

-- 02 — convert POINTS -> STAMPS through the real switch, then every reader must
--      follow the stamps pot. 500 points at 100/stamp = 5 stamps.
do $step2$
declare v_c record; v_vals integer[];
begin
  select * into v_c from _c limit 1;
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_c.owner_u,'role','authenticated')::text, true);
  set local role authenticated;
  perform public.business_switch_to_stamps_v384(v_c.biz, true, 100, gen_random_uuid());
  select array_agg(value) into v_vals from pg_temp.readers_v409();
  reset role;
  insert into _r values ('02 after points->stamps: every reader reads the stamps pot (5)',
    case when v_vals = array[5,5] then 'PASS' else 'FAIL values='||v_vals::text end);
end $step2$;

-- 03 — the points pot is NOT lost, it is dormant. The old total must never reappear
--      as the customer's balance just because a second pot exists.
insert into _r select '03 the dormant points pot is still on the ledger, not in the balance',
  case when (select coalesce(sum(l.points),0) from public.points_ledger l
              where l.business_id=(select biz from _c) and l.client_id=(select cli from _c)
                and l.programme_id=(select prog_points from _c)) = 0
        and (select coalesce(sum(l.points),0) from public.points_ledger l
              where l.business_id=(select biz from _c) and l.client_id=(select cli from _c)) = 5
  then 'PASS' else 'FAIL points_pot='||(select coalesce(sum(l.points),0)::text from public.points_ledger l
              where l.business_id=(select biz from _c) and l.client_id=(select cli from _c)
                and l.programme_id=(select prog_points from _c))
       ||' all_pots='||(select coalesce(sum(l.points),0)::text from public.points_ledger l
              where l.business_id=(select biz from _c) and l.client_id=(select cli from _c)) end;

-- 04 — switch STAMPS -> POINTS again. The balance must follow back to the points pot,
--      which is the owner's exact journey and where the 855 came from.
do $step4$
declare v_c record; v_vals integer[];
begin
  select * into v_c from _c limit 1;
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_c.owner_u,'role','authenticated')::text, true);
  set local role authenticated;
  perform public.set_programmes_v314(v_c.biz,
    jsonb_build_object('points',true,'stamps',false,'tiers',false), gen_random_uuid()::text);
  select array_agg(value) into v_vals from pg_temp.readers_v409();
  reset role;
  insert into _r values ('04 after stamps->points: readers follow back to the points pot',
    case when v_vals[1] = v_vals[2] and v_vals[1] = 0
         then 'PASS'
         when v_vals[1] <> v_vals[2] then 'FAIL readers disagree: '||v_vals::text
         else 'FAIL expected the points pot, got '||v_vals::text end);
end $step4$;

-- 05 — THE REGRESSION ITSELF: no reader may ever return the sum of both pots.
insert into _r select '05 no reader returns the sum of every pot',
  case when (select count(*) from pg_temp.readers_v409() r
              where r.value = (select coalesce(sum(l.points),0) from public.points_ledger l
                                where l.business_id=(select biz from _c)
                                  and l.client_id=(select cli from _c))
                and (select count(distinct l.programme_id) from public.points_ledger l
                      where l.business_id=(select biz from _c)
                        and l.client_id=(select cli from _c)) > 1
                and (select coalesce(sum(l.points),0) from public.points_ledger l
                      where l.business_id=(select biz from _c) and l.client_id=(select cli from _c))
                    <> (select app.client_points_balance_v409((select biz from _c),(select cli from _c)))
            ) = 0
  then 'PASS' else 'FAIL a reader is summing every pot again' end;

-- 06 — the safety switch still governs. Break the ledger==batches invariant and the
--      helper must fall back to the legacy total rather than invent a new number.
do $step6$
declare v_c record; v_scope text; v_bal integer; v_all integer;
begin
  select * into v_c from _c limit 1;
  update public.points_batches set remaining = remaining + 7
   where business_id=v_c.biz and client_id=v_c.cli;
  v_scope := app.programme_balance_scope_v312(v_c.biz);
  v_bal := app.client_points_balance_v409(v_c.biz, v_c.cli);
  select coalesce(sum(points),0) into v_all from public.points_ledger
   where business_id=v_c.biz and client_id=v_c.cli;
  insert into _r values ('06 inconsistent pots fall back to the legacy total',
    case when v_scope='business_pot' and v_bal=v_all then 'PASS'
         else 'FAIL scope='||v_scope||' balance='||v_bal::text||' legacy_total='||v_all::text end);
end $step6$;

select k as check, v as result from _r order by k;

rollback;
