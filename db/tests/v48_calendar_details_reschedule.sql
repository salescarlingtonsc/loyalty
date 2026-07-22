-- Rollback-only v48 appointment reschedule acceptance suite.
-- Run after the complete canonical chain through v48. Synthetic rows never commit.
begin;

create temporary table pg_temp.v48_fixture(
  business_id uuid primary key,
  owner_id uuid not null,
  rw_id uuid not null,
  customer_user_id uuid not null,
  branch_a uuid not null,
  branch_b uuid not null,
  staff_a uuid not null,
  staff_b uuid not null,
  inactive_staff uuid not null,
  foreign_staff uuid not null,
  service_id uuid not null,
  inactive_service_id uuid not null,
  client_id uuid not null,
  appointment_unavailable uuid not null,
  appointment_suppressed uuid not null,
  appointment_created uuid not null,
  appointment_conflict uuid not null,
  blocker_appointment uuid not null,
  appointment_no_link uuid not null,
  appointment_inactive_identity uuid not null,
  appointment_inactive_service uuid not null,
  identity_id uuid not null,
  link_id uuid not null,
  first_start timestamptz not null,
  second_start timestamptz not null,
  third_start timestamptz not null,
  conflict_original_start timestamptz not null,
  conflict_target_start timestamptz not null
) on commit drop;

do $v48_fixture$
declare
  v_owner uuid:=gen_random_uuid();
  v_rw uuid:=gen_random_uuid();
  v_customer_user uuid:=gen_random_uuid();
  v_inactive_customer_user uuid:=gen_random_uuid();
  v_foreign_user uuid:=gen_random_uuid();
  v_business uuid;v_foreign_business uuid;v_branch_a uuid;v_branch_b uuid;v_staff_a uuid;v_staff_b uuid;
  v_inactive_staff uuid;v_foreign_staff uuid;v_service uuid;v_inactive_service uuid;
  v_client uuid;v_no_link_client uuid;v_inactive_client uuid;v_identity uuid;v_inactive_identity uuid;v_link uuid;v_inactive_link uuid;
  v_unavailable uuid;v_suppressed uuid;v_created uuid;v_conflict uuid;v_blocker uuid;
  v_no_link_appointment uuid;v_inactive_identity_appointment uuid;v_inactive_service_appointment uuid;
  v_base timestamptz:=date_trunc('day',clock_timestamp() at time zone 'Asia/Singapore')
    +interval '4 days 9 hours';
  v_first timestamptz;v_second timestamptz;v_third timestamptz;
  v_conflict_original timestamptz;v_conflict_target timestamptz;
