-- Rollback-only v650 acceptance suite: the Customer Intelligence read layer
-- (get_ci_category_mix_v1, get_ci_category_customers_v1, get_ci_acquisition_v1,
-- get_ci_funnel_v1, get_ci_contactability_v1, get_ci_engagement_v1) returns the expected
-- JSON shapes for an authenticated staff member, and every RPC refuses (42501) without an
-- auth context — app.ci_reports_gate_v650() is the entitlement check every reader shares.
-- Depends on the v648 mapping and a stamped sale_items row (v649) existing for the fixture
-- service, and a consented, contactable client (v644).
-- Run after the complete canonical chain through v650 in a disposable database (or as a
-- rolled-back transaction directly against a prod-shaped instance).
begin;

do $fixture$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_service uuid := gen_random_uuid();
  v_client uuid;
  v_sale uuid := gen_random_uuid();
begin
  reset role;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_owner,
    'authenticated','authenticated',
    'phasebc-owner-'||substr(v_owner::text,1,8)||'@example.test',
    '',now(),now(),now()
  );
  insert into public.businesses(
    id,name,slug,industry,join_enabled,enabled_modules
  ) values (
    v_business,'Phase BC fixture',
    'phasebc-'||substr(v_business::text,1,8),'facial',true,
    array['dashboard','clients','sales','till','appointments','loyalty','reports','services']
  );
  insert into public.staff(business_id,user_id,role,full_name,active)
  values (v_business,v_owner,'owner','Phase BC Owner',true);
  insert into public.branches(business_id,name,is_default,active)
  values (v_business,'Primary',true,true);
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_at=clock_timestamp(),
         decision_reason='phase-bc rollback validation fixture',updated_at=clock_timestamp()
   where business_id=v_business;
  insert into public.subscriptions(business_id,status,trial_ends_at)
  values (v_business,'trialing', now() + interval '7 days');
  insert into public.services(id,business_id,name,price_cents,duration_min,active,category)
  values (v_service,v_business,'Signature Glass Skin Facial',12000,60,true,'Facial');
  insert into public.clients (business_id, full_name, phone)
  values (v_business,'Consented','82220001') returning id into v_client;
  insert into public.consents (business_id, client_id, channel, action, source, purpose)
  values (v_business, v_client, 'whatsapp', 'granted', 'phasebc fixture', 'marketing');
  insert into public.service_canonical_map (business_id, service_id, node_key, version_no, method, mapped_by)
  values (v_business, v_service, 'facial.hydration', 1, 'owner_chosen', v_owner);

  perform set_config('phasebc.owner', v_owner::text, true);
  perform set_config('phasebc.business', v_business::text, true);
  perform set_config('phasebc.service', v_service::text, true);
  perform set_config('phasebc.client', v_client::text, true);
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
-- E. v650 CI read layer shapes + entitlement gate
-- ---------------------------------------------------------------------------
do $e$
declare
  v_owner uuid := current_setting('phasebc.owner')::uuid;
  v_business uuid := current_setting('phasebc.business')::uuid;
  v_service uuid := current_setting('phasebc.service')::uuid;
  v_client uuid := current_setting('phasebc.client')::uuid;
  v_res jsonb;
  v_sale uuid;
begin
  perform pg_temp.as_user(v_owner);
  v_res := public.record_quick_sale(
    p_business=>v_business, p_amount_cents=>12000, p_method=>'cash',
    p_client=>v_client,
    p_note=>'glass skin facial visit', p_idempotency_key=>'phasebc-qs-v650-000001')::jsonb;
  v_sale := (v_res #>> '{sale,id}')::uuid;
  insert into public.sale_items (sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents)
  values (v_sale, v_business, 'service', v_service, 'Signature Glass Skin Facial', 1, 0, 0);

  v_res := public.get_ci_category_mix_v1(v_business, (now() at time zone 'Asia/Singapore')::date - 30, (now() at time zone 'Asia/Singapore')::date);
  if v_res->>'status' is null or v_res->'coverage' is null then
    raise exception 'E3: category mix shape wrong: %', v_res;
  end if;
  v_res := public.get_ci_category_customers_v1(v_business, 'facial', (now() at time zone 'Asia/Singapore')::date - 30, (now() at time zone 'Asia/Singapore')::date, 50);
  if jsonb_array_length(v_res->'customers') < 1 then
    raise exception 'E4: facial customers should include the fixture client: %', v_res;
  end if;
  v_res := public.get_ci_acquisition_v1(v_business, (now() at time zone 'Asia/Singapore')::date - 30, (now() at time zone 'Asia/Singapore')::date);
  if jsonb_array_length(v_res->'sources') < 1 then
    raise exception 'E5: acquisition sources empty: %', v_res;
  end if;
  v_res := public.get_ci_funnel_v1(v_business, (now() at time zone 'Asia/Singapore')::date - 30, (now() at time zone 'Asia/Singapore')::date);
  if v_res->'funnel' is null then raise exception 'E6: funnel shape wrong'; end if;
  v_res := public.get_ci_contactability_v1(v_business);
  if (v_res->'business_offers'->'allowed_by_channel'->>'whatsapp')::int < 1 then
    raise exception 'E7: contactability card should show the consented customer: %', v_res;
  end if;
  v_res := public.get_ci_engagement_v1(v_business, 12);
  if v_res->'months' is null then raise exception 'E8: engagement shape wrong'; end if;

  perform pg_temp.as_postgres();
  -- gate: no auth context -> refused
  begin
    perform public.get_ci_category_mix_v1(v_business, current_date - 30, current_date);
    raise exception 'E9: CI RPC must refuse without auth';
  exception when sqlstate '42501' then null;
  end;

  raise notice 'E OK: CI read layer';
end
$e$;

reset role;
rollback;
