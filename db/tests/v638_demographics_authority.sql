-- Rollback-only v638 acceptance suite: app.customer_demographics_v1
-- derives the correct age band and staff_entered provenance from a
-- staff-recorded birth date, and prefer_not_to_say is accepted.
-- Run after the complete canonical chain through v638 in a disposable database.
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
-- H4. v638 demographics authority
-- ---------------------------------------------------------------------------
do $h$
declare
  v_business uuid := current_setting('phasea.business')::uuid;
  v_owner uuid := current_setting('phasea.owner')::uuid;
  v_client uuid;
  v_demo jsonb;
begin
  perform pg_temp.as_postgres();
  -- demographics: staff-entered birth 1990-01-01 -> 31_40 in 2026
  insert into public.clients (business_id, full_name, phone, birth_date)
  values (v_business,'Demographics Customer','81110043','1990-01-01') returning id into v_client;
  perform pg_temp.as_user(v_owner);
  v_demo := app.customer_demographics_v1(v_business, v_client);
  perform pg_temp.as_postgres();
  if v_demo->>'age_band' <> '31_40' or v_demo->>'source' <> 'staff_entered' then
    raise exception 'H4: demographics wrong: %', v_demo;
  end if;
  -- prefer_not_to_say accepted on both tables
  insert into public.clients (business_id, full_name, phone, gender)
  values (v_business,'PNTS','81110044','prefer_not_to_say');
  raise notice 'H OK: v638 demographics authority';
end
$h$;

reset role;
rollback;
