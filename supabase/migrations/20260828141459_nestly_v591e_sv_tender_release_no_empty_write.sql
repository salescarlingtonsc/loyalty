begin;

-- nestly_v591e_sv_tender_release_no_empty_write -- VERBATIM MIRROR of an already-applied
-- production migration (project gadpooereceldfpfxsod, ledger version 20260828141459),
-- recovered read-only on 2026-08-29 during source/production drift closure. See
-- docs/qa/SECURITY-CRON-FOLLOWUP-2026-08-29.md section 2 and the exact capture in
-- docs/qa/audit-artifacts/v590-v592-live-definitions.sql /
-- docs/qa/audit-artifacts/v590-v592-live-object-catalog.csv.
--
-- MUST NOT be re-applied to production. Production already carries this migration's ledger
-- row; record it locally instead with:
--   supabase migration repair --status applied 20260828141459
--
-- Fifth of the five v591 migrations. Replaces app.run_sv_tender_release so the existence probe
-- for reserved stored-value tenders runs BEFORE app.sv_automation_begin(), instead of always
-- opening (and then closing) an sv_automation_runs row even when there was no work. Served by
-- the existing partial index checkout_sv_tenders_active_uk (business_id, account_id) WHERE
-- status = 'reserved'; no new index. Unlike the other v591 functions, this one is not part of
-- the webhook-consumer marker family and does not call app.v591_max_attempts().

CREATE OR REPLACE FUNCTION app.run_sv_tender_release(p_limit integer DEFAULT 1000)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_run uuid; v_b uuid; v_done integer := 0; v_failed integer := 0;
begin
  -- v591: the existence probe now runs BEFORE sv_automation_begin(). Previously
  -- every one of the 480 daily runs inserted an sv_automation_runs row and
  -- updated it at finish, whether or not a single hold needed releasing --
  -- 16,254 rows against 16,174 runs. The audit trail for productive runs and
  -- for failures is unchanged; only the no-work case stops writing.
  -- Served by the existing partial index checkout_sv_tenders_active_uk
  -- (business_id, account_id) WHERE status = 'reserved'. No new index.
  if not exists (
    select 1 from public.checkout_sv_tenders t where t.status = 'reserved'
  ) then
    return 0;
  end if;

  v_run := app.sv_automation_begin('sv_tender_release');
  for v_b in
    select distinct t.business_id from public.checkout_sv_tenders t
     where t.status = 'reserved'
     order by t.business_id
  loop
    begin
      perform public.sv_release_expired_checkout_tenders(v_b, p_limit);
      v_done := v_done + 1;
    exception when others then
      v_failed := v_failed + 1;
      insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
      values (v_b, null, 'SV_AUTOMATION_ERROR', 'sv_automation_runs', v_run, jsonb_build_object(
        'job', 'sv_tender_release', 'sqlstate', sqlstate, 'message', sqlerrm));
    end;
  end loop;
  perform app.sv_automation_finish(v_run, jsonb_build_object('succeeded', v_done, 'failed', v_failed));
  return v_done;
end $function$;

revoke all on function app.run_sv_tender_release(integer) from public, anon, authenticated, service_role;

commit;
