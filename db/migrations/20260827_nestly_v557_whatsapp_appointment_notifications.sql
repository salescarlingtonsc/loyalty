-- ============================================================================
-- nestly_v557 — C7: the appointment tells the customer's phone, once.
--
-- OWNER APPROVAL 2026-08-27: a confirmation when the appointment is booked, and
-- ONE reminder roughly 24 hours before it starts. NO cancellation notices — the
-- owner ruled them out explicitly, so this migration contains no cancellation
-- path at all rather than a switched-off one. set_appointment_status_v47 is
-- untouched; cancelling an appointment sends nothing, by absence.
--
-- ===========================================================================
-- A THIRD LANE ON THE SAME RAIL, NOT A THIRD RAIL
-- ===========================================================================
-- v535/v536/v539 proved the outbound shape in production: a durable queue row
-- per logical message, a claim/report lease protocol with FOR UPDATE SKIP
-- LOCKED, and a monotonic status rank so a late callback cannot downgrade a
-- message the customer demonstrably read. v551 reused it for retention. This
-- reuses it again for transactional appointment templates.
--
-- What is deliberately SHARED rather than re-invented:
--   * app.support_status_rank_v535 — one rank vocabulary. A second CASE
--     expression would be a second thing to keep in step, and the day they
--     disagree is the day a 'read' message quietly becomes 'failed'.
--   * app.capability_state_v518 / app.capability_consume_v518 — the quota
--     engine, its advisory lock, its idempotency and its named refusals.
--   * app.platform_feature_enabled('whatsapp_outbound') — the platform master
--     kill switch. One flip stops every lane instantly, this one included.
--   * app.v536_run_support_dispatch — the EXISTING cron driver. Section 6
--     teaches it to count template sends too, rather than adding a fourth
--     per-minute job that would wake the same edge function.
--
-- What is NOT shared: the queue table. support_messages_v530 is a conversation
-- transcript — every row belongs to a support_conversations_v530 thread inside
-- a 24h service window. A template send has no conversation, no window (that is
-- the entire point of a template) and no staff author. Forcing it into that
-- table would mean a nullable conversation_id, a nullable window, and a reader
-- that must remember which rows are real messages. A separate table with the
-- same protocol is the cheaper honesty.
--
-- ===========================================================================
-- THE IDEMPOTENCY KEY CARRIES THE START TIME. THAT IS THE FEATURE.
-- ===========================================================================
--   kind || ':' || appointment_id || ':' || starts_at
-- Re-running the sweep, replaying the trigger, or retrying after a client
-- timeout all produce the SAME key, and unique(business_id, idempotency_key)
-- turns "do not send twice" into arithmetic rather than a rule someone has to
-- remember. But a RESCHEDULE changes starts_at, so it produces a DIFFERENT key
-- — and the customer gets one reminder for the new time, which is the whole
-- reason the reminder exists. v508 already treats a reschedule as a fresh
-- request; this key agrees with it by construction.
--
-- The quota consume uses the SAME key, so a retry that finds the row already
-- queued also finds the usage already recorded. A retried notice cannot spend
-- the firm's monthly allowance twice.
--
-- ===========================================================================
-- A NOTIFICATION FAILURE MUST NEVER BREAK A BOOKING
-- ===========================================================================
-- The AFTER INSERT trigger wraps the whole enqueue in begin/exception/when
-- others then null. An appointment is money and a promise to a customer; a
-- WhatsApp row is neither. If the capability engine, the template table or the
-- clients read raises for any reason, the booking still commits and the notice
-- is simply absent. The acceptance suite forces exactly that state — it
-- replaces the enqueue function with one that raises, books an appointment, and
-- proves the appointment landed anyway.
--
-- ===========================================================================
-- PROVIDER MESSAGE IDS ARE PII (v535 owner ruling 4, still true)
-- ===========================================================================
-- wamid.HBgK<base64> decodes to the recipient's E.164 number. The table stores
-- provider_message_id because delivery evidence needs it, and RLS with ZERO
-- policies plus a blanket revoke means no browser role can read the table at
-- all. No reader added here projects it. The one new superadmin reader returns
-- grant state and counts, never a send row.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. The queue
-- ---------------------------------------------------------------------------
-- RLS on with ZERO policies + every grant revoked = service_role and SECURITY
-- DEFINER only. This is the v504/v535 posture for anything holding a customer
-- phone number, and it is why there is no "own business read" policy here: the
-- business-facing answer is a count, and a count does not need row access.

