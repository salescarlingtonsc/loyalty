-- Rollback-only v47 smart scheduling acceptance suite.
-- Run after the complete canonical chain through v47.
begin;

create temporary table pg_temp.v47_fixture (
  business_id uuid primary key,
  owner_id uuid not null,
  branch_id uuid not null,
  service_id uuid not null,
  client_id uuid not null,
  manager_id uuid not null,
  rw_id uuid not null,
  readonly_id uuid not null,
  bookkeeper_id uuid not null,
  denied_id uuid not null,
  inactive_id uuid not null,
  foreign_id uuid not null,
  other_business_id uuid not null,
  other_branch_id uuid not null,
  alpha_staff_id uuid not null,
  beta_staff_id uuid not null,
  past_appointment_id uuid not null,
  starts_at timestamptz not null
) on commit drop;

do $v47_fixture$
declare
  v_owner uuid := gen_random_uuid();
  v_alpha_user uuid := gen_random_uuid();
  v_beta_user uuid := gen_random_uuid();
  v_manager_user uuid := gen_random_uuid();
  v_rw_user uuid := gen_random_uuid();
  v_readonly_user uuid := gen_random_uuid();
  v_bookkeeper_user uuid := gen_random_uuid();
  v_denied_user uuid := gen_random_uuid();
  v_inactive_user uuid := gen_random_uuid();
  v_foreign_user uuid := gen_random_uuid();
  v_business uuid;
  v_other_business uuid;
  v_branch uuid;
  v_other_branch uuid;
  v_service uuid;
  v_client uuid;
  v_alpha uuid;
  v_beta uuid;
  v_past_appointment uuid;
  v_local_start timestamp := date_trunc('day', clock_timestamp() at time zone 'Asia/Singapore')
    + interval '2 days 10 hours';
  v_starts timestamptz;
  v_weekday smallint;
