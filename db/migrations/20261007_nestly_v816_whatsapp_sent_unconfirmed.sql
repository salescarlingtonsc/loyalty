/* nestly_v816 — an outcome the database never learned can never be sent again.

   OWNER RULING (2026-10-07), and it is a trade-off the owner made explicitly:

     "A possibly-undelivered message is preferred to a duplicate WhatsApp."

   ============================================================================================
   THE RESIDUAL v687 LEFT OPEN, IN ITS OWN WORDS
   ============================================================================================
   nestly_v687 (audit F126) made the outcome write durable — bounded retries with backoff, a
   named non-retryable case, a counted and logged failure — and then said in the dispatcher's
   own return value:

     "Non-zero means at least one outcome Meta gave us was never written down, so at least one
      row is still 'processing' with a lease that will expire and be re-claimed — i.e. a
      duplicate is coming. Closing that residual for good needs a queue that can record 'sent,
      unconfirmed' (a terminal state the claim RPCs will not re-claim), which is a schema
      decision for the owner; until then this counter is the alarm."

   This is that schema decision. The mechanism that produced the duplicate was never the send:
   it was the CLAIM. Both claim RPCs re-claimed on

       status in ('queued','processing') and (lease_until is null or lease_until < now())

   so "row is in flight and its worker went away" was indistinguishable from "row is waiting to
   be sent". Every crashed, timed-out or unreportable send therefore came back around and the
   customer's phone buzzed a second time.

   ============================================================================================
   WHAT CHANGES — four things, and the fourth is the one that is easy to miss
   ============================================================================================
   1. VOCABULARY. 'sent_unconfirmed' joins both status check constraints and gets rank 22 in
      app.support_status_rank_v535 — above 'sent' (20) so a late 'sent' callback cannot pull a
      quarantined row backwards, below 'failed' (25) so the existing monotonic ingest still
      advances it to delivered (30) or read (40) if Meta ever tells us the truth. The name is
      the honest one: we do not know. Meta may have accepted it and we may simply have lost the
      record, or the worker may have died before the request left. Both collapse to "do not
      send this again".

   2. THE CLAIMS NARROW TO 'queued'. That alone would strand every 'processing' row forever, so:

   3. QUARANTINE IS AN EXPLICIT, AUDITED STEP, never a silent filter. A 'processing' row whose
      lease has expired is moved to 'sent_unconfirmed' by a named function that writes an
      audit_log row carrying the lease token, the worker that held it, when the lease expired
      and why — so "why did this customer never get their reminder" has an answer in the same
      place every other sensitive write is recorded. The dispatcher calls
      public.internal_whatsapp_quarantine_expired_sends_v816 FIRST, before either claim, and
      calls public.internal_whatsapp_quarantine_send_v816 for one specific message when its own
      report write finally fails. Both claim RPCs ALSO run their queue's quarantine at the top:
      the dispatcher is the normal caller, but a row must not be able to strand itself because
      some future caller forgot the pre-step.

   4. app.appointment_already_reminded_v581 — THE ONE THAT IS EASY TO MISS. Its guard against a
      second reminder tested status in ('queued','processing','sent','delivered','read'). A
      quarantined reminder is in none of those, so the very next reminder sweep would have
      enqueued a fresh one and delivered exactly the duplicate this migration exists to stop.
      A terminal state is only terminal if every "has this already gone out?" reader agrees.

   NOT CHANGED, deliberately:
     * app.v536_run_support_dispatch still counts 'processing' rows when deciding whether to
       wake the edge function. It must: a stranded row is exactly what needs the dispatcher to
       run so the quarantine can fire. The verify block asserts this rather than trusting it.
     * The report RPCs need no new refusal for the ordinary case — quarantine clears
       lease_token, so a late report arrives with a token that no longer matches and already
       raises 40001 'stale lease'. An explicit terminal guard is added anyway (same errcode),
       because "never re-sent" should not depend on one nullable column.
     * sent_at is left alone. It means "we recorded Meta accepting this", and a quarantined row
       is precisely the row for which we cannot say that.

   Rollback suite: db/tests/v816_whatsapp_sent_unconfirmed.sql (own tenant, rolled back).
*/

begin;

