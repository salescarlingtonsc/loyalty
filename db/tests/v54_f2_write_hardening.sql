-- Rollback-only v54 suite: F2 value-write hardening.
-- Run after the complete canonical chain through v54 in a disposable rehearsal DB.
--
-- Covers the owner's A5 matrix at the DB level with EXACT final counts asserted
-- (expenses, stock_batches, sales, client_packages, memberships, membership
-- credit_ledger rows, audit_log, f2_write_operations): normal success x4, exact
-- replay x4, changed-payload conflict x4 (expense + receiving directly; package +
-- membership via the v51a /4 semantics), malformed payloads, unauthorized role,
-- wrong branch, cross-tenant product + cross-tenant business ids, inactive staff,
-- the /3 overloads now 42501 for authenticated principals while /4 still work,
-- direct table INSERT now denied, and both internal SECURITY DEFINER writers still
-- functioning after the grant revoke (run_expense_recurrences materializer; FEFO
-- deduct draining a batch received through receive_stock).
--
-- CONCURRENCY (stated honestly): a single-connection rollback suite cannot exercise
-- a true two-transaction race. The idempotency guarantee rests on (1) the
-- transaction-scoped advisory lock on (business, idempotency_key) inside each RPC
-- and (2) the UNIQUE(business_id, idempotency_key) constraint on
-- f2_write_operations — the same structure the live v51a concurrency harness
-- (db/tests/*_concurrency.sh) proves under real parallelism. This suite asserts that
-- structure directly (a duplicate keyed op-ledger insert is rejected with 23505); a
-- dedicated db/tests/v54_f2_write_hardening_concurrency.sh is an OPTIONAL follow-up.
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

do $v54$
declare
  v_biz_a uuid; v_owner_a uuid; v_client_a uuid; v_branch_a uuid;
  v_biz_b uuid; v_owner_b uuid; v_branch_b uuid;
  v_fd_user uuid := gen_random_uuid();     -- frontdesk: no view_finance
  v_inv_user uuid := gen_random_uuid();    -- staff scoped to 'clients' only: no inventory
  v_inact_user uuid := gen_random_uuid();  -- manager but inactive
  v_prod_a uuid; v_prod_inactive uuid; v_prod_b uuid; v_prod_fefo uuid;
  v_pkg uuid; v_mplan uuid; v_client_m uuid;
  v_sgt_today date := (timezone('Asia/Singapore', now()))::date;

  v_key_e1 uuid := gen_random_uuid();
  v_key_s1 uuid := gen_random_uuid();
  v_key_p1 uuid := gen_random_uuid();
  v_key_m1 uuid := gen_random_uuid();

  v_re1 jsonb; v_re2 jsonb; v_rs1 jsonb; v_rs2 jsonb; v_rs_fefo jsonb;
  v_rp1 json; v_rp2 json; v_rm1 json; v_rm2 json;
  v_expense_id uuid; v_batch_id uuid; v_fefo_batch uuid; v_recur uuid;

  v_exp_before int; v_ops_before int; v_audit_before int;
  v_sb_before int; v_exp_recur_before int; v_exp_recur_after int;
  v_n int; v_qty int; v_pay_base int;
begin
  -- =========================================================================
  -- 0. Seed the two pristine tenants plus role/module/product/plan fixtures.
  -- =========================================================================
  reset role;
  select b.id, s.user_id into v_biz_a, v_owner_a
    from public.businesses b
    join public.staff s on s.business_id = b.id and s.role = 'owner' and s.active and s.user_id is not null
   where b.name = 'Pristine chain fixture A';
  select b.id, s.user_id into v_biz_b, v_owner_b
    from public.businesses b
    join public.staff s on s.business_id = b.id and s.role = 'owner' and s.active and s.user_id is not null
   where b.name = 'Pristine chain fixture B';
  select id into v_client_a from public.clients where business_id = v_biz_a and email = 'pristine-a@example.test';
  select id into v_branch_a from public.branches where business_id = v_biz_a and is_default;
  select id into v_branch_b from public.branches where business_id = v_biz_b and is_default;
  if v_biz_a is null or v_biz_b is null or v_client_a is null
     or v_branch_a is null or v_branch_b is null then
    raise exception 'v54 suite requires both pristine tenants and their default branches';
  end if;

  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values
    ('00000000-0000-0000-0000-000000000000', v_fd_user, 'authenticated', 'authenticated',
     'v54-fd-'||v_fd_user::text||'@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_inv_user, 'authenticated', 'authenticated',
     'v54-inv-'||v_inv_user::text||'@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_inact_user, 'authenticated', 'authenticated',
     'v54-inact-'||v_inact_user::text||'@example.test', '', now(), now(), now());

  insert into public.staff(business_id, user_id, role, active, full_name, modules) values
    (v_biz_a, v_fd_user, 'frontdesk', true, 'V54 Frontdesk', null),
    (v_biz_a, v_inv_user, 'staff', true, 'V54 Clients-only', array['clients']),
    (v_biz_a, v_inact_user, 'manager', false, 'V54 Inactive', null);

  insert into public.products(business_id, name, active) values (v_biz_a, 'V54 Widget', true) returning id into v_prod_a;
  insert into public.products(business_id, name, active) values (v_biz_a, 'V54 Retired', false) returning id into v_prod_inactive;
  insert into public.products(business_id, name, active) values (v_biz_a, 'V54 FEFO', true) returning id into v_prod_fefo;
  insert into public.products(business_id, name, active) values (v_biz_b, 'V54 B Widget', true) returning id into v_prod_b;

  insert into public.package_plans(business_id, name, price_cents, sessions, active)
  values (v_biz_a, 'V54 10-pack', 20000, 10, true) returning id into v_pkg;
  insert into public.clients(business_id, full_name) values (v_biz_a, 'V54 Member') returning id into v_client_m;

  perform pg_temp.as_user(v_owner_a);
  v_mplan := (public.save_membership_plan(v_biz_a, null, 'V54 Gold', 5000, 'monthly', 500, 0, true)::jsonb->>'plan_id')::uuid;

  -- v54 F2-1: baseline payments count. None of the F2 writers (expense/receiving) nor the
  -- package/membership /4 paths touch public.payments (tender is a separate, UI-unwired
  -- surface owned by record_payment/record_credit_tender), so this must hold flat throughout.
  reset role;
  select count(*)::int into v_pay_base from public.payments where business_id = v_biz_a;

  -- =========================================================================
  -- 1. create_expense success (owner). Exact counts: +1 expense, +1 op ledger,
  --    +2 audit (generic INSERT trigger row + explicit semantic row). NULL date
  --    falls through to the SGT column default. created_by = actor.
  -- =========================================================================
  reset role;
  select count(*) into v_exp_before from public.expenses where business_id = v_biz_a;
  select count(*) into v_ops_before from public.f2_write_operations where business_id = v_biz_a;
  select count(*) into v_audit_before from public.audit_log;

  perform pg_temp.as_user(v_owner_a);
  v_re1 := public.create_expense(v_biz_a, v_branch_a, 'Rent', 150000, null, 'Landlord', 'Monthly rent', null, v_key_e1);
  perform pg_temp.assert_eq(v_re1->>'status', 'ok', 'create_expense returns ok');
  perform pg_temp.assert_eq((v_re1->>'replayed')::boolean, false, 'first create is not a replay');
  v_expense_id := (v_re1->>'expense_id')::uuid;

  reset role;
  perform pg_temp.assert_eq(
    (select count(*)::int from public.expenses where business_id = v_biz_a), v_exp_before + 1,
    'exactly one expense row created');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.f2_write_operations
      where business_id = v_biz_a and idempotency_key = v_key_e1 and operation_type = 'expense_create'),
    1, 'exactly one expense op-ledger row');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.audit_log), v_audit_before + 2,
    'expense create writes exactly two audit rows (trigger INSERT + semantic)');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.audit_log where entity_id = v_expense_id and action = 'expense_create'),
    1, 'exactly one semantic expense_create audit row');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.audit_log where entity_id = v_expense_id), 2,
    'the expense row has exactly two audit rows');
  perform pg_temp.assert_eq(
    (select created_by from public.expenses where id = v_expense_id), v_owner_a,
    'created_by is the acting owner');
  perform pg_temp.assert_eq(
    (select occurred_on from public.expenses where id = v_expense_id), v_sgt_today,
    'NULL occurred_on defaulted to the SGT date');

  -- =========================================================================
  -- 2. create_expense exact replay: same key + same payload -> original result,
  --    ZERO new rows (no expense, no op, no audit).
  -- =========================================================================
  reset role;
  select count(*) into v_exp_before from public.expenses where business_id = v_biz_a;
  select count(*) into v_ops_before from public.f2_write_operations where business_id = v_biz_a;
  select count(*) into v_audit_before from public.audit_log;

  perform pg_temp.as_user(v_owner_a);
  v_re2 := public.create_expense(v_biz_a, v_branch_a, 'Rent', 150000, null, 'Landlord', 'Monthly rent', null, v_key_e1);
  perform pg_temp.assert_eq(v_re2->>'status', 'duplicate_ignored', 'replay is duplicate_ignored');
  perform pg_temp.assert_eq((v_re2->>'replayed')::boolean, true, 'replay flags replayed=true');
  perform pg_temp.assert_eq(v_re2->>'expense_id', v_re1->>'expense_id', 'replay returns the original expense id');

  reset role;
  perform pg_temp.assert_eq((select count(*)::int from public.expenses where business_id = v_biz_a), v_exp_before,
    'replay created no second expense');
  perform pg_temp.assert_eq((select count(*)::int from public.f2_write_operations where business_id = v_biz_a), v_ops_before,
    'replay created no second op-ledger row');
  perform pg_temp.assert_eq((select count(*)::int from public.audit_log), v_audit_before,
    'replay wrote no audit rows');

  -- =========================================================================
  -- 3. create_expense conflict: same key, different payload -> 23505, ZERO new rows.
  -- =========================================================================
  reset role;
  select count(*) into v_exp_before from public.expenses where business_id = v_biz_a;
  perform pg_temp.as_user(v_owner_a);
  perform pg_temp.expect_state(
    format('select public.create_expense(%L::uuid,%L::uuid,%L,999999,null,null,null,null,%L::uuid)',
      v_biz_a, v_branch_a, 'Rent', v_key_e1),
    'expense key reuse with a different amount rejected', '23505');
  reset role;
  perform pg_temp.assert_eq((select count(*)::int from public.expenses where business_id = v_biz_a), v_exp_before,
    'conflict created no expense');

  -- =========================================================================
  -- 4. receive_stock success (owner). Exact counts: +1 batch, +1 op, +1 audit
  --    (no stock_batches audit trigger exists).
  -- =========================================================================
  reset role;
  select count(*) into v_sb_before from public.stock_batches where product_id = v_prod_a;
  select count(*) into v_audit_before from public.audit_log;

  perform pg_temp.as_user(v_owner_a);
  v_rs1 := public.receive_stock(v_biz_a, v_prod_a, 5, null, null, v_key_s1);
  perform pg_temp.assert_eq(v_rs1->>'status', 'ok', 'receive_stock returns ok');
  perform pg_temp.assert_eq((v_rs1->>'replayed')::boolean, false, 'first receive is not a replay');
  v_batch_id := (v_rs1->>'stock_batch_id')::uuid;

  reset role;
  perform pg_temp.assert_eq((select count(*)::int from public.stock_batches where product_id = v_prod_a), v_sb_before + 1,
    'exactly one stock batch created');
  perform pg_temp.assert_eq((select qty from public.stock_batches where id = v_batch_id), 5, 'batch qty stored');
  perform pg_temp.assert_eq((select received_on from public.stock_batches where id = v_batch_id), v_sgt_today,
    'NULL received_on defaulted to the SGT date');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.f2_write_operations
      where business_id = v_biz_a and idempotency_key = v_key_s1 and operation_type = 'stock_receive'),
    1, 'exactly one stock op-ledger row');
  perform pg_temp.assert_eq((select count(*)::int from public.audit_log), v_audit_before + 1,
    'receive_stock writes exactly one audit row (no table trigger)');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.audit_log where entity_id = v_batch_id and action = 'stock_receive'),
    1, 'exactly one semantic stock_receive audit row');

  -- v54 F2-1: expense + receiving (success/replay/conflict) never touch payments (+0).
  perform pg_temp.assert_eq(
    (select count(*)::int from public.payments where business_id = v_biz_a), v_pay_base,
    'create_expense and receive_stock created zero payments rows');

  -- =========================================================================
  -- 5. receive_stock exact replay -> duplicate_ignored, same batch id, ZERO new rows.
  -- =========================================================================
  reset role;
  select count(*) into v_sb_before from public.stock_batches where product_id = v_prod_a;
  select count(*) into v_audit_before from public.audit_log;
  perform pg_temp.as_user(v_owner_a);
  v_rs2 := public.receive_stock(v_biz_a, v_prod_a, 5, null, null, v_key_s1);
  perform pg_temp.assert_eq(v_rs2->>'status', 'duplicate_ignored', 'stock replay is duplicate_ignored');
  perform pg_temp.assert_eq(v_rs2->>'stock_batch_id', v_rs1->>'stock_batch_id', 'replay returns the original batch id');
  reset role;
  perform pg_temp.assert_eq((select count(*)::int from public.stock_batches where product_id = v_prod_a), v_sb_before,
    'replay created no second batch');
  perform pg_temp.assert_eq((select count(*)::int from public.audit_log), v_audit_before,
    'stock replay wrote no audit rows');

  -- =========================================================================
  -- 6. receive_stock conflict: same key, different qty -> 23505, ZERO new rows.
  -- =========================================================================
  reset role;
  select count(*) into v_sb_before from public.stock_batches where product_id = v_prod_a;
  perform pg_temp.as_user(v_owner_a);
  perform pg_temp.expect_state(
    format('select public.receive_stock(%L::uuid,%L::uuid,99,null,null,%L::uuid)',
      v_biz_a, v_prod_a, v_key_s1),
    'stock key reuse with a different qty rejected', '23505');
  reset role;
  perform pg_temp.assert_eq((select count(*)::int from public.stock_batches where product_id = v_prod_a), v_sb_before,
    'stock conflict created no batch');

  -- =========================================================================
  -- 7. sell_package/4 and enroll_membership_v41/4 success + replay + conflict.
  --    These succeed even though sell_package/3 and enroll_membership_v41/3 are
  --    EXECUTE-revoked from authenticated (section 13): the /4 wrappers are
  --    SECURITY DEFINER and call /3 as the function owner.
  -- =========================================================================
  reset role;
  select count(*) into v_n from public.sales where business_id = v_biz_a and kind = 'package';
  perform pg_temp.as_user(v_owner_a);
  v_rp1 := public.sell_package(v_biz_a, v_client_a, v_pkg, v_key_p1);
  perform pg_temp.assert_eq((v_rp1->>'remaining')::int, 10, 'package sold with 10 sessions (/4 works with /3 revoked)');
  v_rp2 := public.sell_package(v_biz_a, v_client_a, v_pkg, v_key_p1);
  perform pg_temp.assert_eq(v_rp2->>'id', v_rp1->>'id', 'package replay returns the same client_packages row');

  reset role;
  perform pg_temp.assert_eq(
    (select count(*)::int from public.client_packages where business_id = v_biz_a and client_id = v_client_a and plan_id = v_pkg),
    1, 'exactly one client_packages row');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.sales where business_id = v_biz_a and kind = 'package'), v_n + 1,
    'exactly one package sale');

  perform pg_temp.as_user(v_owner_a);
  v_rm1 := public.enroll_membership_v41(v_biz_a, v_client_m, v_mplan, v_key_m1);
  perform pg_temp.assert_eq(v_rm1->>'status', 'active', 'membership enrolled active (/4 works with /3 revoked)');
  v_rm2 := public.enroll_membership_v41(v_biz_a, v_client_m, v_mplan, v_key_m1);
  perform pg_temp.assert_eq(v_rm2->>'id', v_rm1->>'id', 'membership replay returns the same membership');

  reset role;
  perform pg_temp.assert_eq(
    (select count(*)::int from public.memberships where business_id = v_biz_a and client_id = v_client_m), 1,
    'exactly one membership');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.sales where business_id = v_biz_a and kind = 'membership' and client_id = v_client_m), 1,
    'exactly one membership sale');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.credit_ledger
      where business_id = v_biz_a and client_id = v_client_m and entry_type = 'membership_credit'), 1,
    'exactly one membership credit_ledger row');

  -- conflict: reuse each key for a different immutable request (v51a semantics).
  perform pg_temp.as_user(v_owner_a);
  perform pg_temp.expect_state(
    format('select public.sell_package(%L::uuid,%L::uuid,%L::uuid,%L::uuid)',
      v_biz_a, v_client_m, v_pkg, v_key_p1),
    'package key reuse with a different client rejected', '23505');
  perform pg_temp.expect_state(
    format('select public.enroll_membership_v41(%L::uuid,%L::uuid,%L::uuid,%L::uuid)',
      v_biz_a, v_client_a, v_mplan, v_key_m1),
    'membership key reuse with a different client rejected', '23505');
  reset role;
  perform pg_temp.assert_eq(
    (select count(*)::int from public.memberships where business_id = v_biz_a and client_id = v_client_m), 1,
    'membership conflict created no second membership');

  -- v54 F2-1: the package + membership /4 enrolments write sales + client_packages/
  -- memberships + membership credit_ledger, but the exact v51a-semantics payments delta is 0
  -- (enroll_membership/3 and sell_package/3 never insert payments).
  perform pg_temp.assert_eq(
    (select count(*)::int from public.payments where business_id = v_biz_a), v_pay_base,
    'package and membership /4 enrolments created zero payments rows (exact +0 delta)');

  -- =========================================================================
  -- 8. Malformed payloads -> 22023 (owner-authenticated so only validation fires).
  -- =========================================================================
  perform pg_temp.as_user(v_owner_a);
  perform pg_temp.expect_state(
    format('select public.create_expense(%L::uuid,null,%L,100,null,null,null,null,%L::uuid)', v_biz_a, '   ', gen_random_uuid()),
    'blank expense category rejected', '22023');
  perform pg_temp.expect_state(
    format('select public.create_expense(%L::uuid,null,%L,0,null,null,null,null,%L::uuid)', v_biz_a, 'Misc', gen_random_uuid()),
    'zero expense amount rejected', '22023');
  perform pg_temp.expect_state(
    format('select public.create_expense(%L::uuid,null,%L,100000001,null,null,null,null,%L::uuid)', v_biz_a, 'Misc', gen_random_uuid()),
    'over-max expense amount rejected', '22023');
  perform pg_temp.expect_state(
    format('select public.create_expense(%L::uuid,null,%L,100,%L::date,null,null,null,%L::uuid)',
      v_biz_a, 'Misc', (v_sgt_today + 2), gen_random_uuid()),
    'future expense date rejected', '22023');
  perform pg_temp.expect_state(
    format('select public.create_expense(%L::uuid,null,%L,100,%L::date,null,null,null,%L::uuid)',
      v_biz_a, 'Misc', (v_sgt_today - interval '6 years')::date, gen_random_uuid()),
    'ancient expense date rejected', '22023');
  perform pg_temp.expect_state(
    format('select public.receive_stock(%L::uuid,%L::uuid,0,null,null,%L::uuid)', v_biz_a, v_prod_a, gen_random_uuid()),
    'zero receive qty rejected', '22023');
  perform pg_temp.expect_state(
    format('select public.receive_stock(%L::uuid,%L::uuid,1000001,null,null,%L::uuid)', v_biz_a, v_prod_a, gen_random_uuid()),
    'over-max receive qty rejected', '22023');
  perform pg_temp.expect_state(
    format('select public.receive_stock(%L::uuid,%L::uuid,5,%L::date,%L::date,%L::uuid)',
      v_biz_a, v_prod_a, v_sgt_today, v_sgt_today, gen_random_uuid()),
    'expiry not strictly after received rejected', '22023');

  -- =========================================================================
  -- 9. Unauthorized role.
  -- =========================================================================
  perform pg_temp.as_user(v_fd_user);
  perform pg_temp.expect_state(
    format('select public.create_expense(%L::uuid,null,%L,100,null,null,null,null,%L::uuid)', v_biz_a, 'Misc', gen_random_uuid()),
    'frontdesk (no view_finance) denied expense create', '42501');
  perform pg_temp.as_user(v_inv_user);
  perform pg_temp.expect_state(
    format('select public.receive_stock(%L::uuid,%L::uuid,5,null,null,%L::uuid)', v_biz_a, v_prod_a, gen_random_uuid()),
    'clients-only staff denied stock receive (no inventory module)', '42501');

  -- =========================================================================
  -- 10. Wrong branch: a branch that belongs to tenant B -> 22023.
  -- =========================================================================
  perform pg_temp.as_user(v_owner_a);
  perform pg_temp.expect_state(
    format('select public.create_expense(%L::uuid,%L::uuid,%L,100,null,null,null,null,%L::uuid)',
      v_biz_a, v_branch_b, 'Misc', gen_random_uuid()),
    'expense against a cross-tenant branch rejected', '22023');

  -- =========================================================================
  -- 11. Cross-tenant product + cross-tenant business ids + inactive product.
  -- =========================================================================
  perform pg_temp.as_user(v_owner_a);
  perform pg_temp.expect_state(
    format('select public.receive_stock(%L::uuid,%L::uuid,5,null,null,%L::uuid)', v_biz_a, v_prod_b, gen_random_uuid()),
    'receive against a cross-tenant product rejected', '22023');
  perform pg_temp.expect_state(
    format('select public.receive_stock(%L::uuid,%L::uuid,5,null,null,%L::uuid)', v_biz_a, v_prod_inactive, gen_random_uuid()),
    'receive against an inactive product rejected', '22023');
  -- owner_a is not staff of tenant B -> the module-write gate fails first (42501).
  perform pg_temp.expect_state(
    format('select public.create_expense(%L::uuid,null,%L,100,null,null,null,null,%L::uuid)', v_biz_b, 'Misc', gen_random_uuid()),
    'owner A cannot create an expense in tenant B', '42501');
  perform pg_temp.expect_state(
    format('select public.receive_stock(%L::uuid,%L::uuid,5,null,null,%L::uuid)', v_biz_b, v_prod_b, gen_random_uuid()),
    'owner A cannot receive stock in tenant B', '42501');

  -- =========================================================================
  -- 12. Inactive staff -> 42501.
  -- =========================================================================
  perform pg_temp.as_user(v_inact_user);
  perform pg_temp.expect_state(
    format('select public.create_expense(%L::uuid,null,%L,100,null,null,null,null,%L::uuid)', v_biz_a, 'Misc', gen_random_uuid()),
    'inactive staff denied expense create', '42501');
  perform pg_temp.expect_state(
    format('select public.receive_stock(%L::uuid,%L::uuid,5,null,null,%L::uuid)', v_biz_a, v_prod_a, gen_random_uuid()),
    'inactive staff denied stock receive', '42501');

  -- =========================================================================
  -- 13. The non-idempotent /3 overloads are now 42501 for authenticated principals.
  -- =========================================================================
  perform pg_temp.as_user(v_owner_a);
  perform pg_temp.expect_state(
    format('select public.sell_package(%L::uuid,%L::uuid,%L::uuid)', v_biz_a, v_client_a, v_pkg),
    'sell_package/3 execute revoked for authenticated', '42501');
  perform pg_temp.expect_state(
    format('select public.enroll_membership_v41(%L::uuid,%L::uuid,%L::uuid)', v_biz_a, v_client_m, v_mplan),
    'enroll_membership_v41/3 execute revoked for authenticated', '42501');
  perform pg_temp.as_anon();
  perform pg_temp.expect_state(
    format('select public.sell_package(%L::uuid,%L::uuid,%L::uuid)', v_biz_a, v_client_a, v_pkg),
    'sell_package/3 execute revoked for anon', '42501');

  -- =========================================================================
  -- 14. Direct table INSERT to expenses / stock_batches now denied for authenticated.
  -- =========================================================================
  perform pg_temp.as_user(v_owner_a);
  perform pg_temp.expect_state(
    format('insert into public.expenses(business_id,category,amount_cents) values (%L::uuid,%L,100)', v_biz_a, 'Direct'),
    'direct expenses insert denied (write grant revoked)', '42501');
  perform pg_temp.expect_state(
    format('insert into public.stock_batches(product_id,qty) values (%L::uuid,1)', v_prod_a),
    'direct stock_batches insert denied (write grant revoked)', '42501');

  -- SELECT-side behaviour preserved: the owner can still read both tables.
  perform pg_temp.assert_true(
    (select count(*) >= 0 from public.expenses where business_id = v_biz_a),
    'owner can still SELECT expenses');
  perform pg_temp.assert_true(
    (select count(*) >= 0 from public.stock_batches sb join public.products p on p.id = sb.product_id
      where p.business_id = v_biz_a),
    'owner can still SELECT stock_batches');

  -- =========================================================================
  -- 15. Internal SECURITY DEFINER writers still function after the grant revoke.
  -- =========================================================================
  -- 15a. run_expense_recurrences materialiser inserts an expenses row (runs as owner).
  reset role;
  insert into public.expense_recurrences(business_id, name, amount_cents, cadence, next_run_on)
  values (v_biz_a, 'V54 Recurring', 5000, 'monthly', (timezone('Asia/Singapore', now()))::date - 1)
  returning id into v_recur;
  select count(*)::int into v_exp_recur_before from public.expenses where recurrence_id = v_recur;
  perform app.run_expense_recurrences();
  select count(*)::int into v_exp_recur_after from public.expenses where recurrence_id = v_recur;
  perform pg_temp.assert_eq(v_exp_recur_after - v_exp_recur_before, 1,
    'run_expense_recurrences still inserts expenses after the authenticated write revoke');

  -- 15b. FEFO deduct drains a batch received through receive_stock. Use a dedicated
  --      product so the drained batch is deterministic.
  perform pg_temp.as_user(v_owner_a);
  v_rs_fefo := public.receive_stock(v_biz_a, v_prod_fefo, 8, null, null, gen_random_uuid());
  v_fefo_batch := (v_rs_fefo->>'stock_batch_id')::uuid;
  reset role;
  perform pg_temp.assert_eq((select qty from public.stock_batches where id = v_fefo_batch), 8, 'FEFO batch received with qty 8');
  insert into public.sales(business_id, kind, amount_cents, occurred_at, product_id, qty)
  values (v_biz_a, 'retail', 1000, statement_timestamp(), v_prod_fefo, 3);
  perform pg_temp.assert_eq((select qty from public.stock_batches where id = v_fefo_batch), 5,
    'app.on_sale_stock_deduct drained the receive_stock batch (internal writer still functions)');

  -- =========================================================================
  -- 16. Concurrency structure (single-connection proof): the UNIQUE key the
  --     advisory-lock idempotency rests on rejects a duplicate (business, key).
  -- =========================================================================
  reset role;
  perform pg_temp.expect_state(
    'insert into public.f2_write_operations(business_id,actor,operation_type,idempotency_key,request_hash,status,result) '
    || format('values (%L::uuid,%L::uuid,%L,%L::uuid,%L,%L,%L::jsonb)',
         v_biz_a, v_owner_a, 'expense_create', v_key_e1, repeat('a', 64), 'completed', '{}'),
    'duplicate (business, idempotency_key) op-ledger row rejected by UNIQUE', '23505');

  raise notice 'v54 F2 write-hardening suite passed';
end $v54$;

-- ===========================================================================
-- F2-1 DB-FAILURE INJECTION: prove atomicity — a mid-transaction failure of the
-- audit insert (injection A on audit_log) OR the op-ledger insert (injection B on
-- f2_write_operations) inside create_expense / receive_stock persists ZERO rows in
-- expenses / stock_batches / audit_log / f2_write_operations (the owner's "creates no
-- partial record when validation or audit insertion fails" bullet, exercised not just
-- structural). Each injected call is wrapped in a nested BEGIN/EXCEPTION block so the
-- injected failure rolls back to that block's savepoint and the suite continues.
-- The two injection functions raise only for a marker idempotency key (GUC f2.inject_key),
-- so they are surgical; both are dropped, then a normal call is proven to still succeed.
-- ===========================================================================
reset role;
create function public.f2_inject_audit_raise() returns trigger
language plpgsql as $fn$
begin
  if new.action in ('expense_create', 'stock_receive')
     and new.detail->>'idempotency_key' = current_setting('f2.inject_key', true) then
    raise exception 'F2 injected audit-insert failure' using errcode = 'P0001';
  end if;
  return new;
end $fn$;
create function public.f2_inject_op_raise() returns trigger
language plpgsql as $fn$
begin
  if new.idempotency_key::text = current_setting('f2.inject_key', true) then
    raise exception 'F2 injected op-ledger-insert failure' using errcode = 'P0001';
  end if;
  return new;
end $fn$;

do $f2_inject$
declare
  v_biz uuid; v_owner uuid; v_branch uuid; v_prod uuid;
  v_exp0 int; v_sb0 int; v_audit0 int; v_ops0 int;
  v_key uuid; v_raised boolean;
begin
  reset role;
  select b.id into v_biz from public.businesses b where b.name = 'Pristine chain fixture A';
  select s.user_id into v_owner from public.staff s
    where s.business_id = v_biz and s.role = 'owner' and s.active and s.user_id is not null limit 1;
  select id into v_branch from public.branches where business_id = v_biz and is_default;
  select id into v_prod from public.products where business_id = v_biz and name = 'V54 Widget' limit 1;
  if v_biz is null or v_owner is null or v_branch is null or v_prod is null then
    raise exception 'F2-1 injection needs the v54 fixtures (tenant A owner/branch/product)';
  end if;

  -- Snapshot for a wholesale "nothing persisted" comparison across the whole injection phase.
  select count(*)::int into v_exp0 from public.expenses where business_id = v_biz;
  select count(*)::int into v_sb0 from public.stock_batches sb
    join public.products p on p.id = sb.product_id where p.business_id = v_biz;
  select count(*)::int into v_audit0 from public.audit_log where business_id = v_biz;
  select count(*)::int into v_ops0 from public.f2_write_operations where business_id = v_biz;

  -- ========== Injection A: the audit_log insert fails mid-transaction ==========
  execute 'create trigger f2_inject_audit before insert on public.audit_log '
       || 'for each row execute function public.f2_inject_audit_raise()';

  -- A1. create_expense: the explicit semantic audit insert fails -> whole RPC rolls back.
  v_key := gen_random_uuid();
  perform set_config('f2.inject_key', v_key::text, true);
  perform pg_temp.as_user(v_owner);
  v_raised := false;
  begin
    perform public.create_expense(v_biz, v_branch, 'Inject Audit Expense', 12345,
      null, null, null, null, v_key);
  exception when others then v_raised := true;
  end;
  reset role;
  perform pg_temp.assert_true(v_raised, 'create_expense surfaced the injected audit-insert failure');
  perform pg_temp.assert_eq((select count(*)::int from public.expenses where business_id = v_biz),
    v_exp0, 'audit failure left no expense row');
  perform pg_temp.assert_eq((select count(*)::int from public.audit_log where business_id = v_biz),
    v_audit0, 'audit failure left no audit rows');
  perform pg_temp.assert_eq((select count(*)::int from public.f2_write_operations where business_id = v_biz),
    v_ops0, 'audit failure left no op-ledger row');

  -- A2. receive_stock: the explicit semantic audit insert fails -> whole RPC rolls back.
  v_key := gen_random_uuid();
  perform set_config('f2.inject_key', v_key::text, true);
  perform pg_temp.as_user(v_owner);
  v_raised := false;
  begin
    perform public.receive_stock(v_biz, v_prod, 4, null, null, v_key);
  exception when others then v_raised := true;
  end;
  reset role;
  perform pg_temp.assert_true(v_raised, 'receive_stock surfaced the injected audit-insert failure');
  perform pg_temp.assert_eq((select count(*)::int from public.stock_batches sb
    join public.products p on p.id = sb.product_id where p.business_id = v_biz),
    v_sb0, 'audit failure left no stock batch');
  perform pg_temp.assert_eq((select count(*)::int from public.audit_log where business_id = v_biz),
    v_audit0, 'audit failure left no audit rows (receiving)');
  perform pg_temp.assert_eq((select count(*)::int from public.f2_write_operations where business_id = v_biz),
    v_ops0, 'audit failure left no op-ledger row (receiving)');

  execute 'drop trigger f2_inject_audit on public.audit_log';

  -- ========== Injection B: the f2_write_operations insert fails mid-transaction ==========
  -- Distinct from injection A: here the value row AND the audit row are written first, then
  -- the FINAL op-ledger insert fails; the whole RPC must still roll back to zero rows.
  execute 'create trigger f2_inject_op before insert on public.f2_write_operations '
       || 'for each row execute function public.f2_inject_op_raise()';

  -- B1. create_expense: op-ledger insert fails -> whole RPC rolls back.
  v_key := gen_random_uuid();
  perform set_config('f2.inject_key', v_key::text, true);
  perform pg_temp.as_user(v_owner);
  v_raised := false;
  begin
    perform public.create_expense(v_biz, v_branch, 'Inject Op Expense', 23456,
      null, null, null, null, v_key);
  exception when others then v_raised := true;
  end;
  reset role;
  perform pg_temp.assert_true(v_raised, 'create_expense surfaced the injected op-ledger failure');
  perform pg_temp.assert_eq((select count(*)::int from public.expenses where business_id = v_biz),
    v_exp0, 'op-ledger failure left no expense row');
  perform pg_temp.assert_eq((select count(*)::int from public.audit_log where business_id = v_biz),
    v_audit0, 'op-ledger failure left no audit rows');
  perform pg_temp.assert_eq((select count(*)::int from public.f2_write_operations where business_id = v_biz),
    v_ops0, 'op-ledger failure left no op-ledger row');

  -- B2. receive_stock: op-ledger insert fails -> whole RPC rolls back.
  v_key := gen_random_uuid();
  perform set_config('f2.inject_key', v_key::text, true);
  perform pg_temp.as_user(v_owner);
  v_raised := false;
  begin
    perform public.receive_stock(v_biz, v_prod, 6, null, null, v_key);
  exception when others then v_raised := true;
  end;
  reset role;
  perform pg_temp.assert_true(v_raised, 'receive_stock surfaced the injected op-ledger failure');
  perform pg_temp.assert_eq((select count(*)::int from public.stock_batches sb
    join public.products p on p.id = sb.product_id where p.business_id = v_biz),
    v_sb0, 'op-ledger failure left no stock batch');
  perform pg_temp.assert_eq((select count(*)::int from public.audit_log where business_id = v_biz),
    v_audit0, 'op-ledger failure left no audit rows (receiving)');
  perform pg_temp.assert_eq((select count(*)::int from public.f2_write_operations where business_id = v_biz),
    v_ops0, 'op-ledger failure left no op-ledger row (receiving)');

  execute 'drop trigger f2_inject_op on public.f2_write_operations';

  -- ========== Post-injection: with both injections dropped, normal calls succeed. ==========
  perform pg_temp.as_user(v_owner);
  perform public.create_expense(v_biz, v_branch, 'Post Inject Expense', 100,
    null, null, null, null, gen_random_uuid());
  perform public.receive_stock(v_biz, v_prod, 3, null, null, gen_random_uuid());
  reset role;
  perform pg_temp.assert_eq((select count(*)::int from public.expenses where business_id = v_biz),
    v_exp0 + 1, 'a normal create_expense succeeds once the injection is dropped');
  perform pg_temp.assert_eq((select count(*)::int from public.stock_batches sb
    join public.products p on p.id = sb.product_id where p.business_id = v_biz),
    v_sb0 + 1, 'a normal receive_stock succeeds once the injection is dropped');
  perform pg_temp.assert_eq((select count(*)::int from public.f2_write_operations where business_id = v_biz),
    v_ops0 + 2, 'the two post-injection successes each wrote one op-ledger row');

  raise notice 'v54 F2-1 failure-injection cases passed';
end $f2_inject$;

drop function public.f2_inject_audit_raise();
drop function public.f2_inject_op_raise();

rollback;
