-- Rollback-only acceptance for nestly_v455 — FEFO follows sale_items, not the sale header.
--   supabase db query --linked -f db/tests/v455_stock_follows_sale_items.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Every check drives the real checkout kernel: public.evaluate_checkout to price the cart, then
-- public.record_cart_sale to finalise it, as an authenticated owner, against a firm built inside
-- this transaction. Nothing here reads a function's source text.
--
--   01  THE DEFECT: two DISTINCT products on one bill both deduct
--   02  REGRESSION: one product on the bill deducts EXACTLY once (proves no double deduction now
--       that two triggers exist -- a double would show as 6, not 8)
--   03  REGRESSION: product + service deducts the product once and the service not at all
--   04  quantity larger than the stock on hand takes what exists and never goes negative
--   05  a product with NO stock batch still sells, and its balance stays 0
--   06  a reversal restores no stock -- today's behaviour, which this change must not alter
--   07  the exclusivity invariant the two triggers rely on holds for every sale written above
--
-- 02 and 03 are the double-deduction guard the design rests on: app.on_sale_stock_deduct (header)
-- and app.on_sale_item_stock_deduct_v455 (lines) are mutually exclusive on sales.product_id, so
-- exactly one of them acts on any given sale. Check 07 asserts that field-level invariant directly.

begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v455_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v455_user(uuid) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();
  v_staff uuid;
  v_branch uuid;
  v_client uuid := gen_random_uuid();
  v_a uuid := gen_random_uuid();   -- stocked 10
  v_b uuid := gen_random_uuid();   -- stocked 10
  v_c uuid := gen_random_uuid();   -- stocked 10, used by the single-line regression
  v_d uuid := gen_random_uuid();   -- stocked 10, used by the product+service regression
  v_thin uuid := gen_random_uuid();-- stocked 2, oversold on purpose
  v_none uuid := gen_random_uuid();-- NO batch at all
  v_svc uuid := gen_random_uuid();
  v_eval jsonb;
  v_sale jsonb;
  v_txt text;
  v_sale_two uuid;
  v_n int;
  v_stock int;
