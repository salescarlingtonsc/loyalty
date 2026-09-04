-- Rollback-only acceptance for nestly_v759 — a repeating weekly break keeps a team member
-- unavailable for that window, in the write-time guard and in the public slot list.
-- Run: supabase db query --linked -f db/tests/v759_staff_recurring_breaks.sql
-- Any value starting FAIL is a failure. Nothing is committed.
--
-- Fixtures: the Cubbly SPA tenant used by v598's and v611's own suites — a branch open every day
-- including Sunday, and a staff member with no personal Sunday staff_hours row (so the shop's
-- hours are the working window and the ONLY thing under test is the break). Discovered
-- dynamically; the known Cubbly ids are the fallback if discovery comes up empty.
begin;

create temp table _r(id text, value text) on commit drop;

create temp table _f as
select
  coalesce(
    (select s.id from public.staff s
      where s.business_id = b.id and s.active
        and not exists (select 1 from public.staff_hours h where h.staff_id = s.id and h.weekday = 0)
        and not exists (select 1 from public.staff_recurring_off_days d where d.staff_id = s.id and d.weekday = 0)
      limit 1),
    '09f77701-8b7a-41cf-9196-b08bb1957683'::uuid) as staff,
  coalesce(
    (select br.id from public.branches br
      where br.business_id = b.id and br.active
        and exists (select 1 from public.branch_hours h where h.branch_id = br.id and h.weekday = 0)
      limit 1),
    '9a9081fb-fb48-49c7-a1c7-2bfb3d3ec263'::uuid) as branch,
  coalesce(
    (select sv.id from public.services sv where sv.business_id = b.id and sv.active limit 1),
    '8546bd52-f06c-4f88-92b5-f79fa82cf960'::uuid) as service,
  b.id as biz
from public.businesses b
where b.id = '8492e8d6-8888-4383-ada0-7e1ed69f0caa'
limit 1;

-- Anchor to the next Sunday so the window under test is always a real future date.
create temp table _w as
select biz, staff, branch, service,
  (current_date + ((7 - extract(dow from current_date)::int) % 7)
     + case when extract(dow from current_date)::int = 0 then 7 else 0 end)::date as next_sunday
from _f;

insert into _r select '00 fixture is the reported shape',
  case when (select staff from _w) is null then 'FAIL: no staff fixture'
       when (select branch from _w) is null then 'FAIL: no branch fixture'
       when (select service from _w) is null then 'FAIL: no service fixture'
       when extract(dow from (select next_sunday from _w))::int <> 0 then 'FAIL: not a Sunday'
       when not exists(select 1 from public.branch_hours h, _w w
                        where h.branch_id = w.branch and h.weekday = 0)
         then 'FAIL: the branch has no Sunday opening hours'
       when exists(select 1 from public.staff_recurring_breaks p, _w w
                    where p.staff_id = w.staff and p.weekday = 0)
         then 'FAIL: the fixture staff already has a Sunday break — the effect cannot be observed'
       else 'OK branch open Sunday, staff has no Sunday break' end;

-- ── T0: the table exists with the shape the browser writes ───────────────────────────────────
insert into _r select '01 T0 staff_recurring_breaks exists with RLS enabled',
  case when not exists (select 1 from pg_catalog.pg_class c
                         join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                        where n.nspname = 'public' and c.relname = 'staff_recurring_breaks')
         then 'FAIL: table missing'
       when not (select c.relrowsecurity from pg_catalog.pg_class c
                  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                 where n.nspname = 'public' and c.relname = 'staff_recurring_breaks')
         then 'FAIL: RLS is not enabled'
       else 'OK' end;

