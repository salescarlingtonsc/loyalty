-- Rollback-only v87 overdue appointment amendment acceptance suite.
-- Run after the complete canonical chain through v87. Synthetic rows never commit.
begin;

create temporary table pg_temp.v87_fixture(
  business_id uuid primary key,
  foreign_business_id uuid not null,
  owner_id uuid not null,
  branch_limited_id uuid not null,
  foreign_owner_id uuid not null,
  branch_a uuid not null,
  branch_b uuid not null,
  staff_a uuid not null,
  client_id uuid not null,
  overdue_appointment uuid not null,
  completed_appointment uuid not null,
  cancelled_appointment uuid not null,
  no_show_appointment uuid not null,
  future_target timestamptz not null
) on commit drop;

do $v87_fixture$
declare
  v_owner uuid:=gen_random_uuid();
  v_branch_limited uuid:=gen_random_uuid();
  v_foreign_owner uuid:=gen_random_uuid();
  v_business uuid;
  v_foreign_business uuid;
  v_branch_a uuid;
  v_branch_b uuid;
  v_foreign_branch uuid;
  v_staff_a uuid;
  v_branch_limited_staff uuid;
  v_foreign_staff uuid;
  v_client uuid;
  v_overdue uuid;
  v_completed uuid;
  v_cancelled uuid;
  v_no_show uuid;
  v_overdue_start timestamptz:=clock_timestamp()-interval '3 hours';
  v_future_target timestamptz:=clock_timestamp()+interval '4 days';
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
      'v87-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_branch_limited,'authenticated','authenticated',
      'v87-limited-'||substr(v_branch_limited::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_foreign_owner,'authenticated','authenticated',
      'v87-foreign-'||substr(v_foreign_owner::text,1,8)||'@example.test','',now(),now(),now());

  insert into public.businesses(name,slug,industry,enabled_modules)
  values (
    'V87 overdue amendment',
    'v87-amend-'||substr(v_owner::text,1,8),
    'test',
    array['appointments','clients','branches']
  ) returning id into v_business;
  insert into public.businesses(name,slug,industry,enabled_modules)
  values (
    'V87 foreign tenant',
    'v87-foreign-'||substr(v_foreign_owner::text,1,8),
    'test',
    array['appointments']
  ) returning id into v_foreign_business;

  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values (v_business,v_owner,'owner','V87 Owner',true,null,null)
  returning id into v_staff_a;
  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values (
    v_business,v_branch_limited,'staff','V87 Branch B Staff',true,
    array['appointments'],'{"appointments":"rw"}'::jsonb
  ) returning id into v_branch_limited_staff;
  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values (v_foreign_business,v_foreign_owner,'owner','V87 Foreign Owner',true,null,null)
  returning id into v_foreign_staff;

  insert into public.branches(business_id,name,timezone,active,is_default)
  values (v_business,'V87 Branch A','Asia/Singapore',true,true)
  returning id into v_branch_a;
  insert into public.branches(business_id,name,timezone,active,is_default)
  values (v_business,'V87 Branch B','Asia/Singapore',true,false)
  returning id into v_branch_b;
  insert into public.branches(business_id,name,timezone,active,is_default)
  values (v_foreign_business,'V87 Foreign Branch','Asia/Singapore',true,true)
  returning id into v_foreign_branch;

  insert into public.staff_branches(business_id,staff_id,branch_id)
  values
    (v_business,v_staff_a,v_branch_a),
    (v_business,v_branch_limited_staff,v_branch_b),
    (v_foreign_business,v_foreign_staff,v_foreign_branch);

  insert into public.clients(business_id,full_name,phone)
  values (v_business,'V87 Synthetic Customer','81234567')
  returning id into v_client;

  insert into public.appointments(
    business_id,client_id,branch_id,staff_id,starts_at,ends_at,status,total_cents,note
  ) values
    (v_business,v_client,v_branch_a,v_staff_a,
      v_overdue_start,v_overdue_start+interval '1 hour','booked',1000,'v87 overdue'),
    (v_business,v_client,v_branch_a,v_staff_a,
      v_overdue_start-interval '1 day',v_overdue_start-interval '23 hours','completed',1000,'v87 completed'),
    (v_business,v_client,v_branch_a,v_staff_a,
      v_overdue_start-interval '2 days',v_overdue_start-interval '47 hours','cancelled',1000,'v87 cancelled'),
    (v_business,v_client,v_branch_a,v_staff_a,
      v_overdue_start-interval '3 days',v_overdue_start-interval '71 hours','no_show',1000,'v87 no show');

  select id into v_overdue from public.appointments
   where business_id=v_business and note='v87 overdue';
  select id into v_completed from public.appointments
   where business_id=v_business and note='v87 completed';
  select id into v_cancelled from public.appointments
   where business_id=v_business and note='v87 cancelled';
  select id into v_no_show from public.appointments
   where business_id=v_business and note='v87 no show';

  insert into pg_temp.v87_fixture values (
    v_business,v_foreign_business,v_owner,v_branch_limited,v_foreign_owner,
    v_branch_a,v_branch_b,v_staff_a,v_client,v_overdue,v_completed,v_cancelled,
    v_no_show,v_future_target
  );
