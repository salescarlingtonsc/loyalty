-- ============================================================================
-- nestly_v581 — THE SHORT-NOTICE REMINDER, AND TELLING THE CUSTOMER IT MOVED
--
-- Owner ruling 2026-08-28: both of these are P0, not P2. The data agrees —
-- 10 of the last 14 appointments platform-wide were booked LESS than 24 hours
-- before they start (3 under 2h, 2 in 6-12h, 5 in 12-24h). A reminder lane that
-- only fires at T-24h therefore reminds nobody for 71% of real bookings.
--
-- Ships INERT for the two new lanes: their templates are seeded 'draft' and the
-- enqueue now refuses any kind whose template is not 'approved'. Nothing new can
-- send until Meta approves and the registry row is flipped.
--
-- ===========================================================================
-- 1. THE APPROVAL GATE THAT WAS MISSING
-- ===========================================================================
-- v557 chose its Meta template name with a hardcoded CASE and consulted nothing
-- about whether that template was approved. The retention lane has always joined
-- whatsapp_template_registry_v551 and refused anything not 'approved'; the
-- appointment lane never did. That was survivable while its two templates were
-- hand-submitted and known-good, and it stops being survivable the moment this
-- migration adds two MORE kinds.
--
-- So the registry becomes the single source of truth for the appointment lane
-- too: the enqueue reads meta_name and language FROM it, and refuses with
-- 'template_not_approved' otherwise. That is what makes the two new lanes
-- fail-closed by construction rather than by remembering to keep them off.
--
-- ===========================================================================
-- 2. THE SHORT-NOTICE RULE — ONE SENTENCE, NOT A SCHEDULE OF SPECIAL CASES
-- ===========================================================================
--   At roughly two hours before an appointment, if the customer has not
--   already been reminded, remind them once.
--
-- Every case the owner listed falls out of that one rule, with no branching on
-- how far ahead the booking was made:
--   * booked 3 days out  -> reminded at T-24h; at T-2h a reminder already
--                           exists, so the short lane skips it. Never both.
--   * booked 23h out     -> never enters the 23-25h window at all; reminded
--                           once at T-2h.
--   * booked 3h out      -> same; reminded once at T-2h.
--   * booked 90 min out  -> confirmed, then never reminded: by the time it is
--                           old enough to qualify it is already too close.
--                           CONFIRMATION ONLY, because a reminder minutes after
--                           a confirmation is noise, not service.
-- A booking made exactly 23h out DOES fall in the 23-25h window and is reminded
-- there; the short lane exists for everything nearer than that.
--
-- The window is [now+1h30m, now+2h30m) — a full hour, deliberately wider than
-- the 30-minute cron tick, so an appointment cannot fall between two ticks. Two
-- ticks may see it; the idempotency key makes the second a no-op.
--
-- "Already reminded" counts any reminder row that reached or is reaching the
-- customer (queued/processing/sent/delivered/read). A row v580 marked 'failed'
-- because its appointment moved must NOT count — otherwise a reschedule would
-- silence the reminder for the new time.
--
-- ===========================================================================
-- 3. RESCHEDULE — FIRE ON THE FACT, NOT ON THE SAVE
-- ===========================================================================
-- Staff reschedules are an in-place UPDATE of starts_at, so the AFTER INSERT
-- confirmation trigger cannot see them and the customer was never told. The new
-- trigger is AFTER UPDATE OF starts_at ... WHEN (old.starts_at IS DISTINCT FROM
-- new.starts_at AND new.status = 'booked'), which gives the owner's four
-- requirements for free:
--   * re-saving the same time changes no column -> the trigger never fires
--   * cancelling changes status, not starts_at  -> no "it moved" message
--   * an internal edit (note, staff_id)         -> no message
--   * two rapid reschedules                     -> two rows, each keyed to its
--     own time; v580 suppresses the stale one at claim and refunds it, so the
--     LAST time wins and only it is delivered
-- The 24h/short reminders recalculate themselves, because the idempotency key
-- has always carried starts_at.
--
-- Reusing peekaa_appt_confirmation for this would be a lie: its approved body
-- says "is confirmed", which does not tell a customer their time CHANGED. A
-- separate UTILITY template is seeded 'draft' and named here; it cannot send
-- until it is approved.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. The new kinds
-- ---------------------------------------------------------------------------

alter table public.whatsapp_template_sends_v557
  drop constraint if exists whatsapp_template_sends_v557_kind_check;
alter table public.whatsapp_template_sends_v557
  add constraint whatsapp_template_sends_v557_kind_check
  check (kind in ('appointment_confirmation','appointment_reminder',
                  'appointment_reminder_short','appointment_updated'));

-- ---------------------------------------------------------------------------
-- 2. The appointment lane joins the registry
-- ---------------------------------------------------------------------------
-- The two live templates are recorded with the wording and ids Meta already
-- approved on 2026-08-27. The two new ones are 'draft' on purpose.

insert into public.whatsapp_template_registry_v551(
  template_key, meta_name, language_code, category, body_text,
  parameter_descriptors, status, meta_template_id)
