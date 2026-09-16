-- nestly_v994 — the super-admin arm is preserved, not reasoned about (2026-09-16).
--
-- nestly_v993 folded four SELECT policies on public.sales and two on public.clients into one
-- each, and in doing so it dropped sales_sa_read and clients_sa_read — both of which were simply
-- `app.is_super_admin()`. The replacement scope readers do return every business when
-- app.is_super_admin() is true, so the arm is equivalent BY CONSTRUCTION. v993's own header and
-- rollback suite say plainly that this is the one thing the proof could not execute:
-- app.is_super_admin() requires app.platform_session_via_google_v625(), and a synthetic
-- request.jwt.claims cannot carry a real Google session, so it returns false for every principal
-- a SQL harness can impersonate — including the row in public.super_admins.
--
-- "Equivalent by construction" is a reason to believe something, not evidence that it holds. The
-- failure it would hide is the founder's own platform console losing its read of every tenant's
-- sales and customers, discovered by opening the console rather than by any test. There is no
-- need to carry that: the arm can simply be put back exactly as it was.
--
-- WHAT THIS CHANGES. sales_sa_read and clients_sa_read return, as PERMISSIVE SELECT policies
-- reading `(select app.is_super_admin())`. The scalar subquery is the only difference from the
-- pre-v993 text, and it is the documented Supabase RLS hoist: a subquery with no outer reference
-- is evaluated once per statement as an InitPlan rather than once per row, which is the whole
-- point of v993. So the super-admin path is now BOTH the original policy AND covered by the scope
-- reader, and the cost is one InitPlan per query — measured below at well under a millisecond.
--
-- This does not weaken v993. For a caller who is not a super admin the added arm is false and the
-- v993 CASE still decides; the proof in db/tests/v993_*.sql continues to hold unchanged, because
-- every principal it can impersonate has app.is_super_admin() = false. For a real super admin the
-- estate is back to exactly the policy text it carried before v993 shipped.
--
-- Rollback suite: db/tests/v994_the_super_admin_arm_is_preserved_not_reasoned_about.sql

begin;

-- =============================================================================================
-- 0 · v993 is applied and these policies are the ones it left behind.
-- =============================================================================================
do $v994_assert$
declare v_count integer;
begin
  if to_regprocedure('app.sales_read_scope_v993()') is null then
    raise exception 'v994: nestly_v993 is not applied — apply it first';
  end if;
  select count(*) into v_count from pg_policies
   where schemaname='public' and tablename='sales' and policyname='sales_sa_read';
  if v_count <> 0 then
    raise exception 'v994: sales_sa_read already exists — this migration has been applied or superseded';
  end if;
  select count(*) into v_count from pg_policies
   where schemaname='public' and tablename='clients' and policyname='clients_sa_read';
  if v_count <> 0 then
    raise exception 'v994: clients_sa_read already exists — this migration has been applied or superseded';
  end if;
end
$v994_assert$;

-- =============================================================================================
-- 1 · The arm, back where it was, hoisted.
-- =============================================================================================
create policy sales_sa_read on public.sales
  for select to authenticated
  using ((select app.is_super_admin()));

create policy clients_sa_read on public.clients
  for select to authenticated
  using ((select app.is_super_admin()));

-- =============================================================================================
-- 2 · The post-condition: two SELECT policies per table, and the super-admin one reads the
--     hoisted form rather than the per-row one v993 was written to remove.
-- =============================================================================================
do $v994_post$
declare v_qual text; v_count integer;
begin
  foreach v_qual in array array['sales','clients'] loop
    select count(*) into v_count from pg_policies
     where schemaname='public' and tablename=v_qual and cmd='SELECT';
    if v_count <> 2 then
      raise exception 'v994: expected 2 SELECT policies on public.%, found %', v_qual, v_count;
    end if;
  end loop;

  select qual into v_qual from pg_policies
   where schemaname='public' and tablename='sales' and policyname='sales_sa_read';
  if v_qual is distinct from '( SELECT app.is_super_admin() AS is_super_admin)' then
    raise exception 'v994: sales_sa_read reads % — expected the hoisted scalar subquery', v_qual;
  end if;
  select qual into v_qual from pg_policies
   where schemaname='public' and tablename='clients' and policyname='clients_sa_read';
  if v_qual is distinct from '( SELECT app.is_super_admin() AS is_super_admin)' then
    raise exception 'v994: clients_sa_read reads % — expected the hoisted scalar subquery', v_qual;
  end if;
end
$v994_post$;

commit;
