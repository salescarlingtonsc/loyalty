-- Executed rollback-only P0 acceptance for v480 conversion conservation,
-- atomic failure, and immutable idempotency receipts. The original v403 guard
-- regression remains in db/tests/v403_stamp_conversion_ledger_token.sql.
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- Owner, 2026-08-21 (photo 3): "set up stamp does not work". The page showed
--   "points_ledger may only be appended by approved loyalty routes  Nothing was changed."
--
-- app.loyalty_ledger_write_guard (v312) admits a points_ledger insert only when BOTH
-- app.points_ledger_write_scope names an approved route AND app.points_ledger_insert_id equals
-- the row's own id. public.business_switch_to_stamps_v384 set the scope, never the token, and
-- generated both ids inline inside the VALUES list — so there was no id to publish and every
-- conversion row raised 42501.
--
-- Why v384 shipped with this: db/tests/v384_stamp_conversion_switch.sql asserts only that the
-- function EXISTS and carries the right grants. It never calls it, so no test in the repository
-- had ever run a conversion. This suite does, with a real balance, which is the only shape that
-- reaches the guard at all — a firm with no points converts nothing and fails nothing.

begin;

create temp table _r(k text, v text) on commit drop;
create temp table _c(biz uuid, owner uuid, slug text, cli uuid,
                     progPoints uuid, progStamps uuid, convKey uuid) on commit drop;
grant select,insert,update,delete on _r,_c to authenticated;
create function pg_temp.v480_suppress_conversion_batch_update()
returns trigger language plpgsql as $$
begin
  if current_setting('app.v480_test_suppress_conversion_batch',true)='on' then return old; end if;
  return new;
end $$;
create trigger zz_v480_suppress_conversion_batch_update
before update on public.points_batches
for each row execute function pg_temp.v480_suppress_conversion_batch_update();
insert into _c(slug) values ('zz-v403-'||substr(md5(random()::text),1,8));

with i as (insert into public.businesses(name,slug,enabled_modules)
  select 'ZZ V403',slug,array['loyalty','clients'] from _c returning id)
update _c set biz=(select id from i);
insert into public.branches(business_id,name) select biz,'Main' from _c;
with i as (insert into auth.users(id,instance_id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at)
  values (gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'zz-v403-'||substr(md5(random()::text),1,8)||'@example.test','x',now(),now(),now()) returning id)
update _c set owner=(select id from i);
insert into public.staff(business_id,user_id,role,active,access_state,full_name)
  select biz,owner,'owner',true,'approved','ZZ V403 Owner' from _c;
insert into public.business_workspace_controls_v94(business_id,approval_status,decided_by,decided_at,decision_reason)
select biz,'approved',owner,now(),'v403 fixture' from _c
on conflict (business_id) do update set approval_status='approved',
  decided_by=excluded.decided_by, decided_at=excluded.decided_at, decision_reason=excluded.decision_reason;
insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
select biz,false from _c on conflict (business_id) do update set workspace_paused=false;

with i as (insert into public.clients(business_id,full_name,phone)
  select biz,'ZZ V403 Customer','8'||substr((random()*90000000+10000000)::bigint::text,1,7) from _c returning id)
update _c set cli=(select id from i);

update _c set progPoints=(select id from public.business_programmes
  where business_id=(select biz from _c) and kind='points' order by sort,id limit 1);
update _c set progStamps=(select id from public.business_programmes
  where business_id=(select biz from _c) and kind='stamps' order by sort,id limit 1);

select set_config('request.jwt.claims',
  json_build_object('sub',(select owner from _c),'role','authenticated')::text, true);

-- A REAL balance: 500 spendable points, matched by a batch the conversion can draw down.
-- Written one row at a time with its own token, exactly as a real earn does.
do $seed$
declare v_c record; v_id uuid;
begin
  select * into v_c from _c limit 1;
  perform app.acquire_loyalty_exclusive_v480(v_c.biz);
  v_id := gen_random_uuid();
  perform set_config('app.points_ledger_insert_id',v_id::text,true);
  perform set_config('app.points_ledger_write_scope','adjust_points',true);
  insert into public.points_ledger(id,business_id,client_id,programme_id,entry_type,points,actor)
  values (v_id,v_c.biz,v_c.cli,v_c.progPoints,'adjust',500,v_c.owner);
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
end $seed$;
insert into public.points_batches(business_id,client_id,programme_id,earned,remaining,earned_at)
select biz,cli,progPoints,500,500,now() from _c;

-- v480 — a conversion must refuse a pre-existing ledger/batch mismatch, not
-- silently convert min(ledger,batches). Add one proven ledger point without its
-- cache row, assert refusal, then repair the fixture and execute the happy path.
do $mismatch$
declare v_c record; v_id uuid; v_refused boolean:=false;
begin
  select * into v_c from _c limit 1;
  v_id:=gen_random_uuid();
  perform set_config('app.points_ledger_insert_id',v_id::text,true);
  perform set_config('app.points_ledger_write_scope','adjust_points',true);
  insert into public.points_ledger(id,business_id,client_id,programme_id,entry_type,points,actor)
  values(v_id,v_c.biz,v_c.cli,v_c.progPoints,'adjust',1,v_c.owner);
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
  update app.loyalty_integrity_control_v480 set conversions_enabled=true where singleton;
  perform set_config('request.jwt.claims',json_build_object('sub',v_c.owner,'role','authenticated')::text,true);
  begin
    perform public.business_switch_to_stamps_v384(v_c.biz,true,100,gen_random_uuid());
  exception when sqlstate 'XX001' then
    if position('pre-state is not conserved' in sqlerrm)=0 then raise; end if;
    v_refused:=true;
  end;
  if not v_refused then raise exception 'v480 conversion accepted divergent source evidence'; end if;
  insert into public.points_batches(business_id,client_id,programme_id,earned,remaining,earned_at)
  values(v_c.biz,v_c.cli,v_c.progPoints,1,1,now());
