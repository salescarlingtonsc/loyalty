-- nestly_v508 — a customer reschedule is a FRESH booking request, and the old appointment goes.
--
-- OWNER RULING (2026-08-25, photo 3 of the customer Bookings page): remove "Rebook"; pressing
-- reschedule "should not create a new appointment", it "should act as a fresh appointment sent to
-- business to approve or reject", and "the previously accepted or pending appointment will be
-- deleted from the appointment list".
--
-- WHAT EXISTED. Two half-flows, neither of which is what the owner described:
--   · "Rebook" opened the booking portal and created a brand-new request while the old
--     appointment stayed booked — two live bookings for one visit.
--   · "Change" filed a customer_appointment_action_requests row (v33) that the BUSINESS had to
--     approve before anything moved — the old appointment stayed booked until then, and approval
--     AMENDED it rather than replacing it.
--
-- WHAT THIS IS. One atomic transaction: the customer's booked appointment is cancelled, and a
-- fresh booking_requests row is created in 'pending' — the same state a brand-new portal request
-- arrives in, on the same business worklist, approved or rejected the same way
-- (convert_booking_request). Because it is one transaction, a retry either finds the appointment
-- still booked (the first call failed entirely — safe to run) or finds it cancelled (the first
-- call succeeded — refused as already_actioned); there is no half-state with two bookings or none.
--
-- THE TOKEN IS NOT OPTIONAL. customer_get_booking_requests and
-- customer_withdraw_booking_request_v290 both JOIN app.booking_management_tokens on
-- authenticated_user_id — a request without a token row is INVISIBLE in the customer's own list
-- and impossible to withdraw. The gateway submit path mints one per request; this mints one the
-- same shape. The token VALUE is random and never leaves the database: an authenticated customer
-- is matched by authenticated_user_id, never by presenting the token.
--
-- WHY CANCELLING UNILATERALLY IS CORRECT HERE. The customer has just declared they are not
-- attending the old slot. Holding it booked until the business approves the change (the v33
-- shape) keeps a slot blocked that the customer has renounced, and lets the calendar promise a
-- visit that will not happen. The business keeps full control of the NEW time — that is the
-- request they approve or reject.

begin;

