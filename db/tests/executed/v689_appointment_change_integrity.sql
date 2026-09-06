-- Rollback-only nestly_v689 acceptance: four holes in the appointment/booking change path.
--
-- WHAT THE BUGS WERE
--   F064 public.customer_reschedule_appointment_v508 cancelled the booked appointment
--        UNCONDITIONALLY and filed a booking_requests row the customer could then withdraw, so
--        Reschedule-then-Withdraw was a plain cancel at a business that had deliberately left
--        auto-approve OFF expecting to approve every cancellation.
--   F065 public.internal_public_booking_availability offered slots the write guard refuses: it
--        ignored the EXISTING appointment's buffers, offset the candidate block the wrong way,
--        and never looked at public.branch_breaks at all.
--   F066 public.decide_change called app.staff_free_for_appointment_v47 with a NULL staff_id for
--        a table-pool appointment, and that function returns false the moment p_staff is null, so
--        approving a guest's reschedule always answered 'conflict'.
--   F067 trg_booking_request_autoapprove_v660 was AFTER INSERT only, so moving a pending request
--        to a free slot never re-ran auto-approve.
--
-- WHAT THIS SUITE PROVES, against tenants it builds itself:
--    1. Auto-approve OFF: reschedule files a pending change_requests row, the appointment stays
--       'booked', and NO booking_requests row is created — so there is nothing to withdraw.
--    2. A second tap replays that same change request instead of stacking another.
--    3. Auto-approve ON: the cancel-and-refile behaviour v508 has always had is unchanged.
--    4. F066: approving a reschedule of a staff-less (table) appointment now succeeds and the
--       appointment actually moves.
--    5. F066 negative: a STAFFED appointment whose proposed time clashes still answers 'conflict'
--       and does not move — the guard was narrowed, not removed.
--    6. F067: moving a pending request's preferred_at at an auto-approving business confirms it.
--    7. F065: the slot behind an existing booking's cleanup buffer is no longer offered.
--    8. F065: a slot inside a branch break is no longer offered.
--    9. F065 positive control: a plainly free slot IS still offered, so 7 and 8 are not just an
--       empty list from a broken function (the lister swallows every exception and returns null).
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v689_appointment_change_integrity.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v689_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v689_out to public;

create or replace function pg_temp.as_v689_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v689_system() to public;

create or replace function pg_temp.as_v689_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v689_user(uuid,text) to public;

-- A tenant that can actually take a booking: approved workspace, unpaused subscription, the
-- appointments module on, one owner who is also the bookable team member, a default branch open
-- 09:00-18:00 every day, and one verified customer holding a client record.
create or replace function pg_temp.v689_tenant(
  p_business uuid, p_owner uuid, p_customer_user uuid, p_client uuid, p_label text,
  p_auto boolean
) returns void language plpgsql as $$
declare
  v_owner_staff uuid;
  v_branch uuid;
  v_identity uuid;
  v_link uuid;
  v_weekday smallint;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v689-owner-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',p_customer_user,'authenticated','authenticated',
          'v689-cust-'||substr(p_customer_user::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,
                                auto_approve_changes,booking_staff_choice,booking_auto_confirm)
  values (p_business,'V689 '||p_label,'v689-'||substr(p_business::text,1,8),
          'retail','SGD',
          array['dashboard','clients','sales','services','appointments','bookings'],
          p_auto,true,false);
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=p_owner, decided_at=now(),
         decision_reason='v689 rollback fixture'
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id)
  values (p_business) on conflict (business_id) do nothing;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = p_business;
  insert into public.subscriptions(business_id) values (p_business) on conflict do nothing;

  insert into public.business_customer_capabilities_v89(
    business_id, booking_enabled, redemption_enabled, appointment_changes_enabled)
  values (p_business, true, true, true)
  on conflict (business_id) do update
    set booking_enabled = true, appointment_changes_enabled = true;

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (p_business,p_owner,'owner','V689 Owner '||p_label,true,'approved')
  returning id into v_owner_staff;

  insert into public.branches(business_id,name,active,is_default,timezone)
  values (p_business,'V689 Main '||p_label,true,true,'Asia/Singapore')
  returning id into v_branch;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values (p_business,v_owner_staff,v_branch);

  for v_weekday in 0..6 loop
    insert into public.branch_hours(business_id,branch_id,weekday,opens_at,closes_at)
    values (p_business,v_branch,v_weekday,time '09:00',time '18:00');
  end loop;

  insert into public.clients(id,business_id,full_name,phone)
  values (p_client,p_business,'V689 Customer '||p_label,'8100'||substr(p_client::text,1,4));

  insert into public.customer_identities(auth_user_id,status)
  values (p_customer_user,'active') returning id into v_identity;
  -- app.v31_link_immutable_guard only accepts a link whose id the caller has declared.
  v_link := gen_random_uuid();
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values (v_link,p_business,v_identity,p_customer_user,p_client,'verified','email_claim',now());
  perform set_config('app.customer_link_insert_id', '', true);
