-- v15d: persist the public booking portal's marketing-consent checkbox.
-- (1) Store the choice on the booking request; (2) thread a p_consent param through
-- request_booking; (3) when a booking becomes a client (auto-confirm path AND
-- convert_booking_request) escalate the client's consent (never downgrade) and append
-- a PDPA consents ledger row, mirroring join_program / quick_add_client.

-- 1) New column on booking_requests.
alter table public.booking_requests
  add column if not exists marketing_consent boolean not null default false;

-- 2) Shared helper: apply a booking's consent to the created/matched client.
--    Escalate-only on the live flag; always append the decision to the consents ledger.
create or replace function app.apply_booking_consent(p_biz uuid, p_client uuid, p_consent boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if p_client is null then return; end if;

  -- Escalate only: false -> true. Never downgrade an existing opt-in back to false.
  if coalesce(p_consent, false) then
    update public.clients
       set marketing_consent = true
     where id = p_client and marketing_consent = false;
  end if;

  -- PDPA: record the consent decision at the moment it was made, with its source.
  insert into public.consents (business_id, client_id, channel, action, source)
  values (p_biz, p_client, 'marketing',
          case when coalesce(p_consent, false) then 'granted' else 'withdrawn' end,
          'booking');
end $function$;

-- 3) request_booking: add trailing p_consent (defaults false -> old positional callers
--    keep working). Adding a parameter changes the identity, so drop the 9-arg overload
--    first, then recreate as the single 10-arg function and restore grants.
drop function if exists public.request_booking(text, text, text, text, uuid, integer, timestamptz, text, uuid);

create or replace function public.request_booking(
  p_slug text, p_name text, p_email text, p_phone text, p_service uuid,
  p_party integer, p_preferred timestamptz, p_notes text,
  p_table_type uuid default null, p_consent boolean default false)
 returns json
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_biz uuid; v_overflow text; v_hold int; v_auto boolean;
  v_avail int; v_client uuid; v_id uuid; v_appt public.appointments; v_ttid uuid; v_dur int;
