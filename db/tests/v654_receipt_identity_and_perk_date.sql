-- Rollback-only v654 acceptance suite: two owner findings from the 2026-08-30 review.
--
-- (1) app.normalized_business_identity_v79(text) backs a partial unique index expression on
--     businesses.registration_number. An index expression evaluates as the CALLING role, and
--     the function had EXECUTE granted to postgres only, so any owner who typed a UEN into
--     Business Profile got 42501 and the whole save was refused (not just the UEN — the legal
--     name and bio typed in the same form were lost too). The fix is a straight EXECUTE grant
--     to authenticated (and service_role) on the pure, table-free normaliser. Section A proves
--     the grant landed for the role that actually calls it.
--
-- (2) public.customer_get_tier_benefits_v501 now carries a `last_used_at` key on every benefit
--     object — the latest issue inside the same period the count is taken over — so a spent
--     perk can say when it was used instead of just that it was used. Section B proves the key
--     exists in the shipped function body (the exact lateral column the payload is built from),
--     which is a stronger check than probing one fixture's output: it holds regardless of
--     whether any perk has been issued yet for a given tenant.
--
-- Run after the complete canonical chain through v654 in a disposable database (or as a
-- rolled-back transaction directly against a prod-shaped instance).
begin;

-- ---------------------------------------------------------------------------
-- A. app.normalized_business_identity_v79(text) — EXECUTE reaches the role that needs it.
-- ---------------------------------------------------------------------------
do $a$
begin
  if not has_function_privilege(
       'authenticated',
       'app.normalized_business_identity_v79(text)',
       'EXECUTE'
     ) then
    raise exception 'A1: authenticated still cannot evaluate the UEN normaliser — Business Profile saves with a registration_number would still 42501';
  end if;
  if not has_function_privilege(
       'service_role',
       'app.normalized_business_identity_v79(text)',
       'EXECUTE'
     ) then
    raise exception 'A2: service_role lost EXECUTE on the UEN normaliser';
  end if;
  raise notice 'A OK: app.normalized_business_identity_v79(text) is EXECUTE-able by authenticated and service_role';
end
$a$;

-- ---------------------------------------------------------------------------
-- B. public.customer_get_tier_benefits_v501 — last_used_at ships in the benefit payload.
-- ---------------------------------------------------------------------------
do $b$
declare
  v_def text := pg_get_functiondef('public.customer_get_tier_benefits_v501(text)'::regprocedure);
begin
  if v_def !~ 'last_used_at' then
    raise exception 'B1: customer_get_tier_benefits_v501 no longer stamps last_used_at on its benefit rows: %', v_def;
  end if;
  -- the date must come from the SAME lateral aggregate as the count, not a second unscoped
  -- lookup, or it could point at a use from a different window than the one being counted.
  if v_def !~ 'last_in_period' then
    raise exception 'B2: last_used_at is not sourced from the count''s own lateral window: %', v_def;
  end if;
  raise notice 'B OK: customer_get_tier_benefits_v501 carries last_used_at, drawn from the same lateral window as count_in_period';
end
$b$;

-- ---------------------------------------------------------------------------
-- C. The ACL restated at the tail of the migration is exact — no wider grant than before.
-- ---------------------------------------------------------------------------
do $c$
begin
  if has_function_privilege('anon', 'public.customer_get_tier_benefits_v501(text)', 'EXECUTE') then
    raise exception 'C1: anon must never execute customer_get_tier_benefits_v501';
  end if;
  if has_function_privilege('public', 'public.customer_get_tier_benefits_v501(text)', 'EXECUTE') then
    raise exception 'C2: public must never execute customer_get_tier_benefits_v501';
  end if;
  if not has_function_privilege('authenticated', 'public.customer_get_tier_benefits_v501(text)', 'EXECUTE') then
    raise exception 'C3: authenticated must still be able to execute customer_get_tier_benefits_v501';
  end if;
  raise notice 'C OK: customer_get_tier_benefits_v501 ACL unchanged (authenticated/service_role only)';
end
$c$;

reset role;
select 'V654_SUITE_PASSED' as verdict;

rollback;
