-- v432 acceptance — one availability core behind the staff redeem-now list and both customer
-- list readers, with the grant posture the product needs. Read-only against production;
-- BEGIN/ROLLBACK for the house atomic-boundary convention.
begin;

do $$
declare
  v_def text;
  v_reader text;
  v_acl aclitem[];
begin
  -- 01  the core exists and is not callable by clients directly (definer-internal, app schema)
  select p.proacl into v_acl
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'reward_availability_v432';
  if not found then
    raise exception '01 FAIL app.reward_availability_v432 does not exist';
  end if;
  if exists (
    select 1 from unnest(coalesce(v_acl, '{}'::aclitem[])) acl
     where acl::text like 'authenticated=%' or acl::text like 'anon=%' or acl::text like '=%'
  ) then
    raise exception '01 FAIL the availability core is directly callable by client roles: %', v_acl;
  end if;
  raise notice '01 PASS the availability core exists and is definer-internal';

  -- 02  all three list readers consume the core — no reader keeps its own copy
  foreach v_reader in array array[
    'staff_get_customer_actionable_loyalty_v145',
    'customer_get_reward_catalog',
    'customer_get_business_actions_v89'
  ] loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_reader;
    if position('reward_availability_v432' in coalesce(v_def, '')) = 0 then
      raise exception '02 FAIL %.% does not read the shared availability core', 'public', v_reader;
    end if;
  end loop;
  raise notice '02 PASS staff redeem-now and both customer readers share the one core';

  -- 03  the staff list can no longer offer a reward whose programme spine is off: the core
  --     carries the spine gate redemption enforces
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'reward_availability_v432';
  if position('business_programmes' in coalesce(v_def, '')) = 0
     or position('not_on_card' in coalesce(v_def, '')) = 0
     or position('claimed_this_cycle' in coalesce(v_def, '')) = 0 then
    raise exception '03 FAIL the core is missing the spine gate or the stamp-card states';
  end if;
  raise notice '03 PASS the core carries the spine gate and the stamp-card states';
end $$;

rollback;
select 'v432 ALL CHECKS PASSED' as result;
