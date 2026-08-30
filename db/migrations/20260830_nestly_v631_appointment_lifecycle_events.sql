-- NESTLY v631 — Phase A, M4 (A3): appointment lifecycle history.
-- Today the only record of WHEN an appointment completed / was cancelled / was marked
-- no-show is audit_log.created_at, cancellation reasons are scattered free text, and
-- reschedule history is split across three paths — one complete but unreadable
-- (app.appointment_reschedule_operations, service-role only, zero readers), one lossy
-- (decide_change overwrites starts_at in place), one a fossil (v33's status CHECK('pending')).
--
-- This migration:
--   1. appointment_status_events — one append-only row per status transition, written by
--      an AFTER UPDATE OF status trigger so EVERY path (present and future) is captured
--      without touching any RPC. Reason/note arrive via transaction-local context.
--   2. set_appointment_status_with_reason_v631 — a thin wrapper the UI can adopt to pass
--      a structured cancellation/no-show reason. The existing RPC keeps working unchanged.
--   3. decide_change re-emitted byte-faithfully with one addition: an approved reschedule
--      now writes the same app.appointment_reschedule_operations row the calendar path
--      writes, closing the lossy branch. (Table-pool appointments with no staff are
--      skipped: the v48 table's requested_staff_id is NOT NULL and its contract is not
--      renegotiated here.)
--   4. get_appointment_history_v1 — the first tenant-scoped reader over both tables.
--   5. Partial backfill of transition times from audit_log APPOINTMENT_STATUS rows
--      (from_status unknown -> null, marked 'backfill:audit_log').
begin;

-- ---------------------------------------------------------------------------
-- 1. The event table.
-- ---------------------------------------------------------------------------
create table public.appointment_status_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  appointment_id uuid not null,
  from_status text,
  to_status text not null,
  at timestamptz not null default clock_timestamp(),
  actor uuid,
  actor_kind text not null check (actor_kind in ('staff','customer','system')),
  reason_code text check (reason_code is null or reason_code in
    ('customer_request','business_closed','staff_unavailable','no_show_policy',
     'duplicate','weather','other')),
  note text,
  created_at timestamptz not null default now(),
  foreign key (appointment_id, business_id)
    references public.appointments(id, business_id) on delete cascade
);
create index appointment_status_events_appt_idx
  on public.appointment_status_events (business_id, appointment_id, at);
alter table public.appointment_status_events enable row level security;
create policy appointment_status_events_member_read on public.appointment_status_events
  for select to authenticated
  using (app.is_salon_member(business_id) or app.is_super_admin());
revoke all on public.appointment_status_events from public, anon, authenticated;
grant select on public.appointment_status_events to authenticated;

create or replace function app.appointment_status_events_guard_v631()
returns trigger language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'appointment_status_events is append-only' using errcode = '42501';
end;
$$;
create trigger trg_appointment_status_events_append_only
  before update or delete on public.appointment_status_events
  for each row execute function app.appointment_status_events_guard_v631();

-- ---------------------------------------------------------------------------
-- 2. The capture trigger. Fires on every status change from any path.
-- ---------------------------------------------------------------------------
create or replace function app.appointments_status_event_v631()
returns trigger language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_kind text;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;
  if v_actor is null then
    v_kind := 'system';
  elsif exists (select 1 from public.staff s
                 where s.user_id = v_actor and s.business_id = new.business_id) then
    v_kind := 'staff';
  else
    v_kind := 'customer';
  end if;
  insert into public.appointment_status_events
    (business_id, appointment_id, from_status, to_status, actor, actor_kind, reason_code, note)
  values (
    new.business_id, new.id, old.status, new.status, v_actor, v_kind,
    nullif(current_setting('app.appt_status_reason_code', true), ''),
    nullif(current_setting('app.appt_status_note', true), '')
  );
  return new;
end;
$$;
create trigger trg_appointments_status_event_v631
  after update of status on public.appointments
  for each row execute function app.appointments_status_event_v631();

-- ---------------------------------------------------------------------------
-- 3. Reason-carrying wrapper. Same authorization as the wrapped RPC (it
--    delegates immediately); validates the reason vocabulary, then clears the
--    context so a later status change in the same transaction cannot inherit it.
-- ---------------------------------------------------------------------------
create or replace function public.set_appointment_status_with_reason_v631(
  p_business uuid, p_appointment uuid, p_status text,
  p_reason_code text default null, p_note text default null)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_result json;
