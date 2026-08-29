-- nestly_v611 — the write-time booking guard honours "shop hours are the default" too.
--
-- STATUS: ALREADY APPLIED TO PRODUCTION (gadpooereceldfpfxsod) directly via SQL, ahead of this
-- repo commit. This file is governance-after-the-fact — it is a CREATE OR REPLACE, byte-identical
-- to the live `app.staff_free_for_appointment_v47` transcribed verbatim from
-- `pg_get_functiondef('app.staff_free_for_appointment_v47(uuid,uuid,uuid,uuid,timestamptz,
-- timestamptz,uuid)'::regprocedure)` on 2026-08-29. It is idempotent (CREATE OR REPLACE) and safe
-- to re-run, but it must NOT be treated as "still pending" — the behaviour it describes is already
-- live. Do not re-apply it expecting a state change; it exists so the repo's migration ledger
-- matches prod.
--
-- WHY. nestly_v598 (2026-08-29) implemented the owner ruling "the shop's opening hours are every
-- teammate's default working hours" — but only in the CUSTOMER-facing slot generator
-- (public.internal_public_booking_availability). The WRITE-time guard that actually accepts or
-- refuses a Confirm, app.staff_free_for_appointment_v47, was untouched: it still required a
-- personal public.staff_hours row for the appointment's weekday, with no shop-hours fallback. The
-- customer portal (or staff booking screen) could therefore OFFER a Sunday slot for a teammate
-- with only Mon-Sat personal hours (per v598), and pressing Confirm on that exact slot would come
-- back scheduling_conflict every time — v598 fixed the display, not the write.
--
-- THE CHANGE. Ports the same semantics v598 gave the read path into the guard:
--   * a public.staff_hours row for the weekday it names still governs that weekday (an explicit
--     personal window is an override, unchanged);
--   * a weekday with NO personal staff_hours row for that staff member falls back to
--     public.branch_hours for the branch (the shop's own hours), instead of refusing outright;
--   * nothing else moves — the v383 checks in app.staff_free_for_appointment_v120_base (recurring
--     off days, dated off days) and the staff_blocked_times overlap check at the end of this
--     function are preserved byte for byte, so an explicit "off" still refuses regardless of shop
--     hours.
--
-- NOTE — semantic-version tag collision (not a real conflict): a different, parallel session
-- already used the tag v611/v612 for two APP-ONLY (no migration) changes:
-- tests/customer-wallet/v611-inapp-scan-history-race.test.mjs and
-- tests/customer-wallet/v612-join-referral-both-sides.test.mjs. Those are unrelated JS-level fixes
-- with no SQL migration and a different full name; this migration's full name
-- (nestly_v611_guard_honours_shop_hours_default) and deploy stamp (20260829164723) are unique in
-- both migration-order plans, so the collision is twin-naming only, same as the many other
-- twin-name notes already recorded across this ledger.
--
-- Rollback: db/tests/v611_guard_honours_shop_hours_default.sql

begin;

CREATE OR REPLACE FUNCTION app.staff_free_for_appointment_v47(p_business uuid, p_staff uuid, p_branch uuid, p_service uuid, p_starts timestamp with time zone, p_ends timestamp with time zone, p_exclude_appointment uuid DEFAULT NULL::uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_buffer_before integer:=0;
  v_buffer_after integer:=0;
  v_timezone text;
  v_block_start timestamptz;
  v_block_end timestamptz;
  v_local_start timestamp;
  v_local_end timestamp;
  v_weekday smallint;
begin
  if not app.staff_free_for_appointment_v120_base(
    p_business,p_staff,p_branch,p_service,p_starts,p_ends,p_exclude_appointment
  ) then
    return false;
  end if;

  if p_service is not null then
    select service.buffer_before_min,service.buffer_after_min
      into v_buffer_before,v_buffer_after
      from public.services service
     where service.business_id=p_business and service.id=p_service
       and service.active;
    if not found then return false; end if;
  end if;

  select branch.timezone into v_timezone
    from public.branches branch
   where branch.business_id=p_business and branch.id=p_branch and branch.active;
  if not found then return false; end if;
  v_block_start:=p_starts-make_interval(mins=>coalesce(v_buffer_before,0));
  v_block_end:=p_ends+make_interval(mins=>coalesce(v_buffer_after,0));
  v_local_start:=v_block_start at time zone v_timezone;
  v_local_end:=v_block_end at time zone v_timezone;
  v_weekday:=extract(dow from v_local_start)::smallint;

  -- v611: the shop's opening hours are every teammate's default (the owner ruling nestly_v598
  -- implemented for the CUSTOMER slot function, now honoured by the write-time guard too).
  -- A personal staff_hours row governs the weekday it names; a weekday with NO personal row
  -- falls back to the branch hours checked just above. Explicit absence stays explicit:
  -- staff_recurring_off_days / staff_off_days / blocked times keep refusing via the v383 checks
  -- in staff_free_for_appointment_v120_base and the blocked-times clause below.
  if v_local_end::date<>v_local_start::date
     or not exists (
       select 1 from public.branch_hours hours
        where hours.business_id=p_business and hours.branch_id=p_branch
          and hours.weekday=v_weekday
          and v_local_start::time>=hours.opens_at
          and v_local_end::time<=hours.closes_at
     )
     or (
       exists (
         select 1 from public.staff_hours hours
          where hours.business_id=p_business and hours.staff_id=p_staff
            and hours.weekday=v_weekday
       )
       and not exists (
         select 1 from public.staff_hours hours
          where hours.business_id=p_business and hours.staff_id=p_staff
            and hours.weekday=v_weekday
            and v_local_start::time>=hours.starts_at
            and v_local_end::time<=hours.ends_at
       )
     ) then
    return false;
  end if;

  return not exists (
    select 1 from public.staff_blocked_times blocked
     where blocked.business_id=p_business and blocked.staff_id=p_staff
       and blocked.starts_at < v_block_end
       and blocked.ends_at > v_block_start
  );
end
$function$;

-- Grants restated verbatim from the live proacl ({postgres=X/postgres} — owner-only; no other
-- role has ever had EXECUTE on this function). CREATE OR REPLACE preserves grants automatically,
-- but the checklist requires restating them explicitly rather than inventing new ones.
revoke all on function app.staff_free_for_appointment_v47(uuid, uuid, uuid, uuid, timestamptz, timestamptz, uuid) from public, anon, authenticated, service_role;

commit;
