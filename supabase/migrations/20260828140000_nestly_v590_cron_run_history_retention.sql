-- nestly_v590 -- cron run history retention.
--
-- THE DEFECT: cron.job_run_details has never been purged. pg_cron does not
-- self-purge and Supabase ships no retention job. Since 2026-07-18 it grew to
-- 144,456 rows / 26 MB -- the largest table in a 143 MB database -- at roughly
-- 9,306 rows/day, carrying only a PK index on runid.
--
-- THE POLICY (owner ruling 2026-08-28):
--   * succeeded runs -> retain 7 days
--   * non-succeeded  -> retain 90 days, so failed-run forensics survive long
--     enough to diagnose. nestly_v536 explicitly relies on a failed dispatch
--     being diagnosable from cron.job_run_details.
--
-- THIS IS MAINTENANCE ONLY. It does not address the Disk IO budget question
-- and must not be reported as doing so.
--
-- A PROCEDURE with COMMIT-per-batch was tried FIRST and PROVEN NOT VIABLE:
-- pg_cron executes its command inside a transaction block, so the procedure
-- aborted with 2D000 invalid_transaction_termination. Evidence: temporary job
-- 'zz-v590-oneshot-proof', run 2026-08-28 13:54:00Z, status=failed. The proof
-- job was unscheduled and the procedure dropped before this form was applied.
--
-- Single transaction is safe here because DELETE takes ROW EXCLUSIVE, which
-- does NOT conflict with the INSERT/UPDATE pg_cron performs on this table --
-- concurrent cron writers are never blocked. No ACCESS EXCLUSIVE is taken.
-- TRUNCATE is deliberately not used because it would take one.
--
-- Unbounded work is prevented by p_max_rows rather than by committing: each
-- invocation removes at most p_max_rows in p_batch-sized statements, so no
-- single transaction is long. If a backlog exceeds the cap the daily job
-- catches up over subsequent days.
--
-- WHY NO INDEX ON start_time: it would have to be maintained on every one of
-- the ~37,000 daily pg_cron row-writes to serve one daily purge. A seq scan of
-- a fully-cached table is the cheaper side of that trade. Deliberate.
--
-- `end_time is not null` excludes any run still in flight, so a row pg_cron is
-- about to UPDATE can never be deleted out from under it.

begin;

create or replace function app.purge_cron_run_history_v590(
  p_succeeded_days integer default 7,
  p_failed_days    integer default 90,
  p_batch          integer default 5000,
  p_max_rows       integer default 20000
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'cron', 'pg_temp'
as $function$
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

-- Daily at 02:53 UTC. Minute 53 is coprime with every */2 */3 */5 */10 */15 */30
-- cadence in the fleet, and hour 02 carries no other daily job, so the purge
-- never lands in the 19:xx daily cluster.
select cron.schedule(
  'nestly-v590-cron-history-retention',
  '53 2 * * *',
  $cron$select app.purge_cron_run_history_v590()$cron$);

commit;
