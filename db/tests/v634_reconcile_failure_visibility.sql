-- Rollback-only acceptance for NESTLY v634 — a reconciliation run that does not happen is visible.
--
-- Proves, at the server boundary only:
--   · every pg_net reconcile call is recorded, and app.check_billing_reconcile_calls_v634()
--     SETTLES it against net._http_response — 401/500 → 'failed', 2xx → 'succeeded';
--   · a failure raises exactly ONE open alert (kind='reconcile_failed', object_id='reconcile'),
--     and a second, different failure refreshes that alert's detail instead of queueing another;
--   · the checker is idempotent — nothing pending, nothing raised;
--   · a later success RESOLVES every open reconcile_failed AND reconcile_unconfigured alert, one
--     BILLING_ALERT_AUTORESOLVED_V634 audit row each;
--   · a silent call is fail-closed on a clock: 'pending' inside two hours, 'unknown' after;
--   · the v624 detector settles pending calls and counts them in its return;
--   · the call ledger is server-only (RLS on, zero policies, no browser grant) and the checker is
--     not executable by a session role; the schedule exists and is active.
--
-- Fixture technique: net._http_response is writable by the migration-running role, so responses are
-- SYNTHETIC rows at ids 900000001+ (asserted absent first). Real pg_net rows expire after 6 hours
-- (pg_net.ttl) and would make this suite time-dependent.
--
-- Pre-existing production state is neutralised, never assumed: any already-pending call is parked
-- before seeding, alert evidence is a singleton assertion, audit evidence is a DELTA, and the whole
-- thing is one transaction that ends in rollback — safe to run against production.
begin;

do $v634_main$
declare
  v_call_a uuid;
  v_call_b uuid;
  v_call_c uuid;
  v_call_d uuid;
  v_call_e uuid;
  v_resp_a bigint := 900000001;
  v_resp_b bigint := 900000002;
  v_resp_c bigint := 900000003;
  v_resp_e bigint := 900000004;
  v_raised integer;
  v_outcome text;
  v_status integer;
  v_detail jsonb;
  v_open bigint;
  v_open_before bigint;
  v_audit_before bigint;
  v_audit_after bigint;
  v_policies bigint;
  v_active boolean;