begin
  v_first:=v_base at time zone 'Asia/Singapore';
  v_second:=v_first+interval '3 hours';v_third:=v_first+interval '6 hours';
  v_conflict_original:=v_first+interval '1 day';v_conflict_target:=v_first+interval '1 day 3 hours';
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated','v48-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_rw,'authenticated','authenticated','v48-rw-'||substr(v_rw::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_customer_user,'authenticated','authenticated','v48-customer-'||substr(v_customer_user::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_inactive_customer_user,'authenticated','authenticated','v48-inactive-customer-'||substr(v_inactive_customer_user::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_foreign_user,'authenticated','authenticated','v48-foreign-'||substr(v_foreign_user::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.businesses(name,slug,industry,enabled_modules)
  values ('V48 synthetic calendar','v48-calendar-'||substr(v_owner::text,1,8),'test',array['appointments','clients','services','branches'])
  returning id into v_business;
  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values (v_business,v_owner,'owner','V48 Owner',true,null,null) returning id into v_staff_a;
  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values (v_business,v_rw,'staff','V48 Branch A Staff',true,array['appointments'],'{"appointments":"rw"}'::jsonb)
  returning id into v_staff_b;
  insert into public.staff(business_id,role,full_name,active,modules,module_perms)
  values (v_business,'staff','V48 Inactive Staff',false,array['appointments'],'{"appointments":"rw"}'::jsonb)
  returning id into v_inactive_staff;
  insert into public.businesses(name,slug,industry,enabled_modules)
  values ('V48 foreign calendar','v48-foreign-'||substr(v_foreign_user::text,1,8),'test',array['appointments'])
  returning id into v_foreign_business;
  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values (v_foreign_business,v_foreign_user,'owner','V48 Foreign Staff',true,null,null)
  returning id into v_foreign_staff;
  insert into public.branches(business_id,name,timezone,active,is_default)
  values (v_business,'V48 Branch A','Asia/Singapore',true,true) returning id into v_branch_a;
  insert into public.branches(business_id,name,timezone,active,is_default)
  values (v_business,'V48 Branch B','Asia/Singapore',true,false) returning id into v_branch_b;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values (v_business,v_staff_a,v_branch_a),(v_business,v_staff_a,v_branch_b),(v_business,v_staff_b,v_branch_a),
         (v_business,v_inactive_staff,v_branch_b);
  insert into public.services(business_id,name,price_cents,duration_min,active,buffer_before_min,buffer_after_min)
  values (v_business,'V48 Synthetic Service',8800,60,true,0,0) returning id into v_service;
  insert into public.services(business_id,name,price_cents,duration_min,active,buffer_before_min,buffer_after_min)
  values (v_business,'V48 Inactive Service',5500,60,false,0,0) returning id into v_inactive_service;
  insert into public.clients(business_id,full_name,phone,email,notes)
  values (v_business,'V48 Synthetic Customer','81234567','v48-customer@example.test','synthetic only') returning id into v_client;
  insert into public.clients(business_id,full_name) values (v_business,'V48 No-link Customer') returning id into v_no_link_client;
  insert into public.clients(business_id,full_name) values (v_business,'V48 Inactive Identity Customer') returning id into v_inactive_client;
  insert into public.customer_identities(auth_user_id,status,created_via)
  values (v_customer_user,'active','wallet_start') returning id into v_identity;
  v_link:=gen_random_uuid();
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link,v_business,v_identity,v_customer_user,v_client,'verified','email_claim',now());
  insert into public.customer_identities(auth_user_id,status,created_via)
  values (v_inactive_customer_user,'disabled','wallet_start') returning id into v_inactive_identity;
  v_inactive_link:=gen_random_uuid();
  perform set_config('app.customer_link_insert_id',v_inactive_link::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_inactive_link,v_business,v_inactive_identity,v_inactive_customer_user,v_inactive_client,'verified','email_claim',now());
  insert into public.appointments(business_id,client_id,branch_id,service_id,staff_id,starts_at,ends_at,status,total_cents,note)
  values
    (v_business,v_client,v_branch_b,v_service,v_staff_a,v_first,v_first+interval '1 hour','booked',8800,'unavailable fixture'),
    (v_business,v_client,v_branch_b,v_service,v_staff_a,v_second,v_second+interval '1 hour','booked',8800,'suppressed fixture'),
    (v_business,v_client,v_branch_b,v_service,v_staff_a,v_third,v_third+interval '1 hour','booked',8800,'created fixture'),
    (v_business,v_client,v_branch_b,v_service,v_staff_a,v_conflict_original,v_conflict_original+interval '1 hour','booked',8800,'conflict fixture'),
    (v_business,v_client,v_branch_b,v_service,v_staff_a,v_conflict_target,v_conflict_target+interval '1 hour','booked',8800,'blocker fixture'),
    (v_business,v_no_link_client,v_branch_b,v_service,v_staff_a,v_first+interval '2 days',v_first+interval '2 days 1 hour','booked',8800,'no link fixture'),
    (v_business,v_inactive_client,v_branch_b,v_service,v_staff_a,v_first+interval '2 days 3 hours',v_first+interval '2 days 4 hours','booked',8800,'inactive identity fixture'),
    (v_business,v_client,v_branch_b,v_inactive_service,v_staff_a,v_first+interval '2 days 6 hours',v_first+interval '2 days 7 hours','booked',5500,'inactive service fixture');
  select id into v_unavailable from public.appointments where business_id=v_business and note='unavailable fixture';
  select id into v_suppressed from public.appointments where business_id=v_business and note='suppressed fixture';
  select id into v_created from public.appointments where business_id=v_business and note='created fixture';
  select id into v_conflict from public.appointments where business_id=v_business and note='conflict fixture';
  select id into v_blocker from public.appointments where business_id=v_business and note='blocker fixture';
  select id into v_no_link_appointment from public.appointments where business_id=v_business and note='no link fixture';
  select id into v_inactive_identity_appointment from public.appointments where business_id=v_business and note='inactive identity fixture';
  select id into v_inactive_service_appointment from public.appointments where business_id=v_business and note='inactive service fixture';
  insert into pg_temp.v48_fixture values(
    v_business,v_owner,v_rw,v_customer_user,v_branch_a,v_branch_b,v_staff_a,v_staff_b,v_inactive_staff,v_foreign_staff,
    v_service,v_inactive_service,v_client,v_unavailable,v_suppressed,v_created,v_conflict,v_blocker,
    v_no_link_appointment,v_inactive_identity_appointment,v_inactive_service_appointment,
    v_identity,v_link,v_first,v_second,v_third,v_conflict_original,v_conflict_target
  );
end
$v48_fixture$;

create or replace function pg_temp.as_v48_user(p_uid uuid,p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v48_user(uuid,text) to public;

create or replace function pg_temp.expect_v48_error(p_sql text,p_label text,p_sqlstate text default '42501')
returns void language plpgsql as $$
begin
  execute p_sql;raise exception '% unexpectedly succeeded',p_label;
exception when others then
  if sqlstate<>p_sqlstate then raise exception '% failed with %, expected %: %',p_label,sqlstate,p_sqlstate,sqlerrm;end if;
end
$$;
grant execute on function pg_temp.expect_v48_error(text,text,text) to public;

create or replace function pg_temp.v48_operation_count(p_business uuid,p_key uuid)
returns bigint language sql stable security definer
set search_path to 'pg_catalog','app','pg_temp'
as $$ select count(*) from app.appointment_reschedule_operations
      where business_id=$1 and idempotency_key=$2 $$;
grant execute on function pg_temp.v48_operation_count(uuid,uuid) to public;

create or replace function pg_temp.v48_confirmation_count(p_business uuid,p_identity uuid)
returns bigint language sql stable security definer
set search_path to 'pg_catalog','public','pg_temp'
as $$ select count(*) from public.customer_in_app_inbox_events
      where business_id=$1 and identity_id=$2
        and source_kind='v48_appointment_reschedule' and title='Appointment time changed' $$;
grant execute on function pg_temp.v48_confirmation_count(uuid,uuid) to public;

do $v48_acl$
declare f pg_temp.v48_fixture%rowtype;v_definition text;
begin
  select * into f from pg_temp.v48_fixture;
  select pg_get_functiondef('public.reschedule_appointment_v48(uuid,uuid,timestamptz,integer,uuid,text,uuid)'::regprocedure)
    into v_definition;
  if position('pg_advisory_xact_lock(hashtextextended(p_business::text,47))' in replace(v_definition,' ',''))=0
     or position('pg_advisory_xact_lock(hashtextextended(p_business::text,47))' in replace(v_definition,' ',''))
        > position('staff_free_for_appointment_v47' in replace(v_definition,' ','')) then
    raise exception 'v48 must acquire v47 shared scheduling lock before availability';
  end if;
  if has_function_privilege('anon','public.reschedule_appointment_v48(uuid,uuid,timestamptz,integer,uuid,text,uuid)'::regprocedure,'execute')
     or not has_function_privilege('authenticated','public.reschedule_appointment_v48(uuid,uuid,timestamptz,integer,uuid,text,uuid)'::regprocedure,'execute') then
    raise exception 'v48 reschedule RPC ACL is not authenticated-only';
  end if;
  if has_table_privilege('authenticated','app.appointment_reschedule_operations','select')
     or has_table_privilege('authenticated','public.appointments','update') then
    raise exception 'v48 exposed operation evidence or raw appointment writes';
  end if;
  perform pg_temp.as_v48_user(null,'anon');
  perform pg_temp.expect_v48_error(format(
    'select public.reschedule_appointment_v48(%L,%L,%L,60,%L,null,%L)',
    f.business_id,f.appointment_unavailable,f.first_start+interval '30 minutes',f.staff_a,gen_random_uuid()
  ),'anonymous reschedule');
end
$v48_acl$;

reset role;
do $v48_branch_scope$
declare f pg_temp.v48_fixture%rowtype;
begin
  select * into f from pg_temp.v48_fixture;perform pg_temp.as_v48_user(f.rw_id);
  perform pg_temp.expect_v48_error(format(
    'select public.reschedule_appointment_v48(%L,%L,%L,60,%L,null,%L)',
    f.business_id,f.appointment_unavailable,f.first_start+interval '30 minutes',f.staff_a,gen_random_uuid()
  ),'foreign branch reschedule');
end
$v48_branch_scope$;

reset role;
update app.platform_feature_flags set enabled=false where feature_key='customer_in_app_inbox';
do $v48_unavailable_and_replay$
declare f pg_temp.v48_fixture%rowtype;v_first jsonb;v_replay jsonb;v_key uuid:=gen_random_uuid();v_new timestamptz;
begin
  select * into f from pg_temp.v48_fixture;perform pg_temp.as_v48_user(f.owner_id);v_new:=f.first_start+interval '30 minutes';
  v_first:=public.reschedule_appointment_v48(f.business_id,f.appointment_unavailable,v_new,60,f.staff_a,'changed safely',v_key);
  v_replay:=public.reschedule_appointment_v48(f.business_id,f.appointment_unavailable,v_new,60,f.staff_a,'changed safely',v_key);
  if v_first->>'status'<>'rescheduled' or v_first->>'notification_state'<>'unavailable' or coalesce((v_first->>'replayed')::boolean,true) then
    raise exception 'unavailable reschedule result mismatch: %',v_first;
  end if;
  if coalesce((v_replay->>'replayed')::boolean,false) is not true then raise exception 'idempotent replay was not reported';end if;
  if (select starts_at from public.appointments where id=f.appointment_unavailable)<>v_new then raise exception 'successful reschedule did not persist';end if;
  if pg_temp.v48_operation_count(f.business_id,v_key)<>1 then raise exception 'replay duplicated operation evidence';end if;
  perform pg_temp.expect_v48_error(format(
    'select public.reschedule_appointment_v48(%L,%L,%L,60,%L,%L,%L)',
    f.business_id,f.appointment_unavailable,v_new,f.staff_a,'changed safely',gen_random_uuid()
  ),'no-op reschedule','22023');
end
$v48_unavailable_and_replay$;

reset role;
update app.platform_feature_flags set enabled=true where feature_key='customer_in_app_inbox';
do $v48_relationship_rejections$
declare f pg_temp.v48_fixture%rowtype;v_no_link_start timestamptz;v_inactive_service_start timestamptz;
begin
  select * into f from pg_temp.v48_fixture;perform pg_temp.as_v48_user(f.owner_id);
  select starts_at into v_no_link_start from public.appointments where id=f.appointment_no_link;
  select starts_at into v_inactive_service_start from public.appointments where id=f.appointment_inactive_service;
  perform pg_temp.expect_v48_error(format(
    'select public.reschedule_appointment_v48(%L,%L,%L,60,%L,null,%L)',
    f.business_id,f.appointment_no_link,v_no_link_start+interval '30 minutes',f.inactive_staff,gen_random_uuid()
  ),'inactive staff assignment','22023');
  perform pg_temp.expect_v48_error(format(
    'select public.reschedule_appointment_v48(%L,%L,%L,60,%L,null,%L)',
    f.business_id,f.appointment_no_link,v_no_link_start+interval '30 minutes',f.foreign_staff,gen_random_uuid()
  ),'foreign staff assignment','22023');
  perform pg_temp.expect_v48_error(format(
    'select public.reschedule_appointment_v48(%L,%L,%L,60,%L,null,%L)',
    f.business_id,f.appointment_inactive_service,v_inactive_service_start+interval '30 minutes',f.staff_a,gen_random_uuid()
  ),'inactive service reschedule','22023');
end
$v48_relationship_rejections$;

reset role;
do $v48_not_applicable$
declare f pg_temp.v48_fixture%rowtype;v_no_link jsonb;v_inactive_identity jsonb;v_start timestamptz;
begin
  select * into f from pg_temp.v48_fixture;perform pg_temp.as_v48_user(f.owner_id);
  select starts_at into v_start from public.appointments where id=f.appointment_no_link;
  v_no_link:=public.reschedule_appointment_v48(
    f.business_id,f.appointment_no_link,v_start+interval '30 minutes',60,f.staff_a,null,gen_random_uuid());
  if v_no_link->>'notification_state'<>'not_applicable' then
    raise exception 'no-link appointment must be not_applicable: %',v_no_link;
  end if;
  select starts_at into v_start from public.appointments where id=f.appointment_inactive_identity;
  v_inactive_identity:=public.reschedule_appointment_v48(
    f.business_id,f.appointment_inactive_identity,v_start+interval '30 minutes',60,f.staff_a,null,gen_random_uuid());
  if v_inactive_identity->>'notification_state'<>'not_applicable' then
    raise exception 'inactive identity appointment must be not_applicable: %',v_inactive_identity;
  end if;
end
$v48_not_applicable$;

reset role;
do $v48_suppressed$
declare f pg_temp.v48_fixture%rowtype;v_result jsonb;v_new timestamptz;
begin
  select * into f from pg_temp.v48_fixture;perform pg_temp.as_v48_user(f.owner_id);v_new:=f.second_start+interval '30 minutes';
  v_result:=public.reschedule_appointment_v48(f.business_id,f.appointment_suppressed,v_new,60,f.staff_a,null,gen_random_uuid());
  if v_result->>'notification_state'<>'suppressed' then raise exception 'opt-out was not suppressed: %',v_result;end if;
end
$v48_suppressed$;

reset role;
do $v48_enable_preference$
declare f pg_temp.v48_fixture%rowtype;
begin
  select * into f from pg_temp.v48_fixture;
  insert into public.customer_notification_preferences(
    business_id,identity_id,auth_user_id,link_id,client_id,channel,topic,opted_in,consent_at
  ) values (f.business_id,f.identity_id,f.customer_user_id,f.link_id,f.client_id,'in_app','booking_updates',true,now());
end
$v48_enable_preference$;

do $v48_created_and_conflict$
declare f pg_temp.v48_fixture%rowtype;v_created jsonb;v_conflict jsonb;v_created_new timestamptz;v_before timestamptz;
begin
  select * into f from pg_temp.v48_fixture;perform pg_temp.as_v48_user(f.owner_id);v_created_new:=f.third_start+interval '30 minutes';
  v_created:=public.reschedule_appointment_v48(f.business_id,f.appointment_created,v_created_new,60,f.staff_a,null,gen_random_uuid());
  if v_created->>'notification_state'<>'in_app_created' then raise exception 'opted-in in-app confirmation missing: %',v_created;end if;
  if pg_temp.v48_confirmation_count(f.business_id,f.identity_id)<>1 then
    raise exception 'customer-safe confirmation event was not created';
  end if;
  select starts_at into v_before from public.appointments where id=f.appointment_conflict;
  v_conflict:=public.reschedule_appointment_v48(f.business_id,f.appointment_conflict,f.conflict_target_start,60,f.staff_a,null,gen_random_uuid());
  if v_conflict->>'status'<>'conflict' or jsonb_array_length(v_conflict#>'{suggestions,next_best_slots}')<1 then
    raise exception 'conflict suggestions missing: %',v_conflict;
  end if;
  if (select starts_at from public.appointments where id=f.appointment_conflict)<>v_before then
    raise exception 'conflict path mutated the appointment';
  end if;
end
$v48_created_and_conflict$;

reset role;
rollback;
