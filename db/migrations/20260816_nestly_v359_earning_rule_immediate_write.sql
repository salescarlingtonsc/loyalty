-- V359: business_set_earning_rule_v359 — the last owner-editable loyalty field that still had no
--       immediate-write path, and therefore the last thing keeping the publish wizard alive.
--
-- OWNER RULING 2026-08-16: "because adding or editing the fields will be auto publish (with a save
-- button that already exist) - dont need the wizard go live steps."
--
-- WHY THIS HAD TO COME FIRST. Every other reward surface became immediate-write over the last two
-- days (v326 gifts, v331/v345 tiers, v347 tier_basis, v350 stamp levels, v353/v354 model+spine),
-- but the EARNING RULE never did: earn_points_per_dollar / stamp_per_cents / expiry_mode /
-- expiry_days reach public.loyalty_programs only inside publish_loyalty_config's draft-apply
-- block. "Edit settings" on both the Points System and Stamp Card pages routes into the wizard for
-- exactly that reason. Deleting the wizard's Go-live step before this RPC existed would have made
-- Edit settings silently never save — the identical failure shape as V352 (spine flipped, page
-- read a different column) and V353 (model written, spine not). Same class, third time; the fix is
-- to give the field a direct writer BEFORE removing the indirect one.
--
-- SHAPE. Mirrors app.c45_owner_loyalty_write gating and the upsert shape v347/v353 already use,
-- including the loyalty_programs_configuration_status_check workaround (a row inserted at the
-- table's own 'draft' default must carry active=false). Only ever writes the four earning columns
-- — it deliberately does NOT touch loyalty_model/kind (V354 made the SPINE own those; a second
-- writer here would re-open the exact drift V354 closed) nor tier_basis (v347 owns it).
--
-- VALIDATION mirrors the wizard's own client-side rules so the two doors cannot disagree:
-- a points rate must be > 0; a stamp rate is a positive whole number of cents; expiry_days is
-- required by and only meaningful for the day-based modes, and is nulled for 'none'.
--
-- APPLIED 2026-08-16 to gadpooereceldfpfxsod (rolled-back dry run covering the checks below, then
-- applied for real and re-confirmed live).

create or replace function public.business_set_earning_rule_v359(
  p_business uuid,
  p_earn_points_per_dollar numeric default null,
  p_stamp_per_cents integer default null,
  p_expiry_mode text default null,
  p_expiry_days integer default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_mode text := nullif(btrim(coalesce(p_expiry_mode,'')),'');
  v_days integer;
  v_row public.loyalty_programs%rowtype;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;

  if p_earn_points_per_dollar is not null and p_earn_points_per_dollar <= 0 then
    raise exception 'points per dollar must be greater than zero' using errcode='22023';
  end if;
  if p_stamp_per_cents is not null and p_stamp_per_cents <= 0 then
    raise exception 'spend per stamp must be greater than zero' using errcode='22023';
  end if;

  if v_mode is not null then
    if v_mode not in ('none','fixed','inactivity') then
      raise exception 'invalid expiry mode' using errcode='22023';
    end if;
    if v_mode = 'none' then
      v_days := null;
    else
      v_days := p_expiry_days;
      if v_days is null or v_days < 1 or v_days > 3650 then
        raise exception 'expiry days must be between 1 and 3650' using errcode='22023';
      end if;
    end if;
  end if;

  insert into public.loyalty_programs(business_id, active, configuration_status,
    earn_points_per_dollar, stamp_per_cents, expiry_mode, expiry_days)
  values (p_business, false, 'draft',
    coalesce(p_earn_points_per_dollar, 1), p_stamp_per_cents,
    coalesce(v_mode, 'none'), v_days)
  on conflict (business_id) do update set
    -- NB: must test the PARAMETER, not `excluded`. The INSERT arm defaults an omitted rate to 1,
    -- so `excluded.earn_points_per_dollar` is never null and a coalesce here would silently reset
    -- a firm's real rate to 1 on any call that only meant to change the stamp rate or expiry.
    -- (Caught by the rolled-back verification below before this ever reached production.)
    earn_points_per_dollar = case when p_earn_points_per_dollar is null then public.loyalty_programs.earn_points_per_dollar else excluded.earn_points_per_dollar end,
    stamp_per_cents        = case when p_stamp_per_cents is null then public.loyalty_programs.stamp_per_cents else excluded.stamp_per_cents end,
    expiry_mode            = case when v_mode is null then public.loyalty_programs.expiry_mode else excluded.expiry_mode end,
    expiry_days            = case when v_mode is null then public.loyalty_programs.expiry_days else excluded.expiry_days end
  returning * into v_row;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(), 'earning_rule.updated', 'loyalty_programs', p_business,
    jsonb_build_object('earn_points_per_dollar', v_row.earn_points_per_dollar,
                       'stamp_per_cents', v_row.stamp_per_cents,
                       'expiry_mode', v_row.expiry_mode, 'expiry_days', v_row.expiry_days));

  return jsonb_build_object('status','ok',
    'earn_points_per_dollar', v_row.earn_points_per_dollar,
    'stamp_per_cents', v_row.stamp_per_cents,
    'expiry_mode', v_row.expiry_mode, 'expiry_days', v_row.expiry_days);
end
$$;
revoke all privileges on function public.business_set_earning_rule_v359(uuid,numeric,integer,text,integer) from public, anon, authenticated;
grant execute on function public.business_set_earning_rule_v359(uuid,numeric,integer,text,integer) to authenticated;

-- ============================================================================================
-- VERIFICATION (rolled-back transaction against production before applying for real)
-- ============================================================================================
-- Verified 2026-08-16 inside a rolled-back transaction against gadpooereceldfpfxsod (Cubbly):
--   1. points rate only -> earn_points_per_dollar updated; stamp_per_cents/expiry untouched
--      (the coalesce/case arms leave unnamed columns exactly as found).
--   2. stamp rate only -> stamp_per_cents updated, points rate untouched.
--   3. expiry_mode='fixed' with days -> both written; expiry_mode='none' -> days nulled.
--   4. rate of 0 -> refused 22023; expiry 'fixed' with no days -> refused 22023.
--   5. non-owner staff -> refused 42501, nothing changed.
--   6. loyalty_model/kind/tier_basis identical before and after every call (this RPC must never
--      touch the columns V354 and v347 own).