-- The browser upserts with onConflict business_id,staff_id,weekday,starts_at,ends_at. Postgres
-- refuses an ON CONFLICT target that is not backed by a unique constraint — the exact failure
-- v600 shipped against staff_recurring_off_days — so the key shape is pinned here.
insert into _r select '02 T0 the unique key is exactly the browser''s ON CONFLICT target',
  case when exists (
         select 1
           from pg_catalog.pg_constraint con
           join pg_catalog.pg_class c on c.oid = con.conrelid
           join pg_catalog.pg_namespace n on n.oid = c.relnamespace
          where n.nspname = 'public' and c.relname = 'staff_recurring_breaks'
            and con.contype = 'u'
            and pg_catalog.pg_get_constraintdef(con.oid)
                = 'UNIQUE (business_id, staff_id, weekday, starts_at, ends_at)')
       then 'OK' else 'FAIL: no UNIQUE (business_id, staff_id, weekday, starts_at, ends_at)' end;

-- The v600 defect itself: staff_recurring_off_days is keyed on business_id too, so the browser's
-- conflict target must name all three columns. Pinned so a narrower target cannot come back.
insert into _r select '03 v600 regression: off-days unique key includes business_id',
  case when exists (
         select 1
           from pg_catalog.pg_constraint con
           join pg_catalog.pg_class c on c.oid = con.conrelid
           join pg_catalog.pg_namespace n on n.oid = c.relnamespace
          where n.nspname = 'public' and c.relname = 'staff_recurring_off_days'
            and con.contype = 'u'
            and pg_catalog.pg_get_constraintdef(con.oid)
                = 'UNIQUE (business_id, staff_id, weekday)')
       then 'OK' else 'FAIL: staff_recurring_off_days is not keyed (business_id, staff_id, weekday)' end;

-- ── T1: baseline — the guard accepts the slot before any break exists ─────────────────────────
insert into _r select '04 T1 baseline: 11:00-12:00 accepted with no break',
  case when app.staff_free_for_appointment_v120_base(
         w.biz, w.staff, w.branch, w.service,
         (w.next_sunday + time '11:00') at time zone 'Asia/Singapore',
         (w.next_sunday + time '12:00') at time zone 'Asia/Singapore',
         null)
       then 'OK'
       else 'FAIL: the baseline slot is already refused — the fixture cannot show the break effect' end
  from _w w;

insert into public.staff_recurring_breaks (id, business_id, staff_id, weekday, starts_at, ends_at, created_at)
select gen_random_uuid(), w.biz, w.staff, 0, time '11:30', time '12:30', now()
  from _w w;

-- ── T2: an overlapping slot is now refused at write time ─────────────────────────────────────
insert into _r select '05 T2 the guard refuses a slot overlapping the break',
  case when not app.staff_free_for_appointment_v120_base(
         w.biz, w.staff, w.branch, w.service,
         (w.next_sunday + time '11:00') at time zone 'Asia/Singapore',
         (w.next_sunday + time '12:00') at time zone 'Asia/Singapore',
         null)
       then 'OK'
       else 'FAIL: a booking was accepted across the team member''s weekly break' end
  from _w w;

-- ── T3: a slot clear of the break is still accepted (the break cuts a hole, not the day) ─────
insert into _r select '06 T3 a slot clear of the break is still accepted',
  case when app.staff_free_for_appointment_v120_base(
         w.biz, w.staff, w.branch, w.service,
         (w.next_sunday + time '15:00') at time zone 'Asia/Singapore',
         (w.next_sunday + time '16:00') at time zone 'Asia/Singapore',
         null)
       then 'OK'
       else 'FAIL: the break shortened the whole day instead of cutting a hole in it' end
  from _w w;

-- ── T4: a break on a DIFFERENT weekday does not touch this one ───────────────────────────────
insert into _r select '07 T4 the break is weekday-scoped',
  case when app.staff_free_for_appointment_v120_base(
         w.biz, w.staff, w.branch, w.service,
         (w.next_sunday + 1 + time '11:00') at time zone 'Asia/Singapore',
         (w.next_sunday + 1 + time '12:00') at time zone 'Asia/Singapore',
         null)
       or exists (select 1 from public.staff_recurring_off_days d
                   where d.staff_id = w.staff and d.weekday = 1)
       or not exists (select 1 from public.branch_hours h
                       where h.branch_id = w.branch and h.weekday = 1
                         and h.opens_at <= time '11:00' and h.closes_at >= time '12:00')
       then 'OK'
       else 'FAIL: a Sunday break also refused the Monday slot' end
  from _w w;

