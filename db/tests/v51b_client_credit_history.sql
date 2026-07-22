-- Rollback-only v51b suite: staff_get_client_credit_history authorization + shape.
-- Run after the complete canonical chain through v51b in a disposable rehearsal DB.
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

do $v51b$
declare
  v_biz_a uuid; v_owner_a uuid; v_client_a uuid;
  v_biz_b uuid; v_client_b uuid;
  v_manager uuid := gen_random_uuid(); v_frontdesk uuid := gen_random_uuid();
  v_code1 text; v_code2 text; v_res jsonb;
begin
  reset role;
  select b.id, s.user_id into v_biz_a, v_owner_a
    from public.businesses b
    join public.staff s on s.business_id = b.id and s.role = 'owner' and s.active and s.user_id is not null
   where b.name = 'Pristine chain fixture A';
  select b.id into v_biz_b
    from public.businesses b where b.name = 'Pristine chain fixture B';
  select id into v_client_a from public.clients where business_id = v_biz_a and email = 'pristine-a@example.test';
  select id into v_client_b from public.clients where business_id = v_biz_b and email = 'pristine-b@example.test';
  if v_biz_a is null or v_biz_b is null or v_client_a is null or v_client_b is null then
    raise exception 'v51b suite requires the pristine A/B fixture';
  end if;

  -- A manager (view_finance) and a frontdesk (create_sales/view_sales only) on tenant A.
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    ('00000000-0000-0000-0000-000000000000', v_manager, 'authenticated', 'authenticated',
     'v51b-mgr-'||substr(v_manager::text,1,8)||'@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_frontdesk, 'authenticated', 'authenticated',
     'v51b-fd-'||substr(v_frontdesk::text,1,8)||'@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, full_name, active)
  values (v_biz_a, v_manager, 'manager', 'V51b Manager', true),
         (v_biz_a, v_frontdesk, 'frontdesk', 'V51b Frontdesk', true);

  -- Seed BOTH data sources for client A via real routes: two gift cards purchased by A
  -- (gift-card events) and two redemptions loading store credit (credit_ledger movements).
  perform pg_temp.as_user(v_owner_a);
  v_code1 := public.issue_gift_card(v_biz_a, 3000, v_client_a, null, gen_random_uuid())::jsonb->>'code';
  v_code2 := public.issue_gift_card(v_biz_a, 4000, v_client_a, null, gen_random_uuid())::jsonb->>'code';
  perform public.redeem_gift_card_v41(v_biz_a, v_code1, v_client_a);
  perform public.redeem_gift_card_v41(v_biz_a, v_code2, v_client_a);

  -- ========================================================================
  -- 1. Owner (view_finance + clients): both sources present, shape correct.
  -- ========================================================================
  v_res := public.staff_get_client_credit_history(v_biz_a, v_client_a);
  perform pg_temp.assert_eq(v_res->>'status', 'ok', 'owner read returns ok');
  perform pg_temp.assert_eq((v_res->>'client_id')::uuid, v_client_a, 'echoes the requested client');
  perform pg_temp.assert_eq((v_res->>'credit_entry_count')::int, 2, 'both credit-ledger movements present');
  perform pg_temp.assert_eq((v_res->>'gift_card_count')::int, 2, 'both gift-card events present');
  perform pg_temp.assert_true(
    v_res->'gift_cards'->0->>'code_suffix' is not null
      and length(v_res->'gift_cards'->0->>'code_suffix') = 4,
    'gift-card code is bearer-safe (4-char suffix only)');
  perform pg_temp.assert_true(
    not ((v_res->'gift_cards'->0) ? 'code'),
    'no full gift-card code is exposed');

  -- ========================================================================
  -- 2. Bounded output honours p_limit.
  -- ========================================================================
  v_res := public.staff_get_client_credit_history(v_biz_a, v_client_a, 1);
  perform pg_temp.assert_eq((v_res->>'limit')::int, 1, 'limit clamped/echoed');
  perform pg_temp.assert_eq((v_res->>'credit_entry_count')::int, 1, 'credit output bounded to the limit');
  perform pg_temp.assert_eq((v_res->>'gift_card_count')::int, 1, 'gift-card output bounded to the limit');

  -- ========================================================================
  -- 3. Manager (view_finance) is allowed.
  -- ========================================================================
  perform pg_temp.as_user(v_manager);
  v_res := public.staff_get_client_credit_history(v_biz_a, v_client_a);
  perform pg_temp.assert_eq(v_res->>'status', 'ok', 'manager with view_finance is allowed');

  -- ========================================================================
  -- 4. Frontdesk (view_sales but NOT view_finance) is denied — the gate is view_finance.
  -- ========================================================================
  perform pg_temp.as_user(v_frontdesk);
  perform pg_temp.expect_state(
    format('select public.staff_get_client_credit_history(%L::uuid,%L::uuid)', v_biz_a, v_client_a),
    'frontdesk denied (no view_finance)', '42501');

  -- ========================================================================
  -- 5. Cross-tenant and anonymous denials; unknown customer denial.
  -- ========================================================================
  perform pg_temp.as_user(v_owner_a);
  perform pg_temp.expect_state(
    format('select public.staff_get_client_credit_history(%L::uuid,%L::uuid)', v_biz_b, v_client_a),
    'owner A denied on tenant B', '42501');
  perform pg_temp.expect_state(
    format('select public.staff_get_client_credit_history(%L::uuid,%L::uuid)', v_biz_a, v_client_b),
    'client from another business is not found', '42501');

  perform pg_temp.as_anon();
  perform pg_temp.expect_state(
    format('select public.staff_get_client_credit_history(%L::uuid,%L::uuid)', v_biz_a, v_client_a),
    'anon denied', '42501');
end $v51b$;

rollback;
