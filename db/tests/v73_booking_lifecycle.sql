-- Rollback-only v73 atomic booking lifecycle acceptance suite.
-- Run after the complete canonical chain through v73 in a disposable database.
begin;

create or replace function pg_temp.as_v73_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_uid, 'role', p_role
  )::text, true);
end
$$;
grant execute on function pg_temp.as_v73_user(uuid,text) to public;

do $v73_test$
declare
  v_owner uuid := gen_random_uuid();
  v_manager uuid := gen_random_uuid();
  v_frontdesk uuid := gen_random_uuid();
  v_readonly uuid := gen_random_uuid();
  v_business uuid;
  v_other_business uuid;
  v_branch uuid;
  v_other_branch uuid;
  v_owner_staff uuid;
  v_manager_staff uuid;
  v_frontdesk_staff uuid;
  v_readonly_staff uuid;
  v_service uuid;
  v_bound_client uuid;
  v_table uuid;
  v_start timestamptz := (
    date_trunc('day', clock_timestamp() at time zone 'Asia/Singapore')
    + interval '7 days 10 hours'
  ) at time zone 'Asia/Singapore';
  v_weekday smallint;
  v_request uuid;
  v_request_2 uuid;
  v_waitlist uuid;
  v_result jsonb;
  v_appointment uuid;
  v_audit_count integer;
