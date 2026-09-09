-- Rollback-only acceptance for nestly_v861 — a typed-in "Other item" pays no commission.
--   supabase db query --linked -f db/tests/v861_custom_lines_pay_no_commission.sql
--   C1  a till sale with a service (member 10%) and an Other item, rung for a member: the
--       service pays, the custom line pays 0, the report shows the custom line at 0%
--   C2  no custom line anywhere still carries commission (the backfill held)
-- NEGATIVE CONTROL: before v861, C1 fails (the custom line pays the member's product %).
begin;
do $suite$
declare
  q_biz constant uuid := '8ad4a375-2d42-4e0d-b509-b0e4ed6ccf8c'; q_owner constant uuid := 'f73a9423-33fd-424c-9fb9-2d5ba058a2d7';
  q_branch constant uuid := '3f3a88f0-a154-4b50-925b-41c0e93c6321'; q_client constant uuid := '15237428-9a61-4e19-8339-2a98ef8c32d6';
  q_toast constant uuid := '5c2426c8-e363-4486-88ed-e8622f42f066';
  v_mei uuid; v_lines jsonb; v_eval jsonb; v_res jsonb; v_sale uuid; v_cnt int; n int := 0;
begin
  insert into public.staff(business_id, user_id, role, full_name, active, commission_service_bps, commission_product_bps)
  values (q_biz, null, 'staff', 'Mei (suite)', true, 1000, 500) returning id into v_mei;
  update public.services set commission_bps = null, commission_flat_cents = null where id = q_toast;
  n := n + 1;
  v_lines := jsonb_build_array(
    jsonb_build_object('catalog_kind','service','catalog_id',q_toast,'qty',1),
    jsonb_build_object('catalog_kind','custom','description','Delivery','amount_cents',1000,'reason','suite','qty',1));
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',q_owner,'role','authenticated')::text, true);
  v_eval := public.evaluate_checkout(q_biz, q_branch, q_client, v_lines, gen_random_uuid(), null::uuid, false);
  v_res := public.record_cart_sale(q_biz, q_client, q_branch, v_mei, 'cash', 'v861-'||gen_random_uuid()::text,
    v_lines, (v_eval->>'evaluation_id')::uuid, true, now(), '[]'::jsonb)::jsonb;
  v_sale := (v_res->>'sale_id')::uuid;
  select count(*) into v_cnt from public.business_staff_commission_lines_v825(q_biz, null, now() - interval '1 minute', now() + interval '1 minute') r
   where r.sale_id = v_sale and r.item_type = 'custom' and r.commission_cents = 0 and coalesce(r.rate_bps,0) = 0;
  reset role; perform set_config('request.jwt.claims','',true);
  if v_sale is null then raise exception 'C%: no sale (%)', n, left(v_res::text,200); end if;
  if (select commission_cents from public.sale_items where sale_id = v_sale and item_type = 'service') <> 38
     or (select commission_cents from public.sale_items where sale_id = v_sale and item_type = 'custom') <> 0
     or v_cnt <> 1 then
    raise exception 'C%: expected service 38 (10%% of 380) and Other item 0; got %', n,
      (select string_agg(item_type||':'||commission_cents, ' | ') from public.sale_items where sale_id = v_sale);
  end if;
  n := n + 1;
  if exists (select 1 from public.sale_items where item_type = 'custom' and coalesce(commission_cents,0) <> 0) then
    raise exception 'C%: a custom line still pays commission', n;
  end if;
  raise notice 'nestly_v861: % / % assertions passed', n, n;
end
$suite$;
rollback;
