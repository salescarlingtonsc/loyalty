-- Nestly v329 — Memberships gets a real delete → History state
--
-- Owner ruling ("proceed all at once", 2026-08-15): Memberships is the closest architectural
-- cousin to the loyalty gift lifecycle (v326) — save_membership_plan is already an immediate-write
-- RPC with no draft/publish layer, and membership_plans.active already IS the on/off flag
-- (wired to the existing Enable/Disable button via app/app.js:togglePlan). What's missing is
-- delete-to-History: today a plan can only ever be on or off, never removed from the working list.
--
-- Pre-migration audit (full detail: see the audit report this migration was built from) found
-- membership_plans has NO versioning table at all (unlike loyalty_rewards/loyalty_reward_versions)
-- and is already write-locked at the RLS layer (INSERT/UPDATE/DELETE revoked from every role in
-- v41 — public.save_membership_plan is the only writer). Two true gates read `active` today:
--   - public.enroll_membership: blocks NEW enrollment when the plan is inactive.
--   - app.run_membership_renewals (daily cron): CANCELS an existing member's subscription the
--     next time their period rolls over, if their plan's `active` is false. This is not new
--     behaviour this migration introduces — it is what the EXISTING Disable button already does.
-- Because both gates already key off `active`, and this migration's delete sets `active=false`
-- exactly like Disable already does, NEITHER function needs to change. A real `DELETE FROM
-- membership_plans` is separately blocked by Postgres itself (memberships.plan_id references it
-- ON DELETE RESTRICT), which is the strongest argument for a soft-delete column here too.
--
-- What this migration does:
--   1. Adds membership_plans.deleted_at (nullable timestamptz) — the History marker.
--   2. Patches save_membership_plan's UPDATE path to treat an already-deleted plan as not found,
--      the same "resurrection guard" reasoning as v326: a stale editor tab must not be able to
--      revive a deleted plan by resaving it.
--   3. Adds business_delete_membership_plan_v329(p_business,p_plan) — the new immediate-write
--      delete RPC, mirroring business_delete_reward_v326's shape exactly (sets active=false AND
--      deleted_at=now(), moves the plan to History, no new writers needed elsewhere).

begin;

alter table public.membership_plans add column if not exists deleted_at timestamptz;
comment on column public.membership_plans.deleted_at is
  'v329: set once, by business_delete_membership_plan_v329, when an owner deletes a plan from the '
  'Memberships page. NULL = not deleted (on the Published list, either on or off). Deleting also '
  'sets active=false, which is what already stops new enrollment (public.enroll_membership) and '
  'cancels existing members at their next renewal (app.run_membership_renewals) — the identical '
  'mechanism the pre-existing Disable button already used, so neither function needed a change.';

-- 2. save_membership_plan: guard the UPDATE path against editing/reviving a deleted plan. Full
-- original body reproduced verbatim (see 20260721_frenly_v41_customer_module_hardening.sql:774),
-- with one line changed: the existence check now also requires deleted_at is null, so a stale tab
-- attempting to resave a since-deleted plan gets the same "does not belong to this business" error
-- a wrong-tenant id would — never a silent revival.
create or replace function public.save_membership_plan(
  p_business uuid,
  p_plan uuid,
  p_name text,
  p_price_cents integer,
  p_cadence text,
  p_credit_cents integer,
  p_discount_pct numeric,
  p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_name text := nullif(btrim(p_name), '');
  v_plan public.membership_plans%rowtype;
begin
  if v_actor is null or not app.can_module_write(p_business, 'memberships') then
    raise exception 'active memberships-module write authorization is required'
      using errcode = '42501';
  end if;
  select s.id into v_staff from public.staff s
   where s.business_id=p_business and s.user_id=v_actor and s.active
   order by case when s.role='owner' then 0 else 1 end,s.created_at limit 1 for update;
  if not found then raise exception 'active staff authorization is required' using errcode='42501'; end if;
  if v_name is null or char_length(v_name)>200 or p_price_cents is null or p_price_cents<0
     or p_cadence not in ('monthly','annual') or p_credit_cents is null or p_credit_cents<0
     or p_discount_pct is null or p_discount_pct<0 or p_discount_pct>100 or p_active is null then
    raise exception 'invalid membership plan' using errcode='22023';
  end if;
  if p_plan is null then
    insert into public.membership_plans
      (business_id,name,price_cents,cadence,credit_cents,discount_pct,active)
    values (p_business,v_name,p_price_cents,p_cadence,p_credit_cents,p_discount_pct,p_active)
    returning * into v_plan;
  else
    perform 1 from public.membership_plans p
     where p.id=p_plan and p.business_id=p_business and p.deleted_at is null for update;
    if not found then raise exception 'membership plan does not belong to this business' using errcode='22023'; end if;
    update public.membership_plans set name=v_name,price_cents=p_price_cents,
      cadence=p_cadence,credit_cents=p_credit_cents,discount_pct=p_discount_pct,active=p_active
     where id=p_plan and business_id=p_business returning * into v_plan;
  end if;
  return jsonb_build_object('status','completed','plan_id',v_plan.id,'name',v_plan.name,
    'price_cents',v_plan.price_cents,'cadence',v_plan.cadence,'credit_cents',v_plan.credit_cents,
    'discount_pct',v_plan.discount_pct,'active',v_plan.active);
end
$$;
revoke all privileges on function public.save_membership_plan(uuid,uuid,text,integer,text,integer,numeric,boolean)
  from public, anon, authenticated;
grant execute on function public.save_membership_plan(uuid,uuid,text,integer,text,integer,numeric,boolean)
  to authenticated;

-- 3. The new immediate-write delete RPC. Same authorization shape as save_membership_plan
-- (module-write check + active staff row), so an owner and any staff granted memberships-module
-- write access can delete exactly the plans they could already edit — no new permission surface.
create or replace function public.business_delete_membership_plan_v329(
  p_business uuid,
  p_plan uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_plan public.membership_plans%rowtype;
begin
  if v_actor is null or not app.can_module_write(p_business, 'memberships') then
    raise exception 'active memberships-module write authorization is required'
      using errcode = '42501';
  end if;
  select s.id into v_staff from public.staff s
   where s.business_id=p_business and s.user_id=v_actor and s.active
   order by case when s.role='owner' then 0 else 1 end,s.created_at limit 1 for update;
  if not found then raise exception 'active staff authorization is required' using errcode='42501'; end if;
  update public.membership_plans
     set active=false, deleted_at=now()
   where id=p_plan and business_id=p_business and deleted_at is null
  returning * into v_plan;
  if not found then
    raise exception 'membership plan does not belong to this business, or is already deleted' using errcode='22023';
  end if;
  return jsonb_build_object('status','completed','plan_id',v_plan.id,'name',v_plan.name,
    'active',v_plan.active,'deleted_at',v_plan.deleted_at);
end
$$;
revoke all privileges on function public.business_delete_membership_plan_v329(uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.business_delete_membership_plan_v329(uuid,uuid)
  to authenticated;

commit;