begin
  if p_reason_code is not null and p_reason_code not in
     ('customer_request','business_closed','staff_unavailable','no_show_policy',
      'duplicate','weather','other') then
    raise exception 'unsupported status reason %', p_reason_code using errcode = '22023';
  end if;
  if p_note is not null and length(btrim(p_note)) > 300 then
    raise exception 'status note is too long' using errcode = '22023';
  end if;
  perform set_config('app.appt_status_reason_code', coalesce(p_reason_code, ''), true);
  perform set_config('app.appt_status_note', coalesce(nullif(btrim(p_note), ''), ''), true);
  v_result := public.set_appointment_status_v47(p_business, p_appointment, p_status);
  perform set_config('app.appt_status_reason_code', '', true);
  perform set_config('app.appt_status_note', '', true);
  return v_result;
end;
$$;
revoke all on function public.set_appointment_status_with_reason_v631(uuid,uuid,text,text,text) from public, anon;
grant execute on function public.set_appointment_status_with_reason_v631(uuid,uuid,text,text,text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. decide_change: byte-faithful re-emission of the live body (read
--    2026-08-30) with one addition marked -- v631 in the reschedule branch.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.decide_change(p_request uuid, p_approve boolean)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_request public.change_requests%rowtype;
  v_appointment public.appointments%rowtype;
  v_duration integer;
  v_suggestions jsonb;
begin
  select request.* into v_request
    from public.change_requests request where request.id=p_request for update;
  if not found then raise exception 'change request not found' using errcode='22023'; end if;
  select appointment.* into v_appointment
    from public.appointments appointment
   where appointment.id=v_request.appointment_id
     and appointment.business_id=v_request.business_id
   for update;
  if not found then raise exception 'appointment not found' using errcode='22023'; end if;
  if auth.uid() is null
     or not app.can_module_write(v_request.business_id,'appointments')
     or not app.can_see_branch(v_request.business_id,v_appointment.branch_id) then
    raise exception 'appointment write access for this branch is required' using errcode='42501';
  end if;
  if v_request.status<>'pending' then
    raise exception 'change request is already %',v_request.status using errcode='22023';
  end if;
  if not p_approve then
    update public.change_requests set status='declined',decided_at=clock_timestamp()
     where id=p_request;
    return json_build_object('id',p_request,'status','declined','kind',v_request.kind);
  end if;
  if v_appointment.status<>'booked' then
    raise exception 'appointment is no longer booked' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_request.business_id::text,47));
  if v_request.kind='reschedule' then
    v_duration:=greatest(15,ceil(extract(epoch from
      (v_appointment.ends_at-v_appointment.starts_at))/60)::integer);
    if v_request.proposed_at is null
       or not app.staff_free_for_appointment_v47(
         v_request.business_id,v_appointment.staff_id,v_appointment.branch_id,
         v_appointment.service_id,v_request.proposed_at,
         v_request.proposed_at+make_interval(mins=>v_duration),v_appointment.id) then
      v_suggestions:=public.suggest_appointment_staff_v47(
        v_request.business_id,v_appointment.branch_id,v_appointment.service_id,
        coalesce(v_request.proposed_at,clock_timestamp()),v_duration,5);
      return json_build_object('id',p_request,'status','conflict','kind',v_request.kind,
        'suggestions',v_suggestions);
    end if;
    -- v631: the prior time is history, not scrap. Record the same operation row the
    -- calendar reschedule path records, so this branch stops being the lossy one.
    -- Table-pool appointments (no staff) are skipped: the v48 table requires a staff id
    -- and its contract is not changed here.
    if v_appointment.staff_id is not null then
      insert into app.appointment_reschedule_operations(
        business_id, idempotency_key, request_hash, appointment_id, actor,
        old_starts_at, old_ends_at, old_staff_id,
        requested_starts_at, requested_ends_at, requested_staff_id,
        outcome, notification_state, response
      ) values (
        v_request.business_id,
        p_request,
        encode(sha256(convert_to(jsonb_build_object(
          'source','decide_change_v631','request',p_request,
          'proposed_at',v_request.proposed_at)::text, 'utf8')), 'hex'),
        v_appointment.id,
        auth.uid(),
        v_appointment.starts_at,
        v_appointment.ends_at,
        v_appointment.staff_id,
        v_request.proposed_at,
        v_request.proposed_at+make_interval(mins=>v_duration),
        v_appointment.staff_id,
        'rescheduled',
        'not_applicable',
        jsonb_build_object('via','decide_change','request_id',p_request)
      ) on conflict (business_id, idempotency_key) do nothing;
    end if;
    update public.appointments
       set starts_at=v_request.proposed_at,
           ends_at=v_request.proposed_at+make_interval(mins=>v_duration)
     where id=v_appointment.id;
  elsif v_request.kind='cancel' then
    -- v631: a guest-approved cancellation carries its structured reason to the
    -- status-event trigger.
    perform set_config('app.appt_status_reason_code','customer_request',true);
    update public.appointments set status='cancelled' where id=v_appointment.id;
    perform set_config('app.appt_status_reason_code','',true);
  else
    raise exception 'unsupported change request type' using errcode='22023';
  end if;
  update public.change_requests set status='approved',decided_at=clock_timestamp()
   where id=p_request;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (v_request.business_id,auth.uid(),'APPOINTMENT_CHANGE_APPROVE','appointments',
    v_appointment.id,jsonb_build_object('request_id',p_request,'kind',v_request.kind,
      'proposed_at',v_request.proposed_at));
  return json_build_object('id',p_request,'status','approved','kind',v_request.kind);
