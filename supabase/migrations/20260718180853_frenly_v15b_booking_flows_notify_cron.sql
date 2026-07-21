-- ============================================================================
-- Frenly v15b — booking flows (auto-confirm / waitlist / reject / pending-hold),
-- realtime notifications, hold-expiry sweep + cron, intl-phone matching, CSV import.
-- ============================================================================

-- ---------- WS5: notification triggers (insert as owner; bypass RLS) ----------
create or replace function app.notify_on_booking_request()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_when text;
begin
  -- bulk CSV import sets this GUC to avoid one toast per imported row
  if coalesce(current_setting('app.suppress_booking_notify', true), '') = 'on' then
    return new;
  end if;
  v_when := case when new.preferred_at is not null
                 then to_char(new.preferred_at at time zone 'Asia/Singapore', 'Dy DD Mon HH24:MI')
                 else 'no time given' end;
  if new.status in ('new','pending','confirmed') then
    insert into public.notifications(business_id, kind, title, body, ref_table, ref_id)
    values (new.business_id, 'booking_new',
            case when new.status = 'confirmed' then 'New booking (confirmed)'
                 else 'New booking request' end,
            coalesce(new.name,'A guest')
              || case when new.party_size is not null then ', party ' || new.party_size else '' end
              || ' — ' || v_when,
            'booking_requests', new.id);
  elsif new.status = 'waitlisted' then
    insert into public.notifications(business_id, kind, title, body, ref_table, ref_id)
    values (new.business_id, 'booking_waitlisted', 'Added to waitlist',
            coalesce(new.name,'A guest')
              || case when new.party_size is not null then ', party ' || new.party_size else '' end
              || ' — no tables free',
            'booking_requests', new.id);
  end if;
  return new;
end $fn$;

drop trigger if exists trg_booking_request_notify on public.booking_requests;
create trigger trg_booking_request_notify
  after insert on public.booking_requests
  for each row execute function app.notify_on_booking_request();

create or replace function app.notify_on_change_request()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_when text; v_name text;
begin
  select c.full_name into v_name
    from public.appointments a join public.clients c on c.id = a.client_id
   where a.id = new.appointment_id;
  v_when := case when new.proposed_at is not null
                 then to_char(new.proposed_at at time zone 'Asia/Singapore', 'Dy DD Mon HH24:MI')
                 else null end;
  insert into public.notifications(business_id, kind, title, body, ref_table, ref_id)
  values (new.business_id, 'change_request',
          case when new.kind = 'cancel' then 'Cancellation request' else 'Reschedule request' end,
          coalesce(v_name,'A guest')
            || case when new.kind = 'reschedule' and v_when is not null then ' -> ' || v_when else '' end,
          'change_requests', new.id);
  return new;
end $fn$;

drop trigger if exists trg_change_request_notify on public.change_requests;
create trigger trg_change_request_notify
  after insert on public.change_requests
  for each row execute function app.notify_on_change_request();

-- ---------- WS3: hold-expiry sweep + per-minute cron ----------
create or replace function app.expire_stale_bookings()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare r record; n int := 0;
begin
  for r in
    update public.booking_requests
       set status = 'expired'
     where status in ('new','pending')
       and expires_at is not null
       and expires_at < now()
    returning id, business_id, name, table_type_id
  loop
    n := n + 1;
    insert into public.notifications(business_id, kind, title, body, ref_table, ref_id)
    values (r.business_id, 'booking_expired', 'Booking hold expired',
            coalesce(r.name,'A guest') || ' — held table released.',
            'booking_requests', r.id);
    if exists (
      select 1 from public.waitlist w
       where w.business_id = r.business_id and w.status = 'waiting'
         and (r.table_type_id is null or w.table_type_id is null or w.table_type_id = r.table_type_id)
    ) then
      insert into public.notifications(business_id, kind, title, body, ref_table, ref_id)
      values (r.business_id, 'waitlist_ready', 'A table opened up',
              'A held table was released — contact your waitlist.',
              'booking_requests', r.id);
    end if;
  end loop;
  return n;
end $fn$;

select cron.schedule('frenly-booking-expiry', '* * * * *', $$select app.expire_stale_bookings()$$);

-- ---------- WS1: anon availability RPC ----------
create or replace function public.get_booking_availability(p_slug text)
returns json
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select coalesce(json_agg(json_build_object(
      'table_type_id', v.table_type_id, 'name', v.name, 'pax', v.pax,
      'quantity', v.quantity, 'held', v.held, 'available', v.available)
      order by v.sort, v.name), '[]'::json)
  from public.v_table_availability v
  join public.businesses b on b.id = v.business_id
  where b.slug = p_slug;
