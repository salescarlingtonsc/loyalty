-- ============================================================================
-- 20260718_frenly_v14_platform.sql
-- Platform layer: super-admin companies view, BRANCH-SCOPED READ ACCESS,
-- read/write per-module permissions, seat-billing helper, anon self-enrol.
--
-- STATUS: REVIEW-ONLY. Nothing in this file has been applied, committed, or
--         deployed. Fable verifies with rolled-back chain tests and applies.
--         The author (Opus) applied NOTHING. UI ships only AFTER this applies
--         (the reversal_of release-coupling lesson).
--
-- ============================================================================
-- !!! CRITICAL PREMISE CORRECTION — read before reviewing !!!
-- ----------------------------------------------------------------------------
-- The task brief for this migration is written from a STALE snapshot. It states
-- "Live = 17 migrations", "believed 3 businesses / 9 sales / 3 staff / 2 users",
-- and asks me to CREATE super_admin, subscriptions, module_templates, the phone
-- till, the invite/role bug fix, etc. from scratch.
--
-- I fetched LIVE (project kyzovonwnscrzmkvocid) instead of trusting the repo,
-- per the house rule. Reality on 2026-07-18:
--   * 25 migrations are applied, THROUGH v14a-d AND v15a-d. The repo on disk
--     stops at v13 (unapplied) — the repo is behind the DB, as warned.
--   * Row counts VERIFIED live: 3 businesses, 9 sales, 3 staff, 3 users (NOT 2),
--     3 branches, 3 staff_branches (every staff row is an OWNER, each assigned
--     to its own default branch — there is NO non-owner employee live yet).
--   * ALREADY LIVE, do not recreate:
--       - public.super_admins (1 row, API-unwritable: no write policy at all)
--       - app.is_super_admin() — fail-closed for anon (auth.uid() NULL)
--       - 46 "<t>_sa_read" SELECT-only super-admin policies on every tenant table
--       - public.subscriptions (base 2500 / per_seat 1000 / included 1 / SGD),
--         seeded by create_business; app.billable_seats(); v_business_billing
--         (monthly_total = base + max(seats-included,0)*per_seat)
--       - app.can_module()/staff_modules(), staff.modules text[] allowlist,
--         module_templates(business_id,name,modules[])
--       - join_program()/get_join_page()/lookup_client_by_phone()/
--         record_sale_by_phone(), businesses.join_enabled, app.norm_phone(),
--         clients.phone_norm + partial unique (business_id, phone_norm)
--       - The staff/invite ROLE BUG IS ALREADY FIXED. Live CHECKs:
--           staff.role      IN (owner,manager,staff,frontdesk,bookkeeper)
--           staff_invites.role IN (manager,staff,frontdesk,bookkeeper)  [subset]
--         accept_invite inserts a value that always passes the staff CHECK. The
--         "3 of 4 invited roles violate the CHECK" bug described in the brief no
--         longer exists — v14a fixed it. Nothing to fix here; do NOT re-open it.
--
-- Therefore this file is NOT a greenfield v14. It is an ADDITIVE, FULLY
-- IDEMPOTENT hardening layer that BUILDS ON the live platform layer. It is
-- authored to survive Fable's rolled-back replay AGAINST LIVE (a from-scratch
-- CREATE TABLE super_admins / CREATE POLICY *_sa_read would fail "already
-- exists" on the very first statement). Every object here is CREATE OR REPLACE /
-- ADD COLUMN IF NOT EXISTS / DROP POLICY IF EXISTS ... CREATE POLICY.
--
-- It delivers ONLY the genuine gaps:
--   BUILD 1 delta : super_admin_list_businesses() RPC (the companies view the
--                   owner asked for). Everything else in Build 1 already ships.
--   BUILD 2 (NEW) : branch-scoped READ access — a real RLS data boundary.
--   BUILD 3 (NEW) : read-vs-write per-module perms (staff.module_perms jsonb) +
--                   owner/admin/employee role CLASSES + get_my_access().
--   BUILD 4 delta : app.subscription_due() scalar over the existing view.
--   BUILD 5       : enrol_customer() — the exact contract the brief names, as a
--                   thin wrapper over the already-hardened join_program().
--
-- The file name keeps the requested "v14_platform" label, but because v14a-d
-- are taken it is effectively a v16 successor. Fable/owner may rename it to
-- 20260718_frenly_v16_platform.sql before applying — recommended, to keep the
-- version line honest. It has NO ordering dependency on the on-disk unapplied
-- v13 flat-commission migration and does not touch commission.
-- ============================================================================
--
-- ============================================================================
-- DESIGN ARGUMENTS FOR THE RISKY CHOICES
-- ============================================================================
--
-- BUILD 1 — super admin read-only + audited companies list
--   * Read-only is already GUARANTEED live: super-admin visibility is delivered
--     purely by 46 "<t>_sa_read" FOR SELECT policies whose USING is
--     app.is_super_admin(); NO write policy anywhere ORs in is_super_admin on a
--     TENANT table. The only place is_super_admin appears in a write position is
--     subscriptions.subscriptions_sa_write (a PLATFORM table the SA is meant to
--     write) — intentional. The FOR ALL policies the brief worried about
--     (expenses_all, payments*, module_templates_write, etc.) are gated by
--     has_perm/is_salon_owner — NOT is_super_admin — so the SA never gets the
--     write half. I therefore add NOTHING to any write policy. Verified by
--     enumerating pg_policies (see report).
--   * AUDIT HONESTY: per-row SA reads via the *_sa_read RLS policies are NOT
--     audited (RLS SELECT cannot write an audit row). Only the RPC below is
--     audited. This is stated to the owner, not hidden.
--   * super_admins remains API-unwritable (it already has ONLY a SELECT policy;
--     INSERT/UPDATE/DELETE from PostgREST hit no permissive policy => denied).
--     Seeding the first/next super admin is a DELIBERATE out-of-band step:
--       insert into public.super_admins(user_id,email,note) values (...);
--     run as service_role / SQL only. This file seeds NOBODY.
--
-- BUILD 2 — branch scoping is a REAL boundary, and it is READ-scoping
--   * Owner's words: "only owner can VIEW all branch while user can only VIEW
--     specific branch decided by the owner." The ask is explicitly about VIEW.
--     I scope SELECT (reads) — the customer/operational transactional tables
--     that carry branch_id AND are employee-facing: public.sales and
--     public.appointments. That is the real, testable data boundary.
--   * WRITES are deliberately NOT branch-gated (documented deviation). Why:
--     several live sales writers (the app's Quick Sale, some RPCs) insert with
--     branch_id = NULL; the completion trigger and daily cron also write. If I
--     added "employee may only write their branch AND NULL=owner-only" to the
--     write policies, every NULL-branch employee Quick Sale would start failing
--     — a silent production regression on the busiest path. The definer RPCs
--     and triggers bypass RLS anyway, so write-side gating would only ever bite
--     the honest app path. Read-scoping fully satisfies the owner's stated goal;
--     write-side branch enforcement is left for a follow-up once every writer
--     provably sets branch_id. FLAGGED as an open decision for the owner.
--   * NULL branch_id rows (legacy / quick-sale-without-branch): visible to
--     owner/admin-class ONLY, never to a branch-scoped employee. Argument: a row
--     with no branch cannot be "assigned" to an employee's branch, so the safe
--     default is business-wide roles only. Making them employee-visible would be
--     a leak of un-scoped data; making them invisible to owners would hide
--     legacy sales. Owner/admin-only is the fail-closed middle.
--   * Branch-bearing tables NOT scoped and why: branch_hours/branch_breaks/
--     service_branches/staff_branches are CONFIG (member/owner scoped already);
--     payments/expenses/cash_drawer*/sale_balance/sale_commission are FINANCE,
--     already gated by has_perm(view_finance) which only owner/manager/
--     bookkeeper hold — i.e. NOT employees. Branch-scoping finance for
--     employees would be redundant (they can't see it at all). Left as-is;
--     branch filtering there stays a REPORT parameter (get_revenue_summary's
--     p_branch), not an RLS boundary. Documented, not silently skipped.
--   * get_revenue_summary already gates on has_perm(view_finance) and is
--     SECURITY DEFINER. An employee (staff/frontdesk) lacks view_finance so the
--     RPC raises before any branch logic — an employee "passing another branch's
--     id" gets a permission error, not data. Composes correctly with the new RLS
--     (RLS bites direct table reads; the RPC bites at the permission check).
--
-- BUILD 3 — roles + per-module read/write; the HONESTY GATE
--   * ROLE VOCABULARY: the brief asks to collapse to owner/admin/employee and
--     rewrite the staff CHECK. I deliberately DO NOT collapse the physical roles.
--     v14a JUST standardised them to owner|manager|staff|frontdesk|bookkeeper,
--     and app.role_perms() encodes REAL permission differences between them
--     (bookkeeper = view_finance only; frontdesk = create_sales; manager =
--     +refund/finance). Collapsing to 3 roles would DESTROY that granularity —
--     a regression, not a feature, and it would re-litigate a decision the
--     security gate was just built around. Instead I add app.role_class(role)
--     giving the owner's 3-bucket MENTAL MODEL as a projection over the 5 real
--     roles: owner->owner; manager,bookkeeper->admin (business-wide);
--     staff,frontdesk(+legacy stylist,receptionist)->employee (branch-scoped).
--     This is a reviewer's deliberate deviation from the brief WITH rationale;
--     owner sign-off requested if they truly want a 3-role schema.
--   * READ vs WRITE modules: today app.can_module() is a single allowlist used
--     identically in USING and WITH CHECK (read==write). I add staff.module_perms
--     jsonb with the discipline the owner has been bitten by twice:
--         NULL            = INHERIT (fall back to the legacy staff.modules
--                           allowlist == today's behaviour, read==write)
--         '{}'            = sees NOTHING (empty, distinct from NULL)
--         {"inventory":"rw","clients":"r"}  = per-module; key ABSENT = no access;
--                           "r" = read only; "rw" = read+write.
--     app.can_module_read()/can_module_write() resolve this. CRUCIAL no-regression
--     property: when module_perms IS NULL (true for EVERY live staff row today),
--     both functions reduce EXACTLY to app.can_module(). So the 51-assertion
--     security gate behaves identically — the inventory-only employee still gets
--     0 rows on /clients, etc. The new capability only activates when an owner
--     sets module_perms. This is why splitting the FOR ALL policies below is safe.
--   * THE HONESTY STATEMENT (which perms are REAL security vs UI-only):
--       REAL, RLS-enforced read/write:  clients, appointments, products(inventory),
--         stock_batches(inventory). These have USING/WITH CHECK on
--         can_module_read/can_module_write. A "read-only" grant here truly blocks
--         INSERT/UPDATE/DELETE at the database.
--       REAL, but governed by has_perm not module_perms:  finance surfaces
--         (payments/expenses/cash_drawer/sale reads/sale_commission) stay gated
--         by view_finance. module_perms does NOT override the finance boundary —
--         if you grant "expenses:rw" to a bookkeeper-less employee it does
--         nothing; view_finance is the true wall. Consistent by design.
--       UI-ONLY (NOT security):  every other module (waitlist, retention,
--         referrals, memberships, gift_cards, packages, bundles, resources,
--         dashboard, reports, marketing, etc.) has NO sensitive per-row RLS
--         beyond is_salon_member. For these, get_my_access() returning
--         "write:false" is a UI hint the front-end must honour; the DATABASE
--         still allows any member to write. We MUST NOT let module-hiding
--         masquerade as authorization. If a module later needs a true boundary,
--         give it its own can_module_* RLS like clients/appointments.
--   * module_templates.perms jsonb is ADDED (reusable perm sets). RESOLUTION is
--     copy-on-assign: the owner UI expands a template's perms into
--     staff.module_perms when assigning it (per-staff override then wins by being
--     the stored value). I deliberately do NOT join module_templates inside the
--     hot RLS path (can_module_* runs per row) — a template join on every row
--     read would be a measurable tax. Deviation from the brief's "runtime
--     resolution"; rationale = RLS performance + simplicity. Flagged for owner.
--   * Only owner (app.is_salon_owner) may write templates and staff.module_perms/
--     roles — enforced by the EXISTING module_templates_write and staff_update
--     policies (both is_salon_owner). No admin-class write path is added; the
--     brief invited arguing admin could — I judge role/permission editing to be
--     an owner-only act (privilege-escalation surface) and leave it owner-only.
--
-- BUILD 4 — seat billing
--   * Seat definition is ALREADY LIVE and unchanged: a seat = a staff row with
--     user_id IS NOT NULL AND active (app.billable_seats). Rota-only staff
--     (user_id NULL) are FREE; deactivating frees the seat. base covers
--     included_seats (1); due = base + max(seats-included,0)*per_seat. This file
--     only adds app.subscription_due(business) as a scalar wrapper over the
--     existing v_business_billing so the RPC/UI has a single number. Never a
--     stored mutable total. No hard seat cap, no Stripe (owner deferral).
--
-- BUILD 5 — anon self-enrol
--   * join_program() already implements the hardened anon enrol. I add
--     enrol_customer(p_slug,p_phone,p_name,p_email,p_consent) — the EXACT name/
--     arg-order the brief specifies — as a thin SECURITY DEFINER wrapper that
--     calls join_program (arg order (slug,name,phone,...)). No logic is
--     duplicated; the anti-enumeration guarantees are inherited.
--   * ANTI-ENUMERATION (inherited, restated): returns an OPAQUE
--     {status:'ok', business_name:...} whether the phone is new OR already
--     enrolled (ON CONFLICT (business_id,phone_norm) DO NOTHING). It returns NO
--     client id, NO existing name/email, NO "already registered" signal — so an
--     anon caller cannot use it to learn whether a number is a customer, nor
--     read any existing PII. Returning business_name is safe: that is the public
--     business identity from the slug the caller already holds, not client data.
--   * RATE-LIMITING: NONE. There is no infra for it here. This is an unmetered
--     anon insert vector (mass junk clients). We claim NO protection — a
--     captcha / edge rate-limit is REQUIRED before scale. ⚖️ FLAGGED.
--   * PDPA ⚖️: consent is real — marketing_consent on clients AND a row in the
--     consents ledger with source='self_signup' recording grant/withdraw at the
--     moment of decision (join_program does this). We do NOT claim legal
--     compliance; PDPA sign-off is counsel's. ⚖️ FLAGGED.
--
-- SECURITY GATE / REGRESSION POSTURE
--   * The 51-assertion go-live gate (cross-tenant fail-closed for owner/staff/
--     anon/rota) MUST still pass. This file changes only: (a) SELECT policies on
--     sales/appointments to ADD a branch AND-term (tightening, never loosening —
--     cannot create cross-tenant leakage because is_salon_member/has_perm/
--     can_module remain the first AND-term); (b) splits 4 FOR ALL module policies
--     into read+write pairs whose behaviour is IDENTICAL while module_perms is
--     NULL. No policy is loosened. Fail-closed everywhere. Fable re-runs the gate
--     plus new branch assertions.
--
-- HOUSE RULES honoured: every new function is SECURITY DEFINER (except pure/
--   IMMUTABLE role_class) + SET search_path=public; EXECUTE revoked from
--   public,anon then granted intentionally; NO new table (so no truncate/second-
--   FK concern); RLS stays fail-closed. No second FK between any table pair.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. New columns (idempotent, additive, nullable => zero backfill, zero lock risk)
-- ---------------------------------------------------------------------------
alter table public.staff            add column if not exists module_perms jsonb;
alter table public.module_templates add column if not exists perms        jsonb;

comment on column public.staff.module_perms is
  'Per-module read/write override. NULL=inherit legacy staff.modules allowlist; '
  '{}=sees nothing; {"inventory":"rw","clients":"r"} per-module (absent key=no access).';
comment on column public.module_templates.perms is
  'Reusable read/write perm set, same shape as staff.module_perms. Copied into '
  'staff.module_perms on assignment (resolution is copy-on-assign, not RLS-time).';

-- ---------------------------------------------------------------------------
-- 1. Role classes (owner / admin / employee) over the 5 real roles
-- ---------------------------------------------------------------------------
create or replace function app.role_class(p_role text)
  returns text language sql immutable
  set search_path to 'pg_catalog','pg_temp'
as $$
  select case p_role
    when 'owner'      then 'owner'
    when 'manager'    then 'admin'
    when 'bookkeeper' then 'admin'      -- finance oversight => business-wide view
    else 'employee'                     -- staff, frontdesk, legacy stylist/receptionist
  end;
$$;
revoke all on function app.role_class(text) from public, anon;
grant execute on function app.role_class(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. BUILD 2 — branch visibility helper
--    True iff caller is super-admin, OR an owner/admin-class member of the
--    business (see ALL branches), OR assigned to THIS branch via staff_branches.
--    NULL branch => owner/admin only. Fail-closed for anon (auth.uid() NULL =>
--    no staff row, role_class never owner/admin, branch clause false => false).
-- ---------------------------------------------------------------------------
create or replace function app.staff_can_see_branch(p_business uuid, p_branch uuid)
  returns boolean language sql stable security definer
  set search_path to 'public'
as $$
  select
    app.is_super_admin()
    or exists (
      select 1 from public.staff s
      where s.business_id = p_business
        and s.user_id = auth.uid()
        and s.active
        and app.role_class(s.role) in ('owner','admin')
    )
    or (
      p_branch is not null
      and exists (
        select 1
        from public.staff s
        join public.staff_branches sb
          on sb.staff_id = s.id and sb.business_id = s.business_id
        where s.business_id = p_business
          and s.user_id = auth.uid()
          and s.active
          and sb.branch_id = p_branch
      )
    );
$$;
revoke all on function app.staff_can_see_branch(uuid,uuid) from public, anon;
grant execute on function app.staff_can_see_branch(uuid,uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. BUILD 3 — read/write module resolution.
--    module_perms NULL => reduces EXACTLY to app.can_module() (no regression).
-- ---------------------------------------------------------------------------
create or replace function app.can_module_read(p_business uuid, p_module text)
  returns boolean language sql stable security definer
  set search_path to 'public'
as $$
  select exists (
    select 1 from public.staff s
    where s.business_id = p_business
      and s.user_id = auth.uid()
      and s.active
      and (
        s.role = 'owner'
        or (s.module_perms is not null and s.module_perms ? p_module)          -- key present (r or rw)
        or (s.module_perms is null and (s.modules is null or p_module = any(s.modules)))
      )
  );
$$;
revoke all on function app.can_module_read(uuid,text) from public, anon;
grant execute on function app.can_module_read(uuid,text) to authenticated;

create or replace function app.can_module_write(p_business uuid, p_module text)
  returns boolean language sql stable security definer
  set search_path to 'public'
as $$
  select exists (
    select 1 from public.staff s
    where s.business_id = p_business
      and s.user_id = auth.uid()
      and s.active
      and (
        s.role = 'owner'
        or (s.module_perms is not null and (s.module_perms ->> p_module) = 'rw') -- explicit rw
        or (s.module_perms is null and (s.modules is null or p_module = any(s.modules)))
      )
  );
$$;
revoke all on function app.can_module_write(uuid,text) from public, anon;
grant execute on function app.can_module_write(uuid,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. BUILD 2 policy rewrites — SELECT branch-scoping on sales + appointments.
--    Writes untouched (see design note). FOR ALL is split so the write policy
--    NEVER governs SELECT (a FOR ALL write policy would OR back into SELECT and
--    leak other-branch rows to a can_module holder — avoided here).
-- ---------------------------------------------------------------------------

-- sales: already has separate sales_select / sales_insert (append-only, no
-- update/delete policy). Only tighten the read.
drop policy if exists sales_select on public.sales;
create policy sales_select on public.sales
  for select to authenticated
  using (
    app.has_perm(business_id, 'view_sales')
    and app.staff_can_see_branch(business_id, branch_id)
  );
-- sales_insert (has_perm create_sales) and sales_sa_read (super admin) unchanged.

-- appointments: was one FOR ALL policy (appointments_all on can_module).
-- Split into branch-scoped read + unscoped write (can_module_write).
drop policy if exists appointments_all on public.appointments;
create policy appointments_read on public.appointments
  for select to authenticated
  using (
    app.can_module_read(business_id, 'appointments')
    and app.staff_can_see_branch(business_id, branch_id)
  );
create policy appointments_ins on public.appointments
  for insert to authenticated
  with check (app.can_module_write(business_id, 'appointments'));
create policy appointments_upd on public.appointments
  for update to authenticated
  using      (app.can_module_write(business_id, 'appointments'))
  with check (app.can_module_write(business_id, 'appointments'));
create policy appointments_del on public.appointments
  for delete to authenticated
  using (app.can_module_write(business_id, 'appointments'));
-- appointments_sa_read (super admin) unchanged.

-- ---------------------------------------------------------------------------
-- 5. BUILD 3 policy rewrites — split module FOR ALL into read/write pairs.
--    No branch term (these tables carry no branch_id). Behaviour identical to
--    today while module_perms is NULL. clients/appointments are the tables the
--    v14 note calls out as truly RLS-enforced module boundaries.
-- ---------------------------------------------------------------------------

-- clients
drop policy if exists clients_all on public.clients;
create policy clients_read on public.clients
  for select to authenticated using (app.can_module_read(business_id, 'clients'));
create policy clients_ins on public.clients
  for insert to authenticated with check (app.can_module_write(business_id, 'clients'));
create policy clients_upd on public.clients
  for update to authenticated
  using (app.can_module_write(business_id, 'clients'))
  with check (app.can_module_write(business_id, 'clients'));
create policy clients_del on public.clients
  for delete to authenticated using (app.can_module_write(business_id, 'clients'));
-- clients_sa_read unchanged.

-- products (module 'inventory')
drop policy if exists products_all on public.products;
create policy products_read on public.products
  for select to authenticated using (app.can_module_read(business_id, 'inventory'));
create policy products_ins on public.products
  for insert to authenticated with check (app.can_module_write(business_id, 'inventory'));
create policy products_upd on public.products
  for update to authenticated
  using (app.can_module_write(business_id, 'inventory'))
  with check (app.can_module_write(business_id, 'inventory'));
create policy products_del on public.products
  for delete to authenticated using (app.can_module_write(business_id, 'inventory'));
-- products_sa_read unchanged.

-- stock_batches (module 'inventory', scoped via parent product)
drop policy if exists stock_batches_all on public.stock_batches;
create policy stock_batches_read on public.stock_batches
  for select to authenticated
  using (exists (select 1 from public.products p
                 where p.id = stock_batches.product_id
                   and app.can_module_read(p.business_id, 'inventory')));
create policy stock_batches_ins on public.stock_batches
  for insert to authenticated
  with check (exists (select 1 from public.products p
                      where p.id = stock_batches.product_id
                        and app.can_module_write(p.business_id, 'inventory')));
create policy stock_batches_upd on public.stock_batches
  for update to authenticated
  using (exists (select 1 from public.products p
                 where p.id = stock_batches.product_id
                   and app.can_module_write(p.business_id, 'inventory')))
  with check (exists (select 1 from public.products p
                      where p.id = stock_batches.product_id
                        and app.can_module_write(p.business_id, 'inventory')));
create policy stock_batches_del on public.stock_batches
  for delete to authenticated
  using (exists (select 1 from public.products p
                 where p.id = stock_batches.product_id
                   and app.can_module_write(p.business_id, 'inventory')));
-- stock_batches_sa_read unchanged.

-- ---------------------------------------------------------------------------
-- 6. BUILD 3 — resolved-access RPC for the UI
-- ---------------------------------------------------------------------------
create or replace function public.get_my_access(p_business uuid)
  returns json language plpgsql stable security definer
  set search_path to 'public'
as $$
declare s record; v_mods json;
begin
  select * into s from public.staff
   where business_id = p_business and user_id = auth.uid() and active;
  if not found then
    if app.is_super_admin() then
      return json_build_object('role','super_admin','role_class','platform',
                               'is_super_admin', true, 'can_see_all_branches', true);
    end if;
    return json_build_object('role', null, 'role_class', null, 'is_super_admin', false);
  end if;

  select json_object_agg(m, json_build_object(
           'read',  app.can_module_read(p_business, m),
           'write', app.can_module_write(p_business, m)))
    into v_mods
  from unnest((select enabled_modules from public.businesses where id = p_business)) as m;

  return json_build_object(
    'role', s.role,
    'role_class', app.role_class(s.role),
    'is_super_admin', app.is_super_admin(),
    'can_see_all_branches', app.role_class(s.role) in ('owner','admin'),
    'branch_ids', (select coalesce(json_agg(branch_id), '[]'::json)
                     from public.staff_branches where staff_id = s.id),
    'modules', coalesce(v_mods, '{}'::json));
end $$;
revoke all on function public.get_my_access(uuid) from public, anon;
grant execute on function public.get_my_access(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. BUILD 1 delta — super-admin companies list (guarded + audited)
-- ---------------------------------------------------------------------------
create or replace function public.super_admin_list_businesses()
  returns json language plpgsql security definer
  set search_path to 'public'
as $$
declare v json;
begin
  if not app.is_super_admin() then
    raise exception 'super admin only';
  end if;

  select json_agg(x order by x.name) into v
  from (
    select b.id, b.name, b.industry,
      (select count(*) from public.branches br where br.business_id = b.id) as branches,
      (select count(*) from public.staff  s  where s.business_id  = b.id and s.active) as staff,
      (select count(*) from public.clients c where c.business_id  = b.id) as clients,
      vb.billable_seats, vb.monthly_total_cents, vb.status,
      vb.trial_ends_at, vb.current_period_end
    from public.businesses b
    left join public.v_business_billing vb on vb.business_id = b.id
  ) x;

  -- AUDITED (unlike per-row SA reads). business_id is nullable => platform row.
  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (null, auth.uid(), 'SA_LIST_BUSINESSES', 'businesses', null,
          json_build_object('count', coalesce(json_array_length(v), 0))::jsonb);

  return coalesce(v, '[]'::json);
end $$;
revoke all on function public.super_admin_list_businesses() from public, anon;
grant execute on function public.super_admin_list_businesses() to authenticated; -- guard is inside

-- ---------------------------------------------------------------------------
-- 8. BUILD 4 delta — subscription_due() scalar over the existing view
-- ---------------------------------------------------------------------------
create or replace function app.subscription_due(p_business uuid)
  returns integer language sql stable security definer
  set search_path to 'public'
as $$
  select case
           when app.is_salon_member(p_business) or app.is_super_admin()
           then (select monthly_total_cents::int
                   from public.v_business_billing where business_id = p_business)
         end;
$$;
revoke all on function app.subscription_due(uuid) from public, anon;
grant execute on function app.subscription_due(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. BUILD 5 — enrol_customer(): exact-contract wrapper over join_program()
--    Arg order per brief: (slug, phone, name, email, consent).
--    join_program arg order is (slug, name, phone, email, consent).
-- ---------------------------------------------------------------------------
create or replace function public.enrol_customer(
    p_slug   text,
    p_phone  text,
    p_name   text,
    p_email  text    default null,
    p_consent boolean default false)
  returns json language sql security definer
  set search_path to 'public'
as $$
  select public.join_program(p_slug, p_name, p_phone, p_email, p_consent);
$$;
revoke all on function public.enrol_customer(text,text,text,text,boolean) from public, anon;
grant execute on function public.enrol_customer(text,text,text,text,boolean) to anon, authenticated;

comment on function public.enrol_customer(text,text,text,text,boolean) is
  'Anon self-enrol by 8-digit SG mobile. Opaque success; idempotent; no '
  'enumeration oracle. Wrapper over join_program. NO rate limiting (add edge/'
  'captcha before scale). PDPA consent recorded in consents. Legal sign-off ⚖️.';

-- ============================================================================
-- -- MANUAL TEST SCENARIOS  (Fable runs these; author ran NONE — review only)
-- -- Every block is begin; ... rollback;  Nothing is committed.
-- -- NB: live has NO non-owner staff, so Build-2 tests must MINT one first.
-- ============================================================================
--
-- Legend for impersonation (standard pattern in this project):
--   set local role authenticated;
--   set local request.jwt.claims = json_build_object('sub','<user-uuid>','role','authenticated')::text;
-- Reset with: reset role;  (or set local role postgres;)
--
-- ----------------------------------------------------------------------------
-- T1  BUILD 2 — employee assigned to Branch A cannot READ Branch B's sales,
--     owner sees both.  (Control T1c is EXPECTED TO FAIL.)
-- ----------------------------------------------------------------------------
-- begin;
--   -- pick a business with >=2 branches, or create branch B:
--   -- \set biz  '<business_uuid>'
--   -- insert into branches(business_id,name,is_default,active) values (:'biz','Branch B',false,true) returning id;  -- => :branchB
--   -- existing default branch => :branchA
--   -- create a LOGIN employee (needs an auth.users row; in test, reuse an existing user uuid not already staff here):
--   -- insert into staff(business_id,user_id,role,full_name,active) values (:'biz', :'empUser','staff','Test Emp',true) returning id; -- => :emp
--   -- insert into staff_branches(business_id,staff_id,branch_id) values (:'biz', :'emp', :'branchA');
--   -- seed one sale in each branch:
--   -- insert into sales(business_id,branch_id,kind,amount_cents) values (:'biz',:'branchA',5000,...);  -- A
--   -- insert into sales(business_id,branch_id,kind,amount_cents) values (:'biz',:'branchB',7000,...);  -- B
--   set local role authenticated;
--   set local request.jwt.claims = json_build_object('sub', :'empUser','role','authenticated')::text;
--   -- T1a EXPECT: >=1 (branch A visible)
--   select count(*) as branchA_visible from sales where business_id=:'biz' and branch_id=:'branchA';
--   -- T1b EXPECT: 0  (branch B invisible — the real boundary)
--   select count(*) as branchB_visible from sales where business_id=:'biz' and branch_id=:'branchB';
--   -- T1c CONTROL, EXPECTED TO FAIL: asserting the employee CAN see branch B.
--   do $$ begin
--     if (select count(*) from sales where branch_id = current_setting('myapp.branchB')::uuid) = 0
--     then raise exception 'CONTROL FAILED AS DESIGNED: employee cannot see branch B';
--     end if;
--   end $$;
--   reset role;
--   -- T1d owner sees BOTH:
--   set local request.jwt.claims = json_build_object('sub', :'ownerUser','role','authenticated')::text;
--   select count(*) as owner_sees_all from sales where business_id=:'biz' and branch_id in (:'branchA',:'branchB'); -- EXPECT 2
-- rollback;
--
-- ----------------------------------------------------------------------------
-- T2  BUILD 2 — get_revenue_summary composition: employee (no view_finance)
--     passing branch B's id gets a PERMISSION ERROR, not data.
-- ----------------------------------------------------------------------------
-- begin;
--   set local role authenticated;
--   set local request.jwt.claims = json_build_object('sub', :'empUser','role','authenticated')::text;
--   -- EXPECT: raises 'you do not have permission to view finance ... (view_finance)'
--   select public.get_revenue_summary(:'biz', current_date-30, current_date, :'branchB');
-- rollback;
--
-- ----------------------------------------------------------------------------
-- T3  BUILD 1 — super admin READ works but WRITE is rejected on a tenant table.
--     (Show the real 42501.)
-- ----------------------------------------------------------------------------
-- begin;
--   set local role authenticated;
--   set local request.jwt.claims = json_build_object('sub', :'saUser','role','authenticated')::text; -- a super_admins user
--   -- T3a EXPECT: rows (SA reads another tenant's clients via clients_sa_read)
--   select count(*) from clients;
--   -- T3b EXPECT: ERROR 42501 new row violates row-level security policy for "clients"
--   insert into clients(business_id, full_name) values (:'otherBiz','SA should not write');
--   -- T3c EXPECT: ERROR 42501 (credit_ledger has no SA write either)
--   insert into credit_ledger(business_id, client_id, amount_cents) values (:'otherBiz', :'someClient', 100);
--   -- T3d EXPECT: SA CAN write subscriptions (platform table, subscriptions_sa_write)
--   update subscriptions set note='sa-ok' where business_id=:'otherBiz';
--   -- T3e EXPECT: ERROR — super_admins is API-unwritable even by a super admin
--   insert into super_admins(user_id,email) values (gen_random_uuid(),'x@y.z');
-- rollback;
--
-- ----------------------------------------------------------------------------
-- T4  BUILD 3 — read-only module grant truly blocks writes at the DB.
-- ----------------------------------------------------------------------------
-- begin;
--   -- grant the test employee clients READ-ONLY, inventory READ-WRITE:
--   update staff set module_perms = '{"clients":"r","inventory":"rw","appointments":"r"}'::jsonb
--    where id = :'emp';
--   set local role authenticated;
--   set local request.jwt.claims = json_build_object('sub', :'empUser','role','authenticated')::text;
--   -- T4a EXPECT: rows (clients read allowed)
--   select count(*) from clients where business_id=:'biz';
--   -- T4b EXPECT: ERROR 42501 (clients write denied — read only)
--   insert into clients(business_id, full_name) values (:'biz','nope');
--   -- T4c EXPECT: success (inventory rw)
--   insert into products(business_id, name, price_cents) values (:'biz','Test P',100);
--   -- T4d EXPECT: 0 rows / denied on a module NOT in the map (e.g. appointments write)
--   insert into appointments(business_id, client_id, starts_at, ends_at)
--     values (:'biz', :'someClient', now(), now()+interval '1h');   -- appointments is "r" => 42501
--   -- T4e HONESTY: waitlist has NO can_module RLS => this WRITE SUCCEEDS even though
--   --     get_my_access would report write:false. Proves module-hide != authz.
--   insert into waitlist(business_id, client_id) values (:'biz', :'someClient'); -- EXPECT success
-- rollback;
--
-- ----------------------------------------------------------------------------
-- T5  BUILD 3 — no-regression: module_perms NULL behaves exactly like today.
--     inventory-only employee (legacy staff.modules) still gets 0 clients.
-- ----------------------------------------------------------------------------
-- begin;
--   update staff set module_perms = null, modules = array['inventory'] where id = :'emp';
--   set local role authenticated;
--   set local request.jwt.claims = json_build_object('sub', :'empUser','role','authenticated')::text;
--   select count(*) as clients_visible from clients where business_id=:'biz'; -- EXPECT 0
--   select count(*) as products_visible from products where business_id=:'biz'; -- EXPECT >=0 allowed
-- rollback;
--
-- ----------------------------------------------------------------------------
-- T6  BUILD 5 — enrol_customer is idempotent and not an enumeration oracle.
-- ----------------------------------------------------------------------------
-- begin;
--   -- business must have join_enabled=true and a slug :slug
--   set local role anon;
--   -- T6a first enrol EXPECT: {"status":"ok","business_name":...}
--   select public.enrol_customer(:'slug','81863833','Ada', null, true);
--   -- T6b same phone again EXPECT: IDENTICAL opaque {"status":"ok",...} (no error, no id, no "exists")
--   select public.enrol_customer(:'slug','+65 8186 3833','Someone Else', null, false);
--   reset role;
--   -- T6c EXPECT: exactly ONE client row for that number (idempotent, normalised)
--   select count(*) as one_row from clients
--     where business_id = (select id from businesses where slug=:'slug')
--       and phone_norm = '81863833';           -- EXPECT 1
--   -- T6d EXPECT: consent ledger recorded once for the created row
--   select count(*) from consents c
--     join businesses b on b.slug=:'slug' and b.id=c.business_id
--     where c.source='self_signup';            -- EXPECT >=1
-- rollback;
--
-- ----------------------------------------------------------------------------
-- T7  BUILD 4 — subscription_due matches the view; non-member gets NULL.
-- ----------------------------------------------------------------------------
-- begin;
--   set local role authenticated;
--   set local request.jwt.claims = json_build_object('sub', :'ownerUser','role','authenticated')::text;
--   select app.subscription_due(:'biz') as due,
--          (select monthly_total_cents from v_business_billing where business_id=:'biz') as view_total; -- EQUAL
--   -- non-member business => NULL (not another tenant's number)
--   select app.subscription_due(:'otherBiz') as should_be_null; -- EXPECT NULL
-- rollback;
--
-- ============================================================================
-- ROLLBACK PLAN (if this migration must be reversed after apply)
-- ============================================================================
-- -- Restore the four original FOR ALL module policies and the two reads, then
-- -- drop the new objects. (Original defs captured from live pg_policies.)
-- begin;
--   -- sales read
--   drop policy if exists sales_select on public.sales;
--   create policy sales_select on public.sales for select to authenticated
--     using (app.has_perm(business_id,'view_sales'));
--   -- appointments
--   drop policy if exists appointments_read on public.appointments;
--   drop policy if exists appointments_ins  on public.appointments;
--   drop policy if exists appointments_upd  on public.appointments;
--   drop policy if exists appointments_del  on public.appointments;
--   create policy appointments_all on public.appointments for all to authenticated
--     using (app.can_module(business_id,'appointments'))
--     with check (app.can_module(business_id,'appointments'));
--   -- clients
--   drop policy if exists clients_read on public.clients;
--   drop policy if exists clients_ins  on public.clients;
--   drop policy if exists clients_upd  on public.clients;
--   drop policy if exists clients_del  on public.clients;
--   create policy clients_all on public.clients for all to authenticated
--     using (app.can_module(business_id,'clients')) with check (app.can_module(business_id,'clients'));
--   -- products
--   drop policy if exists products_read on public.products;
--   drop policy if exists products_ins  on public.products;
--   drop policy if exists products_upd  on public.products;
--   drop policy if exists products_del  on public.products;
--   create policy products_all on public.products for all to authenticated
--     using (app.can_module(business_id,'inventory')) with check (app.can_module(business_id,'inventory'));
--   -- stock_batches
--   drop policy if exists stock_batches_read on public.stock_batches;
--   drop policy if exists stock_batches_ins  on public.stock_batches;
--   drop policy if exists stock_batches_upd  on public.stock_batches;
--   drop policy if exists stock_batches_del  on public.stock_batches;
--   create policy stock_batches_all on public.stock_batches for all to authenticated
--     using (exists (select 1 from products p where p.id=stock_batches.product_id
--                    and app.can_module(p.business_id,'inventory')))
--     with check (exists (select 1 from products p where p.id=stock_batches.product_id
--                    and app.can_module(p.business_id,'inventory')));
--   -- functions & columns
--   drop function if exists public.enrol_customer(text,text,text,text,boolean);
--   drop function if exists public.super_admin_list_businesses();
--   drop function if exists public.get_my_access(uuid);
--   drop function if exists app.subscription_due(uuid);
--   drop function if exists app.staff_can_see_branch(uuid,uuid);
--   drop function if exists app.can_module_read(uuid,text);
--   drop function if exists app.can_module_write(uuid,text);
--   drop function if exists app.role_class(text);
--   alter table public.staff            drop column if exists module_perms;
--   alter table public.module_templates drop column if exists perms;
-- commit;   -- (kept as commit in the plan; run inside begin/rollback to rehearse)
-- ============================================================================
-- END 20260718_frenly_v14_platform.sql
