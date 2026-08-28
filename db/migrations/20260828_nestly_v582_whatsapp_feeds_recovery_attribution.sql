-- ============================================================================
-- nestly_v582 — A DELIVERED RETENTION WHATSAPP IS AN INTERVENTION
--
-- Today the recovery report (get_recovery_report_v550) counts two kinds of
-- intervention: a bring-back voucher grant (bringback_grants_v361) and a
-- 'message' outreach row that a staff member records by hand from the
-- attention list (record_attention_outreach_v550). The v551 lane sends the
-- bring-back message automatically over WhatsApp and feeds NOTHING into the
-- report. This migration closes that gap. It invents no new mathematics: the
-- window, the 14-day lapse gate, the one-intervention-per-client rule, the
-- baseline cohort and the net formula are all left exactly as v550 wrote them.
-- The only new thing is one more row in the table the report already reads.
--
-- ---------------------------------------------------------------------------
-- 1. WHICH LIFECYCLE POINT — 'delivered', not 'sent'. CHOSEN AND COMMITTED.
-- ---------------------------------------------------------------------------
-- The report asks a causal question: did contacting this lapsed customer bring
-- them back? A message that never reached the customer cannot have caused
-- anything, so it is not an intervention — it is an attempt.
--
--   'sent'      = Meta ACCEPTED the payload. That is a statement about our
--                 relationship with Meta, not about the customer. The handset
--                 may be off, the number reassigned, the account deleted, the
--                 business blocked. Nothing reached anybody.
--   'delivered' = Meta says the message landed on the handset. This is the
--                 weakest claim that still means "the customer could see it".
--
-- The argument FOR 'sent' is that 'delivered' sometimes never arrives even
-- when the message was seen, so we will under-count. That is true, and it is
-- the reason to choose 'delivered' anyway: the two error directions are not
-- symmetric for an owner-facing revenue claim.
--
--   * Counting 'sent' ADDS rows to `treated` that were never interventions.
--     Two harms. (a) It is a false claim on the face of the report — "we
--     contacted 40 lapsed customers" when 6 of them were never contacted.
--     (b) The report keeps exactly ONE intervention per client per window
--     (distinct on client_id, earliest first). A never-delivered 'sent' would
--     SQUAT that single slot and shut out a later message that did land.
--   * Counting 'delivered' only DROPS rows we cannot prove landed. `treated`
--     shrinks; every row left in it is one we can defend line by line. The
--     report understates the lane's reach and never overstates it.
--
-- Understating what we did is a survivable error in a revenue attribution
-- report shown to a paying merchant. Overstating it is not. We take
-- 'delivered'.
--
-- 'read' (rank 40) strictly implies the message reached the handset, so a
-- read-before-delivered callback — Meta does deliver status events out of
-- order — records the outreach too. The trigger is therefore "the send's
-- persisted rank first reaches delivered-or-better", not the literal string.
--
-- NOTHING is recorded at queued, processing, sent, suppressed, failed,
-- undeliverable, template_fault, config_fault or failed_retries_exhausted.
-- Every one of those means the customer was not reached. Note that v551 ranks
-- all terminal faults at 25, BELOW delivered (30), precisely so a late failure
-- callback cannot roll back a confirmed delivery — that ordering is what makes
-- this trigger safe to express as a rank threshold.
--
-- ---------------------------------------------------------------------------
-- 2. IDEMPOTENCY — four layers, because the day-unique key alone is NOT enough
-- ---------------------------------------------------------------------------
-- attention_outreach_v550 already carries UNIQUE (business_id, client_id,
-- occurred_on). That is a real defence but it is the table's OWN editorial
-- rule ("one outreach per customer per Singapore day"), not a send-level
-- identity, and it has a hole: a message delivered at 23:59 SGT and read at
-- 00:01 SGT the next day falls on TWO different occurred_on values, so the day
-- key would happily admit a second row for one message. Layers, therefore:
--
--   (a) EDGE-TRIGGERED ON PERSISTED STATE — and this layer alone is sufficient
--       for every sequence the CURRENT ingest can produce. The UPDATE only
--       fires when it actually advances the row (status_rank < new rank), and
--       we now capture the PRE-update rank in that same statement, recording
--       outreach only on the transition from below-delivered to
--       delivered-or-better. A duplicate webhook, a second identical callback,
--       or a full re-ingest of the 2-day window replays a state that no longer
--       advances anything, so the UPDATE matches zero rows and the recorder is
--       never called. And delivered (30) -> read (40), which DOES advance a
--       second time, is refused too: its pre-rank is already >= 30, so it is
--       not the edge. Derived from committed state, so it survives a crash
--       mid-sweep. (This was measured, not assumed: with the send-level guard
--       of (b) deliberately removed, the delivered-then-read case still
--       produced exactly one row.)
--   (b) SEND-LEVEL IDENTITY. New nullable column retention_send_id with a
--       partial UNIQUE index, and a NOT EXISTS on it inside the recorder.
--       This is NOT load-bearing for the ingest path today — (a) already is.
--       It is here because (a) is a property of ONE call site: it binds the
--       ingest's control flow, not the recorder itself. Any second caller, any
--       backfill, any future replay tool would be bounded by nothing at all
--       across an SG-day boundary, because the day key cannot express "one row
--       per send" when a message is dated 23:59 on one day and re-recorded
--       00:01 on the next. (b) makes the RECORDER idempotent, so the guarantee
--       does not depend on who calls it. Test 08 exercises it directly, and it
--       goes red when the guard is removed.
--   (c) THE TABLE'S OWN RULE. ON CONFLICT (business_id, client_id,
--       occurred_on) DO NOTHING, so a WhatsApp delivery and a staff member's
--       manual attention-list tap on the same customer on the same day still
--       collapse to one row, exactly as the table intends. The message did not
--       become two interventions because it arrived over two routes.
--   (d) CONCURRENCY. Two ingest workers racing past (b)'s NOT EXISTS both
--       reach the index; the loser gets 23505 and we swallow it. Losing the
--       race is the correct outcome — the row exists.
--
-- The recorder can therefore be called any number of times for any send and
-- leaves at most one row. It never raises: the surrounding v551 ingest wraps
-- each event in `exception when others then null`, and a recorder that threw
-- would silently abort the delivery status update it rides on.
--
-- ---------------------------------------------------------------------------
-- 3. CONSTRAINTS THAT BLOCKED THE OBVIOUS SHAPE — WIDENED, DECLARED HERE
-- ---------------------------------------------------------------------------
-- attention_outreach_v550 as shipped in v550 is single-valued on both labels:
--     CHECK (channel = 'whatsapp_manual')
--     CHECK (source  = 'attention_list')
-- so the requested channel='whatsapp' was NOT permitted. Both CHECKs are
-- widened here. This is stated rather than done quietly because it is a
-- loosening of an evidence table's shape:
--     channel: 'whatsapp_manual' | 'whatsapp'
--     source:  'attention_list'  | 'retention_whatsapp'
-- The widening is purely additive — every existing row stays valid, no row is
-- rewritten (the immutability trigger would forbid that anyway), and
-- get_recovery_report_v550 reads neither column, so no reported number moves
-- because of the widening itself. The alternative — reusing 'whatsapp_manual'
-- / 'attention_list' for automated sends — was rejected: it would make a
-- staff member's deliberate tap and a machine's automatic send permanently
-- indistinguishable in the audit record.
--
-- ---------------------------------------------------------------------------
-- 4. THE APPOINTMENT LANE IS NOT TOUCHED, AND CANNOT BE
-- ---------------------------------------------------------------------------
-- whatsapp_template_sends_v557 is transactional (confirmations, reminders,
-- reschedules). A reminder that a customer receives is not an attempt to win
-- them back and must never enter recovery attribution. The only outreach
-- write added here lives inside app.v551_ingest_retention_status, and the
-- recorder resolves its business/client BY SELECTING FROM
-- retention_sends_v551. The two lanes share the whatsapp_webhook_events feed,
-- but an appointment wamid matches no retention_sends_v551 row, so the ingest
-- UPDATE affects zero rows, `found` is false, and the recorder is not called.
-- v557's own claim/report pair (internal_whatsapp_claim_template_sends_v557 /
-- internal_whatsapp_report_template_send_v557) is not modified by this
-- migration and contains no reference to attention_outreach_v550. Test 07
-- proves it against a forged appointment callback.
--
-- ---------------------------------------------------------------------------
-- 5. WHAT THIS DOES AND DOES NOT MOVE IN THE REPORT
-- ---------------------------------------------------------------------------
-- Every retention send hangs off a bring-back grant (retention_sends_v551
-- .grant_id NOT NULL -> bringback_grants_v361), and the grant is always
-- EARLIER than the delivery. The report picks one intervention per client
-- ordered by time, so where both fall inside the window the voucher still
-- wins and the counts do not move at all. The new row earns its place in two
-- narrower places: it is the intervention when the grant predates the report
-- window but the delivery falls inside it, and it is standing evidence that
-- the message actually reached a handset — which is what the whole lane was
-- otherwise unable to prove.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 3a. widen the two single-valued CHECKs (additive; see header §3)
-- ---------------------------------------------------------------------------
alter table public.attention_outreach_v550
  drop constraint attention_outreach_v550_channel_check;
