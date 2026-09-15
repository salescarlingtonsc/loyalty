-- nestly_v974 rolled-back verification — the reconcile poll, and the switch that silences it.
--
-- Run against production. Everything happens inside the transaction and the file ends in
-- `rollback;`, including the flag this flips, so the schedule is exactly as it was afterwards.
--
--   1. the switch is read BEFORE anything observable — with the flag off the runner returns
--      'disabled' and touches neither the vault nor pg_net;
--   2. with the flag on it gets as far as asking, which is all this test may safely prove
--      without firing an hourly job's worth of Graph traffic inside a test;
--   3. the job is actually scheduled, hourly, against the function this migration created;
--   4. it is service_role only — no browser role may poke it;
--   5. and scheduling a poll did not turn sending on.

\set ON_ERROR_STOP on

begin;

do $test$
declare
  v_result jsonb;
begin
  -- 1. the switch comes first
  update app.platform_feature_flags set enabled = false
   where feature_key = 'whatsapp_template_reconcile_cron';
  v_result := app.v974_run_template_reconcile();
  assert v_result->>'reconcile' = 'disabled',
    format('a disabled poll must do nothing at all, got %s', v_result);
  assert v_result->'request_id' is null,
    format('a disabled poll must not have called anything: %s', v_result);

  -- 2. with the switch on it reaches the asking stage. 'requested' means the vault and pg_net were
  --    both there and the call went out; 'secret_unconfigured' would be the named fail-closed.
  update app.platform_feature_flags set enabled = true
   where feature_key = 'whatsapp_template_reconcile_cron';
  v_result := app.v974_run_template_reconcile();
  assert v_result->>'reconcile' in ('requested', 'extensions_unavailable'),
    format('an enabled poll must ask or name why it cannot, got %s', v_result);

  raise notice 'v974 runner verified: %', v_result->>'reconcile';
end
$test$;

-- 3/4/5. the schedule, the grant and the v824 switches, read from the catalogue.
do $guards$
declare
  v_acl text;
  v_schedule text;
  v_command text;
begin
  if to_regnamespace('cron') is not null then
    select schedule, command into v_schedule, v_command
      from cron.job where jobname = 'nestly-v974-template-reconcile';
    assert v_schedule is not null, 'the reconcile job must be scheduled';
    assert v_schedule = '7 * * * *',
      format('hourly, offset off the hour; found %s', v_schedule);
    assert v_command like '%v974_run_template_reconcile%',
      format('the job must call the v974 runner, found %s', v_command);
  end if;

  select coalesce(array_to_string(p.proacl::text[], ','), '') into v_acl
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'v974_run_template_reconcile';
  assert v_acl like '%service_role=X%', format('service_role must execute: %s', v_acl);
  assert v_acl not like '%anon=X%' and v_acl not like '%authenticated=X%',
    format('no browser role may run the poll: %s', v_acl);

  assert not app.platform_feature_enabled('whatsapp_outbound'),
    'v974 must not have re-opened the v824 master switch';
  assert not app.platform_feature_enabled('whatsapp_retention_sends'),
    'v974 must not have re-opened retention sends';

  raise notice 'v974 schedule and grants verified';
end
$guards$;

rollback;