$fn$;
grant execute on function public.get_booking_availability(text) to anon, authenticated, service_role;

-- ---------- WS2/WS4: reworked request_booking (return type changes: uuid -> json) ----------
drop function if exists public.request_booking(text, text, text, text, uuid, integer, timestamptz, text);

create function public.request_booking(
  p_slug text, p_name text, p_email text, p_phone text,
  p_service uuid, p_party integer, p_preferred timestamptz, p_notes text,
  p_table_type uuid default null
) returns json
language plpgsql
security definer
set search_path to 'public'
as $fn$
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
                                         party_size, preferred_at, notes, status)
    values (v_biz, trim(p_name), p_email, p_phone, p_service, p_party, p_preferred, p_notes, 'new')
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
                                           table_type_id, appointment_id)
      values (v_biz, trim(p_name), p_email, p_phone, p_service, p_party, p_preferred, p_notes,
              'confirmed', p_table_type, v_appt.id)
      returning id into v_id;
      return json_build_object('status','confirmed','request_id', v_id, 'appointment_id', v_appt.id);
    else
      -- Manual-confirm firm: hold the table as 'pending' with a countdown (WS3).
      insert into public.booking_requests (business_id, name, email, phone, service_id,
                                           party_size, preferred_at, notes, status,
                                           table_type_id, expires_at)
      values (v_biz, trim(p_name), p_email, p_phone, p_service, p_party, p_preferred, p_notes,
              'pending', p_table_type,
              case when v_hold > 0 then now() + make_interval(mins => v_hold) else null end)
      returning id into v_id;
      return json_build_object('status','pending','request_id', v_id);
    end if;
  else
    -- No capacity: overflow policy decides.
    if v_overflow = 'reject' then
      insert into public.booking_requests (business_id, name, email, phone, service_id,
                                           party_size, preferred_at, notes, status, table_type_id)
      values (v_biz, trim(p_name), p_email, p_phone, p_service, p_party, p_preferred,
              trim(coalesce(p_notes,'') || ' [auto-declined: no capacity]'), 'declined', p_table_type)
      returning id into v_id;
      return json_build_object('status','rejected','request_id', v_id);
    else
      insert into public.booking_requests (business_id, name, email, phone, service_id,
                                           party_size, preferred_at, notes, status, table_type_id)
      values (v_biz, trim(p_name), p_email, p_phone, p_service, p_party, p_preferred, p_notes,
              'waitlisted', p_table_type)
      returning id into v_id;
      insert into public.waitlist (business_id, name, phone, service_id, preferred, notes,
                                   status, booking_request_id, table_type_id)
      values (v_biz, trim(p_name), p_phone, p_service,
              to_char(coalesce(p_preferred, now()) at time zone 'Asia/Singapore', 'YYYY-MM-DD HH24:MI'),
              p_notes, 'waiting', v_id, p_table_type);
      return json_build_object('status','waitlisted','request_id', v_id);
    end if;
  end if;
end $fn$;
grant execute on function
  public.request_booking(text,text,text,text,uuid,integer,timestamptz,text,uuid)
  to anon, authenticated, service_role;

-- ---------- WS1/WS2: manual confirm path draws down a table too ----------
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

-- ---------- WS4: SG-and-intl phone matching on the manage-booking lookups ----------
create or replace function public.list_my_appointments(p_slug text, p_phone text)
returns json
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_biz uuid; v_key text; v_result json;
begin
  select id into v_biz from public.businesses where slug = p_slug;
  if v_biz is null then raise exception 'business not found'; end if;
  v_key := app.phone_match_key(p_phone);
  select coalesce(json_agg(row_to_json(t) order by t.starts_at), '[]'::json) into v_result
  from (
    select a.id, a.starts_at, s.name as service_name, a.status
    from public.appointments a
    join public.clients c on c.id = a.client_id
    left join public.services s on s.id = a.service_id
    where a.business_id = v_biz
      and a.status = 'booked'
      and a.starts_at > now()
      and v_key is not null
      and app.phone_match_key(c.phone) = v_key
    order by a.starts_at
  ) t;
  return v_result;
end $fn$;

create or replace function public.request_change(p_slug text, p_appointment uuid, p_phone text,
                                                 p_kind text, p_proposed timestamptz, p_note text)
