-- Rollback-only v36 safe draft reward editor suite. Run after v24a-v36 in a
-- rehearsal database. It is intentionally behavioral; static checks are not
-- enough to prove eligibility isolation.
begin;
\ir fixtures/pristine_chain_fixture.psql

do $v36_test$
declare
  v_business uuid;
  v_owner uuid;
  v_staff uuid;
  v_branch uuid;
  v_service uuid;
  v_product uuid;
  v_draft uuid;
  v_reward uuid;
  v_reward_version uuid;
  v_payload jsonb;
  v_reward_payload jsonb;
  v_hash text;
  v_after_hash text;
begin
  select business_id, user_id into v_business, v_owner
    from public.staff
   where role = 'owner' and active and user_id is not null
   order by created_at
   limit 1;
  if v_business is null then
    raise exception 'v36 suite requires an active owner';
  end if;

  select user_id into v_staff
    from public.staff
   where business_id = v_business
     and role <> 'owner'
     and active
     and user_id is not null
   order by created_at
   limit 1;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  select id into v_branch from public.branches
   where business_id = v_business and active
   order by is_default desc, created_at
   limit 1;
  if v_branch is null then
    insert into public.branches(business_id, name, is_default, active)
    values (v_business, 'v36 branch', true, true)
    returning id into v_branch;
  end if;

  insert into public.services(business_id, name, price_cents, duration_min, active)
  values (v_business, 'v36 eligible service', 1000, 30, true)
  returning id into v_service;

  insert into public.products(business_id, name, retail_price_cents, active)
  values (v_business, 'v36 eligible product', 500, true)
  returning id into v_product;

  v_payload := public.create_loyalty_config_draft(v_business, null, 'v36_test')::jsonb;
  v_draft := (v_payload->>'version_id')::uuid;

  v_payload := public.save_loyalty_config_draft(v_draft, jsonb_build_object(
    'reward', jsonb_build_object(
      'business_id', v_business,
      'name', 'v36 internal',
      'customer_name', 'v36 restricted reward',
      'fulfillment_kind', 'credit',
      'cost_points', 10,
      'credit_cents', 100,
      'estimated_cost_cents', 50,
      'active', true
    ),
    'reward_branch_ids', jsonb_build_array(v_branch),
    'reward_service_ids', jsonb_build_array(v_service),
    'reward_product_ids', jsonb_build_array(v_product)
  ))::jsonb;
  v_hash := v_payload->>'snapshot_hash';

  select reward_id, id into v_reward, v_reward_version
    from public.loyalty_reward_versions
   where config_version_id = v_draft
     and business_id = v_business
     and customer_name = 'v36 restricted reward';
  if v_reward_version is null then
    raise exception 'v36 setup failed to create a reward version';
  end if;

  v_payload := public.get_loyalty_reward_draft(v_draft);
  if v_payload->>'snapshot_hash' is distinct from v_hash then
    raise exception 'draft payload did not return current snapshot hash';
  end if;
  select reward into v_reward_payload
    from jsonb_array_elements(v_payload->'rewards') reward
   where reward->>'reward_id' = v_reward::text;
  if v_reward_payload is null then
    raise exception 'draft payload omitted the saved reward';
  end if;
  if v_reward_payload->>'id' is distinct from v_reward::text
     or v_reward_payload->>'reward_id' is distinct from v_reward::text
     or v_reward_payload->>'reward_version_id' is distinct from v_reward_version::text then
    raise exception 'draft payload did not expose stable and version reward IDs distinctly';
  end if;
  if v_reward_payload->'eligibility'->'branches' <> jsonb_build_array(v_branch)
     or v_reward_payload->'eligibility'->'services' <> jsonb_build_array(v_service)
     or v_reward_payload->'eligibility'->'products' <> jsonb_build_array(v_product) then
    raise exception 'draft payload did not preserve exact eligibility tree: %',
      v_reward_payload->'eligibility';
  end if;

  if v_staff is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);
    begin
      perform public.get_loyalty_reward_draft(v_draft);
      raise exception 'staff unexpectedly read owner draft payload';
    exception when insufficient_privilege then null;
    end;
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  perform public.save_loyalty_config_draft(v_draft, jsonb_build_object(
    'reward', jsonb_build_object(
      'id', v_reward,
      'business_id', v_business,
      'name', 'v36 internal changed',
      'customer_name', 'v36 restricted reward',
      'fulfillment_kind', 'credit',
      'cost_points', 10,
      'credit_cents', 100,
      'estimated_cost_cents', 50,
      'active', true
    ),
    'reward_branch_ids', jsonb_build_array(v_branch),
    'reward_service_ids', jsonb_build_array(v_service),
    'reward_product_ids', jsonb_build_array(v_product)
  ), v_hash);

  select snapshot_hash into v_after_hash
    from public.firm_config_versions
   where id = v_draft;

  begin
    perform public.save_loyalty_config_draft(v_draft, jsonb_build_object(
      'reward', jsonb_build_object(
        'id', v_reward,
        'business_id', v_business,
        'name', 'v36 stale overwrite',
        'customer_name', 'v36 stale unrestricted',
        'fulfillment_kind', 'credit',
        'cost_points', 10,
        'credit_cents', 100,
        'estimated_cost_cents', 50,
        'active', true
      ),
      'reward_branch_ids', '[]'::jsonb,
      'reward_service_ids', '[]'::jsonb,
      'reward_product_ids', '[]'::jsonb
    ), v_hash);
    raise exception 'stale hash unexpectedly overwrote draft eligibility';
  exception when serialization_failure then null;
  end;

  if not exists (
    select 1 from public.firm_config_versions
     where id = v_draft and snapshot_hash = v_after_hash
  ) then
    raise exception 'stale save changed the draft snapshot hash';
  end if;
  if not exists (
    select 1 from public.loyalty_reward_branches
     where reward_version_id = v_reward_version
       and reward_id = v_reward
       and business_id = v_business
       and branch_id = v_branch
  ) or not exists (
    select 1 from public.loyalty_reward_services
     where reward_version_id = v_reward_version
       and reward_id = v_reward
       and business_id = v_business
       and service_id = v_service
  ) or not exists (
    select 1 from public.loyalty_reward_products
     where reward_version_id = v_reward_version
       and reward_id = v_reward
       and business_id = v_business
       and product_id = v_product
  ) then
    raise exception 'stale save removed eligibility rows';
  end if;

  if to_regprocedure('public.save_loyalty_config_draft(uuid,jsonb)') is null then
    raise exception 'internal legacy draft save wrapper needed by recommendation generator is missing';
  end if;
  if has_function_privilege('authenticated', 'public.save_loyalty_config_draft(uuid,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.save_loyalty_config_draft(uuid,jsonb)', 'execute') then
    raise exception 'legacy two-argument draft save RPC is browser-executable';
  end if;
  if not has_function_privilege('authenticated', 'public.get_loyalty_reward_draft(uuid)', 'execute')
     or has_function_privilege('anon', 'public.get_loyalty_reward_draft(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.save_loyalty_config_draft(uuid,jsonb,text)', 'execute')
     or has_function_privilege('anon', 'public.save_loyalty_config_draft(uuid,jsonb,text)', 'execute') then
    raise exception 'v36 RPC ACL contract is incorrect';
  end if;

  raise notice 'v36 safe draft reward editor suite: ALL PASS';
end $v36_test$;

rollback;