begin
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'v455-owner@example.test', '', now(), now(), now());

  insert into public.businesses(id, name, slug, enabled_modules)
  values (v_biz, 'V455 Firm', 'v455-' || substr(v_biz::text, 1, 8),
          array['till', 'inventory', 'clients', 'sales', 'services', 'loyalty']);
  insert into public.staff(business_id, user_id, role, full_name, active)
  values (v_biz, v_owner, 'owner', 'V455 Owner', true)
  returning id into v_staff;

  -- An unapproved or paused workspace makes every module 'disabled' and the kernel refuses before
  -- it writes anything; a stock assertion against a refused sale would pass for the wrong reason.
  insert into public.business_workspace_controls_v94(
    business_id, approval_status, decided_by, decided_at, decision_reason)
  values (v_biz, 'approved', v_owner, now(), 'v455 fixture')
  on conflict (business_id) do update
    set approval_status = 'approved', decided_by = excluded.decided_by,
        decided_at = excluded.decided_at, decision_reason = excluded.decision_reason;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false)
  on conflict (business_id) do update set workspace_paused = false;

  select id into v_branch from public.branches
   where business_id = v_biz order by created_at, id limit 1;
  if v_branch is null then
    v_branch := gen_random_uuid();
    insert into public.branches(id, business_id, name) values (v_branch, v_biz, 'V455 Main');
  end if;

  insert into public.clients(id, business_id, full_name) values (v_client, v_biz, 'V455 Customer');
  insert into public.products(id, business_id, name, retail_price_cents) values
    (v_a,    v_biz, 'V455 Product A',        1000),
    (v_b,    v_biz, 'V455 Product B',         500),
    (v_c,    v_biz, 'V455 Product C',         800),
    (v_d,    v_biz, 'V455 Product D',         900),
    (v_thin, v_biz, 'V455 Thin Stock',        300),
    (v_none, v_biz, 'V455 Never Received',    400);
  insert into public.services(id, business_id, name, price_cents, duration_min)
  values (v_svc, v_biz, 'V455 Service', 700, 30);
  insert into public.stock_batches(product_id, qty) values
    (v_a, 10), (v_b, 10), (v_c, 10), (v_d, 10), (v_thin, 2);
  -- v_none deliberately receives nothing.

  ---------------------------------------------------- 1 - two distinct products on one bill
  perform pg_temp.as_v455_user(v_owner);
  begin
    v_eval := to_jsonb(public.evaluate_checkout(v_biz, v_branch, v_client,
      jsonb_build_array(
        jsonb_build_object('catalog_kind', 'product', 'catalog_id', v_a, 'qty', 2),
        jsonb_build_object('catalog_kind', 'product', 'catalog_id', v_b, 'qty', 3)),
      gen_random_uuid()));
    v_sale := to_jsonb(public.record_cart_sale(v_biz, v_client, v_branch, v_staff, 'cash',
      'v455-two-products', null, (v_eval->>'evaluation_id')::uuid, true));
    v_txt := null;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm; v_sale := null;
  end;
  reset role;
  v_sale_two := nullif(v_sale->>'sale_id', '')::uuid;
  insert into _r values('01_two_product_sale_recorded',
    case when v_txt is not null then 'FAIL the two-product cart raised ' || v_txt
         when v_sale->>'status' = 'ok' then 'PASS total=' || (v_sale->>'total_cents')
         else 'FAIL unexpected receipt ' || coalesce(v_sale::text, 'null') end);

  select stock into v_stock from public.product_stock where product_id = v_a;
  insert into _r values('01_two_product_first_line_deducted',
    case when v_stock = 8 then 'PASS product A 10 -> 8'
         when v_stock = 10 then 'FAIL product A was not deducted at all (the v455 defect)'
         else 'FAIL product A is ' || v_stock || ', expected 8' end);
  select stock into v_stock from public.product_stock where product_id = v_b;
  insert into _r values('01_two_product_second_line_deducted',
    case when v_stock = 7 then 'PASS product B 10 -> 7'
         when v_stock = 10 then 'FAIL product B was not deducted at all (the v455 defect)'
         else 'FAIL product B is ' || v_stock || ', expected 7' end);

  ------------------------------------- 2 - one product: deducted EXACTLY once, not twice
  perform pg_temp.as_v455_user(v_owner);
  begin
    v_eval := to_jsonb(public.evaluate_checkout(v_biz, v_branch, v_client,
      jsonb_build_array(jsonb_build_object('catalog_kind', 'product', 'catalog_id', v_c, 'qty', 2)),
      gen_random_uuid()));
    v_sale := to_jsonb(public.record_cart_sale(v_biz, v_client, v_branch, v_staff, 'cash',
      'v455-one-product', null, (v_eval->>'evaluation_id')::uuid, true));
    v_txt := null;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm; v_sale := null;
  end;
  reset role;
  insert into _r values('02_single_product_sale_recorded',
    case when v_txt is not null then 'FAIL the single-product cart raised ' || v_txt
         when v_sale->>'status' = 'ok' then 'PASS total=' || (v_sale->>'total_cents')
         else 'FAIL unexpected receipt ' || coalesce(v_sale::text, 'null') end);

  select stock into v_stock from public.product_stock where product_id = v_c;
  insert into _r values('02_single_product_deducted_exactly_once',
    case when v_stock = 8 then 'PASS product C 10 -> 8 (one deduction)'
         when v_stock = 6 then 'FAIL DOUBLE DEDUCTION: 10 -> 6; both triggers acted on one line'
         when v_stock = 10 then 'FAIL product C was not deducted at all'
         else 'FAIL product C is ' || v_stock || ', expected 8' end);

  ------------------------------------------------------------ 3 - product plus a service
  perform pg_temp.as_v455_user(v_owner);
  begin
    v_eval := to_jsonb(public.evaluate_checkout(v_biz, v_branch, v_client,
      jsonb_build_array(
        jsonb_build_object('catalog_kind', 'product', 'catalog_id', v_d, 'qty', 1),
        jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_svc, 'qty', 1)),
      gen_random_uuid()));
    v_sale := to_jsonb(public.record_cart_sale(v_biz, v_client, v_branch, v_staff, 'cash',
      'v455-product-and-service', null, (v_eval->>'evaluation_id')::uuid, true));
    v_txt := null;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm; v_sale := null;
  end;
  reset role;
  insert into _r values('03_product_and_service_recorded',
    case when v_txt is not null then 'FAIL the product+service cart raised ' || v_txt
         when v_sale->>'status' = 'ok' then 'PASS total=' || (v_sale->>'total_cents')
         else 'FAIL unexpected receipt ' || coalesce(v_sale::text, 'null') end);
  select stock into v_stock from public.product_stock where product_id = v_d;
  insert into _r values('03_product_deducted_exactly_once',
    case when v_stock = 9 then 'PASS product D 10 -> 9 (one deduction)'
         when v_stock = 8 then 'FAIL DOUBLE DEDUCTION: 10 -> 8'
         else 'FAIL product D is ' || v_stock || ', expected 9' end);

  --------------------------------------- 4 - a line larger than stock never goes negative
  perform pg_temp.as_v455_user(v_owner);
  begin
    v_eval := to_jsonb(public.evaluate_checkout(v_biz, v_branch, v_client,
      jsonb_build_array(
        jsonb_build_object('catalog_kind', 'product', 'catalog_id', v_thin, 'qty', 5),
        jsonb_build_object('catalog_kind', 'product', 'catalog_id', v_a, 'qty', 1)),
      gen_random_uuid()));
    v_sale := to_jsonb(public.record_cart_sale(v_biz, v_client, v_branch, v_staff, 'cash',
      'v455-oversell', null, (v_eval->>'evaluation_id')::uuid, true));
    v_txt := null;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm; v_sale := null;
  end;
  reset role;
  insert into _r values('04_oversell_still_sells',
    case when v_txt is not null then 'FAIL a line larger than stock must still sell; raised ' || v_txt
         when v_sale->>'status' = 'ok' then 'PASS the sale was recorded'
         else 'FAIL unexpected receipt ' || coalesce(v_sale::text, 'null') end);
  select stock into v_stock from public.product_stock where product_id = v_thin;
  insert into _r values('04_oversell_floors_at_zero',
    case when v_stock = 0 then 'PASS thin stock 2 -> 0, never negative'
         when v_stock < 0 then 'FAIL stock went negative: ' || v_stock
         else 'FAIL thin stock is ' || v_stock || ', expected 0' end);
  select count(*) into v_n from public.stock_batches where qty < 0;
  insert into _r values('04_no_negative_batch_anywhere',
    case when v_n = 0 then 'PASS no stock batch in the database is negative'
         else 'FAIL ' || v_n || ' stock batch(es) are negative' end);
  select stock into v_stock from public.product_stock where product_id = v_a;
  insert into _r values('04_sibling_line_on_same_bill_deducted',
    case when v_stock = 7 then 'PASS product A 8 -> 7 on the same oversold bill'
         else 'FAIL product A is ' || v_stock || ', expected 7' end);

  ------------------------------------------- 5 - a product that never received any stock
  perform pg_temp.as_v455_user(v_owner);
  begin
    v_eval := to_jsonb(public.evaluate_checkout(v_biz, v_branch, v_client,
      jsonb_build_array(jsonb_build_object('catalog_kind', 'product', 'catalog_id', v_none, 'qty', 4)),
      gen_random_uuid()));
    v_sale := to_jsonb(public.record_cart_sale(v_biz, v_client, v_branch, v_staff, 'cash',
      'v455-no-batch', null, (v_eval->>'evaluation_id')::uuid, true));
    v_txt := null;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm; v_sale := null;
  end;
  reset role;
  insert into _r values('05_unstocked_product_still_sells',
    case when v_txt is not null then 'FAIL selling an unstocked product raised ' || v_txt
         when v_sale->>'status' = 'ok' then 'PASS the sale was recorded'
         else 'FAIL unexpected receipt ' || coalesce(v_sale::text, 'null') end);
  select stock into v_stock from public.product_stock where product_id = v_none;
  insert into _r values('05_unstocked_product_stays_zero',
    case when v_stock = 0 then 'PASS the balance is 0, not negative'
         else 'FAIL expected 0, got ' || v_stock end);

  ---------------------------------------------- 6 - a reversal restores no stock (today)
  select stock into v_stock from public.product_stock where product_id = v_b;
  perform pg_temp.as_v455_user(v_owner);
  begin
    perform public.reverse_sale_fast_v84(v_biz, v_sale_two, 'v455 acceptance', 'v455-reverse-1');
    v_txt := null;
  exception when others then
    v_txt := sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  insert into _r values('06_reversal_ran',
    case when v_txt is null then 'PASS the two-product sale was reversed'
         else 'INFO the reversal path refused (' || v_txt
              || '); the stock assertion below still holds' end);
  select count(*) into v_n from public.sales where business_id = v_biz and reversal_of = v_sale_two;
  insert into _r values('06_reversal_row_written',
    case when v_txt is null and v_n = 1 then 'PASS one compensating sales row exists'
         when v_txt is not null then 'INFO no reversal row; the path refused'
         else 'FAIL expected exactly one compensating row, found ' || v_n end);
  insert into _r values('06_reversal_restores_no_stock',
    case when (select stock from public.product_stock where product_id = v_b) = v_stock
      then 'PASS product B is unchanged at ' || v_stock || ' -- reversals never restocked'
      else 'FAIL a reversal moved stock; product B went from ' || v_stock || ' to '
           || (select stock from public.product_stock where product_id = v_b) end);

  ------------------------------------- 7 - the invariant the two triggers are keyed on
  select count(*) into v_n
    from (
      select s.id, s.product_id,
             count(*) filter (where i.item_type = 'retail' and i.product_id is not null) retail_lines
        from public.sales s
        join public.sale_items i on i.sale_id = s.id
       where s.business_id = v_biz
       group by s.id, s.product_id
    ) per_sale
   where (product_id is not null and retail_lines <> 1);
  insert into _r values('07_stamped_header_means_exactly_one_retail_line',
    case when v_n = 0 then 'PASS every stamped header corresponds to exactly one retail line'
         else 'FAIL ' || v_n || ' sale(s) carry a header product with a line count other than 1;'
              || ' the two triggers are no longer mutually exclusive' end);

  select count(*) into v_n
    from public.sales s
   where s.business_id = v_biz
     and s.product_id is not null
     and not exists (
       select 1 from public.sale_items i
        where i.sale_id = s.id and i.item_type = 'retail'
          and i.product_id = s.product_id and i.qty = s.qty);
  insert into _r values('07_stamped_header_agrees_with_its_line',
    case when v_n = 0 then 'PASS every stamped header matches its retail line on product and qty'
         else 'FAIL ' || v_n || ' header(s) disagree with the line they claim to represent' end);

  ------------------------------- 8 - this is a stock change and nothing else
  -- The v10 sale-policy resolution is the kernel's business, not the stock trigger's. If a stock
  -- change ever altered what a sale counts as, these flags are where it would show first.
  select count(*) into v_n
    from public.sales
   where business_id = v_biz and reversal_of is null and kind = 'quick_sale'
     and (counts_as_revenue is not true or counts_as_visit is not true or earns_points is not true);
  insert into _r values('08_sale_policy_untouched',
    case when v_n = 0
      then 'PASS every cart sale still resolves revenue=true, visit=true, earns_points=true'
      else 'FAIL ' || v_n || ' cart sale(s) changed their v10 policy resolution' end);

  select count(*) into v_n from public.points_ledger where business_id = v_biz;
  insert into _r values('08_no_loyalty_side_effect',
    case when v_n = 0
      then 'PASS a firm with no active programme still earns nothing; the ledger is untouched'
      else 'FAIL the stock change produced ' || v_n || ' points_ledger row(s)' end);
