-- Rollback-only v646 acceptance suite: engagement_monthly_rollup_v1 is populated by
-- app.run_engagement_rollup_v646() from real telemetry (identity-free by construction —
-- month x business x event/channel counts only) and is append-only at the row level.
-- This suite validates against an instance whose historical telemetry the backfill has
-- already rolled up (a fresh empty sandbox with no prior events will not exercise C1;
-- the source production validation ran against a live instance with real telemetry months).
-- Run after the complete canonical chain through v646 in a disposable database (or as a
-- rolled-back transaction directly against a prod-shaped instance).
begin;

do $fixture$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
begin
  reset role;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_owner,
    'authenticated','authenticated',
    'phasebc-owner-'||substr(v_owner::text,1,8)||'@example.test',
    '',now(),now(),now()
  );
  insert into public.businesses(
    id,name,slug,industry,join_enabled,enabled_modules
  ) values (
    v_business,'Phase BC fixture',
    'phasebc-'||substr(v_business::text,1,8),'facial',true,
    array['dashboard','clients','sales','till','appointments','loyalty','reports','services']
  );
  insert into public.staff(business_id,user_id,role,full_name,active)
  values (v_business,v_owner,'owner','Phase BC Owner',true);
  insert into public.branches(business_id,name,is_default,active)
  values (v_business,'Primary',true,true);
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_at=clock_timestamp(),
         decision_reason='phase-bc rollback validation fixture',updated_at=clock_timestamp()
   where business_id=v_business;
  insert into public.subscriptions(business_id,status,trial_ends_at)
  values (v_business,'trialing', now() + interval '7 days');

  perform set_config('phasebc.owner', v_owner::text, true);
  perform set_config('phasebc.business', v_business::text, true);
end
$fixture$;

create or replace function pg_temp.as_postgres() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
end;
$$;
grant execute on function pg_temp.as_postgres() to public;

-- ---------------------------------------------------------------------------
-- C. v646 backfill produced closed-month rollups from real production telemetry,
--    and the rollup table's append-only guard fails a mutation attempt.
-- ---------------------------------------------------------------------------
do $c$
declare v_n integer;
begin
  perform pg_temp.as_postgres();
  select count(*) into v_n from public.engagement_monthly_rollup_v1;
  if v_n = 0 then
    raise exception 'C1: rollup backfill produced no rows despite existing telemetry months';
  end if;
  begin
    update public.engagement_monthly_rollup_v1 set event_count = 0 where true;
    raise exception 'C2: rollup append-only guard failed';
  exception when sqlstate '42501' then null;
  end;
  raise notice 'C OK: engagement rollups (% rows)', v_n;
end
$c$;

reset role;
rollback;
