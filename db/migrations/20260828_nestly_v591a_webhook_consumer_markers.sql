begin;

-- nestly_v591a_webhook_consumer_markers -- VERBATIM MIRROR of an already-applied production
-- migration (project gadpooereceldfpfxsod, ledger version 20260828141250), recovered
-- read-only on 2026-08-29 during source/production drift closure. See
-- docs/qa/SECURITY-CRON-FOLLOWUP-2026-08-29.md section 2 and the exact capture in
-- docs/qa/audit-artifacts/v590-v592-live-definitions.sql /
-- docs/qa/audit-artifacts/v590-v592-live-object-catalog.csv.
--
-- MUST NOT be re-applied to production. Production already carries this migration's ledger
-- row; record it locally instead with:
--   supabase migration repair --status applied 20260828141250
--
-- First of the five v591 migrations. Creates the per-(webhook event, consumer) high-water-mark
-- table that the next three migrations (591b/c/d) anti-join against so a WhatsApp webhook
-- callback is claimed by each consumer at most once, plus the shared retry-cap helper they all
-- call. The table has RLS enabled and NO policies at all -- it is server/service-role only,
-- never browser-reachable.

create table if not exists public.whatsapp_webhook_event_consumers (
  event_id     uuid not null references public.whatsapp_webhook_events(id) on delete cascade,
  consumer     text not null,
  processed_at timestamptz,
  attempts     integer not null default 0,
  last_error   text,
  first_seen_at timestamptz not null default now(),
  primary key (event_id, consumer)
);

comment on table public.whatsapp_webhook_event_consumers is
  'v591: high-water mark per (webhook event, consumer). processed_at IS NULL means attempted and failed -- still retryable, never silently dropped.';

alter table public.whatsapp_webhook_event_consumers enable row level security;
revoke all on table public.whatsapp_webhook_event_consumers from public, anon, authenticated;
grant all on table public.whatsapp_webhook_event_consumers to service_role;

CREATE OR REPLACE FUNCTION app.v591_max_attempts()
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$ select 5 $function$;

revoke all on function app.v591_max_attempts() from public, anon, authenticated;

commit;