end $mismatch$;

-- A disappearing batch update midway through conversion must roll the whole
-- statement back: no pot switch, ledger child, batch child, or receipt survives.
do $midway$
declare v_c record; v_key uuid:=gen_random_uuid(); v_refused boolean:=false;
begin
  select * into v_c from _c limit 1;
  perform set_config('app.v480_test_suppress_conversion_batch','on',true);
  begin
    perform public.business_switch_to_stamps_v384(v_c.biz,true,100,v_key);
  exception when sqlstate 'XX001' then
    if position('post-state is not conserved' in sqlerrm)=0 then raise; end if;
    v_refused:=true;
  end;
  perform set_config('app.v480_test_suppress_conversion_batch','',true);
  if not v_refused then raise exception 'v480 conversion committed after a disappearing batch update'; end if;
  if exists(select 1 from public.programme_stamp_conversions_v384
             where business_id=v_c.biz and idempotency_key=v_key)
     or exists(select 1 from public.points_ledger where business_id=v_c.biz
               and reference like 'stamp conversion:%') then
    raise exception 'failed conversion left a receipt or ledger child';
  end if;
  insert into _r values('02 midway failure is atomic','PASS');
end $midway$;

-- 01 — the guard is NOT loosened. The v384 shape (scope only, no token) must still be refused,
-- or this fix would have been a hole rather than a repair.
do $red$
declare v_c record;
begin
  select * into v_c from _c limit 1;
  begin
    perform set_config('app.points_ledger_write_scope','programme_pot_transfer',true);
    insert into public.points_ledger(id,business_id,client_id,programme_id,entry_type,points)
    values (gen_random_uuid(),v_c.biz,v_c.cli,v_c.progPoints,'adjust',-1);
    perform set_config('app.points_ledger_write_scope','',true);
    insert into _r values ('01 guard still refuses an untokened insert','FAIL the guard accepted it');
  exception when insufficient_privilege then
    perform set_config('app.points_ledger_write_scope','',true);
    insert into _r values ('01 guard still refuses an untokened insert','PASS');
  end;
end $red$;

-- 02 — the switch itself, run as the owner over the wire, converts without raising.
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner from _c),'role','authenticated')::text, true);
set local role authenticated;
do $green$
declare v_c record; v_out jsonb; v_key uuid:=gen_random_uuid();
begin
  select * into v_c from _c limit 1;
  begin
    update _c set convKey=v_key;
    v_out := public.business_switch_to_stamps_v384(v_c.biz, true, 100, v_key);
    insert into _r values ('03 switch to stamps converts existing points','PASS');
  exception when others then
    insert into _r values ('03 switch to stamps converts existing points','FAIL '||sqlstate||' '||sqlerrm);
  end;
end $green$;

do $replay$
declare v_c record; v_out jsonb; v_conflict boolean:=false;
begin
  select * into v_c from _c limit 1;
  v_out:=public.business_switch_to_stamps_v384(v_c.biz,true,100,v_c.convKey);
  if (v_out->>'points_converted')::integer<>500 then
    raise exception 'exact conversion replay returned another result: %',v_out;
  end if;
  insert into _r values('04 same conversion key exact replay','PASS');
  begin
    perform public.business_switch_to_stamps_v384(v_c.biz,true,101,v_c.convKey);
  exception when unique_violation then v_conflict:=true; end;
  if not v_conflict then raise exception 'conversion idempotency key accepted changed rate'; end if;
  insert into _r values('05 same conversion key changed payload','PASS');
end $replay$;
reset role;

-- 03 — both conversion rows landed, on the right pots and in the right directions.
insert into _r select '06 points pot spent 500',
  case when coalesce((select sum(points) from public.points_ledger
     where business_id=(select biz from _c) and programme_id=(select progPoints from _c)
       and reference='stamp conversion: points spent'),0) = -500
  then 'PASS' else 'FAIL got '||coalesce((select sum(points)::text from public.points_ledger
     where business_id=(select biz from _c) and programme_id=(select progPoints from _c)
       and reference='stamp conversion: points spent'),'no row') end;

insert into _r select '07 stamps pot issued 5',
  case when coalesce((select sum(points) from public.points_ledger
     where business_id=(select biz from _c) and programme_id=(select progStamps from _c)
       and reference='stamp conversion: stamps issued'),0) = 5
  then 'PASS' else 'FAIL got '||coalesce((select sum(points)::text from public.points_ledger
     where business_id=(select biz from _c) and programme_id=(select progStamps from _c)
       and reference='stamp conversion: stamps issued'),'no row') end;

-- 05 — the drawn-down batch is gone and a stamp batch replaced it, so the balance is provable
-- from batches as well as from the ledger.
insert into _r select '08 points batch drawn to zero, stamp batch created',
  case when (select coalesce(sum(remaining),0) from public.points_batches
              where business_id=(select biz from _c) and programme_id=(select progPoints from _c))=1
        and (select coalesce(sum(remaining),0) from public.points_batches
              where business_id=(select biz from _c) and programme_id=(select progStamps from _c))=5
  then 'PASS' else 'FAIL points_remaining='||(select coalesce(sum(remaining),0)::text from public.points_batches
              where business_id=(select biz from _c) and programme_id=(select progPoints from _c))
       ||' stamp_remaining='||(select coalesce(sum(remaining),0)::text from public.points_batches
              where business_id=(select biz from _c) and programme_id=(select progStamps from _c)) end;

select k as check, v as result from _r order by k;

rollback;