returns json
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_biz uuid; v_appt record; v_auto boolean; v_status text := 'pending'; v_id uuid;
begin
  select id, auto_approve_changes into v_biz, v_auto from public.businesses where slug = p_slug;
  if v_biz is null then raise exception 'business not found'; end if;
  if p_kind not in ('cancel','reschedule') then raise exception 'invalid kind: %', p_kind; end if;
  if p_kind = 'reschedule' and (p_proposed is null or p_proposed <= now()) then
    raise exception 'reschedule requires a future proposed time';
  end if;
  select a.*, c.phone as client_phone into v_appt
    from public.appointments a join public.clients c on c.id = a.client_id
   where a.id = p_appointment and a.business_id = v_biz;
  if not found then raise exception 'appointment not found'; end if;
  if v_appt.status <> 'booked' then raise exception 'appointment is not booked'; end if;
  if v_appt.client_phone is null
     or app.phone_match_key(p_phone) is null
     or app.phone_match_key(v_appt.client_phone) is distinct from app.phone_match_key(p_phone) then
    raise exception 'phone does not match this appointment';
  end if;
  insert into public.change_requests (business_id, appointment_id, kind, proposed_at, phone, note, status)
  values (v_biz, p_appointment, p_kind, p_proposed, trim(p_phone), p_note, 'pending')
  returning id into v_id;
  if v_auto then
    if p_kind = 'cancel' then
      update public.appointments set status = 'cancelled' where id = p_appointment and status = 'booked';
    elsif p_kind = 'reschedule' then
      update public.appointments
         set starts_at = p_proposed, ends_at = p_proposed + (ends_at - starts_at)
       where id = p_appointment and status = 'booked';
    end if;
    update public.change_requests set status = 'approved', decided_at = now() where id = v_id;
    v_status := 'approved';
  end if;
  return json_build_object('id', v_id, 'status', v_status);
end $fn$;

-- ---------- WS1: portal public payload gains tables + booking settings ----------
create or replace function public.get_business_public(p_slug text)
returns json
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select json_build_object(
    'id', b.id, 'name', b.name, 'industry', b.industry, 'currency', b.currency,
    'booking_policy', b.booking_policy, 'brand_color', b.brand_color,
    'booking_overflow', b.booking_overflow,
    'booking_hold_minutes', b.booking_hold_minutes,
    'booking_auto_confirm', b.booking_auto_confirm,
    'uses_tables', exists(select 1 from public.booking_tables t where t.business_id = b.id and t.active),
    'services', coalesce((select json_agg(json_build_object(
        'id', s.id, 'name', s.name, 'price_cents', s.price_cents, 'duration_min', s.duration_min))
      from public.services s where s.business_id = b.id and s.active), '[]'::json),
    'tables', coalesce((select json_agg(json_build_object(
        'table_type_id', v.table_type_id, 'name', v.name, 'pax', v.pax,
        'quantity', v.quantity, 'held', v.held, 'available', v.available) order by v.sort, v.name)
      from public.v_table_availability v where v.business_id = b.id), '[]'::json))
  from public.businesses b where b.slug = p_slug;
$fn$;

-- ---------- WS3/WS5: firm booking settings saver (owner-gated) ----------
create or replace function public.set_booking_settings(p_business uuid, p_hold_minutes integer,
                                                       p_overflow text, p_notify boolean,
                                                       p_auto_confirm boolean default null)
returns json
language plpgsql
security definer
set search_path to 'public'
as $fn$
begin
  if not app.is_salon_owner(p_business) then raise exception 'not authorized'; end if;
  if p_overflow is not null and p_overflow not in ('waitlist','reject') then
    raise exception 'invalid overflow (waitlist|reject)';
  end if;
  if p_hold_minutes is not null and p_hold_minutes < 0 then
    raise exception 'hold minutes must be >= 0';
  end if;
  update public.businesses set
    booking_hold_minutes = coalesce(p_hold_minutes, booking_hold_minutes),
    booking_overflow     = coalesce(p_overflow, booking_overflow),
    notify_new_bookings  = coalesce(p_notify, notify_new_bookings),
    booking_auto_confirm = coalesce(p_auto_confirm, booking_auto_confirm)
  where id = p_business;
  return json_build_object('status','ok');
end $fn$;
revoke all on function public.set_booking_settings(uuid,integer,text,boolean,boolean) from public, anon;
grant execute on function public.set_booking_settings(uuid,integer,text,boolean,boolean) to authenticated, service_role;

