-- nestly_v591 -- webhook consumers process each event once, and sv tender
-- release stops writing an audit row when there is nothing to release.
--
-- DEFECT 1 -- REPEATED SCANNING OF ALREADY-PROCESSED ROWS.
-- Three workers read public.whatsapp_webhook_events with the identical
-- predicate `received_at > now() - interval '2 days'` and NO record of what
-- they had already processed:
--     app.support_ingest_status_v535   (* * * * *  -> 1,440 runs/day)
--     app.v551_ingest_retention_status (*/5        ->   288 runs/day)
--     app.v551_ingest_retention_optout (*/10       ->   144 runs/day)
-- Every run re-expanded the same envelopes through three nested
-- jsonb_array_elements and re-issued the same UPDATEs -- 1,872 full rescans a
-- day. The v551 comment called re-application "free"; it is idempotent, but it
-- is not free.
--
-- WHY NOT REUSE whatsapp_webhook_events.processing_status: that flag is owned
-- by the v531 inbound router. Four consumers read this table and each needs its
-- own high-water mark, so one shared column cannot express "routed but status
-- not yet ingested". A per-consumer marker table is the smallest correct shape.
--
-- WHY NO NEW INDEX ON whatsapp_webhook_events: the marker table's PRIMARY KEY
-- (event_id, consumer) already serves the anti-join, and the outer scan is
-- bounded by the v528 7-day retention purge. Measured: 12 rows. Deliberate.
--
-- REUSED EXISTING SCHEMA: entry_kinds is already computed by the v504 webhook
-- from exactly the condition each consumer tests (value.statuses /
-- value.messages is an array). Verified against prod: 6 rows ['statuses'] all
-- with statuses, 3 ['messages'] all with messages, 3 ['other'] with neither.
-- Filtering on it is equivalent, not a narrowing.
--
-- RETRY AND LOSS SAFETY: a completion marker is written ONLY on success and in
-- the SAME subtransaction as the processing, so a failed event keeps no marker
-- and is retried by the next sweep. A failure records attempts + last_error and
-- retries until v591_max_attempts, after which it stops burning cycles but
-- REMAINS VISIBLE (processed_at still null) rather than silently vanishing. The
-- webhook's payload_sha256 dedupe stays authoritative and is untouched.
--
-- DEFECT 2 -- BUSINESS WRITES DURING AN EMPTY RUN.
-- app.run_sv_tender_release called app.sv_automation_begin() before looking for
-- work, so all 480 daily runs inserted an sv_automation_runs row and updated it
-- at finish -- 16,254 rows for 16,174 runs, 1:1, never purged. The audit trail
-- for PRODUCTIVE runs and for failures is preserved exactly; only the no-work
-- case stops writing. The existing partial index checkout_sv_tenders_active_uk
-- (business_id, account_id) WHERE status = 'reserved' serves the probe.
--
-- Applied to production 2026-08-28 as nestly_v591a..v591e.
-- Proven in prod by a rolled-back fixture (all five assertions passed):
--   T1 a new status callback is applied (rank advances to 'delivered')
--   T2 exactly one completion marker is written
--   T3 a completed event is NOT rescanned
--   T4 a failed event IS re-claimed on the next sweep
--   T5 at the attempts cap it stops being claimed but stays visible
-- And: sv_automation_runs 16,266 -> 16,266 across an empty tender-release run.

begin;

create table if not exists public.whatsapp_webhook_event_consumers (
  event_id     uuid        not null
                 references public.whatsapp_webhook_events(id) on delete cascade,
  consumer     text        not null,
  processed_at timestamptz,
  attempts     integer     not null default 0,
  last_error   text,
  first_seen_at timestamptz not null default now(),
  primary key (event_id, consumer)
);

comment on table public.whatsapp_webhook_event_consumers is
  'v591: high-water mark per (webhook event, consumer). processed_at IS NULL means attempted and failed -- still retryable, never silently dropped.';

-- Internal queue bookkeeping written only by SECURITY DEFINER workers owned by
-- postgres; service_role bypasses RLS. RLS on with NO policy therefore denies
-- anon and authenticated outright, matching the super_admins pattern.
alter table public.whatsapp_webhook_event_consumers enable row level security;
revoke all on table public.whatsapp_webhook_event_consumers from public, anon, authenticated;

create or replace function app.v591_max_attempts() returns integer
language sql immutable parallel safe as $$ select 5 $$;
revoke all on function app.v591_max_attempts() from public, anon, authenticated;

commit;

-- The three worker bodies and app.run_sv_tender_release are reproduced from
-- production via pg_get_functiondef in
-- db/migrations/20260828_nestly_v591_bodies.sql to keep this file readable;
-- both were applied together and neither is valid without the other.
