-- V128 rollback-only acceptance. Run after the canonical chain through V128
-- in a disposable database. It proves governed sector selection, exact replay,
-- stale-tab draft resume, effective Loyalty-write authorization, and no publish.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v128_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object(
    'sub',p_uid,'role',p_role
  )::text,true);
end
$$;
grant execute on function pg_temp.as_v128_user(uuid,text)
  to authenticated,anon;

do $v128$
declare
  business_a uuid;
  business_b uuid;
  owner_a uuid;
  owner_b uuid;
  active_before uuid;
  first_result jsonb;
  replay_result jsonb;
  resumed_result jsonb;
  draft_id uuid;
  run_count integer;
  draft_count integer;
  denied boolean;
begin
  reset role;
  select id into business_a from public.businesses
   where name='Pristine chain fixture A';
  select id into business_b from public.businesses
   where name='Pristine chain fixture B';
  select user_id into owner_a from public.staff
   where business_id=business_a and role='owner' and active limit 1;
  select user_id into owner_b from public.staff
   where business_id=business_b and role='owner' and active limit 1;
  if business_a is null or business_b is null
     or owner_a is null or owner_b is null then
    raise exception 'V128 pristine tenant fixtures are incomplete';
  end if;

  update public.businesses set industry='facial' where id=business_a;
  insert into public.services(business_id,name,price_cents,duration_min,active)
  values(business_a,'Signature radiance facial',16800,75,true);
  insert into public.products(business_id,name,sku,retail_price_cents,active)
  values(business_a,'Barrier repair serum','V128-SERUM',8800,true);
  select active_config_version_id into active_before
    from public.businesses where id=business_a;

  perform pg_temp.as_v128_user(owner_a);
  first_result:=public.generate_retention_recommendation(
    business_a,'v128-facial-owner-first'
  )::jsonb;
  draft_id:=(first_result->>'draft_config_version_id')::uuid;
  assert first_result->>'model'='points_tiers',
    'governed facial sector must generate points_tiers';
  assert first_result->>'status'='draft_ready'
     and not (first_result->>'published')::boolean
     and not (first_result->>'resumed_existing')::boolean,
    'first automatic setup must create one unpublished editable draft';
  assert (select status from public.firm_config_versions where id=draft_id)='draft',
    'automatic setup result must identify a draft';
  assert not (select active from public.loyalty_program_versions
               where business_id=business_a and config_version_id=draft_id),
    'automatic setup draft must remain inactive';
  assert (select active_config_version_id from public.businesses where id=business_a)
       is not distinct from active_before,
    'automatic setup must not change the published config';

  replay_result:=public.generate_retention_recommendation(
    business_a,'v128-facial-owner-first'
  )::jsonb;
  assert replay_result=first_result,
    'same idempotency key must return the exact completed result';

  resumed_result:=public.generate_retention_recommendation(
    business_a,'v128-stale-second-tab'
  )::jsonb;
  assert resumed_result->>'status'='existing_draft'
     and (resumed_result->>'resumed_existing')::boolean
     and (resumed_result->>'draft_config_version_id')::uuid=draft_id,
    'stale second tab must resume the existing draft';
  select count(*) into run_count
    from public.retention_recommendation_runs where business_id=business_a;
  select count(*) into draft_count
    from public.firm_config_versions
   where business_id=business_a and status='draft'
     and based_on_version_id=active_before;
  assert run_count=1 and draft_count=1,
    'exact replay and stale second tab must not create duplicate runs or drafts';

  -- The early existing-draft path must not leak its identifier or metrics when
  -- platform policy has made Loyalty read-only for the owner.
  reset role;
  insert into public.platform_module_overrides_v94(
    business_id,branch_scope,module_key,mode,reason,updated_by
  ) values(
    business_a,null,'loyalty','r',
    'V128 rollback-only read-only authorization fixture',owner_b
  );
  perform pg_temp.as_v128_user(owner_a);
  denied:=false;
  begin
    perform public.generate_retention_recommendation(
      business_a,'v128-denied-existing-draft'
    );
  exception when insufficient_privilege then
    denied:=true;
  end;
  assert denied,
    'read-only Loyalty owner reached the existing-draft early return';
  reset role;
  assert (select count(*) from public.retention_recommendation_runs
           where business_id=business_a)=1,
    'denied read-only attempt wrote a recommendation run';
  assert (select count(*) from public.firm_config_versions
           where business_id=business_a and status='draft'
             and based_on_version_id=active_before)=1,
    'denied read-only attempt wrote another draft';

  update public.platform_module_overrides_v94
     set mode='disabled',version=version+1,
       reason='V128 rollback-only disabled authorization fixture'
   where business_id=business_a and branch_scope is null
     and module_key='loyalty';
  perform pg_temp.as_v128_user(owner_a);
  denied:=false;
  begin
    perform public.generate_retention_recommendation(
      business_a,'v128-denied-disabled'
    );
  exception when insufficient_privilege then
    denied:=true;
  end;
  assert denied,'disabled Loyalty owner generated or resumed a draft';

  perform pg_temp.as_v128_user(owner_b);
  denied:=false;
  begin
    perform public.generate_retention_recommendation(
      business_a,'v128-cross-tenant-owner'
    );
  exception when insufficient_privilege then
    denied:=true;
  end;
  assert denied,'cross-tenant owner generated or resumed tenant A draft';

  perform pg_temp.as_v128_user(null,'anon');
  begin
    perform public.generate_retention_recommendation(
      business_a,'v128-anonymous-caller'
    );
    raise exception 'V128 anon unexpectedly executed automatic setup';
  exception when insufficient_privilege then null;
  end;

  reset role;
  assert has_function_privilege(
    'authenticated','public.generate_retention_recommendation(uuid,text)','execute'
  ),'V128 authenticated execute grant is missing';
  assert not has_function_privilege(
    'anon','public.generate_retention_recommendation(uuid,text)','execute'
  ),'V128 anon must not execute automatic setup';

  raise notice 'V128 SIMPLE REWARDS RECOMMENDER SUITE PASS';
end
$v128$;

rollback;
