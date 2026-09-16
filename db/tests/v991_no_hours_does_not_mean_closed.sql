-- nestly_v991 acceptance — an unconfigured shop is not a closed shop.
--
-- Run:  supabase db query --linked -f db/tests/v991_no_hours_does_not_mean_closed.sql
-- Ends by raising V991_RESULT so nothing commits. PASS is an exception saying ALL PASS.
--
-- PROVEN RED FIRST against production, before the migration existed. Same tenant (QA Test Cafe),
-- same staff member, same branch, same Wednesday 10:00-11:00 slot; the only variable is whether the
-- branch has any opening hours recorded:
--     no branch_hours rows        -> app.staff_free_for_appointment_v47 = false   (cannot book)
--     branch_hours 09:00-18:00    -> true
-- 18 of the 24 businesses on this estate had no branch_hours row at all, and 16 of those had never
-- created a single appointment.
--
-- Assertion 2 is the one that was red. Assertions 3 and 4 are the controls that stop the fix from
-- being "hours are ignored" — a migration that simply deleted the check would pass assertion 2 and
-- break the product.

begin;

do $v991$
declare
  n integer := 0;
  v_biz uuid; v_branch uuid; v_staff uuid; v_name text;
  v_start timestamptz; v_end timestamptz;
  v_weekday smallint;
  v_free boolean;
begin
  -- ==========================================================================================
  -- 1 · A SUBJECT: an active branch with an assigned active staff member and no hours at all.
  --     Manufactured if production has none, so this suite cannot pass by finding nothing.
  -- ==========================================================================================
  select b.id, b.name, br.id, s.id into v_biz, v_name, v_branch, v_staff
    from public.businesses b
    join public.branches br on br.business_id=b.id and br.active
    join public.staff s on s.business_id=b.id and s.active
    join public.staff_branches sb on sb.business_id=b.id and sb.staff_id=s.id and sb.branch_id=br.id
   where not exists (select 1 from public.branch_hours h where h.branch_id=br.id)
   limit 1;

  if v_biz is null then
    /* every branch now has hours — take one and strip them for the duration of this transaction */
    select b.id, b.name, br.id, s.id into v_biz, v_name, v_branch, v_staff
      from public.businesses b
      join public.branches br on br.business_id=b.id and br.active
      join public.staff s on s.business_id=b.id and s.active
      join public.staff_branches sb on sb.business_id=b.id and sb.staff_id=s.id and sb.branch_id=br.id
     limit 1;
    if v_biz is null then
      raise exception 'V991 INCONCLUSIVE: no tenant has an active branch with an assigned active staff member';
    end if;
    delete from public.branch_hours where branch_id = v_branch;
  end if;
  n := n + 1;

  v_start := (date_trunc('week', now() at time zone 'Asia/Singapore')::date + 9 + time '10:00')
             at time zone 'Asia/Singapore';
  v_end := v_start + interval '1 hour';
  v_weekday := extract(dow from (v_start at time zone 'Asia/Singapore'))::smallint;

  -- ==========================================================================================
  -- 2 · THE DEFECT. No opening hours must mean "no restriction", not "closed for ever".
  --     This is the assertion that was red.
  -- ==========================================================================================
  v_free := app.staff_free_for_appointment_v47(v_biz, v_staff, v_branch, null, v_start, v_end, null);
  if not v_free then
    raise exception 'V991 ASSERT 2 FAILED: % has no opening hours and its staff are unbookable — an unconfigured shop is being treated as a closed one', v_name;
  end if;
  n := n + 1;

  -- ==========================================================================================
  -- 3 · CONTROL — hours that COVER the slot still allow it. (A fix that deleted the check would
  --     also pass assertion 2; this and assertion 4 are what tell the two apart.)
  -- ==========================================================================================
  insert into public.branch_hours(business_id, branch_id, weekday, opens_at, closes_at)
  values (v_biz, v_branch, v_weekday, time '09:00', time '18:00');

  v_free := app.staff_free_for_appointment_v47(v_biz, v_staff, v_branch, null, v_start, v_end, null);
  if not v_free then
    raise exception 'V991 ASSERT 3 FAILED: a 10:00-11:00 slot was refused inside 09:00-18:00 opening hours';
  end if;
  n := n + 1;

  -- ==========================================================================================
  -- 4 · CONTROL — hours that EXCLUDE the slot still refuse it. Opening hours must keep working.
  -- ==========================================================================================
  update public.branch_hours
     set opens_at = time '14:00', closes_at = time '18:00'
   where branch_id = v_branch and weekday = v_weekday;

  v_free := app.staff_free_for_appointment_v47(v_biz, v_staff, v_branch, null, v_start, v_end, null);
  if v_free then
    raise exception 'V991 ASSERT 4 FAILED: a 10:00-11:00 slot was allowed although the branch opens at 14:00 — the fix removed the restriction instead of guarding it';
  end if;
  n := n + 1;

  -- ==========================================================================================
  -- 5 · A DIFFERENT WEEKDAY WITH NO ROW IS STILL UNRESTRICTED, even though this branch now has
  --     hours for one weekday. "Configured" is per weekday, not per branch — which is what the
  --     guard actually tests, and the distinction a coarser fix would lose.
  -- ==========================================================================================
  v_start := v_start + interval '1 day';
  v_end := v_start + interval '1 hour';
  if extract(dow from (v_start at time zone 'Asia/Singapore'))::smallint = v_weekday then
    raise exception 'V991 INCONCLUSIVE: the +1 day slot landed on the same weekday';
  end if;
  v_free := app.staff_free_for_appointment_v47(v_biz, v_staff, v_branch, null, v_start, v_end, null);
  if not v_free then
    raise exception 'V991 ASSERT 5 FAILED: a weekday with no hours row was refused because a DIFFERENT weekday has one';
  end if;
  n := n + 1;

  raise exception 'V991_RESULT ALL PASS (% assertions) on %', n, v_name;
end
$v991$;

rollback;