values
 ('appointment_confirmation','peekaa_appt_confirmation','en','utility',
  'Your appointment with {{1}} is confirmed — {{2}} on {{3}}. Reply to this chat if you need to change it.',
  '["business_name","service_name","when_text"]'::jsonb,'approved','3613779478780236'),
 ('appointment_reminder','peekaa_appt_reminder','en','utility',
  'Reminder from {{1}} — {{2}} tomorrow at {{3}}. See you soon! Reply here to reschedule.',
  '["business_name","service_name","when_text"]'::jsonb,'approved','1602528361431069'),
 -- NOT approved. The body says "today", because the approved 24h template says
 -- "tomorrow" and would be false two hours before an appointment.
 ('appointment_reminder_short','peekaa_appt_reminder_today','en','utility',
  'Reminder from {{1}} — {{2}} today at {{3}}. See you soon! Reply here to reschedule.',
  '["business_name","service_name","when_text"]'::jsonb,'draft',null),
 -- NOT approved. "is confirmed" cannot tell a customer their time CHANGED.
 ('appointment_updated','peekaa_appt_updated','en','utility',
  'Your appointment with {{1}} has been moved — {{2}} is now on {{3}}. Reply to this chat if that does not work for you.',
  '["business_name","service_name","when_text"]'::jsonb,'draft',null)
on conflict (template_key) do nothing;

-- ---------------------------------------------------------------------------
-- 3. Enqueue: registry-driven, approval-gated, four kinds
-- ---------------------------------------------------------------------------
-- Faithful to the v574 definition in every gate and every order; the only
-- changes are the registry lookup replacing the hardcoded CASE, the
-- 'template_not_approved' refusal, and the two new kinds.

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
  v_tpl public.whatsapp_template_registry_v551%rowtype;
  v_state jsonb;
  v_quota jsonb;
  v_biz jsonb;
  v_biz_name text;
  v_service_name text;
  v_idem text;
  v_when text;
  v_id uuid;
begin
  if p_kind is null or p_kind not in ('appointment_confirmation','appointment_reminder',
                                      'appointment_reminder_short','appointment_updated') then
    return jsonb_build_object('status','refused','reason','unknown_kind');
  end if;

  select * into v_appt from public.appointments
   where id = p_appointment and business_id = p_business;
  if not found then
    return jsonb_build_object('status','refused','reason','appointment_not_found');
  end if;
  if v_appt.status <> 'booked' then
    return jsonb_build_object('status','refused','reason','appointment_not_booked');
  end if;

  if not app.platform_feature_enabled('whatsapp_outbound') then
    return jsonb_build_object('status','refused','reason','outbound_not_enabled');
  end if;

  v_biz := app.business_may_initiate_comms_v572(p_business, 'whatsapp', 'transactional');
  if not coalesce((v_biz->>'allowed')::boolean, false) then
    return jsonb_build_object('status','refused',
      'reason', coalesce(v_biz->>'reason', 'business_not_eligible'));
  end if;

  -- v581: the template must exist AND be approved. This is what keeps a newly
  -- added kind inert until Meta has actually said yes.
  select * into v_tpl from public.whatsapp_template_registry_v551
   where template_key = p_kind;
  if not found then
    return jsonb_build_object('status','refused','reason','template_unknown');
  end if;
  if v_tpl.status <> 'approved' then
    return jsonb_build_object('status','refused','reason','template_not_approved',
      'template_status', v_tpl.status);
  end if;

  v_state := app.capability_state_v518(p_business, 'whatsapp_appointment_notification');
  if (v_state->>'allowed') is distinct from 'true' then
    return jsonb_build_object('status','refused',
      'reason', coalesce(v_state->>'reason','capability_refused')) || v_state;
  end if;

  select * into v_client from public.clients
   where id = v_appt.client_id and business_id = p_business;
  if not found then
    return jsonb_build_object('status','refused','reason','client_not_found');
  end if;
  if coalesce(v_client.is_synthetic, false) then
    return jsonb_build_object('status','refused','reason','synthetic_client');
  end if;
  if v_client.phone_norm is null then
    return jsonb_build_object('status','refused','reason','no_phone');
  end if;

  select b.name into v_biz_name from public.businesses b where b.id = p_business;
  select s.name into v_service_name from public.services s where s.id = v_appt.service_id;

  -- A reminder names only a time because its template already says which day.
  -- A confirmation or a change of time must name the date, because the customer
  -- is being told something they do not already know.
  v_when := case
    when p_kind in ('appointment_reminder','appointment_reminder_short')
      then to_char(v_appt.starts_at at time zone 'Asia/Singapore', 'HH12:MI AM')
    else to_char(v_appt.starts_at at time zone 'Asia/Singapore', 'Dy DD Mon, HH12:MI AM')
  end;

  v_idem := p_kind || ':' || p_appointment::text || ':'
            || to_char(v_appt.starts_at at time zone 'UTC', 'YYYYMMDD"T"HH24MISS');

  insert into public.whatsapp_template_sends_v557(
    business_id, appointment_id, kind, recipient_phone_norm,
    template_name, language_code, parameters, idempotency_key,
    status, status_rank, attempt_count, queued_at, next_attempt_at)
  values (
    p_business, p_appointment, p_kind, v_client.phone_norm,
    v_tpl.meta_name, v_tpl.language_code,
    jsonb_build_array(
      jsonb_build_object('type','text','text', coalesce(nullif(btrim(v_biz_name),''),'Peekaa')),
      jsonb_build_object('type','text','text', coalesce(nullif(btrim(v_service_name),''),'your appointment')),
      jsonb_build_object('type','text','text', v_when)),
    v_idem, 'queued', app.support_status_rank_v535('queued'), 0, now(), now())
  on conflict (business_id, idempotency_key) do nothing
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('status','ok','duplicate',true,'reason','already_queued');
  end if;

  v_quota := app.capability_consume_v518(
    p_business, 'whatsapp_appointment_notification', v_idem,
    jsonb_build_object('appointment_id', p_appointment, 'kind', p_kind));

  if (v_quota->>'consumed') is distinct from 'true' then
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
    'template_name',v_tpl.meta_name,'idempotency_key',v_idem,
    'remaining', v_quota->'remaining');
