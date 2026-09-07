-- nestly_v820 rollback suite: the job decides the default, the owner still decides the person.
--
--   supabase db query --linked -f db/tests/v820_role_decides_who_customers_can_book.sql

begin;

do $suite$
declare
  c_biz    constant uuid := '8ccace3a-9736-447e-bb1e-da842622592d';  -- ÉLAN Wellness
  c_slug   constant text := 'kky-demo';
  c_branch constant uuid := '586f4069-12cb-4f54-b37c-8c5742244520';
  c_clare  constant uuid := '2ee655e3-9969-4894-83f1-3c1f5c92d372';  -- frontdesk, 0/7 days
  c_kky    constant uuid := '5b38b93c-c52b-4d4e-85ae-dc59a657ceaf';  -- owner, 0/7 days
  c_amanda constant uuid := '0fb55728-f2b3-4db9-87ec-574e93b80780';  -- staff, 90 slots
  v_new    uuid;
  v_txt    text;
  v_got    integer;
  n        integer := 0;
begin
  -- ------------------------------------------------- the two dead ends are gone

  n := n + 1;
  if (select customer_bookable from public.staff where id = c_clare) then
    raise exception 'A%: the receptionist is still bookable by default', n;
  end if;
  n := n + 1;
  if (select customer_bookable from public.staff where id = c_kky) then
    raise exception 'A%: the owner-role member is still bookable by default', n;
  end if;

  -- The people who actually do the work are untouched.
  n := n + 1;
  if not (select customer_bookable from public.staff where id = c_amanda) then
    raise exception 'A%: a staff-role therapist was taken off the booking page', n;
  end if;

  -- ------------------------------------------- the Team step now agrees with the Time step
  -- This is the assertion the end-to-end walk failed on: every name offered must have at
  -- least one bookable slot, or picking them is a dead end.
  n := n + 1;
  select string_agg(st.full_name, ', ' order by st.full_name) into v_txt
    from app.v183_bookable_staff(c_biz, null, null, c_branch) member
    join public.staff st on st.id = member.staff_id
   where not exists (
     select 1
       from jsonb_array_elements(coalesce(
              (public.internal_public_booking_availability(
                 c_slug, null, null, (now() at time zone 'Asia/Singapore')::date, 7, c_branch))->'days',
              '[]'::jsonb)) d
       cross join lateral jsonb_array_elements(coalesce(d->'slots','[]'::jsonb)) slot
       cross join lateral jsonb_array_elements_text(coalesce(slot->'staff_ids','[]'::jsonb)) sid
      where sid = member.staff_id::text);
  if v_txt is not null then
    raise exception 'A%: the Team step still offers % with no bookable slot', n, v_txt;
  end if;

  n := n + 1;
  select count(*)::integer into v_got
    from app.v183_bookable_staff(c_biz, null, null, c_branch);
  if v_got < 1 then
    raise exception 'A%: nobody at all is bookable now — the booking page would be empty', n;
  end if;

  -- --------------------------------------- the owner's explicit override still works
  -- The whole reason the role test is NOT in v183_bookable_staff: a business that genuinely
  -- wants its receptionist bookable must be able to say so, and be obeyed.
  n := n + 1;
  update public.staff set customer_bookable = true where id = c_clare;
  if not exists (select 1 from app.v183_bookable_staff(c_biz, null, null, c_branch) m
                  where m.staff_id = c_clare) then
    raise exception 'A%: ticking a receptionist back on did NOT put them on the booking page', n;
  end if;
  n := n + 1;
  if not exists (select 1 from jsonb_array_elements(
        (public.internal_public_booking_page(c_slug))->'staff') s
      where (s->>'id')::uuid = c_clare) then
    raise exception 'A%: the override is not visible on the customer booking page itself', n;
  end if;
  update public.staff set customer_bookable = false where id = c_clare;

  -- ------------------------------------------------- the default at creation, by role
  n := n + 1;
  insert into public.staff(business_id, role, full_name, active)
  values (c_biz, 'frontdesk', 'v820 probe desk', true) returning id into v_new;
  if (select customer_bookable from public.staff where id = v_new) then
    raise exception 'A%: a NEW receptionist was created bookable', n;
  end if;

  n := n + 1;
  insert into public.staff(business_id, role, full_name, active)
  values (c_biz, 'staff', 'v820 probe therapist', true) returning id into v_new;
  if not (select customer_bookable from public.staff where id = v_new) then
    raise exception 'A%: a NEW therapist was created unbookable', n;
  end if;

  -- A caller that passes customer_bookable=true for a non-service role is still stamped by
  -- the role: creation-time default is the role's answer, and the override is a later edit.
  n := n + 1;
  insert into public.staff(business_id, role, full_name, active, customer_bookable)
  values (c_biz, 'bookkeeper', 'v820 probe books', true, true) returning id into v_new;
  if (select customer_bookable from public.staff where id = v_new) then
    raise exception 'A%: an insert-time true beat the role default for a bookkeeper', n;
  end if;

  -- ------------------------------------------------- nothing that was live has stopped
  -- The one business that ends up with nobody bookable must still be one with no bookings.
  n := n + 1;
  select count(*)::integer into v_got
    from public.businesses b
   where coalesce(b.booking_staff_choice, false)
     and not exists (select 1 from public.staff st
           where st.business_id = b.id and st.active and st.customer_bookable)
     and exists (select 1 from public.appointments a where a.business_id = b.id);
  if v_got <> 0 then
    raise exception 'A%: % business(es) that take real bookings now have nobody bookable', n, v_got;
  end if;

  raise notice 'nestly_v820: % / % assertions passed', n, n;
end
$suite$;

rollback;