-- =============================================================================================
-- 1. Vocabulary
-- =============================================================================================

alter table public.support_messages_v530
  drop constraint if exists support_messages_v530_status_check;
alter table public.support_messages_v530
  add constraint support_messages_v530_status_check
  check (status in ('received','queued','processing','sent','sent_unconfirmed',
                    'delivered','read','failed'));

alter table public.whatsapp_template_sends_v557
  drop constraint if exists whatsapp_template_sends_v557_status_check;
alter table public.whatsapp_template_sends_v557
  add constraint whatsapp_template_sends_v557_status_check
  check (status in ('queued','processing','sent','sent_unconfirmed',
                    'delivered','read','failed'));

comment on column public.support_messages_v530.status_rank is
  'v816 monotonic guard. queued 0 < processing 10 < sent 20 < sent_unconfirmed 22 < failed 25 < delivered 30 < read 40. sent_unconfirmed outranks sent so a late callback cannot un-quarantine a row, and sits below delivered/read so Meta can still tell us it arrived.';
comment on column public.whatsapp_template_sends_v557.status_rank is
  'v816 monotonic guard, ranked by app.support_status_rank_v535 so this lane and the support lane can never drift apart. sent_unconfirmed = 22.';

create or replace function app.support_status_rank_v535(p_status text)
returns integer language sql immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select case p_status
    when 'queued' then 0 when 'processing' then 10 when 'sent' then 20
    when 'sent_unconfirmed' then 22
    when 'failed' then 25 when 'delivered' then 30 when 'read' then 40
    else 0 end
$$;
-- ACL restated exactly as v535 left it: no grant to any API role, and none to service_role
-- either — every caller reaches it as the SECURITY DEFINER owner.
revoke all on function app.support_status_rank_v535(text) from public, anon, authenticated;

-- =============================================================================================
-- 2. Quarantine — one per queue, each of them loud
-- =============================================================================================
-- The predicate is deliberately the OLD claim predicate: exactly the set of rows that would
-- have been re-claimed and re-sent is exactly the set that is now quarantined. A 'processing'
-- row with a NULL lease_until is included for the same reason — the old claim took it too.

create or replace function app.whatsapp_quarantine_support_v816(
  p_worker_id text default null,
  p_limit integer default 200,
  p_reason text default 'lease_expired_while_processing'
)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_row record; v_count integer := 0;
begin
  for v_row in
    select m.id, m.business_id, m.lease_token, m.leased_by, m.lease_until, m.attempt_count
      from public.support_messages_v530 m
     where m.direction = 'outbound'
       and m.status = 'processing'
       and (m.lease_until is null or m.lease_until < now())
     order by m.queued_at
     limit greatest(coalesce(p_limit, 200), 1)
     for update of m skip locked
  loop
    update public.support_messages_v530
       set status = 'sent_unconfirmed',
           status_rank = greatest(status_rank, app.support_status_rank_v535('sent_unconfirmed')),
           error_code = left(coalesce(nullif(btrim(p_reason), ''), 'lease_expired_while_processing'), 64),
           next_attempt_at = null,
           lease_token = null, leased_by = null, lease_until = null
     where id = v_row.id;

    -- Never silently. The lease and the worker are named so an operator can tie this row to a
    -- specific dispatcher run. No wamid, no body, no recipient — this table is readable by the
    -- firm's own staff.
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (v_row.business_id, null, 'whatsapp_send_quarantined_v816',
            'support_messages_v530', v_row.id,
            jsonb_build_object(
              'queue', 'support',
              'reason', coalesce(nullif(btrim(p_reason), ''), 'lease_expired_while_processing'),
              'lease_token', v_row.lease_token,
              'leased_by', v_row.leased_by,
              'lease_until', v_row.lease_until,
              'quarantined_by', left(coalesce(nullif(btrim(p_worker_id), ''), 'sweep'), 64),
              'attempt_count', v_row.attempt_count));
    v_count := v_count + 1;
  end loop;
  return v_count;
end
$fn$;

revoke all on function app.whatsapp_quarantine_support_v816(text, integer, text)
  from public, anon, authenticated;
grant execute on function app.whatsapp_quarantine_support_v816(text, integer, text) to service_role;

