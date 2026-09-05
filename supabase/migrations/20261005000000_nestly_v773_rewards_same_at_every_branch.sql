-- nestly_v773 — rewards are the same at every branch (owner ruling 2026-09-05).
--
-- OWNER: "remove per-branch override, rewards same for all branches — if the company edits the
-- rewards from any branch, all branches will reflect."
--
-- Since v37 a branch could override the firm's earn rate, spend-per-stamp, expiry and on/off
-- switch (public.loyalty_branch_overrides). That is now retired, fail-closed:
--   1. app.resolve_loyalty_branch_config answers with the firm configuration for every branch
--      and never joins the override table. Every earn, stamp and expiry reader goes through it.
--   2. public.save_loyalty_branch_override_draft refuses with a named reason. The remove RPC keeps
--      working so an old draft can be cleaned; the table is left in place (history, and v433's
--      snapshot hash reads it) but nothing feeds it any more:
--   3. app.clone_loyalty_branch_overrides_on_draft no longer clones rows into a new draft, and
--   4. business_copy_branch_settings_v202 no longer copies overrides to a new branch.
--
-- Effect on live data: one tenant (Hougang ABC) had a published override of 10 points per $1 on
-- its Hougang ABC branch against a firm rate of 1. From this migration that branch earns the
-- firm rate, as ruled. Told to the owner in the same message that shipped this.
--
-- Grants restated verbatim from the live proacl.

begin;

-- 1 · the resolver: firm configuration for every branch. Postgres refuses a CREATE OR REPLACE
--     whose RETURNS TABLE differs textually from the live one, so it is dropped and recreated in
--     this transaction; PL/pgSQL callers resolve the name at run time.
drop function if exists app.resolve_loyalty_branch_config(uuid,uuid,uuid);
create function app.resolve_loyalty_branch_config(
  p_business_id uuid, p_branch_id uuid, p_config_version_id uuid default null
) returns table(
  business_id uuid, config_version_id uuid, branch_id uuid, source text, kind text,
  loyalty_model text, active boolean, earn_points_per_dollar numeric, redeem_points integer,
  reward_credit_cents integer, stamp_target integer, stamp_per_cents integer, tier_basis text,
  expiry_mode text, expiry_days integer
)
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $function$
declare
  v_config_version_id uuid;
begin
  if p_branch_id is not null
     and not exists (
       select 1 from public.branches b
        where b.id = p_branch_id and b.business_id = p_business_id
     ) then
    raise exception 'branch does not belong to business' using errcode = 'foreign_key_violation';
  end if;

  v_config_version_id := coalesce(
    p_config_version_id,
    app.active_config_version(p_business_id)
  );

  -- A newly onboarded firm may still have only its inactive draft. In that
  -- case there is no earn configuration and recording a sale remains valid.
  if v_config_version_id is null then
    return;
  end if;

  if not exists (
    select 1 from public.firm_config_versions v
     where v.id = v_config_version_id and v.business_id = p_business_id
  ) then
    raise exception 'configuration version does not belong to business'
      using errcode = 'foreign_key_violation';
  end if;

  /* nestly_v773: no override join. The branch is echoed back so callers keep their shape; the
     source is always the firm's. `active` stays the SPINE's answer (nestly_v564). */
  return query
  select d.business_id,
         d.config_version_id,
         p_branch_id,
         'firm_default'::text,
         d.kind,
         d.loyalty_model,
         (select coalesce(bool_or(spine.active),false)
            from public.business_programmes spine
           where spine.business_id = d.business_id
             and spine.kind in ('points','stamps','tiers')),
         d.earn_points_per_dollar,
         d.redeem_points,
         d.reward_credit_cents,
         d.stamp_target,
         d.stamp_per_cents,
         d.tier_basis,
         d.expiry_mode,
         d.expiry_days
    from public.loyalty_program_versions d
   where d.business_id = p_business_id
     and d.config_version_id = v_config_version_id;
end
$function$;

comment on function app.resolve_loyalty_branch_config(uuid,uuid,uuid) is
  'nestly_v773: the firm loyalty configuration, for any branch. Per-branch overrides are retired; '
  'rewards are the same at every branch (owner ruling 2026-09-05).';

revoke all on function app.resolve_loyalty_branch_config(uuid,uuid,uuid) from public, anon;

