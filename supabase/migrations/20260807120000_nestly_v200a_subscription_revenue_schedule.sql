-- NESTLY v200a — the "automatic" half of subscription revenue.
--
-- Runs daily at 00:20 SGT (16:20 UTC), just after midnight in Singapore, so a
-- month of service that begins today is recognised today rather than a day late.
--
-- Re-running is a no-op by construction: every posting is keyed to a
-- deterministic source id and app.platform_post_journal_v147 is idempotent on
-- (source_type, source_id). A missed day therefore self-heals on the next run —
-- there is no backfill to remember and no way for a double run to double-post.

begin;

select cron.schedule(
  'platform-subscription-revenue-v200',
  '20 16 * * *',
  $cron$select public.platform_run_subscription_revenue_v200();$cron$
);

commit;
