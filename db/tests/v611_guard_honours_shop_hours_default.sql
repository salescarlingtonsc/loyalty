-- Rollback-only acceptance for nestly_v611 — the write-time guard honours "shop hours are the
-- default" (app.staff_free_for_appointment_v47), on ALREADY-PATCHED production.
-- Run: supabase db query --linked -f db/tests/v611_guard_honours_shop_hours_default.sql
-- Any value starting FAIL is a failure. Nothing is committed.
--
-- Fixtures: the Cubbly SPA tenant used by v598's own suite — a staff member with personal
-- staff_hours for weekdays 1-6 only (no Sunday row) and a branch open every day including
-- Sunday. Discovered dynamically; the known Cubbly ids below are the fallback if discovery
-- comes up empty.
begin;

create temp table _r(id text, value text) on commit drop;

create temp table _f as
select
  coalesce(
    (select s.id from public.staff s
      where s.business_id = b.id and s.active
        and exists (select 1 from public.staff_hours h where h.staff_id = s.id and h.weekday between 1 and 6)
        and not exists (select 1 from public.staff_hours h where h.staff_id = s.id and h.weekday = 0)
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
       when exists(select 1 from public.staff_hours h, _w w
                    where h.staff_id = w.staff and h.weekday = 0)
         then 'FAIL: staff already has a personal Sunday row — the regression cannot be observed'
       else 'OK branch open Sunday, staff has no personal Sunday row' end;

-- ── T1: a staff with weekday 1-6 personal rows is free on a Sunday slot inside branch hours ──
insert into _r select '01 T1 shop-hours fallback: free inside branch Sunday hours, no personal row',
  case when app.staff_free_for_appointment_v47(
         w.biz, w.staff, w.branch, w.service,
         (w.next_sunday + time '11:00') at time zone 'Asia/Singapore',
         (w.next_sunday + time '12:00') at time zone 'Asia/Singapore',
         null)
       then 'OK'
       else 'FAIL: refused a slot that should fall back to branch hours (v611 regression)' end
  from _w w;

-- ── T2: a personal-row misfit is refused, even though the shop itself is open ─────────────────
-- Give the staff a NARROW personal Sunday window (11:00-12:00) inside this transaction, then
-- probe a slot that is inside the branch's Sunday hours but OUTSIDE that personal window. The
-- explicit personal row must govern the weekday it names, not fall back to the (wider) branch.
insert into public.staff_hours (id, business_id, staff_id, weekday, starts_at, ends_at)
select gen_random_uuid(), w.biz, w.staff, 0, time '11:00', time '12:00'
  from _w w;

insert into _r select '02 T2 personal-row misfit is refused despite the shop being open',
  case when not app.staff_free_for_appointment_v47(
         w.biz, w.staff, w.branch, w.service,
         (w.next_sunday + time '15:00') at time zone 'Asia/Singapore',
         (w.next_sunday + time '16:00') at time zone 'Asia/Singapore',
         null)
       then 'OK'
       else 'FAIL: a personal-row misfit was accepted (personal row should override the branch fallback)' end
  from _w w;

insert into _r select '02b T2 the same personal row still accepts its own window',
  case when app.staff_free_for_appointment_v47(
         w.biz, w.staff, w.branch, w.service,
         (w.next_sunday + time '11:00') at time zone 'Asia/Singapore',
         (w.next_sunday + time '12:00') at time zone 'Asia/Singapore',
         null)
       then 'OK'
       else 'FAIL: refused a slot squarely inside the staff''s own personal Sunday window' end
  from _w w;

delete from public.staff_hours h using _w w where h.staff_id = w.staff and h.weekday = 0;

-- ── T3: an explicit weekly off-day still refuses, even with no personal row (shop-hours default
--        must not override a stated absence) ──────────────────────────────────────────────────
insert into public.staff_recurring_off_days (id, business_id, staff_id, weekday, created_at)
select gen_random_uuid(), w.biz, w.staff, 0, now()
  from _w w;

insert into _r select '03 T3 an explicit weekly off-day still refuses the shop-hours fallback',
  case when not app.staff_free_for_appointment_v47(
         w.biz, w.staff, w.branch, w.service,
         (w.next_sunday + time '11:00') at time zone 'Asia/Singapore',
         (w.next_sunday + time '12:00') at time zone 'Asia/Singapore',
         null)
       then 'OK'
       else 'FAIL: a staff member marked off that weekday was still accepted (v383 must still win)' end
  from _w w;

delete from public.staff_recurring_off_days d using _w w where d.staff_id = w.staff and d.weekday = 0;

-- ── T1 replay: with the off-day removed, the shop-hours fallback is available again ───────────
insert into _r select '04 T1 replay: fallback restored once the off-day row is gone',
  case when app.staff_free_for_appointment_v47(
         w.biz, w.staff, w.branch, w.service,
         (w.next_sunday + time '11:00') at time zone 'Asia/Singapore',
         (w.next_sunday + time '12:00') at time zone 'Asia/Singapore',
         null)
       then 'OK'
       else 'FAIL: the fallback did not come back after removing the off-day row' end
  from _w w;

select id, value from _r order by id;

rollback;