end
$v87_fixture$;

create or replace function pg_temp.as_v87_user(p_uid uuid,p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,
    true
  );
end
$$;
grant execute on function pg_temp.as_v87_user(uuid,text) to public;

create or replace function pg_temp.expect_v87_error(
  p_sql text,
  p_label text,
  p_sqlstate text
)
returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception '% unexpectedly succeeded',p_label;
exception when others then
  if sqlstate<>p_sqlstate then
    raise exception '% failed with %, expected %: %',p_label,sqlstate,p_sqlstate,sqlerrm;
  end if;
end
$$;
grant execute on function pg_temp.expect_v87_error(text,text,text) to public;

create or replace function pg_temp.v87_operation_count(p_business uuid,p_key uuid)
returns bigint
language sql
stable
security definer
set search_path to 'pg_catalog','app','pg_temp'
as $$
  select count(*)
    from app.appointment_reschedule_operations
   where business_id=$1 and idempotency_key=$2
$$;
grant execute on function pg_temp.v87_operation_count(uuid,uuid) to public;

create or replace function pg_temp.v87_audit_count(p_business uuid,p_appointment uuid)
returns bigint
language sql
stable
security definer
set search_path to 'pg_catalog','public','pg_temp'
as $$
  select count(*)
    from public.audit_log
   where business_id=$1
     and action='APPOINTMENT_RESCHEDULE_V48'
     and entity='appointments'
     and entity_id=$2
$$;
grant execute on function pg_temp.v87_audit_count(uuid,uuid) to public;

do $v87_target_and_access_rejections$
declare
  f pg_temp.v87_fixture%rowtype;
  v_terminal uuid;
  v_label text;
begin
  select * into f from pg_temp.v87_fixture;
  perform pg_temp.as_v87_user(f.owner_id);

  perform pg_temp.expect_v87_error(
    format(
      'select public.reschedule_appointment_v48(%L,%L,%L,60,%L,null,%L)',
      f.business_id,f.overdue_appointment,clock_timestamp()-interval '1 minute',
      f.staff_a,gen_random_uuid()
    ),
    'past amendment target',
    '22023'
  );

  for v_terminal,v_label in
    select *
      from (values
        (f.completed_appointment,'completed appointment'),
        (f.cancelled_appointment,'cancelled appointment'),
        (f.no_show_appointment,'no-show appointment')
      ) rejected(appointment_id,label)
  loop
    perform pg_temp.expect_v87_error(
      format(
        'select public.reschedule_appointment_v48(%L,%L,%L,60,%L,null,%L)',
        f.business_id,v_terminal,f.future_target,f.staff_a,gen_random_uuid()
      ),
      v_label,
      '22023'
    );
  end loop;
end
$v87_target_and_access_rejections$;

