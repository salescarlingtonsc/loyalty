-- Rollback-only v632 acceptance suite: booked_from_appointment_id, the
-- write-once rebooking guard, and link_rebooked_appointment_v1.
-- Run after the complete canonical chain through v632 in a disposable database.
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
-- D5/D6. v632 rebooking link
-- ---------------------------------------------------------------------------
do $d$
declare
  v_owner uuid := current_setting('phasea.owner')::uuid;
  v_business uuid := current_setting('phasea.business')::uuid;
  v_service uuid := current_setting('phasea.service')::uuid;
  v_client uuid;
  v_appt1 uuid := gen_random_uuid();
  v_appt2 uuid := gen_random_uuid();
begin
  perform pg_temp.as_postgres();
  insert into public.clients (business_id, full_name, phone, birth_date)
  values (v_business,'Rebook Customer','81110013','1990-01-01') returning id into v_client;
  insert into public.appointments (id,business_id,client_id,service_id,starts_at,ends_at,status,total_cents)
  values (v_appt1,v_business,v_client,v_service, now() - interval '2 hours', now() - interval '1 hour','booked',8000);
  insert into public.appointments (id,business_id,client_id,service_id,starts_at,ends_at,status,total_cents)
  values (v_appt2,v_business,v_client,v_service, now() + interval '7 days', now() + interval '7 days 1 hour','booked',8000);

  -- rebooking link: appt2 was born from appt1's completion screen
  perform pg_temp.as_user(v_owner);
  perform public.link_rebooked_appointment_v1(v_business, v_appt2, v_appt1);
  perform pg_temp.as_postgres();
  if (select booked_from_appointment_id from public.appointments where id=v_appt2) <> v_appt1 then
    raise exception 'D5: rebooking link not set';
  end if;
  begin
    update public.appointments set booked_from_appointment_id=v_appt2 where id=v_appt2;
    raise exception 'D6: rebooking write-once guard failed';
  exception when sqlstate '42501' then null;
  end;
  raise notice 'D OK: v632 rebooking link';
end
$d$;

reset role;
rollback;
