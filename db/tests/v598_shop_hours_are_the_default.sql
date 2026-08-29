-- Rollback-only acceptance for nestly_v598 — the shop's hours are every teammate's default.
-- Run: supabase db query --linked -f db/tests/v598_shop_hours_are_the_default.sql
-- Any value starting FAIL is a failure. Nothing is committed.
--
-- Driven by the tenant that reported it: Cubbly SPA, whose Cubbly · Orchard branch is open every
-- day 10:00-19:00 and whose three bookable staff carry personal hours for Mon-Sat only. Before
-- v598 that combination produced zero Sunday slots for customers; the checks below run the real
-- availability function over a real Sunday and read what a customer would actually be offered.
begin;

create temp table _r(id text, value text) on commit drop;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

create temp table _f as
select b.id as biz, b.slug,
  (select br.id from public.branches br
    where br.business_id=b.id and br.active and br.name like 'Cubbly%' limit 1) as branch,
  (select sv.id from public.services sv where sv.business_id=b.id limit 1) as service,
  -- the next Sunday, so the window under test is a real future date the generator will emit
  (current_date + ((7 + 0 - extract(dow from current_date)::int) % 7 + 7) % 7
     + case when extract(dow from current_date)::int = 0 then 7 else 0 end)::date as next_sunday
from public.businesses b where b.id='8492e8d6-8888-4383-ada0-7e1ed69f0caa';
grant select, insert on all tables in schema pg_temp to authenticated, anon;

insert into _r select '00 fixture is the reported shape',
  case when (select branch from _f) is null then 'FAIL: no Cubbly · Orchard branch'
       when (select service from _f) is null then 'FAIL: no service to price a slot with'
       when extract(dow from (select next_sunday from _f))::int <> 0 then 'FAIL: not a Sunday'
       when not exists(select 1 from public.branch_hours h,_f f
                        where h.branch_id=f.branch and h.weekday=0)
         then 'FAIL: the branch has no Sunday opening hours'
       when exists(select 1 from public.staff_hours h,_f f
                    where h.business_id=f.biz and h.weekday=0)
         then 'FAIL: somebody already has Sunday hours — the regression cannot be observed'
       else 'OK shop open Sunday, nobody has personal Sunday hours' end;

-- ── 01 the reported symptom is gone: a customer is offered Sunday ──────────
create temp table _avail as
select public.internal_public_booking_availability(
  (select slug from _f),(select service from _f),null,
  (select next_sunday from _f),1,(select branch from _f)) as j;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

insert into _r select '01 the shop being open on Sunday now offers Sunday slots',
  case when jsonb_array_length(coalesce(j->'days','[]'::jsonb))=0
         then 'FAIL: no days returned at all: '||left(j::text,200)
       when coalesce(jsonb_array_length(j->'days'->0->'slots'),0)=0
         then 'FAIL: Sunday came back with zero slots (the v598 bug): '||left((j->'days'->0)::text,300)
       else 'OK '||jsonb_array_length(j->'days'->0->'slots')||' slots' end from _avail;

insert into _r select '01b every teammate the shop has is offered, not just one',
  case when jsonb_array_length(coalesce((select j->'staff' from _avail),'[]'::jsonb))
          = (select count(*) from public.staff s,_f f
              where s.business_id=f.biz and s.active and coalesce(s.customer_bookable,false))
       then 'OK' else 'FAIL: '||jsonb_array_length(coalesce((select j->'staff' from _avail),'[]'::jsonb))||' offered' end;

insert into _r select '01c the slots sit inside the shop''s own opening hours',
  case when exists(
    -- a slot is {"at": <timestamptz>, "staff_ids": [...]}, not a bare timestamp
    select 1 from jsonb_array_elements(
      (select j->'days'->0->'slots' from _avail)) slot
     where ((slot->>'at')::timestamptz at time zone 'Asia/Singapore')::time
             not between (select h.opens_at from public.branch_hours h,_f f where h.branch_id=f.branch and h.weekday=0)
                     and (select h.closes_at from public.branch_hours h,_f f where h.branch_id=f.branch and h.weekday=0))
       then 'FAIL: a slot fell outside 10:00-19:00'
       else 'OK' end;

-- ── 02 being unavailable is STATED, and still refused ──────────────────────
-- A weekly day off is the owner's explicit instrument (v383). With one recorded for every
-- bookable teammate, Sunday must go back to offering nothing at all.
insert into public.staff_recurring_off_days(business_id,staff_id,weekday)
select f.biz,s.id,0 from public.staff s,_f f
where s.business_id=f.biz and s.active and coalesce(s.customer_bookable,false);

insert into _r select '02 a stated weekly day off still closes the day for everyone',
  case when coalesce(jsonb_array_length(
         public.internal_public_booking_availability((select slug from _f),(select service from _f),
           null,(select next_sunday from _f),1,(select branch from _f))->'days'->0->'slots'),0)=0
       then 'OK' else 'FAIL: a teammate marked off every Sunday is still bookable' end;

delete from public.staff_recurring_off_days rec using _f f
 where rec.business_id=f.biz and rec.weekday=0;

-- ── 03 a personal rota still OVERRIDES the shop for the weekday it names ───
insert into public.staff_hours(business_id,staff_id,weekday,starts_at,ends_at)
select f.biz,s.id,0,'14:00','16:00' from public.staff s,_f f
where s.business_id=f.biz and s.active and coalesce(s.customer_bookable,false);

insert into _r select '03 a personal Sunday rota overrides the shop''s hours',
  case when exists(
    select 1 from jsonb_array_elements(
      public.internal_public_booking_availability((select slug from _f),(select service from _f),
        null,(select next_sunday from _f),1,(select branch from _f))->'days'->0->'slots') slot
     where ((slot->>'at')::timestamptz at time zone 'Asia/Singapore')::time < time '14:00')
       then 'FAIL: a slot was offered before the teammate''s own 14:00 start'
       else 'OK' end;

delete from public.staff_hours h using _f f where h.business_id=f.biz and h.weekday=0;

-- ── 04 a day the shop is CLOSED stays closed for everybody ─────────────────
delete from public.branch_hours h using _f f where h.branch_id=f.branch and h.weekday=0;

insert into _r select '04 with the shop shut on Sunday, nobody is bookable',
  case when coalesce(jsonb_array_length(
         public.internal_public_booking_availability((select slug from _f),(select service from _f),
           null,(select next_sunday from _f),1,(select branch from _f))->'days'->0->'slots'),0)=0
       then 'OK' else 'FAIL: slots were offered on a day the shop is closed' end;

select id, value from _r order by id;
rollback;
