-- ============================================================================
--  frenly_v17_branch_visibility
--  Branch-scoped READ visibility for a live multi-tenant SaaS (Frenly).
--  Project: kyzovonwnscrzmkvocid   |   Author: Opus (design + rolled-back verify)
--  Status:  REVIEW-ONLY. NOT APPLIED. Fable verifies with rolled-back tests + applies.
--  Apply order: this is additive on top of live head `frenly_v15d_booking_consent`
--               (live = 25 migrations; there is NO applied v16 — a git commit
--               labelled "v16" was never applied, hence this is v17).
-- ============================================================================
--
--  OWNER REQUIREMENT (verbatim)
--  "only owner can view all branch while user can only view specific branch
--   decided by the owner. owner will be able to access individual branch and
--   generate reports based on individual branch / consolidated. dashboard
--   should also support that."
--
--  THE GAP (verified live, 2026-07-18)
--  `sales_select` USING = app.has_perm(business_id,'view_sales') — every role that
--  holds view_sales (owner/manager/staff/frontdesk/bookkeeper) currently reads
--  EVERY branch's sales in its tenant. `appointments_all` (FOR ALL) USING =
--  app.can_module(business_id,'appointments') — same, all branches. There is NO
--  branch restriction anywhere today. Proven: a bookkeeper assigned only to
--  Branch A read Branch B's sales, appointments AND finance.
--
--  THE BOUNDARY ARGUMENT (why this does not regress the go-live tenant gate)
--  Tenant isolation today is a PERMISSIVE policy per table (has_perm / can_module /
--  is_salon_member). Postgres composes RLS as:
--        (OR of PERMISSIVE USING)  AND  (AND of RESTRICTIVE USING)
--  This migration adds branch scoping as a NEW *RESTRICTIVE* FOR SELECT policy per
--  table. It therefore:
--    * NEVER edits, drops, or weakens the existing tenant-isolation policy — the
--      tenant check remains the first, independent AND-term, byte-for-byte
--      unchanged, so cross-tenant is still fail-closed exactly as it passed the
--      go-live gate. (Verified: employee cross-tenant read = 0, before AND after.)
--    * Can only ever SUBTRACT rows within a tenant (a RESTRICTIVE policy cannot
--      widen visibility). Branch scoping is strictly additional restriction.
--    * Leaves ALL write policies (INSERT/UPDATE/DELETE, incl. every FOR ALL
--      policy's WITH CHECK) untouched — a FOR SELECT restrictive policy has no
--      effect on writes, so no FOR ALL policy needs to be split.
--
--  DEVIATION #1 (argued) — restrictive policy instead of "AND into the SELECT USING"
--  The brief suggested AND-ing the predicate into each SELECT USING and splitting
--  FOR ALL policies. A RESTRICTIVE FOR SELECT policy is the strictly safer form of
--  the same intent: it is literally an additional AND-term, it touches none of the
--  go-live-gated policies, and it removes the need to split `appointments_all`
--  (splitting a live FOR ALL policy is exactly the kind of change that could
--  regress writes). Same net semantics, smaller blast radius.
--
--  DEVIATION #2 (necessary) — get_revenue_summary is SECURITY DEFINER
--  The brief assumed RLS alone would make get_revenue_summary compose safely. It
--  does NOT: get_revenue_summary is SECURITY DEFINER (owner=postgres) and BYPASSES
--  RLS, so the branch policy cannot reach its internal aggregates. Verified live: a
--  bookkeeper assigned to Branch A called get_revenue_summary(...,Branch B) and got
--  Branch B revenue. This migration therefore adds an in-function branch guard
--  (the ONLY way to close the reporting hole). It reuses app.can_see_branch so the
--  consolidated (NULL) call is automatically owner/admin/super-admin-only and a
--  specific branch is allowed only if the caller may see it.
--
--  ROLE MAPPING — app.role_class(role) onto the LIVE 5-role vocabulary
--    owner                      -> 'owner'     : all branches
--    manager                    -> 'admin'     : all branches
--    staff | frontdesk | bookkeeper -> 'employee': assigned branches only
--    (legacy stylist/receptionist, or anything unknown) -> 'employee' (fail-safe)
--  Owner & admin see all branches (incl. unattributed rows). Employee is restricted
--  to branches assigned in staff_branches. (role_class did NOT exist live; created.)
--
--  NULL-BRANCH RULING (legacy rows, quick sales, business-wide expenses)
--  can_see_branch(business, NULL) = owner/admin/super-admin only. An employee never
--  sees a row whose branch_id is NULL. Rationale: an unattributed row is not
--  "assigned" to anyone; letting branch-restricted staff read all NULL-branch rows
--  would be a hole (e.g. nulling branch_id to expose data, or legacy pre-branch
--  revenue leaking to every employee). Owner/admin already see everything. Note the
--  three-valued-logic trap is avoided: staff_branches.branch_id is NOT NULL and the
--  employee arm is guarded by `p_branch IS NOT NULL` before any `= p_branch`, and
--  the function always returns a non-NULL boolean.
--
--  FAIL-CLOSED FOR ANON
--  auth.uid() IS NULL -> false. (Policies are TO authenticated; anon never reaches
--  them, but the helper is fail-closed regardless.)
--
--  WHAT IS ADDITIONALLY PROTECTED, AND WHY  (finance "redundancy" resolved)
--  Scoped (RESTRICTIVE FOR SELECT branch policy added):
--    sales, appointments                         -- primary: dashboard + ops + reports
--    payments, expenses, expense_recurrences,     -- finance
--    cash_drawer_sessions, cash_drawer_movements  -- finance
--  Finance is NOT redundant: view_finance is held by owner, manager AND *bookkeeper*.
--  bookkeeper is employee-class, so a branch-restricted bookkeeper would otherwise
--  read every branch's payments/expenses/drawer directly. Proven live (expenses):
--  bookkeeper saw both branches before, only their branch after. For staff/frontdesk
--  the finance policies are belt-and-suspenders (they lack view_finance), harmless.
--  NOT scoped (documented, deliberate):
--    branches, branch_hours, branch_breaks, service_branches  -- branch CONFIG, not
--       tenant transaction data; booking/portal UIs legitimately render every
--       location's hours/services. Low sensitivity; scoping would break booking.
--    staff_branches -- the assignment map itself; can_see_branch reads it, and
--       members must see their own assignments. Left as-is.
--    Views (sale_balance, sale_commission, cash_drawer_balance,
--       cash_drawer_session_summary) inherit RLS from their base tables — no policy
--       needed (and PG applies the invoker's RLS to the underlying tables).
--
--  WRITE PATHS — UNAFFECTED (verified, not merely reasoned)
--  All 7 sale writers + both branch-fill triggers + policy/commission/stock/
--  retention triggers + the completion trigger + cron (run_membership_renewals etc.)
--  are SECURITY DEFINER owned by postgres, and every target table is
--  relforcerowsecurity=false, so they bypass RLS entirely. A FOR SELECT restrictive
--  policy cannot affect INSERT/UPDATE/DELETE in any case. Re-verified with the new
--  policies live-in-place (rolled back): direct sales INSERT ok; record_sale_by_phone
--  ok; appointment completion -> sale ok.
--
--  HOUSE RULES: all new functions are `SET search_path = public`; no new tables
--  (so no TRUNCATE grant to revoke); no new FK between any pair (no PGRST201);
--  RLS fail-closed; additive + idempotent (drop-if-exists before create).
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. app.role_class(role) — map the live 5-role vocabulary to a visibility class.
--    IMMUTABLE, touches no tables. search_path pinned to satisfy the linter.
-- ----------------------------------------------------------------------------
create or replace function app.role_class(p_role text)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when p_role = 'owner'                              then 'owner'
    when p_role = 'manager'                            then 'admin'
    when p_role in ('staff','frontdesk','bookkeeper')  then 'employee'
    else 'employee'   -- legacy (stylist/receptionist) / unknown -> most-restricted
  end;
$$;

comment on function app.role_class(text) is
  'v17: owner->owner, manager->admin, staff/frontdesk/bookkeeper->employee (unknown->employee). Owner & admin see all branches; employee is branch-restricted.';

-- ----------------------------------------------------------------------------
-- 2. app.can_see_branch(business, branch) — the branch visibility predicate.
--    STABLE SECURITY DEFINER (reads staff/staff_branches which are themselves
--    RLS-protected; definer avoids recursive policy evaluation, mirroring the
--    existing app.has_perm / app.is_salon_member helpers).
--    Returns a non-NULL boolean always. Fails closed for anon.
-- ----------------------------------------------------------------------------
create or replace function app.can_see_branch(p_business uuid, p_branch uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when auth.uid() is null      then false            -- fail closed for anon
    when app.is_super_admin()    then true             -- platform read-all (matches *_sa_read)
    else exists (
      select 1
      from public.staff s
      where s.business_id = p_business
        and s.user_id     = auth.uid()
        and (
              -- owner/admin: every branch, including unattributed (NULL) rows
              app.role_class(s.role) in ('owner','admin')
              -- employee: only assigned branches, and never NULL-branch rows
           or ( p_branch is not null
                and exists (
                  select 1
                  from public.staff_branches sb
                  where sb.business_id = p_business
                    and sb.staff_id    = s.id
                    and sb.branch_id   = p_branch
                )
              )
            )
    )
  end;
$$;

comment on function app.can_see_branch(uuid,uuid) is
  'v17 branch visibility. super-admin & owner & admin (manager) -> all branches (incl NULL). employee (staff/frontdesk/bookkeeper) -> only branches assigned in staff_branches; NULL branch is owner/admin only. Fail-closed for anon. Note: intentionally does NOT filter staff.active (mirrors has_perm) so it is never stricter than the tenant gate it composes with.';

-- Least-privilege execute: authenticated evaluates can_see_branch inside RLS
-- policies; role_class is only ever reached transitively (definer context) but is
-- granted for symmetry/future use. Not granted to anon (policies are TO authenticated).
grant execute on function app.role_class(text)         to authenticated;
grant execute on function app.can_see_branch(uuid,uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 3. RESTRICTIVE FOR SELECT branch policies (idempotent).
--    Each ANDs onto the untouched tenant-isolation SELECT path. Writes untouched.
-- ----------------------------------------------------------------------------

-- 3a. sales  (branch_id nullable)  — the primary gap (revenue KPIs, charts, lists)
drop policy if exists sales_branch_visibility on public.sales;
create policy sales_branch_visibility on public.sales
  as restrictive for select to authenticated
  using (app.can_see_branch(business_id, branch_id));

-- 3b. appointments (branch_id nullable) — operations lists / week calendar.
--     appointments_all (FOR ALL) governs writes and is left intact; this
--     restrictive policy only narrows the SELECT command.
drop policy if exists appointments_branch_visibility on public.appointments;
create policy appointments_branch_visibility on public.appointments
  as restrictive for select to authenticated
  using (app.can_see_branch(business_id, branch_id));

-- 3c. Finance tables — closes the bookkeeper (employee-class + view_finance) hole.
--     payments / expenses / expense_recurrences: branch_id nullable (NULL ruling
--     applies). cash_drawer_sessions / cash_drawer_movements: branch_id NOT NULL.
drop policy if exists payments_branch_visibility on public.payments;
create policy payments_branch_visibility on public.payments
  as restrictive for select to authenticated
  using (app.can_see_branch(business_id, branch_id));

drop policy if exists expenses_branch_visibility on public.expenses;
create policy expenses_branch_visibility on public.expenses
  as restrictive for select to authenticated
  using (app.can_see_branch(business_id, branch_id));

drop policy if exists expense_recurrences_branch_visibility on public.expense_recurrences;
create policy expense_recurrences_branch_visibility on public.expense_recurrences
  as restrictive for select to authenticated
  using (app.can_see_branch(business_id, branch_id));

drop policy if exists cash_drawer_sessions_branch_visibility on public.cash_drawer_sessions;
create policy cash_drawer_sessions_branch_visibility on public.cash_drawer_sessions
  as restrictive for select to authenticated
  using (app.can_see_branch(business_id, branch_id));

drop policy if exists cash_drawer_movements_branch_visibility on public.cash_drawer_movements;
create policy cash_drawer_movements_branch_visibility on public.cash_drawer_movements
  as restrictive for select to authenticated
  using (app.can_see_branch(business_id, branch_id));

-- ----------------------------------------------------------------------------
-- 4. get_revenue_summary — add the branch guard (DEVIATION #2 above).
--    Body is the LIVE definition verbatim; the ONLY change is the new guard block
--    immediately after the existing view_finance check. Signature, security,
--    search_path and existing GRANTs are preserved by CREATE OR REPLACE.
-- ----------------------------------------------------------------------------
create or replace function public.get_revenue_summary(
  p_business uuid, p_from date, p_to date, p_branch uuid default null::uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare v_accrual bigint; v_cash bigint; v_expenses bigint;
        v_unpaid bigint; v_collected bigint;
begin
  if not app.has_perm(p_business, 'view_finance') then
    raise exception 'you do not have permission to view finance for this business (view_finance)';
  end if;

  -- v17 branch-visibility guard. This function is SECURITY DEFINER and BYPASSES
  -- RLS, so the row-level branch policy cannot reach the aggregates below. Enforce
  -- the same rule here. can_see_branch(business, NULL) is true only for
  -- owner/admin/super-admin, so a consolidated (p_branch IS NULL) report is
  -- automatically all-branch-privileged, while a specific branch is allowed only
  -- if the caller may see it (an employee passing a non-assigned branch -> deny).
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'you are not permitted to view this branch scope for this business (branch_visibility)'
      using errcode = '42501';
  end if;

  select coalesce(sum(s.amount_cents), 0) into v_accrual
    from sales s
   where s.business_id = p_business
     and s.counts_as_revenue
     and s.occurred_at::date between p_from and p_to
     and (p_branch is null or s.branch_id = p_branch);
  select coalesce(sum(p.amount_cents), 0) into v_cash
    from payments p
    join sales s
      on  s.id = p.sale_id
       or (p.sale_id is null
           and p.appointment_id is not null
           and s.appointment_id = p.appointment_id)
   where p.business_id = p_business
     and s.counts_as_revenue
     and p.occurred_at::date between p_from and p_to
     and (p_branch is null or p.branch_id = p_branch);
  select coalesce(sum(p.amount_cents), 0) into v_collected
    from payments p
   where p.business_id = p_business
     and p.occurred_at::date between p_from and p_to
     and (p_branch is null or p.branch_id = p_branch);
  select coalesce(sum(b.balance_cents), 0) into v_unpaid
    from sale_balance b
   where b.business_id = p_business
     and b.counts_as_revenue
     and b.balance_cents > 0
     and b.occurred_at::date between p_from and p_to
     and (p_branch is null or b.branch_id = p_branch);
  select coalesce(sum(round(e.amount_cents * e.fx_rate_to_base)), 0) into v_expenses
    from expenses e
   where e.business_id = p_business
     and e.voided_at is null
     and e.occurred_on between p_from and p_to
     and (p_branch is null or e.branch_id = p_branch);
  return json_build_object(
    'from', p_from, 'to', p_to, 'branch_id', p_branch,
    'revenue_accrual_cents', v_accrual,
    'revenue_cash_cents',    v_cash,
    'cash_collected_cents',  v_collected,
    'unpaid_balance_cents',  v_unpaid,
    'expenses_cents',        v_expenses,
    'net_accrual_cents',     v_accrual - v_expenses,
    'net_cash_cents',        v_cash    - v_expenses);
end $$;

-- ----------------------------------------------------------------------------
-- 5. super_admin_list_businesses() — platform "view all companies" summary.
--    Did NOT exist live (created here). is_super_admin() guarded (else 42501),
--    audits every call. Seat count via existing app.billable_seats (there is no
--    app.subscription_due live; monthly estimate computed from subscriptions).
--    VOLATILE (it writes audit_log) — must not be marked STABLE.
-- ----------------------------------------------------------------------------
create or replace function public.super_admin_list_businesses()
returns table(
  business_id uuid, name text, industry text,
  branch_count int, staff_count int, client_count int,
  billable_seats int, subscription_status text, est_monthly_cents int)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not app.is_super_admin() then
    raise exception 'super admin only' using errcode = '42501';
  end if;

  insert into public.audit_log(business_id, actor, action, entity, detail)
    values (null, auth.uid(), 'READ', 'businesses',
            jsonb_build_object('fn','super_admin_list_businesses'));

  return query
    select b.id, b.name, b.industry,
           (select count(*)::int from public.branches br where br.business_id = b.id),
           (select count(*)::int from public.staff    s  where s.business_id  = b.id),
           (select count(*)::int from public.clients  c  where c.business_id  = b.id),
           app.billable_seats(b.id),
           coalesce(sub.status, 'none'),
           coalesce(sub.base_price_cents
             + greatest(0, app.billable_seats(b.id) - sub.included_seats)
               * sub.per_seat_price_cents, 0)::int
    from public.businesses b
    left join public.subscriptions sub on sub.business_id = b.id
    order by b.name;
end;
$$;

comment on function public.super_admin_list_businesses() is
  'v17: platform super-admin roster of all tenants (name, industry, #branches, #staff, #clients, billable seats, subscription status, estimated monthly). is_super_admin() guarded; audited to audit_log.';

grant execute on function public.super_admin_list_businesses() to authenticated;

commit;

-- ============================================================================
-- MANUAL TEST SCENARIOS
--   Method used to design/verify this migration (executed live, each wrapped so it
--   ROLLS BACK — every DO block ends in RAISE EXCEPTION which aborts the block and
--   surfaces the numbers in the error text; NOTHING was persisted; live stayed at
--   25 migrations). Reproduce with the exact fixtures below, or adapt UUIDs.
--
--   Live fixtures used (2026-07-18):
--     business B2  = 8c2644b2-2990-4670-b3ff-b9c78455c876  (QA Go-Live Cafe)
--     branch  A    = 0b38d935-a671-4afa-9bd7-579fc2111f9b  (existing default branch of B2)
--     owner(B2) uid= 25173acc-d97a-4136-892f-2ad97c7ea8bb
--     business B3  = dcaaf5d6-3396-43b4-bff4-1cdd4df01cbf  (cross-tenant control)
--   All 3 live staff are owners, so the test MINTS a non-owner employee inside the txn.
--
--   Establishing a real non-superuser RLS context (critical — table owner/postgres
--   bypasses RLS because relforcerowsecurity=false):
--     perform set_config('request.jwt.claims',
--        json_build_object('sub', <uid>, 'role','authenticated')::text, true);
--     execute 'set local role authenticated';   -- drops owner-bypass; RLS now enforced
--     ... assertions ...
--     execute 'reset role';                      -- back to owner/postgres for DDL
--   Canary proving the drop worked: as owner/postgres the Branch-B row is visible;
--   as the employee it is not.
--
--   ---- SCENARIO 1: sales boundary (the core proof) ----
--   Setup in B2 (owner context): mint auth user + staff(role 'bookkeeper') assigned
--   via staff_branches to Branch A ONLY; add Branch B; add one sale in A, one in B,
--   and one with branch_id = NULL (disable trg_sales_default_branch for that insert).
--     BEFORE FIX (employee)     : A=4  B=1  NULL=1     <- B=1 and NULL=1 are the LEAK
--     canary (owner-bypass)     : sees B = 1           <- data really exists
--     AFTER FIX (employee)      : A=4  B=0  NULL=0  total_B2=4  cross_tenant_B3=0
--     CONTROL (owner of B2)     : A=4  B=1  NULL=1     <- owner NOT restricted; if
--                                                         owner B ever reads 0, the
--                                                         policy is over-blocking.
--   Result: PASS (leak before, closed after, control intact, cross-tenant still 0).
--
--   ---- SCENARIO 2: get_revenue_summary guard (SECURITY DEFINER hole) ----
--   As bookkeeper assigned to A (has view_finance); revenue sale A=1000, B=2000.
--     BEFORE FIX: get_revenue_summary(B2,.,.,BranchB).revenue_accrual = 2000  <- LEAK
--     AFTER FIX : employee BranchA = 1000 (allowed); BranchB = DENIED;
--                 NULL/consolidated = DENIED (employee may not see all-branch total)
--                 owner NULL/consolidated = 3000 ; owner BranchB = 2000 (allowed)
--   Result: PASS.
--
--   ---- SCENARIO 3: appointments boundary ----
--     BEFORE FIX employee BranchB = 1 (leak); AFTER employee A>0, B=0; owner B=1.
--   Result: PASS.
--
--   ---- SCENARIO 4: finance (expenses) boundary for bookkeeper ----
--     BEFORE FIX A=1 B=1 (bookkeeper sees both); AFTER A=1 B=0; owner B=1.
--   Result: PASS (confirms finance scoping is NOT redundant for bookkeeper).
--
--   ---- SCENARIO 5: super-admin read-all still works ----
--     As a super admin, restrictive policy short-circuits to true:
--     sees Branch B = 1, sees rows across all tenants. Result: PASS.
--
--   ---- SCENARIO 6: write paths (with new policies in place) ----
--     direct INSERT into sales (owner)                    -> OK, row visible
--     record_sale_by_phone(...) quick-sale RPC (owner)    -> OK, 1 sale row
--     insert appointment + set status='completed' (owner) -> OK, completion trigger
--                                                            created 1 sale row
--   Result: PASS (all SECURITY DEFINER; unaffected by FOR SELECT restrictive policy).
--
--   ---- SCENARIO 7: super_admin_list_businesses() ----
--     as super admin -> returns 3 rows + writes 1 audit_log row;
--     as a non-super-admin (owner) -> raises (DENIED). Result: PASS.
-- ============================================================================

-- ============================================================================
-- ROLLBACK PLAN (if applied and needs reverting)
--   begin;
--     drop policy if exists sales_branch_visibility                on public.sales;
--     drop policy if exists appointments_branch_visibility         on public.appointments;
--     drop policy if exists payments_branch_visibility             on public.payments;
--     drop policy if exists expenses_branch_visibility             on public.expenses;
--     drop policy if exists expense_recurrences_branch_visibility  on public.expense_recurrences;
--     drop policy if exists cash_drawer_sessions_branch_visibility on public.cash_drawer_sessions;
--     drop policy if exists cash_drawer_movements_branch_visibility on public.cash_drawer_movements;
--     -- restore the pre-v17 get_revenue_summary (identical body WITHOUT the
--     -- can_see_branch guard block) via CREATE OR REPLACE;
--     drop function if exists public.super_admin_list_businesses();
--     drop function if exists app.can_see_branch(uuid,uuid);
--     drop function if exists app.role_class(text);
--   commit;
--   Dropping only the policies (leaving the helpers/guard) instantly restores the
--   prior all-branch read behaviour without touching tenant isolation.
-- ============================================================================
