-- v183 rolled-back verification — customer staff choice + live booking availability.
--
-- Run against production. Every mutation is inside the transaction and the file ends in
-- `rollback;`, so nothing survives. Assertions cover the four things that must hold:
--   1. staff choice OFF never exposes the roster and never offers slots (fail closed);
--   2. staff choice ON exposes only bookable, active staff, and reports honestly whether
--      the business has published any hours at all;
--   3. a rota produces real slots, and blocked time removes them;
--   3b. a rota REPLACES the shop hours, an unrostered weekday offers nothing, and clearing
--      the rota returns the person to the shop hours (the contract the Settings editor uses);
--   4. the submit path re-validates the requested person server-side.

begin;

do $test$
declare
  v_biz uuid;
  v_slug text;
  v_staff uuid;
  v_other uuid;
  v_service uuid;
  v_branch uuid;
  v_actor uuid;
  v_out jsonb;
  v_slots integer;
  v_probe date;
  v_first timestamptz;
begin
  select business.id, business.slug into v_biz, v_slug
    from public.businesses business
    join public.staff member on member.business_id = business.id and coalesce(member.active, true)
    join public.services service on service.business_id = business.id
     and service.active and service.show_on_booking_page
   order by business.created_at
   limit 1;
  if v_biz is null then
    raise notice 'v183: no tenant with both active staff and a bookable service; skipping';
    return;
  end if;

  select id into v_staff from public.staff
   where business_id = v_biz and coalesce(active, true) order by created_at limit 1;
  select id into v_service from public.services
   where business_id = v_biz and active and show_on_booking_page order by name limit 1;
  select id into v_branch from public.branches
   where business_id = v_biz order by is_default desc nulls last, created_at limit 1;
  select user_id into v_actor from public.staff
   where business_id = v_biz and user_id is not null limit 1;

  -- 1. fail closed while the toggle is off
  update public.businesses set booking_staff_choice = false where id = v_biz;
  v_out := public.internal_public_booking_availability(v_slug, null, null, null, 7);
  assert (v_out->>'staff_choice')::boolean = false, 'toggle off must report staff_choice false';
  assert v_out->'staff' = '[]'::jsonb, 'toggle off must not expose the roster';
  assert v_out->'days' = '[]'::jsonb, 'toggle off must not offer slots';
  assert (public.internal_public_booking_page(v_slug)->>'booking_staff_choice')::boolean = false;
  assert public.internal_public_booking_page(v_slug)->'staff' = '[]'::jsonb,
    'the public booking page must not carry staff identities while the toggle is off';

  -- 2. toggle on: roster visible, hours honestly reported
  update public.businesses set booking_staff_choice = true where id = v_biz;
  v_out := public.internal_public_booking_availability(v_slug, null, null, null, 7);
  assert (v_out->>'staff_choice')::boolean = true;
  assert jsonb_array_length(v_out->'staff') > 0, 'roster must be visible when the toggle is on';
  assert jsonb_array_length(public.internal_public_booking_page(v_slug)->'staff') > 0;
  delete from public.staff_hours where business_id = v_biz;
  delete from public.branch_hours where business_id = v_biz;
  v_out := public.internal_public_booking_availability(v_slug, null, null, null, 7);
  assert (v_out->>'hours_configured')::boolean = false,
    'with no rota and no opening hours the customer must fall back to a plain time request';
  assert v_out->'days' = '[]'::jsonb;

  -- 3. a rota produces slots; blocked time removes them
  insert into public.staff_hours (business_id, staff_id, weekday, starts_at, ends_at)
  select v_biz, v_staff, weekday, time '09:00', time '18:00' from generate_series(0, 6) weekday;
  v_out := public.internal_public_booking_availability(v_slug, v_service, v_staff, null, 3);
  assert (v_out->>'hours_configured')::boolean = true, 'a rota must count as configured hours';
  select coalesce(sum(jsonb_array_length(day->'slots')), 0) into v_slots
    from jsonb_array_elements(v_out->'days') day;
  assert v_slots > 0, 'a rostered person must produce slots';

  insert into public.staff_blocked_times (business_id, branch_id, staff_id, starts_at, ends_at, reason, created_by)
  values (v_biz, v_branch, v_staff,
          timezone('Asia/Singapore', ((statement_timestamp() at time zone 'Asia/Singapore')::date + 1)::timestamp),
          timezone('Asia/Singapore', ((statement_timestamp() at time zone 'Asia/Singapore')::date + 2)::timestamp),
          'v183 rolled-back test', v_actor);
  v_out := public.internal_public_booking_availability(
    v_slug, v_service, v_staff, ((statement_timestamp() at time zone 'Asia/Singapore')::date + 1)::date, 1);
  select coalesce(sum(jsonb_array_length(day->'slots')), 0) into v_slots
    from jsonb_array_elements(v_out->'days') day;
  assert v_slots = 0, 'a full-day block must remove every slot for that day';

  -- 3b. a rota REPLACES the shop hours, and an unrostered weekday offers nothing.
  -- This is the contract the Settings rota editor is built on, so pin it here.
  delete from public.staff_blocked_times where business_id = v_biz and staff_id = v_staff;
  delete from public.staff_hours where business_id = v_biz and staff_id = v_staff;
  insert into public.branch_hours (business_id, branch_id, weekday, opens_at, closes_at)
  select v_biz, v_branch, weekday, time '09:00', time '18:00' from generate_series(0, 6) weekday
  on conflict (branch_id, weekday) do update set opens_at = excluded.opens_at, closes_at = excluded.closes_at;
  v_probe := ((statement_timestamp() at time zone 'Asia/Singapore')::date + 2)::date;
  -- rostered on the probe day only, and later than the shop opens
  insert into public.staff_hours (business_id, staff_id, weekday, starts_at, ends_at)
  values (v_biz, v_staff, extract(dow from v_probe)::smallint, time '14:00', time '18:00');
  v_out := public.internal_public_booking_availability(v_slug, v_service, v_staff, v_probe, 1);
  select min((slot->>'at')::timestamptz) into v_first
    from jsonb_array_elements(v_out->'days') day,
         jsonb_array_elements(day->'slots') slot;
  assert v_first is not null, 'the rostered day must still offer slots';
  assert (v_first at time zone 'Asia/Singapore')::time = time '14:00',
    'the rota start must win over the shop opening time';

  v_out := public.internal_public_booking_availability(v_slug, v_service, v_staff, (v_probe + 1)::date, 1);
  select coalesce(sum(jsonb_array_length(day->'slots')), 0) into v_slots
    from jsonb_array_elements(v_out->'days') day;
  assert v_slots = 0,
    'a person with a rota is unavailable on a weekday they are not rostered, even when the shop is open';

  -- clearing the rota is what returns the person to the shop hours
  delete from public.staff_hours where business_id = v_biz and staff_id = v_staff;
  v_out := public.internal_public_booking_availability(v_slug, v_service, v_staff, (v_probe + 1)::date, 1);
  select coalesce(sum(jsonb_array_length(day->'slots')), 0) into v_slots
    from jsonb_array_elements(v_out->'days') day;
  assert v_slots > 0, 'with no rota the person must follow the shop opening hours again';

  -- a person the business hid is never offered, even when asked for by id
  update public.staff set customer_bookable = false where id = v_staff;
  v_out := public.internal_public_booking_availability(v_slug, v_service, v_staff, null, 3);
  assert v_out->'staff' = '[]'::jsonb, 'a hidden team member must not be offered';
  update public.staff set customer_bookable = true where id = v_staff;

  -- 4. the submit path re-validates the requested person
  begin
    perform public.internal_public_booking_submit(
      v_slug, 'Test', 'test@example.com', null, null, 1,
      statement_timestamp() + interval '2 days', null, null, false,
      repeat('a', 64), repeat('b', 64), repeat('c', 64), null,
      '00000000-0000-4000-8000-000000000000'::uuid);
    raise exception 'expected a foreign staff id to be rejected';
  exception when sqlstate '22023' then null;
  end;

  select id into v_other from public.staff
   where business_id <> v_biz and coalesce(active, true) limit 1;
  if v_other is not null then
    begin
      perform public.internal_public_booking_submit(
        v_slug, 'Test', 'test@example.com', null, null, 1,
        statement_timestamp() + interval '2 days', null, null, false,
        repeat('a', 64), repeat('b', 64), repeat('c', 64), null, v_other);
      raise exception 'expected another tenant''s staff id to be rejected';
    exception when sqlstate '22023' then null;
    end;
  end if;

  raise notice 'v183 verification passed';
end $test$;

rollback;