end
$fn$;

revoke all on function app.whatsapp_enqueue_appointment_notice_v557(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function app.whatsapp_enqueue_appointment_notice_v557(uuid, uuid, text)
  to service_role;

-- ---------------------------------------------------------------------------
-- 4. "Has this customer already been reminded about this appointment?"
-- ---------------------------------------------------------------------------
-- Deliberately ignores 'failed' rows: v580 fails a reminder whose appointment
-- moved, and that must not count as "already reminded" for the new time.

create or replace function app.appointment_already_reminded_v581(p_appointment uuid)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select exists (
    select 1 from public.whatsapp_template_sends_v557 m
     where m.appointment_id = p_appointment
       and m.kind in ('appointment_reminder','appointment_reminder_short')
       and m.status in ('queued','processing','sent','delivered','read')
  )
$$;

revoke all on function app.appointment_already_reminded_v581(uuid)
  from public, anon, authenticated;
grant execute on function app.appointment_already_reminded_v581(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 5. The sweep gains the short-notice window
-- ---------------------------------------------------------------------------
-- Same cron, same limit semantics, same per-row exception handling as v557.
-- The 24h pass is unchanged. The short pass is a second, narrower question.

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
  v_short integer := 0;
begin
  -- Pass 1: the 24-hour reminder, exactly as before.
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
      v_errored := v_errored + 1;
    end;
  end loop;

  -- Pass 2 (v581): about two hours out, and nobody has been reminded yet.
  -- An hour-wide window against a 30-minute tick, so nothing falls between
  -- ticks; the idempotency key absorbs the second look.
  for v_row in
    select a.id, a.business_id
      from public.appointments a
     where a.status = 'booked'
       and a.starts_at >= now() + interval '90 minutes'
       and a.starts_at <  now() + interval '150 minutes'
       -- ...and they are not still looking at the confirmation. Without this a
       -- booking made 100 minutes ahead would be confirmed and then reminded
       -- inside the same half hour, which is the noise the owner ruled out.
       -- A booking made close to its own start therefore gets a confirmation
       -- and nothing else, which is the right amount of contact.
       and a.created_at <= now() - interval '45 minutes'
       and not app.appointment_already_reminded_v581(a.id)
     order by a.starts_at
     limit greatest(coalesce(p_limit, 200), 1)
  loop
    begin
      v_result := app.whatsapp_enqueue_appointment_notice_v557(
        v_row.business_id, v_row.id, 'appointment_reminder_short');
      if (v_result->>'status') = 'ok' then
        if (v_result->>'duplicate') = 'true' then v_duplicate := v_duplicate + 1;
        else v_short := v_short + 1; end if;
      else
        v_refused := v_refused + 1;
      end if;
    exception when others then
      v_errored := v_errored + 1;
    end;
  end loop;

  return jsonb_build_object(
    'enqueued', v_enqueued, 'short_notice', v_short, 'duplicate', v_duplicate,
    'refused', v_refused, 'errored', v_errored);
end
$fn$;

revoke all on function app.run_whatsapp_reminder_sweep_v557(int)
  from public, anon, authenticated;
grant execute on function app.run_whatsapp_reminder_sweep_v557(int) to service_role;

-- ---------------------------------------------------------------------------
-- 6. Telling the customer it moved
-- ---------------------------------------------------------------------------

create or replace function app.whatsapp_appointment_moved_v581()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
begin
  begin
    perform app.whatsapp_enqueue_appointment_notice_v557(
      new.business_id, new.id, 'appointment_updated');
  exception when others then
    -- Same posture as the confirmation trigger: a rescheduling staff member
    -- must never see their save fail because a message could not be queued.
    null;
  end;
  return null;
end
$fn$;

revoke all on function app.whatsapp_appointment_moved_v581()
  from public, anon, authenticated;

drop trigger if exists whatsapp_appointment_moved_v581 on public.appointments;
create trigger whatsapp_appointment_moved_v581
after update of starts_at on public.appointments
for each row
when (old.starts_at is distinct from new.starts_at and new.status = 'booked')
execute function app.whatsapp_appointment_moved_v581();

commit;
