-- NESTLY v673 — staff_insert is owner-only; the "first owner" bootstrap clause is gone.
--
-- Audit finding F132 (2026-09-02, verified read-only on production as the real
-- `authenticated` role). The frenly_init policy read:
--
--   with check ( app.is_salon_owner(business_id)
--                OR NOT EXISTS (select 1 from public.staff s where s.business_id = staff.business_id) )
--
-- The second arm was meant to let the very first owner row of a brand-new business
-- through. But a subquery inside a policy expression is evaluated AS THE CALLER, under
-- the staff table's own SELECT policy (staff_select = app.is_salon_member). A caller who
-- is not a member of the business sees zero staff rows, so NOT EXISTS is TRUE for every
-- business — and any signed-in account (a customer of any tenant, a teammate of another
-- shop, a self-registered login) could insert itself as staff of any business with one
-- POST to /rest/v1/staff. `authenticated` holds INSERT on public.staff and the only
-- triggers are the audit trail and the v510 inactive-shell guard, so nothing else stood
-- in the way.
--
-- No legitimate caller needs the arm. Every path that creates a staff row —
-- accept_invite, accept_workspace_owner_invite_v79, activate_approved_business_application_v95,
-- platform_activate_approved_application_v169, platform_decide_business_application_v105,
-- start_self_serve_business_v130, commit_import_job — is SECURITY DEFINER (owner postgres,
-- rolbypassrls), and the browser never inserts into staff directly (0 sites in app/app.js
-- and app/platform-console.js). create_business is the v599 denial stub.
--
-- Blast radius before this migration (production, 2026-09-02): 24 staff rows, 21 with a
-- login, 3 non-owner logins — two with a full invite + owner-approval audit trail and one
-- synthetic UAT fixture; no business has more than one owner. No exploitation seen.
--
-- Replay-safe: ALTER POLICY is idempotent. Rollback suite: db/tests/v673_staff_insert_owner_only.sql
begin;

alter policy staff_insert on public.staff
  with check ( app.is_salon_owner(business_id) );

commit;
