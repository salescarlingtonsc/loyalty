/* nestly_v689 — four holes in the appointment/booking change path.

   Audit findings F064, F065, F066, F067 (all P2/P3, all confirmed read-only against production
   on 2026-09-02 by reading the live definitions with pg_get_functiondef).

   ------------------------------------------------------------------------------------------
   F064 — "cancel needs approval" was bypassable by Reschedule-then-Withdraw.
   ------------------------------------------------------------------------------------------
   nestly_v663 gave a business the choice: with auto_approve_changes OFF, a customer's Cancel
   becomes a pending public.change_requests row and "the appointment stays booked until they
   answer" (public.customer_cancel_appointment_v655, live). Reschedule never learned that rule.
   public.customer_reschedule_appointment_v508 cancels the booked appointment UNCONDITIONALLY
   and files a fresh public.booking_requests row, which the customer may then withdraw through
   public.customer_withdraw_booking_request_v290. Reschedule then Withdraw is therefore a plain
   cancel that the business is never asked about — the exact act the setting exists to gate.

   The fix mirrors v655 rather than inventing a second grammar: with auto-approve OFF the
   reschedule is a REQUEST. A public.change_requests row of kind 'reschedule' carrying the new
   time is filed, the appointment is left 'booked', and public.decide_change — which already
   knows how to move an appointment on approve — is the one place the new time can land. There
   is nothing to withdraw, because no booking_requests row is created. A second tap while a
   reschedule request is still pending replays that request instead of stacking another, the
   same shape v655 uses for a repeated cancel.

   With auto-approve ON nothing changes at all: the cancel-and-refile behaviour v508 has always
   had is the auto-approving business's own choice, and trg_booking_request_autoapprove_v660
   confirms the new slot in the same transaction.

   ------------------------------------------------------------------------------------------
   F065 — the public slot lister offered slots the write guard would never accept.
   ------------------------------------------------------------------------------------------
   public.internal_public_booking_availability and app.staff_free_for_appointment_v47 /
   app.staff_free_for_appointment_v120_base disagreed in three ways:

     1. The lister tested the EXISTING appointment as a bare [starts_at, ends_at) window. The
        guard blocks [starts - buffer_before, ends + buffer_after) — the existing booking's own
        buffers. A 60-minute service with 15 minutes of cleanup after it left 11:00 offered
        right behind a 10:00-11:00 booking that the guard blocks until 11:15.
     2. The lister built the CANDIDATE block as [slot, slot + duration + before + after). The
        guard builds [slot - before, slot + duration + after) — the same LENGTH, shifted left by
        buffer_before, because the prep time happens before the customer arrives, not after.
     3. The lister never consulted public.branch_breaks at all (the guard refuses any overlap),
        so a 12:30 lunch break was offered to strangers on the public booking page.

   All three are corrected here in the lister, deliberately rather than by having the lister
   call app.staff_free_for_appointment_v47 per slot: that function refuses outright when its
   p_branch is null, and the lister's p_branch is optional, so routing every slot through it
   would empty the booking page for every single-branch firm that does not pass one. The
   branch used for the break lookup is the one the lister already resolved for opening hours,
   falling back to the requested branch and then to app.default_branch, so a weekday with a
   personal staff_hours override but no branch_hours row is still checked against real breaks.

   The pending-booking_requests exclusion below the two corrected clauses is deliberately left
   alone. It compares two REQUESTED slots, both expressed in the lister's own unshifted
   convention, so it is self-consistent; shifting one side only would break it.

   ------------------------------------------------------------------------------------------
   F066 — approving a table-pool reschedule always answered "conflict".
   ------------------------------------------------------------------------------------------
   public.decide_change's reschedule branch calls app.staff_free_for_appointment_v47 with
   v_appointment.staff_id. A table-type booking made through app.request_bound_booking_v72's
   auto-confirm branch inserts an appointment with NO staff_id, and v120_base returns false the
   moment p_staff is null. Every Approve of such a change request therefore returned 'conflict'
   with a suggestion list, on 100% of attempts, and the owner could never accept the guest's
   new time from Bookings.

   The staff guard now applies only when there is a staff member to be busy. It is NOT replaced
   by a table-capacity test: public.v_table_availability counts holds, not time windows, and the
   appointment being moved is ALREADY one of the holds it counts — requiring available > 0 would
   refuse a move that consumes no new capacity. The table-pool booking path itself checks
   capacity only when acquiring a table, never when moving one, and this now matches it.

   ------------------------------------------------------------------------------------------
   F067 — editing a pending request never re-ran auto-approve.
   ------------------------------------------------------------------------------------------
   trg_booking_request_autoapprove_v660 was AFTER INSERT only, so a request left pending because
   its first slot was taken stayed pending after public.customer_amend_booking_request_v627 moved
   it to a free one. The trigger now also fires AFTER UPDATE OF preferred_at, staff_id, branch_id.

   This cannot recurse: app.v660_autoapprove_booking_request's own UPDATE sets status,
   appointment_id and expires_at, none of which are in the OF list, and the helper refuses any
   row that is not still new/pending/waitlisted with a null appointment_id anyway.

   Rollback suite: db/tests/v689_appointment_change_integrity.sql */
