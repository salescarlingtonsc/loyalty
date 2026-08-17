-- Rollback-only acceptance for v383 — an off day actually keeps a team member off.
--   supabase db query --linked -f db/tests/v383_off_days_block_bookings.sql
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- Checks 01 and 02 are the PRE-fix state and are expected to show the defects: a recurring off day
-- has nowhere to live, and the public booking page ignores a one-off off day entirely.

begin;

create temp table _r(k text, v text) on commit drop;
create temp table _c(biz uuid, br uuid, owner uuid, staff uuid, svc uuid, slug text,
                     mon date, tue date) on commit drop;
grant select,insert,update,delete on _r,_c to authenticated;
insert into _c(slug) values ('zz-v383-'||substr(md5(random()::text),1,8));

-- booking_staff_choice must be on, or internal_public_booking_availability returns an empty
-- payload before it ever looks at a calendar.
with i as (insert into public.businesses(name,slug,enabled_modules,booking_staff_choice)
  select 'ZZ V383',slug,array['appointments','bookings'],true from _c returning id)
update _c set biz=(select id from i);
with i as (insert into public.branches(business_id,name) select biz,'Main' from _c returning id)
update _c set br=(select id from i);
with i as (insert into auth.users(id,instance_id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at)
  values (gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'zz-v383-'||substr(md5(random()::text),1,8)||'@example.test','x',now(),now(),now()) returning id)
update _c set owner=(select id from i);
insert into public.staff(business_id,user_id,role,active,access_state,full_name)
  select biz,owner,'owner',true,'approved','ZZ V383 Owner' from _c;
insert into public.business_workspace_controls_v94(business_id,approval_status,decided_by,decided_at,decision_reason)
select biz,'approved',owner,now(),'v383 fixture' from _c
on conflict (business_id) do update set approval_status='approved',
  decided_by=excluded.decided_by, decided_at=excluded.decided_at, decision_reason=excluded.decision_reason;
insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
select biz,false from _c on conflict (business_id) do update set workspace_paused=false;

-- a bookable team member and a service
with i as (insert into public.staff(business_id,role,active,access_state,full_name,customer_bookable)
  select biz,'staff',true,'approved','ZZ V383 Stylist',true from _c returning id)
update _c set staff=(select id from i);
insert into public.staff_branches(business_id,staff_id,branch_id) select biz,staff,br from _c;
with i as (insert into public.services(business_id,name,price_cents,duration_min,active,show_on_booking_page)
  select biz,'ZZ Cut',3000,60,true,true from _c returning id)
update _c set svc=(select id from i);
-- the next Monday and the next Tuesday, so the assertions never straddle "today"
update _c set mon=(current_date + ((8 - extract(dow from current_date)::int) % 7 + 7))::date;
update _c set tue=(select mon + 1 from _c);
-- open every weekday so nothing but the off day can close a slot
insert into public.branch_hours(business_id,branch_id,weekday,opens_at,closes_at)
select biz,br,d,'09:00','18:00' from _c, generate_series(0,6) d;

create or replace function pg_temp.free_v383(p_when timestamptz) returns boolean
language sql security definer as $$
  select app.staff_free_for_appointment_v120_base((select biz from _c),(select staff from _c),
    (select br from _c),(select svc from _c), p_when, p_when + interval '60 minutes', null)
$$;
create or replace function pg_temp.public_slots_v383(p_day date) returns integer
language sql security definer as $$
  -- slots are nested per day: {days:[{date, slots:[...]}]}
  select coalesce((
    select sum(jsonb_array_length(day_row->'slots'))::integer
      from jsonb_array_elements(
        coalesce(public.internal_public_booking_availability((select slug from _c),(select svc from _c),
          (select staff from _c), p_day, 1, (select br from _c))->'days','[]'::jsonb)) as day_row
  ),0)
$$;
grant execute on function pg_temp.free_v383(timestamptz), pg_temp.public_slots_v383(date) to authenticated;

insert into _r select '00 a normal Monday slot is bookable to begin with',
  case when pg_temp.free_v383((select (mon + time '10:00') at time zone 'Asia/Singapore' from _c))
  then 'PASS' else 'FAIL the fixture is not bookable even before an off day' end;
insert into _r select '00b the public page offers Monday slots to begin with',
  case when pg_temp.public_slots_v383((select mon from _c))>0
  then 'PASS' else 'FAIL the public page offers nothing even before an off day' end;

-- 01/02 — the pre-fix defects.
insert into _r select '01 recurring off days have nowhere to live',
  case when to_regclass('public.staff_recurring_off_days') is null
  then 'PASS (no storage exists yet)' else 'INFO the table already exists' end;
