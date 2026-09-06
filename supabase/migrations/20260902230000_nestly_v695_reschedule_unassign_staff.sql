/* nestly_v695 — "Anyone available" can actually un-assign a booking request when staff move it.

   Audit finding W4G (P2, confirmed read-only against production gadpooereceldfpfxsod on
   2026-09-06 with a rolled-back probe run as the real principal).

   THE DEFECT — coalesce cannot express "nobody".
     public.staff_reschedule_and_confirm_booking_request_v329 applied the staff choice as

       update public.booking_requests
          set preferred_at = p_preferred,
              staff_id = coalesce(p_staff, staff_id)

     NULL was the only way the RPC could be told "no team member", and coalesce reads NULL as
     "leave it alone". W3B/F075 then made "Anyone available" a real option in both reschedule
     forms in app/app.js, whose empty value reaches the RPC as p_staff:null — and its own comment
     recorded the coalesce shape as the reason that was safe. It is safe in one direction only:
     a request that arrived UNASSIGNED stays unassigned, which is what F075 tested. A request the
     customer filed WITH a named team member cannot be un-assigned at all. Staff picked
     "Anyone available", pressed "Move & confirm", were told the move applied, and the request
     was confirmed with the original person still on it. Live proof, rolled back, on production:

       the customer asked for a named team member -> request.staff_id = <member> status=new
       staff pick "Anyone available" (p_staff => null) and move the request
         -> rpc outcome=applied, status=confirmed, request.staff_id AFTER = <the SAME member>
       the appointment that was created -> appointment.staff_id = <the SAME member>

     The confirmation is not merely cosmetic: staff_decide_booking_request_v73 books that member,
     so the wrong person is scheduled and the round-robin that "Anyone available" is supposed to
     invoke never runs.

   THE FIX — say "clear it" explicitly, because NULL already means "unchanged".
     A new boolean parameter p_clear_staff, defaulting to false:

       p_clear_staff = false  ->  staff_id = coalesce(p_staff, staff_id)   (v329, byte-for-byte)
       p_clear_staff = true   ->  staff_id = null

     Passing both a team member and p_clear_staff is a contradiction, not a precedence puzzle, so
     it is refused with 22023 rather than resolved silently.

   WHY DROP AND RECREATE RATHER THAN ADD AN OVERLOAD. CREATE OR REPLACE cannot add a parameter;
   it would leave the 4-argument function in place beside a 5-argument one, and PostgREST answers
   a named-argument call that matches two candidates with PGRST203 — which is exactly how every
   promotion save was blocked in v410. So the old signature is dropped and the new one carries
   the default, leaving ONE function in the catalogue. The 4-argument call is still valid: the
   default supplies p_clear_staff, so any caller that has not been updated keeps the behaviour it
   has today. Nothing else in the database references this function (checked against production:
   no other pg_proc body mentions it), and it is called from app/app.js and nowhere else.

   NO PERMISSION CHANGE. The ACL below restates production verbatim
   ({postgres=X/postgres, authenticated=X/postgres, service_role=X/postgres}). The
   app.can_module_write(p_business,'bookings') guard, the pending-status check, the future-date
   check, the staff-belongs-to-this-business check and the delegation to
   public.staff_decide_booking_request_v73 (which does the real branch-scoped authorisation via
   app.require_branch_module_v94) are all unchanged.

   Client: both reschedule forms in app/app.js now send p_clear_staff, true only when the form
   actually offered the choice and the person using it chose the empty "Anyone available" option.

   Rollback suite: db/tests/v695_reschedule_unassign_staff.sql */
begin;

drop function if exists public.staff_reschedule_and_confirm_booking_request_v329(uuid, uuid, timestamptz, uuid);

