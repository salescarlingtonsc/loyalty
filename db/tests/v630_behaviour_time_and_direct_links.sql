-- Rollback-only v630 acceptance suite: record_quick_sale's p_occurred_at
-- capture (payload key added only when supplied, 48h clamp) and the
-- append-only redemption_sale_links_v630 direct-link table.
-- Run after the complete canonical chain through v630 in a disposable database.
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
-- C. v630 till time capture: occurred_at, payload key, clamp
-- ---------------------------------------------------------------------------
do $c$
declare
  v_owner uuid := current_setting('phasea.owner')::uuid;
  v_business uuid := current_setting('phasea.business')::uuid;
  v_res jsonb;
  v_sale uuid;
  v_when timestamptz := now() - interval '1 hour';
  v_payload jsonb;
begin
  perform pg_temp.as_user(v_owner);
  v_res := public.record_quick_sale(
    p_business=>v_business, p_amount_cents=>5000, p_method=>'cash',
    p_note=>'phasea quick', p_idempotency_key=>'phasea-qs-000001',
    p_occurred_at=>v_when)::jsonb;
  v_sale := (v_res #>> '{sale,id}')::uuid;
  if v_sale is null then raise exception 'C1: no sale id returned'; end if;
  if abs(extract(epoch from ((v_res #>> '{sale,occurred_at}')::timestamptz - v_when))) > 1 then
    raise exception 'C2: occurred_at not honoured: %', v_res #>> '{sale,occurred_at}';
  end if;
  perform pg_temp.as_postgres();
  select request_payload into v_payload from public.financial_operations
   where operation_type='quick_sale' and idempotency_key='phasea-qs-000001';
  if not (v_payload ? 'occurred_at') then
    raise exception 'C4: explicit occurred_at should join the payload';
  end if;
  -- default call: payload must NOT gain the key
  perform pg_temp.as_user(v_owner);
  v_res := public.record_quick_sale(
    p_business=>v_business, p_amount_cents=>700, p_method=>'cash',
    p_idempotency_key=>'phasea-qs-000002')::jsonb;
  perform pg_temp.as_postgres();
  select request_payload into v_payload from public.financial_operations
   where operation_type='quick_sale' and idempotency_key='phasea-qs-000002';
  if v_payload ? 'occurred_at' then
    raise exception 'C5: default call must not add occurred_at to the payload';
  end if;
  -- clamp
  perform pg_temp.as_user(v_owner);
  begin
    perform public.record_quick_sale(
      p_business=>v_business, p_amount_cents=>900, p_method=>'cash',
      p_idempotency_key=>'phasea-qs-000003', p_occurred_at=>now() - interval '3 days');
    raise exception 'C6: 3-day-old occurred_at must be rejected';
  exception when sqlstate '22023' then null;
  end;
  perform pg_temp.as_postgres();
  raise notice 'C OK: till time capture';
end
$c$;

-- ---------------------------------------------------------------------------
-- F2. v630 direct links: append-only posture
-- ---------------------------------------------------------------------------
do $f$
declare
  v_business uuid := current_setting('phasea.business')::uuid;
  v_sale uuid;
  v_id uuid;
begin
  perform pg_temp.as_postgres();
  select id into v_sale from public.sales
   where business_id=v_business and kind='quick_sale' limit 1;
  insert into public.redemption_sale_links_v630
    (business_id, client_id, redemption_kind, redemption_id, sale_id)
  values (v_business, null, 'loyalty', gen_random_uuid(), v_sale) returning id into v_id;
  begin
    delete from public.redemption_sale_links_v630 where id=v_id;
    raise exception 'F2: direct-link append-only guard failed';
  exception when sqlstate '42501' then null;
  end;
  raise notice 'F2 OK: direct-link append-only posture';
end
$f$;

reset role;
rollback;