create or replace function app.whatsapp_quarantine_template_v816(
  p_worker_id text default null,
  p_limit integer default 200,
  p_reason text default 'lease_expired_while_processing'
)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_row record; v_count integer := 0;
begin
  for v_row in
    select m.id, m.business_id, m.lease_token, m.leased_by, m.lease_until, m.attempt_count
      from public.whatsapp_template_sends_v557 m
     where m.status = 'processing'
       and (m.lease_until is null or m.lease_until < now())
     order by m.queued_at
     limit greatest(coalesce(p_limit, 200), 1)
     for update of m skip locked
  loop
    update public.whatsapp_template_sends_v557
       set status = 'sent_unconfirmed',
           status_rank = greatest(status_rank, app.support_status_rank_v535('sent_unconfirmed')),
           last_error_code = left(coalesce(nullif(btrim(p_reason), ''), 'lease_expired_while_processing'), 64),
           next_attempt_at = null,
           lease_token = null, leased_by = null, lease_until = null
     where id = v_row.id;

    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (v_row.business_id, null, 'whatsapp_send_quarantined_v816',
            'whatsapp_template_sends_v557', v_row.id,
            jsonb_build_object(
              'queue', 'template',
              'reason', coalesce(nullif(btrim(p_reason), ''), 'lease_expired_while_processing'),
              'lease_token', v_row.lease_token,
              'leased_by', v_row.leased_by,
              'lease_until', v_row.lease_until,
              'quarantined_by', left(coalesce(nullif(btrim(p_worker_id), ''), 'sweep'), 64),
              'attempt_count', v_row.attempt_count));
    v_count := v_count + 1;
  end loop;
  return v_count;
end
$fn$;

revoke all on function app.whatsapp_quarantine_template_v816(text, integer, text)
  from public, anon, authenticated;
grant execute on function app.whatsapp_quarantine_template_v816(text, integer, text) to service_role;

