-- Nestly v223 — table reservations become an explicit choice, not an assumption.
--
-- Owner: "how can table bookings be present in a spa/salon? - you need to seperate the modules
-- and only enable the module when there's tables or reservation bookings."
--
-- The Bookings module is genuinely shared: a spa customer requests an appointment through the
-- public page, an F&B customer reserves a table, and both arrive as booking_requests. What is
-- NOT shared is seating — "Tables / capacity", pax counts and the when-you're-full overflow
-- rule are meaningless to a facial spa, and the salon/spa/massage/fitness sectors are granted
-- the full module list, so every one of them was shown table management they can never use.
--
-- A boolean on the business says whether it seats people. It is backfilled from what each
-- business actually is and does, so nobody has to answer a question to get back what they had:
--   * on for F&B, the sector the feature was built for;
--   * on for anyone who has already defined a table type, whatever their sector — that is
--     evidence they use it, and turning it off under them would hide their own data;
--   * off for everyone else, who keep the booking page and lose only the seating controls.

begin;

alter table public.businesses
  add column if not exists takes_table_reservations boolean not null default false;

comment on column public.businesses.takes_table_reservations is
  'v223: this business seats guests at tables, so Tables/capacity and the when-full overflow '
  'rule apply. Off for appointment-only businesses (spa, salon, clinic), which still take '
  'booking requests through the public page.';

update public.businesses business
set takes_table_reservations = true
where takes_table_reservations = false
  and (
    business.industry = 'fnb'
    or exists(
      select 1 from public.booking_tables t
      where t.business_id = business.id
    )
  );

-- The booking-settings writer learns the flag, so an owner can turn seating on for themselves
-- rather than needing a platform operator. Optional and coalesced, so every existing
-- five-argument caller is unchanged and a null never resets a stored value.
create or replace function public.set_booking_settings(
  p_business uuid, p_hold_minutes integer, p_overflow text, p_notify boolean,
  p_auto_confirm boolean DEFAULT NULL::boolean,
  p_takes_table_reservations boolean DEFAULT NULL::boolean)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
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
    booking_auto_confirm = coalesce(p_auto_confirm, booking_auto_confirm),
    takes_table_reservations = coalesce(p_takes_table_reservations, takes_table_reservations)
  where id = p_business;
  return json_build_object('status','ok');
end $function$;

-- The five-argument overload is now ambiguous against the six-argument default, so it goes.
drop function if exists public.set_booking_settings(uuid,integer,text,boolean,boolean);

revoke all on function public.set_booking_settings(uuid,integer,text,boolean,boolean,boolean)
  from public, anon;
grant execute on function public.set_booking_settings(uuid,integer,text,boolean,boolean,boolean)
  to authenticated;

commit;