alter table public.attention_outreach_v550
  add constraint attention_outreach_v550_channel_check
  check (channel in ('whatsapp_manual', 'whatsapp'));

alter table public.attention_outreach_v550
  drop constraint attention_outreach_v550_source_check;
alter table public.attention_outreach_v550
  add constraint attention_outreach_v550_source_check
  check (source in ('attention_list', 'retention_whatsapp'));

-- ---------------------------------------------------------------------------
-- 2b. send-level identity for automated rows (NULL for every manual row)
-- ---------------------------------------------------------------------------
-- DELIBERATELY NOT A FOREIGN KEY. Measured against prod, not assumed: with
-- `references retention_sends_v551(id) on delete set null` in place, deleting a
-- bring-back grant cascades to its send, whose ON DELETE SET NULL issues an
-- UPDATE against attention_outreach_v550 — and the v550 immutability trigger
-- refuses it with 42501. One outreach row would have made its grant, its
-- campaign and its client permanently undeletable. An immutable evidence table
-- must not be mutable by an upstream delete, so the column is a plain pointer.
-- The row survives its send; the report never joins through it; and the
-- business_id/client_id FKs still cascade, so a deleted customer takes their
-- evidence with them exactly as before.
alter table public.attention_outreach_v550
  add column if not exists retention_send_id uuid;

