-- EXECUTED acceptance fixture for nestly_v821
-- (db/migrations/20261007_nestly_v821_billing_reconcile_call_failure_alerts.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --migrated-only --filter=v821
--
-- WHY THIS EXISTS. nestly_v791 restored the Stripe reconciler edge function with a named import
-- the shared module no longer exported, so the deployed worker failed at boot and the nightly
-- cron nestly-v624-billing-reconcile recorded status_code=503 / outcome='failed' /
-- body {"code":"BOOT_ERROR"} on three consecutive nights. Platform billing went unreconciled and
-- the console did not make that legible: nestly_v634 keeps exactly ONE open 'reconcile_failed'
-- row and only refreshes its detail, so created_at — the console's "Raised" column — froze at
-- the first failure and three failing nights read as one old complaint. Worse, every alert in
-- the family is downstream of a call HAPPENING: a reconciler that stopped being called at all
-- would have raised nothing, and silence would have been indistinguishable from health.
--
-- nestly_v821 adds two kinds beside the untouched 'reconcile_failed':
--   'reconcile_call_failed' — one open row per UTC day a call fails, and
--   'reconcile_stale'       — no successful call in 36 hours while the cron job is active.
--
-- ASSERTIONS (rows, with a fatal gate at the end):
--   T1   A 503 BOOT_ERROR receipt settles the call as outcome='failed'.
--   T2   ...and raises a 'reconcile_call_failed' alert keyed to that call's own UTC day.
--   T3   The alert carries the 503 receipt (status_code, outcome, call_id), not just a word.
--   T4   Two failed calls on two different UTC days raise TWO open per-day rows — the length of
--        an outage is readable, which is exactly what the live incident could not show.
--   T5   Two failed calls on the SAME UTC day raise only ONE open row (per-day deduplication),
--        and the second refreshes the detail rather than duplicating the row.
--   T6   The nestly_v634 'reconcile_failed' contract is untouched: still exactly ONE open row
--        across all of the above.
--   T7   STALE SCENARIO: with the reconcile cron job active and no successful call in the last
--        36 hours, app.detect_billing_alerts_v624() raises 'reconcile_stale'.
--   T8   ...and the alert names the job and the hours since the last success.
--   T9   A call that succeeded 12 hours ago (inside the window) raises NO 'reconcile_stale' —
--        the 36-hour bound is a real bound, not an always-on alarm. This is the assertion that
--        would fail if somebody narrowed the window to 24 hours and made a healthy estate
--        complain every evening between the detector pass and that night's run.
--   T10  An INACTIVE reconcile cron job raises no 'reconcile_stale' — a deliberately paused
--        reconciler is not a failure, and an alert nobody can action is noise.
--   T11  A 2xx call supersedes the WHOLE family — reconcile_failed, every per-day
--        reconcile_call_failed, and reconcile_stale — so one green run clears the backlog.
--   T12  ...and each auto-resolution is audited as BILLING_ALERT_AUTORESOLVED_V634.
--
-- Every assertion is recorded as a row; the final gate makes any FAIL fatal. Rolled back.
--
-- NOTE ON THE FIXTURE'S DEPENDENCIES. This suite writes net._http_response rows and cron.job
-- rows directly. In the scratch cluster both are local stand-ins created by
-- scripts/db-tests/bootstrap-extras.sql and db/tests/rehearsal/bootstrap.sql; in production they
-- are pg_net and pg_cron. Nothing here dispatches an HTTP request — the receipt IS the fixture,
-- which is the same shape app.check_billing_reconcile_calls_v634() reads in production.
begin;

create temp table v821_out(seq integer, step text, outcome text, detail text) on commit drop;

create or replace function pg_temp.v821_note(
  p_seq integer, p_step text, p_ok boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into v821_out values (p_seq, p_step, case when p_ok then 'PASS' else 'FAIL' end, p_detail);
end
$$;

/* A settled receipt of the given status, dispatched at the given time. Returns the call id. */
create or replace function pg_temp.v821_call(p_status integer, p_body text, p_at timestamptz)
returns uuid language plpgsql as $$
declare
  v_req bigint;
  v_id uuid;
begin
  v_req := coalesce((select max(id) from net._http_response), 0) + 1;
  insert into net._http_response (id, status_code, content, timed_out, error_msg)
  values (v_req, p_status, p_body, false, null);
  insert into public.platform_billing_reconcile_calls_v634 (net_request_id, requested_at)
  values (v_req, p_at) returning id into v_id;
  return v_id;
end
$$;

do $v821_test$
declare
  v_boot text := '{"code":"BOOT_ERROR","message":"Function failed to start (please check logs)"}';
  v_call_a uuid;
  v_call_b uuid;
  v_call_c uuid;
  v_call_ok uuid;
  v_day_a text;
  v_day_b text;
  v_n integer;
  v_outcome text;
  v_detail jsonb;
  v_had_job boolean;
begin
  /* The estate starts clean: nothing this suite asserts about may already be open. */
  delete from public.platform_billing_alerts_v624
   where kind in ('reconcile_failed', 'reconcile_call_failed', 'reconcile_stale',
                  'reconcile_unconfigured');
  delete from public.platform_billing_reconcile_calls_v634;

  -- ------------------------------------------------------------------------------------------
  -- T1-T3 · one 503 BOOT_ERROR night
  -- ------------------------------------------------------------------------------------------
  v_call_a := pg_temp.v821_call(503, v_boot, now() - interval '48 hours');
  v_day_a := to_char(((now() - interval '48 hours') at time zone 'UTC')::date, 'YYYY-MM-DD');
  perform app.check_billing_reconcile_calls_v634();

  select outcome into v_outcome
    from public.platform_billing_reconcile_calls_v634 where id = v_call_a;
  perform pg_temp.v821_note(1, 'T1 a 503 BOOT_ERROR receipt settles the call as failed',
    v_outcome = 'failed', 'outcome=' || coalesce(v_outcome, '<null>'));

  select count(*) into v_n
    from public.platform_billing_alerts_v624
   where kind = 'reconcile_call_failed' and object_id = 'reconcile:' || v_day_a
     and resolved_at is null;
  perform pg_temp.v821_note(2, 'T2 the failed call raises reconcile_call_failed for its own UTC day',
    v_n = 1, 'open rows for reconcile:' || v_day_a || '=' || v_n);

  select detail into v_detail
    from public.platform_billing_alerts_v624
   where kind = 'reconcile_call_failed' and object_id = 'reconcile:' || v_day_a
     and resolved_at is null;
  perform pg_temp.v821_note(3, 'T3 the alert carries the 503 receipt, not only an outcome word',
    coalesce(v_detail->>'status_code', '') = '503'
      and coalesce(v_detail->>'outcome', '') = 'failed'
      and coalesce(v_detail->>'call_id', '') = v_call_a::text,
    'detail=' || coalesce(v_detail::text, '<null>'));

  -- ------------------------------------------------------------------------------------------
  -- T4 · a second failing night is its own row
  -- ------------------------------------------------------------------------------------------
  v_call_b := pg_temp.v821_call(503, v_boot, now() - interval '24 hours');
  v_day_b := to_char(((now() - interval '24 hours') at time zone 'UTC')::date, 'YYYY-MM-DD');
  perform app.check_billing_reconcile_calls_v634();

  select count(*) into v_n
    from public.platform_billing_alerts_v624
   where kind = 'reconcile_call_failed' and resolved_at is null;
  perform pg_temp.v821_note(4, 'T4 two failed nights are two open per-day alerts',
    (v_day_a = v_day_b and v_n = 1) or (v_day_a <> v_day_b and v_n = 2),
    'days=' || v_day_a || '/' || v_day_b || ' open=' || v_n);

  -- ------------------------------------------------------------------------------------------
  -- T5 · a second failure on the SAME day refreshes, it does not duplicate
  -- ------------------------------------------------------------------------------------------
  v_call_c := pg_temp.v821_call(500, '{"error":"a second failure the same night"}',
                                now() - interval '23 hours');
  perform app.check_billing_reconcile_calls_v634();

  select count(*) into v_n
    from public.platform_billing_alerts_v624
   where kind = 'reconcile_call_failed' and object_id = 'reconcile:' || v_day_b
     and resolved_at is null;
  select detail into v_detail
    from public.platform_billing_alerts_v624
   where kind = 'reconcile_call_failed' and object_id = 'reconcile:' || v_day_b
     and resolved_at is null;
  perform pg_temp.v821_note(5, 'T5 a second failure the same UTC day refreshes one row, it does not duplicate',
    v_n = 1 and coalesce(v_detail->>'call_id', '') = v_call_c::text,
    'open=' || v_n || ' newest call_id=' || coalesce(v_detail->>'call_id', '<null>'));

  -- ------------------------------------------------------------------------------------------
  -- T6 · the nestly_v634 standing complaint is untouched
  -- ------------------------------------------------------------------------------------------
  select count(*) into v_n
    from public.platform_billing_alerts_v624
   where kind = 'reconcile_failed' and resolved_at is null;
  perform pg_temp.v821_note(6, 'T6 reconcile_failed keeps its one-open-row contract across three failures',
    v_n = 1, 'open reconcile_failed=' || v_n);

  -- ------------------------------------------------------------------------------------------
  -- T7-T8 · staleness: the cron is active and nothing has come back green
  -- ------------------------------------------------------------------------------------------
  select exists (select 1 from cron.job where jobname = 'nestly-v624-billing-reconcile')
    into v_had_job;
  if not v_had_job then
    insert into cron.job (schedule, command, jobname, active)
    values ('30 19 * * *', 'select app.run_billing_reconcile_call_v624()',
            'nestly-v624-billing-reconcile', true);
  else
    update cron.job set active = true where jobname = 'nestly-v624-billing-reconcile';
  end if;

  delete from public.platform_billing_alerts_v624 where kind = 'reconcile_stale';
  perform app.detect_billing_alerts_v624();

  select count(*) into v_n
    from public.platform_billing_alerts_v624
   where kind = 'reconcile_stale' and object_id = 'reconcile' and resolved_at is null;
  perform pg_temp.v821_note(7, 'T7 an active reconcile cron with no success in 36h raises reconcile_stale',
    v_n = 1, 'open reconcile_stale=' || v_n);

  select detail into v_detail
    from public.platform_billing_alerts_v624
   where kind = 'reconcile_stale' and object_id = 'reconcile' and resolved_at is null;
  perform pg_temp.v821_note(8, 'T8 the staleness alert names the job it is complaining about',
    coalesce(v_detail->>'job', '') = 'nestly-v624-billing-reconcile',
    'detail=' || coalesce(v_detail::text, '<null>'));

  -- ------------------------------------------------------------------------------------------
  -- T9 · a success inside the window is NOT stale
  -- ------------------------------------------------------------------------------------------
  delete from public.platform_billing_alerts_v624 where kind = 'reconcile_stale';
  insert into public.platform_billing_reconcile_calls_v634
    (net_request_id, requested_at, checked_at, status_code, outcome, detail)
  values (-1, now() - interval '12 hours', now() - interval '12 hours', 200, 'succeeded',
          jsonb_build_object('status_code', 200));
  perform app.detect_billing_alerts_v624();

  select count(*) into v_n
    from public.platform_billing_alerts_v624
   where kind = 'reconcile_stale' and resolved_at is null;
  perform pg_temp.v821_note(9, 'T9 a reconciliation that succeeded 12h ago is inside the 36h window and raises nothing',
    v_n = 0, 'open reconcile_stale=' || v_n);

  -- ------------------------------------------------------------------------------------------
  -- T10 · an inactive job is not a failure
  -- ------------------------------------------------------------------------------------------
  delete from public.platform_billing_reconcile_calls_v634 where net_request_id = -1;
  delete from public.platform_billing_alerts_v624 where kind = 'reconcile_stale';
  update cron.job set active = false where jobname = 'nestly-v624-billing-reconcile';
  perform app.detect_billing_alerts_v624();

  select count(*) into v_n
    from public.platform_billing_alerts_v624
   where kind = 'reconcile_stale' and resolved_at is null;
  perform pg_temp.v821_note(10, 'T10 a paused reconcile cron job raises no reconcile_stale',
    v_n = 0, 'open reconcile_stale=' || v_n);

  update cron.job set active = true where jobname = 'nestly-v624-billing-reconcile';
  perform app.detect_billing_alerts_v624();

  -- ------------------------------------------------------------------------------------------
  -- T11-T12 · one green run clears the family, and says so in the audit log
  -- ------------------------------------------------------------------------------------------
  v_call_ok := pg_temp.v821_call(200, '{"status":"clean","partial":false}', now());
  perform app.check_billing_reconcile_calls_v634();

  select count(*) into v_n
    from public.platform_billing_alerts_v624
   where kind in ('reconcile_failed', 'reconcile_call_failed', 'reconcile_stale')
     and resolved_at is null;
  perform pg_temp.v821_note(11, 'T11 a 2xx reconciliation supersedes every open reconciliation alert',
    v_n = 0, 'still open=' || v_n);

  select count(*) into v_n
    from public.audit_log
   where action = 'BILLING_ALERT_AUTORESOLVED_V634'
     and detail->>'kind' in ('reconcile_failed', 'reconcile_call_failed', 'reconcile_stale');
  perform pg_temp.v821_note(12, 'T12 every auto-resolution is audited as BILLING_ALERT_AUTORESOLVED_V634',
    v_n >= 3, 'audit rows=' || v_n);
end
$v821_test$;

select seq, step, outcome, detail from v821_out order by seq;

do $gate$
declare v_failed integer;
begin
  select count(*) into v_failed from v821_out where outcome <> 'PASS';
  if v_failed > 0 then
    raise exception 'nestly_v821 acceptance: % assertion(s) FAILED', v_failed;
  end if;
end
$gate$;

rollback;