end
$function$;

-- ACL restated verbatim from live proacl:
revoke all on function public.decide_change(uuid,boolean) from public, anon;
grant execute on function public.decide_change(uuid,boolean) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. The first tenant-scoped reader over both history tables.
-- ---------------------------------------------------------------------------
create or replace function public.get_appointment_history_v1(p_business uuid, p_appointment uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_branch uuid;
begin
  select a.branch_id into v_branch
    from public.appointments a
   where a.id = p_appointment and a.business_id = p_business;
  if not found then
    raise exception 'appointment not found' using errcode = '22023';
  end if;
  if auth.uid() is null
     or not app.can_module(p_business, 'appointments')
     or not app.can_see_branch(p_business, v_branch) then
    raise exception 'appointment read access is required' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'appointment_id', p_appointment,
    'status_events', coalesce((
      select jsonb_agg(jsonb_build_object(
               'from_status', e.from_status, 'to_status', e.to_status,
               'at', e.at, 'actor_kind', e.actor_kind,
               'reason_code', e.reason_code, 'note', e.note)
             order by e.at)
        from public.appointment_status_events e
       where e.business_id = p_business and e.appointment_id = p_appointment
    ), '[]'::jsonb),
    'reschedules', coalesce((
      select jsonb_agg(jsonb_build_object(
               'old_starts_at', o.old_starts_at, 'new_starts_at', o.requested_starts_at,
               'old_staff_id', o.old_staff_id, 'new_staff_id', o.requested_staff_id,
               'outcome', o.outcome, 'at', o.created_at)
             order by o.created_at)
        from app.appointment_reschedule_operations o
       where o.business_id = p_business and o.appointment_id = p_appointment
         and o.outcome = 'rescheduled'
    ), '[]'::jsonb)
  );
end;
$$;
revoke all on function public.get_appointment_history_v1(uuid,uuid) from public, anon;
grant execute on function public.get_appointment_history_v1(uuid,uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Partial backfill: transition times recoverable from audit_log
--    APPOINTMENT_STATUS rows. from_status is honestly null; the note marks the
--    provenance. Actor kind is 'system' — the original actor's role is not
--    re-derived from today's staff table (people change roles).
-- ---------------------------------------------------------------------------
insert into public.appointment_status_events
  (business_id, appointment_id, from_status, to_status, at, actor, actor_kind, note)
select a.business_id, a.entity_id,
       a.detail->>'from',
       a.detail->>'to',
       a.created_at, a.actor, 'system', 'backfill:audit_log'
  from public.audit_log a
 where a.action = 'APPOINTMENT_STATUS'
   and a.entity = 'appointments'
   and a.detail->>'to' is not null
   and exists (select 1 from public.appointments ap
                where ap.id = a.entity_id and ap.business_id = a.business_id);

-- ---------------------------------------------------------------------------
-- 7. Watermark.
-- ---------------------------------------------------------------------------
insert into public.analytics_observation_watermarks (metric_key, observed_since, reason)
values ('appointment_lifecycle_events', now(),
        'status transitions carry structured events from v631; audit_log backfill covers times only, reasons begin now');

commit;
