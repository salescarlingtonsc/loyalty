-- Rollback-only V120 staff blocked-time acceptance.
-- Run after the canonical chain through V120.
begin;

create temporary table pg_temp.v120_fixture (
  business_id uuid primary key,
  owner_user_id uuid not null,
  readonly_user_id uuid not null,
  branch_a uuid not null,
  branch_b uuid not null,
  staff_id uuid not null,
  service_id uuid not null,
  client_id uuid not null,
  day_start timestamptz not null,
  weekday smallint not null
) on commit drop;

do $fixture$
declare
  v_owner uuid:=gen_random_uuid();
  v_readonly uuid:=gen_random_uuid();
  v_staff_user uuid:=gen_random_uuid();
  v_business uuid;
  v_branch_a uuid;
  v_branch_b uuid;
  v_staff uuid;
  v_service uuid;
  v_client uuid;
  v_local timestamp:='2026-07-31 00:00:00';
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
      'v120-owner-'||v_owner::text||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_readonly,'authenticated','authenticated',
      'v120-readonly-'||v_readonly::text||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_staff_user,'authenticated','authenticated',
      'v120-staff-'||v_staff_user::text||'@example.test','',now(),now(),now());

  insert into public.businesses(name,slug,industry,enabled_modules,created_at)
  values (
    'Glow Atelier V120','glow-v120-'||replace(v_owner::text,'-',''),'spa',
    array['dashboard','clients','services','branches','appointments'],'2000-01-01'
  ) returning id into v_business;
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,
         decided_at=statement_timestamp(),
         decision_reason='approved synthetic V120 rollback fixture',
         updated_at=statement_timestamp()
   where business_id=v_business and approval_status='pending';
  if not found then
    raise exception 'V120 fixture workspace control was not pending';
  end if;
  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values
    (v_business,v_owner,'owner','Olivia Tan',true,null,null),
    (v_business,v_readonly,'staff','Read-only viewer',true,array['appointments'],'{"appointments":"r"}'),
    (v_business,v_staff_user,'staff','Chen Wei',true,array['appointments'],'{"appointments":"rw"}');
  select id into v_staff from public.staff
   where business_id=v_business and user_id=v_staff_user;

  insert into public.branches(business_id,name,timezone,active,is_default)
  values (v_business,'Orchard','Asia/Singapore',true,true)
  returning id into v_branch_a;
  insert into public.branches(business_id,name,timezone,active,is_default)
  values (v_business,'Tampines','Asia/Singapore',true,false)
  returning id into v_branch_b;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  select v_business,staff.id,branch.id
    from public.staff staff cross join public.branches branch
   where staff.business_id=v_business and branch.business_id=v_business;
  insert into public.branch_hours(business_id,branch_id,weekday,opens_at,closes_at)
  values (v_business,v_branch_a,5,'09:00','18:00'),
         (v_business,v_branch_b,5,'09:00','18:00');
  insert into public.staff_hours(business_id,staff_id,weekday,starts_at,ends_at)
  values (v_business,v_staff,5,'09:00','18:00');
  insert into public.services(
    business_id,name,variant_label,price_cents,duration_min,active,
    buffer_before_min,buffer_after_min
  ) values (
    v_business,'Spa Ritual','60 min',6000,60,true,15,15
  ) returning id into v_service;
  insert into public.staff_services(business_id,staff_id,service_id)
  values(v_business,v_staff,v_service);
  insert into public.clients(business_id,full_name,phone)
  values(v_business,'Mei Lin','+6581864567') returning id into v_client;

  insert into pg_temp.v120_fixture values(
    v_business,v_owner,v_readonly,v_branch_a,v_branch_b,v_staff,v_service,v_client,
    v_local at time zone 'Asia/Singapore',5
  );
end
$fixture$;

create or replace function pg_temp.as_v120_user(p_user uuid)
returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claim.sub',p_user::text,true);
  perform set_config('request.jwt.claims',json_build_object(
    'sub',p_user,'role','authenticated'
  )::text,true);
  execute 'set local role authenticated';
end
$$;
grant execute on function pg_temp.as_v120_user(uuid) to public;

create or replace function pg_temp.expect_v120_error(
  p_sql text,p_state text,p_label text
) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception '% unexpectedly succeeded',p_label;
exception when others then
  if sqlstate<>p_state then
    raise exception '% returned %, expected %: %',p_label,sqlstate,p_state,sqlerrm;
  end if;
end
$$;
grant execute on function pg_temp.expect_v120_error(text,text,text) to public;

do $acceptance$
declare
  f pg_temp.v120_fixture%rowtype;
  v_create jsonb;
  v_replay jsonb;
  v_delete jsonb;
  v_block uuid;
  v_rows integer;
