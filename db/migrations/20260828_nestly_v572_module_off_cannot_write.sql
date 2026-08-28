-- nestly_v572 -- a module set Off cannot write that module's tables.
--
-- THE DEFECT (found by the full module audit the owner asked for after v570). v570 closed the
-- dashboard READER. This closes the far worse half the audit then found: six tables whose only
-- policy is a permissive ALL keyed on app.is_salon_member(business_id) -- workspace membership
-- alone. Module permissions were never consulted, so ANY approved teammate could write them
-- straight over the REST API, whatever the owner had switched Off.
--
-- PROVEN IN PRODUCTION, not inferred. As the real `authenticated` role, impersonating the staff
-- account the owner reported (allowlist exactly {clients, sales, till}), inside begin/rollback:
--     app.can_module(business,'services') = false
--     update services set price_cents = 3500 ...  ->  1 row
--     price_before = 3000   price_after = 3500
-- A teammate denied the Services module re-priced the firm's menu from SGD 30.00 to SGD 35.00.
-- The same shape let her INSERT into waitlist. booking_requests, appointment_services and
-- service_products share the identical policy shape (policy-proven; those tables are empty in
-- that tenant, so absence of rows was the only thing stopping it). change_requests allowed any
-- member to UPDATE -- i.e. to approve a customer's reschedule/cancel request.
--
-- THE FIX -- gate WRITES, never READS. Each ALL policy is split into an unchanged SELECT policy
-- plus INSERT/UPDATE/DELETE policies that additionally ask app.can_module_write(). Reads must
-- stay open on purpose: the till legitimately renders the service menu for a till-permitted
-- teammate who has no Services module, and gating the read would break Record sale. Read
-- exposure on these tables is business reference data, not money or PII, and is reported
-- separately rather than fixed blind.
--
-- WHY THIS IS SAFE FOR EVERY EXISTING ACCOUNT (app.staff_module_mode_v94, same reasoning v570
-- measured): role='owner' returns the platform mode, so owners always pass; a staff row with
-- modules IS NULL and no module_perms map resolves 'rw', so inherit-staff always pass; only an
-- explicit denial resolves otherwise. Blast radius measured live before writing this migration:
--   17 owners            -> unaffected
--   0  inherit-staff     -> unaffected
--   2  configured staff  -> lose exactly the writes their owner already switched Off
-- Those two are the reported teammate and a UAT frontdesk whose allowlist is {appointments}.
-- That is the intended effect of the fix, not collateral damage.
--
-- service_branches also had a real hole of its own: its WITH CHECK was is_salon_owner but its
-- USING was is_salon_member, and DELETE is governed by USING alone -- so any member could delete
-- a service's branch assignments. Writes there are now owner-only in all four commands, which is
-- what the WITH CHECK always intended.
--
-- ROLLBACK: db/tests/v572_module_off_cannot_write.sql

begin;

do $pre$
declare
  v_missing text;
begin
  if to_regprocedure('app.can_module_write(uuid,text)') is null then
    raise exception 'v572: app.can_module_write(uuid,text) is missing -- the authority this migration delegates to';
  end if;
  select string_agg(t, ', ') into v_missing
  from unnest(array['services','service_products','service_branches','waitlist',
                    'booking_requests','appointment_services','change_requests']) t
  where to_regclass('public.'||t) is null;
  if v_missing is not null then
    raise exception 'v572: expected tables are absent: %', v_missing;
  end if;
end
$pre$;