alter table public.attention_outreach_v550
  drop constraint if exists attention_outreach_v550_retention_send_id_fkey;

comment on column public.attention_outreach_v550.retention_send_id is
  'v582: the retention send whose delivery produced this row. NULL for a manual '
  'attention-list tap. Partial-unique: one outreach row per send, forever. '
  'Intentionally NOT a foreign key — an FK action would UPDATE this immutable table.';

create unique index if not exists attention_outreach_v550_send_uk
  on public.attention_outreach_v550(retention_send_id)
  where retention_send_id is not null;

-- ---------------------------------------------------------------------------
-- the recorder — the single place an automated outreach row is written
-- ---------------------------------------------------------------------------
create or replace function app.v582_record_retention_outreach(
  p_send uuid,
  p_at   timestamptz
) returns boolean
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_at        timestamptz := coalesce(p_at, now());
  v_inserted  boolean := false;
begin
  if p_send is null then
    return false;
  end if;

  -- occurred_at is the DELIVERY moment reported by Meta, not now(): the whole
  -- report is windowed and lapse-gated on this timestamp, so a re-ingest run
  -- days later must not relocate an intervention to the day it was ingested.
  -- occurred_on is derived from that same instant in SGT, matching the
  -- column's own default expression.
  begin
    insert into public.attention_outreach_v550
      (business_id, client_id, channel, source, occurred_at, occurred_on, actor, retention_send_id)
    select s.business_id,
           s.client_id,
           'whatsapp',
           'retention_whatsapp',
           v_at,
           ((v_at at time zone 'Asia/Singapore')::date),
           null,            -- no human actor: the lane sent this by itself
           s.id
      from public.retention_sends_v551 s
     where s.id = p_send
       and not exists (
         select 1 from public.attention_outreach_v550 o
          where o.retention_send_id = s.id)
    on conflict (business_id, client_id, occurred_on) do nothing;
    v_inserted := found;
  exception
    when unique_violation then
      -- lost the race against a concurrent ingest worker; the row exists
      v_inserted := false;
    when others then
      -- attribution evidence must never abort a delivery status update
      v_inserted := false;
  end;

  return v_inserted;
