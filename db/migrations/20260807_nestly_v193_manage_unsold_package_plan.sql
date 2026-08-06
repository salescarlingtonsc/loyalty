-- V193 — an unsold package version can be renamed or deleted.
-- APPLIED TO PRODUCTION 2026-08-07 via MCP apply_migration (nestly_v193_manage_unsold_package_plan).
--
-- A package version is frozen so a customer who bought it keeps the price, sessions and service
-- they paid for. That protection is right — but it only means anything once somebody HAS bought
-- it. Both of this firm's versions had ZERO purchases, so the freeze guarded nothing while making
-- a typo ("10 Sessions Acne Pacage") permanent.
--
-- package_plans carries only SELECT policies; every write goes through a SECURITY DEFINER RPC, so
-- a browser .update()/.delete() would have silently affected zero rows rather than erroring.
--
-- THE GUARD IS THE POINT: rename and delete are refused the moment a single client_packages row
-- references the plan, checked on plan_id — the real foreign key — not a name/version snapshot,
-- so two versions sharing a name cannot fool it. Verified in a rolled-back transaction: 0
-- purchases before, 1 after a synthetic sale, guard flips to refuse, and the FK refuses the raw
-- delete independently (defence in depth).
begin;

create or replace function public.business_manage_package_plan_v193(
  p_business uuid, p_plan uuid, p_action text, p_name text default null
)
returns json
language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_plan public.package_plans%rowtype; v_sold integer; v_name text;
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
  if v_sold > 0 then
    raise exception 'this package has been sold to % customer(s); create a new version instead', v_sold
      using errcode='42501';
  end if;
  if p_action='rename' then
    v_name := btrim(coalesce(p_name,''));
    if length(v_name) < 2 then
      raise exception 'give the package a name' using errcode='22023';
    end if;
    update public.package_plans set name=v_name where id=p_plan and business_id=p_business;
  else
    delete from public.package_plans where id=p_plan and business_id=p_business;
  end if;
  insert into public.audit_log(business_id, actor, action, entity, entity_id, meta)
  values (p_business, auth.uid(), 'package_plan.'||p_action, 'package_plans', p_plan,
          jsonb_build_object('was_sold', v_sold, 'name', coalesce(v_name, v_plan.name)));
  return json_build_object('status','ok','action',p_action,'plan_id',p_plan);
end $$;

revoke all on function public.business_manage_package_plan_v193(uuid,uuid,text,text) from public, anon;
grant execute on function public.business_manage_package_plan_v193(uuid,uuid,text,text) to authenticated;

commit;
