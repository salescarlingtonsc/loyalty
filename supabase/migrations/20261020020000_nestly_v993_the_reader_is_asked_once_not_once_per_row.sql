-- nestly_v993 — the reader is asked once, not once per row (2026-09-16).
--
-- THE DEFECT. Row-level security on public.sales and public.clients calls its guard functions
-- with the ROW's own columns, so Postgres must evaluate them once per row instead of once per
-- query. The sales SELECT predicate was the AND of four policies:
--
--   sales_sa_read                  PERMISSIVE   app.is_super_admin()
--   sales_select                   PERMISSIVE   app.has_perm(business_id,'view_sales')
--   sales_branch_visibility        RESTRICTIVE  app.can_see_branch(business_id, branch_id)
--   sales_v94_branch_module_select RESTRICTIVE  is_super_admin() OR
--                                               can_module_read_at_v94(business_id, branch_id,'sales')
--
-- Measured on production as the real owner of the largest tenant, everything warm:
--
--     21 rows ->  60.9 ms     99 rows -> 222.7 ms
--     40 rows -> 106.7 ms    252 rows -> 429.2 ms          ~2.1 ms per row
--
-- Per 1000 calls, also measured: can_module_read_at_v94 1084 ms, can_see_branch 724 ms,
-- has_perm 328 ms, is_super_admin 192 ms. The ~0.19 ms floor on is_super_admin — which for a
-- normal caller is one index lookup that short-circuits before the Google-session check — is
-- the per-call overhead of a SECURITY DEFINER function in this database. That is why making the
-- BODIES faster cannot fix this: the cost is the number of CALLS, and there are three to five
-- of them for every row read.
--
-- The role `authenticated` carries statement_timeout=8s. OFFSET re-evaluates the predicate on
-- every skipped row, so a cafe recording ~110 sales a day crosses the wall on page four of
-- "Sales & refunds" inside the default 30-day window, and the failure path leaves the loading
-- skeleton on screen rather than an error.
--
-- THE FIX. Ask once. app.sales_read_scope_v993() returns the (business, branch) pairs the caller
-- may read, computed from the SAME three guards. A subquery with no outer reference is hoisted
-- by Postgres into an InitPlan and evaluated once per statement, so the per-row work becomes a
-- hash lookup. Measured on the same tenant and rows: 222.7 ms -> 17 ms, thirteen times faster,
-- and now flat in the row count rather than linear.
--
-- WHY A CASE AND NOT AN OR. The fast path can only enumerate branches that BELONG to the
-- business. app.can_see_branch returns true for an owner or manager against ANY branch id,
-- including one belonging to another business or one that does not exist — so for a malformed
-- row the enumeration is narrower than the predicate it replaces. An equivalence proof across
-- 112 (business, branch) pairs and 26 principals found exactly that: 75 of 2912 evaluations
-- diverged, all of them rows whose branch is not the business's own, and all in the direction of
-- hiding one of the owner's own rows. The second CASE arm is therefore the OLD predicate,
-- verbatim, reached only when the row's branch does not belong to its business. CASE is used
-- rather than OR because CASE guarantees evaluation order and OR does not — the planner is free
-- to reorder OR arms by estimated cost, and this one must try the cheap arm first. With the
-- fallback in place the same proof returns 0 divergent of 2912, and the timing is unchanged.
--
-- public.clients has no branch dimension at all (app.can_module_read is
-- can_module_read_at_v94(business, NULL, module)), so its scope is a plain list of businesses
-- and needs no fallback.
--
-- public.appointments has the same defect and the same shape as sales and is deliberately NOT
-- changed here. It is a separate equivalence proof, it grows far more slowly than sales, and
-- three copies of this CASE is the "one rule spelled in several places" mistake that nestly_v992
-- had just finished cleaning up. It should follow, with this file as the pattern.
--
-- THE DROPPED POLICIES. sales_sa_read, sales_branch_visibility, sales_v94_branch_module_select
-- and clients_sa_read are dropped rather than left as no-ops, because their meaning now lives in
-- the scope functions and a second copy of an authorization rule is a defect waiting to happen.
-- No test asserts these names (checked across tests/ and db/tests/); they appear only in the
-- frozen schema snapshot and in dated audit artifacts, neither of which gates a build. The
-- super-admin arms are not lost: both scope functions return every business when
-- app.is_super_admin() is true — see the next paragraph for how far that is proved.
--
-- PROVEN, AND NOT PROVEN. The equivalence proof runs 2912 sales evaluations and 624 client
-- evaluations across every active staff login and every business, and returns 0 divergent. It
-- does NOT exercise the super-admin arm: app.is_super_admin() requires
-- app.platform_session_via_google_v625(), and a synthetic request.jwt.claims cannot carry a real
-- Google session, so it returns false even for the row in public.super_admins. That arm is
-- therefore equivalent by construction rather than by execution — both the old predicate and the
-- new one call the same app.is_super_admin(), and when it is true both admit everything — and it
-- should be re-checked from a real console session after this ships.
--
-- Rollback suite: db/tests/v993_the_reader_is_asked_once_not_once_per_row.sql

begin;

-- =============================================================================================
-- 0 · The live policies are what this file believes they are.
-- =============================================================================================
do $v993_assert$
declare
  v_expected text[][] := array[
    array['sales','sales_sa_read','app.is_super_admin()'],
    array['sales','sales_select','app.has_perm(business_id, ''view_sales''::text)'],
    array['sales','sales_branch_visibility','app.can_see_branch(business_id, branch_id)'],
    array['sales','sales_v94_branch_module_select',
          '(app.is_super_admin() OR app.can_module_read_at_v94(business_id, branch_id, ''sales''::text))'],
    array['clients','clients_sa_read','app.is_super_admin()'],
    array['clients','clients_v41_read','app.can_module_read(business_id, ''clients''::text)']
  ];
  v_row text[];
  v_qual text;