-- Idempotent from either starting state. This migration first shipped under the version number
-- v571, which a parallel session had already used for an unrelated retention fix; renumbering it
-- to v572 renamed the policies it creates, so the v571-suffixed policies from that first apply
-- are dropped here alongside the ones this file itself creates. Replaying is a no-op.
drop policy if exists services_select on public.services;
drop policy if exists services_insert_v572 on public.services;
drop policy if exists services_insert_v571 on public.services;
drop policy if exists services_update_v572 on public.services;
drop policy if exists services_update_v571 on public.services;
drop policy if exists services_delete_v572 on public.services;
drop policy if exists services_delete_v571 on public.services;
drop policy if exists service_products_select on public.service_products;
drop policy if exists service_products_insert_v572 on public.service_products;
drop policy if exists service_products_insert_v571 on public.service_products;
drop policy if exists service_products_update_v572 on public.service_products;
drop policy if exists service_products_update_v571 on public.service_products;
drop policy if exists service_products_delete_v572 on public.service_products;
drop policy if exists service_products_delete_v571 on public.service_products;
drop policy if exists service_branches_select on public.service_branches;
drop policy if exists service_branches_insert_v572 on public.service_branches;
drop policy if exists service_branches_insert_v571 on public.service_branches;
drop policy if exists service_branches_update_v572 on public.service_branches;
drop policy if exists service_branches_update_v571 on public.service_branches;
drop policy if exists service_branches_delete_v572 on public.service_branches;
drop policy if exists service_branches_delete_v571 on public.service_branches;
drop policy if exists waitlist_select on public.waitlist;
drop policy if exists waitlist_insert_v572 on public.waitlist;
drop policy if exists waitlist_insert_v571 on public.waitlist;
drop policy if exists waitlist_update_v572 on public.waitlist;
drop policy if exists waitlist_update_v571 on public.waitlist;
drop policy if exists waitlist_delete_v572 on public.waitlist;
drop policy if exists waitlist_delete_v571 on public.waitlist;
drop policy if exists booking_requests_select on public.booking_requests;
drop policy if exists booking_requests_insert_v572 on public.booking_requests;
drop policy if exists booking_requests_insert_v571 on public.booking_requests;
drop policy if exists booking_requests_update_v572 on public.booking_requests;
drop policy if exists booking_requests_update_v571 on public.booking_requests;
drop policy if exists booking_requests_delete_v572 on public.booking_requests;
drop policy if exists booking_requests_delete_v571 on public.booking_requests;
drop policy if exists appointment_services_select on public.appointment_services;
drop policy if exists appointment_services_insert_v572 on public.appointment_services;
drop policy if exists appointment_services_insert_v571 on public.appointment_services;
drop policy if exists appointment_services_update_v572 on public.appointment_services;
drop policy if exists appointment_services_update_v571 on public.appointment_services;
drop policy if exists appointment_services_delete_v572 on public.appointment_services;
drop policy if exists appointment_services_delete_v571 on public.appointment_services;
drop policy if exists change_requests_update_v572 on public.change_requests;
drop policy if exists change_requests_update_v571 on public.change_requests;

-- ---------------------------------------------------------------- services (module: services)
drop policy if exists services_all on public.services;

create policy services_select on public.services
  for select using (app.is_salon_member(business_id));

create policy services_insert_v572 on public.services
  for insert with check (
    app.is_salon_member(business_id) and app.can_module_write(business_id,'services'));

create policy services_update_v572 on public.services
  for update using (
    app.is_salon_member(business_id) and app.can_module_write(business_id,'services'))
  with check (
    app.is_salon_member(business_id) and app.can_module_write(business_id,'services'));

create policy services_delete_v572 on public.services
  for delete using (
    app.is_salon_member(business_id) and app.can_module_write(business_id,'services'));

-- ------------------------------------------------- service_products (module: services, via parent)
drop policy if exists service_products_all on public.service_products;

create policy service_products_select on public.service_products
  for select using (exists (
    select 1 from public.services s
    where s.id = service_products.service_id and app.is_salon_member(s.business_id)));

create policy service_products_insert_v572 on public.service_products
  for insert with check (exists (
    select 1 from public.services s
    where s.id = service_products.service_id
      and app.is_salon_member(s.business_id)
      and app.can_module_write(s.business_id,'services')));

create policy service_products_update_v572 on public.service_products
  for update using (exists (
    select 1 from public.services s
    where s.id = service_products.service_id
      and app.is_salon_member(s.business_id)
      and app.can_module_write(s.business_id,'services')))
  with check (exists (
    select 1 from public.services s
    where s.id = service_products.service_id
      and app.is_salon_member(s.business_id)
      and app.can_module_write(s.business_id,'services')));