create or replace function public.staff_reschedule_and_confirm_booking_request_v329(
  p_business uuid,
  p_request uuid,
  p_preferred timestamptz,
  p_staff uuid default null,
  p_clear_staff boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_request public.booking_requests%rowtype;
begin
  -- Defence in depth, matching the existing decline check's shape in
  -- staff_decide_booking_request_v73_v94_base. The real, branch-scoped authorization still
  -- happens inside the staff_decide_booking_request_v73 call below via
  -- app.require_branch_module_v94 — this is not a substitute for it.
  if not app.can_module_write(p_business, 'bookings') then
    raise exception 'booking write access is required' using errcode = '42501';
  end if;

  /* nestly_v695: naming a team member AND asking to clear the choice is a contradiction. It is
     refused rather than given a precedence rule, so a client bug can never become a silent
     mis-assignment. */
  if coalesce(p_clear_staff, false) and p_staff is not null then
    raise exception 'choose a team member or leave it open, not both' using errcode = '22023';
  end if;

  select * into v_request
    from public.booking_requests
   where id = p_request and business_id = p_business
   for update;
  if not found then
    raise exception 'booking request not found' using errcode = '22023';
  end if;
  if v_request.status not in ('new', 'pending', 'waitlisted') then
    raise exception 'this request is no longer pending' using errcode = '22023';
  end if;

  if p_preferred is null or p_preferred < clock_timestamp() then
    raise exception 'a future date and time is required' using errcode = '22023';
  end if;

  if p_staff is not null and not exists (
    select 1 from public.staff member
     where member.id = p_staff
       and member.business_id = p_business
       and coalesce(member.active, true)
  ) then
    raise exception 'invalid request' using errcode = '22023';
  end if;

  /* nestly_v695: NULL means "unchanged" here and always has, so "leave it open" needs a word of
     its own. Without p_clear_staff the customer's original team member survived every
     "Anyone available" reschedule and was then booked by staff_decide_booking_request_v73. */
  update public.booking_requests
     set preferred_at = p_preferred,
         staff_id = case
                      when coalesce(p_clear_staff, false) then null
                      else coalesce(p_staff, staff_id)
                    end
   where id = p_request and business_id = p_business;

  return public.staff_decide_booking_request_v73(p_business, p_request, 'confirm', null);
end;
$function$;

/* ACL restated verbatim from production, on the new exact overload. */
revoke all on function public.staff_reschedule_and_confirm_booking_request_v329(uuid, uuid, timestamptz, uuid, boolean) from public, anon;
grant execute on function public.staff_reschedule_and_confirm_booking_request_v329(uuid, uuid, timestamptz, uuid, boolean) to authenticated, service_role;

comment on function public.staff_reschedule_and_confirm_booking_request_v329(uuid, uuid, timestamptz, uuid, boolean) is
  'nestly_v329/v695 moves a pending booking request to a new time (and optionally a new team member) and confirms it through staff_decide_booking_request_v73. v695: p_clear_staff = true un-assigns the request, because p_staff = NULL has always meant "unchanged" and there was therefore no way to honour the customer-facing "Anyone available" choice. The two are mutually exclusive and passing both is refused.';

-- =============================================================================================
-- Prove the change took, in the same transaction that made it.
-- =============================================================================================
do $verify$
declare
  v_count integer;
  v_def text;
begin
  select count(*) into v_count
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'staff_reschedule_and_confirm_booking_request_v329';
  if v_count <> 1 then
    raise exception 'nestly_v695: % overloads of the reschedule RPC exist — PostgREST would answer a named-argument call with PGRST203', v_count
      using errcode = 'XX001';
  end if;

  v_def := pg_get_functiondef(
    'public.staff_reschedule_and_confirm_booking_request_v329(uuid,uuid,timestamptz,uuid,boolean)'::regprocedure);
  if position('p_clear_staff boolean DEFAULT false' in v_def) = 0 then
    raise exception 'nestly_v695: the clear flag is not defaulted, so the four-argument call is no longer valid'
      using errcode = 'XX001';
  end if;
  if position('when coalesce(p_clear_staff, false) then null' in v_def) = 0 then
    raise exception 'nestly_v695: the reschedule RPC still cannot clear an existing staff assignment'
      using errcode = 'XX001';
  end if;
  if position('else coalesce(p_staff, staff_id)' in v_def) = 0 then
    raise exception 'nestly_v695: the unchanged-when-not-clearing behaviour was lost'
      using errcode = 'XX001';
  end if;
  if position('choose a team member or leave it open, not both' in v_def) = 0 then
    raise exception 'nestly_v695: naming a member while clearing is no longer refused'
      using errcode = 'XX001';
  end if;
  if position('app.can_module_write(p_business, ''bookings'')' in v_def) = 0 then
    raise exception 'nestly_v695: the bookings write guard was lost' using errcode = 'XX001';
  end if;
  if exists (select 1 from information_schema.routine_privileges
              where routine_schema = 'public'
                and routine_name = 'staff_reschedule_and_confirm_booking_request_v329'
                and grantee in ('anon','PUBLIC')) then
    raise exception 'nestly_v695: the reschedule RPC became anonymously reachable' using errcode = 'XX001';
  end if;
  if not exists (select 1 from information_schema.routine_privileges
                  where routine_schema = 'public'
                    and routine_name = 'staff_reschedule_and_confirm_booking_request_v329'
                    and grantee = 'authenticated') then
    raise exception 'nestly_v695: the browser lost execute on the reschedule RPC' using errcode = 'XX001';
  end if;
end
$verify$;

commit;