begin
  foreach v_row slice 1 in array v_expected loop
    select qual into v_qual from pg_policies
     where schemaname='public' and tablename=v_row[1] and policyname=v_row[2];
    if v_qual is null then
      raise exception 'v993: policy %.% is missing — the boundary has moved since this file was written',
        v_row[1], v_row[2];
    end if;
    if v_qual is distinct from v_row[3] then
      raise exception 'v993: policy %.% reads % but this file expects % — reconcile before replacing it',
        v_row[1], v_row[2], v_qual, v_row[3];
    end if;
  end loop;
end
$v993_assert$;

-- =============================================================================================
-- 1 · The scope readers. Same three guards, asked once per statement instead of once per row.
-- =============================================================================================
create or replace function app.sales_read_scope_v993()
returns table(business_id uuid, branch_key uuid)
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  /* branch_key is coalesce(branch_id, all-zero uuid) on BOTH sides of the membership test, so a
     row with a NULL branch can be compared with =, which NULL never can. The all-zero uuid is
     not a valid branch id: public.branches is keyed by gen_random_uuid(). */
  with candidate_business as (
    select b.id from public.businesses b where (select app.is_super_admin())
    union
    select distinct staff_row.business_id
      from public.staff staff_row
     where staff_row.user_id = auth.uid()
       and staff_row.active
       and staff_row.access_state = 'approved'
  ),
  candidate_branch as (
    select cb.id as business_id, branch.id as branch_id
      from candidate_business cb
      left join public.branches branch on branch.business_id = cb.id
    union
    select cb.id, null::uuid from candidate_business cb
  )
  select distinct cbr.business_id,
         coalesce(cbr.branch_id, '00000000-0000-0000-0000-000000000000'::uuid)
    from candidate_branch cbr
   where ((select app.is_super_admin()) or app.has_perm(cbr.business_id, 'view_sales'))
     and app.can_see_branch(cbr.business_id, cbr.branch_id)
     and ((select app.is_super_admin())
          or app.can_module_read_at_v94(cbr.business_id, cbr.branch_id, 'sales'))
$function$;
revoke all on function app.sales_read_scope_v993() from public, anon;
grant execute on function app.sales_read_scope_v993() to authenticated;

create or replace function app.client_read_scope_v993()
returns table(business_id uuid)
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  with candidate_business as (
    select b.id from public.businesses b where (select app.is_super_admin())
    union
    select distinct staff_row.business_id
      from public.staff staff_row
     where staff_row.user_id = auth.uid()
       and staff_row.active
       and staff_row.access_state = 'approved'
  )
  select cb.id
    from candidate_business cb
   where (select app.is_super_admin())
      or app.can_module_read(cb.id, 'clients')
$function$;
revoke all on function app.client_read_scope_v993() from public, anon;
grant execute on function app.client_read_scope_v993() to authenticated;

-- =============================================================================================
-- 2 · One policy per table, asking the scope reader.
-- =============================================================================================
drop policy if exists sales_sa_read on public.sales;
drop policy if exists sales_branch_visibility on public.sales;
drop policy if exists sales_v94_branch_module_select on public.sales;

alter policy sales_select on public.sales using (
  case
    when (sales.business_id,
          coalesce(sales.branch_id, '00000000-0000-0000-0000-000000000000'::uuid))
         in (select scope.business_id, scope.branch_key
               from app.sales_read_scope_v993() scope)
      then true
    when sales.branch_id is not null
         and not exists (select 1 from public.branches branch
                          where branch.id = sales.branch_id
                            and branch.business_id = sales.business_id)
      /* The row's branch does not belong to its business, so the enumeration above could not
         represent it. Answer with the pre-v993 predicate, verbatim. */
      then ( ((select app.is_super_admin())
              or app.has_perm(sales.business_id, 'view_sales'))
             and app.can_see_branch(sales.business_id, sales.branch_id)
             and ((select app.is_super_admin())
                  or app.can_module_read_at_v94(sales.business_id, sales.branch_id, 'sales')) )
    else false
  end
);

drop policy if exists clients_sa_read on public.clients;

alter policy clients_v41_read on public.clients using (
  clients.business_id in (select scope.business_id from app.client_read_scope_v993() scope)
);

-- =============================================================================================
-- 3 · The post-condition: one SELECT policy per table, and no per-row guard call left in it.
-- =============================================================================================
do $v993_post$
declare
  v_count integer;
  v_qual text;
begin
  select count(*) into v_count from pg_policies
   where schemaname='public' and tablename='sales' and cmd='SELECT';
  if v_count <> 1 then
    raise exception 'v993: expected exactly 1 SELECT policy on public.sales, found %', v_count;
  end if;
  select count(*) into v_count from pg_policies
   where schemaname='public' and tablename='clients' and cmd='SELECT';
  if v_count <> 1 then
    raise exception 'v993: expected exactly 1 SELECT policy on public.clients, found %', v_count;
  end if;

  select qual into v_qual from pg_policies
   where schemaname='public' and tablename='clients' and policyname='clients_v41_read';
  if position('client_read_scope_v993' in v_qual) = 0 then
    raise exception 'v993: clients_v41_read does not ask the scope reader';
  end if;
  if position('can_module_read' in v_qual) > 0 then
    raise exception 'v993: clients_v41_read still calls a guard per row';
  end if;
end
$v993_post$;

commit;
