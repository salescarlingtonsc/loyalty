-- nestly_v552 — a gated section fails alone, names itself, and the account-opens clamp ends a
-- production outage no one could see.
--
-- WHAT WAS WRONG (AI-005, upgraded on diagnosis 2026-08-27). app.v176_gated_evidence assembled
-- four consultative sections (consultant_brief, catalogue_affinity, recommendations,
-- account_opens_report) inside ONE `exception when others` that discarded the error and returned
-- `{available:false, reason:'evidence_rpc_unavailable'}`. Two compounding defects:
--
--   1. ALL-OR-NOTHING: one section's failure removed all four.
--   2. SWALLOWED DIAGNOSIS: the reason string named neither the section nor the error.
--
-- Diagnosed read-only against production by calling each RPC separately under the same
-- impersonation: three sections are healthy; the fourth, platform_customer_account_opens_v175,
-- raises 22023 "report range must be ordered, no longer than 367 days and not future" — because
-- the monthly pack hands it the month's LAST day as p_to, which is in the future for any report
-- claimed before month-end. So every mid-month monthly report in production has been silently
-- missing all four consultative sections, and the model read the nulls as "nothing to report".
-- v175's guard is correct for its own API; the caller is the wrong party.
--
-- WHAT THIS DOES:
--   * app.v176_gated_evidence: the account-opens range end is clamped to the current Singapore
--     date (disclosed in `account_opens_range` — requested_to / effective_to / clamped); each of
--     the four sections runs in its OWN exception block, so one failure loses one section; the
--     failures are listed in `unavailable_sections` as [{section, sqlstate}] — the sqlstate only,
--     never sqlerrm, so no internal identifiers reach the model.
--   * app.v176_evidence_pack: evidence_completeness carries `unavailable_sections` through, and
--     `gated_rpcs_available` stays true only when every section arrived. account_opens gains the
--     clamp disclosure as `report_range`.
--   * The system prompt ships alongside: an unavailable section is WITHHELD, not empty — the
--     model must not read absence as "nothing to report" nor fill the gap by inference.
--
-- Impersonation preamble/restore is preserved verbatim; with per-section handlers no exception
-- can escape past the restore. Neither function's callable surface changes: both remain
-- postgres-only SECURITY DEFINER internals (proacl restated below).
--
-- ROLLBACK: db/tests/v552_gated_evidence_isolation.sql

begin;