reset role;
do $v87_branch_rejection$
declare f pg_temp.v87_fixture%rowtype;
begin
  select * into f from pg_temp.v87_fixture;
  perform pg_temp.as_v87_user(f.branch_limited_id);
  perform pg_temp.expect_v87_error(
    format(
      'select public.reschedule_appointment_v48(%L,%L,%L,60,%L,null,%L)',
      f.business_id,f.overdue_appointment,f.future_target,f.staff_a,gen_random_uuid()
    ),
    'out-of-scope branch amendment',
    '42501'
  );
end
$v87_branch_rejection$;

reset role;
do $v87_tenant_rejection$
declare f pg_temp.v87_fixture%rowtype;
begin
  select * into f from pg_temp.v87_fixture;
  perform pg_temp.as_v87_user(f.foreign_owner_id);
  perform pg_temp.expect_v87_error(
    format(
      'select public.reschedule_appointment_v48(%L,%L,%L,60,%L,null,%L)',
      f.business_id,f.overdue_appointment,f.future_target,f.staff_a,gen_random_uuid()
    ),
    'foreign-tenant amendment',
    '42501'
  );
end
$v87_tenant_rejection$;

reset role;
do $v87_overdue_success_and_idempotency$
declare
  f pg_temp.v87_fixture%rowtype;
  v_key uuid:=gen_random_uuid();
  v_first jsonb;
  v_replay jsonb;
  v_before_count bigint;
  v_after_count bigint;
begin
  select * into f from pg_temp.v87_fixture;
  select count(*) into v_before_count from public.appointments
   where business_id=f.business_id and id=f.overdue_appointment;
  perform pg_temp.as_v87_user(f.owner_id);

  v_first:=public.reschedule_appointment_v48(
    f.business_id,f.overdue_appointment,f.future_target,60,f.staff_a,
    'overdue appointment rescued',v_key
  );
  v_replay:=public.reschedule_appointment_v48(
    f.business_id,f.overdue_appointment,f.future_target,60,f.staff_a,
    'overdue appointment rescued',v_key
  );

  if v_first->>'status'<>'rescheduled'
     or coalesce((v_first->>'replayed')::boolean,true) then
    raise exception 'overdue booked amendment did not succeed: %',v_first;
  end if;
  if coalesce((v_replay->>'replayed')::boolean,false) is not true
     or (v_first-'replayed') is distinct from (v_replay-'replayed') then
    raise exception 'same-key replay did not return the original outcome: first %, replay %',
      v_first,v_replay;
  end if;
  if (select starts_at from public.appointments where id=f.overdue_appointment)
       is distinct from f.future_target
     or (select status from public.appointments where id=f.overdue_appointment)<>'booked' then
    raise exception 'overdue appointment was not moved to the future as booked';
  end if;
  select count(*) into v_after_count from public.appointments
   where business_id=f.business_id and id=f.overdue_appointment;
  if v_before_count<>1 or v_after_count<>1 then
    raise exception 'idempotent replay duplicated or removed the appointment';
  end if;
  if pg_temp.v87_operation_count(f.business_id,v_key)<>1 then
    raise exception 'idempotent replay did not emit exactly one operation record';
  end if;
  if pg_temp.v87_audit_count(f.business_id,f.overdue_appointment)<>1 then
    raise exception 'idempotent replay did not emit exactly one amendment audit record';
  end if;

  perform pg_temp.expect_v87_error(
    format(
      'select public.reschedule_appointment_v48(%L,%L,%L,60,%L,%L,%L)',
      f.business_id,f.overdue_appointment,f.future_target+interval '30 minutes',
      f.staff_a,'changed payload',v_key
    ),
    'changed payload with reused idempotency key',
    '22023'
  );

  if pg_temp.v87_operation_count(f.business_id,v_key)<>1
     or pg_temp.v87_audit_count(f.business_id,f.overdue_appointment)<>1 then
    raise exception 'changed-payload rejection duplicated operation or audit evidence';
  end if;
end
$v87_overdue_success_and_idempotency$;

reset role;
rollback;
