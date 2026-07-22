-- Rollback-only v51 sale_items / record_cart_sale suite.
-- Run after the complete canonical chain through v51 in a disposable rehearsal DB.
-- Every synthetic row is discarded by the closing ROLLBACK.
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

do $v51$
declare
  v_biz_a uuid; v_owner_a uuid; v_client_a uuid; v_branch_a uuid;
  v_biz_b uuid; v_owner_b uuid; v_svc_b uuid;
  v_svc_a uuid; v_prod1 uuid; v_prod2 uuid; v_batch1 uuid; v_batch2 uuid;
  v_res jsonb; v_res2 jsonb; v_sale uuid; v_sale2 uuid;
  v_items int; v_pts int; v_pid uuid; v_qty int;
  v_b1 int; v_b2 int; v_lines jsonb;
begin
  -- Locate the pristine loyalty-active tenant A and the separate tenant B.
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
  select id into v_branch_a from public.branches where business_id = v_biz_a and active order by is_default desc, created_at limit 1;
  if v_biz_a is null or v_biz_b is null or v_client_a is null or v_branch_a is null then
    raise exception 'v51 suite requires the pristine A/B fixture';
  end if;

  -- Privileged fixture seeding: a service + two products with stock in A, a service in B.
  insert into public.services(business_id, name, price_cents, duration_min, active)
  values (v_biz_a, 'V51 Cut', 3000, 30, true) returning id into v_svc_a;
  insert into public.services(business_id, name, price_cents, duration_min, active)
  values (v_biz_b, 'V51 B Service', 1000, 30, true) returning id into v_svc_b;
  insert into public.products(business_id, name, sku, retail_price_cents, active)
  values (v_biz_a, 'V51 Shampoo', 'V51-SKU-1', 1000, true) returning id into v_prod1;
  insert into public.products(business_id, name, sku, retail_price_cents, active)
  values (v_biz_a, 'V51 Conditioner', 'V51-SKU-2', 1000, true) returning id into v_prod2;
  insert into public.stock_batches(product_id, qty, expires_on, received_on)
  values (v_prod1, 10, current_date + 90, current_date) returning id into v_batch1;
  insert into public.stock_batches(product_id, qty, expires_on, received_on)
  values (v_prod2, 5, current_date + 90, current_date) returning id into v_batch2;

  -- ========================================================================
  -- 1. Happy path: service + custom line; points earn on the TOTAL; no FEFO.
  -- ========================================================================
  perform pg_temp.as_user(v_owner_a);
  v_lines := jsonb_build_array(
    jsonb_build_object('item_type', 'service', 'ref_id', v_svc_a, 'description', 'Cut', 'qty', 1, 'unit_cents', 3000),
    jsonb_build_object('item_type', 'custom', 'description', 'Tip', 'qty', 1, 'unit_cents', 2000));
  v_res := public.record_cart_sale(v_biz_a, v_client_a, v_branch_a, null, 'cash', 'cart-happy-0001', v_lines)::jsonb;
  perform pg_temp.assert_eq(v_res->>'status', 'ok', 'happy path returns ok');
  perform pg_temp.assert_eq((v_res->>'total_cents')::int, 5000, 'total is the sum of lines');
  perform pg_temp.assert_eq((v_res->>'item_count')::int, 2, 'two lines counted');
  v_sale := (v_res->>'sale_id')::uuid;

  reset role;
  select count(*) into v_items from public.sale_items where sale_id = v_sale and business_id = v_biz_a;
  perform pg_temp.assert_eq(v_items, 2, 'two child sale_items written');
  perform pg_temp.assert_eq((select kind from public.sales where id = v_sale), 'quick_sale',
    'parent row is a quick_sale (fires points/retention/referral like the till)');
  perform pg_temp.assert_true((select product_id from public.sales where id = v_sale) is null,
    'no retail line => parent product_id stays null');
  select coalesce(sum(points), 0) into v_pts from public.points_ledger
   where sale_id = v_sale and entry_type = 'earn';
  perform pg_temp.assert_eq(v_pts, 50, 'points earned on the $50 total at 1pt/$');

  -- ========================================================================
  -- 2. Single-retail cart FEFO-deducts and stamps parent product_id/qty.
  -- ========================================================================
  reset role;
  select qty into v_b1 from public.stock_batches where id = v_batch1;
  perform pg_temp.assert_eq(v_b1, 10, 'batch1 starts at 10');
  perform pg_temp.as_user(v_owner_a);
  v_lines := jsonb_build_array(
    jsonb_build_object('item_type', 'retail', 'ref_id', v_prod1, 'description', 'Shampoo x3', 'qty', 3, 'unit_cents', 1000));
  v_res := public.record_cart_sale(v_biz_a, v_client_a, v_branch_a, null, 'card', 'cart-retail-0001', v_lines)::jsonb;
  v_sale := (v_res->>'sale_id')::uuid;
  perform pg_temp.assert_eq((v_res->>'total_cents')::int, 3000, 'single retail total 3000');

  reset role;
  select qty into v_b1 from public.stock_batches where id = v_batch1;
  perform pg_temp.assert_eq(v_b1, 7, 'single-retail cart drained 3 from the FEFO batch');
  select product_id, qty into v_pid, v_qty from public.sales where id = v_sale;
  perform pg_temp.assert_eq(v_pid, v_prod1, 'parent product_id stamped to the single retail product');
  perform pg_temp.assert_eq(v_qty, 3, 'parent qty stamped to the single retail qty');
  perform pg_temp.assert_eq(
    (select product_id from public.sale_items where sale_id = v_sale), v_prod1,
    'retail sale_item carries product_id');
  select coalesce(sum(points), 0) into v_pts from public.points_ledger where sale_id = v_sale and entry_type = 'earn';
  perform pg_temp.assert_eq(v_pts, 30, 'points earned on the $30 retail total');

  -- ========================================================================
  -- 3. Multi-retail cart deducts nothing and leaves product_id null.
  -- ========================================================================
  reset role;
  select qty into v_b1 from public.stock_batches where id = v_batch1;
  select qty into v_b2 from public.stock_batches where id = v_batch2;
  perform pg_temp.as_user(v_owner_a);
  v_lines := jsonb_build_array(
    jsonb_build_object('item_type', 'retail', 'ref_id', v_prod1, 'qty', 1, 'unit_cents', 500),
    jsonb_build_object('item_type', 'retail', 'ref_id', v_prod2, 'qty', 1, 'unit_cents', 500));
  v_res := public.record_cart_sale(v_biz_a, v_client_a, v_branch_a, null, 'paynow', 'cart-multi-0001', v_lines)::jsonb;
  v_sale := (v_res->>'sale_id')::uuid;
  reset role;
  perform pg_temp.assert_eq((select qty from public.stock_batches where id = v_batch1), v_b1,
    'multi-retail cart deducts nothing from batch1');
  perform pg_temp.assert_eq((select qty from public.stock_batches where id = v_batch2), v_b2,
    'multi-retail cart deducts nothing from batch2');
  perform pg_temp.assert_true((select product_id from public.sales where id = v_sale) is null,
    'multi-retail cart leaves parent product_id null');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.sale_items where sale_id = v_sale), 2, 'both retail lines itemized');

  -- ========================================================================
  -- 4. Idempotent replay: same key + lines => same sale, same items, no dupes.
  -- ========================================================================
  perform pg_temp.as_user(v_owner_a);
  v_lines := jsonb_build_array(
    jsonb_build_object('item_type', 'service', 'ref_id', v_svc_a, 'qty', 1, 'unit_cents', 3000));
  v_res := public.record_cart_sale(v_biz_a, v_client_a, v_branch_a, null, 'cash', 'cart-replay-0001', v_lines)::jsonb;
  v_res2 := public.record_cart_sale(v_biz_a, v_client_a, v_branch_a, null, 'cash', 'cart-replay-0001', v_lines)::jsonb;
  v_sale := (v_res->>'sale_id')::uuid;
  v_sale2 := (v_res2->>'sale_id')::uuid;
  perform pg_temp.assert_eq(v_sale2, v_sale, 'replay returns the same sale id');
  perform pg_temp.assert_eq(v_res2->>'status', 'duplicate_ignored', 'replay is flagged duplicate_ignored');
  perform pg_temp.assert_eq((v_res2->>'points_earned')::int, 0, 'replay reports zero fresh points');
  reset role;
  perform pg_temp.assert_eq(
    (select count(*)::int from public.sale_items where sale_id = v_sale), 1, 'replay wrote no duplicate items');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.sales where business_id = v_biz_a and note = 'cart checkout'
      and id = v_sale), 1, 'exactly one parent sale for the replayed key');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.points_ledger where sale_id = v_sale and entry_type = 'earn'), 1,
    'points earned exactly once across the replay');

  -- ========================================================================
  -- 5. Validation rejections (owner A, authorized; failures are input errors).
  -- ========================================================================
  perform pg_temp.as_user(v_owner_a);
  perform pg_temp.expect_state(
    format('select public.record_cart_sale(%L::uuid,%L::uuid,%L::uuid,null,%L,%L,%L::jsonb)',
      v_biz_a, v_client_a, v_branch_a, 'cash', 'short', jsonb_build_array(
        jsonb_build_object('item_type','custom','qty',1,'unit_cents',1000))::text),
    'short idempotency key rejected', '22023');
  perform pg_temp.expect_state(
    format('select public.record_cart_sale(%L::uuid,%L::uuid,%L::uuid,null,%L,%L,%L::jsonb)',
      v_biz_a, v_client_a, v_branch_a, 'cash', 'cart-empty-0001', '[]'::text),
    'empty cart rejected', '22023');
  perform pg_temp.expect_state(
    format('select public.record_cart_sale(%L::uuid,%L::uuid,%L::uuid,null,%L,%L,%L::jsonb)',
      v_biz_a, v_client_a, v_branch_a, 'cash', 'cart-badtype-01', jsonb_build_array(
        jsonb_build_object('item_type','voucher','qty',1,'unit_cents',1000))::text),
    'unknown item_type rejected', '22023');
  perform pg_temp.expect_state(
    format('select public.record_cart_sale(%L::uuid,%L::uuid,%L::uuid,null,%L,%L,%L::jsonb)',
      v_biz_a, v_client_a, v_branch_a, 'cash', 'cart-badqty-001', jsonb_build_array(
        jsonb_build_object('item_type','custom','qty',0,'unit_cents',1000))::text),
    'non-positive qty rejected', '22023');
  perform pg_temp.expect_state(
    format('select public.record_cart_sale(%L::uuid,%L::uuid,%L::uuid,null,%L,%L,%L::jsonb)',
      v_biz_a, v_client_a, v_branch_a, 'cash', 'cart-xtenant-01', jsonb_build_array(
        jsonb_build_object('item_type','service','ref_id',v_svc_b,'qty',1,'unit_cents',1000))::text),
    'cross-tenant service ref rejected', '22023');
  perform pg_temp.expect_state(
    format('select public.record_cart_sale(%L::uuid,%L::uuid,%L::uuid,null,%L,%L,%L::jsonb)',
      v_biz_a, v_client_a, v_branch_a, 'bitcoin', 'cart-badpay-001', jsonb_build_array(
        jsonb_build_object('item_type','custom','qty',1,'unit_cents',1000))::text),
    'unsupported method rejected', '22023');
  perform pg_temp.expect_state(
    format('select public.record_cart_sale(%L::uuid,%L::uuid,%L::uuid,null,%L,%L,(select jsonb_agg(jsonb_build_object(''item_type'',''custom'',''qty'',1,''unit_cents'',1)) from generate_series(1,51)))',
      v_biz_a, v_client_a, v_branch_a, 'cash', 'cart-toolong-01'),
    'over-50-line cart rejected', '22023');

  -- ========================================================================
  -- 6. Cross-tenant write denial: owner A cannot bill business B.
  -- ========================================================================
  perform pg_temp.expect_state(
    format('select public.record_cart_sale(%L::uuid,null,null,null,%L,%L,%L::jsonb)',
      v_biz_b, 'cash', 'cart-crossbiz-1', jsonb_build_array(
        jsonb_build_object('item_type','custom','qty',1,'unit_cents',1000))::text),
    'owner A denied on tenant B', '42501');

  -- ========================================================================
  -- 7. Anonymous denial.
  -- ========================================================================
  perform pg_temp.as_anon();
  perform pg_temp.expect_state(
    format('select public.record_cart_sale(%L::uuid,%L::uuid,%L::uuid,null,%L,%L,%L::jsonb)',
      v_biz_a, v_client_a, v_branch_a, 'cash', 'cart-anon-00001', jsonb_build_array(
        jsonb_build_object('item_type','custom','qty',1,'unit_cents',1000))::text),
    'anon denied', '42501');

  -- ========================================================================
  -- 8. Append-only guard on sale_items (UPDATE and DELETE both refused).
  -- ========================================================================
  reset role;
  select id into v_sale from public.sale_items limit 1;
  perform pg_temp.expect_state(
    format('update public.sale_items set description = ''tampered'' where id = %L::uuid', v_sale),
    'sale_items UPDATE refused', '23001'::text);
end $v51$;

-- The append-only guard raises errcode 'restrict_violation' (SQLSTATE 23001) on DELETE too.
do $guard$
declare v_row uuid; v_state text;
begin
  reset role;
  select id into v_row from public.sale_items limit 1;
  begin
    execute format('delete from public.sale_items where id = %L::uuid', v_row);
    raise exception 'sale_items DELETE unexpectedly succeeded';
  exception when others then
    v_state := sqlstate;
    if v_state <> '23001' then
      raise exception 'sale_items DELETE raised %, expected restrict_violation 23001: %', v_state, sqlerrm;
    end if;
  end;
end $guard$;

rollback;