insert into public.staff_off_days(business_id,staff_id,starts_on,ends_on,reason)
select biz,staff,mon,mon,'v383 one-off' from _c;
insert into _r select '02 pre-fix the PUBLIC page ignores a one-off off day',
  case when pg_temp.public_slots_v383((select mon from _c))>0
  then 'PASS (still offering '||pg_temp.public_slots_v383((select mon from _c))||' slots on a day off)'
  else 'INFO already honoured' end;
insert into _r select '02b pre-fix the staff engine DOES honour the one-off',
  case when not pg_temp.free_v383((select (mon + time '10:00') at time zone 'Asia/Singapore' from _c))
  then 'PASS' else 'FAIL the base engine ignored a one-off off day too' end;



-- --------------------------------------------------------------- public.staff_recurring_off_days
create table if not exists public.staff_recurring_off_days(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  staff_id uuid not null references public.staff(id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6),
  created_at timestamptz not null default now(),
  unique (business_id, staff_id, weekday)
);
comment on table public.staff_recurring_off_days is
  'v383 A team member''s recurring weekly day off. weekday uses extract(dow) — 0 = Sunday — the
   same convention branch_hours and staff_hours already use, so every availability reader asks the
   same question. A one-off day off stays in staff_off_days; this is only the repeating rule.';

alter table public.staff_recurring_off_days enable row level security;

-- Policies mirror staff_off_days exactly: members read, the owner writes, super admin reads.
drop policy if exists staff_recurring_off_days_select on public.staff_recurring_off_days;
create policy staff_recurring_off_days_select on public.staff_recurring_off_days
  for select to authenticated using (app.is_salon_member(business_id));
drop policy if exists staff_recurring_off_days_write on public.staff_recurring_off_days;
create policy staff_recurring_off_days_write on public.staff_recurring_off_days
  for all to authenticated using (app.is_salon_owner(business_id)) with check (app.is_salon_owner(business_id));
drop policy if exists staff_recurring_off_days_sa_read on public.staff_recurring_off_days;
create policy staff_recurring_off_days_sa_read on public.staff_recurring_off_days
  for select to authenticated using (app.is_super_admin());

grant select, insert, update, delete on public.staff_recurring_off_days to authenticated;
grant all on public.staff_recurring_off_days to postgres, service_role;

create index if not exists staff_recurring_off_days_lookup
  on public.staff_recurring_off_days (business_id, staff_id, weekday);


