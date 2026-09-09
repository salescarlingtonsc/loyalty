-- Rollback-only end-to-end walk of STAFF COMMISSION ACCURACY, run as the REAL principals.
--   supabase db query --linked -f db/tests/v850_commission_accuracy_end_to_end.sql
--
-- OWNER REQUEST (2026-09-09): "verify the end to end sales commission works perfectly with data
-- accuracy ... test the different variations, from setting commission on product / services /
-- package / bundles > ensure staff commission is accurate."
--
-- Every sale is rung through the real till RPCs as the owner, attributed to a rota-only team
-- member "Mei" (services 10%, products 5%), on QA Kopi Lab; the discount case runs on AhXiang
-- (services 8%, products 20%, a VVVIP customer with an automatic 20% tier discount). Expected
-- figures are computed here from the RATES and the PRICES, never read back from the engine.
--
--   V1  one sale, five kinds of line, one member:
--         service with its own 20%   Kaya Toast 380 × 2 = 760  →  152
--         service with $1.00 fixed   Kopi Set 1500            →  100   (fixed beats %)
--         product with $0.50 fixed   Kaya Jar 800 × 3         →  150   (fixed × qty)
--         product, blank             Kopi Powder 1200         →   60   (member's product 5%)
--         custom "Delivery" 1000                              →    0   (nestly_v861: a typed-in line pays nothing)
--       sale total 6,860, commission 462; the header staff is Mei on every line
--   V2  bundle with its own 8%: every member line pays floor(line × 8%), whatever the members'
--       own rates say
--   V3  bundle with a $2.00 fixed amount: the lines sum to exactly 200 (last line absorbs
--       the rounding), and NOT 200 per line
--   V4  package sold to Mei via the till's seller RPC: pays the package's own 15% ONCE
--       (1600 → 240) to MEI, not to the owner who was logged in; a session use pays 0
--   V5  a member whose commission starts tomorrow is paid 0 on today's sale
--   V6  discount (AhXiang): two services at 8% (20000 + 45000), automatic 20% off → the
--       discount line reduces commission at 8% (−13000 × 8% = −1040), so the member nets
--       exactly 8% of the 52,000 the customer paid
--   V7  reversing V1: the reversal row's commission is −512 in public.sale_commission and the
--       report flags every V1 line reversed
--   V8  three readers agree per sale: Σ sale_items = sale_commission view = Σ report rows
--   V9  per member: the report's counted commission for Mei equals the sum of her non-reversed
--       lines, and the owner is paid nothing for the package Mei sold
--
-- NEGATIVE CONTROL: on the database before nestly_v850 (applied as v832; objects keep _v832), V6 fails (the discount line is charged
-- at the member's 20% product rate: −2600, and V4 fails (the package pays the owner).

begin;

do $suite$
declare
  q_biz    constant uuid := '8ad4a375-2d42-4e0d-b509-b0e4ed6ccf8c';   -- QA Kopi Lab
  q_owner  constant uuid := 'f73a9423-33fd-424c-9fb9-2d5ba058a2d7';
  q_owner_staff constant uuid := 'aa8aa260-62ad-49a8-bb70-226b61a7ada3';
  q_branch constant uuid := '3f3a88f0-a154-4b50-925b-41c0e93c6321';
  q_client constant uuid := '15237428-9a61-4e19-8339-2a98ef8c32d6';   -- no tier, no auto discount
  q_kopi   constant uuid := '49d40266-3523-4377-9ca6-c11b0a4a6066';   -- Kopi Set 1500
  q_toast  constant uuid := '5c2426c8-e363-4486-88ed-e8622f42f066';   -- Kaya Toast Set 380
  q_powder constant uuid := '4597e6be-af6e-49bc-800f-43536775acd4';   -- Kopi Powder 1200
  q_jar    constant uuid := 'b857b282-827d-43c3-ac6a-8b5e1cf71265';   -- Kaya Jar 800
  q_plan   constant uuid := '3bd23bd6-eafe-40ba-b7fc-f900d607d3bb';   -- 5x Kaya Toast Set 1600
  a_biz    constant uuid := '33773caa-6d51-4cf2-9ad6-b83f015759e6';   -- AhXiang
  a_owner  constant uuid := '05e0e55f-3c53-49ac-b57b-09aeab6d5417';
  a_branch constant uuid := '868664ba-06ea-436c-9f67-a196ca4037c6';
  a_vvvip  constant uuid := '1e0f723c-b772-4115-95f7-401203ab48a6';
  a_svc200 constant uuid := '00b3e697-14a3-43c5-9c94-69ccc89061e9';
  a_svc450 constant uuid := '223fc970-4e97-4a8f-9d0a-3f2d1a5b6c7e';
  v_a_svc450 uuid; v_a_staff uuid;
  v_mei uuid; v_later uuid; v_bundle uuid;
  v_eval jsonb; v_res jsonb; v_lines jsonb;
  v_s1 uuid; v_s2 uuid; v_s3 uuid; v_s4 uuid; v_s5 uuid; v_s6 uuid; v_cp uuid;
  v_n int; v_sum bigint; v_sum2 bigint; v_bad int; v_txt text;
  n int := 0;
begin
  -- fixtures ------------------------------------------------------------------------------
  insert into public.staff(business_id, user_id, role, full_name, active, commission_service_bps, commission_product_bps)
  values (q_biz, null, 'staff', 'Mei (suite)', true, 1000, 500) returning id into v_mei;
  insert into public.staff(business_id, user_id, role, full_name, active, commission_service_bps, commission_product_bps, commission_starts_on)
  values (q_biz, null, 'staff', 'Later (suite)', true, 1000, 500, (timezone('Asia/Singapore', now()))::date + 1) returning id into v_later;
  update public.services set commission_bps = 2000, commission_flat_cents = null where id = q_toast;
  update public.services set commission_bps = null, commission_flat_cents = 100 where id = q_kopi;
  select id into v_a_svc450 from public.services where business_id = a_biz and price_cents = 45000 and active limit 1;
  select id into v_a_staff from public.staff where business_id = a_biz and user_id = a_owner and active limit 1;
  if v_a_svc450 is null or v_a_staff is null then raise exception 'fixture drift: AhXiang $450 service or owner staff row missing'; end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',q_owner,'role','authenticated')::text, true);
  perform public.business_set_catalogue_commission_v825(q_biz, 'product', q_jar, null, 50);
  perform public.business_set_catalogue_commission_v825(q_biz, 'product', q_powder, null, null);
  perform public.business_set_catalogue_commission_v825(q_biz, 'package', q_plan, 1500, null);
  v_res := public.create_service_bundle_v123(q_biz, 'Breakfast Duo (suite)', 1700, array[q_kopi, q_toast], 'v832-bundle-'||gen_random_uuid()::text);
  reset role; perform set_config('request.jwt.claims','',true);
  v_bundle := coalesce(nullif(v_res->>'bundle_id',''), nullif(v_res->>'id',''))::uuid;
  if v_bundle is null then
    select id into v_bundle from public.bundles where business_id = q_biz and name = 'Breakfast Duo (suite)';
  end if;
  if v_bundle is null then raise exception 'fixture: bundle was not created (%)', left(v_res::text,200); end if;

  -- V1 five kinds of line ------------------------------------------------------------------
  n := n + 1;
  v_lines := jsonb_build_array(
    jsonb_build_object('catalog_kind','service','catalog_id',q_toast,'qty',2),
    jsonb_build_object('catalog_kind','service','catalog_id',q_kopi,'qty',1),
    jsonb_build_object('catalog_kind','product','catalog_id',q_jar,'qty',3),
    jsonb_build_object('catalog_kind','product','catalog_id',q_powder,'qty',1),
    jsonb_build_object('catalog_kind','custom','description','Delivery','amount_cents',1000,'reason','suite','qty',1));
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',q_owner,'role','authenticated')::text, true);
  v_eval := public.evaluate_checkout(q_biz, q_branch, q_client, v_lines, gen_random_uuid(), null::uuid, false);
  if v_eval->>'status' <> 'ok' then raise exception 'V%: evaluate refused: %', n, left(v_eval::text,300); end if;
  v_res := public.record_cart_sale(q_biz, q_client, q_branch, v_mei, 'cash', 'v832-s1-'||gen_random_uuid()::text,
    v_lines, (v_eval->>'evaluation_id')::uuid, true, now(), '[]'::jsonb)::jsonb;
  reset role; perform set_config('request.jwt.claims','',true);
  v_s1 := (v_res->>'sale_id')::uuid;
  if v_s1 is null then raise exception 'V%: no sale (%)', n, left(v_res::text,300); end if;
  select string_agg(item_type||':'||line_cents||':'||coalesce(commission_rate_bps::text,'-')||':'||coalesce(commission_flat_cents::text,'-')||':'||commission_cents, ' | ' order by line_cents desc, item_type)
    into v_txt from public.sale_items where sale_id = v_s1;
  if (select amount_cents from public.sales where id = v_s1) <> 6860
     or (select count(*) from public.sale_items where sale_id = v_s1 and item_type='service' and ref_id=q_toast and line_cents=760 and commission_rate_bps=2000 and commission_cents=152) <> 1
     or (select count(*) from public.sale_items where sale_id = v_s1 and item_type='service' and ref_id=q_kopi and line_cents=1500 and commission_flat_cents=100 and commission_cents=100) <> 1
     or (select count(*) from public.sale_items where sale_id = v_s1 and item_type='retail' and coalesce(product_id,ref_id)=q_jar and line_cents=2400 and commission_flat_cents=50 and commission_cents=150) <> 1
     or (select count(*) from public.sale_items where sale_id = v_s1 and item_type='retail' and coalesce(product_id,ref_id)=q_powder and line_cents=1200 and commission_rate_bps=500 and commission_cents=60) <> 1
     or (select count(*) from public.sale_items where sale_id = v_s1 and item_type='custom' and line_cents=1000 and commission_cents=0) <> 1
     or (select sum(commission_cents) from public.sale_items where sale_id = v_s1) <> 462
     or (select staff_id from public.sales where id = v_s1) <> v_mei then
    raise exception 'V%: five-line sale is not 152/100/150/60/0 = 462 on 6860 for Mei; got %', n, v_txt;
  end if;

  -- V2 bundle % override ---------------------------------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',q_owner,'role','authenticated')::text, true);
  perform public.business_set_catalogue_commission_v825(q_biz, 'bundle', v_bundle, 800, null);
  v_lines := jsonb_build_array(jsonb_build_object('catalog_kind','bundle','catalog_id',v_bundle,'qty',1));
  v_eval := public.evaluate_checkout(q_biz, q_branch, q_client, v_lines, gen_random_uuid(), null::uuid, false);
  if v_eval->>'status' <> 'ok' then raise exception 'V%: bundle evaluate refused: %', n, left(v_eval::text,300); end if;
  v_res := public.record_cart_sale(q_biz, q_client, q_branch, v_mei, 'cash', 'v832-s2-'||gen_random_uuid()::text,
    v_lines, (v_eval->>'evaluation_id')::uuid, true, now(), '[]'::jsonb)::jsonb;
  reset role; perform set_config('request.jwt.claims','',true);
  v_s2 := (v_res->>'sale_id')::uuid;
  select count(*), coalesce(sum(line_cents),0) into v_n, v_sum from public.sale_items where sale_id = v_s2 and bundle_id = v_bundle;
  if v_s2 is null or v_n <> 2 or v_sum <> 1700
     or exists (select 1 from public.sale_items where sale_id = v_s2 and bundle_id = v_bundle
                  and (commission_rate_bps <> 800 or commission_cents <> floor(line_cents::numeric * 800 / 10000)::int)) then
    raise exception 'V%: bundle 8%% override not applied per member line (% lines, Σ %)', n, v_n, v_sum;
  end if;

  -- V3 bundle fixed amount -------------------------------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',q_owner,'role','authenticated')::text, true);
  perform public.business_set_catalogue_commission_v825(q_biz, 'bundle', v_bundle, null, 200);
  v_eval := public.evaluate_checkout(q_biz, q_branch, q_client, v_lines, gen_random_uuid(), null::uuid, false);
  v_res := public.record_cart_sale(q_biz, q_client, q_branch, v_mei, 'cash', 'v832-s3-'||gen_random_uuid()::text,
    v_lines, (v_eval->>'evaluation_id')::uuid, true, now(), '[]'::jsonb)::jsonb;
  reset role; perform set_config('request.jwt.claims','',true);
  v_s3 := (v_res->>'sale_id')::uuid;
  select count(*), coalesce(sum(commission_cents),0) into v_n, v_sum from public.sale_items where sale_id = v_s3 and bundle_id = v_bundle;
  if v_s3 is null or v_n <> 2 or v_sum <> 200
     or (select max(commission_cents) from public.sale_items where sale_id = v_s3) >= 200 then
    raise exception 'V%: bundle $2.00 fixed should sum to exactly 200 across 2 lines; got Σ % over % lines', n, v_sum, v_n;
  end if;

  -- V4 package pays who sold it, once -------------------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',q_owner,'role','authenticated')::text, true);
  begin
    v_res := public.sell_package_v832(q_biz, q_client, q_plan, q_branch, gen_random_uuid(), v_mei);
  exception when undefined_function then
    v_res := public.sell_package_v102(q_biz, q_client, q_plan, q_branch, gen_random_uuid());
  end;
  v_s4 := (v_res->>'sale_id')::uuid; v_cp := (v_res->>'client_package_id')::uuid;
  perform public.use_package_session_v102(q_biz, v_cp, q_branch, 'v832-use-'||gen_random_uuid()::text);
  reset role; perform set_config('request.jwt.claims','',true);
  if v_s4 is null then raise exception 'V%: package sale failed (%)', n, left(v_res::text,300); end if;
  if (select staff_id from public.sales where id = v_s4) is distinct from v_mei
     or (select count(*) from public.sale_items where sale_id = v_s4 and item_type='package' and ref_id=q_plan
           and coalesce(staff_id, v_mei) = v_mei and commission_rate_bps=1500 and commission_cents=240) <> 1 then
    raise exception 'V%: the package should pay Mei 15%% of 1600 = 240 once; sale staff=%, lines: %', n,
      (select staff_id from public.sales where id = v_s4),
      (select string_agg(item_type||':'||coalesce(staff_id::text,'-')||':'||commission_cents, ' | ') from public.sale_items where sale_id = v_s4);
  end if;
  if exists (select 1 from public.sale_items where item_type='package_session' and ref_id = v_cp and commission_cents <> 0)
     or exists (select 1 from public.sale_items si join public.sales s on s.id=si.sale_id where s.client_id=q_client and si.item_type='package_session' and si.created_at > now() - interval '1 minute' and si.commission_cents <> 0) then
    raise exception 'V%: a package session use paid commission', n;
  end if;

  -- V5 commission starts tomorrow -------------------------------------------------------------
  n := n + 1;
  v_lines := jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',q_toast,'qty',1));
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',q_owner,'role','authenticated')::text, true);
  v_eval := public.evaluate_checkout(q_biz, q_branch, q_client, v_lines, gen_random_uuid(), null::uuid, false);
  v_res := public.record_cart_sale(q_biz, q_client, q_branch, v_later, 'cash', 'v832-s5-'||gen_random_uuid()::text,
    v_lines, (v_eval->>'evaluation_id')::uuid, true, now(), '[]'::jsonb)::jsonb;
  reset role; perform set_config('request.jwt.claims','',true);
  v_s5 := (v_res->>'sale_id')::uuid;
  if v_s5 is null or (select sum(commission_cents) from public.sale_items where sale_id = v_s5) <> 0 then
    raise exception 'V%: a member whose commission starts tomorrow was paid today', n;
  end if;

  -- V6 discount reduces commission at the bill's own rate ---------------------------------------
  n := n + 1;
  v_lines := jsonb_build_array(
    jsonb_build_object('catalog_kind','service','catalog_id',a_svc200,'qty',1),
    jsonb_build_object('catalog_kind','service','catalog_id',v_a_svc450,'qty',1));
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',a_owner,'role','authenticated')::text, true);
  v_eval := public.evaluate_checkout(a_biz, a_branch, a_vvvip, v_lines, gen_random_uuid(), null::uuid, false);
  if v_eval->>'status' <> 'ok' or (v_eval->>'discount_total_cents')::int <> 13000 then
    raise exception 'V%: expected the automatic 20%% (13000) on 65000; got %', n, left(v_eval::text,300);
  end if;
  v_res := public.record_cart_sale(a_biz, a_vvvip, a_branch, v_a_staff, 'cash', 'v832-s6-'||gen_random_uuid()::text,
    v_lines, (v_eval->>'evaluation_id')::uuid, true, now(), '[]'::jsonb)::jsonb;
  reset role; perform set_config('request.jwt.claims','',true);
  v_s6 := (v_res->>'sale_id')::uuid;
  select string_agg(item_type||':'||line_cents||':'||coalesce(commission_rate_bps::text,'-')||':'||commission_cents, ' | ' order by line_cents desc) into v_txt
    from public.sale_items where sale_id = v_s6;
  if v_s6 is null
     or (select sum(commission_cents) from public.sale_items where sale_id = v_s6 and line_cents > 0) <> 5200
     or (select count(*) from public.sale_items where sale_id = v_s6 and item_type='studio_discount' and line_cents = -13000
           and commission_rate_bps = 800 and commission_cents = -1040) <> 1
     or (select sum(commission_cents) from public.sale_items where sale_id = v_s6) <> 4160 then
    raise exception 'V%: 8%% of the 52000 paid = 4160 expected (lines 5200, discount −1040 at 8%%); got %', n, v_txt;
  end if;

  -- V7 reversal ---------------------------------------------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',q_owner,'role','authenticated')::text, true);
  v_res := public.reverse_sale(q_biz, v_s1, 'suite reversal', 'v832-rev-'||gen_random_uuid()::text, null, null);
  select coalesce(sum(sc.commission_cents),0) into v_sum from public.sale_commission sc where sc.business_id = q_biz and sc.sale_id in (select id from public.sales where reversal_of = v_s1);
  select count(*), count(*) filter (where r.reversed) into v_n, v_bad
    from public.business_staff_commission_lines_v825(q_biz, null, now() - interval '2 minutes', now() + interval '2 minutes') r where r.sale_id = v_s1;
  reset role; perform set_config('request.jwt.claims','',true);
  if not exists (select 1 from public.sales where reversal_of = v_s1) then raise exception 'V%: reversal did not create a row (%)', n, left(v_res::text,300); end if;
  if v_sum <> -462 then raise exception 'V%: the reversal row carries % commission in sale_commission (expected −462)', n, v_sum; end if;
  if v_n <> 5 or v_bad <> 5 then raise exception 'V%: report shows % of % V1 lines reversed (expected 5 of 5)', n, v_bad, v_n; end if;

  -- V8 three readers agree per sale -------------------------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',q_owner,'role','authenticated')::text, true);
  select count(*) into v_bad from (
    select s.id,
           (select sum(li.commission_cents) from public.sale_items li where li.sale_id = s.id) as lines_sum,
           (select sc.commission_cents from public.sale_commission sc where sc.sale_id = s.id) as view_sum,
           (select sum(r.commission_cents) from public.business_staff_commission_lines_v825(q_biz, null, now() - interval '2 minutes', now() + interval '2 minutes') r where r.sale_id = s.id) as report_sum
      from public.sales s where s.id in (v_s1, v_s2, v_s3, v_s4, v_s5)) x
   where x.lines_sum is distinct from x.view_sum or x.lines_sum is distinct from x.report_sum;
  reset role; perform set_config('request.jwt.claims','',true);
  if v_bad <> 0 then raise exception 'V%: % sales where sale_items, sale_commission and the report disagree', n, v_bad; end if;

  -- V9 per member ----------------------------------------------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',q_owner,'role','authenticated')::text, true);
  select coalesce(sum(r.commission_cents) filter (where not r.reversed and r.staff_id = v_mei),0),
         coalesce(sum(r.commission_cents) filter (where not r.reversed and r.staff_id = q_owner_staff and r.sale_id in (v_s1,v_s2,v_s3,v_s4,v_s5)),0)
    into v_sum, v_sum2
    from public.business_staff_commission_lines_v825(q_biz, null, now() - interval '2 minutes', now() + interval '2 minutes') r;
  reset role; perform set_config('request.jwt.claims','',true);
  select coalesce(sum(li.commission_cents),0) into v_n from public.sale_items li join public.sales s on s.id = li.sale_id
   where s.id in (v_s2, v_s3, v_s4) and coalesce(li.staff_id, s.staff_id) = v_mei;
  if v_sum <> v_n or v_sum <> (select sum(commission_cents) from public.sale_items where sale_id in (v_s2,v_s3)) + 240 then
    raise exception 'V%: Mei''s counted commission on the page is % but her non-reversed lines sum to %', n, v_sum, v_n;
  end if;
  if v_sum2 <> 0 then raise exception 'V%: the owner is paid % for sales Mei made', n, v_sum2; end if;

  raise notice 'v832 commission accuracy: % / % assertions passed', n, n;
end
$suite$;

rollback;