begin
  v_starts := v_local_start at time zone 'Asia/Singapore';
  v_weekday := extract(dow from v_local_start)::smallint;

  insert into auth.users (
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
      'v47-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_alpha_user,'authenticated','authenticated',
      'v47-alpha-'||substr(v_alpha_user::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_beta_user,'authenticated','authenticated',
      'v47-beta-'||substr(v_beta_user::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_manager_user,'authenticated','authenticated',
      'v47-manager-'||substr(v_manager_user::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_rw_user,'authenticated','authenticated',
      'v47-rw-'||substr(v_rw_user::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_readonly_user,'authenticated','authenticated',
      'v47-readonly-'||substr(v_readonly_user::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_bookkeeper_user,'authenticated','authenticated',
      'v47-bookkeeper-'||substr(v_bookkeeper_user::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_denied_user,'authenticated','authenticated',
      'v47-denied-'||substr(v_denied_user::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_inactive_user,'authenticated','authenticated',
      'v47-inactive-'||substr(v_inactive_user::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_foreign_user,'authenticated','authenticated',
      'v47-foreign-'||substr(v_foreign_user::text,1,8)||'@example.test','',now(),now(),now());

  insert into public.businesses(name,slug,industry,enabled_modules)
  values ('V47 scheduling fixture','v47-scheduling-'||substr(v_owner::text,1,8),'test',
    array['dashboard','clients','services','branches','appointments']) returning id into v_business;
  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values (v_business,v_owner,'owner','V47 Owner',true,null,null);
  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values (v_business,v_alpha_user,'staff','Alpha Staff',true,array['appointments'],
    '{"appointments":"rw"}'::jsonb) returning id into v_alpha;
  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values (v_business,v_beta_user,'staff','Beta Staff',true,array['appointments'],
    '{"appointments":"rw"}'::jsonb) returning id into v_beta;
  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values
    (v_business,v_manager_user,'manager','V47 Manager',true,array['appointments'],
      '{"appointments":"rw"}'::jsonb),
    (v_business,v_rw_user,'staff','V47 RW Staff',true,array['appointments'],
      '{"appointments":"rw"}'::jsonb),
    (v_business,v_readonly_user,'staff','V47 Read-only Staff',true,array['appointments'],
      '{"appointments":"r"}'::jsonb),
    (v_business,v_bookkeeper_user,'bookkeeper','V47 Bookkeeper',true,array['appointments'],
      '{"appointments":"rw"}'::jsonb),
    (v_business,v_denied_user,'staff','V47 Denied Staff',true,array[]::text[],
      '{}'::jsonb),
    (v_business,v_inactive_user,'staff','V47 Inactive Staff',false,array['appointments'],
      '{"appointments":"rw"}'::jsonb);

  insert into public.branches(business_id,name,timezone,active,is_default)
  values (v_business,'V47 Branch','Asia/Singapore',true,true) returning id into v_branch;
  insert into public.branches(business_id,name,timezone,active,is_default)
  values (v_business,'V47 Other Branch','Asia/Singapore',true,false) returning id into v_other_branch;
  insert into public.branch_hours(business_id,branch_id,weekday,opens_at,closes_at)
  values (v_business,v_branch,v_weekday,'09:00','18:00');
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values (v_business,v_alpha,v_branch),(v_business,v_beta,v_branch);
  insert into public.staff_branches(business_id,staff_id,branch_id)
  select v_business,staff.id,v_branch from public.staff staff
   where staff.business_id=v_business
     and staff.user_id in (
       v_manager_user,v_rw_user,v_readonly_user,v_bookkeeper_user,v_denied_user,v_inactive_user
     );
  insert into public.staff_hours(business_id,staff_id,weekday,starts_at,ends_at)
  values (v_business,v_alpha,v_weekday,'09:00','18:00'),
         (v_business,v_beta,v_weekday,'09:00','18:00');

  insert into public.services(
    business_id,name,price_cents,duration_min,active,buffer_before_min,buffer_after_min
  ) values (v_business,'V47 Service',5000,60,true,15,15) returning id into v_service;
  insert into public.staff_services(business_id,staff_id,service_id)
  values (v_business,v_alpha,v_service),(v_business,v_beta,v_service);
  insert into public.clients(business_id,full_name,phone)
  values (v_business,'V47 Customer','+65 8000 0047') returning id into v_client;
  insert into public.appointments(
    business_id,client_id,branch_id,service_id,staff_id,starts_at,ends_at,status,total_cents,note,created_at
  ) values (
    v_business,v_client,v_branch,v_service,v_beta,
    clock_timestamp()-interval '2 hours',clock_timestamp()-interval '1 hour',
    'booked',5000,'v47 past completion fixture',clock_timestamp()-interval '1 hour'
  ) returning id into v_past_appointment;

  insert into public.businesses(name,slug,industry,enabled_modules)
  values ('V47 foreign fixture','v47-foreign-'||substr(v_foreign_user::text,1,8),'test',
    array['dashboard','appointments']) returning id into v_other_business;
  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values (v_other_business,v_foreign_user,'manager','V47 Foreign Manager',true,
    array['appointments'],'{"appointments":"rw"}'::jsonb);

  insert into pg_temp.v47_fixture values (
    v_business,v_owner,v_branch,v_service,v_client,
    v_manager_user,v_rw_user,v_readonly_user,v_bookkeeper_user,v_denied_user,v_inactive_user,
    v_foreign_user,v_other_business,v_other_branch,v_alpha,v_beta,v_past_appointment,v_starts
  );
end
$v47_fixture$;

create or replace function pg_temp.as_v47_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object(
    'sub',p_uid,'role',p_role
  )::text,true);
end
$$;
grant execute on function pg_temp.as_v47_user(uuid,text) to public;

create or replace function pg_temp.expect_v47_error(
  p_sql text,
  p_label text,
  p_sqlstate text default '42501'
) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception '% unexpectedly succeeded',p_label;
exception
  when others then
    if sqlstate <> p_sqlstate then
      raise exception '% failed with %, expected %: %',p_label,sqlstate,p_sqlstate,sqlerrm;
    end if;
end
$$;
grant execute on function pg_temp.expect_v47_error(text,text,text) to public;

do $v47_test$
declare
  f pg_temp.v47_fixture%rowtype;
  v_suggestion jsonb;
  v_first jsonb;
  v_replay jsonb;
  v_second jsonb;
  v_conflict jsonb;
  v_status jsonb;
  v_quick jsonb;
  v_quick_replay jsonb;
  v_matrix_booking jsonb;
  v_owner_staff uuid;
  v_blocked boolean;
  v_weekday smallint;
begin
  select * into f from pg_temp.v47_fixture;
  perform pg_temp.as_v47_user(f.owner_id);

  if to_regprocedure('public.suggest_appointment_staff_v47(uuid,uuid,uuid,timestamptz,integer,integer)') is null
     or to_regprocedure('public.book_appointment_smart_v47(uuid,uuid,uuid,uuid,timestamptz,integer,uuid,text,text,text)') is null
     or to_regprocedure('public.set_appointment_status_v47(uuid,uuid,text)') is null then
    raise exception 'v47 RPC surface is incomplete';
  end if;
  if exists (
    select 1
      from pg_proc proc
      join pg_namespace namespace on namespace.oid=proc.pronamespace
     where namespace.nspname='public'
       and proc.proname=any(array[
         'join_program','enrol_customer','get_join_page','request_booking',
         'get_booking_availability','get_business_public','list_my_appointments','request_change'
       ])
       and (
         has_function_privilege('anon',proc.oid,'execute')
         or has_function_privilege('authenticated',proc.oid,'execute')
       )
  ) then
    raise exception 'v47 reopened a deprecated browser-executable public gateway overload';
  end if;
  if to_regprocedure('public.internal_public_booking_change(text,uuid,text,text,timestamptz,text)') is null
     or has_function_privilege('anon',
       'public.internal_public_booking_change(text,uuid,text,text,timestamptz,text)'::regprocedure,
       'execute')
     or has_function_privilege('authenticated',
       'public.internal_public_booking_change(text,uuid,text,text,timestamptz,text)'::regprocedure,
       'execute')
     or not has_function_privilege('service_role',
       'public.internal_public_booking_change(text,uuid,text,text,timestamptz,text)'::regprocedure,
       'execute') then
    raise exception 'v47 final gateway ACLs must preserve the service-only Turnstile path';
  end if;
  if has_function_privilege('anon',
       'public.book_appointment_smart_v47(uuid,uuid,uuid,uuid,timestamptz,integer,uuid,text,text,text)'::regprocedure,
       'execute')
     or not has_function_privilege('authenticated',
       'public.book_appointment_smart_v47(uuid,uuid,uuid,uuid,timestamptz,integer,uuid,text,text,text)'::regprocedure,
       'execute') then
    raise exception 'v47 booking RPC must be authenticated-only';
  end if;
  if has_function_privilege('authenticated',
       'public.record_sale_by_phone(uuid,text,integer,text,text,uuid,text)'::regprocedure,
       'execute')
     or has_function_privilege('anon',
       'public.record_sale_by_phone(uuid,text,integer,text,text,uuid,text,uuid,text)'::regprocedure,
       'execute')
     or not has_function_privilege('authenticated',
       'public.record_sale_by_phone(uuid,text,integer,text,text,uuid,text,uuid,text)'::regprocedure,
       'execute') then
    raise exception 'v47 Quick earn must expose only the explicit branch-and-tender overload';
  end if;
  if has_table_privilege('authenticated','public.appointments','insert')
     or has_table_privilege('authenticated','public.appointments','update')
     or has_table_privilege('authenticated','public.appointments','delete')
     or has_table_privilege('authenticated','app.appointment_booking_operations','select') then
    raise exception 'v47 left raw appointment writes or operation hashes browser-accessible';
  end if;
  perform pg_temp.expect_v47_error(format(
    'insert into public.appointments(business_id,client_id,branch_id,starts_at,ends_at,status) values (%L::uuid,%L::uuid,%L::uuid,%L::timestamptz,%L::timestamptz,%L)',
    f.business_id,f.client_id,f.branch_id,f.starts_at+interval '6 hours',
    f.starts_at+interval '7 hours','booked'
  ),'authenticated direct appointment insert','42501');

  v_suggestion := public.suggest_appointment_staff_v47(
    f.business_id,f.branch_id,f.service_id,f.starts_at,60,5);
  if jsonb_array_length(v_suggestion->'available_staff') <> 2
     or v_suggestion->>'recommended_staff_id' <> f.alpha_staff_id::text then
    raise exception 'v47 initial fair suggestion was not deterministic: %',v_suggestion;
  end if;

  v_first := public.book_appointment_smart_v47(
    f.business_id,f.client_id,f.branch_id,f.service_id,f.starts_at,60,null,
    'round_robin','first fair booking','v47-first-booking');
  v_replay := public.book_appointment_smart_v47(
    f.business_id,f.client_id,f.branch_id,f.service_id,f.starts_at,60,null,
    'round_robin','first fair booking','v47-first-booking');
  if v_first->>'status' <> 'booked'
     or v_first->>'staff_id' <> f.alpha_staff_id::text
     or v_replay->>'replayed' <> 'true'
     or (select count(*) from public.appointments
          where id=(v_first->>'appointment_id')::uuid) <> 1 then
    raise exception 'v47 exact replay or initial fair booking failed: % / %',v_first,v_replay;
  end if;

  v_blocked := false;
  begin
    perform public.book_appointment_smart_v47(
      f.business_id,f.client_id,f.branch_id,f.service_id,f.starts_at+interval '1 day',60,null,
      'round_robin','changed request','v47-first-booking');
  exception when sqlstate '22023' then v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'v47 changed idempotency replay did not fail closed';
  end if;

  -- Alpha is blocked from 09:45 through 11:15 because the service has 15-minute buffers.
  -- Beta remains available and must be returned instead of allowing a double-booking.
  v_conflict := public.book_appointment_smart_v47(
    f.business_id,f.client_id,f.branch_id,f.service_id,f.starts_at+interval '30 minutes',60,
    f.alpha_staff_id,'manual','buffer clash','v47-buffer-conflict');
  if v_conflict->>'status' <> 'conflict'
     or not (v_conflict->'suggestions'->'available_staff' @>
       jsonb_build_array(jsonb_build_object('staff_id',f.beta_staff_id)))
     or jsonb_array_length(v_conflict->'suggestions'->'next_best_slots') <> 2 then
    raise exception 'v47 conflict alternatives were incomplete: %',v_conflict;
  end if;

  -- At noon both are free, but Beta has fewer recent appointments and gets the fair turn.
  v_second := public.book_appointment_smart_v47(
    f.business_id,f.client_id,f.branch_id,f.service_id,f.starts_at+interval '2 hours',60,null,
    'round_robin','second fair booking','v47-second-booking');
  if v_second->>'staff_id' <> f.beta_staff_id::text then
    raise exception 'v47 fair-load rotation did not select the least-loaded staff member: %',v_second;
  end if;

  -- A future booking cannot create revenue, points or free its slot early.
  perform pg_temp.expect_v47_error(format(
    'select public.set_appointment_status_v47(%L::uuid,%L::uuid,%L)',
    f.business_id,(v_second->>'appointment_id')::uuid,'completed'
  ),'future appointment completion','22023');
  perform pg_temp.expect_v47_error(format(
    'select public.set_appointment_status_v47(%L::uuid,%L::uuid,%L)',
    f.business_id,(v_second->>'appointment_id')::uuid,'no_show'
  ),'future appointment no-show','22023');
  if exists(select 1 from public.sales sale
             where sale.appointment_id=(v_second->>'appointment_id')::uuid)
     or not exists(select 1 from public.appointments appointment
                    where appointment.id=(v_second->>'appointment_id')::uuid
                      and appointment.status='booked') then
    raise exception 'v47 future outcome guard changed the appointment or created a sale';
  end if;

  -- Completion has a separate sales capability gate and the generated sale must
  -- retain the past appointment's exact branch and staff attribution.
  v_status := public.set_appointment_status_v47(
    f.business_id,f.past_appointment_id,'completed');
  if v_status->>'status' <> 'completed'
     or not exists(
       select 1 from public.sales sale
        where sale.business_id=f.business_id
          and sale.appointment_id=f.past_appointment_id
          and sale.branch_id=f.branch_id
          and sale.staff_id=f.beta_staff_id
     ) then
    raise exception 'v47 completion did not create one branch/staff-correct sale: %',v_status;
  end if;

  -- Quick earn refuses caller-supplied staff spoofing and weak idempotency, then
  -- binds the exact replay to the authenticated active staff row.
  select staff.id into v_owner_staff from public.staff staff
   where staff.business_id=f.business_id and staff.user_id=f.owner_id and staff.active;
  perform pg_temp.expect_v47_error(format(
    'select public.record_sale_by_phone(%L::uuid,%L,2500,%L,%L,%L::uuid,%L,%L::uuid,%L)',
    f.business_id,'+65 8000 0047','quick_sale','v47 spoof',f.alpha_staff_id,'v47-spoof-key',
    f.branch_id,'paynow'
  ),'Quick earn staff spoof','42501');
  perform pg_temp.expect_v47_error(format(
    'select public.record_sale_by_phone(%L::uuid,%L,2500,%L,%L,null,null,%L::uuid,%L)',
    f.business_id,'+65 8000 0047','quick_sale','v47 missing idempotency',f.branch_id,'paynow'
  ),'Quick earn missing idempotency','22023');
  perform pg_temp.expect_v47_error(format(
    'select public.record_sale_by_phone(%L::uuid,%L,2500,%L,%L,null,%L,%L::uuid,%L)',
    f.business_id,'+65 8000 0047','service','v47 invalid kind','v47-invalid-kind',f.branch_id,'paynow'
  ),'Quick earn non-quick-sale kind','22023');
  v_quick:=public.record_sale_by_phone(
    f.business_id,'+65 8000 0047',2500,'quick_sale','v47 valid Quick earn',null,
    'v47-quick-earn-valid',f.branch_id,'paynow');
  v_quick_replay:=public.record_sale_by_phone(
    f.business_id,'+65 8000 0047',2500,'quick_sale','v47 valid Quick earn',v_owner_staff,
    'v47-quick-earn-valid',f.branch_id,'paynow');
  if v_quick->>'status'<>'ok' or v_quick_replay->>'status'<>'duplicate_ignored'
     or v_quick_replay->>'sale_id' is distinct from v_quick->>'sale_id'
     or not exists(select 1 from public.sales sale
                    where sale.id=(v_quick->>'sale_id')::uuid
                      and sale.business_id=f.business_id
                      and sale.branch_id=f.branch_id
                      and sale.staff_id=v_owner_staff
                      and sale.kind='quick_sale'
                      and sale.amount_cents=2500)
     or (select count(*) from public.payments payment
          where payment.id=(v_quick->>'payment_id')::uuid
            and payment.business_id=f.business_id
            and payment.sale_id=(v_quick->>'sale_id')::uuid
            and payment.branch_id=f.branch_id
            and payment.staff_id=v_owner_staff
            and payment.method='paynow'
            and payment.kind='payment'
            and payment.amount_cents=2500)<>1 then
    raise exception 'v47 Quick earn binding or exact replay failed: % / %',v_quick,v_quick_replay;
  end if;

  -- Authenticated role matrix: owner, manager and rw may mutate; r may only
  -- suggest/read; missing module, inactive, foreign tenant and foreign branch fail closed.
  perform pg_temp.as_v47_user(f.manager_id);
  perform public.suggest_appointment_staff_v47(
    f.business_id,f.branch_id,f.service_id,f.starts_at+interval '7 days',60,5);
  v_matrix_booking:=public.book_appointment_smart_v47(
    f.business_id,f.client_id,f.branch_id,f.service_id,f.starts_at+interval '7 days',60,null,
    'round_robin','manager matrix booking','v47-manager-matrix');
  if v_matrix_booking->>'status'<>'booked' then
    raise exception 'v47 manager rw booking failed: %',v_matrix_booking;
  end if;

  perform pg_temp.as_v47_user(f.rw_id);
  v_matrix_booking:=public.book_appointment_smart_v47(
    f.business_id,f.client_id,f.branch_id,f.service_id,f.starts_at+interval '7 days 2 hours',60,null,
    'round_robin','rw staff matrix booking','v47-rw-matrix');
  if v_matrix_booking->>'status'<>'booked' then
    raise exception 'v47 staff rw booking failed: %',v_matrix_booking;
  end if;
  perform pg_temp.expect_v47_error(format(
    'select public.suggest_appointment_staff_v47(%L::uuid,%L::uuid,%L::uuid,%L::timestamptz,60,5)',
    f.business_id,f.other_branch_id,f.service_id,f.starts_at+interval '7 days'
  ),'staff foreign-branch suggestion','42501');

  perform pg_temp.as_v47_user(f.readonly_id);
  perform public.suggest_appointment_staff_v47(
    f.business_id,f.branch_id,f.service_id,f.starts_at+interval '14 days',60,5);
  perform pg_temp.expect_v47_error(format(
    'select public.book_appointment_smart_v47(%L::uuid,%L::uuid,%L::uuid,%L::uuid,%L::timestamptz,60,null,%L,%L,%L)',
    f.business_id,f.client_id,f.branch_id,f.service_id,f.starts_at+interval '14 days',
    'round_robin','readonly denied booking','v47-readonly-denied'
  ),'read-only appointment booking','42501');

  perform pg_temp.as_v47_user(f.bookkeeper_id);
  v_matrix_booking:=public.book_appointment_smart_v47(
    f.business_id,f.client_id,f.branch_id,f.service_id,f.starts_at+interval '21 days',60,null,
    'round_robin','bookkeeper matrix booking','v47-bookkeeper-matrix');
  if v_matrix_booking->>'status'<>'booked' then
    raise exception 'v47 bookkeeper appointment write failed: %',v_matrix_booking;
  end if;
  perform pg_temp.expect_v47_error(format(
    'select public.set_appointment_status_v47(%L::uuid,%L::uuid,%L)',
    f.business_id,(v_matrix_booking->>'appointment_id')::uuid,'completed'
  ),'bookkeeper completion without create-sales','42501');
  if exists(select 1 from public.sales sale
             where sale.appointment_id=(v_matrix_booking->>'appointment_id')::uuid) then
    raise exception 'v47 unauthorized completion created a sale';
  end if;

  perform pg_temp.as_v47_user(f.denied_id);
  perform pg_temp.expect_v47_error(format(
    'select public.suggest_appointment_staff_v47(%L::uuid,%L::uuid,%L::uuid,%L::timestamptz,60,5)',
    f.business_id,f.branch_id,f.service_id,f.starts_at+interval '14 days'
  ),'missing-module appointment suggestion','42501');

  perform pg_temp.as_v47_user(f.inactive_id);
  perform pg_temp.expect_v47_error(format(
    'select public.suggest_appointment_staff_v47(%L::uuid,%L::uuid,%L::uuid,%L::timestamptz,60,5)',
    f.business_id,f.branch_id,f.service_id,f.starts_at+interval '14 days'
  ),'inactive appointment suggestion','42501');

  perform pg_temp.as_v47_user(f.foreign_id);
  perform pg_temp.expect_v47_error(format(
    'select public.suggest_appointment_staff_v47(%L::uuid,%L::uuid,%L::uuid,%L::timestamptz,60,5)',
    f.business_id,f.branch_id,f.service_id,f.starts_at+interval '14 days'
  ),'foreign-tenant appointment suggestion','42501');

  perform pg_temp.as_v47_user(f.owner_id);

  v_weekday := extract(dow from (f.starts_at at time zone 'Asia/Singapore'))::smallint;
  insert into public.branch_breaks(business_id,branch_id,weekday,starts_at,ends_at)
  values (f.business_id,f.branch_id,v_weekday,'14:00','15:00');
  v_suggestion := public.suggest_appointment_staff_v47(
    f.business_id,f.branch_id,f.service_id,f.starts_at+interval '4 hours',60,5);
  if jsonb_array_length(v_suggestion->'available_staff') <> 0 then
    raise exception 'v47 ignored a branch break: %',v_suggestion;
  end if;

  v_status := public.set_appointment_status_v47(
    f.business_id,(v_first->>'appointment_id')::uuid,'cancelled');
  if v_status->>'replayed' <> 'false'
     or public.set_appointment_status_v47(
       f.business_id,(v_first->>'appointment_id')::uuid,'cancelled')->>'replayed' <> 'true' then
    raise exception 'v47 status transition was not replay-safe';
  end if;

  raise notice 'v47 smart scheduling suite: ALL PASS';
end
$v47_test$;

rollback;