-- The step the dispatcher calls FIRST, before either claim. Returns the counts so a run that
-- quarantined anything is visible in the cron response, beside v687's `unreported`.
create or replace function public.internal_whatsapp_quarantine_expired_sends_v816(
  p_worker_id text default null,
  p_limit integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_support integer; v_template integer;
begin
  v_support  := app.whatsapp_quarantine_support_v816(p_worker_id, p_limit);
  v_template := app.whatsapp_quarantine_template_v816(p_worker_id, p_limit);
  return jsonb_build_object(
    'status', 'ok', 'support', v_support, 'template', v_template,
    'quarantined', v_support + v_template);
end
$fn$;

revoke all on function public.internal_whatsapp_quarantine_expired_sends_v816(text, integer)
  from public, anon, authenticated;
grant execute on function public.internal_whatsapp_quarantine_expired_sends_v816(text, integer)
  to service_role;

comment on function public.internal_whatsapp_quarantine_expired_sends_v816(text, integer) is
  'v816 moves every outbound row stuck in ''processing'' with an expired lease to the terminal ''sent_unconfirmed'', in both the support and template lanes, writing an audit_log row that names the lease, the worker and the reason. Called by whatsapp-send-dispatch before it claims anything.';

-- The targeted form: ONE message, whose lease this worker still holds, whose outcome could not
-- be written down. Idempotent, because the dispatcher retries it.
create or replace function public.internal_whatsapp_quarantine_send_v816(
  p_queue text,
  p_message uuid,
  p_lease_token uuid,
  p_reason text default 'report_write_failed',
  p_worker_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_reason text := left(coalesce(nullif(btrim(p_reason), ''), 'report_write_failed'), 64);
  v_worker text := left(coalesce(nullif(btrim(p_worker_id), ''), 'dispatcher'), 64);
  v_support public.support_messages_v530%rowtype;
  v_template public.whatsapp_template_sends_v557%rowtype;
  v_business uuid; v_status text; v_lease uuid; v_leased_by text;
  v_lease_until timestamptz; v_attempt integer; v_entity text;
begin
  if p_queue is null or p_queue not in ('support', 'template') then
    raise exception 'unknown send queue' using errcode = '22023';
  end if;

  if p_queue = 'support' then
    select * into v_support from public.support_messages_v530 where id = p_message for update;
    if not found then
      raise exception 'unknown outbound message' using errcode = 'P0002';
    end if;
    v_entity := 'support_messages_v530';
    v_business := v_support.business_id; v_status := v_support.status;
    v_lease := v_support.lease_token; v_leased_by := v_support.leased_by;
    v_lease_until := v_support.lease_until; v_attempt := v_support.attempt_count;
  else
    select * into v_template from public.whatsapp_template_sends_v557 where id = p_message for update;
    if not found then
      raise exception 'unknown template send' using errcode = 'P0002';
    end if;
    v_entity := 'whatsapp_template_sends_v557';
    v_business := v_template.business_id; v_status := v_template.status;
    v_lease := v_template.lease_token; v_leased_by := v_template.leased_by;
    v_lease_until := v_template.lease_until; v_attempt := v_template.attempt_count;
  end if;

  -- Already terminal. The retry that arrives after a successful first call, or after the report
  -- in fact landed, is an OK — not an error the dispatcher has to reason about.
  if v_status <> 'processing' then
    return jsonb_build_object('status','ok','quarantined',false,
      'message_id', p_message, 'message_status', v_status,
      'already_terminal', v_status <> 'queued');
  end if;

  -- Same rule, same errcode as the report RPCs: a worker that no longer owns the lease does not
  -- get to decide this row's fate.
  if v_lease is distinct from p_lease_token then
    raise exception 'stale lease' using errcode = '40001';
  end if;

  if p_queue = 'support' then
    update public.support_messages_v530
       set status = 'sent_unconfirmed',
           status_rank = greatest(status_rank, app.support_status_rank_v535('sent_unconfirmed')),
           error_code = v_reason,
           next_attempt_at = null,
           lease_token = null, leased_by = null, lease_until = null
     where id = p_message;
  else
    update public.whatsapp_template_sends_v557
       set status = 'sent_unconfirmed',
           status_rank = greatest(status_rank, app.support_status_rank_v535('sent_unconfirmed')),
           last_error_code = v_reason,
           next_attempt_at = null,
           lease_token = null, leased_by = null, lease_until = null
     where id = p_message;
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (v_business, null, 'whatsapp_send_quarantined_v816', v_entity, p_message,
          jsonb_build_object(
            'queue', p_queue, 'reason', v_reason,
            'lease_token', v_lease, 'leased_by', v_leased_by, 'lease_until', v_lease_until,
            'quarantined_by', v_worker, 'attempt_count', v_attempt));

  return jsonb_build_object('status','ok','quarantined',true,
    'message_id', p_message, 'message_status', 'sent_unconfirmed', 'reason', v_reason);
end
$fn$;

revoke all on function public.internal_whatsapp_quarantine_send_v816(text, uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.internal_whatsapp_quarantine_send_v816(text, uuid, uuid, text, text)
  to service_role;

comment on function public.internal_whatsapp_quarantine_send_v816(text, uuid, uuid, text, text) is
  'v816 terminal quarantine for ONE in-flight send whose outcome could not be persisted. Requires the caller''s lease (40001 otherwise), is idempotent on an already-terminal row, and audits the lease and worker. The dispatcher calls this when reportSendOutcome finally fails on a ''sent'' disposition, so the row can never be re-claimed and the customer can never receive the message twice.';

-- =============================================================================================
-- 3. The claims stop taking 'processing'
-- =============================================================================================
-- Restated in full (v535 body, unchanged except the predicate and the quarantine pre-step),
-- because CREATE OR REPLACE replaces the whole function and PL/pgSQL resolves names at run time.

create or replace function public.internal_support_claim_outbound_v535(
  p_worker_id text,
  p_limit integer default 20,
  p_lease_seconds integer default 120
)
returns table(
  message_id uuid, business_id uuid, recipient_phone_norm text,
  rendered_body text, attempt_count integer, lease_token uuid)
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_lease uuid := gen_random_uuid();
begin
  -- v816: retire anything stranded in flight BEFORE looking for work. The dispatcher already
  -- calls the public sweep first; this is here so no caller can strand a row by forgetting to.
  perform app.whatsapp_quarantine_support_v816(p_worker_id, 200);

  return query
  with claimable as (
    select m.id
      from public.support_messages_v530 m
     where m.direction = 'outbound'
       -- v816: 'processing' is NOT re-claimable. An expired lease used to mean "the worker went
       -- away, send it again"; it now means "we do not know what happened", and the customer
       -- gets a possibly-undelivered message rather than a certain duplicate.
       and m.status = 'queued'
       and coalesce(m.next_attempt_at, now()) <= now()
       and (m.lease_until is null or m.lease_until < now())
     order by m.queued_at
     limit greatest(coalesce(p_limit, 20), 1)
     for update skip locked
  )
  update public.support_messages_v530 target
     set status = 'processing',
         status_rank = greatest(target.status_rank, app.support_status_rank_v535('processing')),
         lease_token = v_lease, leased_by = left(coalesce(p_worker_id,'worker'), 64),
         lease_until = now() + make_interval(secs => greatest(coalesce(p_lease_seconds,120), 30))
    from claimable
   where target.id = claimable.id
  returning target.id, target.business_id,
            (select c.customer_phone_norm from public.support_conversations_v530 c
              where c.id = target.conversation_id),
            target.rendered_body, target.attempt_count, v_lease;
end
$fn$;

revoke all on function public.internal_support_claim_outbound_v535(text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.internal_support_claim_outbound_v535(text, integer, integer)
  to service_role;

comment on function public.internal_support_claim_outbound_v535(text, integer, integer) is
  'v816 claims ONLY ''queued'' outbound support replies, after quarantining anything stranded in ''processing'' with an expired lease. A message whose outcome the database never learned is terminal, never re-sent.';

-- The template lane keeps the whole v580 body — the stale-appointment suppression with its quota
-- release, and the v572 comms gate in the claim CTE. Only the status predicates move to 'queued'
-- and the v816 quarantine is added at the top.

create or replace function public.internal_whatsapp_claim_template_sends_v557(
  p_worker_id text,
  p_limit integer default 20,
  p_lease_seconds integer default 120
)
returns table(
  message_id uuid, business_id uuid, recipient_phone_norm text,
  template_name text, language_code text, parameters jsonb,
  attempt_count integer, lease_token uuid)
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_lease uuid := gen_random_uuid();
  v_stale record;
begin
  -- v816: stranded in-flight rows become terminal 'sent_unconfirmed' before anything else runs,
  -- so the loops below only ever see rows that are genuinely still waiting to be sent.
  perform app.whatsapp_quarantine_template_v816(p_worker_id, 200);

  -- v580: a queued notice whose appointment is gone, no longer booked, or no
  -- longer at the time in the key is suppressed BY NAME, and its quota unit is
  -- given back. Named reasons, never a silent filter.
  for v_stale in
    select m.id, m.business_id, m.idempotency_key,
           case
             when m.appointment_id is null then 'appointment_deleted'
             when a.status is distinct from 'booked' then 'appointment_' || coalesce(a.status,'missing')
             else 'appointment_rescheduled'
           end as why
      from public.whatsapp_template_sends_v557 m
      left join public.appointments a on a.id = m.appointment_id
     where m.status = 'queued'
       and (m.lease_until is null or m.lease_until < now())
       and (
         m.appointment_id is null
         or a.status is distinct from 'booked'
         or m.idempotency_key <> (m.kind || ':' || m.appointment_id::text || ':'
              || to_char(a.starts_at at time zone 'UTC', 'YYYYMMDD"T"HH24MISS'))
       )
     for update of m skip locked
  loop
    update public.whatsapp_template_sends_v557
       set status = 'failed',
           status_rank = greatest(status_rank, app.support_status_rank_v535('failed')),
           last_error_code = left(v_stale.why, 64),
           next_attempt_at = null,
           lease_token = null, leased_by = null, lease_until = null
     where id = v_stale.id;
    -- The unit was reserved at enqueue under this same key; the customer will
    -- never receive this message, so the merchant gets it back.
    perform app.capability_release_v572(
      v_stale.business_id, 'whatsapp_appointment_notification',
      v_stale.idempotency_key, v_stale.why);
  end loop;

  return query
  with claimable as (
    select m.id
      from public.whatsapp_template_sends_v557 m
      join public.appointments a
        on a.id = m.appointment_id
       and a.status = 'booked'
       and m.idempotency_key = (m.kind || ':' || m.appointment_id::text || ':'
             || to_char(a.starts_at at time zone 'UTC', 'YYYYMMDD"T"HH24MISS'))
     where m.status = 'queued'
       and coalesce(m.next_attempt_at, now()) <= now()
       and (m.lease_until is null or m.lease_until < now())
       and coalesce((app.business_may_initiate_comms_v572(m.business_id,'whatsapp','transactional')->>'allowed')::boolean, false)
     order by m.queued_at
     limit greatest(coalesce(p_limit, 20), 1)
     for update of m skip locked
  )
  update public.whatsapp_template_sends_v557 target
     set status = 'processing',
         status_rank = greatest(target.status_rank, app.support_status_rank_v535('processing')),
         lease_token = v_lease,
         leased_by = left(coalesce(p_worker_id, 'worker'), 64),
         lease_until = now() + make_interval(secs => greatest(coalesce(p_lease_seconds, 120), 30))
    from claimable
   where target.id = claimable.id
  returning target.id, target.business_id, target.recipient_phone_norm,
            target.template_name, target.language_code, target.parameters,
            target.attempt_count, v_lease;
end
$fn$;

revoke all on function public.internal_whatsapp_claim_template_sends_v557(text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.internal_whatsapp_claim_template_sends_v557(text, integer, integer)
  to service_role;

comment on function public.internal_whatsapp_claim_template_sends_v557(text, integer, integer) is
  'v816 claim for appointment template sends. Quarantines stranded in-flight rows to ''sent_unconfirmed'' first, then (v580) suppresses by name, with quota release, any QUEUED row whose appointment is deleted, no longer booked, or no longer at the time in its idempotency key, then leases only ''queued'' rows. A message the database never got an outcome for is never re-sent.';

-- =============================================================================================
-- 4. The report RPCs refuse a quarantined row explicitly
-- =============================================================================================
-- Quarantine clears lease_token, so a late report already fails the lease check with 40001. The
-- guard below states the rule instead of inheriting it from a nullable column.

create or replace function public.internal_support_report_outbound_v535(
  p_message uuid,
  p_lease_token uuid,
  p_disposition text,
  p_provider_message_id text default null,
  p_error_code text default null,
  p_http_status integer default null,
  p_retry_in_seconds integer default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_row public.support_messages_v530%rowtype;
begin
  select * into v_row from public.support_messages_v530 where id = p_message for update;
  if not found then
    raise exception 'unknown outbound message' using errcode = 'P0002';
  end if;
  -- v816: a quarantined row is terminal. Nothing may move it back to queued or overwrite the
  -- fact that we do not know what happened to it.
  if v_row.status = 'sent_unconfirmed' then
    raise exception 'stale lease' using errcode = '40001';
  end if;
  -- A stale lease means another worker owns this row now. Refuse rather than
  -- overwrite: the v95 protocol, and the reason a slow worker cannot resurrect
  -- a message someone else already sent.
  if v_row.lease_token is distinct from p_lease_token then
    raise exception 'stale lease' using errcode = '40001';
  end if;

  if p_disposition = 'sent' then
    update public.support_messages_v530
       set status = 'sent',
           status_rank = greatest(status_rank, app.support_status_rank_v535('sent')),
           provider_message_id = p_provider_message_id,
           sent_at = now(), last_http_status = p_http_status,
           attempt_count = attempt_count + 1,
           lease_token = null, leased_by = null, lease_until = null,
           error_code = null, next_attempt_at = null
     where id = p_message;
  elsif p_disposition = 'retry' then
    update public.support_messages_v530
       set status = 'queued',
           attempt_count = attempt_count + 1,
           last_http_status = p_http_status, error_code = p_error_code,
           next_attempt_at = now() + make_interval(secs => greatest(coalesce(p_retry_in_seconds, 30), 5)),
           lease_token = null, leased_by = null, lease_until = null
     where id = p_message;
  else
    update public.support_messages_v530
       set status = 'failed',
           status_rank = greatest(status_rank, app.support_status_rank_v535('failed')),
           failed_at = now(), last_http_status = p_http_status,
           error_code = left(coalesce(p_error_code, p_disposition), 64),
           attempt_count = attempt_count + 1,
           lease_token = null, leased_by = null, lease_until = null,
           next_attempt_at = null
     where id = p_message;
  end if;

  return jsonb_build_object('status','ok','message_id',p_message,'disposition',p_disposition);
end
$fn$;

revoke all on function public.internal_support_report_outbound_v535(uuid, uuid, text, text, text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.internal_support_report_outbound_v535(uuid, uuid, text, text, text, integer, integer)
  to service_role;

create or replace function public.internal_whatsapp_report_template_send_v557(
  p_message uuid,
  p_lease_token uuid,
  p_disposition text,
  p_provider_message_id text default null,
  p_error_code text default null,
  p_http_status integer default null,
  p_retry_in_seconds integer default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_row public.whatsapp_template_sends_v557%rowtype;
begin
  select * into v_row from public.whatsapp_template_sends_v557 where id = p_message for update;
  if not found then
    raise exception 'unknown template send' using errcode = 'P0002';
  end if;
  -- v816: terminal means terminal, in this lane too.
  if v_row.status = 'sent_unconfirmed' then
    raise exception 'stale lease' using errcode = '40001';
  end if;
  if v_row.lease_token is distinct from p_lease_token then
    raise exception 'stale lease' using errcode = '40001';
  end if;

  if p_disposition = 'sent' then
    update public.whatsapp_template_sends_v557
       set status = 'sent',
           status_rank = greatest(status_rank, app.support_status_rank_v535('sent')),
           provider_message_id = p_provider_message_id,
           sent_at = now(),
           attempt_count = coalesce(attempt_count, 0) + 1,
           lease_token = null, leased_by = null, lease_until = null,
           last_error_code = null, next_attempt_at = null
     where id = p_message;
  elsif p_disposition = 'retry' then
    update public.whatsapp_template_sends_v557
       set status = 'queued',
           attempt_count = coalesce(attempt_count, 0) + 1,
           last_error_code = left(coalesce(p_error_code, 'retry'), 64),
           next_attempt_at = now() + make_interval(secs => greatest(coalesce(p_retry_in_seconds, 30), 5)),
           lease_token = null, leased_by = null, lease_until = null
     where id = p_message;
  else
    update public.whatsapp_template_sends_v557
       set status = 'failed',
           status_rank = greatest(status_rank, app.support_status_rank_v535('failed')),
           last_error_code = left(coalesce(p_error_code, p_disposition), 64),
           attempt_count = coalesce(attempt_count, 0) + 1,
           lease_token = null, leased_by = null, lease_until = null,
           next_attempt_at = null
     where id = p_message;
  end if;

  return jsonb_build_object(
    'status','ok','message_id',p_message,'disposition',p_disposition,
    'http_status', p_http_status);
end
$fn$;

revoke all on function public.internal_whatsapp_report_template_send_v557(uuid, uuid, text, text, text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.internal_whatsapp_report_template_send_v557(uuid, uuid, text, text, text, integer, integer)
  to service_role;

-- =============================================================================================
-- 5. Every "has this already gone out?" reader learns the new terminal state
-- =============================================================================================
-- Without this the reminder sweep would enqueue a fresh reminder for an appointment whose first
-- reminder was quarantined — the exact duplicate this migration exists to prevent, arriving by
-- a different door.

create or replace function app.appointment_already_reminded_v581(p_appointment uuid)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
  select exists (
    select 1 from public.whatsapp_template_sends_v557 m
     where m.appointment_id = p_appointment
       and m.kind in ('appointment_reminder','appointment_reminder_short')
       and m.status in ('queued','processing','sent','sent_unconfirmed','delivered','read')
  )
$fn$;

revoke all on function app.appointment_already_reminded_v581(uuid) from public, anon, authenticated;
grant execute on function app.appointment_already_reminded_v581(uuid) to service_role;

-- =============================================================================================
-- 6. Verify, in this transaction
-- =============================================================================================

do $verify$
declare
  v_def text;
  v_missing text := '';
begin
  -- Vocabulary
  if (select count(*) from pg_constraint
       where conname = 'support_messages_v530_status_check'
         and pg_get_constraintdef(oid) like '%sent_unconfirmed%') <> 1 then
    raise exception 'nestly_v816: support_messages_v530 does not accept sent_unconfirmed';
  end if;
  if (select count(*) from pg_constraint
       where conname = 'whatsapp_template_sends_v557_status_check'
         and pg_get_constraintdef(oid) like '%sent_unconfirmed%') <> 1 then
    raise exception 'nestly_v816: whatsapp_template_sends_v557 does not accept sent_unconfirmed';
  end if;

  -- Rank: strictly between sent and failed, so a late 'sent' cannot undo it and Meta can still
  -- advance it to delivered/read.
  if app.support_status_rank_v535('sent_unconfirmed') <> 22
     or not (app.support_status_rank_v535('sent') < app.support_status_rank_v535('sent_unconfirmed')
             and app.support_status_rank_v535('sent_unconfirmed') < app.support_status_rank_v535('failed')) then
    raise exception 'nestly_v816: sent_unconfirmed must rank strictly between sent (%) and failed (%), got %',
      app.support_status_rank_v535('sent'), app.support_status_rank_v535('failed'),
      app.support_status_rank_v535('sent_unconfirmed');
  end if;

  -- Neither claim may re-claim 'processing', and both must quarantine first.
  for v_def in
    select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('internal_support_claim_outbound_v535',
                         'internal_whatsapp_claim_template_sends_v557')
  loop
    if v_def like '%status in (''queued'',''processing'')%' then
      raise exception 'nestly_v816: a claim RPC still re-claims ''processing'' rows';
    end if;
    if v_def not like '%status = ''queued''%' then
      raise exception 'nestly_v816: a claim RPC no longer narrows to ''queued''';
    end if;
    if v_def not like '%whatsapp_quarantine_%_v816%' then
      raise exception 'nestly_v816: a claim RPC does not quarantine stranded rows first';
    end if;
  end loop;

  -- The reminder guard must count the new terminal state, or the duplicate returns by the
  -- enqueue door.
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'appointment_already_reminded_v581';
  if v_def not like '%sent_unconfirmed%' then
    raise exception 'nestly_v816: appointment_already_reminded_v581 would re-remind a quarantined appointment';
  end if;

  -- The driver must still WAKE on a stranded row, or nothing ever quarantines it.
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'v536_run_support_dispatch';
  if v_def not like '%''queued'', ''processing''%' then
    raise exception 'nestly_v816: v536_run_support_dispatch no longer counts ''processing'' rows, so a stranded row would never wake the quarantine';
  end if;

  -- Both report RPCs refuse a quarantined row by name.
  for v_def in
    select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('internal_support_report_outbound_v535',
                         'internal_whatsapp_report_template_send_v557')
  loop
    if v_def not like '%status = ''sent_unconfirmed''%' then
      raise exception 'nestly_v816: a report RPC can still overwrite a quarantined row';
    end if;
  end loop;

  -- ACL: service_role only, on every function this migration created or replaced.
  select string_agg(fn, ', ') into v_missing from (
    select n.nspname || '.' || p.proname as fn
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname, p.proname) in (
             ('public','internal_whatsapp_quarantine_expired_sends_v816'),
             ('public','internal_whatsapp_quarantine_send_v816'),
             ('public','internal_support_claim_outbound_v535'),
             ('public','internal_whatsapp_claim_template_sends_v557'),
             ('public','internal_support_report_outbound_v535'),
             ('public','internal_whatsapp_report_template_send_v557'),
             ('app','whatsapp_quarantine_support_v816'),
             ('app','whatsapp_quarantine_template_v816'),
             ('app','appointment_already_reminded_v581'))
       and (not has_function_privilege('service_role', p.oid, 'execute')
            or has_function_privilege('anon', p.oid, 'execute')
            or has_function_privilege('authenticated', p.oid, 'execute'))
  ) bad;
  if v_missing is not null then
    raise exception 'nestly_v816: ACL wrong (service_role missing, or anon/authenticated granted) on: %', v_missing;
  end if;
end
$verify$;

commit;