begin
  reset role;

  -- Guard the synthetic ids: a collision with a live pg_net response would make every settlement
  -- assertion below meaningless.
  if exists (select 1 from net._http_response r
              where r.id in (v_resp_a, v_resp_b, v_resp_c, v_resp_e, 900000005)) then
    raise exception 'v634 fixture unavailable: a live net._http_response already occupies 9000000xx';
  end if;

  -- Park anything production left pending, so every count below is about this fixture only.
  update public.platform_billing_reconcile_calls_v634
     set outcome = 'unknown', checked_at = now(),
         detail = jsonb_build_object('why', 'parked by the v634 rollback-only suite')
   where outcome = 'pending';

  -- ---------------------------------------------------------------------
  -- E1 · a non-2xx response settles the call to 'failed' and raises ONE alert.
  -- ---------------------------------------------------------------------
  insert into public.platform_billing_reconcile_calls_v634 (net_request_id, requested_at)
  values (v_resp_a, now() - interval '10 minutes') returning id into v_call_a;
  insert into net._http_response (id, status_code, content_type, headers, content, timed_out,
                                  error_msg, created)
  values (v_resp_a, 401, 'application/json', '{}'::jsonb,
          '{"error":"reconciliation_authentication_required"}', false, null, now());

  v_raised := app.check_billing_reconcile_calls_v634();
  if v_raised <> 1 then
    raise exception 'v634 E1: a 401 reconcile call raised % alerts, expected 1', v_raised;
  end if;
  select outcome, status_code into v_outcome, v_status
    from public.platform_billing_reconcile_calls_v634 where id = v_call_a;
  if v_outcome <> 'failed' or v_status <> 401 then
    raise exception 'v634 E1: a 401 call settled as %/% , expected failed/401', v_outcome, v_status;
  end if;
  select count(*) into v_open from public.platform_billing_alerts_v624
   where kind = 'reconcile_failed' and object_id = 'reconcile' and resolved_at is null;
  if v_open <> 1 then
    raise exception 'v634 E2: % open reconcile_failed alerts after one failure, expected 1', v_open;
  end if;

  -- ---------------------------------------------------------------------
  -- E3 · idempotency: nothing pending, nothing raised.
  -- ---------------------------------------------------------------------
  v_raised := app.check_billing_reconcile_calls_v634();
  if v_raised <> 0 then
    raise exception 'v634 E3: a re-run with nothing pending raised % alerts', v_raised;
  end if;

  -- ---------------------------------------------------------------------
  -- E4 · a SECOND failure does not queue a second alert — but does refresh the detail.
  -- ---------------------------------------------------------------------
  insert into public.platform_billing_reconcile_calls_v634 (net_request_id, requested_at)
  values (v_resp_b, now() - interval '5 minutes') returning id into v_call_b;
  insert into net._http_response (id, status_code, content_type, headers, content, timed_out,
                                  error_msg, created)
  values (v_resp_b, 500, 'application/json', '{}'::jsonb, '{"error":"boom"}', false, null, now());

  v_raised := app.check_billing_reconcile_calls_v634();
  if v_raised <> 1 then
    raise exception 'v634 E4: the second failure raised % , expected 1', v_raised;
  end if;
  select count(*) into v_open from public.platform_billing_alerts_v624
   where kind = 'reconcile_failed' and object_id = 'reconcile' and resolved_at is null;
  if v_open <> 1 then
    raise exception 'v634 E5: the reconcile_failed alert is not a singleton — % open rows', v_open;
  end if;
  select detail into v_detail from public.platform_billing_alerts_v624
   where kind = 'reconcile_failed' and object_id = 'reconcile' and resolved_at is null;
  if v_detail->>'status_code' <> '500' or (v_detail->>'call_id')::uuid <> v_call_b then
    raise exception 'v634 E6: the singleton alert kept a stale detail: %', v_detail;
  end if;

  -- ---------------------------------------------------------------------
  -- E7 · a success settles to 'succeeded' and self-heals the standing complaints.
  --      An unconfigured-vault alert is seeded first so both kinds are proven.
  -- ---------------------------------------------------------------------
  insert into public.platform_billing_alerts_v624 (kind, object_id, detail)
  values ('reconcile_unconfigured', 'vault',
          jsonb_build_object('why', 'v634 rollback-only fixture'))
  on conflict do nothing;

  select count(*) into v_open_before from public.platform_billing_alerts_v624
   where kind in ('reconcile_failed', 'reconcile_unconfigured') and resolved_at is null;
  if v_open_before < 2 then
    raise exception 'v634 E7: expected at least 2 open reconcile alerts before the success, got %',
      v_open_before;
  end if;
  select count(*) into v_audit_before from public.audit_log
   where action = 'BILLING_ALERT_AUTORESOLVED_V634';

  insert into public.platform_billing_reconcile_calls_v634 (net_request_id, requested_at)
  values (v_resp_c, now() - interval '1 minute') returning id into v_call_c;
  insert into net._http_response (id, status_code, content_type, headers, content, timed_out,
                                  error_msg, created)
  values (v_resp_c, 200, 'application/json', '{}'::jsonb, '{"ok":true}', false, null, now());

  v_raised := app.check_billing_reconcile_calls_v634();
  if v_raised <> 0 then
    raise exception 'v634 E8: a successful call raised % alerts, expected 0', v_raised;
  end if;
  select outcome, status_code into v_outcome, v_status
    from public.platform_billing_reconcile_calls_v634 where id = v_call_c;
  if v_outcome <> 'succeeded' or v_status <> 200 then
    raise exception 'v634 E9: a 200 call settled as %/%, expected succeeded/200', v_outcome, v_status;
  end if;

  select count(*) into v_open from public.platform_billing_alerts_v624
   where kind = 'reconcile_failed' and resolved_at is null;
  if v_open <> 0 then
    raise exception 'v634 E10: % reconcile_failed alerts survived a successful run', v_open;
  end if;
  select count(*) into v_open from public.platform_billing_alerts_v624
   where kind = 'reconcile_unconfigured' and resolved_at is null;
  if v_open <> 0 then
    raise exception 'v634 E11: % reconcile_unconfigured alerts survived a successful run', v_open;
  end if;

  select count(*) into v_audit_after from public.audit_log
   where action = 'BILLING_ALERT_AUTORESOLVED_V634';
  if v_audit_after - v_audit_before <> v_open_before then
    raise exception 'v634 E12: % auto-resolution audit rows for % resolved alerts',
      v_audit_after - v_audit_before, v_open_before;
  end if;

  -- ---------------------------------------------------------------------
  -- E13 · a silent call is judged on a clock: pending inside two hours...
  -- ---------------------------------------------------------------------
  insert into public.platform_billing_reconcile_calls_v634 (net_request_id, requested_at)
  values (900000005, now() - interval '30 minutes') returning id into v_call_d;
  v_raised := app.check_billing_reconcile_calls_v634();
  if v_raised <> 0 then
    raise exception 'v634 E13: a 30-minute-old silent call raised % alerts, expected 0', v_raised;
  end if;
  select outcome into v_outcome from public.platform_billing_reconcile_calls_v634 where id = v_call_d;
  if v_outcome <> 'pending' then
    raise exception 'v634 E13: a young silent call settled early as %', v_outcome;
  end if;

  -- ...and 'unknown' — fail-closed — once it is older than two hours.
  update public.platform_billing_reconcile_calls_v634
     set requested_at = now() - interval '3 hours' where id = v_call_d;
  v_raised := app.check_billing_reconcile_calls_v634();
  if v_raised <> 1 then
    raise exception 'v634 E14: an unanswered 3-hour-old call raised % alerts, expected 1', v_raised;
  end if;
  select outcome into v_outcome from public.platform_billing_reconcile_calls_v634 where id = v_call_d;
  if v_outcome <> 'unknown' then
    raise exception 'v634 E14: an unanswered 3-hour-old call settled as %, expected unknown', v_outcome;
  end if;
  select count(*) into v_open from public.platform_billing_alerts_v624
   where kind = 'reconcile_failed' and object_id = 'reconcile' and resolved_at is null;
  if v_open <> 1 then
    raise exception 'v634 E14: an unknown outcome left % open alerts, expected 1', v_open;
  end if;

  -- ---------------------------------------------------------------------
  -- E15 · the alert vocabulary learned 'reconcile_failed' and still refuses nonsense.
  -- ---------------------------------------------------------------------
  begin
    insert into public.platform_billing_alerts_v624 (kind, object_id, detail)
    values ('reconcile_nonsense_v634', 'probe', '{}'::jsonb);
    raise exception 'v634 E15: an unknown alert kind was accepted by the check constraint';
  exception when sqlstate '23514' then null;
  end;

  -- ---------------------------------------------------------------------
  -- E16 · the v624 detector settles pending calls and counts them.
  -- ---------------------------------------------------------------------
  insert into public.platform_billing_reconcile_calls_v634 (net_request_id, requested_at)
  values (v_resp_e, now() - interval '2 minutes') returning id into v_call_e;
  insert into net._http_response (id, status_code, content_type, headers, content, timed_out,
                                  error_msg, created)
  values (v_resp_e, 502, 'application/json', '{}'::jsonb, '{"error":"bad gateway"}', false, null, now());

  v_raised := app.detect_billing_alerts_v624();
  if v_raised < 1 then
    raise exception 'v634 E16: the v624 detector returned %, excluding the failing reconcile call',
      v_raised;
  end if;
  select outcome into v_outcome from public.platform_billing_reconcile_calls_v634 where id = v_call_e;
  if v_outcome <> 'failed' then
    raise exception 'v634 E16: the detector left a failing call as %', v_outcome;
  end if;

  -- ---------------------------------------------------------------------
  -- E17 · the call ledger is server-only: RLS on, zero policies, no browser grant.
  -- ---------------------------------------------------------------------
  if not coalesce((
    select c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = 'platform_billing_reconcile_calls_v634'
  ), false) then
    raise exception 'v634 E17: the reconcile call ledger is missing or has RLS disabled';
  end if;
  select count(*) into v_policies from pg_policies
   where schemaname = 'public' and tablename = 'platform_billing_reconcile_calls_v634';
  if v_policies <> 0 then
    raise exception 'v634 E17: the reconcile call ledger carries % policies, expected 0', v_policies;
  end if;
  if has_table_privilege('authenticated', 'public.platform_billing_reconcile_calls_v634', 'SELECT')
     or has_table_privilege('authenticated', 'public.platform_billing_reconcile_calls_v634', 'INSERT')
     or has_table_privilege('anon', 'public.platform_billing_reconcile_calls_v634', 'SELECT') then
    raise exception 'v634 E17: the reconcile call ledger is directly browser-reachable';
  end if;
  if exists (
    select 1 from information_schema.role_table_grants
     where table_schema = 'public'
       and table_name = 'platform_billing_reconcile_calls_v634'
       and grantee in ('authenticated', 'anon', 'PUBLIC')
  ) then
    raise exception 'v634 E17: the reconcile call ledger holds a browser-role grant';
  end if;

  -- ---------------------------------------------------------------------
  -- E18 · the checker is not callable from a session.
  -- ---------------------------------------------------------------------
  if has_function_privilege('authenticated', 'app.check_billing_reconcile_calls_v634()', 'EXECUTE')
     or has_function_privilege('anon', 'app.check_billing_reconcile_calls_v634()', 'EXECUTE') then
    raise exception 'v634 E18: the reconcile checker is executable from a browser session';
  end if;

  -- ---------------------------------------------------------------------
  -- E19 · the checker is scheduled, not aspirational.
  -- ---------------------------------------------------------------------
  if to_regnamespace('cron') is not null then
    select active into v_active from cron.job where jobname = 'nestly-v634-reconcile-check';
    if v_active is null then
      raise exception 'v634 E19: the nestly-v634-reconcile-check schedule is missing';
    end if;
    if not v_active then
      raise exception 'v634 E19: the nestly-v634-reconcile-check schedule exists but is inactive';
    end if;
  end if;

  raise notice 'v634 reconcile failure visibility suite: ALL PASS';
end
$v634_main$;

reset role;
rollback;