begin
  v_weekday := extract(dow from v_start at time zone 'Asia/Singapore')::smallint;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
      'v73-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_manager,'authenticated','authenticated',
      'v73-manager-'||substr(v_manager::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_frontdesk,'authenticated','authenticated',
      'v73-frontdesk-'||substr(v_frontdesk::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_readonly,'authenticated','authenticated',
      'v73-readonly-'||substr(v_readonly::text,1,8)||'@example.test','',now(),now(),now());

  insert into public.businesses(name,slug,industry,enabled_modules)
  values (
    'V73 booking lifecycle fixture',
    'v73-booking-'||substr(v_owner::text,1,8),
    'test', array['bookings','appointments','clients','services','branches']
  ) returning id into v_business;
  insert into public.businesses(name,slug,industry,enabled_modules)
  values (
    'V73 foreign fixture',
    'v73-foreign-'||substr(v_owner::text,1,8),
    'test', array['bookings','appointments']
  ) returning id into v_other_business;

  insert into public.staff(
    business_id,user_id,role,full_name,active,modules,module_perms
  ) values
    (v_business,v_owner,'owner','V73 Owner',true,null,null)
      returning id into v_owner_staff;
  insert into public.staff(
    business_id,user_id,role,full_name,active,modules,module_perms
  ) values
    (v_business,v_manager,'manager','V73 Manager',true,
      array['bookings','appointments'],
      '{"bookings":"r","appointments":"rw"}') returning id into v_manager_staff;
  insert into public.staff(
    business_id,user_id,role,full_name,active,modules,module_perms
  ) values
    (v_business,v_frontdesk,'frontdesk','V73 Frontdesk',true,
      array['bookings','appointments'],
      '{"bookings":"r","appointments":"rw"}') returning id into v_frontdesk_staff;
  insert into public.staff(
    business_id,user_id,role,full_name,active,modules,module_perms
  ) values
    (v_business,v_readonly,'frontdesk','V73 Read-only',true,
      array['bookings','appointments'],
      '{"bookings":"r","appointments":"r"}') returning id into v_readonly_staff;

  insert into public.branches(business_id,name,active,is_default)
  values (v_business,'V73 Default',true,true) returning id into v_branch;
  insert into public.branches(business_id,name,active,is_default)
  values (v_business,'V73 Other',true,false) returning id into v_other_branch;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values
    (v_business,v_owner_staff,v_branch),
    (v_business,v_manager_staff,v_branch),
    (v_business,v_frontdesk_staff,v_branch),
    (v_business,v_readonly_staff,v_branch);
  insert into public.branch_hours(business_id,branch_id,weekday,opens_at,closes_at)
  values (v_business,v_branch,v_weekday,'09:00','18:00');
  insert into public.staff_hours(
    business_id,staff_id,weekday,starts_at,ends_at
  ) values (v_business,v_owner_staff,v_weekday,'09:00','18:00');
  insert into public.services(
    business_id,name,price_cents,duration_min,active
  ) values (v_business,'V73 Service',2500,30,true)
  returning id into v_service;
  insert into public.staff_services(business_id,staff_id,service_id)
  values (v_business,v_owner_staff,v_service);
  insert into public.clients(
    business_id,full_name,phone,email,marketing_consent
  ) values (
    v_business,'V73 Bound Client','+6580000073',
    'bound-v73@example.test',false
  ) returning id into v_bound_client;

  -- SQL NULL is not a decision. It must fail before authorization/state work and
  -- cannot silently fall through to the confirm branch.
  insert into public.booking_requests(
    business_id,name,phone,party_size,preferred_at,status
  ) values (
    v_business,'Null decision fixture','+6581010073',1,v_start,'new'
  ) returning id into v_request;
  begin
    perform pg_temp.as_v73_user(v_owner);
    perform public.staff_decide_booking_request_v73(
      v_business,v_request,null,null
    );
    reset role;
    raise exception 'NULL decision confirmed a booking request';
  exception when sqlstate '22023' then
    reset role;
  end;
  if not exists (
    select 1 from public.booking_requests request
     where request.id=v_request and request.status='new'
  ) or exists (
    select 1 from public.audit_log audit
     where audit.business_id=v_business
       and audit.action='BOOKING_REQUEST_DECISION_V73'
       and audit.entity_id=v_request
  ) then
    raise exception 'NULL decision mutated or audited a booking request';
  end if;

  -- Owner decline, replay and opposite terminal result.
  insert into public.booking_requests(
    business_id,name,phone,party_size,preferred_at,status,expires_at
  ) values (
    v_business,'Decline fixture','+6581110073',1,v_start,'new',v_start
  ) returning id into v_request;
  perform pg_temp.as_v73_user(v_owner);
  v_result := public.staff_decide_booking_request_v73(
    v_business,v_request,'decline',null
  );
  reset role;
  if v_result->>'outcome' <> 'applied'
     or v_result->>'actual_status' <> 'declined'
     or v_result->>'requested_decision' <> 'decline'
     or not (v_result ? 'requested_decision')
     or v_result::text ~* '(phone|client|name|note)' then
    raise exception 'decline result stripped requested_decision or was not safe and applied: %',v_result;
  end if;
  perform pg_temp.as_v73_user(v_owner);
  v_result := public.staff_decide_booking_request_v73(
    v_business,v_request,'decline',null
  );
  reset role;
  if v_result->>'outcome' <> 'replayed'
     or (v_result->>'replayed')::boolean is not true then
    raise exception 'same decline did not replay';
  end if;
  perform pg_temp.as_v73_user(v_owner);
  v_result := public.staff_decide_booking_request_v73(
    v_business,v_request,'confirm',v_branch
  );
  reset role;
  if v_result->>'outcome' <> 'terminal_conflict' then
    raise exception 'opposite terminal decision was not truthful';
  end if;

  -- Manager has appointments:rw but bookings:r: confirm allowed, decline denied.
  insert into public.booking_requests(
    business_id,name,phone,service_id,party_size,preferred_at,status
  ) values (
    v_business,'Manager confirm','+6582220073',v_service,1,v_start,'new'
  ) returning id into v_request;
  perform pg_temp.as_v73_user(v_manager);
  v_result := public.staff_decide_booking_request_v73(
    v_business,v_request,'confirm',v_branch
  );
  reset role;
  if v_result->>'outcome' <> 'applied' then
    raise exception 'appointments:rw manager could not confirm: %',v_result;
  end if;
  if not exists (
    select 1
      from public.appointments appointment
      join public.clients client
        on client.id=appointment.client_id
       and client.business_id=appointment.business_id
     where appointment.id=(v_result->>'appointment_id')::uuid
       and client.full_name='Manager confirm'
  ) then
    raise exception 'guest confirmation did not preserve v72 client creation semantics';
  end if;

  -- The only eligible provider is already occupied at v_start. The shaped
  -- conflict must roll back tentative guest client/consent writes.
  insert into public.booking_requests(
    business_id,name,phone,service_id,party_size,preferred_at,status,
    marketing_consent
  ) values (
    v_business,'Scheduling conflict rollback','+6582320073',
    v_service,1,v_start,'new',true
  ) returning id into v_request_2;
  perform pg_temp.as_v73_user(v_owner);
  v_result := public.staff_decide_booking_request_v73(
    v_business,v_request_2,'confirm',v_branch
  );
  reset role;
  if v_result->>'outcome' <> 'scheduling_conflict'
     or exists (
       select 1 from public.clients client
        where client.business_id=v_business
          and client.full_name='Scheduling conflict rollback'
     )
     or exists (
       select 1 from public.audit_log audit
        where audit.business_id=v_business
          and audit.action='BOOKING_REQUEST_DECISION_V73'
          and audit.entity_id=v_request_2
     ) then
    raise exception 'scheduling conflict leaked a side effect';
  end if;

  begin
    insert into public.booking_requests(
      business_id,name,phone,party_size,preferred_at,status
    ) values (
      v_business,'Manager decline denied','+6583330073',1,
      v_start+interval '1 hour','new'
    ) returning id into v_request_2;
    perform pg_temp.as_v73_user(v_manager);
    perform public.staff_decide_booking_request_v73(
      v_business,v_request_2,'decline',null
    );
    reset role;
    raise exception 'bookings:r manager declined a request';
  exception when insufficient_privilege then
    reset role;
  end;

  -- Frontdesk has the same asymmetric permission and only its assigned branch.
  insert into public.booking_requests(
    business_id,name,phone,service_id,party_size,preferred_at,status
  ) values (
    v_business,'Frontdesk confirm','+6584440073',v_service,1,
    v_start+interval '1 hour','pending'
  ) returning id into v_request;
  perform pg_temp.as_v73_user(v_frontdesk);
  v_result := public.staff_decide_booking_request_v73(
    v_business,v_request,'confirm',v_branch
  );
  reset role;
  if v_result->>'outcome' <> 'applied' then
    raise exception 'appointments:rw frontdesk could not confirm';
  end if;
  begin
    insert into public.booking_requests(
      business_id,name,phone,service_id,party_size,preferred_at,status
    ) values (
      v_business,'Wrong branch','+6585550073',v_service,1,
      v_start+interval '2 hours','new'
    ) returning id into v_request_2;
    perform pg_temp.as_v73_user(v_frontdesk);
    perform public.staff_decide_booking_request_v73(
      v_business,v_request_2,'confirm',v_other_branch
    );
    reset role;
    raise exception 'frontdesk confirmed outside its branch';
  exception when insufficient_privilege then
    reset role;
  end;

  -- Bound conversion keeps the exact client and does not copy contact/consent.
  insert into public.booking_requests(
    business_id,customer_client_id,name,email,phone,service_id,
    party_size,preferred_at,status,marketing_consent
  ) values (
    v_business,v_bound_client,'Do not copy','changed@example.test',
    '+6589990073',v_service,1,v_start+interval '2 hours','pending',true
  ) returning id into v_request;
  perform pg_temp.as_v73_user(v_owner);
  v_result := public.staff_decide_booking_request_v73(
    v_business,v_request,'confirm',v_branch
  );
  reset role;
  v_appointment := (v_result->>'appointment_id')::uuid;
  if not exists (
    select 1 from public.appointments appointment
     where appointment.id=v_appointment
       and appointment.client_id=v_bound_client
       and appointment.party_size=1
       and appointment.source='portal'
  ) or not exists (
    select 1 from public.clients client
     where client.id=v_bound_client
       and client.full_name='V73 Bound Client'
       and client.email='bound-v73@example.test'
       and client.phone='+6580000073'
       and not client.marketing_consent
  ) then
    raise exception 'bound client conversion drifted';
  end if;

  -- Waitlist confirmation synchronizes the linked row and consumes capacity.
  insert into public.booking_tables(business_id,name,pax,quantity,active)
  values (v_business,'V73 Table',4,1,true) returning id into v_table;
  insert into public.booking_requests(
    business_id,name,phone,service_id,party_size,preferred_at,status,table_type_id
  ) values (
    v_business,'Waitlist confirm','+6586660073',v_service,2,
    v_start+interval '3 hours','waitlisted',v_table
  ) returning id into v_request;
  insert into public.waitlist(
    business_id,name,phone,service_id,status,booking_request_id,table_type_id
  ) values (
    v_business,'Waitlist confirm','+6586660073',v_service,
    'contacted',v_request,v_table
  ) returning id into v_waitlist;
  perform pg_temp.as_v73_user(v_owner);
  v_result := public.staff_decide_booking_request_v73(
    v_business,v_request,'confirm',v_branch
  );
  reset role;
  if v_result->>'outcome' <> 'applied'
     or v_result->>'waitlist_status' <> 'booked'
     or not exists (
       select 1 from public.appointments appointment
        where appointment.id=(v_result->>'appointment_id')::uuid
          and appointment.table_type_id=v_table
     ) then
    raise exception 'linked waitlist confirmation did not synchronize';
  end if;

  -- A second waitlisted table request sees the locked live pool as full.
  insert into public.booking_requests(
    business_id,name,phone,service_id,party_size,preferred_at,status,table_type_id
  ) values (
    v_business,'Capacity conflict','+6587770073',v_service,2,
    v_start+interval '4 hours','waitlisted',v_table
  ) returning id into v_request;
  insert into public.waitlist(
    business_id,name,phone,service_id,status,booking_request_id,table_type_id
  ) values (
    v_business,'Capacity conflict','+6587770073',v_service,
    'waiting',v_request,v_table
  );
  perform pg_temp.as_v73_user(v_owner);
  v_result := public.staff_decide_booking_request_v73(
    v_business,v_request,'confirm',v_branch
  );
  reset role;
  if v_result->>'outcome' <> 'capacity_conflict'
     or exists (
       select 1 from public.booking_requests request
        where request.id=v_request and request.status <> 'waitlisted'
     ) then
    raise exception 'capacity conflict mutated the request';
  end if;

  -- Expired pending holds no longer own capacity; the same locked calculation
  -- excludes that request and may convert when a table is actually available.
  update public.appointments
     set status='cancelled'
   where business_id=v_business and table_type_id=v_table;
  insert into public.booking_requests(
    business_id,name,phone,service_id,party_size,preferred_at,status,
    table_type_id,expires_at
  ) values (
    v_business,'Expired sibling hold','+6587870073',v_service,2,
    v_start+interval '5 hours','pending',v_table,clock_timestamp()-interval '2 minutes'
  ) returning id into v_request_2;
  insert into public.booking_requests(
    business_id,name,phone,service_id,party_size,preferred_at,status,
    table_type_id,expires_at
  ) values (
    v_business,'Expired pending hold','+6587880073',v_service,2,
    v_start+interval '5 hours','pending',v_table,clock_timestamp()-interval '1 minute'
  ) returning id into v_request;
  perform pg_temp.as_v73_user(v_owner);
  v_result := public.staff_decide_booking_request_v73(
    v_business,v_request,'confirm',v_branch
  );
  reset role;
  if v_result->>'outcome' <> 'applied' then
    raise exception 'expired sibling pending hold caused a false capacity conflict';
  end if;

  -- Read-only appointment access cannot confirm.
  begin
    insert into public.booking_requests(
      business_id,name,phone,service_id,party_size,preferred_at,status
    ) values (
      v_business,'Read-only denied','+6588880073',v_service,1,
      v_start+interval '6 hours','new'
    ) returning id into v_request;
    perform pg_temp.as_v73_user(v_readonly);
    perform public.staff_decide_booking_request_v73(
      v_business,v_request,'confirm',v_branch
    );
    reset role;
    raise exception 'appointments:r staff confirmed a request';
  exception when insufficient_privilege then
    reset role;
  end;

  -- Composite FK and unique linked-row invariant reject corrupt writes.
  begin
    insert into public.booking_requests(
      business_id,name,phone,party_size,preferred_at,status
    ) values (
      v_other_business,'Foreign request','+6580100073',1,v_start,'new'
    ) returning id into v_request_2;
    insert into public.waitlist(
      business_id,name,status,booking_request_id
    ) values (v_business,'Cross tenant','waiting',v_request_2);
    raise exception 'cross-tenant linked waitlist row was accepted';
  exception when foreign_key_violation then null;
  end;
  begin
    insert into public.waitlist(
      business_id,name,status,booking_request_id
    ) values (v_business,'Duplicate link','waiting',v_request);
    insert into public.waitlist(
      business_id,name,status,booking_request_id
    ) values (v_business,'Duplicate link 2','waiting',v_request);
    raise exception 'duplicate linked waitlist rows were accepted';
  exception when unique_violation then null;
  end;

  -- Legacy wrapper remains authenticated and delegates without recursion.
  insert into public.booking_requests(
    business_id,name,phone,service_id,party_size,preferred_at,status
  ) values (
    v_business,'Legacy wrapper','+6580200073',v_service,1,
    v_start+interval '7 hours','new'
  ) returning id into v_request;
  perform pg_temp.as_v73_user(v_owner);
  if (public.convert_booking_request(v_request)::jsonb->>'id') is null then
    raise exception 'legacy convert wrapper did not return an appointment';
  end if;
  reset role;
  if pg_get_functiondef('public.convert_booking_request(uuid)'::regprocedure)
       !~ 'staff_decide_booking_request_v73' then
    raise exception 'legacy conversion wrapper can recurse';
  end if;

  select count(*) into v_audit_count
    from public.audit_log audit
   where audit.business_id=v_business
     and audit.action='BOOKING_REQUEST_DECISION_V73'
     and audit.entity_id=v_request;
  if v_audit_count <> 1 then
    raise exception 'applied legacy decision did not have exactly one v73 audit';
  end if;
  if has_function_privilege(
       'anon',
       'public.staff_decide_booking_request_v73(uuid,uuid,text,uuid)',
       'execute'
     ) or not has_function_privilege(
       'authenticated',
       'public.staff_decide_booking_request_v73(uuid,uuid,text,uuid)',
       'execute'
     ) then
    raise exception 'v73 lifecycle ACL drifted';
  end if;

  raise notice 'v73 booking lifecycle suite: ALL PASS';
end
$v73_test$;

rollback;
