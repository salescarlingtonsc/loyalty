-- EXECUTED acceptance fixture for nestly_v823 (db/migrations/20261007_nestly_v823_reconcile_call_timeout.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --migrated-only --filter=v823
--
-- WHY THIS EXISTS. The nightly reconciliation call used pg_net's 5 s default timeout; a cold edge
-- worker (3.4 s boot) plus a 1.7 s run overshot it on 2026-09-07 and a CLEAN run was settled as
-- "timed out", raising nestly_v821's failure alerts for a success. v823 waits 60 s.
--
-- ASSERTIONS (rows, with a fatal gate at the end):
--   T1  The dispatcher passes timeout_milliseconds := 60000 to net.http_post.
--   T2  The dispatcher still targets /functions/v1/stripe-billing-reconcile and writes its receipt row.
--   T3  Calling the dispatcher with the vault configured writes exactly one pending call row.
--   T4  anon and authenticated cannot execute the dispatcher.
--
-- Rolled back.
begin;

create temp table v823_out(seq integer, step text, outcome text, detail text) on commit drop;

create or replace function pg_temp.v823_note(
  p_seq integer, p_step text, p_ok boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into v823_out values (p_seq, p_step, case when p_ok then 'PASS' else 'FAIL' end, p_detail);
end
$$;

do $v823_test$
declare
  v_def text;
  v_before bigint;
  v_after bigint;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'run_billing_reconcile_call_v624';

  perform pg_temp.v823_note(1, 'T1 dispatcher waits 60 s for a cold reconciler',
    position('timeout_milliseconds := 60000' in v_def) > 0);

  perform pg_temp.v823_note(2, 'T2 dispatcher still targets the reconciler and writes its receipt',
    position('/functions/v1/stripe-billing-reconcile' in v_def) > 0
    and position('insert into public.platform_billing_reconcile_calls_v634 (net_request_id)' in v_def) > 0);

  -- T3: the vault stand-in may or may not carry the two secrets in the scratch cluster; seed them
  -- so the dispatch path (not the 'reconcile_unconfigured' path) is the one exercised.
  if not exists (select 1 from vault.decrypted_secrets where name = 'v176_supabase_url') then
    perform vault.create_secret('http://stub.local', 'v176_supabase_url');
  end if;
  if not exists (select 1 from vault.decrypted_secrets where name = 'v624_reconcile_secret') then
    perform vault.create_secret('stub-secret', 'v624_reconcile_secret');
  end if;
  select count(*) into v_before from public.platform_billing_reconcile_calls_v634;
  perform app.run_billing_reconcile_call_v624();
  select count(*) into v_after from public.platform_billing_reconcile_calls_v634;
  perform pg_temp.v823_note(3, 'T3 one dispatch writes exactly one pending receipt row',
    v_after = v_before + 1
    and exists (select 1 from public.platform_billing_reconcile_calls_v634
                 where outcome = 'pending' order by requested_at desc limit 1),
    'before=' || v_before || ' after=' || v_after);

  perform pg_temp.v823_note(4, 'T4 tenant-facing roles cannot dispatch the reconciler',
    not pg_catalog.has_function_privilege('anon', 'app.run_billing_reconcile_call_v624()', 'execute')
    and not pg_catalog.has_function_privilege('authenticated', 'app.run_billing_reconcile_call_v624()', 'execute'));
end
$v823_test$;

select seq, step, outcome, detail from v823_out order by seq;

do $gate$
declare v_failed integer;
begin
  select count(*) into v_failed from v823_out where outcome <> 'PASS';
  if v_failed > 0 then
    raise exception 'nestly_v823 acceptance: % assertion(s) FAILED', v_failed;
  end if;
end
$gate$;

rollback;