create or replace function public.customer_reschedule_appointment_v508(
  p_business_slug text,
  p_appointment uuid,
  p_preferred_at timestamptz,
  p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_slug text := lower(btrim(coalesce(p_business_slug, '')));
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_identity_id uuid;
  v_link_id uuid;
  v_business_id uuid;
  v_client_id uuid;
  v_enabled_modules text[];
  v_appt public.appointments%rowtype;
  v_client public.clients%rowtype;
  v_request_id uuid := gen_random_uuid();
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if p_preferred_at is null or p_preferred_at <= now() then
    raise exception 'the new time must be in the future' using errcode = '22023';
  end if;
  if v_note is not null and length(v_note) > 750 then
    raise exception 'note must not exceed 750 characters' using errcode = '22023';
  end if;

  -- One reschedule of one appointment at a time, per customer.
  perform pg_advisory_xact_lock(hashtextextended(
    'v508:reschedule:' || v_actor::text || ':' || coalesce(p_appointment::text, ''), 0));

  -- The slug narrows the verified relationship; business, client, identity and link all derive
  -- from auth.uid() — the same shape customer_request_appointment_action uses.
  select ci.id, l.id, l.business_id, l.client_id, coalesce(b.enabled_modules, '{}'::text[])
    into v_identity_id, v_link_id, v_business_id, v_client_id, v_enabled_modules
    from public.customer_identities ci
    join public.customer_links l
      on l.identity_id = ci.id
     and l.auth_user_id = v_actor
     and l.state = 'verified'
    join public.businesses b on b.id = l.business_id
   where ci.auth_user_id = v_actor
     and ci.status = 'active'
     and b.slug = v_slug
   limit 1;
  if not found or not ('appointments' = any(v_enabled_modules)) then
    raise exception 'verified customer link and appointment required' using errcode = '42501';
  end if;

  select * into v_appt
    from public.appointments a
   where a.id = p_appointment
     and a.business_id = v_business_id
     and a.client_id = v_client_id
   for update;
  if not found then
    raise exception 'verified customer link and appointment required' using errcode = '42501';
  end if;
  -- Atomicity IS the idempotency: a successful first call leaves this appointment cancelled, so
  -- a duplicate submit is refused here rather than filing a second request.
  if v_appt.status <> 'booked' then
    raise exception 'already_actioned' using errcode = '22023';
  end if;

  -- The same throttle window the v33 action requests use, over the table this writes.
  if (select count(*) from public.booking_requests r
       where r.business_id = v_business_id
         and r.customer_client_id = v_client_id
         and r.created_at >= now() - interval '15 minutes') >= 5 then
    raise exception 'too many booking requests; try later' using errcode = '42901';
  end if;

  select * into v_client from public.clients c
   where c.id = v_client_id and c.business_id = v_business_id;
  if not found then
    raise exception 'verified customer link and appointment required' using errcode = '42501';
  end if;

  -- 1. The old appointment goes — "deleted from the appointment list" in the owner's words,
  --    cancelled in the ledger's: the row survives for history and reporting, and every list of
  --    live appointments already excludes cancelled rows.
  update public.appointments
     set status = 'cancelled'
   where id = v_appt.id and business_id = v_business_id;

  -- 2. The fresh request, carrying the old appointment's service, staff and branch so the
  --    business sees WHAT is being re-timed, not an anonymous new enquiry. 'pending' is the same
  --    status a portal request arrives in, on the same worklist.
  insert into public.booking_requests(
    id, business_id, name, phone, email, service_id, party_size, preferred_at, notes,
    status, customer_client_id, staff_id, branch_id, marketing_consent
  ) values (
    v_request_id, v_business_id,
    coalesce(nullif(btrim(coalesce(v_client.full_name, '')), ''), 'Customer'),
    v_client.phone, v_client.email,
    v_appt.service_id, 1, p_preferred_at,
    'Reschedule: replaces the cancelled '
      || to_char(v_appt.starts_at at time zone 'Asia/Singapore', 'DD Mon HH24:MI')
      || ' appointment.' || coalesce(' ' || v_note, ''),
    'pending', v_client_id, v_appt.staff_id, v_appt.branch_id, false
  );

  v_result := jsonb_build_object(
    'status', 'pending',
    'request_id', v_request_id,
    'cancelled_appointment_id', v_appt.id,
    'preferred_at', p_preferred_at);

  -- 3. The management token that makes the request visible and withdrawable in the customer's
  --    own list. Random, never returned: the authenticated customer is matched by
  --    authenticated_user_id, exactly as customer_withdraw_booking_request_v290 does.
  insert into app.booking_management_tokens(
    token_hash, idempotency_hash, request_fingerprint,
    business_id, booking_request_id, appointment_id,
    authenticated_user_id, customer_client_id,
    expires_at, initial_response
  ) values (
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')),
    sha256(convert_to('v508:' || v_actor::text || ':' || v_appt.id::text, 'UTF8')),
    sha256(convert_to(v_appt.id::text || ':' || p_preferred_at::text, 'UTF8')),
    v_business_id, v_request_id, null,
    v_actor, v_client_id,
    greatest(p_preferred_at, now()) + interval '30 days', v_result
  );

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (v_business_id, v_actor, 'appointment.rescheduled_as_fresh_request', 'appointments', v_appt.id,
    jsonb_build_object('cancelled_appointment_id', v_appt.id,
      'old_starts_at', v_appt.starts_at,
      'new_request_id', v_request_id,
      'preferred_at', p_preferred_at,
      'source', 'customer_reschedule_v508'));

  return v_result;
end;
$function$;

comment on function public.customer_reschedule_appointment_v508(text,uuid,timestamptz,text) is
  'nestly_v508: a customer reschedule cancels the booked appointment and files a FRESH pending booking request (owner ruling 2026-08-25) — one transaction, business approves or rejects the new time as usual.';

revoke all on function public.customer_reschedule_appointment_v508(text,uuid,timestamptz,text) from public, anon;
grant execute on function public.customer_reschedule_appointment_v508(text,uuid,timestamptz,text) to authenticated;
grant execute on function public.customer_reschedule_appointment_v508(text,uuid,timestamptz,text) to service_role;

commit;