begin
  select * into f from pg_temp.v120_fixture;
  perform pg_temp.as_v120_user(f.owner_user_id);

  if to_regprocedure(
    'public.create_staff_blocked_time_v120(uuid,uuid,uuid,timestamptz,timestamptz,text,text)'
  ) is null or to_regprocedure(
    'public.delete_staff_blocked_time_v120(uuid,uuid,text)'
  ) is null then raise exception 'V120 RPC surface is incomplete'; end if;
  if has_table_privilege('authenticated','public.staff_blocked_times','select')
     or has_table_privilege('authenticated','app.staff_blocked_time_operations_v120','select')
  then raise exception 'V120 internal tables are API-readable'; end if;

  v_create:=public.create_staff_blocked_time_v120(
    f.business_id,f.branch_a,f.staff_id,
    f.day_start+interval '14 hours',f.day_start+interval '15 hours',
    'Supplier training','create-1'
  );
  v_block:=(v_create->>'block_id')::uuid;
  if v_create->>'status'<>'created' or (v_create->>'replayed')::boolean then
    raise exception 'first create did not return a new receipt: %',v_create;
  end if;
  v_replay:=public.create_staff_blocked_time_v120(
    f.business_id,f.branch_a,f.staff_id,
    f.day_start+interval '14 hours',f.day_start+interval '15 hours',
    'Supplier training','create-1'
  );
  if not (v_replay->>'replayed')::boolean
     or (v_replay->>'block_id')::uuid<>v_block then
    raise exception 'lost-response replay changed the block: %',v_replay;
  end if;
  execute 'reset role';
  select count(*) into v_rows from public.staff_blocked_times
   where business_id=f.business_id;
  if v_rows<>1 then raise exception 'create replay produced % rows',v_rows; end if;
  perform pg_temp.as_v120_user(f.owner_user_id);

  perform pg_temp.expect_v120_error(format(
    $q$select public.create_staff_blocked_time_v120(
      %L,%L,%L,%L,%L,'Different reason','create-1')$q$,
    f.business_id,f.branch_a,f.staff_id,
    f.day_start+interval '14 hours',f.day_start+interval '15 hours'
  ),'22023','same key with edited request');
  perform pg_temp.expect_v120_error(format(
    $q$select public.create_staff_blocked_time_v120(
      %L,%L,%L,%L,%L,'Overlap','create-2')$q$,
    f.business_id,f.branch_b,f.staff_id,
    f.day_start+interval '14 hours 30 minutes',f.day_start+interval '15 hours 30 minutes'
  ),'23P01','cross-branch overlapping block');
  perform pg_temp.expect_v120_error(format(
    $q$select public.create_staff_blocked_time_v120(
      %L,%L,%L,%L,%L,%L,'create-long')$q$,
    f.business_id,f.branch_a,f.staff_id,
    f.day_start+interval '16 hours',f.day_start+interval '17 hours',repeat('x',161)
  ),'22023','overlong reason');

  execute 'reset role';
  if app.staff_free_for_appointment_v47(
    f.business_id,f.staff_id,f.branch_b,f.service_id,
    f.day_start+interval '15 hours 10 minutes',
    f.day_start+interval '16 hours 10 minutes',null
  ) then raise exception 'service buffer ignored a cross-branch block'; end if;
  if not app.staff_free_for_appointment_v47(
    f.business_id,f.staff_id,f.branch_b,f.service_id,
    f.day_start+interval '15 hours 15 minutes',
    f.day_start+interval '16 hours 15 minutes',null
  ) then raise exception 'boundary-touching service should be available'; end if;
  if app.staff_free_for_appointment_v47(
    f.business_id,f.staff_id,f.branch_b,f.service_id,
    f.day_start+interval '1 day 10 hours',
    f.day_start+interval '1 day 11 hours',null
  ) then raise exception 'missing weekday hours did not fail closed'; end if;

  perform pg_temp.as_v120_user(f.owner_user_id);
  select count(*) into v_rows
    from public.list_staff_blocked_times_v120(
      f.business_id,f.branch_b,f.day_start,f.day_start+interval '1 day'
    ) block
   where block.id is null and block.reason is null
     and block.staff_id=f.staff_id;
  if v_rows<>1 then
    raise exception 'cross-branch conflict was not returned redacted';
  end if;

  perform pg_temp.as_v120_user(f.readonly_user_id);
  perform pg_temp.expect_v120_error(format(
    $q$select public.create_staff_blocked_time_v120(
      %L,%L,%L,%L,%L,'Denied','readonly-create')$q$,
    f.business_id,f.branch_a,f.staff_id,
    f.day_start+interval '16 hours',f.day_start+interval '17 hours'
  ),'42501','read-only create');

  perform pg_temp.as_v120_user(f.owner_user_id);
  execute 'reset role';
  perform pg_temp.expect_v120_error(format(
    $q$insert into public.appointments(
      business_id,client_id,branch_id,service_id,staff_id,starts_at,ends_at,status
    ) values (%L,%L,%L,%L,%L,%L,%L,'booked')$q$,
    f.business_id,f.client_id,f.branch_b,f.service_id,f.staff_id,
    f.day_start+interval '15 hours 10 minutes',
    f.day_start+interval '16 hours 10 minutes'
  ),'23P01','direct cross-branch appointment overlap');

  perform pg_temp.as_v120_user(f.owner_user_id);
  v_delete:=public.delete_staff_blocked_time_v120(
    f.business_id,v_block,'delete-1'
  );
  v_replay:=public.delete_staff_blocked_time_v120(
    f.business_id,v_block,'delete-1'
  );
  if v_delete->>'status'<>'deleted' or (v_delete->>'replayed')::boolean
     or not (v_replay->>'replayed')::boolean then
    raise exception 'delete replay receipt is invalid: % / %',v_delete,v_replay;
  end if;
  execute 'reset role';
  if exists (
    select 1 from public.staff_blocked_times where id=v_block
  ) then raise exception 'deleted block remains'; end if;
  if 1<>(select count(*) from public.audit_log
    where business_id=f.business_id and action='STAFF_TIME_UNBLOCK'
      and entity_id=v_block and detail->>'reason'='Supplier training')
  then raise exception 'delete audit snapshot is missing or duplicated'; end if;
end
$acceptance$;

reset role;
select 'V120 staff blocked-time acceptance: PASS' as result;
rollback;