-- --------------------------------------------- app.staff_free_for_appointment_v120_base
CREATE OR REPLACE FUNCTION app.staff_free_for_appointment_v120_base(p_business uuid, p_staff uuid, p_branch uuid, p_service uuid, p_starts timestamp with time zone, p_ends timestamp with time zone, p_exclude_appointment uuid DEFAULT NULL::uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_timezone text;
  v_buffer_before integer := 0;
  v_buffer_after integer := 0;
  v_block_start timestamptz;
  v_block_end timestamptz;
  v_local_start timestamp;
  v_local_end timestamp;
  v_weekday smallint;
begin
  if p_business is null or p_staff is null or p_branch is null
     or p_starts is null or p_ends is null or p_ends <= p_starts then
    return false;
  end if;

  select b.timezone into v_timezone
    from public.branches b
   where b.id = p_branch and b.business_id = p_business and b.active;
  if not found then return false; end if;

  if p_service is not null then
    select service.buffer_before_min, service.buffer_after_min
      into v_buffer_before, v_buffer_after
      from public.services service
     where service.id = p_service and service.business_id = p_business and service.active;
    if not found then return false; end if;
  end if;

  v_block_start := p_starts - make_interval(mins => v_buffer_before);
  v_block_end := p_ends + make_interval(mins => v_buffer_after);
  v_local_start := v_block_start at time zone v_timezone;
  v_local_end := v_block_end at time zone v_timezone;
  v_weekday := extract(dow from v_local_start)::smallint;

  if v_local_end::date <> v_local_start::date then return false; end if;

  if not exists (
    select 1
      from public.staff s
      join public.staff_branches sb
        on sb.business_id = s.business_id and sb.staff_id = s.id
       and sb.branch_id = p_branch
     where s.id = p_staff and s.business_id = p_business and s.active
  ) then return false; end if;

  if p_service is not null
     and exists (
       select 1 from public.staff_services configured
        where configured.business_id = p_business
          and configured.service_id = p_service
     )
     and not exists (
       select 1 from public.staff_services qualified
        where qualified.business_id = p_business
          and qualified.staff_id = p_staff
          and qualified.service_id = p_service
     ) then return false; end if;

  if exists (
    select 1 from public.staff_off_days off_day
     where off_day.business_id = p_business and off_day.staff_id = p_staff
       and v_local_start::date between off_day.starts_on and off_day.ends_on
  ) then return false; end if;

  -- v383: a recurring weekly off day. Same refusal as a one-off, keyed on the SAME weekday
  -- expression (extract(dow ...), 0 = Sunday) the branch and staff hour rules above already use.
  if exists (
    select 1 from public.staff_recurring_off_days recurring
     where recurring.business_id = p_business and recurring.staff_id = p_staff
       and recurring.weekday = v_weekday
  ) then return false; end if;

  -- Legacy workspaces may not have configured opening hours. Once any row exists
  -- for this weekday, the service plus its buffers must fit inside an opening row.
  if exists (
    select 1 from public.branch_hours configured
     where configured.business_id = p_business and configured.branch_id = p_branch
       and configured.weekday = v_weekday
  ) and not exists (
    select 1 from public.branch_hours hours
     where hours.business_id = p_business and hours.branch_id = p_branch
       and hours.weekday = v_weekday
       and v_local_start::time >= hours.opens_at
       and v_local_end::time <= hours.closes_at
  ) then return false; end if;

  if exists (
    select 1 from public.branch_breaks pause
     where pause.business_id = p_business and pause.branch_id = p_branch
       and pause.weekday = v_weekday
       and pause.starts_at < v_local_end::time
       and pause.ends_at > v_local_start::time
  ) then return false; end if;

  -- Existing firms did not always configure staff hours. Preserve availability in that
  -- case, but once a weekday row exists the complete appointment must fit inside it.
  if exists (
    select 1 from public.staff_hours configured
     where configured.business_id = p_business and configured.staff_id = p_staff
       and configured.weekday = v_weekday
  ) and not exists (
    select 1 from public.staff_hours hours
     where hours.business_id = p_business and hours.staff_id = p_staff
       and hours.weekday = v_weekday
       and v_local_start::time >= hours.starts_at
       and v_local_end::time <= hours.ends_at
  ) then return false; end if;

  if exists (
    select 1
      from public.appointments existing
      left join public.services existing_service
        on existing_service.id = existing.service_id
       and existing_service.business_id = existing.business_id
     where existing.business_id = p_business
       and existing.staff_id = p_staff
       and existing.status = 'booked'
       and existing.id is distinct from p_exclude_appointment
       and (
         existing.starts_at - make_interval(mins => coalesce(existing_service.buffer_before_min,0))
       ) < v_block_end
       and (
         existing.ends_at + make_interval(mins => coalesce(existing_service.buffer_after_min,0))
       ) > v_block_start
  ) then return false; end if;

  return true;
end
$function$;

revoke all on function app.staff_free_for_appointment_v120_base(uuid,uuid,uuid,uuid,timestamptz,timestamptz,uuid) from public, anon;
grant execute on function app.staff_free_for_appointment_v120_base(uuid,uuid,uuid,uuid,timestamptz,timestamptz,uuid) to postgres, service_role, authenticated;


-- ------------------------------------------- public.internal_public_booking_availability
CREATE OR REPLACE FUNCTION public.internal_public_booking_availability(p_slug text, p_service uuid, p_staff uuid, p_from date, p_days integer, p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_business public.businesses%rowtype;
  v_duration integer;
  v_days integer := least(greatest(coalesce(p_days, 7), 1), 14);
  v_from date := greatest(coalesce(p_from, (statement_timestamp() at time zone 'Asia/Singapore')::date),
                          (statement_timestamp() at time zone 'Asia/Singapore')::date);
  v_hours_configured boolean;
  v_staff jsonb;
  v_days_out jsonb;
  v_earliest timestamptz := statement_timestamp() + interval '15 minutes';
begin
  if p_slug is null or p_slug !~ '^[a-z0-9][a-z0-9-]{0,62}$' then
    return null;
  end if;

  select business.* into v_business
    from public.businesses business
   where business.slug = p_slug
   limit 1;
  if not found then
    return null;
  end if;

  if coalesce(v_business.booking_staff_choice, false) is not true then
    return jsonb_build_object(
      'staff_choice', false, 'hours_configured', false,
      'slot_minutes', 30, 'staff', '[]'::jsonb, 'days', '[]'::jsonb
    );
  end if;

  if p_service is not null and not exists (
    select 1 from public.services service
     where service.id = p_service
       and service.business_id = v_business.id
       and service.active
       and service.show_on_booking_page
  ) then
    return null;
  end if;

  if p_branch is not null and not exists (
    select 1 from public.branches branch_row
     where branch_row.id = p_branch
       and branch_row.business_id = v_business.id
       and branch_row.active
  ) then
    return null;
  end if;

  select coalesce(service.duration_min, 60)
       + coalesce(service.buffer_before_min, 0)
       + coalesce(service.buffer_after_min, 0)
    into v_duration
    from public.services service
   where service.id = p_service
     and service.business_id = v_business.id;
  v_duration := greatest(coalesce(v_duration, 60), 5);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', bookable.staff_id, 'name', bookable.full_name, 'title', bookable.title
         ) order by lower(bookable.full_name), bookable.staff_id), '[]'::jsonb)
    into v_staff
    from app.v183_bookable_staff(v_business.id, p_service, p_staff, p_branch) bookable;

  v_hours_configured := exists (
    select 1 from public.staff_hours hours
     join app.v183_bookable_staff(v_business.id, p_service, p_staff, p_branch) bookable
       on bookable.staff_id = hours.staff_id
     where hours.business_id = v_business.id
  ) or exists (
    select 1 from public.branch_hours hours
     join public.branches branch_row
       on branch_row.id = hours.branch_id
      and branch_row.business_id = v_business.id
     where hours.business_id = v_business.id
       and (p_branch is null or branch_row.id = p_branch)
  );

  if not v_hours_configured or v_staff = '[]'::jsonb then
    return jsonb_build_object(
      'staff_choice', true,
      'hours_configured', v_hours_configured,
      'slot_minutes', 30,
      'staff', v_staff,
      'days', '[]'::jsonb
    );
  end if;

  with calendar as (
    select (v_from + offset_days)::date as day
      from generate_series(0, v_days - 1) as offset_days
  ), windows as (
    select calendar.day,
           member.staff_id,
           coalesce(own.starts_at, branch.opens_at) as starts_at,
           coalesce(own.ends_at, branch.closes_at) as ends_at
      from calendar
      cross join app.v183_bookable_staff(v_business.id, p_service, p_staff, p_branch) member
      left join public.staff_hours own
        on own.business_id = v_business.id
       and own.staff_id = member.staff_id
       and own.weekday = extract(dow from calendar.day)::smallint
      left join lateral (
        select hours.opens_at, hours.closes_at
          from public.branch_hours hours
          join public.branches branch_row
            on branch_row.id = hours.branch_id
           and branch_row.business_id = v_business.id
           and coalesce(branch_row.active, true)
         where hours.business_id = v_business.id
           and hours.weekday = extract(dow from calendar.day)::smallint
           and (p_branch is null or branch_row.id = p_branch)
         order by branch_row.is_default desc nulls last, branch_row.created_at, branch_row.id
         limit 1
      ) branch on not exists (
        select 1 from public.staff_hours any_row
         where any_row.business_id = v_business.id and any_row.staff_id = member.staff_id
      )
     where coalesce(own.starts_at, branch.opens_at) is not null
       and coalesce(own.ends_at, branch.closes_at) is not null
       -- v383: the public booking page never honoured off days at all — this function does not
       -- call staff_free_for_appointment, so a team member marked off was still offered slots to
       -- strangers. Both kinds are refused here, on the same weekday expression used above.
       and not exists (
         select 1 from public.staff_off_days off_day
          where off_day.business_id = v_business.id and off_day.staff_id = member.staff_id
            and calendar.day between off_day.starts_on and off_day.ends_on
       )
       and not exists (
         select 1 from public.staff_recurring_off_days recurring
          where recurring.business_id = v_business.id and recurring.staff_id = member.staff_id
            and recurring.weekday = extract(dow from calendar.day)::smallint
       )
  ), slots as (
    select windows.day,
           windows.staff_id,
           slot_at
      from windows
      cross join lateral generate_series(
        timezone('Asia/Singapore', (windows.day + windows.starts_at)::timestamp),
        timezone('Asia/Singapore', (windows.day + windows.ends_at)::timestamp) - make_interval(mins => v_duration),
        interval '30 minutes'
      ) as slot_at
  ), free as (
    select slots.day, slots.staff_id, slots.slot_at
      from slots
     where slots.slot_at >= v_earliest
       and not exists (
         select 1 from public.appointments booked
          where booked.business_id = v_business.id
            and booked.staff_id = slots.staff_id
            and booked.status not in ('cancelled', 'no_show', 'declined')
            and tstzrange(booked.starts_at,
                          coalesce(booked.ends_at, booked.starts_at + interval '1 hour'), '[)')
                && tstzrange(slots.slot_at, slots.slot_at + make_interval(mins => v_duration), '[)')
       )
       and not exists (
         select 1 from public.staff_blocked_times blocked
          where blocked.business_id = v_business.id
            and blocked.staff_id = slots.staff_id
            and tstzrange(blocked.starts_at, blocked.ends_at, '[)')
                && tstzrange(slots.slot_at, slots.slot_at + make_interval(mins => v_duration), '[)')
       )
       and not exists (
         select 1 from public.booking_requests pending
         left join public.services pending_service
           on pending_service.id = pending.service_id
          and pending_service.business_id = v_business.id
          where pending.business_id = v_business.id
            and pending.staff_id = slots.staff_id
            and pending.status in ('new', 'pending', 'waitlisted')
            and pending.preferred_at is not null
            and tstzrange(pending.preferred_at,
                          pending.preferred_at + make_interval(mins => greatest(
                            coalesce(pending_service.duration_min, 60)
                              + coalesce(pending_service.buffer_before_min, 0)
                              + coalesce(pending_service.buffer_after_min, 0),
                            5)),
                          '[)')
                && tstzrange(slots.slot_at, slots.slot_at + make_interval(mins => v_duration), '[)')
       )
  ), per_slot as (
    select free.day,
           free.slot_at,
           jsonb_agg(free.staff_id order by free.staff_id) as staff_ids
      from free
     group by free.day, free.slot_at
  )
  select coalesce(jsonb_agg(day_row order by day_row->>'date'), '[]'::jsonb)
    into v_days_out
    from (
      select jsonb_build_object(
               'date', to_char(per_slot.day, 'YYYY-MM-DD'),
               'slots', jsonb_agg(jsonb_build_object(
                 'at', per_slot.slot_at,
                 'staff_ids', per_slot.staff_ids
               ) order by per_slot.slot_at)
             ) as day_row
        from per_slot
       group by per_slot.day
    ) grouped;

  return jsonb_build_object(
    'staff_choice', true,
    'hours_configured', true,
    'slot_minutes', 30,
    'duration_minutes', v_duration,
    'staff', v_staff,
    'days', coalesce(v_days_out, '[]'::jsonb)
  );
