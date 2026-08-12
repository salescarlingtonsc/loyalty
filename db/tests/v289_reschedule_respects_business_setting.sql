-- Rollback-only acceptance for v289 — the public reschedule respects the business setting.
-- Proves against the DEPLOYED function (not the migration text): the guard exists, it gates
-- only reschedules, it fails closed on a missing capability row, and cancel is untouched.
begin;
do $suite$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'internal_public_booking_change';
  if v_def is null then
    raise exception 'v289: internal_public_booking_change is missing';
  end if;
  if position('cap.appointment_changes_enabled' in v_def) = 0 then
    raise exception 'v289: the reschedule guard on appointment_changes_enabled is missing';
  end if;
  if v_def !~ 'p_kind = ''reschedule'' and not coalesce\(\(\s*select cap\.appointment_changes_enabled' then
    raise exception 'v289: the guard must gate ONLY reschedules — cancel is never refused';
  end if;
  if position('where cap.business_id = v_appt.business_id), false)' in v_def) = 0 then
    raise exception 'v289: fail closed — a missing capability row must refuse, and the business id must come from the token''s own appointment';
  end if;
  -- the guard must run BEFORE any write
  if position('cap.appointment_changes_enabled' in v_def) >
     position('insert into public.change_requests' in v_def) then
    raise exception 'v289: the guard must precede the change_requests insert';
  end if;
  raise notice 'v289 acceptance: all assertions passed';
end $suite$;
rollback;
