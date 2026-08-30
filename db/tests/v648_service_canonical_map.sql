-- Rollback-only v648 acceptance suite: a service resolves to exactly one canonical node.
-- app.suggest_canonical_node_v1 offers a keyword-derived suggestion; the owner confirms it
-- via public.set_service_canonical_node_v1, which records the mapping, appends to
-- service_canonical_map_history, and rejects an unknown node key. The board read
-- (get_service_mapping_board_v1) must not itself write anything.
-- Run after the complete canonical chain through v648 in a disposable database (or as a
-- rolled-back transaction directly against a prod-shaped instance).
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

  perform set_config('phasebc.owner', v_owner::text, true);
  perform set_config('phasebc.business', v_business::text, true);
  perform set_config('phasebc.service', v_service::text, true);
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
-- D. v648 service -> canonical-node mapping flow
-- ---------------------------------------------------------------------------
do $d$
declare
  v_owner uuid := current_setting('phasebc.owner')::uuid;
  v_business uuid := current_setting('phasebc.business')::uuid;
  v_service uuid := current_setting('phasebc.service')::uuid;
  v_sugg text;
  v_board jsonb;
begin
  perform pg_temp.as_postgres();
  v_sugg := app.suggest_canonical_node_v1(v_business, v_service);
  if v_sugg <> 'facial.hydration' then
    raise exception 'D2: expected facial.hydration suggestion for Glass Skin, got %', coalesce(v_sugg,'null');
  end if;

  perform pg_temp.as_user(v_owner);
  perform public.set_service_canonical_node_v1(v_business, v_service, 'facial.hydration');
  v_board := public.get_service_mapping_board_v1(v_business);

  perform pg_temp.as_postgres();
  if (select node_key from public.service_canonical_map
       where business_id=v_business and service_id=v_service) <> 'facial.hydration' then
    raise exception 'D3: mapping not recorded';
  end if;
  if (select count(*) from public.service_canonical_map_history
       where business_id=v_business and service_id=v_service and change_kind='set') <> 1 then
    raise exception 'D4: mapping history missing';
  end if;
  if v_board is null then
    raise exception 'D4a: mapping board read returned nothing';
  end if;

  perform pg_temp.as_user(v_owner);
  begin
    perform public.set_service_canonical_node_v1(v_business, v_service, 'not_a_node');
    raise exception 'D5: unknown node must be rejected';
  exception when sqlstate '22023' then null;
  end;

  perform pg_temp.as_postgres();
  raise notice 'D OK: taxonomy + mapping';
end
$d$;

reset role;
rollback;