end
$$;
grant execute on function pg_temp.v689_tenant(uuid,uuid,uuid,uuid,text,boolean) to public;

-- The staff member and branch a tenant built above, so the assertions can name them.
create or replace function pg_temp.v689_staff(p_business uuid) returns uuid language sql stable as $$
  select id from public.staff where business_id = p_business order by created_at, id limit 1;
$$;
grant execute on function pg_temp.v689_staff(uuid) to public;
create or replace function pg_temp.v689_branch(p_business uuid) returns uuid language sql stable as $$
  select id from public.branches where business_id = p_business order by created_at, id limit 1;
$$;
grant execute on function pg_temp.v689_branch(uuid) to public;

do $v689_test$
declare
  bManual uuid := gen_random_uuid();  oManual uuid := gen_random_uuid();
  uManual uuid := gen_random_uuid();  cManual uuid := gen_random_uuid();
  bAuto uuid := gen_random_uuid();    oAuto uuid := gen_random_uuid();
  uAuto uuid := gen_random_uuid();    cAuto uuid := gen_random_uuid();
  v_slug text;
  v_staff uuid;
  v_branch uuid;
  v_service uuid;
  v_service_short uuid;
  v_appt uuid;
  v_table_appt uuid;
  v_table_type uuid;
  v_change uuid;
  v_request uuid;
  v_res jsonb;
  v_json json;
  v_err text;
  v_status text;
  v_starts timestamptz;
  v_count integer;
  v_day date;
  v_slots jsonb;
  v_avail jsonb;