end
$function$;

revoke all on function app.v582_record_retention_outreach(uuid, timestamptz) from public;
revoke all on function app.v582_record_retention_outreach(uuid, timestamptz) from anon, authenticated;

comment on function app.v582_record_retention_outreach(uuid, timestamptz) is
  'v582: records ONE attention_outreach_v550 row for a retention send that '
  'reached the handset. Idempotent by send id, then by the table day key, then '
  'by unique-violation catch. Never raises.';

-- ---------------------------------------------------------------------------
-- the ingest, patched. Everything outside the marked block is v551 verbatim.
-- ---------------------------------------------------------------------------
create or replace function app.v551_ingest_retention_status(p_limit integer default 200)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_event record; v_status jsonb; v_wamid text; v_state text;
  v_at timestamptz; v_rank integer; v_applied integer := 0; v_ignored integer := 0;
  -- v582
  v_send_id uuid; v_prev_rank integer;
  v_reach constant integer := app.v551_retention_status_rank('delivered');
begin
  -- No processing_status filter, no lock: the v531 router owns that flag and
  -- the v535 support ingest reads the same rows the same way. Re-application
  -- is free because the update only ever advances status_rank, and support
  -- and retention wamids are disjoint, so the two sweeps can never both match
  -- one callback.
  for v_event in
    select * from public.whatsapp_webhook_events
     where received_at > now() - interval '2 days'
     order by received_at
     limit greatest(p_limit, 1)
  loop
    begin
      for v_status in
        select st from jsonb_array_elements(coalesce(v_event.payload->'entry','[]'::jsonb)) entry,
             jsonb_array_elements(coalesce(entry->'changes','[]'::jsonb)) change,
             jsonb_array_elements(coalesce(change->'value'->'statuses','[]'::jsonb)) st
      loop
        v_wamid := v_status->>'id';
        v_state := v_status->>'status';
        v_at := to_timestamp((v_status->>'timestamp')::bigint);
        if v_state not in ('sent','delivered','read','failed') then
          v_ignored := v_ignored + 1; continue;
        end if;
        v_rank := app.v551_retention_status_rank(v_state);

        -- v582: same predicate as v551 (advance only), but the PRE-update rank
        -- is captured in the SAME statement so the delivered transition is
        -- edge-detected from committed state rather than guessed afterwards.
        v_send_id := null; v_prev_rank := null;
        update public.retention_sends_v551 t
           set status = v_state,
               status_rank = v_rank,
               delivered_at = case when v_state = 'delivered' then coalesce(t.delivered_at, v_at) else t.delivered_at end,
               read_at = case when v_state = 'read' then coalesce(t.read_at, v_at) else t.read_at end,
               failed_at = case when v_state = 'failed' then coalesce(t.failed_at, v_at) else t.failed_at end
          from (
            select r.id, r.status_rank as prev_rank
              from public.retention_sends_v551 r
             where r.provider_message_id = v_wamid
             for update
          ) s
         where t.id = s.id
           and s.prev_rank < v_rank
        returning t.id, s.prev_rank into v_send_id, v_prev_rank;

        if found then
          v_applied := v_applied + 1;
          -- v582: the message first reached the handset on THIS callback.
          if v_rank >= v_reach and coalesce(v_prev_rank, -1) < v_reach then
            perform app.v582_record_retention_outreach(v_send_id, v_at);
          end if;
        else
          v_ignored := v_ignored + 1;
        end if;
      end loop;
    exception when others then
      null;
    end;
  end loop;
  return jsonb_build_object('applied', v_applied, 'ignored', v_ignored);
end
$function$;

commit;
