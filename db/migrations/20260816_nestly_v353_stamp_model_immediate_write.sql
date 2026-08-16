-- V353: fixes "Set up Stamp Card system" doing nothing visible on click.
--
-- V352 (same day, earlier) fixed the CTA to turn the stamps spine on inline instead of bouncing to
-- the wizard — but that alone was NOT enough. growPointsConfiguredV326/growStampsPageV350's
-- "configured" check for stamps is `liveLoyaltyModelV235==='stamps'`
-- (app/app.js:22345-22346), which reads `snapshot.loyalty?.loyalty_model==='stamps'` — the
-- public.loyalty_programs.loyalty_model COLUMN, entirely separate from the business_programmes
-- spine V352 flips. Confirmed by grep: loyalty_model (and the sibling `kind` column) are written
-- ONLY inside publish_loyalty_config's draft-apply block, in every migration that touches it
-- (v37b/v45/v55/v331/v332) — there was never an immediate-write path for either column at all, the
-- exact same gap v347 found and closed for tier_basis. So V352's fix flipped the spine (which
-- DOES immediately start/stop accrual — the engine itself reads the spine, per V314), but the
-- OWNER-FACING PAGE never noticed, because it was still reading a column the click never touched.
-- Clicking silently did something (the RPC call), just not the thing that made the page move.
--
-- `kind` is set alongside `loyalty_model` because several redemption-path RPCs (v89, v326) gate on
-- `v_program.kind<>'points' or v_program.loyalty_model<>'classic'` — leaving kind='points' while
-- loyalty_model='stamps' would leave those two columns disagreeing with each other, an inconsistency
-- worth avoiding even though the accrual engine itself no longer reads either column (V314 comment,
-- app/app.js:896-901: "app.on_sale_recorded loops over active accruing spine rows").
--
-- APPLIED 2026-08-16 to gadpooereceldfpfxsod (rolled-back dry run covering all 4 checks below,
-- then applied for real and re-confirmed the function is live).

create or replace function public.business_set_loyalty_model_v353(p_business uuid, p_model text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_kind text;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if p_model is null or p_model not in ('classic','points_tiers','stamps') then
    raise exception 'invalid loyalty model' using errcode='22023';
  end if;
  v_kind := case when p_model='stamps' then 'stamps' else 'points' end;

  -- active must be false while configuration_status stays at its table default 'draft' --
  -- loyalty_programs_configuration_status_check requires configuration_status='draft' => not
  -- active (same insert-path constraint v347 already worked around for tier_basis).
  insert into public.loyalty_programs(business_id, loyalty_model, kind, active, configuration_status)
  values (p_business, p_model, v_kind, false, 'draft')
  on conflict (business_id) do update set loyalty_model=excluded.loyalty_model, kind=excluded.kind;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'loyalty_model.updated','loyalty_programs',p_business,
    jsonb_build_object('loyalty_model',p_model,'kind',v_kind));

  return jsonb_build_object('status','ok','loyalty_model',p_model,'kind',v_kind);
end
$$;
revoke all privileges on function public.business_set_loyalty_model_v353(uuid,text) from public, anon, authenticated;
grant execute on function public.business_set_loyalty_model_v353(uuid,text) to authenticated;

-- ============================================================================================
-- VERIFICATION (rolled-back transaction against production before applying for real)
-- ============================================================================================
-- Verified 2026-08-16 inside a rolled-back transaction against gadpooereceldfpfxsod, using Cubbly:
--   1. set p_model='stamps' -> loyalty_programs.loyalty_model='stamps', kind='stamps'.
--   2. non-owner staff attempt -> refused with 42501, nothing changed.
--   3. invalid model string -> refused with 22023, nothing changed.
--   4. set p_model='classic' (switching back) -> loyalty_model='classic', kind='points'.
