-- nestly_v790 rollback suite — the catalogue knows the sandbox plan id beside the live one.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production.
--
-- WHAT IT PROVES
--   C1  every active tier that has a base plan id also has a sandbox plan id after the data step.
--   C2  app.razorpay_plan_cadence_v755 resolves a SANDBOX id to the same cadence as the base id,
--       and an unknown id to nothing.
--   C3  the branch applier's unit-amount lookup body matches either column.
--   C4  the function ACL is unchanged (server-only).
begin;

do $v790_main$
declare
  v_tier public.billing_capacity_tier_catalog_v664%rowtype;
  v_cadence text;
  v_months integer;
  v_missing integer;
begin
  reset role;

  select count(*) into v_missing from public.billing_capacity_tier_catalog_v664
   where active and provider_base_price_id is not null and provider_test_price_id is null;
  if v_missing > 0 then
    raise exception 'v790 C1: % active tier(s) have no sandbox plan id', v_missing;
  end if;

  select * into v_tier from public.billing_capacity_tier_catalog_v664
   where active and provider_base_price_id is not null order by cadence, capacity_ceiling limit 1;
  update public.billing_capacity_tier_catalog_v664
     set provider_test_price_id = 'plan_v790sandbox' where id = v_tier.id;
  select cadence, cadence_months into v_cadence, v_months from app.razorpay_plan_cadence_v755('plan_v790sandbox');
  if v_cadence is distinct from v_tier.cadence or v_months is distinct from v_tier.cadence_months::integer then
    raise exception 'v790 C2: sandbox id resolved to %/% not %/%', v_cadence, v_months, v_tier.cadence, v_tier.cadence_months;
  end if;
  select cadence into v_cadence from app.razorpay_plan_cadence_v755('plan_v790nope');
  if v_cadence is not null then raise exception 'v790 C2: an unknown id resolved a cadence'; end if;

  if position('v_plan in (tier.provider_base_price_id, tier.provider_test_price_id)'
       in pg_get_functiondef('app.apply_razorpay_branch_event_v786(text,uuid,uuid,smallint)'::regprocedure)) = 0 then
    raise exception 'v790 C3: the branch applier does not read the sandbox plan id';
  end if;

  if has_function_privilege('authenticated','app.razorpay_plan_cadence_v755(text)','EXECUTE')
     or has_function_privilege('anon','app.razorpay_plan_cadence_v755(text)','EXECUTE') then
    raise exception 'v790 C4: plan cadence ACL is not server-only';
  end if;

  raise notice 'v790 acceptance: C1–C4 passed';
end
$v790_main$;

rollback;