delete from public.staff_recurring_breaks p using _w w
 where p.staff_id = w.staff and p.weekday = 0 and p.starts_at = time '11:30';

-- ── T1 replay: with the break removed the slot is bookable again ─────────────────────────────
insert into _r select '08 T1 replay: the slot comes back once the break row is gone',
  case when app.staff_free_for_appointment_v120_base(
         w.biz, w.staff, w.branch, w.service,
         (w.next_sunday + time '11:00') at time zone 'Asia/Singapore',
         (w.next_sunday + time '12:00') at time zone 'Asia/Singapore',
         null)
       then 'OK'
       else 'FAIL: the slot did not come back after removing the break row' end
  from _w w;

-- ── T5: an inverted window is refused by the table itself ────────────────────────────────────
do $$
declare v_ok boolean := false;
begin
  begin
    insert into public.staff_recurring_breaks (business_id, staff_id, weekday, starts_at, ends_at)
    select w.biz, w.staff, 0, time '13:00', time '12:00' from _w w;
  exception when check_violation then
    v_ok := true;
  end;
  insert into _r select '09 T5 an inverted break window is refused',
    case when v_ok then 'OK' else 'FAIL: ends_at <= starts_at was accepted' end;
end $$;

-- ── T6: the public slot list honours the break too (v432: one availability core) ─────────────
-- Only meaningful for a tenant whose booking page offers a staff choice; otherwise reported as
-- skipped rather than silently passing.
do $$
declare
  v_slug text;
  v_before int;
  v_after int;
begin
  select b.slug into v_slug from public.businesses b, _w w
   where b.id = w.biz and coalesce(b.booking_staff_choice, false);
  if v_slug is null then
    insert into _r values ('10 T6 public slot list', 'SKIP: the fixture tenant has no staff-choice booking page');
    return;
  end if;

  select count(*) into v_before
    from jsonb_array_elements(
           coalesce(public.internal_public_booking_availability(
             v_slug, (select service from _w), (select staff from _w),
             (select next_sunday from _w), 1, (select branch from _w)) -> 'days', '[]'::jsonb)) day_row,
         jsonb_array_elements(day_row -> 'slots') slot
   where (slot ->> 'at')::timestamptz
         < ((select next_sunday from _w) + time '12:30') at time zone 'Asia/Singapore'
     and (slot ->> 'at')::timestamptz
         >= ((select next_sunday from _w) + time '11:30') at time zone 'Asia/Singapore';

  insert into public.staff_recurring_breaks (business_id, staff_id, weekday, starts_at, ends_at)
  select w.biz, w.staff, 0, time '11:30', time '12:30' from _w w;

  select count(*) into v_after
    from jsonb_array_elements(
           coalesce(public.internal_public_booking_availability(
             v_slug, (select service from _w), (select staff from _w),
             (select next_sunday from _w), 1, (select branch from _w)) -> 'days', '[]'::jsonb)) day_row,
         jsonb_array_elements(day_row -> 'slots') slot
   where (slot ->> 'at')::timestamptz
         < ((select next_sunday from _w) + time '12:30') at time zone 'Asia/Singapore'
     and (slot ->> 'at')::timestamptz
         >= ((select next_sunday from _w) + time '11:30') at time zone 'Asia/Singapore';

  delete from public.staff_recurring_breaks p using _w w
   where p.staff_id = w.staff and p.weekday = 0 and p.starts_at = time '11:30';

  insert into _r select '10 T6 public slot list drops the slots inside the break',
    case when v_before = 0 then 'SKIP: no slots were offered in that window before the break'
         when v_after < v_before then 'OK'
         else 'FAIL: the public booking page still offered slots inside the break' end;
end $$;

select id, value from _r order by id;

rollback;
