-- Rollback-only v644 acceptance suite: app.can_contact_v1 composes the consents ledger,
-- synthetic-client denial, phone reachability and the transactional-category refusal into
-- one contactability authority; app.contactable_counts_v1 reads the same law for audience
-- sizing. Run after the complete canonical chain through v644 in a disposable database
-- (or as a rolled-back transaction directly against a prod-shaped instance).
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
-- A. v644 contactability matrix
-- ---------------------------------------------------------------------------
do $a$
declare
  v_business uuid := current_setting('phasebc.business')::uuid;
  v_c1 uuid; v_c2 uuid; v_c3 uuid;
  v_res jsonb;
begin
  perform pg_temp.as_postgres();
  insert into public.clients (business_id, full_name, phone) values (v_business,'Consented','82220001') returning id into v_c1;
  insert into public.clients (business_id, full_name, phone) values (v_business,'No Consent','82220002') returning id into v_c2;
  insert into public.clients (business_id, full_name) values (v_business,'No Phone') returning id into v_c3;
  insert into public.consents (business_id, client_id, channel, action, source, purpose)
  values (v_business, v_c1, 'whatsapp', 'granted', 'phasebc fixture', 'marketing');

  v_res := app.can_contact_v1(v_business, v_c1, 'business_offers', 'whatsapp');
  if not (v_res->>'allowed')::boolean then
    raise exception 'A1: consented client should be contactable: %', v_res;
  end if;
  v_res := app.can_contact_v1(v_business, v_c2, 'business_offers', 'whatsapp');
  if (v_res->>'allowed')::boolean or v_res->>'reason' <> 'consent_missing' then
    raise exception 'A2: unconsented client must be consent_missing: %', v_res;
  end if;
  v_res := app.can_contact_v1(v_business, v_c3, 'business_offers', 'whatsapp');
  if v_res->>'reason' <> 'unreachable_no_phone' then
    raise exception 'A3: phoneless client must be unreachable: %', v_res;
  end if;
  update public.clients set is_synthetic = true where id = v_c2;
  v_res := app.can_contact_v1(v_business, v_c2, 'business_offers', 'whatsapp');
  if v_res->>'reason' <> 'synthetic_client' then
    raise exception 'A4: synthetic must be denied: %', v_res;
  end if;
  update public.clients set is_synthetic = false where id = v_c2;
  begin
    perform app.can_contact_v1(v_business, v_c1, 'booking_updates', 'whatsapp');
    raise exception 'A5: transactional category must be refused';
  exception when sqlstate '22023' then null;
  end;
  v_res := app.contactable_counts_v1(v_business, 'business_offers');
  if (v_res->'allowed_by_channel'->>'whatsapp')::int <> 1 then
    raise exception 'A6: expected exactly 1 whatsapp-contactable, got %', v_res;
  end if;
  raise notice 'A OK: contactability authority';
end
$a$;

reset role;
rollback;