begin;

-- =============================================================================================
-- F064 — a reschedule at a business that has not opted into auto-approve is a REQUEST.
--        Three comment-free splices into the live definition; the rest of v508 is untouched.
-- =============================================================================================
do $v689_f064$
declare
  v_def text; v_new text;
  v_decl constant text :=
'  v_result jsonb;
begin';
  v_decl_new constant text :=
'  v_result jsonb;
  v_auto boolean := false;
  v_change_request uuid;
  v_change_phone text;
begin';
  v_read constant text :=
'  select ci.id, l.id, l.business_id, l.client_id, coalesce(b.enabled_modules, ''{}''::text[])
    into v_identity_id, v_link_id, v_business_id, v_client_id, v_enabled_modules';
  v_read_new constant text :=
'  select ci.id, l.id, l.business_id, l.client_id, coalesce(b.enabled_modules, ''{}''::text[]),
         coalesce(b.auto_approve_changes, false)
    into v_identity_id, v_link_id, v_business_id, v_client_id, v_enabled_modules, v_auto';
  v_arm constant text :=
'  if v_appt.status <> ''booked'' then
    raise exception ''already_actioned'' using errcode = ''22023'';
  end if;

  if (select count(*) from public.booking_requests r';
  v_arm_new constant text :=
'  if v_appt.status <> ''booked'' then
    raise exception ''already_actioned'' using errcode = ''22023'';
  end if;

  if not v_auto then
    select r.id into v_change_request
      from public.change_requests r
     where r.business_id = v_business_id
       and r.appointment_id = v_appt.id
       and r.kind = ''reschedule''
       and r.status = ''pending''
     order by r.created_at
     limit 1;
    if found then
      return jsonb_build_object(''status'', ''pending'', ''auto_approved'', false,
        ''appointment_id'', v_appt.id, ''request_id'', v_change_request,
        ''change_request_id'', v_change_request, ''preferred_at'', p_preferred_at,
        ''kept_booked'', true, ''replayed'', true);
    end if;
    select c.phone into v_change_phone from public.clients c
     where c.id = v_client_id and c.business_id = v_business_id;
    insert into public.change_requests(
      business_id, appointment_id, kind, proposed_at, phone, note, status)
    values (v_business_id, v_appt.id, ''reschedule'', p_preferred_at, v_change_phone,
      coalesce(v_note, ''A new time was asked for in the Peekaa app.''), ''pending'')
    returning id into v_change_request;
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (v_business_id, v_actor, ''appointment.reschedule_requested_by_customer'',
      ''appointments'', v_appt.id,
      jsonb_build_object(''client_id'', v_client_id, ''starts_at'', v_appt.starts_at,
        ''preferred_at'', p_preferred_at, ''change_request_id'', v_change_request,
        ''source'', ''v689''));
    return jsonb_build_object(''status'', ''pending'', ''auto_approved'', false,
      ''appointment_id'', v_appt.id, ''request_id'', v_change_request,
      ''change_request_id'', v_change_request, ''preferred_at'', p_preferred_at,
      ''kept_booked'', true, ''replayed'', false);
  end if;

  if (select count(*) from public.booking_requests r';
begin
  v_def := pg_get_functiondef(
    'public.customer_reschedule_appointment_v508(text,uuid,timestamptz,text)'::regprocedure);
  if position('kept_booked' in v_def) > 0 then
    raise notice 'nestly_v689: v508 already files a reschedule request, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_decl, ''))) / nullif(length(v_decl),0) <> 1
       or (length(v_def) - length(replace(v_def, v_read, ''))) / nullif(length(v_read),0) <> 1
       or (length(v_def) - length(replace(v_def, v_arm, ''))) / nullif(length(v_arm),0) <> 1 then
      raise exception 'nestly_v689: a v508 anchor did not match exactly once — the body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(replace(replace(v_def, v_decl, v_decl_new), v_read, v_read_new),
                     v_arm, v_arm_new);
    if v_new = v_def then
      raise exception 'nestly_v689: the v508 splice produced no change' using errcode = 'XX001';
    end if;
    execute v_new;
  end if;
end
$v689_f064$;
revoke all on function public.customer_reschedule_appointment_v508(text,uuid,timestamptz,text)
  from public, anon;
grant execute on function public.customer_reschedule_appointment_v508(text,uuid,timestamptz,text)
  to authenticated, service_role;

-- =============================================================================================
-- F065 — the public slot lister now applies the same buffers and breaks the write guard does.
-- =============================================================================================
do $v689_f065$
declare
  v_def text; v_new text;
  v_declare constant text :=
'  v_earliest timestamptz := statement_timestamp() + interval ''15 minutes'';';
  v_declare_new constant text :=
'  v_earliest timestamptz := statement_timestamp() + interval ''15 minutes'';
  v_buffer_before integer := 0;
  v_break_branch uuid;';
  v_dur constant text :=
'  v_duration := greatest(coalesce(v_duration, 60), 5);';
  v_dur_new constant text :=
'  v_duration := greatest(coalesce(v_duration, 60), 5);
  select coalesce(service.buffer_before_min, 0)
    into v_buffer_before
    from public.services service
   where service.id = p_service
     and service.business_id = v_business.id;
  v_buffer_before := greatest(coalesce(v_buffer_before, 0), 0);
  v_break_branch := coalesce(p_branch, app.default_branch(v_business.id));';
  v_lat constant text :=
'      left join lateral (
        select hours.opens_at, hours.closes_at
          from public.branch_hours hours';
  v_lat_new constant text :=
'      left join lateral (
        select hours.opens_at, hours.closes_at, branch_row.id as branch_id
          from public.branch_hours hours';
  v_win constant text :=
'    select calendar.day,
           member.staff_id,
           coalesce(own.starts_at, branch.opens_at) as starts_at,
           coalesce(own.ends_at, branch.closes_at) as ends_at
      from calendar';
  v_win_new constant text :=
'    select calendar.day,
           member.staff_id,
           coalesce(branch.branch_id, v_break_branch) as branch_id,
           coalesce(own.starts_at, branch.opens_at) as starts_at,
           coalesce(own.ends_at, branch.closes_at) as ends_at
      from calendar';
  v_slots constant text :=
'  ), slots as (
    select windows.day,
           windows.staff_id,
           slot_at
      from windows';
  v_slots_new constant text :=
'  ), slots as (
    select windows.day,
           windows.staff_id,
           windows.branch_id,
           slot_at
      from windows';
  v_free constant text :=
'       and not exists (
         select 1 from public.appointments booked
          where booked.business_id = v_business.id
            and booked.staff_id = slots.staff_id
            and booked.status not in (''cancelled'', ''no_show'', ''declined'')
            and tstzrange(booked.starts_at,
                          coalesce(booked.ends_at, booked.starts_at + interval ''1 hour''), ''[)'')
                && tstzrange(slots.slot_at, slots.slot_at + make_interval(mins => v_duration), ''[)'')
       )
       and not exists (
         select 1 from public.staff_blocked_times blocked
          where blocked.business_id = v_business.id
            and blocked.staff_id = slots.staff_id
            and tstzrange(blocked.starts_at, blocked.ends_at, ''[)'')
                && tstzrange(slots.slot_at, slots.slot_at + make_interval(mins => v_duration), ''[)'')
       )';
  v_free_new constant text :=
