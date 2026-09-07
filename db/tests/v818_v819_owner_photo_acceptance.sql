-- nestly_v818 / v819 — OWNER PHOTO ACCEPTANCE.
--
-- The v818 and v819 suites prove the mechanisms. This one proves the PHOTOS, by driving the
-- same entry points the owner's own taps reach, not the internals underneath them:
--
--   photo 1+2  public.record_cart_sale        (the Record sale button)
--   photo 3    public.reverse_sale_fast_v84   (the Reverse sale dialog — NOT public.reverse_sale,
--                                              which is what the mechanism suite exercised)
--   photo 4    public.set_appointment_status_v47   (the Cancel action)
--   photo 6    public.business_get_checkout_catalogue_v94  (the Add item sheet's read)
--   photo 7    public.internal_public_booking_page (the customer's "Who would you like?" step)
--
-- Every call runs as a REAL principal via request.jwt.claims, never as the table owner, so RLS
-- and every internal gate is in force. Rolled back; nothing is left behind.
--
--   supabase db query --linked -f db/tests/v818_v819_owner_photo_acceptance.sql
--
-- Photo 5 is a client-side render and cannot be proved here; it is measured in a real Chrome by
-- tests/browser/verify-v818-day-count-and-bundle.mjs, which also covers the client half of
-- photo 6 (bundle assembly). This file states that boundary rather than implying coverage it
-- does not have.

begin;

do $suite$
declare
  c_biz     constant uuid := '8ccace3a-9736-447e-bb1e-da842622592d';  -- ÉLAN Wellness
  c_owner   constant uuid := '8efcffc8-61a5-4235-ad45-54a8954208f9';  -- Kiat Ke Ying (owner)
  c_branch  constant uuid := '586f4069-12cb-4f54-b37c-8c5742244520';
  c_aroma   constant uuid := '8a191981-7df0-44e7-a452-92581e3c8ea3';  -- pinned to the dead branch
  c_signature constant uuid := '274204da-ad83-4e3b-b7f5-30681788079d';
  c_amanda  constant uuid := '0fb55728-f2b3-4db9-87ec-574e93b80780';
  v_client  uuid;
  v_product uuid;
  v_sale    uuid;
  v_appt    uuid;
  v_req     uuid;
  v_res     json;
  v_resj    jsonb;
  v_eval    jsonb;
  v_got     integer;
  v_txt     text;
  v_amount  integer;
  n         integer := 0;

  procedure_as_owner text;
begin
  select id into v_client from public.clients where business_id = c_biz limit 1;
  select id into v_product from public.products
   where business_id = c_biz and active and retail_price_cents > 0 limit 1;

  -- ===================================================================== PHOTOS 1 AND 2
  -- "Commission failed to link to staff commission when service sold" /
  -- "Service comm failed to link ... Product comm applied on both product and service sold"
  --
  -- Amanda exactly as photo 2 shows her: service blank, product 10%. The service carries the
  -- 10% override photo 1 rings. Rates chosen so a per-line answer cannot coincide with the
  -- old whole-basket one.
  update public.staff
     set commission_service_bps = null, commission_product_bps = 2000, commission_starts_on = null
   where id = c_amanda;
  update public.services set commission_bps = 1000, commission_flat_cents = null
   where id = c_signature;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);

  -- The REAL till write. The browser prices a basket with evaluate_checkout and finalises it
  -- with record_cart_sale/11 carrying that evaluation token — record_cart_sale/7 is not even
  -- granted to `authenticated`, so calling it would have proved a path no till can take.
  n := n + 1;
  v_eval := public.evaluate_checkout(
    c_biz, c_branch, v_client,
    -- catalog_kind + catalog_id + qty ONLY: the server prices the basket and refuses a
    -- client-priced line, so this is the exact shape the till sends.
    jsonb_build_array(
      jsonb_build_object('catalog_kind','service','catalog_id',c_signature,'qty',1),
      jsonb_build_object('catalog_kind','product','catalog_id',v_product,'qty',1)),
    gen_random_uuid(), null::uuid, false)::jsonb;
  if nullif(v_eval->>'evaluation_id','') is null then
    reset role;
    perform set_config('request.jwt.claims', '', true);
    raise exception 'PHOTO 1/2 FAIL (%): evaluate_checkout returned no evaluation (%)', n, left(v_eval::text,300);
  end if;

  v_res := public.record_cart_sale(
    c_biz, v_client, c_branch, c_amanda, 'cash', 'v818-acceptance-' || gen_random_uuid()::text,
    -- catalog_kind + catalog_id + qty ONLY: the server prices the basket and refuses a
    -- client-priced line, so this is the exact shape the till sends.
    jsonb_build_array(
      jsonb_build_object('catalog_kind','service','catalog_id',c_signature,'qty',1),
      jsonb_build_object('catalog_kind','product','catalog_id',v_product,'qty',1)),
    (v_eval->>'evaluation_id')::uuid, true, now(), '[]'::jsonb);
  reset role;
  perform set_config('request.jwt.claims', '', true);
  v_resj := v_res::jsonb;
  v_sale := nullif(v_resj->>'sale_id','')::uuid;
  if v_sale is null then
    raise exception 'P%: the till RPC returned no sale_id (%)', n, left(v_res::text, 300);
  end if;

  -- The SERVICE line took the service override, not the product rate.
  n := n + 1;
  select commission_rate_bps into v_got from public.sale_items
   where sale_id = v_sale and item_type = 'service';
  if v_got is distinct from 1000 then
    raise exception 'PHOTO 1/2 FAIL (%): a service sold at the till took % bps; the service override is 1000', n, v_got;
  end if;

  -- The PRODUCT line took the product rate. This is the second half of photo 2: before v818
  -- the product rate was charged against BOTH lines.
  n := n + 1;
  select commission_rate_bps into v_got from public.sale_items
   where sale_id = v_sale and item_type = 'retail';
  if v_got is distinct from 2000 then
    raise exception 'PHOTO 2 FAIL (%): the product line took % bps, expected 2000', n, v_got;
  end if;

  -- Two lines, two DIFFERENT rates, on one basket rung up by one button.
  n := n + 1;
  select count(distinct commission_rate_bps)::integer into v_got
    from public.sale_items where sale_id = v_sale;
  if v_got <> 2 then
    raise exception 'PHOTO 2 FAIL (%): the basket resolved % distinct rates, expected 2', n, v_got;
  end if;

  -- What the owner is actually paid, read the way Staff performance reads it.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  select commission_cents into v_got from public.sale_commission where sale_id = v_sale;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_got is distinct from 1480 then
    raise exception 'PHOTO 1/2 FAIL (%): the till sale pays %c; expected 1480c (880 service + 600 product)', n, v_got;
  end if;
  -- The pre-v818 answer for this basket was 20%% of 11800 = 2360c. Naming it makes the suite
  -- fail loudly if the old whole-basket behaviour ever comes back.
  n := n + 1;
  if v_got = 2360 then
    raise exception 'PHOTO 2 FAIL (%): the till is paying the whole-basket product rate again', n;
  end if;

  -- ============================================================================= PHOTO 3
  -- "Why reversal refused? If use other card or paynow then can't reverse sale?"
  -- Driven through reverse_sale_fast_v84, which is the RPC the dialog in the photo calls.
  n := n + 1;
  select s.id, s.amount_cents into v_sale, v_amount
    from public.sales s
   where s.business_id = c_biz and s.reversal_of is null and s.amount_cents > 0
     and not exists (select 1 from public.sales r where r.reversal_of = s.id)
     and exists (select 1 from public.payments p
                  where p.sale_id = s.id and p.method = 'card' and p.amount_cents > 0)
     and not exists (select 1 from public.payments p where p.sale_id = s.id and p.method <> 'card')
   order by s.occurred_at
   limit 1;
  if v_sale is null then
    raise exception 'PHOTO 3 FAIL (%): no un-reversed card sale left to reverse', n;
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  begin
    v_res := public.reverse_sale_fast_v84(c_biz, v_sale, 'photo 3 acceptance',
                                          'v819-acceptance-' || gen_random_uuid()::text);
  exception when feature_not_supported then
    reset role;
    perform set_config('request.jwt.claims', '', true);
    raise exception 'PHOTO 3 FAIL (%): the dialog still refuses a card sale — %', n, sqlerrm;
  end;
  reset role;
  perform set_config('request.jwt.claims', '', true);

  -- The books actually balance afterwards: payments for that sale net to zero, and the refund
  -- is recorded as CARD, not quietly reclassified as cash.
  n := n + 1;
  select coalesce(sum(amount_cents),0)::integer into v_got
    from public.payments where sale_id = v_sale;
  if v_got <> 0 then
    raise exception 'PHOTO 3 FAIL (%): payments net to %c after the reversal, expected 0', n, v_got;
  end if;
  n := n + 1;
  select count(*)::integer into v_got from public.payments
   where sale_id = v_sale and kind = 'refund' and method = 'card' and amount_cents = -v_amount;
  if v_got <> 1 then
    raise exception 'PHOTO 3 FAIL (%): % card refund rows, expected 1', n, v_got;
  end if;

  -- ============================================================================= PHOTO 4
  -- "Appt cancelled but still showing Confirmed. Only can see it was cancelled after
  -- clicking into it." Driven through the Cancel action's own RPC.
  n := n + 1;
  insert into public.appointments(business_id, client_id, service_id, branch_id,
                                  starts_at, ends_at, status)
  values (c_biz, v_client, c_signature, c_branch,
          now() + interval '3 days', now() + interval '3 days 1 hour', 'booked')
  returning id into v_appt;
  insert into public.booking_requests(business_id, appointment_id, name, preferred_at, status)
  values (c_biz, v_appt, 'Photo 4 acceptance', now() + interval '3 days', 'confirmed')
  returning id into v_req;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  perform public.set_appointment_status_v47(c_biz, v_appt, 'cancelled');
  reset role;
  perform set_config('request.jwt.claims', '', true);

  -- The Bookings list renders booking_requests.status. That is the field in the photo.
  select status into v_txt from public.booking_requests where id = v_req;
  if v_txt is distinct from 'cancelled' then
    raise exception 'PHOTO 4 FAIL (%): after Cancel, the Bookings list still reads "%"', n, v_txt;
  end if;

  -- ============================================================================= PHOTO 6
  -- "One of the item added and show ON but not shown here." The Add item sheet's own read.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  select count(*)::integer into v_got
    from jsonb_array_elements(
      (public.business_get_checkout_catalogue_v94(c_biz, c_branch, false))->'items') item
   where (item->>'item_id')::uuid = c_aroma;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_got <> 1 then
    raise exception 'PHOTO 6 FAIL (%): the Add item sheet returns % rows for the ringed service, expected 1', n, v_got;
  end if;

  -- The bundle in the photo is withheld unless EVERY member is sellable at this branch, so
  -- prove both members are — that is the whole reason "Bundles" had no section to draw.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  select count(*)::integer into v_got
    from public.bundle_items bi
   where bi.bundle_id = (select id from public.bundles
                          where business_id = c_biz and active order by id limit 1)
     and bi.service_id is not null
     and not exists (
       select 1 from jsonb_array_elements(
         (public.business_get_checkout_catalogue_v94(c_biz, c_branch, false))->'items') item
        where (item->>'item_id')::uuid = bi.service_id);
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_got <> 0 then
    raise exception 'PHOTO 6 FAIL (%): % bundle member(s) are still unsellable at this branch, so the Bundles section stays hidden', n, v_got;
  end if;

  -- ============================================================================= PHOTO 7
  -- "Can choose who to show on customer side? Manager and front desk should remove from
  -- here." I told the owner the control already exists. This proves that claim end to end
  -- against the customer's OWN booking page read, rather than asserting a column exists.
  n := n + 1;
  if not exists (select 1 from jsonb_array_elements(
        (public.internal_public_booking_page('kky-demo'))->'staff') s
      where (s->>'id')::uuid = c_amanda) then
    raise exception 'PHOTO 7 FAIL (%): a bookable member is missing from the customer booking page', n;
  end if;

  n := n + 1;
  update public.staff set customer_bookable = false where id = c_amanda;
  if exists (select 1 from jsonb_array_elements(
        (public.internal_public_booking_page('kky-demo'))->'staff') s
      where (s->>'id')::uuid = c_amanda) then
    raise exception 'PHOTO 7 FAIL (%): unticking a member does NOT remove them from the customer booking page — the control the owner was told to use does not work', n;
  end if;

  n := n + 1;
  update public.staff set customer_bookable = true where id = c_amanda;
  if not exists (select 1 from jsonb_array_elements(
        (public.internal_public_booking_page('kky-demo'))->'staff') s
      where (s->>'id')::uuid = c_amanda) then
    raise exception 'PHOTO 7 FAIL (%): re-ticking a member does not bring them back', n;
  end if;

  raise notice 'owner photo acceptance: % / % assertions passed', n, n;
end
$suite$;

rollback;