end
$$;

-- 9 - the deduction triggers, and only those two, are what moves stock on a CART SALE.
-- trg_appointment_completed on public.appointments is deliberately excluded: it deducts service
-- COMPONENTS from public.service_products on the appointment path, writes no sale_items, and
-- cannot stack with either sale trigger. Any OTHER trigger appearing here would mean a third
-- writer had been added and the exclusivity argument no longer covers the ground.
do $$
declare v_sales_trigger int; v_items_trigger int; v_other int; v_other_names text;
begin
  select count(*) into v_sales_trigger from pg_trigger t
   where t.tgrelid = 'public.sales'::regclass and not t.tgisinternal
     and t.tgname = 'trg_sale_stock_deduct';
  select count(*) into v_items_trigger from pg_trigger t
   where t.tgrelid = 'public.sale_items'::regclass and not t.tgisinternal
     and t.tgname = 'trg_sale_item_stock_deduct';
  select count(*), coalesce(string_agg(t.tgname, ', ' order by t.tgname), '')
    into v_other, v_other_names
    from pg_trigger t
    join pg_proc p on p.oid = t.tgfoid
   where not t.tgisinternal
     and pg_get_functiondef(p.oid) like '%update public.stock_batches%'
     and t.tgname not in ('trg_sale_stock_deduct', 'trg_sale_item_stock_deduct',
                          'trg_appointment_completed');

  insert into _r values('09_header_trigger_still_installed',
    case when v_sales_trigger = 1
      then 'PASS app.on_sale_stock_deduct still runs on public.sales; v455 did not modify it'
      else 'FAIL the pre-existing header trigger is missing' end);
  insert into _r values('09_line_trigger_installed',
    case when v_items_trigger = 1
      then 'PASS trg_sale_item_stock_deduct runs on public.sale_items'
      else 'FAIL the v455 line trigger is not installed' end);
  insert into _r values('09_no_third_stock_writer',
    case when v_other = 0
      then 'PASS the only stock writers are the two sale triggers and the appointment path'
      else 'FAIL a third trigger writes stock_batches (' || v_other_names
           || '); deduction could stack' end);
end
$$;

select k, v from _r order by k;

rollback;
