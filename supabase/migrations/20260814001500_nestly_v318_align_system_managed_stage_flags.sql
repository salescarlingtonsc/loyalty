-- nestly_v318_align_system_managed_stage_flags
--
-- Two tables disagreed about which pipeline stages are machine-driven:
-- public.sme_pipeline_stages.is_system (drives the console UI, and — as of
-- v317 — the guard inside platform_move_prospect_stage_v76) and
-- public.sme_stage_entry_requirements.system_managed (enforced independently
-- by app.validate_stage_entry_v86).
--
-- The disagreement had two live consequences:
--
--   1. 'onboarding' was rep-facing in sme_pipeline_stages but system-managed
--      in sme_stage_entry_requirements, so a consultant could not advance a
--      deal into it at all — the UI offered the move, and
--      validate_stage_entry_v86 rejected it every time.
--
--   2. 'activated' (a Peekaa merchant going live) was NOT system-managed in
--      sme_stage_entry_requirements, so a consultant could mark a business a
--      live merchant from a plain dropdown with no workspace, subscription,
--      or conversion evidence behind it — forging the one number this system
--      exists to measure.
--
-- public.sme_pipeline_stages.is_system becomes the single source of truth:
-- 'activated' joins the machine-driven set there, and
-- sme_stage_entry_requirements.system_managed is realigned to match it
-- everywhere, closing both gaps from one authority instead of two that can
-- drift again.

begin;

update public.sme_pipeline_stages set is_system = true
 where stage_key = 'activated' and is_system = false;

update public.sme_stage_entry_requirements r set system_managed = s.is_system
  from public.sme_pipeline_stages s
 where s.stage_key = r.stage_key and r.system_managed is distinct from s.is_system;

do $verify$
declare v_bad text;
begin
  select string_agg(s.stage_key, ', ') into v_bad
    from public.sme_pipeline_stages s
    join public.sme_stage_entry_requirements r on r.stage_key = s.stage_key
   where r.system_managed is distinct from s.is_system;
  if v_bad is not null then
    raise exception 'system-managed flags still disagree for: %', v_bad;
  end if;
end $verify$;

commit;
