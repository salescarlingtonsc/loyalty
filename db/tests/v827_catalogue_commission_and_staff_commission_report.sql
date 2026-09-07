-- nestly_v827 rollback suite (the migration was written and applied as v825; its objects keep _v825).
--
-- Asserts every claim nestly_v825 makes, against an applied database, inside a transaction
-- that is ROLLED BACK. Nothing is left behind.
--
--   supabase db query --linked -f db/tests/v827_catalogue_commission_and_staff_commission_report.sql
--
-- Before the migration was applied it was run with the migration prepended and its trailing
-- `commit;` stripped (and this file's leading `begin;` stripped), which is how the assertions
-- below were proved to FAIL before and PASS after.
--
-- The tenant is the Cubbly demo business (cleanup authorised by the owner); the RPC calls run
-- as the REAL owner principal via request.jwt.claims, never as the table owner.

begin;

-- One sale + one line for the Cubbly demo tenant; returns the line's commission_cents.
-- Lives in pg_temp so the transaction's rollback takes it away with everything else.
create function pg_temp.v825_line(
  p_sale_kind text, p_amount int, p_item_type text, p_ref uuid, p_product uuid,
  p_bundle uuid, p_qty int, p_unit int, p_staff uuid, p_occurred timestamptz
) returns integer
language plpgsql
as $f$
declare v_id uuid := gen_random_uuid(); v_c int;
begin
  insert into public.sales(id, business_id, client_id, kind, amount_cents, occurred_at, branch_id, staff_id)
  values (v_id, '8492e8d6-8888-4383-ada0-7e1ed69f0caa', 'ba4190c5-928f-4cd3-87f0-2fb26d0c30ac',
          p_sale_kind, p_amount, p_occurred, '9a9081fb-fb48-49c7-a1c7-2bfb3d3ec263', p_staff);
  insert into public.sale_items(sale_id, business_id, item_type, ref_id, product_id, bundle_id,
                                description, qty, unit_cents, line_cents)
  values (v_id, '8492e8d6-8888-4383-ada0-7e1ed69f0caa', p_item_type, p_ref, p_product, p_bundle,
          'v825 ' || p_item_type, p_qty, p_unit, p_qty * p_unit);
  select commission_cents into v_c from public.sale_items where sale_id = v_id;
  return v_c;
end
$f$;

do $suite$
declare
  c_biz       constant uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';  -- Cubbly (demo)
  c_owner     constant uuid := 'f73a9423-33fd-424c-9fb9-2d5ba058a2d7';  -- Chuan (owner, auth uid)
  c_kelvin    constant uuid := '63974b85-7ba6-4ab7-ae55-a40ddebd64bb';  -- Kelvin (staff, no login)
  c_branch    constant uuid := '9a9081fb-fb48-49c7-a1c7-2bfb3d3ec263';  -- Cubbly · Orchard
  c_branch2   constant uuid := '45a463f4-5d91-4115-9fe9-f9da056cd369';  -- Kopitiam 2
  c_bundle    constant uuid := '47d1d1da-9bfb-4d3c-94a0-d15c07e01e28';  -- Rainbow special, 8000
  c_facial    constant uuid := 'fb40ad58-65a0-47bb-a2f3-5f16a70a3a4b';  -- member, 3000, 10% override
  c_spa       constant uuid := '8546bd52-f06c-4f88-92b5-f79fa82cf960';  -- member, 3000, 10% override
  c_pillow    constant uuid := '989e3cd4-3d3d-4505-8da0-b22c03eb80a0';  -- product, 5800
  c_plan      constant uuid := '76eec23c-b44c-4087-b00e-94d3e625dd38';  -- 5x spa session, 30000
  c_client    constant uuid := 'ba4190c5-928f-4cd3-87f0-2fb26d0c30ac';  -- Debby
  v_now       constant timestamptz := now();
  v_sale      uuid;
  v_sale_bundle uuid;
  v_sale_bare uuid;
  v_reversal  uuid := gen_random_uuid();
  v_got       integer;
  v_got2      integer;
  v_txt       text;
  v_cnt       integer;
  v_json      jsonb;
  v_bool      boolean;
  n           integer := 0;

begin
  -- Fixture rates: Kelvin earns 10% on services and 20% on products by default, from today.
  update public.staff
     set commission_service_bps = 1000, commission_product_bps = 2000, commission_starts_on = null
   where id = c_kelvin and business_id = c_biz;
  update public.services set commission_bps = 1000, commission_flat_cents = null
   where id in (c_facial, c_spa) and business_id = c_biz;
  update public.products set commission_bps = null, commission_flat_cents = null where id = c_pillow;
  update public.bundles set commission_bps = null, commission_flat_cents = null where id = c_bundle;
  update public.package_plans set commission_bps = null, commission_flat_cents = null where id = c_plan;

  ---------------------------------------------------------------- A. shape
  n := n + 1;
  select count(*) into v_cnt from information_schema.columns
   where table_schema = 'public'
     and ((table_name in ('products','bundles','package_plans')
           and column_name in ('commission_bps','commission_flat_cents'))
          or (table_name = 'sale_items' and column_name = 'bundle_id'));
  if v_cnt <> 7 then
    raise exception 'A%: expected 7 new columns, found %', n, v_cnt;
  end if;

  n := n + 1;
  if not exists (select 1 from pg_trigger where tgname = 'trg_sale_items_commission_v825')
     or exists (select 1 from pg_trigger where tgname = 'trg_sale_items_commission_v811') then
    raise exception 'A%: the sale_items commission trigger was not swapped to v825', n;
  end if;

  n := n + 1;
  select pg_get_functiondef(p.oid) into v_txt from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'record_cart_sale' and p.pronargs = 11;
  if position('nullif(e->>''bundle_id'', '''')::uuid' in v_txt) = 0 then
    raise exception 'A%: record_cart_sale/11 does not write sale_items.bundle_id', n;
  end if;

  n := n + 1;
  select pg_get_functiondef(p.oid) into v_txt from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'sell_package_v102';
  if position('v_staff, v_plan.id);' in v_txt) = 0 then
    raise exception 'A%: sell_package_v102 does not reference the plan on its package line', n;
  end if;

  n := n + 1;
  select pg_get_functiondef(p.oid) into v_txt from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'delete_service_bundle_v285';
  if position('bundle_has_sales' in v_txt) = 0 then
    raise exception 'A%: delete_service_bundle_v285 still hard-deletes a sold bundle', n;
  end if;

  n := n + 1;
  select pg_get_functiondef(p.oid) into v_txt from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'app' and p.proname = 'sale_items_immutable_guard';
  if position('new.bundle_id' in v_txt) = 0 then
    raise exception 'A%: the sale_items immutable guard does not protect bundle_id', n;
  end if;

  ---------------------------------------------------------------- B. products
  n := n + 1;   -- blank: the member's 20%
  v_got := pg_temp.v825_line('quick_sale', 5800, 'retail', c_pillow, c_pillow, null, 1, 5800, c_kelvin, v_now);
  if v_got is distinct from 1160 then
    raise exception 'B%: blank product override paid %c, expected 1160c (20%% of 5800)', n, v_got;
  end if;

  n := n + 1;   -- 15% override beats the member's 20%
  update public.products set commission_bps = 1500 where id = c_pillow;
  v_got := pg_temp.v825_line('quick_sale', 5800, 'retail', c_pillow, c_pillow, null, 1, 5800, c_kelvin, v_now);
  if v_got is distinct from 870 then
    raise exception 'B%: product 15%% override paid %c, expected 870c', n, v_got;
  end if;

  n := n + 1;   -- 0% is a real setting
  update public.products set commission_bps = 0 where id = c_pillow;
  v_got := pg_temp.v825_line('quick_sale', 5800, 'retail', c_pillow, c_pillow, null, 1, 5800, c_kelvin, v_now);
  if v_got is distinct from 0 then
    raise exception 'B%: product 0%% override paid %c, expected 0c', n, v_got;
  end if;

  n := n + 1;   -- fixed amount per unit × qty, outranking the %
  update public.products set commission_bps = 1500, commission_flat_cents = 300 where id = c_pillow;
  v_got := pg_temp.v825_line('quick_sale', 11600, 'retail', c_pillow, c_pillow, null, 2, 5800, c_kelvin, v_now);
  if v_got is distinct from 600 then
    raise exception 'B%: product fixed 300c × 2 paid %c, expected 600c', n, v_got;
  end if;
  update public.products set commission_bps = null, commission_flat_cents = null where id = c_pillow;

  ---------------------------------------------------------------- C. packages
  n := n + 1;   -- blank: the member's product rate, as v818 paid it
  v_got := pg_temp.v825_line('package', 30000, 'package', c_plan, null, null, 1, 30000, c_kelvin, v_now);
  if v_got is distinct from 6000 then
    raise exception 'C%: blank package override paid %c, expected 6000c (20%% of 30000)', n, v_got;
  end if;

  n := n + 1;   -- 10% override
  update public.package_plans set commission_bps = 1000 where id = c_plan;
  v_got := pg_temp.v825_line('package', 30000, 'package', c_plan, null, null, 1, 30000, c_kelvin, v_now);
  if v_got is distinct from 3000 then
    raise exception 'C%: package 10%% override paid %c, expected 3000c', n, v_got;
  end if;

  n := n + 1;   -- fixed amount per package
  update public.package_plans set commission_flat_cents = 2500 where id = c_plan;
  v_got := pg_temp.v825_line('package', 30000, 'package', c_plan, null, null, 1, 30000, c_kelvin, v_now);
  if v_got is distinct from 2500 then
    raise exception 'C%: package fixed 2500c paid %c', n, v_got;
  end if;

  n := n + 1;   -- a session use pays NOTHING (owner ruling: once, at purchase)
  v_got := pg_temp.v825_line('service', 0, 'package_session', null, null, null, 1, 0, c_kelvin, v_now);
  select commission_rate_bps into v_got2 from public.sale_items
   where description = 'v825 package_session' order by created_at desc limit 1;
  if v_got is distinct from 0 or v_got2 is distinct from 0 then
    raise exception 'C%: a package session paid %c at % bps, expected 0 / 0', n, v_got, v_got2;
  end if;
  update public.package_plans set commission_bps = null, commission_flat_cents = null where id = c_plan;

  ---------------------------------------------------------------- D. bundles
  -- Two member lines exactly as v204 expands "Rainbow special" (8000 over 3000 + 3000).
  n := n + 1;   -- blank bundle: each member pays its own 10% override → 400 + 400
  v_sale := gen_random_uuid();
  insert into public.sales(id, business_id, client_id, kind, amount_cents, occurred_at, branch_id, staff_id)
  values (v_sale, c_biz, c_client, 'quick_sale', 8000, v_now, c_branch, c_kelvin);
  insert into public.sale_items(sale_id, business_id, item_type, ref_id, bundle_id, description, qty, unit_cents, line_cents)
  values (v_sale, c_biz, 'service', c_facial, c_bundle, 'facial · Rainbow special', 1, 4000, 4000),
         (v_sale, c_biz, 'service', c_spa,    c_bundle, 'spa · Rainbow special',    1, 4000, 4000);
  select sum(commission_cents)::integer into v_got from public.sale_items where sale_id = v_sale;
  if v_got is distinct from 800 then
    raise exception 'D%: blank bundle paid %c, expected 800c (members'' own 10%%)', n, v_got;
  end if;

  n := n + 1;   -- bundle 5% override beats both members' 10%
  update public.bundles set commission_bps = 500 where id = c_bundle;
  v_sale_bundle := gen_random_uuid();
  insert into public.sales(id, business_id, client_id, kind, amount_cents, occurred_at, branch_id, staff_id)
  values (v_sale_bundle, c_biz, c_client, 'quick_sale', 8000, v_now, c_branch, c_kelvin);
  insert into public.sale_items(sale_id, business_id, item_type, ref_id, bundle_id, description, qty, unit_cents, line_cents)
  values (v_sale_bundle, c_biz, 'service', c_facial, c_bundle, 'facial · Rainbow special', 1, 4000, 4000),
         (v_sale_bundle, c_biz, 'service', c_spa,    c_bundle, 'spa · Rainbow special',    1, 4000, 4000);
  select sum(commission_cents)::integer, min(commission_rate_bps) into v_got, v_got2
    from public.sale_items where sale_id = v_sale_bundle;
  if v_got is distinct from 400 or v_got2 is distinct from 500 then
    raise exception 'D%: bundle 5%% override paid %c at % bps, expected 400c at 500', n, v_got, v_got2;
  end if;

  n := n + 1;   -- the bundle % also silences a member''s fixed amount
  update public.services set commission_flat_cents = 700 where id = c_facial;
  v_got := pg_temp.v825_line('quick_sale', 4000, 'service', c_facial, null, c_bundle, 1, 4000, c_kelvin, v_now);
  if v_got is distinct from 200 then
    raise exception 'D%: bundle override let the member fixed amount through (%c, expected 200c)', n, v_got;
  end if;
  n := n + 1;   -- …while the same service sold OUTSIDE the bundle still pays its fixed 700
  v_got := pg_temp.v825_line('quick_sale', 3000, 'service', c_facial, null, null, 1, 3000, c_kelvin, v_now);
  if v_got is distinct from 700 then
    raise exception 'D%: facial sold alone paid %c, expected its fixed 700c', n, v_got;
  end if;
  update public.services set commission_flat_cents = null where id = c_facial;

  n := n + 1;   -- bundle fixed 1000 over equal shares → 500 + 500, exactly once per bundle
  update public.bundles set commission_bps = null, commission_flat_cents = 1000 where id = c_bundle;
  v_sale := gen_random_uuid();
  insert into public.sales(id, business_id, client_id, kind, amount_cents, occurred_at, branch_id, staff_id)
  values (v_sale, c_biz, c_client, 'quick_sale', 8000, v_now, c_branch, c_kelvin);
  insert into public.sale_items(sale_id, business_id, item_type, ref_id, bundle_id, description, qty, unit_cents, line_cents)
  values (v_sale, c_biz, 'service', c_facial, c_bundle, 'facial · Rainbow special', 1, 4000, 4000),
         (v_sale, c_biz, 'service', c_spa,    c_bundle, 'spa · Rainbow special',    1, 4000, 4000);
  select sum(commission_cents)::integer, max(commission_cents), min(commission_flat_cents)
    into v_got, v_got2, v_cnt from public.sale_items where sale_id = v_sale;
  if v_got is distinct from 1000 or v_got2 is distinct from 500 or v_cnt is distinct from 500 then
    raise exception 'D%: bundle fixed 1000c paid % total (max line %, flat %), expected 1000 / 500 / 500', n, v_got, v_got2, v_cnt;
  end if;

  n := n + 1;   -- rounding remainder lands on the LAST member line: 100 over 2667/5333 → 33 + 67
  update public.bundles set commission_flat_cents = 100 where id = c_bundle;
  v_sale := gen_random_uuid();
  insert into public.sales(id, business_id, client_id, kind, amount_cents, occurred_at, branch_id, staff_id)
  values (v_sale, c_biz, c_client, 'quick_sale', 8000, v_now, c_branch, c_kelvin);
  insert into public.sale_items(sale_id, business_id, item_type, ref_id, bundle_id, description, qty, unit_cents, line_cents)
  values (v_sale, c_biz, 'service', c_facial, c_bundle, 'facial · Rainbow special', 1, 2667, 2667),
         (v_sale, c_biz, 'service', c_spa,    c_bundle, 'spa · Rainbow special',    1, 5333, 5333);
  select sum(commission_cents)::integer into v_got from public.sale_items where sale_id = v_sale;
  select commission_cents into v_got2 from public.sale_items where sale_id = v_sale and ref_id = c_facial;
  if v_got is distinct from 100 or v_got2 is distinct from 33 then
    raise exception 'D%: uneven bundle fixed paid % total (first line %), expected 100 / 33', n, v_got, v_got2;
  end if;

  n := n + 1;   -- two bundles in one basket (v204 writes one line set for qty 2): 2 × fixed
  v_sale := gen_random_uuid();
  insert into public.sales(id, business_id, client_id, kind, amount_cents, occurred_at, branch_id, staff_id)
  values (v_sale, c_biz, c_client, 'quick_sale', 16000, v_now, c_branch, c_kelvin);
  insert into public.sale_items(sale_id, business_id, item_type, ref_id, bundle_id, description, qty, unit_cents, line_cents)
  values (v_sale, c_biz, 'service', c_facial, c_bundle, 'facial · Rainbow special', 1, 8000, 8000),
         (v_sale, c_biz, 'service', c_spa,    c_bundle, 'spa · Rainbow special',    1, 8000, 8000);
  select sum(commission_cents)::integer into v_got from public.sale_items where sale_id = v_sale;
  if v_got is distinct from 200 then
    raise exception 'D%: two bundles at fixed 100c paid %c, expected 200c', n, v_got;
  end if;
  update public.bundles set commission_bps = null, commission_flat_cents = null where id = c_bundle;

  ---------------------------------------------------------------- E. one authority
  n := n + 1;   -- the v811 names resolve through v825
  select app.sale_item_commission_bps_v811(c_biz, 'service', c_facial, c_kelvin, v_now),
         app.sale_item_commission_bps_v825(c_biz, 'service', c_facial, null, null, c_kelvin, v_now)
    into v_got, v_got2;
  if v_got is distinct from v_got2 or v_got is distinct from 1000 then
    raise exception 'E%: v811 wrapper (%) and v825 (%) disagree', n, v_got, v_got2;
  end if;

  n := n + 1;   -- commission_starts_on still gates everything, bundles included
  update public.staff set commission_starts_on = (v_now at time zone 'Asia/Singapore')::date + 1 where id = c_kelvin;
  update public.bundles set commission_flat_cents = 1000 where id = c_bundle;
  v_got := pg_temp.v825_line('quick_sale', 4000, 'service', c_facial, null, c_bundle, 1, 4000, c_kelvin, v_now);
  if v_got is distinct from 0 then
    raise exception 'E%: a member before commission_starts_on was paid %c through a bundle', n, v_got;
  end if;
  update public.staff set commission_starts_on = null where id = c_kelvin;
  update public.bundles set commission_flat_cents = null where id = c_bundle;

  ---------------------------------------------------------------- F. the report reader
  -- A line-less sale (what a pre-v818 quick sale looks like) — its header snapshot is used.
  v_sale_bare := gen_random_uuid();
  insert into public.sales(id, business_id, client_id, kind, amount_cents, occurred_at, branch_id, staff_id)
  values (v_sale_bare, c_biz, c_client, 'quick_sale', 5000, v_now, c_branch, c_kelvin);

  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  select count(*), sum(r.commission_cents)::integer, min(r.staff_name)
    into v_cnt, v_got, v_txt
    from public.business_staff_commission_lines_v825(c_biz, null, v_now - interval '1 minute', v_now + interval '1 minute') r
   where r.sale_id = v_sale_bundle;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_cnt is distinct from 2 or v_got is distinct from 400 or v_txt is distinct from 'Kelvin' then
    raise exception 'F%: the report returned % lines paying %c to "%" for the bundle sale, expected 2 / 400c / Kelvin', n, v_cnt, v_got, v_txt;
  end if;

  n := n + 1;   -- the customer is named, the line is not reversed
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  select min(client_name), bool_or(reversed) into v_txt, v_bool
    from public.business_staff_commission_lines_v825(c_biz, null, v_now - interval '1 minute', v_now + interval '1 minute') r
   where r.sale_id = v_sale_bundle;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_txt is distinct from 'Debby' or v_bool is distinct from false then
    raise exception 'F%: bundle sale read as customer "%", reversed=%; expected Debby / false', n, v_txt, v_bool;
  end if;

  n := n + 1;   -- the line-less sale appears once, from its header snapshot (20% of 5000)
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  select count(*), min(commission_cents), bool_and(line_id is null) into v_cnt, v_got, v_bool
    from public.business_staff_commission_lines_v825(c_biz, null, v_now - interval '1 minute', v_now + interval '1 minute') r
   where r.sale_id = v_sale_bare;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_cnt is distinct from 1 or v_got is distinct from 1000 or v_bool is distinct from true then
    raise exception 'F%: line-less sale gave % rows / %c / header=%; expected 1 / 1000c / true', n, v_cnt, v_got, v_bool;
  end if;

  n := n + 1;   -- branch scope: the Orchard sale is not in Kopitiam 2''s report
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  select count(*) into v_cnt
    from public.business_staff_commission_lines_v825(c_biz, c_branch2, v_now - interval '1 minute', v_now + interval '1 minute') r
   where r.sale_id = v_sale_bundle;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_cnt <> 0 then
    raise exception 'F%: a Kopitiam 2 report contained an Orchard sale', n;
  end if;

  n := n + 1;   -- reversal: the sale stays, FLAGGED; the reversal row itself never appears
  perform set_config('app.sale_reversal_insert_id', v_reversal::text, true);
  perform set_config('app.sale_reversal_original_id', v_sale_bundle::text, true);
  insert into public.sales(id, business_id, client_id, kind, amount_cents, occurred_at, branch_id, staff_id,
                           reversal_of, reversal_reason, reversal_actor, reversal_idempotency_key)
  values (v_reversal, c_biz, c_client, 'quick_sale', -8000, v_now, c_branch, c_kelvin,
          v_sale_bundle, 'v825 suite: customer changed her mind', c_owner, 'v825-suite-' || v_reversal::text);
  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  select count(*) filter (where r.sale_id = v_sale_bundle),
         bool_and(r.reversed) filter (where r.sale_id = v_sale_bundle),
         min(r.reversal_reason) filter (where r.sale_id = v_sale_bundle),
         count(*) filter (where r.sale_id = v_reversal)
    into v_cnt, v_bool, v_txt, v_got
    from public.business_staff_commission_lines_v825(c_biz, null, v_now - interval '1 minute', v_now + interval '1 minute') r;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_cnt is distinct from 2 or v_bool is distinct from true or v_got <> 0
     or v_txt is distinct from 'v825 suite: customer changed her mind' then
    raise exception 'F%: after reversal: % original lines, reversed=%, reason="%", % reversal rows; expected 2 / true / the reason / 0', n, v_cnt, v_bool, v_txt, v_got;
  end if;

  n := n + 1;   -- a signed-in principal without view_finance is refused
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  begin
    perform 1 from public.business_staff_commission_lines_v825(c_biz, null, v_now - interval '1 minute', v_now + interval '1 minute');
    v_txt := 'allowed';
  exception when insufficient_privilege then
    v_txt := 'refused';
  end;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_txt <> 'refused' then
    raise exception 'F%: a stranger read the staff commission report', n;
  end if;

  ---------------------------------------------------------------- G. the one writer
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  v_json := public.business_set_catalogue_commission_v825(c_biz, 'product', c_pillow, 1234, null);
  perform public.business_set_catalogue_commission_v825(c_biz, 'bundle', c_bundle, null, 450);
  perform public.business_set_catalogue_commission_v825(c_biz, 'package', c_plan, 800, 100);
  reset role;
  perform set_config('request.jwt.claims', '', true);
  select commission_bps into v_got from public.products where id = c_pillow;
  select commission_flat_cents into v_got2 from public.bundles where id = c_bundle;
  select commission_bps * 1000 + commission_flat_cents into v_cnt from public.package_plans where id = c_plan;
  if v_json->>'status' is distinct from 'ok' or v_got is distinct from 1234
     or v_got2 is distinct from 450 or v_cnt is distinct from 800100 then
    raise exception 'G%: the writer did not land: product %, bundle flat %, package %', n, v_got, v_got2, v_cnt;
  end if;

  n := n + 1;   -- and it is audited
  select count(*) into v_cnt from public.audit_log
   where business_id = c_biz and action = 'CATALOGUE_COMMISSION_SET_V825' and entity_id in (c_pillow, c_bundle, c_plan);
  if v_cnt <> 3 then
    raise exception 'G%: expected 3 audit rows, found %', n, v_cnt;
  end if;

  n := n + 1;   -- range and kind are refused with 22023
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  v_cnt := 0;
  begin
    perform public.business_set_catalogue_commission_v825(c_biz, 'product', c_pillow, 20000, null);
  exception when invalid_parameter_value then v_cnt := v_cnt + 1;
  end;
  begin
    perform public.business_set_catalogue_commission_v825(c_biz, 'product', c_pillow, null, -1);
  exception when invalid_parameter_value then v_cnt := v_cnt + 1;
  end;
  begin
    perform public.business_set_catalogue_commission_v825(c_biz, 'service', c_facial, 100, null);
  exception when invalid_parameter_value then v_cnt := v_cnt + 1;
  end;
  begin
    perform public.business_set_catalogue_commission_v825(c_biz, 'product', gen_random_uuid(), 100, null);
  exception when invalid_parameter_value then v_cnt := v_cnt + 1;
  end;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_cnt <> 4 then
    raise exception 'G%: expected 4 typed refusals, got %', n, v_cnt;
  end if;

  n := n + 1;   -- a stranger cannot price commission
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  begin
    perform public.business_set_catalogue_commission_v825(c_biz, 'product', c_pillow, 100, null);
    v_txt := 'allowed';
  exception when insufficient_privilege then v_txt := 'refused';
  end;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_txt <> 'refused' then
    raise exception 'G%: a stranger set a product commission', n;
  end if;

  ---------------------------------------------------------------- H. a sold bundle cannot be deleted
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  begin
    perform public.delete_service_bundle_v285(c_biz, c_bundle);
    v_txt := 'deleted';
  exception when foreign_key_violation then v_txt := sqlerrm;
  end;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if position('bundle_has_sales' in v_txt) = 0 then
    raise exception 'H%: deleting a sold bundle answered "%", expected bundle_has_sales', n, v_txt;
  end if;

  raise notice 'nestly_v827: % / % assertions passed', n, n;
end
$suite$;

rollback;
