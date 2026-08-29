-- nestly_v601 -- nine cron jobs whose feature is off, done, or delivers to nowhere go dormant.
--
-- Owner-approved 2026-08-29 (launch-audit Phase C; docs/qa/SECURITY-CRON-FOLLOWUP-2026-08-29.md
-- section 7, docs/qa/SECURITY-CRON-LAUNCH-AUDIT-2026-08-29.md section 9). DEACTIVATE, not
-- unschedule: cron.alter_job(active=>false) keeps the registration and its history so any job
-- reactivates with one call when its feature ships. Idempotent -- only currently-active rows are
-- touched, and a jobname absent from cron.job is simply skipped.
--
-- Before-state captured 2026-08-29 (all nine active, all recent runs succeeding):
--   6  frenly-outbox-sweep            */2   -- zero outbox/capture activity in 30d; the only
--                                            producer (app.ps1b_execute_event 'send_notification')
--                                            last fired 2026-07-23, synthetic era; nothing reads
--                                            the captured_messages sink. A future pending row
--                                            waits harmlessly for a real delivery provider.
--   8  frenly-sv-expiry               daily -- zero live stored-value businesses
--   9  frenly-sv-tender-release       */3   -- zero reserved tenders (v591e already stops empty writes)
--   10 frenly-sv-reconciliation       daily -- no live stored-value authority yet
--   24 frenly-programme-pot-migrations */10 -- finite V312 queue fully drained (zero pending/running)
--   28 nestly-v511-work-reopen        */10  -- Work OS has zero work rows
--   44 nestly-v551-retention-dispatch */5   -- whatsapp_retention_sends=false
--   45 nestly-v551-retention-status-ingest */5 -- same flag
--   46 nestly-v551-retention-optout   */10  -- same flag; compliance-critical ONLY once sends exist
--
-- Reactivation rule: each job comes back WITH its feature (stored value pilot, Work OS launch,
-- whatsapp_retention_sends=true, a real comms delivery provider, a new pot-migration queue), via
-- a migration that calls cron.alter_job(active=>true) -- never by hand.

begin;

do $$
declare
  j record;
  n int := 0;
begin
  for j in
    select jobid, jobname from cron.job
    where jobname in (
      'frenly-outbox-sweep',
      'frenly-sv-expiry',
      'frenly-sv-tender-release',
      'frenly-sv-reconciliation',
      'frenly-programme-pot-migrations',
      'nestly-v511-work-reopen',
      'nestly-v551-retention-dispatch',
      'nestly-v551-retention-status-ingest',
      'nestly-v551-retention-optout'
    ) and active
  loop
    perform cron.alter_job(j.jobid, active => false);
    n := n + 1;
  end loop;
  raise notice 'v601: deactivated % cron job(s)', n;
end
$$;

commit;