begin
  select id, booking_overflow, booking_hold_minutes, booking_auto_confirm
    into v_biz, v_overflow, v_hold, v_auto
    from public.businesses where slug = p_slug;
  if v_biz is null then raise exception 'business not found'; end if;
  if p_name is null or length(trim(p_name)) < 2 then raise exception 'name required'; end if;

  -- Services-only / salon style (no table): unchanged -> 'new', firm confirms manually.
  if p_table_type is null then
    insert into public.booking_requests (business_id, name, email, phone, service_id,
                                         party_size, preferred_at, notes, status, marketing_consent)
    values (v_biz, trim(p_name), p_email, p_phone, p_service, p_party, p_preferred, p_notes, 'new',
            coalesce(p_consent, false))
    returning id into v_id;
    return json_build_object('status','pending','request_id', v_id);
  end if;

  -- Table chosen: lock the type row to serialise concurrent draw-down, validate ownership.
  select bt.id into v_ttid
    from public.booking_tables bt
   where bt.id = p_table_type and bt.business_id = v_biz and bt.active
   for update;
  if v_ttid is null then raise exception 'invalid table type'; end if;

  select available into v_avail from public.v_table_availability where table_type_id = p_table_type;
  v_avail := coalesce(v_avail, 0);

  if v_avail > 0 then
    if v_auto then
      -- Auto-confirm: create client + real appointment (draws down), record confirmed request.
      v_client := app.upsert_portal_client(v_biz, p_name, p_phone, p_email);
      perform app.apply_booking_consent(v_biz, v_client, p_consent);
      v_dur := coalesce((select duration_min from public.services where id = p_service), 60);
      insert into public.appointments (business_id, client_id, service_id, starts_at, ends_at,
                                       status, party_size, source, note, table_type_id)
      values (v_biz, v_client, p_service,
              coalesce(p_preferred, now() + interval '1 day'),
              coalesce(p_preferred, now() + interval '1 day') + make_interval(mins => greatest(v_dur,1)),
              'booked', p_party, 'portal', p_notes, p_table_type)
      returning * into v_appt;
      insert into public.booking_requests (business_id, name, email, phone, service_id,
                                           party_size, preferred_at, notes, status,
                                           table_type_id, appointment_id, marketing_consent)
      values (v_biz, trim(p_name), p_email, p_phone, p_service, p_party, p_preferred, p_notes,
              'confirmed', p_table_type, v_appt.id, coalesce(p_consent, false))
      returning id into v_id;
      return json_build_object('status','confirmed','request_id', v_id, 'appointment_id', v_appt.id);
    else
      -- Manual-confirm firm: hold the table as 'pending' with a countdown (WS3).
      insert into public.booking_requests (business_id, name, email, phone, service_id,
                                           party_size, preferred_at, notes, status,
                                           table_type_id, expires_at, marketing_consent)
      values (v_biz, trim(p_name), p_email, p_phone, p_service, p_party, p_preferred, p_notes,
              'pending', p_table_type,
              case when v_hold > 0 then now() + make_interval(mins => v_hold) else null end,
              coalesce(p_consent, false))
      returning id into v_id;
      return json_build_object('status','pending','request_id', v_id);
    end if;
  else
    -- No capacity: overflow policy decides.
    if v_overflow = 'reject' then
      insert into public.booking_requests (business_id, name, email, phone, service_id,
                                           party_size, preferred_at, notes, status, table_type_id,
                                           marketing_consent)
      values (v_biz, trim(p_name), p_email, p_phone, p_service, p_party, p_preferred,
              trim(coalesce(p_notes,'') || ' [auto-declined: no capacity]'), 'declined', p_table_type,
              coalesce(p_consent, false))
      returning id into v_id;
      return json_build_object('status','rejected','request_id', v_id);
    else
      insert into public.booking_requests (business_id, name, email, phone, service_id,
                                           party_size, preferred_at, notes, status, table_type_id,
                                           marketing_consent)
      values (v_biz, trim(p_name), p_email, p_phone, p_service, p_party, p_preferred, p_notes,
              'waitlisted', p_table_type, coalesce(p_consent, false))
      returning id into v_id;
      insert into public.waitlist (business_id, name, phone, service_id, preferred, notes,
                                   status, booking_request_id, table_type_id)
      values (v_biz, trim(p_name), p_phone, p_service,
              to_char(coalesce(p_preferred, now()) at time zone 'Asia/Singapore', 'YYYY-MM-DD HH24:MI'),
              p_notes, 'waiting', v_id, p_table_type);
      return json_build_object('status','waitlisted','request_id', v_id);
    end if;
  end if;
end $function$;

grant execute on function
  public.request_booking(text, text, text, text, uuid, integer, timestamptz, text, uuid, boolean)
  to anon, authenticated, service_role;

-- 4) convert_booking_request: apply the stored booking consent to the created/matched
--    client when a held/pending request becomes a real appointment. Signature unchanged.
create or replace function public.convert_booking_request(p_request uuid)
 returns json
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare req record; v_client uuid; v_start timestamptz; v_end timestamptz; ap public.appointments;
begin
  select * into req from public.booking_requests where id = p_request;
  if not found then raise exception 'request not found'; end if;
  if not app.is_salon_member(req.business_id) then raise exception 'not a member of this business'; end if;
  if req.appointment_id is not null then
    raise exception 'request already converted to an appointment';
  end if;

  v_client := app.upsert_portal_client(req.business_id, req.name, req.phone, req.email);
  perform app.apply_booking_consent(req.business_id, v_client, req.marketing_consent);
  v_start := coalesce(req.preferred_at, now() + interval '1 day');
  v_end := v_start + coalesce((select make_interval(mins => greatest(duration_min,1))
            from public.services where id = req.service_id), interval '60 minutes');
  insert into public.appointments (business_id, client_id, service_id, starts_at, ends_at,
                                   status, party_size, source, note, table_type_id)
  values (req.business_id, v_client, req.service_id, v_start, v_end,
          'booked', req.party_size, 'portal', req.notes, req.table_type_id)
  returning * into ap;
  update public.booking_requests
     set status = 'confirmed', appointment_id = ap.id, expires_at = null
   where id = p_request;
  return row_to_json(ap);
end $function$;