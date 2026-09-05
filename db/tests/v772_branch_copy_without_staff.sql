-- EXECUTED acceptance fixture for nestly_v772
-- (db/migrations/20261004_nestly_v772_branch_copy_without_staff.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v772 --migrated-only
--
-- Owner ruling 2026-09-05: copying a branch's settings must NOT copy who works there.
--
-- ASSERTIONS (as the real owner, rolled back):
--   F1  hours, breaks and services offered are copied from the source branch.
--   F2  staff_branches rows are NOT copied; the response says staff_assignments 0.
--   F3  a second copy is idempotent (no duplicate hours/services rows).
begin;

do $v772$
declare
  v_business uuid; v_owner uuid := gen_random_uuid(); v_now timestamptz := date_trunc('second', now());
  v_from uuid; v_to uuid; v_staff uuid; v_service uuid; v_result jsonb;
  v_hours integer; v_services integer; v_staff_rows integer; v_breaks integer;
begin
  insert into public.businesses(name,slug,industry,enabled_modules)
  values ('V772 copy tenant','v772-copy-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard'])
  returning id into v_business;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
    'zz-v772-'||substr(v_owner::text,1,8)||'@example.test','',v_now,v_now,v_now);
  insert into public.staff(business_id,user_id,role,active,access_state)
  values (v_business,v_owner,'owner',true,'approved') returning id into v_staff;
  /* app.is_salon_owner needs an open workspace: approved AND a current subscription. */
  insert into public.subscriptions(business_id,status,currency,base_price_cents,included_seats,
    per_seat_price_cents,billing_provider,billing_cadence,payment_status,provider_subscription_id,
    current_period_end)
  values (v_business,'active','SGD',118800,1,0,'razorpay','annual','paid','sub_v772fixture',
    v_now + interval '300 days')
  on conflict (business_id) do update set status='active', payment_status='paid',
    current_period_end=v_now + interval '300 days';
  insert into public.business_workspace_controls_v94(business_id,approval_status,decided_at,decision_reason)
  values (v_business,'approved',v_now,'v772 fixture')
  on conflict (business_id) do update set approval_status='approved', decided_at=v_now, decision_reason='v772 fixture';

  select id into v_from from public.branches where business_id=v_business order by created_at limit 1;
  if v_from is null then
    insert into public.branches(business_id,name,is_default,active) values (v_business,'V772 main',true,true) returning id into v_from;
  end if;
  perform set_config('app.branch_authority_v621','on',true);
  perform set_config('app.v79_system_transition','on',true);
  insert into public.branches(business_id,name,is_default,active) values (v_business,'V772 new',false,false) returning id into v_to;
  perform set_config('app.branch_authority_v621','off',true);
  perform set_config('app.v79_system_transition','off',true);

  insert into public.branch_hours(business_id,branch_id,weekday,opens_at,closes_at)
  values (v_business,v_from,1,'09:00','18:00'),(v_business,v_from,2,'09:00','18:00');
  insert into public.branch_breaks(business_id,branch_id,weekday,starts_at,ends_at)
  values (v_business,v_from,1,'12:00','13:00');
  insert into public.services(business_id,name,price_cents,duration_min,active)
  values (v_business,'V772 cut',3000,30,true) returning id into v_service;
  insert into public.service_branches(business_id,service_id,branch_id) values (v_business,v_service,v_from)
  on conflict do nothing;
  insert into public.staff_branches(business_id,staff_id,branch_id) values (v_business,v_staff,v_from)
  on conflict do nothing;

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_owner,'role','authenticated','aud','authenticated')::text, true);

  v_result := public.business_copy_branch_settings_v202(v_business, v_from, v_to);

  -- F1
  select count(*) into v_hours from public.branch_hours where branch_id=v_to;
  select count(*) into v_breaks from public.branch_breaks where branch_id=v_to;
  select count(*) into v_services from public.service_branches where branch_id=v_to;
  if v_hours <> 2 or v_breaks <> 1 or v_services <> 1 then
    raise exception 'F1: copied hours=% breaks=% services=% (expected 2/1/1)', v_hours, v_breaks, v_services;
  end if;
  -- F2
  select count(*) into v_staff_rows from public.staff_branches where branch_id=v_to;
  if v_staff_rows <> 0 then
    raise exception 'F2: % staff assignment(s) were copied to the new branch', v_staff_rows;
  end if;
  if coalesce((v_result->>'staff_assignments')::integer, -1) <> 0 then
    raise exception 'F2: the response reports staff_assignments=%', v_result->>'staff_assignments';
  end if;
  -- F3
  v_result := public.business_copy_branch_settings_v202(v_business, v_from, v_to);
  select count(*) into v_hours from public.branch_hours where branch_id=v_to;
  select count(*) into v_services from public.service_branches where branch_id=v_to;
  if v_hours <> 2 or v_services <> 1 then
    raise exception 'F3: a second copy duplicated rows (hours=% services=%)', v_hours, v_services;
  end if;

  raise notice 'v772 corpus: F1-F3 passed';
end
$v772$;

rollback;