create policy service_products_delete_v572 on public.service_products
  for delete using (exists (
    select 1 from public.services s
    where s.id = service_products.service_id
      and app.is_salon_member(s.business_id)
      and app.can_module_write(s.business_id,'services')));

-- ------------------------------------------ service_branches (writes were already meant to be owner-only)
drop policy if exists service_branches_all on public.service_branches;

create policy service_branches_select on public.service_branches
  for select using (app.is_salon_member(business_id));

create policy service_branches_insert_v572 on public.service_branches
  for insert with check (app.is_salon_owner(business_id));

create policy service_branches_update_v572 on public.service_branches
  for update using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));

create policy service_branches_delete_v572 on public.service_branches
  for delete using (app.is_salon_owner(business_id));

-- ---------------------------------------------------------------- waitlist (module: waitlist)
drop policy if exists waitlist_all on public.waitlist;

create policy waitlist_select on public.waitlist
  for select using (app.is_salon_member(business_id));

create policy waitlist_insert_v572 on public.waitlist
  for insert with check (
    app.is_salon_member(business_id) and app.can_module_write(business_id,'waitlist'));

create policy waitlist_update_v572 on public.waitlist
  for update using (
    app.is_salon_member(business_id) and app.can_module_write(business_id,'waitlist'))
  with check (
    app.is_salon_member(business_id) and app.can_module_write(business_id,'waitlist'));

create policy waitlist_delete_v572 on public.waitlist
  for delete using (
    app.is_salon_member(business_id) and app.can_module_write(business_id,'waitlist'));

-- -------------------------------------------------------- booking_requests (module: bookings)
drop policy if exists br_all on public.booking_requests;

create policy booking_requests_select on public.booking_requests
  for select using (app.is_salon_member(business_id));

create policy booking_requests_insert_v572 on public.booking_requests
  for insert with check (
    app.is_salon_member(business_id) and app.can_module_write(business_id,'bookings'));

create policy booking_requests_update_v572 on public.booking_requests
  for update using (
    app.is_salon_member(business_id) and app.can_module_write(business_id,'bookings'))
  with check (
    app.is_salon_member(business_id) and app.can_module_write(business_id,'bookings'));

create policy booking_requests_delete_v572 on public.booking_requests
  for delete using (
    app.is_salon_member(business_id) and app.can_module_write(business_id,'bookings'));

-- ------------------------------- appointment_services (module: appointments, via parent appointment)
drop policy if exists appt_services_all on public.appointment_services;

create policy appointment_services_select on public.appointment_services
  for select using (exists (
    select 1 from public.appointments a
    where a.id = appointment_services.appointment_id and app.is_salon_member(a.business_id)));

create policy appointment_services_insert_v572 on public.appointment_services
  for insert with check (exists (
    select 1 from public.appointments a
    where a.id = appointment_services.appointment_id
      and app.is_salon_member(a.business_id)
      and app.can_module_write(a.business_id,'appointments')));

create policy appointment_services_update_v572 on public.appointment_services
  for update using (exists (
    select 1 from public.appointments a
    where a.id = appointment_services.appointment_id
      and app.is_salon_member(a.business_id)
      and app.can_module_write(a.business_id,'appointments')))
  with check (exists (
    select 1 from public.appointments a
    where a.id = appointment_services.appointment_id
      and app.is_salon_member(a.business_id)
      and app.can_module_write(a.business_id,'appointments')));

create policy appointment_services_delete_v572 on public.appointment_services
  for delete using (exists (
    select 1 from public.appointments a
    where a.id = appointment_services.appointment_id
      and app.is_salon_member(a.business_id)
      and app.can_module_write(a.business_id,'appointments')));

-- ------------------------------------------- change_requests (approval path -- module: bookings)
-- Deciding a customer's reschedule/cancel request is an approval, and it lived behind bare
-- membership. The SELECT policy is untouched.
drop policy if exists change_requests_update on public.change_requests;

create policy change_requests_update_v572 on public.change_requests
  for update using (
    app.is_salon_member(business_id) and app.can_module_write(business_id,'bookings'))
  with check (
    app.is_salon_member(business_id) and app.can_module_write(business_id,'bookings'));

commit;
