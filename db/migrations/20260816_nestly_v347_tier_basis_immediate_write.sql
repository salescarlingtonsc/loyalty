-- V347: business_set_tier_basis_v347 — lets the Manage Tiers page (growTiersManageV331) set how
-- tiers are earned WITHOUT bouncing to the "Set up rewards" wizard.
--
-- Owner complaint 2026-08-16: clicking "Set up Tier membership" on the one-page Manage Tiers view
-- still landed on the multi-step wizard ("Step 5 of 7") even though V345 already gave that page
-- full add/edit/benefit parity. Root cause: tier_basis (public.loyalty_programs.tier_basis) had
-- NO immediate-write RPC anywhere — every existing write path went through saveDraft(...) followed
-- by publish_loyalty_config, the full draft/publish machinery. business_create_tier_v331 and
-- set_programmes_v314 (the spine on/off switch) were already immediate-write and sufficient for
-- "first tier created" + "turned on for customers" — this is the one missing piece.
--
-- loyalty_programs.business_id is UNIQUE (loyalty_programs_business_id_key), and every business
-- already gets a row at creation (create_business); the upsert only exists to be safe for any
-- tenant that somehow lacks one, using the table's own column defaults for everything but
-- business_id/tier_basis so it never contradicts create_business's own shape.
--
-- APPLIED 2026-08-16 to gadpooereceldfpfxsod (rolled-back dry run + a real update/reject-invalid
-- cycle re-run immediately before the real apply; function confirmed live afterward).

create or replace function public.business_set_tier_basis_v347(p_business uuid, p_basis text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_basis text := nullif(btrim(coalesce(p_basis,'')),'');
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if v_basis is null or v_basis not in ('visits','spend','points_earned') then
    raise exception 'invalid tier basis' using errcode='22023';
  end if;

  -- active must be false while configuration_status stays at its table default 'draft' --
  -- loyalty_programs_configuration_status_check requires configuration_status='draft' => not
  -- active (confirmed live: the executor validates row constraints against the proposed INSERT
  -- row, defaults included, before ON CONFLICT ever resolves — a bare default-column insert here
  -- throws 23514 even though the actual outcome for an existing row is always the UPDATE branch).
  -- Mirrors create_business's own insert shape (business_id,kind,active,loyalty_model,
  -- configuration_status) for the only-ever-hit-on-a-missing-row path.
  insert into public.loyalty_programs(business_id, tier_basis, active, configuration_status)
  values (p_business, v_basis, false, 'draft')
  on conflict (business_id) do update set tier_basis=excluded.tier_basis;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'tier_basis.updated','loyalty_programs',p_business,
    jsonb_build_object('tier_basis',v_basis));

  return jsonb_build_object('status','ok','tier_basis',v_basis);
end
$$;
revoke all privileges on function public.business_set_tier_basis_v347(uuid,text) from public, anon, authenticated;
grant execute on function public.business_set_tier_basis_v347(uuid,text) to authenticated;

-- ============================================================================================
-- VERIFICATION (rolled-back transaction against production before applying for real)
-- ============================================================================================
-- Verified 2026-08-16, all 4 checks passed inside a rolled-back transaction against
-- gadpooereceldfpfxsod. Live loyalty_programs confirmed unchanged after each rollback:
--   1. owner sets basis to 'points_earned' on a business with an existing loyalty_programs row
--      -> tier_basis updated, only that column changed.
--   2. non-owner staff attempt -> refused with 42501, nothing changed.
--   3. invalid basis string -> refused with 22023, nothing changed.
--   4. business with NO loyalty_programs row (deleted for the test) -> insert path creates one
--      with the requested tier_basis and every other column at its table default.
