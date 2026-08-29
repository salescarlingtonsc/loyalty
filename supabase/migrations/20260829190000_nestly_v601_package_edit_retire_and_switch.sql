-- nestly_v601 — a package can be edited, switched off, and taken off sale for good.
--
-- OWNER (photo 2): "instead of create new version - it should be edit. dont label it as V1 / V2
-- etc. that is incorrect. - when press edit should pop up for user to easily edit and save. once
-- save will be true moving forward. and add a delete button to delete that package. Since there's
-- on/off allow user to on/off as well."
--
-- WHAT STAYS. "Once save will be true moving forward" is exactly what the existing versioning
-- does and why it exists: a customer who bought 5x facial at SGD 400 keeps the price, the session
-- count and the service snapshot they paid for, and the owner's edit applies to sales made after
-- it. So the mechanic is untouched. What changes is the WORDS and the shape of the control — the
-- version number stops being shown, because a version number is Peekaa's bookkeeping and not
-- something an owner should have to reason about.
--
-- WHAT THIS MIGRATION ADDS, and only this:
--
-- 1. packages can be RETIRED. Owner ruling, asked and answered: "Delete removes it from Record
--    sale and from the list, so it can never be sold again. The customers who already bought keep
--    their remaining sessions and can still use them at the counter." Until now delete refused
--    outright the moment a package had been sold, so a firm that stopped offering a package had no
--    way to say so and it sat on the list for ever. A plan with no purchases is still deleted
--    outright — there is nothing to honour.
--
-- 2. the ON/OFF switch can be flipped WITHOUT creating a version. save_package_plan_v102 takes
--    p_active, but calling it on an existing plan supersedes that plan and mints a new one, so
--    wiring the switch to it would breed a version every time somebody paused a package. This is
--    a two-line writer that flips the flag and nothing else.
--
-- WHY NO SELLING PATH IS TOUCHED, checked rather than assumed. public.sell_package_v102 — the one
-- function that grants sessions — already requires `plan.active` and raises
-- package_plan_not_found_or_inactive without it. The live checkout, record_cart_sale/9, prices
-- from checkout_evaluations.server_lines and has no package line kind at all (`package` appears
-- nowhere in its body), so a package cannot be sold through the cart. Retiring sets active=false,
-- so both doors are already shut by the flag; retired_at records the DECISION, which is what makes
-- it survive somebody switching the plan back on.
--
-- Rollback: db/tests/v601_package_edit_retire_and_switch.sql

begin;

alter table public.package_plans
  add column if not exists retired_at timestamptz;

comment on column public.package_plans.retired_at is
  'nestly_v601: when the owner took this package off sale for good. Set only by '
  'business_manage_package_plan_v193(action=delete) on a plan that has already been sold; a plan '
  'nobody bought is deleted outright instead. A retired plan is never active, is hidden from the '
  'packages list, and cannot be switched back on — but every customer holding it keeps the '
  'sessions they paid for and can still use them.';

create index if not exists package_plans_live_idx
  on public.package_plans(business_id) where retired_at is null;

-- ── delete becomes: honour what was sold ───────────────────────────────────
create or replace function public.business_manage_package_plan_v193(
  p_business uuid, p_plan uuid, p_action text, p_name text default null::text)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_plan public.package_plans%rowtype;
  v_sold integer;
  v_name text;
  v_retired boolean := false;
begin
  if p_action not in ('rename','delete') then
    raise exception 'unsupported package action' using errcode='22023';
  end if;
  if not app.can_module_write(p_business,'packages') then
    raise exception 'packages write access is required' using errcode='42501';
  end if;

  select * into v_plan from public.package_plans
   where id=p_plan and business_id=p_business for update;
  if not found then
    raise exception 'package not found in this business' using errcode='42704';
  end if;

  select count(*) into v_sold from public.client_packages
   where business_id=p_business and plan_id=p_plan;

  if p_action='rename' then
    -- Renaming a sold package would rename it on the receipts and wallets of everybody who
    -- bought it, so this half keeps its original refusal exactly.
    if v_sold > 0 then
      raise exception 'this package has been sold to % customer(s); create a new version instead', v_sold
        using errcode='42501';
    end if;
    v_name := btrim(coalesce(p_name,''));
    if length(v_name) < 2 then
      raise exception 'give the package a name' using errcode='22023';
    end if;
    update public.package_plans set name=v_name where id=p_plan and business_id=p_business;
  elsif v_sold > 0 then
    -- nestly_v601 (owner ruling). Sold: taken off sale, never removed. The rows customers hold in
    -- client_packages are untouched, so their remaining sessions still redeem at the counter.
    -- active=false is what actually shuts the selling door (sell_package_v102 refuses an inactive
    -- plan); retired_at records that this was a decision and not a pause.
    if v_plan.retired_at is not null then
      raise exception 'this package is already off sale' using errcode='22023';
    end if;
    update public.package_plans
       set retired_at=now(), active=false
     where id=p_plan and business_id=p_business;
    v_retired := true;
  else
    delete from public.package_plans where id=p_plan and business_id=p_business;
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(),
          'package_plan.'||case when v_retired then 'retire' else p_action end,
          'package_plans', p_plan,
          jsonb_build_object('was_sold', v_sold, 'name', coalesce(v_name, v_plan.name),
                             'retired', v_retired));

  return json_build_object('status','ok',
    'action', case when v_retired then 'retire' else p_action end,
    'plan_id', p_plan, 'sold_to', v_sold);
end
$function$;

revoke all on function public.business_manage_package_plan_v193(uuid, uuid, text, text) from public, anon;
grant execute on function public.business_manage_package_plan_v193(uuid, uuid, text, text) to authenticated, service_role;

-- ── the on/off switch, which must not mint a version ───────────────────────
create or replace function public.business_set_package_active_v601(
  p_business uuid, p_plan uuid, p_active boolean)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_plan public.package_plans%rowtype;
begin
  if p_active is null then
    raise exception 'on or off is required' using errcode='22023';
  end if;
  if not app.can_module_write(p_business,'packages') then
    raise exception 'packages write access is required' using errcode='42501';
  end if;

  select * into v_plan from public.package_plans
   where id=p_plan and business_id=p_business for update;
  if not found then
    raise exception 'package not found in this business' using errcode='42704';
  end if;
  -- Off is a pause and can be undone; retired is a decision and cannot. Without this a retired
  -- package could be switched back on and quietly return to Record sale.
  if v_plan.retired_at is not null and p_active then
    raise exception 'this package was taken off sale and cannot be switched back on' using errcode='22023';
  end if;

  if v_plan.active is distinct from p_active then
    update public.package_plans set active=p_active where id=p_plan and business_id=p_business;
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, auth.uid(), 'package_plan.'||case when p_active then 'switched_on' else 'switched_off' end,
            'package_plans', p_plan, jsonb_build_object('name', v_plan.name, 'active', p_active));
  end if;

  return json_build_object('status','ok','plan_id',p_plan,'active',p_active);
end
$function$;

revoke all on function public.business_set_package_active_v601(uuid, uuid, boolean) from public, anon;
grant execute on function public.business_set_package_active_v601(uuid, uuid, boolean) to authenticated, service_role;

commit;
