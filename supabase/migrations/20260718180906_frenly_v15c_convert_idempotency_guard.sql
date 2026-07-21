-- v15c — make convert_booking_request idempotent: never double-convert a request
-- into a 2nd appointment (which would draw the table down twice).
create or replace function public.convert_booking_request(p_request uuid)
returns json
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare req record; v_client uuid; v_start timestamptz; v_end timestamptz; ap public.appointments;
begin
  select * into req from public.booking_requests where id = p_request;
  if not found then raise exception 'request not found'; end if;
  if not app.is_salon_member(req.business_id) then raise exception 'not a member of this business'; end if;
  if req.appointment_id is not null then
    raise exception 'request already converted to an appointment';
  end if;

  v_client := app.upsert_portal_client(req.business_id, req.name, req.phone, req.email);
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
end $fn$;