-- 2 · the writer refuses, in the owner's words.
create or replace function public.save_loyalty_branch_override_draft(
  p_config_version uuid, p_branch uuid, p_override jsonb, p_expected_snapshot_hash text default null
) returns json
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $function$
begin
  raise exception 'Rewards are the same at every branch. Edit the programme once and every branch follows it (per-branch settings were retired in nestly_v773).'
    using errcode = '22023';
end
$function$;

comment on function public.save_loyalty_branch_override_draft(uuid,uuid,jsonb,text) is
  'nestly_v773: retired — always refuses. Rewards are the same at every branch.';

revoke all on function public.save_loyalty_branch_override_draft(uuid,uuid,jsonb,text) from public, anon;
grant execute on function public.save_loyalty_branch_override_draft(uuid,uuid,jsonb,text) to authenticated, service_role;

-- 3 · a new draft is born without overrides.
create or replace function app.clone_loyalty_branch_overrides_on_draft()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $function$
begin
  /* nestly_v773: nothing to clone — overrides are retired. The trigger stays attached so the
     draft path keeps its shape; it simply no longer writes. */
  return new;
end
$function$;

comment on function app.clone_loyalty_branch_overrides_on_draft() is
  'nestly_v773: no-op — per-branch loyalty overrides are retired.';

-- 4 · copying a branch copies its hours, breaks and services — never loyalty overrides.
create or replace function public.business_copy_branch_settings_v202(
  p_business uuid, p_from uuid, p_to uuid
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $function$
declare
  v_hours integer := 0; v_breaks integer := 0; v_services integer := 0;
begin
  if auth.uid() is null or not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'owner access is required' using errcode='42501';
  end if;
  if p_from is null or p_to is null or p_from = p_to then
    raise exception 'a source and a different destination branch are required' using errcode='22023';
  end if;
  if not exists (select 1 from public.branches where id=p_from and business_id=p_business)
     or not exists (select 1 from public.branches where id=p_to and business_id=p_business) then
    raise exception 'both branches must belong to this business' using errcode='42501';
  end if;

  insert into public.branch_hours(business_id,branch_id,weekday,opens_at,closes_at)
  select p_business,p_to,h.weekday,h.opens_at,h.closes_at
    from public.branch_hours h
   where h.business_id=p_business and h.branch_id=p_from
     and not exists (
       select 1 from public.branch_hours e
        where e.business_id=p_business and e.branch_id=p_to and e.weekday=h.weekday
          and e.opens_at=h.opens_at and e.closes_at=h.closes_at);
  get diagnostics v_hours = row_count;

  insert into public.branch_breaks(business_id,branch_id,weekday,starts_at,ends_at)
  select p_business,p_to,b.weekday,b.starts_at,b.ends_at
    from public.branch_breaks b
   where b.business_id=p_business and b.branch_id=p_from
     and not exists (
       select 1 from public.branch_breaks e
        where e.business_id=p_business and e.branch_id=p_to and e.weekday=b.weekday
          and e.starts_at=b.starts_at and e.ends_at=b.ends_at);
  get diagnostics v_breaks = row_count;

  insert into public.service_branches(business_id,service_id,branch_id)
  select p_business,s.service_id,p_to from public.service_branches s
   where s.business_id=p_business and s.branch_id=p_from
  on conflict do nothing;
  get diagnostics v_services = row_count;

  /* v772: staff are assigned per branch on Staff Members, never copied.
     v773: rewards are the same at every branch, nothing to copy. */
  return jsonb_build_object(
    'status','ok','from_branch',p_from,'to_branch',p_to,
    'opening_hours',v_hours,'breaks',v_breaks,'services',v_services,
    'staff_assignments',0,'loyalty_overrides',0,
    'products_note','products, prices and rewards are firm-wide and need no copy');
end
$function$;

comment on function public.business_copy_branch_settings_v202(uuid,uuid,uuid) is
  'nestly_v773: copies opening hours, breaks and services offered from one branch to another. '
  'Staff (v772) and loyalty overrides (v773) are never copied.';

revoke all on function public.business_copy_branch_settings_v202(uuid,uuid,uuid) from public, anon;
grant execute on function public.business_copy_branch_settings_v202(uuid,uuid,uuid) to authenticated, service_role;

commit;
