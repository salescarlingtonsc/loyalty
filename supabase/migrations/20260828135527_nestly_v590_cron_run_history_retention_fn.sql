begin;

-- nestly_v590_cron_run_history_retention_fn -- VERBATIM MIRROR of an already-applied
-- production migration (project gadpooereceldfpfxsod, ledger version 20260828135527),
-- recovered read-only on 2026-08-29 during source/production drift closure. See
-- docs/qa/SECURITY-CRON-FOLLOWUP-2026-08-29.md section 2 and the exact capture in
-- docs/qa/audit-artifacts/v590-v592-live-definitions.sql /
-- docs/qa/audit-artifacts/v590-v592-live-object-catalog.csv.
--
-- MUST NOT be re-applied to production. Production already carries this migration's ledger
-- row; record it locally instead with:
--   supabase migration repair --status applied 20260828135527
--
-- Second of two v590 migrations: creates the function scheduled two minutes earlier by
-- nestly_v590_cron_run_history_retention (20260828135225). Deletes completed
-- cron.job_run_details rows older than the succeeded/failed retention windows, batched, capped
-- at p_max_rows per run, and writes one audit_log row summarizing the sweep.

CREATE OR REPLACE FUNCTION app.purge_cron_run_history_v590(p_succeeded_days integer DEFAULT 7, p_failed_days integer DEFAULT 90, p_batch integer DEFAULT 5000, p_max_rows integer DEFAULT 20000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'cron', 'pg_temp'
AS $function$
declare
  v_cutoff_ok    timestamptz := now() - make_interval(days => greatest(p_succeeded_days, 1));
  v_cutoff_bad   timestamptz := now() - make_interval(days => greatest(p_failed_days, 1));
  v_rows_before  bigint;
  v_bytes_before bigint;
  v_rows_after   bigint;
  v_deleted      bigint := 0;
  v_batch_deleted bigint;
  v_batches      integer := 0;
  v_started      timestamptz := clock_timestamp();
  v_detail       jsonb;
begin
  if p_batch < 1 or p_batch > 50000 then
    raise exception 'p_batch out of range (1..50000): %', p_batch using errcode = '22023';
  end if;
  if p_max_rows < 1 or p_max_rows > 500000 then
    raise exception 'p_max_rows out of range (1..500000): %', p_max_rows using errcode = '22023';
  end if;

  select count(*), pg_total_relation_size('cron.job_run_details')
    into v_rows_before, v_bytes_before from cron.job_run_details;

  loop
    exit when v_deleted >= p_max_rows;

    delete from cron.job_run_details
     where ctid in (
       select d.ctid from cron.job_run_details d
        where d.end_time is not null
          and (   (d.status =  'succeeded' and d.start_time < v_cutoff_ok)
               or (d.status <> 'succeeded' and d.start_time < v_cutoff_bad))
        limit least(p_batch, p_max_rows - v_deleted));

    get diagnostics v_batch_deleted = row_count;
    v_deleted := v_deleted + v_batch_deleted;
    v_batches := v_batches + 1;

    exit when v_batch_deleted = 0;
  end loop;

  select count(*) into v_rows_after from cron.job_run_details;

  v_detail := jsonb_build_object(
    'migration',      'nestly_v590',
    'succeeded_days', p_succeeded_days,
    'failed_days',    p_failed_days,
    'batch_size',     p_batch,
    'max_rows',       p_max_rows,
    'batches',        v_batches,
    'hit_row_cap',    v_deleted >= p_max_rows,
    'rows_deleted',   v_deleted,
    'rows_before',    v_rows_before,
    'rows_after',     v_rows_after,
    'bytes_before',   v_bytes_before,
    'duration_ms',    round(extract(epoch from (clock_timestamp() - v_started))::numeric * 1000, 1));

  insert into public.audit_log(business_id, actor, action, entity, detail)
  values (null, null, 'cron_run_history_purged', 'cron.job_run_details', v_detail);

  return v_detail;
end;
$function$;

revoke all on function app.purge_cron_run_history_v590(integer, integer, integer, integer) from public, anon, authenticated;

commit;
