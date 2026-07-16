# 20260716 frenly_v3_engine (applied remotely via Supabase MCP)
Points expiry: loyalty_programs.expiry_mode(none|inactivity|fixed)+expiry_days;
points_batches (backfilled, FIFO-drained); app.run_points_expiry() + pg_cron daily
19:00 UTC (03:00 SGT) + run_expiry_now(business) RPC.
Referrals: referral_programs (enabled, reward_cents, min_spend_cents);
clients.referral_code (auto-gen trigger, backfilled, unique); one referral per
referred client; on_sale_recorded now pays referrer on first qualifying sale.
Consent: consents append-only events. Audit: audit_log + triggers on credit_ledger,
points_ledger, reward_grants, referrals/retention/booking updates.
redeem_points + new adjust_points(owner-only) drain batches oldest-first.
All businesses: +referrals module. Full SQL: Supabase migration history
(supabase_migrations.schema_migrations, version 2026-07-16, name frenly_v3_engine).
