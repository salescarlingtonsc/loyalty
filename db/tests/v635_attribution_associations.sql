-- Rollback-only v635 acceptance suite: the append-only
-- attribution_associations ledger (a fixture-only round-trip proving
-- the shape; no production job writes here yet).
-- Run after the complete canonical chain through v635 in a disposable database.
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
-- F1. v635 attribution associations: append-only posture
-- ---------------------------------------------------------------------------
do $f$
declare
  v_business uuid := current_setting('phasea.business')::uuid;
  v_owner uuid := current_setting('phasea.owner')::uuid;
  v_sale uuid;
  v_id uuid;
  v_res jsonb;
begin
  perform pg_temp.as_user(v_owner);
  v_res := public.record_quick_sale(
    p_business=>v_business, p_amount_cents=>1200, p_method=>'cash',
    p_idempotency_key=>'phasea-qs-v635-001')::jsonb;
  v_sale := (v_res #>> '{sale,id}')::uuid;
  perform pg_temp.as_postgres();
  insert into public.attribution_associations
    (business_id, subject_kind, subject_id, object_kind, object_id,
     strength, method, window_start, window_end, evidence, computed_by)
  values (v_business,'promotion_view',gen_random_uuid(),'sale',v_sale,
          'inferred_weak','post_view_purchase_7d', now()-interval '7 days', now(),
          '{"fixture":true}','phasea-validation')
  returning id into v_id;
  begin
    update public.attribution_associations set strength='inferred_strong' where id=v_id;
    raise exception 'F1: association append-only guard failed';
  exception when sqlstate '42501' then null;
  end;
  raise notice 'F1 OK: attribution association append-only posture';
end
$f$;

reset role;
rollback;
