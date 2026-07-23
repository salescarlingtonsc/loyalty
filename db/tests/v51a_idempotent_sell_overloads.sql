-- Rollback-only v51a suite: server-idempotent sell_package / enroll_membership_v41 overloads.
-- Run after the complete canonical chain (including v54) in a disposable rehearsal DB.
--
-- NOTE (v54 supersession): section 3 below originally asserted that the zero-key /3
-- overloads were "untouched and still create rows". v54 (F2 write-hardening) EXECUTE-revoked
-- both /3 overloads from every browser principal, so that legacy-unaffected guarantee no
-- longer holds. Section 3 is inverted accordingly: an authenticated /3 call now raises 42501,
-- while the idempotent /4 overloads still succeed (proving the definer wrappers' internal
-- delegation to /3, as the function owner, is unaffected by the browser revoke).
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end $$;

create or replace function pg_temp.as_anon() returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role anon';
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
end $$;

create or replace function pg_temp.assert_true(p_ok boolean, p_message text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'ASSERTION FAILED: %', p_message; end if;
end $$;

create or replace function pg_temp.assert_eq(p_actual anyelement, p_expected anyelement, p_message text)
returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'ASSERTION FAILED: % (actual %, expected %)', p_message, p_actual, p_expected;
  end if;
end $$;

create or replace function pg_temp.expect_state(p_sql text, p_label text, p_state text)
returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception '% unexpectedly succeeded', p_label;
exception when others then
  if sqlstate <> p_state then
    raise exception '% failed with %, expected %: %', p_label, sqlstate, p_state, sqlerrm;
  end if;
end $$;

grant execute on function pg_temp.as_user(uuid) to public;
grant execute on function pg_temp.as_anon() to public;
grant execute on function pg_temp.assert_true(boolean, text) to public;
grant execute on function pg_temp.assert_eq(anyelement, anyelement, text) to public;
grant execute on function pg_temp.expect_state(text, text, text) to public;

do $v51a$
declare
  v_biz_a uuid; v_owner_a uuid; v_client_a uuid;
  v_client_m uuid; v_client_m2 uuid;
  v_pkg uuid; v_pkg2 uuid; v_mplan uuid;
  v_key1 uuid := gen_random_uuid(); v_key2 uuid := gen_random_uuid();
  v_r1 json; v_r2 json; v_m1 json; v_m2 json; v_r3 json;
  v_pkg_sales_before int; v_pkg_count int; v_ms_count int;
begin
  reset role;
  select b.id, s.user_id into v_biz_a, v_owner_a
    from public.businesses b
    join public.staff s on s.business_id = b.id and s.role = 'owner' and s.active and s.user_id is not null
   where b.name = 'Pristine chain fixture A';
  select id into v_client_a from public.clients where business_id = v_biz_a and email = 'pristine-a@example.test';
  if v_biz_a is null or v_client_a is null then raise exception 'v51a suite requires pristine tenant A'; end if;

  -- Fresh clients for membership enrolls (one live membership per client is enforced).
  insert into public.clients(business_id, full_name) values (v_biz_a, 'V51a Member One') returning id into v_client_m;
  insert into public.clients(business_id, full_name) values (v_biz_a, 'V51a Member Two') returning id into v_client_m2;

  -- Package plans (direct seed) and a membership plan (via the real owner RPC).
  insert into public.package_plans(business_id, name, price_cents, sessions, active)
  values (v_biz_a, 'V51a 10-pack', 20000, 10, true) returning id into v_pkg;
  insert into public.package_plans(business_id, name, price_cents, sessions, active)
  values (v_biz_a, 'V51a 5-pack', 10000, 5, true) returning id into v_pkg2;

  perform pg_temp.as_user(v_owner_a);
  v_mplan := (public.save_membership_plan(v_biz_a, null, 'V51a Gold', 5000, 'monthly', 500, 0, true)::jsonb->>'plan_id')::uuid;

  -- ========================================================================
  -- 1. sell_package(4-arg) is replay-safe: same key => same package, no dupes.
  -- ========================================================================
  reset role;
  select count(*)::int into v_pkg_sales_before from public.sales where business_id = v_biz_a and kind = 'package';
  perform pg_temp.as_user(v_owner_a);
  v_r1 := public.sell_package(v_biz_a, v_client_a, v_pkg, v_key1);
  perform pg_temp.assert_eq((v_r1->>'remaining')::int, 10, 'package sold with 10 sessions');
  v_r2 := public.sell_package(v_biz_a, v_client_a, v_pkg, v_key1);
  perform pg_temp.assert_eq(v_r2->>'id', v_r1->>'id', 'replay returns the same client_packages row');

  reset role;
  select count(*)::int into v_pkg_count from public.client_packages
   where business_id = v_biz_a and client_id = v_client_a and plan_id = v_pkg;
  perform pg_temp.assert_eq(v_pkg_count, 1, 'replay created no second client_packages row');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.sales where business_id = v_biz_a and kind = 'package'),
    v_pkg_sales_before + 1, 'replay booked no second package sale');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.sale_intent_operations
      where business_id = v_biz_a and idempotency_key = v_key1 and operation_type = 'package_sale'),
    1, 'one package idempotency ledger row');

  -- ========================================================================
  -- 2. enroll_membership_v41(4-arg) is replay-safe.
  -- ========================================================================
  perform pg_temp.as_user(v_owner_a);
  v_m1 := public.enroll_membership_v41(v_biz_a, v_client_m, v_mplan, v_key2);
  perform pg_temp.assert_eq(v_m1->>'status', 'active', 'membership enrolled active');
  v_m2 := public.enroll_membership_v41(v_biz_a, v_client_m, v_mplan, v_key2);
  perform pg_temp.assert_eq(v_m2->>'id', v_m1->>'id', 'replay returns the same membership');

  reset role;
  select count(*)::int into v_ms_count from public.memberships
   where business_id = v_biz_a and client_id = v_client_m;
  perform pg_temp.assert_eq(v_ms_count, 1, 'replay created no second membership');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.sales where business_id = v_biz_a and kind = 'membership'
       and client_id = v_client_m),
    1, 'replay booked no second membership sale');

  -- ========================================================================
  -- 3. v54 SUPERSEDES the "legacy /3 unaffected" guarantee: the zero-key /3 overloads
  --    are now EXECUTE-revoked for authenticated principals. The idempotent /4 overloads
  --    still create rows (the definer wrappers delegate to /3 as the function owner).
  -- ========================================================================
  perform pg_temp.as_user(v_owner_a);
  perform pg_temp.expect_state(
    format('select public.sell_package(%L::uuid,%L::uuid,%L::uuid)', v_biz_a, v_client_a, v_pkg),
    '3-arg sell_package now execute-revoked for authenticated', '42501');
  perform pg_temp.expect_state(
    format('select public.enroll_membership_v41(%L::uuid,%L::uuid,%L::uuid)', v_biz_a, v_client_m2, v_mplan),
    '3-arg enroll_membership_v41 now execute-revoked for authenticated', '42501');
  -- The /4 overloads still create rows despite /3 being revoked (definer delegation).
  v_r3 := public.sell_package(v_biz_a, v_client_a, v_pkg, gen_random_uuid());  -- 4-arg
  perform pg_temp.assert_eq((v_r3->>'remaining')::int, 10, '4-arg sell_package still works with /3 revoked');
  perform public.enroll_membership_v41(v_biz_a, v_client_m2, v_mplan, gen_random_uuid());  -- 4-arg
  reset role;
  perform pg_temp.assert_eq(
    (select count(*)::int from public.client_packages
      where business_id = v_biz_a and client_id = v_client_a and plan_id = v_pkg),
    2, '4-arg sell_package added a second package (client already had one from section 1)');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.memberships where business_id = v_biz_a and client_id = v_client_m2),
    1, '4-arg enroll_membership_v41 enrolled client m2');

  -- ========================================================================
  -- 4. Reusing a key for a different immutable request is rejected.
  -- ========================================================================
  perform pg_temp.as_user(v_owner_a);
  perform pg_temp.expect_state(
    format('select public.sell_package(%L::uuid,%L::uuid,%L::uuid,%L::uuid)',
      v_biz_a, v_client_a, v_pkg2, v_key1),
    'package key reuse with a different plan rejected', '23505');
  perform pg_temp.expect_state(
    format('select public.enroll_membership_v41(%L::uuid,%L::uuid,%L::uuid,%L::uuid)',
      v_biz_a, v_client_m, v_mplan, v_key1),
    'membership reuse of a package key rejected', '23505');

  -- ========================================================================
  -- 5. Client-tenant and anon guards on the overloads.
  -- ========================================================================
  perform pg_temp.expect_state(
    format('select public.sell_package(%L::uuid,%L::uuid,%L::uuid,%L::uuid)',
      v_biz_a, gen_random_uuid(), v_pkg, gen_random_uuid()),
    'package sale for a non-member client rejected', '22023');

  perform pg_temp.as_anon();
  perform pg_temp.expect_state(
    format('select public.sell_package(%L::uuid,%L::uuid,%L::uuid,%L::uuid)',
      v_biz_a, v_client_a, v_pkg, gen_random_uuid()),
    'anon package sale rejected', '42501');
  perform pg_temp.expect_state(
    format('select public.enroll_membership_v41(%L::uuid,%L::uuid,%L::uuid,%L::uuid)',
      v_biz_a, v_client_m, v_mplan, gen_random_uuid()),
    'anon membership enroll rejected', '42501');
end $v51a$;

rollback;
