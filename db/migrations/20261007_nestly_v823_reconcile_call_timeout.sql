-- NESTLY v823 — the nightly reconciliation call waits for a cold function.
--
-- WHY THIS EXISTS. app.run_billing_reconcile_call_v624() dispatches the Stripe reconciler through
-- net.http_post with pg_net's DEFAULT timeout of 5000 ms. The reconciler is invoked once a night, so
-- its worker is always cold: on 2026-09-07 17:35 UTC (production, right after nestly_v822's deploy)
-- the request was accepted at 17:35:08.14, the function started at 17:35:11.57 (a 3.4 s cold boot)
-- and finished CLEAN at 17:35:13.29 — 5.15 s after the request. pg_net had already given up: the
-- receipt says timed_out=true, app.check_billing_reconcile_calls_v634() settled the call as
-- outcome='failed' ("the reconciliation request timed out"), and nestly_v821's alerts fired for a
-- run that had in fact succeeded. Every nightly run sits on that 5 s boundary. A false failure
-- alert most nights is the exact noise nestly_v821 was written to remove.
--
-- WHAT THIS MIGRATION DOES. Restates app.run_billing_reconcile_call_v624() character-for-character
-- from the live production definition read on 2026-09-07, adding ONE argument to net.http_post:
-- timeout_milliseconds := 60000. The reconciler's own bound is MAX_PAGES_PER_STREAM per invocation;
-- 60 s is ample for a cold boot plus a bounded run and well inside pg_net's 6-hour receipt window.
-- Nothing else moves: the vault reads, the 'reconcile_unconfigured' alert, the receipt row.
--
-- WHAT THIS MIGRATION DOES NOT TOUCH. The settle logic, the alert family, the cron schedule.
--
-- FORM. Full restatement guarded by a pre-flight anchor check so a drifted live body is refused,
-- not silently reverted. ACL restated. Verified in-transaction by reading the new body back.
--
-- ACCEPTANCE: db/tests/v823_reconcile_call_timeout.sql (and the identical db/tests/executed/ copy).
-- Replay: LC_ALL=C node scripts/db-tests/run.mjs --migrated-only --filter=v823

begin;
set local search_path = pg_catalog, public, app, pg_temp;

do $v823_pre$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'run_billing_reconcile_call_v624';
  if v_def is null then
    raise exception 'v823: app.run_billing_reconcile_call_v624() is not present -- nestly_v624/v634 must be applied first';
  end if;
  if position('timeout_milliseconds := 60000' in v_def) > 0 then
    raise notice 'v823: the dispatcher already waits 60 s, restating anyway';
  end if;
  if position('/functions/v1/stripe-billing-reconcile' in v_def) = 0
     or position('x-nestly-reconciliation-secret' in v_def) = 0
     or position('insert into public.platform_billing_reconcile_calls_v634 (net_request_id)' in v_def) = 0
     or position('''reconcile_unconfigured'', ''vault''' in v_def) = 0 then
    raise exception 'v823: the live dispatcher body is not the one v823 was written against -- production has drifted; re-read pg_get_functiondef before replacing it';
  end if;
end
$v823_pre$;

create or replace function app.run_billing_reconcile_call_v624()
returns void
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_url text;
  v_secret text;
  v_request_id bigint;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'v176_supabase_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'v624_reconcile_secret';
  if v_url is null or v_secret is null then
    insert into public.platform_billing_alerts_v624 (kind, object_id, detail)
    values ('reconcile_unconfigured', 'vault',
            jsonb_build_object('missing_url', v_url is null, 'missing_secret', v_secret is null))
    on conflict do nothing;
    return;
  end if;
  select net.http_post(
    url := v_url || '/functions/v1/stripe-billing-reconcile',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-nestly-reconciliation-secret', v_secret
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  ) into v_request_id;
  insert into public.platform_billing_reconcile_calls_v634 (net_request_id)
  values (v_request_id);
end
$function$;

revoke all on function app.run_billing_reconcile_call_v624() from public, anon, authenticated;

do $v823_verify$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'run_billing_reconcile_call_v624';
  if position('timeout_milliseconds := 60000' in v_def) = 0 then
    raise exception 'v823 verify: the dispatcher still uses the pg_net default timeout';
  end if;
  if position('/functions/v1/stripe-billing-reconcile' in v_def) = 0
     or position('insert into public.platform_billing_reconcile_calls_v634 (net_request_id)' in v_def) = 0 then
    raise exception 'v823 verify: the dispatcher lost its target or its receipt row';
  end if;
  if pg_catalog.has_function_privilege('anon', 'app.run_billing_reconcile_call_v624()', 'execute')
     or pg_catalog.has_function_privilege('authenticated', 'app.run_billing_reconcile_call_v624()', 'execute') then
    raise exception 'v823 verify: a tenant-facing role can dispatch the billing reconciler';
  end if;
end
$v823_verify$;

commit;