exception when others then
  return null;
end;
$function$;

revoke all on function public.internal_public_booking_availability(text,uuid,uuid,date,integer,uuid) from public, anon, authenticated;
grant execute on function public.internal_public_booking_availability(text,uuid,uuid,date,integer,uuid) to postgres, service_role;


insert into _r select '03 the public page now refuses the one-off off day',
  case when pg_temp.public_slots_v383((select mon from _c))=0
  then 'PASS' else 'FAIL still offering '||pg_temp.public_slots_v383((select mon from _c))||' slots' end;

-- a recurring Monday off, with the one-off removed so only the rule is under test
delete from public.staff_off_days where business_id=(select biz from _c);
insert into public.staff_recurring_off_days(business_id,staff_id,weekday)
select biz,staff,extract(dow from mon)::smallint from _c;

insert into _r select '04 the staff engine refuses a recurring Monday',
  case when not pg_temp.free_v383((select (mon + time '10:00') at time zone 'Asia/Singapore' from _c))
  then 'PASS' else 'FAIL a recurring off day did not block the booking engine' end;
insert into _r select '05 the public page refuses a recurring Monday',
  case when pg_temp.public_slots_v383((select mon from _c))=0
  then 'PASS' else 'FAIL public page offered '||pg_temp.public_slots_v383((select mon from _c))||' slots' end;
insert into _r select '06 Tuesday is untouched — only that weekday is off',
  case when pg_temp.free_v383((select (tue + time '10:00') at time zone 'Asia/Singapore' from _c))
        and pg_temp.public_slots_v383((select tue from _c))>0
  then 'PASS' else 'FAIL a recurring Monday closed another weekday too' end;

-- 07 — removing the rule restores the day, so this is reversible in both directions.
delete from public.staff_recurring_off_days where business_id=(select biz from _c);
insert into _r select '07 removing the rule opens the day again',
  case when pg_temp.free_v383((select (mon + time '10:00') at time zone 'Asia/Singapore' from _c))
        and pg_temp.public_slots_v383((select mon from _c))>0
  then 'PASS' else 'FAIL the day stayed closed after the rule was removed' end;

select k as check, v as result from _r order by k;

rollback;
