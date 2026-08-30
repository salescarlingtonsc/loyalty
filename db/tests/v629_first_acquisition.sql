-- Rollback-only v629 acceptance suite: first-acquisition provenance
-- columns, the creation-time trigger default, the write-once guard, and
-- the provable-only backfill.
-- Run after the complete canonical chain through v629 in a disposable database.
begin;

do $fixture$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_service uuid := gen_random_uuid();
begin
  reset role;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_owner,
    'authenticated','authenticated',
    'phasea-owner-'||substr(v_owner::text,1,8)||'@example.test',
    '',now(),now(),now()
  );
  insert into public.businesses(
    id,name,slug,industry,join_enabled,enabled_modules
  ) values (
    v_business,'Phase A fixture',
    'phasea-'||substr(v_business::text,1,8),'test',true,
    array['dashboard','clients','sales','till','appointments','bookings','loyalty','reports','services']
  );
  insert into public.staff(business_id,user_id,role,full_name,active)
  values (v_business,v_owner,'owner','Phase A Owner',true);
  insert into public.branches(business_id,name,is_default,active)
  values (v_business,'Primary',true,true);
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_at=clock_timestamp(),
         decision_reason='phase-a rollback validation fixture',updated_at=clock_timestamp()
   where business_id=v_business;
  insert into public.services(id,business_id,name,price_cents,duration_min,active)
  values (v_service,v_business,'Fixture Facial',8000,60,true);
  -- v620 entitlement gate: a workspace is operational only with an approved control
  -- row AND a live subscription (trialing or paid).
  insert into public.subscriptions(business_id,status,trial_ends_at)
  values (v_business,'trialing', now() + interval '7 days');

  perform set_config('phasea.owner', v_owner::text, true);
  perform set_config('phasea.business', v_business::text, true);
  perform set_config('phasea.service', v_service::text, true);
end
$fixture$;

create or replace function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','authenticated')::text,true);
end;
$$;
create or replace function pg_temp.as_postgres() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
end;
$$;
grant execute on function pg_temp.as_user(uuid) to public;
grant execute on function pg_temp.as_postgres() to public;

-- ---------------------------------------------------------------------------
-- B. v629 acquisition: trigger default, writer context, guard, backfill state
-- ---------------------------------------------------------------------------
do $b$
declare
  v_business uuid := current_setting('phasea.business')::uuid;
  v_id uuid;
  v_row public.clients%rowtype;
  v_nulls integer;
begin
  perform pg_temp.as_postgres();
  -- default path: no context -> unknown
  insert into public.clients (business_id, full_name, phone)
  values (v_business,'Unknown Path','81110001') returning id into v_id;
  select * into v_row from public.clients where id=v_id;
  if v_row.first_acquired_via <> 'unknown' or v_row.first_acquired_evidence <> 'unknown' then
    raise exception 'B1: default insert should record unknown/unknown, got %/%',
      v_row.first_acquired_via, v_row.first_acquired_evidence;
  end if;
  -- context path
  perform set_config('app.first_acquired_via','walk_in_till',true);
  insert into public.clients (business_id, full_name, phone)
  values (v_business,'Till Path','81110002') returning id into v_id;
  perform set_config('app.first_acquired_via','',true);
  select * into v_row from public.clients where id=v_id;
  if v_row.first_acquired_via <> 'walk_in_till' or v_row.first_acquired_evidence <> 'recorded_at_creation' then
    raise exception 'B2: context insert misrecorded: %/%', v_row.first_acquired_via, v_row.first_acquired_evidence;
  end if;
  -- write-once guard
  begin
    update public.clients set first_acquired_via='qr_join' where id=v_id;
    raise exception 'B3: guard failed to block provenance rewrite';
  exception when sqlstate '42501' then null;
  end;
  -- upgrade path unknown -> provable is allowed
  update public.clients set first_acquired_via='referral', first_acquired_evidence='backfilled_provable'
   where business_id=v_business and full_name='Unknown Path';
  -- whole-table invariant
  select count(*) into v_nulls from public.clients where first_acquired_via is null;
  if v_nulls > 0 then raise exception 'B4: % clients with null acquisition', v_nulls; end if;
  raise notice 'B OK: v629 acquisition trigger+guard';
end
$b$;

do $b2$
declare r record;
begin
  raise notice 'B backfill distribution:';
  for r in select first_acquired_via, first_acquired_evidence, count(*) n
             from public.clients group by 1,2 order by 3 desc loop
    raise notice '  % / % : %', r.first_acquired_via, r.first_acquired_evidence, r.n;
  end loop;
end
$b2$;

reset role;
rollback;
