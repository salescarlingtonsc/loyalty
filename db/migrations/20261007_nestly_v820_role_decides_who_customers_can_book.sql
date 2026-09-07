-- nestly_v820 — the job decides who a customer can book; the owner can still say otherwise.
--
-- OWNER RULING, 2026-09-07, on the customer booking page's "Who would you like?" step:
--   "clare = receptionist - should not have any bookings available. we only look at roles -
--    ask if unsure. unless owner explicitly agree with that particular staff to be bookable"
-- and, asked which roles: exclude the owner role too, and apply the rule to people who
-- already exist rather than only to new ones.
--
-- WHAT WAS WRONG. An end-to-end walk of the booking page found the Team step and the Time
-- step disagreeing about who is bookable:
--
--     Amanda        Senior therapist   works 6/7 days    90 slots   offered
--     Vincent       Senior Therapist   works 7/7 days   126 slots   offered
--     Clare         Receptionist       works 0/7 days     0 slots   offered  <-- dead end
--     Kiat Ke Ying  Manager            works 0/7 days     0 slots   offered  <-- dead end
--
-- app.v183_bookable_staff offers anyone active, customer_bookable and assigned to the branch.
-- It never asks whether the person does the work. So a customer picked the receptionist and
-- landed on an empty Time step with nothing to explain it. Availability was right; the list
-- in front of it was not.
--
-- HOW THIS IS BUILT, and why it is not a role test in the query. The obvious fix — add
-- `role = 'staff'` to v183_bookable_staff — would make the owner's own override impossible:
-- a receptionist a salon genuinely wants bookable could never be shown, whatever anyone
-- ticked. The ruling explicitly keeps that door open ("unless owner explicitly agree").
--
-- So the role sets the STORED DEFAULT and the flag stays the single authority:
--   1. every existing active member whose role is not 'staff' has customer_bookable set to
--      false — the role default applied to people who already exist, as ruled;
--   2. a newly created member is stamped customer_bookable = (role = 'staff') on insert;
--   3. app.v183_bookable_staff is NOT changed. It still reads customer_bookable and nothing
--      else, so Customer Interface -> Appointment Setting keeps working exactly as it did and
--      a tick on any individual, of any role, still puts them back on the booking page.
--
-- BLAST RADIUS, measured before writing this rather than after. The Team step only exists
-- where businesses.booking_staff_choice is on — 4 businesses on the estate, not the 23 a
-- naive count of owners suggests. Of those 4, exactly one ends up with nobody bookable, and
-- it has no appointments at all. Two frontdesk members are affected estate-wide, neither has
-- ever had an appointment. Nothing that is taking real bookings today stops.
--
-- NOT DONE, deliberately: a role CHANGE does not re-stamp the flag. Promoting a receptionist
-- to staff leaves them unbookable until someone ticks them, which is the safe direction —
-- re-stamping would silently undo an owner's explicit "no".

begin;

-- 1. The role default, applied to the people who already exist.
--    Restricted to active members: a deactivated row's flag is not worth rewriting, and
--    leaving it alone keeps the change reversible by reactivation + tick.
update public.staff
   set customer_bookable = false
 where active
   and role is distinct from 'staff'
   and coalesce(customer_bookable, true);

-- 2. The role default, applied at creation. A trigger rather than a column DEFAULT because
--    the answer depends on the row's own role, which a column default cannot see.
create or replace function app.staff_customer_bookable_role_default_v820()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  /* Creation-time default only. Whatever the caller passed is replaced by the role's answer,
     which is what "default" means here — every insert path (accept_invite, the Settings
     roster, seeds) gets the same treatment without each having to remember the rule. The
     owner's override is a later UPDATE through Appointment Setting, which this never sees. */
  new.customer_bookable := (new.role = 'staff');
  return new;
end
$function$;

drop trigger if exists trg_staff_customer_bookable_role_default_v820 on public.staff;
create trigger trg_staff_customer_bookable_role_default_v820
  before insert on public.staff
  for each row execute function app.staff_customer_bookable_role_default_v820();

comment on column public.staff.customer_bookable is
  'nestly_v820: whether this member appears on the customer booking page. Stamped at insert '
  'from the role (only role=staff starts true) and thereafter owned entirely by the business, '
  'through Customer Interface -> Appointment Setting. app.v183_bookable_staff reads this and '
  'never the role, so an owner can put any individual of any role back on the page.';

revoke all on function app.staff_customer_bookable_role_default_v820() from public, anon, authenticated;

commit;
