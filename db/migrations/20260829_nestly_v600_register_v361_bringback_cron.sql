begin;

-- nestly_v600_register_v361_bringback_cron -- registers in source the ONE remaining live
-- production cron job that was created manually rather than by a reproducible migration:
-- cron job nestly-v361-bringback-issue-daily (project gadpooereceldfpfxsod), which runs
--   select app.run_bringback_issue_v361();
-- daily at 03:20 UTC. See docs/qa/SECURITY-CRON-FOLLOWUP-2026-08-29.md section 2.2 ("Maintain
-- it, but register it in source") and section 2.3 ("Recovery rule").
--
-- Unlike nestly_v590 through nestly_v592 (which mirror migrations already applied to
-- production and must NEVER be re-applied), this migration is meant to be applied. It is
-- written idempotently precisely because production already has the job: applying it there is
-- a verified no-op, while applying it to a fresh database creates the job for the first time.
-- Note for whoever applies this: the deploy tooling assigns the actual ledger version at apply
-- time (see nestly_v599, whose proposed 20260829105315 stamp was superseded by the ledger's
-- real 20260829094129 -- this file's own supabase/migrations timestamp may likewise be
-- re-stamped on apply and should not be assumed authoritative until confirmed against
-- supabase_migrations.schema_migrations).
--
-- app.run_bringback_issue_v361() itself is unchanged and already lives in source (v361, the
-- 2026-08-16 rewards wave). This migration only adds the missing cron.schedule call.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'nestly-v361-bringback-issue-daily'
  ) THEN
    PERFORM cron.schedule(
      'nestly-v361-bringback-issue-daily',
      '20 3 * * *',
      $cron$select app.run_bringback_issue_v361();$cron$
    );
  END IF;
END
$$;

commit;