'       and not exists (
         select 1 from public.appointments booked
          left join public.services booked_service
            on booked_service.id = booked.service_id
           and booked_service.business_id = booked.business_id
          where booked.business_id = v_business.id
            and booked.staff_id = slots.staff_id
            and booked.status not in (''cancelled'', ''no_show'', ''declined'')
            and tstzrange(
                  booked.starts_at
                    - make_interval(mins => coalesce(booked_service.buffer_before_min, 0)),
                  coalesce(booked.ends_at, booked.starts_at + interval ''1 hour'')
                    + make_interval(mins => coalesce(booked_service.buffer_after_min, 0)), ''[)'')
                && tstzrange(slots.slot_at - make_interval(mins => v_buffer_before),
                             slots.slot_at - make_interval(mins => v_buffer_before)
                               + make_interval(mins => v_duration), ''[)'')
       )
       and not exists (
         select 1 from public.staff_blocked_times blocked
          where blocked.business_id = v_business.id
            and blocked.staff_id = slots.staff_id
            and tstzrange(blocked.starts_at, blocked.ends_at, ''[)'')
                && tstzrange(slots.slot_at - make_interval(mins => v_buffer_before),
                             slots.slot_at - make_interval(mins => v_buffer_before)
                               + make_interval(mins => v_duration), ''[)'')
       )
       and not exists (
         select 1 from public.branch_breaks pause
          where pause.business_id = v_business.id
            and pause.branch_id = slots.branch_id
            and pause.weekday = extract(dow from
                  (slots.slot_at - make_interval(mins => v_buffer_before))
                    at time zone ''Asia/Singapore'')::smallint
            and pause.starts_at < ((slots.slot_at - make_interval(mins => v_buffer_before)
                  + make_interval(mins => v_duration)) at time zone ''Asia/Singapore'')::time
            and pause.ends_at > ((slots.slot_at - make_interval(mins => v_buffer_before))
                  at time zone ''Asia/Singapore'')::time
       )';