create table if not exists public.whatsapp_template_sends_v557(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  -- on delete SET NULL, not cascade: if the appointment is deleted after Meta
  -- accepted the message, the delivery evidence must survive the row it was
  -- about. Deleting the proof of a message the customer received is not a
  -- cleanup, it is a loss.
  appointment_id uuid references public.appointments(id) on delete set null,
  kind text not null check (kind in ('appointment_confirmation','appointment_reminder')),
  recipient_phone_norm text not null,
  template_name text not null,
  language_code text not null default 'en',
  -- Meta's body parameter array, already in wire shape:
  -- [{"type":"text","text":"..."}, ...]. Built server-side; the browser never
  -- supplies one, because the browser cannot reach this table.
  parameters jsonb not null default '[]'::jsonb
    check (jsonb_typeof(parameters) = 'array'),
  idempotency_key text not null check (char_length(btrim(idempotency_key)) between 8 and 200),
  status text not null default 'queued'
    check (status in ('queued','processing','sent','failed','delivered','read')),
  -- Same ranks as v535, produced by the same function. See section 2.
  status_rank int not null default 0,
  provider_message_id text,
  attempt_count int default 0,
  next_attempt_at timestamptz,
  queued_at timestamptz default now(),
  sent_at timestamptz,
  lease_token uuid,
  leased_by text,
  lease_until timestamptz,
  last_error_code text,
  constraint whatsapp_template_sends_v557_idem_uk unique (business_id, idempotency_key)
);

comment on table public.whatsapp_template_sends_v557 is
  'v557 outbound WhatsApp TEMPLATE queue for appointment confirmations and 24h reminders. One row per logical notice; unique(business_id, idempotency_key) where the key carries the appointment start time, so a replay is free and a reschedule re-arms.';
comment on column public.whatsapp_template_sends_v557.idempotency_key is
  'v557 kind:appointment_id:starts_at. A replay produces the same key (no second message); a reschedule produces a new one (a fresh reminder for the new time). The v518 quota consume uses this same key.';
comment on column public.whatsapp_template_sends_v557.provider_message_id is
  'v557 PII (a wamid decodes to the recipient E.164). Never projected to any browser reader; the table has RLS with zero policies and no role grants.';
comment on column public.whatsapp_template_sends_v557.status_rank is
  'v557 monotonic guard, ranked by app.support_status_rank_v535 so this lane and the support lane can never drift apart.';

create index if not exists whatsapp_template_sends_v557_dispatch_idx
  on public.whatsapp_template_sends_v557(status, next_attempt_at)
  where status in ('queued','processing');
create index if not exists whatsapp_template_sends_v557_wamid_idx
  on public.whatsapp_template_sends_v557(provider_message_id)
  where provider_message_id is not null;
create index if not exists whatsapp_template_sends_v557_business_idx
  on public.whatsapp_template_sends_v557(business_id, queued_at desc);
create index if not exists whatsapp_template_sends_v557_appointment_idx
  on public.whatsapp_template_sends_v557(appointment_id)
  where appointment_id is not null;