-- ---------- WS5: notification read RPCs (member-gated) ----------
create or replace function public.get_notifications(p_business uuid, p_limit integer default 30)
returns json
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_result json;
begin
  if not app.is_salon_member(p_business) then raise exception 'not authorized'; end if;
  select json_build_object(
    'unread', (select count(*) from public.notifications where business_id = p_business and read_at is null),
    'items', coalesce((select json_agg(row_to_json(t)) from (
        select id, kind, title, body, ref_table, ref_id, created_at, read_at
        from public.notifications where business_id = p_business
        order by created_at desc
        limit greatest(coalesce(p_limit,30), 1)
      ) t), '[]'::json)
  ) into v_result;
  return v_result;
end $fn$;
revoke all on function public.get_notifications(uuid,integer) from public, anon;
grant execute on function public.get_notifications(uuid,integer) to authenticated, service_role;

create or replace function public.mark_notification_read(p_id uuid)
returns json
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_count int;
begin
  update public.notifications set read_at = coalesce(read_at, now())
   where id = p_id and app.is_salon_member(business_id);
  get diagnostics v_count = row_count;
  return json_build_object('status','ok','updated', v_count);
end $fn$;
revoke all on function public.mark_notification_read(uuid) from public, anon;
grant execute on function public.mark_notification_read(uuid) to authenticated, service_role;

create or replace function public.mark_all_notifications_read(p_business uuid)
returns json
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_count int;
begin
  if not app.is_salon_member(p_business) then raise exception 'not authorized'; end if;
  update public.notifications set read_at = now()
   where business_id = p_business and read_at is null;
  get diagnostics v_count = row_count;
  return json_build_object('status','ok','updated', v_count);
end $fn$;
revoke all on function public.mark_all_notifications_read(uuid) from public, anon;
grant execute on function public.mark_all_notifications_read(uuid) to authenticated, service_role;

-- ---------- WS6: CSV import of existing bookings (owner-gated, conservative) ----------
create or replace function public.import_bookings(p_business uuid, p_rows jsonb)
returns json
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  r jsonb; v_inserted int := 0; v_skipped int := 0; v_errors jsonb := '[]'::jsonb; v_idx int := 0;
  v_name text; v_phone text; v_email text; v_party int; v_pref timestamptz; v_notes text;
  v_tt uuid; v_ttname text;
begin
  if not app.is_salon_owner(p_business) then raise exception 'not authorized'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be a JSON array';
  end if;
  perform set_config('app.suppress_booking_notify','on', true);   -- no toast per row

  for r in select * from jsonb_array_elements(p_rows) loop
    v_idx := v_idx + 1;
    begin
      v_name  := nullif(trim(coalesce(r->>'name','')),'');
      if v_name is null or length(v_name) < 2 then
        v_skipped := v_skipped + 1;
        v_errors  := v_errors || jsonb_build_object('row', v_idx, 'error', 'missing/short name');
        continue;
      end if;
      v_phone := nullif(trim(coalesce(r->>'phone','')),'');
      v_email := nullif(trim(coalesce(r->>'email','')),'');
      v_notes := nullif(trim(coalesce(r->>'notes','')),'');
      begin v_party := nullif(r->>'party_size','')::int; exception when others then v_party := null; end;
      begin v_pref  := nullif(r->>'preferred_at','')::timestamptz; exception when others then v_pref := null; end;

      v_tt := null;
      if coalesce(r->>'table_type_id','') <> '' then
        begin v_tt := (r->>'table_type_id')::uuid; exception when others then v_tt := null; end;
        if v_tt is not null then
          perform 1 from public.booking_tables where id = v_tt and business_id = p_business;
          if not found then v_tt := null; end if;
        end if;
      end if;
      if v_tt is null then
        v_ttname := nullif(trim(coalesce(r->>'table_type','')),'');
        if v_ttname is not null then
          select id into v_tt from public.booking_tables
           where business_id = p_business and active and lower(name) = lower(v_ttname) limit 1;
        end if;
      end if;

      insert into public.booking_requests (business_id, name, email, phone, party_size,
                                           preferred_at, notes, status, table_type_id)
      values (p_business, v_name, v_email, v_phone, v_party, v_pref, v_notes, 'new', v_tt);
      v_inserted := v_inserted + 1;
    exception when others then
      v_skipped := v_skipped + 1;
      v_errors  := v_errors || jsonb_build_object('row', v_idx, 'error', SQLERRM);
    end;
  end loop;

  return json_build_object('inserted', v_inserted, 'skipped', v_skipped, 'errors', v_errors);
end $fn$;
revoke all on function public.import_bookings(uuid, jsonb) from public, anon;
grant execute on function public.import_bookings(uuid, jsonb) to authenticated, service_role;