begin
  v_def := pg_get_functiondef(
    'public.internal_public_booking_availability(text,uuid,uuid,date,integer,uuid)'::regprocedure);
  if position('branch_breaks' in v_def) > 0 then
    raise notice 'nestly_v689: the slot lister already honours branch breaks, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_declare, ''))) / nullif(length(v_declare),0) <> 1
       or (length(v_def) - length(replace(v_def, v_dur, ''))) / nullif(length(v_dur),0) <> 1
       or (length(v_def) - length(replace(v_def, v_lat, ''))) / nullif(length(v_lat),0) <> 1
       or (length(v_def) - length(replace(v_def, v_win, ''))) / nullif(length(v_win),0) <> 1
       or (length(v_def) - length(replace(v_def, v_slots, ''))) / nullif(length(v_slots),0) <> 1
       or (length(v_def) - length(replace(v_def, v_free, ''))) / nullif(length(v_free),0) <> 1 then
      raise exception 'nestly_v689: a slot-lister anchor did not match exactly once — body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_declare, v_declare_new);
    v_new := replace(v_new, v_dur, v_dur_new);
    v_new := replace(v_new, v_lat, v_lat_new);
    v_new := replace(v_new, v_win, v_win_new);
    v_new := replace(v_new, v_slots, v_slots_new);
    v_new := replace(v_new, v_free, v_free_new);
    if v_new = v_def then
      raise exception 'nestly_v689: the slot-lister splice produced no change' using errcode = 'XX001';
    end if;
    execute v_new;
  end if;
end
$v689_f065$;
revoke all on function public.internal_public_booking_availability(text,uuid,uuid,date,integer,uuid)
  from public;