alter table public.whatsapp_template_sends_v557 enable row level security;
revoke all privileges on table public.whatsapp_template_sends_v557
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Enqueue — every refusal has a name
-- ---------------------------------------------------------------------------
-- Gate order is deliberate and matches v535: master flag, then the per-firm
-- capability, then the recipient. Asking about the phone number before asking
-- whether the firm may send is a small privacy leak into the return value for
-- no benefit.
--
-- The capability is CHECKED with capability_state_v518 before the insert and
-- CONSUMED with capability_consume_v518 after it, so an insert that lost the
-- unique-index race consumes nothing. If the consume is refused between those
-- two points (a concurrent send filled the cap), the row is marked failed with
-- the refusal's own name and nothing is dispatched — the queue never carries a
-- row the quota engine has not paid for.

create or replace function app.whatsapp_enqueue_appointment_notice_v557(
  p_business uuid,
  p_appointment uuid,
  p_kind text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_appt public.appointments%rowtype;
  v_client public.clients%rowtype;
  v_state jsonb;
  v_quota jsonb;
  v_biz_name text;
  v_service_name text;
  v_idem text;
  v_template text;
  v_when text;
  v_id uuid;
begin
  if p_kind is null or p_kind not in ('appointment_confirmation','appointment_reminder') then
    return jsonb_build_object('status','refused','reason','unknown_kind');
  end if;

  -- business_id is in the predicate, so another tenant's appointment id matches
  -- nothing rather than leaking its existence.
  select * into v_appt from public.appointments
   where id = p_appointment and business_id = p_business;
  if not found then
    return jsonb_build_object('status','refused','reason','appointment_not_found');
  end if;
  if v_appt.status <> 'booked' then
    return jsonb_build_object('status','refused','reason','appointment_not_booked');
  end if;

  -- (1) the PLATFORM master switch
  if not app.platform_feature_enabled('whatsapp_outbound') then
    return jsonb_build_object('status','refused','reason','outbound_not_enabled');
  end if;

  -- (2) the PER-FIRM capability and its monthly cap, resolved but not yet spent
  v_state := app.capability_state_v518(p_business, 'whatsapp_appointment_notification');
  if (v_state->>'allowed') is distinct from 'true' then
    return jsonb_build_object('status','refused',
      'reason', coalesce(v_state->>'reason','capability_refused')) || v_state;
  end if;

  -- (3) the recipient
  select * into v_client from public.clients
   where id = v_appt.client_id and business_id = p_business;
  if not found then
    return jsonb_build_object('status','refused','reason','client_not_found');
  end if;
  if coalesce(v_client.is_synthetic, false) then
    return jsonb_build_object('status','refused','reason','synthetic_client');
  end if;
  if v_client.phone_norm is null then
    -- The platform normaliser rejected or never saw a number. Naming it is what
    -- lets a merchant fix it, instead of wondering why one customer is silent.
    return jsonb_build_object('status','refused','reason','no_phone');
  end if;

  select b.name into v_biz_name from public.businesses b where b.id = p_business;
  select s.name into v_service_name from public.services s where s.id = v_appt.service_id;

  -- Asia/Singapore is a fixed +08 with no DST, which is why a stored zone name
  -- and "at +08" are the same answer here — and why the repo uses the name.
  if p_kind = 'appointment_confirmation' then
    v_template := 'peekaa_appt_confirmation';
    v_when := to_char(v_appt.starts_at at time zone 'Asia/Singapore', 'Dy DD Mon, HH12:MI AM');
  else
    v_template := 'peekaa_appt_reminder';
    v_when := to_char(v_appt.starts_at at time zone 'Asia/Singapore', 'HH12:MI AM');
  end if;

  -- The key that makes replay free and a reschedule a new notice. starts_at is
  -- rendered in UTC so the key is stable regardless of the session TimeZone.
  v_idem := p_kind || ':' || p_appointment::text || ':'
            || to_char(v_appt.starts_at at time zone 'UTC', 'YYYYMMDD"T"HH24MISS');

  insert into public.whatsapp_template_sends_v557(
    business_id, appointment_id, kind, recipient_phone_norm,
    template_name, language_code, parameters, idempotency_key,
    status, status_rank, attempt_count, queued_at, next_attempt_at)
  values (
    p_business, p_appointment, p_kind, v_client.phone_norm,
    v_template, 'en',
    jsonb_build_array(
      jsonb_build_object('type','text','text', coalesce(nullif(btrim(v_biz_name),''),'Peekaa')),
      jsonb_build_object('type','text','text', coalesce(nullif(btrim(v_service_name),''),'your appointment')),
      jsonb_build_object('type','text','text', v_when)),
    v_idem, 'queued', app.support_status_rank_v535('queued'), 0, now(), now())
  on conflict (business_id, idempotency_key) do nothing
  returning id into v_id;

  -- NOT FOUND here means the unique index already held this notice. Returning
  -- ok/duplicate rather than an error is what makes the sweep safe to re-run
  -- every 30 minutes over the same two-hour window.
  if v_id is null then
    return jsonb_build_object('status','ok','duplicate',true,'reason','already_queued');
  end if;

  -- (4) spend the cap, keyed identically, ONLY now that a row exists.
  v_quota := app.capability_consume_v518(
    p_business, 'whatsapp_appointment_notification', v_idem,
    jsonb_build_object('appointment_id', p_appointment, 'kind', p_kind));

  if (v_quota->>'consumed') is distinct from 'true' then
    -- Lost a race against a concurrent send. The row exists but is unpaid, so
    -- it must never dispatch: fail it by name and say so.
    update public.whatsapp_template_sends_v557
       set status = 'failed',
           status_rank = greatest(status_rank, app.support_status_rank_v535('failed')),
           last_error_code = left(coalesce(v_quota->>'reason','capability_refused'), 64),
           next_attempt_at = null
     where id = v_id;
    return jsonb_build_object('status','refused',
      'reason', coalesce(v_quota->>'reason','capability_refused'),
      'send_id', v_id);
  end if;

  return jsonb_build_object(
    'status','ok','duplicate',false,'send_id',v_id,'kind',p_kind,
    'template_name',v_template,'idempotency_key',v_idem,
    'remaining', v_quota->'remaining');
end
$fn$;

revoke all on function app.whatsapp_enqueue_appointment_notice_v557(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function app.whatsapp_enqueue_appointment_notice_v557(uuid, uuid, text)
  to service_role;

-- ---------------------------------------------------------------------------
-- 3. The confirmation trigger — deliberately deaf to its own failures
-- ---------------------------------------------------------------------------

create or replace function app.whatsapp_appointment_booked_v557()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
begin
  begin
    perform app.whatsapp_enqueue_appointment_notice_v557(
      new.business_id, new.id, 'appointment_confirmation');
  exception when others then
    -- A booking is money and a promise. A WhatsApp row is neither. Nothing
    -- inside this block may abort the transaction that created the appointment.
    null;
  end;
  return null;
end
$fn$;

revoke all on function app.whatsapp_appointment_booked_v557()
  from public, anon, authenticated;

drop trigger if exists whatsapp_appointment_booked_v557 on public.appointments;
create trigger whatsapp_appointment_booked_v557
after insert on public.appointments
for each row when (new.status = 'booked')
execute function app.whatsapp_appointment_booked_v557();

-- ---------------------------------------------------------------------------
-- 4. The 24h reminder sweep
-- ---------------------------------------------------------------------------
-- The window is [now+23h, now+25h) and the job runs every 30 minutes, so each
-- appointment falls inside the window on several consecutive runs. That is not
-- waste — it is the redundancy that survives one missed tick. The idempotency
-- key makes every run after the first a no-op.

create or replace function app.run_whatsapp_reminder_sweep_v557(p_limit int default 200)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_row record;
  v_result jsonb;
  v_enqueued integer := 0;
  v_duplicate integer := 0;
  v_refused integer := 0;
  v_errored integer := 0;
begin
  for v_row in
    select a.id, a.business_id
      from public.appointments a
     where a.status = 'booked'
       and a.starts_at >= now() + interval '23 hours'
       and a.starts_at <  now() + interval '25 hours'
     order by a.starts_at
     limit greatest(coalesce(p_limit, 200), 1)
  loop
    begin
      v_result := app.whatsapp_enqueue_appointment_notice_v557(
        v_row.business_id, v_row.id, 'appointment_reminder');
      if (v_result->>'status') = 'ok' then
        if (v_result->>'duplicate') = 'true' then v_duplicate := v_duplicate + 1;
        else v_enqueued := v_enqueued + 1; end if;
      else
        v_refused := v_refused + 1;
      end if;
    exception when others then
      -- One unhappy tenant must not stop the sweep for every other tenant.
      v_errored := v_errored + 1;
    end;
  end loop;

  return jsonb_build_object(
    'enqueued', v_enqueued, 'duplicate', v_duplicate,
    'refused', v_refused, 'errored', v_errored);
end
$fn$;

revoke all on function app.run_whatsapp_reminder_sweep_v557(int)
  from public, anon, authenticated;
grant execute on function app.run_whatsapp_reminder_sweep_v557(int) to service_role;

-- Unschedule-then-schedule, guarded, so replaying this migration leaves exactly
-- one job. cron.schedule alone would be fine (it upserts by name on recent
-- pg_cron) but the explicit unschedule states the intent and works either way.
do $cron$
begin
  if to_regnamespace('cron') is not null
     and to_regprocedure('cron.schedule(text,text,text)') is not null then
    if exists (select 1 from cron.job where jobname = 'peekaa-whatsapp-reminder-sweep') then
      perform cron.unschedule('peekaa-whatsapp-reminder-sweep');
    end if;
    perform cron.schedule(
      'peekaa-whatsapp-reminder-sweep',
      '*/30 * * * *',
      $command$select app.run_whatsapp_reminder_sweep_v557(200)$command$);
  end if;
exception when others then null;
end $cron$;

-- ---------------------------------------------------------------------------
-- 5. Claim / report — the v535 lease protocol, verbatim in shape
-- ---------------------------------------------------------------------------

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
declare v_lease uuid := gen_random_uuid();
begin
  return query
  with claimable as (
    select m.id
      from public.whatsapp_template_sends_v557 m
     where m.status in ('queued','processing')
       and coalesce(m.next_attempt_at, now()) <= now()
       and (m.lease_until is null or m.lease_until < now())
     order by m.queued_at
     limit greatest(coalesce(p_limit, 20), 1)
     for update skip locked
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
  -- A stale lease means another worker owns this row now. Refusing is what stops
  -- a slow worker resurrecting a message someone else already sent.
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

-- ---------------------------------------------------------------------------
-- 6. The existing driver learns that template sends are also work
-- ---------------------------------------------------------------------------
-- Body copied VERBATIM from v539, including the vault lookup ORDER — v539 was
-- the fix for exactly that order, and re-deriving it here would be how it gets
-- un-fixed. The single change is the queued count, which now sums both lanes so
-- the per-minute cron wakes the edge function for a template send too.

create or replace function app.v536_run_support_dispatch()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_url text;
  v_secret text;
  v_request bigint;
  v_queued integer;
  v_name text;
begin
  select (
    select count(*)
      from public.support_messages_v530
     where direction = 'outbound'
       and status in ('queued', 'processing')
       and coalesce(next_attempt_at, now()) <= now()
  ) + (
    -- v557: the appointment-template lane rides the same driver.
    select count(*)
      from public.whatsapp_template_sends_v557
     where status in ('queued', 'processing')
       and coalesce(next_attempt_at, now()) <= now()
  ) into v_queued;

  if v_queued = 0 then
    return jsonb_build_object('queued', 0, 'dispatch', 'idle');
  end if;

  if to_regnamespace('vault') is null or to_regnamespace('net') is null then
    return jsonb_build_object('queued', v_queued, 'dispatch', 'extensions_unavailable');
  end if;

  begin
    -- v539: own name first, then the one this project actually has. The legacy
    -- pair stays last so a future environment that does define them still works.
    foreach v_name in array array['v536_supabase_url','v176_supabase_url',
                                  'v282_supabase_url','v156_supabase_url'] loop
      execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
        into v_url using v_name;
      exit when coalesce(v_url, '') <> '';
    end loop;
    execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
      into v_secret using 'v536_whatsapp_dispatch_secret';
  exception when others then
    return jsonb_build_object('queued', v_queued, 'dispatch', 'vault_unavailable');
  end;

  if coalesce(v_url, '') = '' then
    return jsonb_build_object('queued', v_queued, 'dispatch', 'base_url_unconfigured');
  end if;
  if coalesce(v_secret, '') = '' then
    return jsonb_build_object('queued', v_queued, 'dispatch', 'dispatch_secret_unconfigured');
  end if;

  execute 'select net.http_post(url := $1, body := ''{}''::jsonb, headers := jsonb_build_object(''content-type'',''application/json'',''x-peekaa-whatsapp-dispatch-secret'',$2), timeout_milliseconds := 25000)'
    into v_request
    using rtrim(v_url, '/') || '/functions/v1/whatsapp-send-dispatch', v_secret;

  return jsonb_build_object('queued', v_queued, 'dispatch_request_id', v_request);
end
$fn$;

-- Restated verbatim from v539's own ACL.
revoke all privileges on function app.v536_run_support_dispatch()
  from public, anon, authenticated, service_role;
grant execute on function app.v536_run_support_dispatch() to service_role;

-- ---------------------------------------------------------------------------
-- 7. Status ingest falls back to the template table
-- ---------------------------------------------------------------------------
-- Meta reports delivered/read against a wamid; it does not tell us which of our
-- tables that wamid lives in. Without this fallback every delivery receipt for
-- an appointment notice would be counted 'ignored' and the evidence would
-- silently never arrive. Same monotonic rule, same non-competing posture toward
-- v531's inbound router (no processing_status filter, no row lock).

create or replace function app.support_ingest_status_v535(p_limit integer default 200)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_event record; v_status jsonb; v_wamid text; v_state text;
  v_at timestamptz; v_rank integer; v_applied integer := 0; v_ignored integer := 0;
  v_hit boolean;
begin
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
        v_rank := app.support_status_rank_v535(v_state);

        update public.support_messages_v530
           set status = v_state,
               status_rank = v_rank,
               delivered_at = case when v_state = 'delivered' then coalesce(delivered_at, v_at) else delivered_at end,
               read_at = case when v_state = 'read' then coalesce(read_at, v_at) else read_at end,
               failed_at = case when v_state = 'failed' then coalesce(failed_at, v_at) else failed_at end
         where provider_message_id = v_wamid
           and direction = 'outbound'
           and status_rank < v_rank;
        v_hit := found;

        if not v_hit then
          -- v557: the same callback, the other lane. Only ever ADVANCES rank,
          -- so replaying a webhook row changes nothing.
          update public.whatsapp_template_sends_v557
             set status = v_state,
                 status_rank = v_rank,
                 sent_at = case when v_state = 'sent' then coalesce(sent_at, v_at) else sent_at end
           where provider_message_id = v_wamid
             and status_rank < v_rank;
          v_hit := found;
        end if;

        if v_hit then v_applied := v_applied + 1; else v_ignored := v_ignored + 1; end if;
      end loop;
    exception when others then
      null;
    end;
  end loop;
  return jsonb_build_object('applied', v_applied, 'ignored', v_ignored);
end
$fn$;

-- Restated verbatim from v535's own ACL.
revoke all on function app.support_ingest_status_v535(integer)
  from public, anon, authenticated;
grant execute on function app.support_ingest_status_v535(integer) to service_role;

-- ---------------------------------------------------------------------------
-- 8. The superadmin's one screen: who has WhatsApp, and how much is left
-- ---------------------------------------------------------------------------
-- platform_get_capability_matrix_v518 answers this for ONE firm. Granting the
-- pilot means comparing firms, which today is one call per business. This is the
-- cross-firm read, restricted to the whatsapp_* capabilities so it stays a
-- WhatsApp console rather than a platform dump.
--
-- Gate is app.is_super_admin() INSIDE the function (the v14 posture), with
-- EXECUTE to authenticated — same shape as every sibling platform reader. It
-- returns grant state and counts; no send row, no phone number, no wamid.
--
-- SHAPE: a FLAT jsonb ARRAY, one object per (business, whatsapp_* capability),
-- because the console renders rows and asArray()s the result. Every value is
-- the EFFECTIVE one (grant override resolved against the registry default), so
-- the panel never has to re-implement v518's precedence and then drift from it.
--
-- limit_period is emitted in the console's own vocabulary (daily / monthly),
-- and limit_period_key carries v518's canonical value (day / month / ...) —
-- the value platform_set_capability_grant_v518 will accept back. Two names
-- because they are two different things; collapsing them is how a display
-- string ends up in a CHECK constraint.

create or replace function public.platform_list_capability_grants_v557()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_rows jsonb;
begin
  if not app.is_super_admin() then
    raise exception 'super admin required' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(entry order by entry->>'business_name', entry->>'capability_key'), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'business_id', b.id,
      'business_name', b.name,
      'industry', b.industry,
      'capability_key', cap.capability_key,
      'title', cap.title,
      'active', cap.active,

      -- EFFECTIVE state, resolved exactly as app.capability_state_v518 does.
      'enabled', coalesce(g.enabled, cap.default_enabled),
      'limit_unlimited', coalesce(g.limit_unlimited, false)
        or (not coalesce(g.limit_unlimited, false)
            and coalesce(g.limit_count, cap.default_limit_count) is null),
      'limit_count', case when coalesce(g.limit_unlimited, false) then null
                          else coalesce(g.limit_count, cap.default_limit_count) end,
      -- what the console renders
      'limit_period', case coalesce(g.limit_period, cap.default_limit_period)
                        when 'day' then 'daily' when 'week' then 'weekly'
                        when 'month' then 'monthly' when 'year' then 'yearly'
                        else coalesce(g.limit_period, cap.default_limit_period) end,
      -- what platform_set_capability_grant_v518 accepts back
      'limit_period_key', coalesce(g.limit_period, cap.default_limit_period),

      'used_this_period', coalesce((st.state->>'used')::integer, 0),
      'remaining', st.state->'remaining',
      'period_key', st.state->>'period_key',
      'allowed', coalesce((st.state->>'allowed')::boolean, false),
      'reason', st.state->>'reason',

      -- the optimistic-concurrency token the console must echo back
      'version', coalesce(g.version, 0),
      'note', g.note,

      'default_enabled', cap.default_enabled,
      'default_limit_count', cap.default_limit_count,
      'default_limit_period', cap.default_limit_period
    ) as entry
    from public.businesses b
    cross join public.platform_capabilities_v518 cap
    left join public.business_capability_grants_v518 g
      on g.business_id = b.id and g.capability_key = cap.capability_key
    cross join lateral (
      select app.capability_state_v518(b.id, cap.capability_key, now()) as state
    ) st
    where cap.capability_key like 'whatsapp\_%'
  ) rows;

  return v_rows;
end
$fn$;

revoke all on function public.platform_list_capability_grants_v557()
  from public, anon, authenticated;
grant execute on function public.platform_list_capability_grants_v557()
  to authenticated, service_role;

comment on function public.platform_list_capability_grants_v557() is
  'v557 superadmin cross-firm WhatsApp capability roster: one flat row per (business, whatsapp_* capability) carrying the EFFECTIVE grant state plus current-period usage. Gated on app.is_super_admin(); exposes no send row, phone number or provider message id.';

commit;