create or replace function app.v176_gated_evidence(p_business uuid, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_reader uuid;
  v_prior_sub text;
  v_prior_claims text;
  v_impersonated boolean := false;
  v_to_effective date;
  v_brief jsonb; v_affinity jsonb; v_recs jsonb; v_opens jsonb;
  v_unavailable jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then
    select super_admin.user_id into v_reader
      from public.super_admins super_admin
     order by super_admin.user_id limit 1;
    if v_reader is null then
      return pg_catalog.jsonb_build_object(
        'available', false,
        'reason', 'no_platform_reader',
        'unavailable_sections', pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object('section','consultant_brief','sqlstate','n/a'),
          pg_catalog.jsonb_build_object('section','catalogue_affinity','sqlstate','n/a'),
          pg_catalog.jsonb_build_object('section','recommendations','sqlstate','n/a'),
          pg_catalog.jsonb_build_object('section','account_opens_report','sqlstate','n/a')
        )
      );
    end if;
    v_prior_sub := coalesce(pg_catalog.current_setting('request.jwt.claim.sub', true), '');
    v_prior_claims := coalesce(pg_catalog.current_setting('request.jwt.claims', true), '');
    perform pg_catalog.set_config('request.jwt.claim.sub', v_reader::text, true);
    perform pg_catalog.set_config('request.jwt.claims', pg_catalog.json_build_object(
      'sub', v_reader, 'role', 'authenticated', 'aud', 'authenticated')::text, true);
    v_impersonated := true;
  end if;

  /* v552: the account-opens reader refuses future dates (its 22023 guard is correct); the
     monthly pack's period end is the month's last day, future for any mid-month claim. Clamp
     here, and say so in the payload rather than clamping silently. */
  v_to_effective := least(p_to, (pg_catalog.now() at time zone 'Asia/Singapore')::date);

  /* v552: one section, one handler. A failing section records its sqlstate (never sqlerrm — no
     internal identifiers for the model) and the other three survive. Before this, one failure
     removed all four and the error text was discarded. */
  begin
    v_brief := public.platform_get_assigned_firm_report_v94(p_business, null, p_from, p_to);
  exception when others then
    v_unavailable := v_unavailable || pg_catalog.jsonb_build_object(
      'section','consultant_brief','sqlstate', sqlstate);
  end;
  begin
    v_affinity := public.platform_get_catalogue_affinity_v94(p_business, null, p_from, p_to, 25);
  exception when others then
    v_unavailable := v_unavailable || pg_catalog.jsonb_build_object(
      'section','catalogue_affinity','sqlstate', sqlstate);
  end;
  begin
    v_recs := public.platform_get_consultative_recommendations_v94(p_business, null, p_from, p_to, 25);
  exception when others then
    v_unavailable := v_unavailable || pg_catalog.jsonb_build_object(
      'section','recommendations','sqlstate', sqlstate);
  end;
  begin
    v_opens := public.platform_customer_account_opens_v175(p_business, p_from, v_to_effective);
  exception when others then
    v_unavailable := v_unavailable || pg_catalog.jsonb_build_object(
      'section','account_opens_report','sqlstate', sqlstate);
  end;

  if v_impersonated then
    perform pg_catalog.set_config('request.jwt.claim.sub', v_prior_sub, true);
    perform pg_catalog.set_config('request.jwt.claims', v_prior_claims, true);
  end if;

  return pg_catalog.jsonb_build_object(
    'available', pg_catalog.jsonb_array_length(v_unavailable) = 0,
    'reason', case when pg_catalog.jsonb_array_length(v_unavailable) = 0 then null
                   else 'sections_unavailable' end,
    'unavailable_sections', v_unavailable,
    'consultant_brief', v_brief,
    'catalogue_affinity', v_affinity,
    'recommendations', v_recs,
    'account_opens_report', v_opens,
    'account_opens_range', pg_catalog.jsonb_build_object(
      'requested_to', p_to,
      'effective_to', v_to_effective,
      'clamped', v_to_effective < p_to
    )
  );
end
$function$;

-- both functions stay postgres-only internals; restate the live proacl verbatim
revoke all on function app.v176_gated_evidence(uuid, date, date) from public, anon, authenticated;

do $patch$
declare d text; n text;
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='app' and p.proname='v176_evidence_pack';
  if d is null then raise exception 'v552: app.v176_evidence_pack is missing'; end if;

  if position('unavailable_sections' in d) > 0 then
    raise notice 'v552: the evidence pack already signals unavailable sections';
    return;
  end if;

  n := regexp_replace(d,
    '''report'',\s*v_gated->''account_opens_report''',
    '''report'', v_gated->''account_opens_report'',
      ''report_range'', v_gated->''account_opens_range''');
  if n = d then raise exception 'v552: account_opens report anchor not found'; end if;
  d := n;

  n := regexp_replace(d,
    '''gated_rpcs_reason'',\s*v_gated->>''reason'',',
    '''gated_rpcs_reason'', v_gated->>''reason'',
      /* v552: the list the model must consult - a section named here was WITHHELD, and its
         absence is not "nothing to report". */
      ''unavailable_sections'', coalesce(v_gated->''unavailable_sections'', ''[]''::jsonb),');
  if n = d then raise exception 'v552: evidence_completeness anchor not found'; end if;

  execute n;
  raise notice 'v552: evidence pack signals per-section availability';
end
$patch$;

do $verify$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='app' and p.proname='v176_gated_evidence'
       and position('unavailable_sections' in p.prosrc) > 0
  ) or not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='app' and p.proname='v176_evidence_pack'
       and position('unavailable_sections' in p.prosrc) > 0
  ) then
    raise exception 'v552: per-section signalling did not land in both functions';
  end if;
end
$verify$;

commit;