grant execute on function public.internal_public_booking_availability(text,uuid,uuid,date,integer,uuid)
  to anon, authenticated, service_role;

-- =============================================================================================
-- F066 — the staff guard applies only when the appointment has a staff member.
-- =============================================================================================
do $v689_f066$
declare
  v_def text; v_new text;
  v_anchor constant text :=
'    if v_request.proposed_at is null
       or not app.staff_free_for_appointment_v47(
         v_request.business_id,v_appointment.staff_id,v_appointment.branch_id,
         v_appointment.service_id,v_request.proposed_at,
         v_request.proposed_at+make_interval(mins=>v_duration),v_appointment.id) then';
  v_inject constant text :=
'    if v_request.proposed_at is null
       or (v_appointment.staff_id is not null
           and not app.staff_free_for_appointment_v47(
             v_request.business_id,v_appointment.staff_id,v_appointment.branch_id,
             v_appointment.service_id,v_request.proposed_at,
             v_request.proposed_at+make_interval(mins=>v_duration),v_appointment.id)) then';
begin
  v_def := pg_get_functiondef('public.decide_change(uuid,boolean)'::regprocedure);
  if position('and not app.staff_free_for_appointment_v47' in v_def) > 0 then
    raise notice 'nestly_v689: decide_change already skips the staff guard, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_anchor, ''))) / nullif(length(v_anchor),0) <> 1 then
      raise exception 'nestly_v689: the decide_change anchor did not match exactly once'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_anchor, v_inject);
    if v_new = v_def then
      raise exception 'nestly_v689: the decide_change splice produced no change' using errcode = 'XX001';
    end if;
    execute v_new;
  end if;
end
$v689_f066$;
revoke all on function public.decide_change(uuid,boolean) from public, anon;
grant execute on function public.decide_change(uuid,boolean) to authenticated, service_role;

-- =============================================================================================
-- F067 — moving a pending request to a free slot re-runs auto-approve.
-- =============================================================================================
drop trigger if exists trg_booking_request_autoapprove_v660 on public.booking_requests;
create trigger trg_booking_request_autoapprove_v660
  after insert or update of preferred_at, staff_id, branch_id on public.booking_requests
  for each row execute function app.v660_booking_request_autoapprove();

-- =============================================================================================
-- Prove all four changes took, in the transaction that made them.
-- =============================================================================================
do $verify$
declare
  v_v508 text := pg_get_functiondef(
    'public.customer_reschedule_appointment_v508(text,uuid,timestamptz,text)'::regprocedure);
  v_lister text := pg_get_functiondef(
    'public.internal_public_booking_availability(text,uuid,uuid,date,integer,uuid)'::regprocedure);
  v_decide text := pg_get_functiondef('public.decide_change(uuid,boolean)'::regprocedure);
  v_trigger text;
begin
  if position('kept_booked' in v_v508) = 0
     or position('reschedule_requested_by_customer' in v_v508) = 0 then
    raise exception 'nestly_v689 (F064): v508 still cancels without asking the business'
      using errcode = 'XX001';
  end if;
  if position('branch_breaks' in v_lister) = 0
     or position('booked_service.buffer_after_min' in v_lister) = 0
     or position('v_buffer_before' in v_lister) = 0 then
    raise exception 'nestly_v689 (F065): the slot lister still disagrees with the write guard'
      using errcode = 'XX001';
  end if;
  if position('and not app.staff_free_for_appointment_v47' in v_decide) = 0 then
    raise exception 'nestly_v689 (F066): decide_change still refuses staff-less appointments'
      using errcode = 'XX001';
  end if;
  select pg_get_triggerdef(t.oid) into v_trigger
    from pg_trigger t
   where t.tgrelid = 'public.booking_requests'::regclass
     and t.tgname = 'trg_booking_request_autoapprove_v660';
  if v_trigger is null or position('UPDATE OF' in upper(v_trigger)) = 0 then
    raise exception 'nestly_v689 (F067): auto-approve still fires on INSERT only'
      using errcode = 'XX001';
  end if;
end
$verify$;

commit;