begin
  perform pg_temp.as_v689_system();
  perform pg_temp.v689_tenant(bManual,oManual,uManual,cManual,'Manual',false);
  perform pg_temp.v689_tenant(bAuto,oAuto,uAuto,cAuto,'Auto',true);

  -- Tomorrow at 10:00 Singapore: comfortably inside 09:00-18:00 and past the lister's
  -- now()+15-minutes floor whatever time this suite runs.
  v_day := ((now() at time zone 'Asia/Singapore')::date + 1);
  v_staff := pg_temp.v689_staff(bManual);
  v_branch := pg_temp.v689_branch(bManual);
  select slug into v_slug from public.businesses where id = bManual;

  insert into public.services(business_id,name,price_cents,duration_min,active,
                              show_on_booking_page,buffer_before_min,buffer_after_min)
  values (bManual,'V689 Cut',5000,60,true,true,0,15) returning id into v_service;
  insert into public.services(business_id,name,price_cents,duration_min,active,
                              show_on_booking_page,buffer_before_min,buffer_after_min)
  values (bManual,'V689 Colour',9000,60,true,true,15,0) returning id into v_service_short;

  insert into public.appointments(business_id,client_id,staff_id,service_id,branch_id,
                                  starts_at,ends_at,status,source)
  values (bManual,cManual,v_staff,v_service,v_branch,
          timezone('Asia/Singapore',(v_day + time '10:00')::timestamp),
          timezone('Asia/Singapore',(v_day + time '11:00')::timestamp),
          'booked','manual')
  returning id into v_appt;

  -- ------------------------------------------------------------------ 1. reschedule is a REQUEST
  perform pg_temp.as_v689_user(uManual);
  v_err := null;
  begin
    select public.customer_reschedule_appointment_v508(
      v_slug, v_appt,
      timezone('Asia/Singapore',(v_day + time '15:00')::timestamp), 'please') into v_res;
  exception when others then v_err := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v689_system();
  select status into v_status from public.appointments where id = v_appt;
  select count(*) into v_count from public.booking_requests
   where business_id = bManual and customer_client_id = cManual;
  select id into v_change from public.change_requests
   where business_id = bManual and appointment_id = v_appt and kind = 'reschedule';
  if v_err is null and (v_res->>'status') = 'pending' and (v_res->>'kept_booked') = 'true'
     and v_status = 'booked' and v_count = 0 and v_change is not null then
    insert into v689_out values (1,'F064 reschedule without auto-approve files a change request and keeps the booking','PASS');
  else
    insert into v689_out values (1,'F064 reschedule without auto-approve files a change request and keeps the booking',
      format('FAIL - err=%s result=%s appt_status=%s booking_requests=%s change_request=%s',
        coalesce(v_err,'<none>'),coalesce(v_res::text,'<null>'),v_status,v_count,coalesce(v_change::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 2. a second tap replays
  perform pg_temp.as_v689_user(uManual);
  v_err := null;
  begin
    select public.customer_reschedule_appointment_v508(
      v_slug, v_appt,
      timezone('Asia/Singapore',(v_day + time '16:00')::timestamp), null) into v_res;
  exception when others then v_err := sqlerrm; v_res := null;
  end;
  perform pg_temp.as_v689_system();
  select count(*) into v_count from public.change_requests
   where business_id = bManual and appointment_id = v_appt and kind = 'reschedule';
  if v_err is null and (v_res->>'replayed') = 'true'
     and (v_res->>'request_id') = v_change::text and v_count = 1 then
    insert into v689_out values (2,'F064 a second reschedule replays the pending request instead of stacking one','PASS');
  else
    insert into v689_out values (2,'F064 a second reschedule replays the pending request instead of stacking one',
      format('FAIL - err=%s result=%s change_requests=%s',
        coalesce(v_err,'<none>'),coalesce(v_res::text,'<null>'),v_count));
  end if;

  -- ------------------------------------------------------------------ 3. auto-approve is unchanged
  declare
    v_auto_slug text;
    v_auto_appt uuid;
    v_auto_staff uuid := pg_temp.v689_staff(bAuto);
    v_auto_branch uuid := pg_temp.v689_branch(bAuto);
    v_auto_service uuid;
  begin
    select slug into v_auto_slug from public.businesses where id = bAuto;
    insert into public.services(business_id,name,price_cents,duration_min,active,show_on_booking_page)
    values (bAuto,'V689 Trim',4000,60,true,true) returning id into v_auto_service;
    insert into public.appointments(business_id,client_id,staff_id,service_id,branch_id,
                                    starts_at,ends_at,status,source)
    values (bAuto,cAuto,v_auto_staff,v_auto_service,v_auto_branch,
            timezone('Asia/Singapore',(v_day + time '10:00')::timestamp),
            timezone('Asia/Singapore',(v_day + time '11:00')::timestamp),
            'booked','manual')
    returning id into v_auto_appt;

    perform pg_temp.as_v689_user(uAuto);
    v_err := null;
    begin
      select public.customer_reschedule_appointment_v508(
        v_auto_slug, v_auto_appt,
        timezone('Asia/Singapore',(v_day + time '14:00')::timestamp), null) into v_res;
    exception when others then v_err := sqlerrm; v_res := null;
    end;
    perform pg_temp.as_v689_system();
    select status into v_status from public.appointments where id = v_auto_appt;
    select count(*) into v_count from public.booking_requests
     where business_id = bAuto and customer_client_id = cAuto;
    if v_err is null and v_status = 'cancelled' and v_count = 1
       and (v_res->>'kept_booked') is null then
      insert into v689_out values (3,'F064 an auto-approving business keeps the cancel-and-refile behaviour','PASS');
    else
      insert into v689_out values (3,'F064 an auto-approving business keeps the cancel-and-refile behaviour',
        format('FAIL - err=%s result=%s appt_status=%s booking_requests=%s',
          coalesce(v_err,'<none>'),coalesce(v_res::text,'<null>'),v_status,v_count));
    end if;
  end;

  -- ------------------------------------------------------------------ 4. F066 staff-less approve
  insert into public.booking_tables(business_id,name,pax,quantity,active)
  values (bManual,'V689 Window table',2,4,true) returning id into v_table_type;
  insert into public.appointments(business_id,client_id,service_id,branch_id,table_type_id,
                                  starts_at,ends_at,status,source,party_size)
  values (bManual,cManual,v_service,v_branch,v_table_type,
          timezone('Asia/Singapore',(v_day + time '12:00')::timestamp),
          timezone('Asia/Singapore',(v_day + time '13:00')::timestamp),
          'booked','portal',2)
  returning id into v_table_appt;
  insert into public.change_requests(business_id,appointment_id,kind,proposed_at,status)
  values (bManual,v_table_appt,'reschedule',
          timezone('Asia/Singapore',(v_day + time '16:30')::timestamp),'pending')
  returning id into v_change;

  perform pg_temp.as_v689_user(oManual);
  v_err := null;
  begin
    select public.decide_change(v_change, true) into v_json;
  exception when others then v_err := sqlerrm; v_json := null;
  end;
  perform pg_temp.as_v689_system();
  select starts_at into v_starts from public.appointments where id = v_table_appt;
  if v_err is null and (v_json::jsonb->>'status') = 'approved'
     and v_starts = timezone('Asia/Singapore',(v_day + time '16:30')::timestamp) then
    insert into v689_out values (4,'F066 approving a table-pool reschedule succeeds and moves the appointment','PASS');
  else
    insert into v689_out values (4,'F066 approving a table-pool reschedule succeeds and moves the appointment',
      format('FAIL - err=%s result=%s starts_at=%s',
        coalesce(v_err,'<none>'),coalesce(v_json::text,'<null>'),v_starts));
  end if;

  -- ------------------------------------------------------------------ 5. F066 negative: a real clash
  declare
    v_blocker uuid;
    v_clash_change uuid;
    v_before timestamptz;
  begin
    insert into public.appointments(business_id,client_id,staff_id,service_id,branch_id,
                                    starts_at,ends_at,status,source)
    values (bManual,cManual,v_staff,v_service,v_branch,
            timezone('Asia/Singapore',(v_day + time '14:00')::timestamp),
            timezone('Asia/Singapore',(v_day + time '15:00')::timestamp),
            'booked','manual')
    returning id into v_blocker;
    select starts_at into v_before from public.appointments where id = v_appt;
    insert into public.change_requests(business_id,appointment_id,kind,proposed_at,status)
    values (bManual,v_appt,'reschedule',
            timezone('Asia/Singapore',(v_day + time '14:00')::timestamp),'pending')
    returning id into v_clash_change;

    perform pg_temp.as_v689_user(oManual);
    v_err := null;
    begin
      select public.decide_change(v_clash_change, true) into v_json;
    exception when others then v_err := sqlerrm; v_json := null;
    end;
    perform pg_temp.as_v689_system();
    select starts_at into v_starts from public.appointments where id = v_appt;
    if v_err is null and (v_json::jsonb->>'status') = 'conflict' and v_starts = v_before then
      insert into v689_out values (5,'F066 a STAFFED appointment with a real clash still answers conflict','PASS');
    else
      insert into v689_out values (5,'F066 a STAFFED appointment with a real clash still answers conflict',
        format('FAIL - err=%s result=%s starts_at=%s expected=%s',
          coalesce(v_err,'<none>'),coalesce(v_json::text,'<null>'),v_starts,v_before));
    end if;
  end;

  -- ------------------------------------------------------------------ 6. F067 amend re-runs auto-approve
  declare
    v_auto_request uuid;
    v_auto_service uuid;
    v_auto_appt uuid;
  begin
    select id into v_auto_service from public.services
     where business_id = bAuto order by id limit 1;
    perform set_config('app.v678_autoapprove_deferred','on',true);
    insert into public.booking_requests(
      business_id,customer_client_id,name,phone,service_id,party_size,preferred_at,status,
      branch_id,staff_id,marketing_consent)
    values (bAuto,cAuto,'V689 Customer Auto','81000000',v_auto_service,1,
            timezone('Asia/Singapore',(v_day + time '09:30')::timestamp),'pending',
            pg_temp.v689_branch(bAuto), pg_temp.v689_staff(bAuto), false)
    returning id into v_auto_request;
    perform set_config('app.v678_autoapprove_deferred','',true);

    update public.booking_requests
       set preferred_at = timezone('Asia/Singapore',(v_day + time '16:00')::timestamp)
     where id = v_auto_request;
    select status, appointment_id into v_status, v_auto_appt
      from public.booking_requests where id = v_auto_request;
    if v_status = 'confirmed' and v_auto_appt is not null then
      insert into v689_out values (6,'F067 moving a pending request to a free slot re-runs auto-approve','PASS');
    else
      insert into v689_out values (6,'F067 moving a pending request to a free slot re-runs auto-approve',
        format('FAIL - status=%s appointment=%s',v_status,coalesce(v_auto_appt::text,'<null>')));
    end if;
  end;

  -- ------------------------------------------------------------------ 7/8/9. F065 the slot lister
  -- A second tenant, untouched by the appointments above, so the day is predictable.
  declare
    bList uuid := gen_random_uuid();  oList uuid := gen_random_uuid();
    uList uuid := gen_random_uuid();  cList uuid := gen_random_uuid();
    v_list_slug text;
    v_list_staff uuid;
    v_list_branch uuid;
    v_existing_service uuid;
    v_wanted_service uuid;
    v_has_11 boolean;
    v_has_1130 boolean;
    v_has_1300 boolean;
  begin
    perform pg_temp.v689_tenant(bList,oList,uList,cList,'Lister',false);
    select slug into v_list_slug from public.businesses where id = bList;
    v_list_staff := pg_temp.v689_staff(bList);
    v_list_branch := pg_temp.v689_branch(bList);

    -- The booked service: one hour, then fifteen minutes of cleanup nobody else may have.
    insert into public.services(business_id,name,price_cents,duration_min,active,
                                show_on_booking_page,buffer_before_min,buffer_after_min)
    values (bList,'V689 Booked service',5000,60,true,true,0,15)
    returning id into v_existing_service;
    -- The service the stranger is trying to book: one hour, with fifteen minutes of prep BEFORE
    -- it, so the candidate block starts a quarter of an hour before the slot on offer.
    insert into public.services(business_id,name,price_cents,duration_min,active,
                                show_on_booking_page,buffer_before_min,buffer_after_min)
    values (bList,'V689 Wanted service',9000,60,true,true,15,0)
    returning id into v_wanted_service;

    insert into public.appointments(business_id,client_id,staff_id,service_id,branch_id,
                                    starts_at,ends_at,status,source)
    values (bList,cList,v_list_staff,v_existing_service,v_list_branch,
            timezone('Asia/Singapore',(v_day + time '10:00')::timestamp),
            timezone('Asia/Singapore',(v_day + time '11:00')::timestamp),
            'booked','manual');

    insert into public.branch_breaks(business_id,branch_id,weekday,starts_at,ends_at)
    values (bList,v_list_branch,extract(dow from v_day)::smallint,time '13:00',time '14:00');

    perform pg_temp.as_v689_user(uList);
    select public.internal_public_booking_availability(
      v_list_slug, v_wanted_service, v_list_staff, v_day, 1, v_list_branch) into v_avail;
    perform pg_temp.as_v689_system();

    select day_row->'slots' into v_slots
      from pg_catalog.jsonb_array_elements(coalesce(v_avail->'days','[]'::jsonb)) as d(day_row)
     where day_row->>'date' = to_char(v_day,'YYYY-MM-DD');
    v_slots := coalesce(v_slots,'[]'::jsonb);

    select bool_or((slot->>'at')::timestamptz
                   = timezone('Asia/Singapore',(v_day + time '11:00')::timestamp)),
           bool_or((slot->>'at')::timestamptz
                   = timezone('Asia/Singapore',(v_day + time '11:30')::timestamp)),
           bool_or((slot->>'at')::timestamptz
                   = timezone('Asia/Singapore',(v_day + time '13:00')::timestamp))
      into v_has_11, v_has_1130, v_has_1300
      from pg_catalog.jsonb_array_elements(v_slots) as s(slot);

    if v_avail is not null and coalesce(v_has_11,false) = false then
      insert into v689_out values (7,'F065 the slot inside the previous booking''s cleanup buffer is not offered','PASS');
    else
      insert into v689_out values (7,'F065 the slot inside the previous booking''s cleanup buffer is not offered',
        format('FAIL - availability_null=%s has_1100=%s slots=%s',
          v_avail is null, coalesce(v_has_11,false), v_slots));
    end if;

    if v_avail is not null and coalesce(v_has_1300,false) = false then
      insert into v689_out values (8,'F065 a slot inside a branch break is not offered','PASS');
    else
      insert into v689_out values (8,'F065 a slot inside a branch break is not offered',
        format('FAIL - availability_null=%s has_1300=%s slots=%s',
          v_avail is null, coalesce(v_has_1300,false), v_slots));
    end if;

    if coalesce(v_has_1130,false) then
      insert into v689_out values (9,'F065 positive control: a plainly free slot IS still offered','PASS');
    else
      insert into v689_out values (9,'F065 positive control: a plainly free slot IS still offered',
        format('FAIL - availability=%s slots=%s',coalesce(v_avail::text,'<null>'),v_slots));
    end if;
  end;
end
$v689_test$;

select seq, step, outcome from v689_out order by seq;

/* The report above is printed first so a human sees WHICH assertion failed; this block then
   makes the failure fatal. It matters because scripts/db-tests/run.mjs judges a file purely by
   psql's exit code — a suite that only records FAIL rows is reported green. */
do $v689_gate$
declare
  v_bad integer;
  v_all integer;
begin
  select count(*) filter (where outcome not like 'PASS%'), count(*) into v_bad, v_all from v689_out;
  if v_all <> 9 then
    raise exception 'nestly_v689: % of 9 assertions ran — the suite aborted early', v_all;
  end if;
  if v_bad > 0 then
    raise exception 'nestly_v689: % assertion(s) FAILED — see the report above', v_bad;
  end if;
end
$v689_gate$;

rollback;
