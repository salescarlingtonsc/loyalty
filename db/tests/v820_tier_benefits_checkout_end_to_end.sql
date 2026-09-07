-- Rollback-only end-to-end walk of TIER BENEFITS AT CHECKOUT, run as the REAL principals.
--   supabase db query --linked -f db/tests/v820_tier_benefits_checkout_end_to_end.sql
--
-- Verification only — no migration accompanies this suite. It pins the behaviour of the live
-- tier-discount path as an owner would exercise it from the till and as a customer sees it:
--
--   AhXiang (three UNLIMITED "% off the whole bill" perks on a VIP < VVIP < VVVIP ladder)
--   A1  the staff reader and the customer reader list the same benefits with the same counts
--   A2  AUTOMATIC: a VVVIP customer buying a $200 service is quoted 20% off with no hand-apply
--       (best-one-wins across the ladder; the 10% and 15% rungs are not stacked)
--   A3  the finalised sale carries a signed studio_discount line for exactly that amount and
--       exactly that benefit, the sale total is the discounted total, and an UNLIMITED perk
--       spends no allowance (no tier_benefit_issues row)
--   A4  a customer on no tier gets no discount, and hand-applying the VVVIP perk to them is
--       refused (tier_benefit_not_available)
--   A5  a perk that belongs to ANOTHER business is refused for this customer
--   A6  an anonymous sale (no customer) gets no discount
--   A7  V394: pausing the VVVIP tier drops the quote to the next rung (15%); soft-deleting that
--       rung drops it to VIP (10%) — paused and deleted tiers grant nothing
--
--   Cubbly SPA (LIMITED perks: Platinum 30% off, 1/month, capped at $100)
--   C1  nothing is spent silently: with no hand-apply a Platinum customer is quoted full price
--   C2  hand-applied on one $188 line → 30% = $56.40 off, flagged tier_benefit_limited
--   C3  on two lines ($376) 30% = $112.80 is CAPPED to $100.00
--   C4  finalising the capped sale writes the −$100 line AND an issue row keyed by the sale id
--       (period_key = this month), so the discount and the spend cannot disagree
--   C5  both readers now say used 1 / remaining 0 / not claimable
--   C6  a second hand-apply this month is refused (tier_benefit_used_up)
--   C7  staff "give it back" (staff_reverse_gift_redemption_v665, tier_perk) marks the issue
--       reversed and the perk is claimable again — at the till and in both readers
--   C8  a free_item perk cannot be pushed through the discount slot (tier_benefit_not_available)
--   C9  an ITEM-scoped perk (10% off selected items) discounts only the highest-priced ELIGIBLE
--       line, not the $188 service that is not on its list
--
-- evaluate_checkout RAISES (sqlstate 22023) on a tier refusal; the refusal probes catch that and
-- read the reason token back as the status.
--
-- NEGATIVE CONTROL: copy this file, and before the suite add
--     update public.tier_benefits_v365 set discount_percent = 25 where id = '047f16e4-580f-4e11-8cc9-e5670624f598';
--   A2 must fail (quoted 5000, expected 4000) — the assertions read the live rule, not a fixture.

begin;

do $suite$
declare
  -- AhXiang
  a_biz    constant uuid := '33773caa-6d51-4cf2-9ad6-b83f015759e6';
  a_owner  constant uuid := '05e0e55f-3c53-49ac-b57b-09aeab6d5417';
  a_branch constant uuid := '868664ba-06ea-436c-9f67-a196ca4037c6';
  a_svc200 constant uuid := '00b3e697-14a3-43c5-9c94-69ccc89061e9';  -- Active acne, $200
  a_vvvip  constant uuid := '1e0f723c-b772-4115-95f7-401203ab48a6';  -- VVVIP customer
  a_vvvip_user constant uuid := 'afd87b44-c36b-4098-83b4-75b36c8caf09';
  a_none   constant uuid := 'b912b098-607c-4189-9e90-e327f9b186ce';  -- customer on no tier
  a_tier_vvvip constant uuid := 'de71447f-3dbc-4638-95f2-b00f2c053636';
  a_tier_vvip  constant uuid := 'a731882c-fbef-493a-9b15-5d41fce6e206';
  a_ben20  constant uuid := '047f16e4-580f-4e11-8cc9-e5670624f598';  -- VVVIP 20% ever
  a_ben15  constant uuid := 'a6bc9712-6409-4794-8543-94d3ef46b837';  -- VVIP 15% ever
  a_ben10  constant uuid := 'fc07d4b2-164f-4be0-a071-aa8d2759c3ce';  -- VIP 10% ever
  -- Cubbly SPA
  c_biz    constant uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  c_owner  constant uuid := 'f73a9423-33fd-424c-9fb9-2d5ba058a2d7';
  c_branch constant uuid := '9a9081fb-fb48-49c7-a1c7-2bfb3d3ec263';
  c_slug   constant text := 'kopi-tiam-tyeh';
  c_svc188 constant uuid := 'be802d25-9571-4148-87c2-3d49a5d4886c';  -- SPAAAA $188 (not in the item-scope list)
  c_svc30  constant uuid := 'fb40ad58-65a0-47bb-a2f3-5f16a70a3a4b';  -- facial $30 (in the item-scope list)
  c_plat   constant uuid := 'b7861555-2bd9-4773-85c4-f5576699e8e9';  -- Platinum customer
  c_plat_user constant uuid := 'afd87b44-c36b-4098-83b4-75b36c8caf09';
  c_ben30  constant uuid := 'b1a64510-88f8-413f-98e6-de30b5249e43';  -- Platinum 30% 1/month cap $100
  c_free   constant uuid := '20b6055f-b97f-439c-b641-b221007e89cc';  -- Gold free_item 1/month
  c_item10 constant uuid := 'eba8b196-ef25-4d47-a57a-b2a72243dac4';  -- Gold 10% off selected items 1/month

  v_eval jsonb; v_res jsonb; v_staff jsonb; v_cust jsonb; v_eff jsonb;
  v_sale uuid; v_issue uuid; v_amt int; v_cnt int;
  v_lines jsonb;
  n integer := 0;

begin
  -- =========================================================== AhXiang
  -- A1 readers agree ---------------------------------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',a_owner,'role','authenticated')::text, true);
  v_staff := public.staff_tier_benefits_for_client_v365(a_biz, a_vvvip);
  perform set_config('request.jwt.claims', json_build_object('sub',a_vvvip_user,'role','authenticated')::text, true);
  v_cust := public.customer_get_tier_benefits_v501('ahxiang');
  reset role; perform set_config('request.jwt.claims','',true);
  if v_staff->>'status' <> 'ok' or v_cust->>'status' <> 'ok'
     or v_staff->'tier'->>'id' <> a_tier_vvvip::text or v_cust->'tier'->>'id' <> a_tier_vvvip::text then
    raise exception 'A%: readers disagree on the tier (staff % / customer %)', n,
      left(v_staff::text,200), left(v_cust::text,200);
  end if;
  if (select coalesce(string_agg(b->>'benefit_id'||':'||coalesce(b->>'used','-')||':'||coalesce(b->>'remaining','-')||':'||(b->>'claimable_now'), ',' order by b->>'benefit_id'), '')
        from jsonb_array_elements(v_staff->'benefits') b)
     <> (select coalesce(string_agg(b->>'benefit_id'||':'||coalesce(b->>'used','-')||':'||coalesce(b->>'remaining','-')||':'||(b->>'claimable_now'), ',' order by b->>'benefit_id'), '')
        from jsonb_array_elements(v_cust->'benefits') b) then
    raise exception 'A%: the staff and customer benefit lists differ', n;
  end if;
  if not exists (select 1 from jsonb_array_elements(v_staff->'benefits') b where b->>'benefit_id' = a_ben20::text and (b->>'claimable_now')::boolean) then
    raise exception 'A%: the VVVIP 20%% perk is not listed as claimable for a VVVIP customer', n;
  end if;

  -- A2 automatic best-one-wins ---------------------------------------------------------------
  n := n + 1;
  v_lines := jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',a_svc200,'qty',1));
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',a_owner,'role','authenticated')::text, true);
  v_eval := public.evaluate_checkout(a_biz, a_branch, a_vvvip, v_lines, gen_random_uuid(), null::uuid, false);
  reset role; perform set_config('request.jwt.claims','',true);
  if v_eval->>'status' <> 'ok' then raise exception 'A%: evaluate refused: %', n, left(v_eval::text,300); end if;
  select count(*), max((e->>'amount_cents')::int) into v_cnt, v_amt
    from jsonb_array_elements(v_eval->'applied_effects') e where e->>'source' = 'tier_benefit';
  if v_cnt <> 1 or v_amt <> 4000 or (v_eval->>'total_cents')::int <> 16000
     or not exists (select 1 from jsonb_array_elements(v_eval->'applied_effects') e
                     where e->>'tier_benefit_id' = a_ben20::text and (e->>'tier_benefit_limited')::boolean = false) then
    raise exception 'A%: expected one automatic 20%% effect (4000 off 20000 → 16000); got % effects, amount %, total % (%)',
      n, v_cnt, v_amt, v_eval->>'total_cents', left((v_eval->'applied_effects')::text,400);
  end if;

  -- A3 the sale carries the line; unlimited spends nothing -----------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',a_owner,'role','authenticated')::text, true);
  v_res := public.record_cart_sale(a_biz, a_vvvip, a_branch, null, 'cash', 'tier-e2e-'||gen_random_uuid()::text,
    v_lines, (v_eval->>'evaluation_id')::uuid, true, now(), '[]'::jsonb)::jsonb;
  reset role; perform set_config('request.jwt.claims','',true);
  v_sale := (v_res->>'sale_id')::uuid;
  if v_sale is null then raise exception 'A%: the till returned no sale (%)', n, left(v_res::text,300); end if;
  if (select amount_cents from public.sales where id = v_sale) <> 16000 then
    raise exception 'A%: sale total % ≠ 16000', n, (select amount_cents from public.sales where id = v_sale);
  end if;
  if (select count(*) from public.sale_items si where si.sale_id = v_sale and si.item_type = 'studio_discount'
        and si.ref_id = a_ben20 and si.line_cents = -4000) <> 1 then
    raise exception 'A%: expected exactly one studio_discount line of -4000 for benefit % on the sale', n, a_ben20;
  end if;
  if exists (select 1 from public.tier_benefit_issues_v365 i where i.client_id = a_vvvip and i.idem_key = v_sale) then
    raise exception 'A%: an UNLIMITED perk wrote an allowance row', n;
  end if;

  -- A4 no tier → no discount, and the perk cannot be forced ------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',a_owner,'role','authenticated')::text, true);
  v_eval := public.evaluate_checkout(a_biz, a_branch, a_none, v_lines, gen_random_uuid(), null::uuid, false);
  begin
    v_res  := public.evaluate_checkout(a_biz, a_branch, a_none, v_lines, gen_random_uuid(), a_ben20, false);
  exception when others then
    v_res := jsonb_build_object('status', split_part(sqlerrm, ':', 1));
  end;
  reset role; perform set_config('request.jwt.claims','',true);
  if v_eval->>'status' <> 'ok' or (v_eval->>'total_cents')::int <> 20000
     or exists (select 1 from jsonb_array_elements(v_eval->'applied_effects') e where e->>'source' = 'tier_benefit') then
    raise exception 'A%: a customer on no tier was discounted (%)', n, left(v_eval::text,300);
  end if;
  if v_res->>'status' <> 'tier_benefit_not_available' then
    raise exception 'A%: hand-applying a VVVIP perk to a no-tier customer answered % (expected tier_benefit_not_available)', n, v_res->>'status';
  end if;

  -- A5 another business's perk ------------------------------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',a_owner,'role','authenticated')::text, true);
  begin
    v_res := public.evaluate_checkout(a_biz, a_branch, a_vvvip, v_lines, gen_random_uuid(), c_ben30, false);
  exception when others then
    v_res := jsonb_build_object('status', split_part(sqlerrm, ':', 1));
  end;
  reset role; perform set_config('request.jwt.claims','',true);
  if v_res->>'status' <> 'tier_benefit_not_available' then
    raise exception 'A%: a Cubbly perk was accepted on an AhXiang bill (%)', n, v_res->>'status';
  end if;

  -- A6 anonymous sale ---------------------------------------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',a_owner,'role','authenticated')::text, true);
  v_eval := public.evaluate_checkout(a_biz, a_branch, null, v_lines, gen_random_uuid(), null::uuid, false);
  reset role; perform set_config('request.jwt.claims','',true);
  if v_eval->>'status' <> 'ok' or (v_eval->>'total_cents')::int <> 20000
     or exists (select 1 from jsonb_array_elements(v_eval->'applied_effects') e where e->>'source' = 'tier_benefit') then
    raise exception 'A%: an anonymous sale was tier-discounted (%)', n, left(v_eval::text,300);
  end if;

  -- =========================================================== Cubbly SPA
  -- C1 limited perks are never spent silently ----------------------------------------------------
  n := n + 1;
  v_lines := jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',c_svc188,'qty',1));
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',c_owner,'role','authenticated')::text, true);
  v_eval := public.evaluate_checkout(c_biz, c_branch, c_plat, v_lines, gen_random_uuid(), null::uuid, false);
  reset role; perform set_config('request.jwt.claims','',true);
  if v_eval->>'status' <> 'ok' or (v_eval->>'total_cents')::int <> 18800
     or exists (select 1 from jsonb_array_elements(v_eval->'applied_effects') e where e->>'source' = 'tier_benefit') then
    raise exception 'C%: a LIMITED perk was applied automatically (%)', n, left(v_eval::text,300);
  end if;

  -- C2 hand-applied, one line --------------------------------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',c_owner,'role','authenticated')::text, true);
  v_eval := public.evaluate_checkout(c_biz, c_branch, c_plat, v_lines, gen_random_uuid(), c_ben30, false);
  reset role; perform set_config('request.jwt.claims','',true);
  select count(*), max((e->>'amount_cents')::int) into v_cnt, v_amt
    from jsonb_array_elements(v_eval->'applied_effects') e where e->>'tier_benefit_id' = c_ben30::text;
  if v_eval->>'status' <> 'ok' or v_cnt <> 1 or v_amt <> 5640 or (v_eval->>'total_cents')::int <> 13160
     or not exists (select 1 from jsonb_array_elements(v_eval->'applied_effects') e
                     where e->>'tier_benefit_id' = c_ben30::text and (e->>'tier_benefit_limited')::boolean) then
    raise exception 'C%: expected 30%% of 18800 = 5640 off → 13160, limited; got % (%)', n, v_eval->>'total_cents', left(v_eval::text,400);
  end if;

  -- C3 the money cap -----------------------------------------------------------------------------
  n := n + 1;
  v_lines := jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',c_svc188,'qty',2));
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',c_owner,'role','authenticated')::text, true);
  v_eval := public.evaluate_checkout(c_biz, c_branch, c_plat, v_lines, gen_random_uuid(), c_ben30, false);
  reset role; perform set_config('request.jwt.claims','',true);
  select max((e->>'amount_cents')::int) into v_amt
    from jsonb_array_elements(v_eval->'applied_effects') e where e->>'tier_benefit_id' = c_ben30::text;
  if v_eval->>'status' <> 'ok' or v_amt <> 10000 or (v_eval->>'total_cents')::int <> 27600 then
    raise exception 'C%: 30%% of 37600 = 11280 should be capped at 10000 → 27600; got % off, total % (%)',
      n, v_amt, v_eval->>'total_cents', left(v_eval::text,400);
  end if;

  -- C4 finalise: line + allowance in one transaction ----------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',c_owner,'role','authenticated')::text, true);
  v_res := public.record_cart_sale(c_biz, c_plat, c_branch, null, 'cash', 'tier-e2e-'||gen_random_uuid()::text,
    v_lines, (v_eval->>'evaluation_id')::uuid, true, now(), '[]'::jsonb)::jsonb;
  reset role; perform set_config('request.jwt.claims','',true);
  v_sale := (v_res->>'sale_id')::uuid;
  if v_sale is null then raise exception 'C%: the till returned no sale (%)', n, left(v_res::text,300); end if;
  if (select amount_cents from public.sales where id = v_sale) <> 27600
     or (select count(*) from public.sale_items si where si.sale_id = v_sale and si.item_type = 'studio_discount'
           and si.ref_id = c_ben30 and si.line_cents = -10000) <> 1 then
    raise exception 'C%: the finalised sale does not carry the capped -10000 line (total %)', n,
      (select amount_cents from public.sales where id = v_sale);
  end if;
  select i.id into v_issue from public.tier_benefit_issues_v365 i
   where i.business_id = c_biz and i.benefit_id = c_ben30 and i.client_id = c_plat and i.idem_key = v_sale
     and i.period_key = app.v365_period_key('month', now()) and i.reversed_at is null;
  if v_issue is null then
    raise exception 'C%: the sale took 30%% off but no allowance row was written for it', n;
  end if;

  -- C5 both readers count it ---------------------------------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',c_owner,'role','authenticated')::text, true);
  v_staff := public.staff_tier_benefits_for_client_v365(c_biz, c_plat);
  perform set_config('request.jwt.claims', json_build_object('sub',c_plat_user,'role','authenticated')::text, true);
  v_cust := public.customer_get_tier_benefits_v501(c_slug);
  reset role; perform set_config('request.jwt.claims','',true);
  if not exists (select 1 from jsonb_array_elements(v_staff->'benefits') b where b->>'benefit_id' = c_ben30::text
                   and (b->>'used')::int = 1 and (b->>'remaining')::int = 0 and not (b->>'claimable_now')::boolean)
     or not exists (select 1 from jsonb_array_elements(v_cust->'benefits') b where b->>'benefit_id' = c_ben30::text
                   and (b->>'used')::int = 1 and (b->>'remaining')::int = 0 and not (b->>'claimable_now')::boolean) then
    raise exception 'C%: after the sale the readers do not both say used 1 / remaining 0 / not claimable (staff % | customer %)', n,
      (select b::text from jsonb_array_elements(v_staff->'benefits') b where b->>'benefit_id' = c_ben30::text),
      (select b::text from jsonb_array_elements(v_cust->'benefits') b where b->>'benefit_id' = c_ben30::text);
  end if;

  -- C6 second use this month refused --------------------------------------------------------------
  n := n + 1;
  v_lines := jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',c_svc188,'qty',1));
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',c_owner,'role','authenticated')::text, true);
  begin
    v_res := public.evaluate_checkout(c_biz, c_branch, c_plat, v_lines, gen_random_uuid(), c_ben30, false);
  exception when others then
    v_res := jsonb_build_object('status', split_part(sqlerrm, ':', 1));
  end;
  reset role; perform set_config('request.jwt.claims','',true);
  if v_res->>'status' <> 'tier_benefit_used_up' then
    raise exception 'C%: a second use in the same month answered % (expected tier_benefit_used_up)', n, v_res->>'status';
  end if;

  -- C7 give it back → claimable again ------------------------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',c_owner,'role','authenticated')::text, true);
  v_res := public.staff_reverse_gift_redemption_v665(c_biz, 'tier_perk', v_issue, 'end-to-end suite: perk given back', gen_random_uuid());
  v_eval := public.evaluate_checkout(c_biz, c_branch, c_plat, v_lines, gen_random_uuid(), c_ben30, false);
  v_staff := public.staff_tier_benefits_for_client_v365(c_biz, c_plat);
  perform set_config('request.jwt.claims', json_build_object('sub',c_plat_user,'role','authenticated')::text, true);
  v_cust := public.customer_get_tier_benefits_v501(c_slug);
  reset role; perform set_config('request.jwt.claims','',true);
  if (select reversed_at from public.tier_benefit_issues_v365 where id = v_issue) is null then
    raise exception 'C%: giving the perk back did not mark the issue reversed (%)', n, left(v_res::text,300);
  end if;
  if v_eval->>'status' <> 'ok' or (v_eval->>'total_cents')::int <> 13160 then
    raise exception 'C%: after giving it back the till still refuses the perk (%)', n, left(v_eval::text,300);
  end if;
  if not exists (select 1 from jsonb_array_elements(v_staff->'benefits') b where b->>'benefit_id' = c_ben30::text
                   and (b->>'used')::int = 0 and (b->>'remaining')::int = 1 and (b->>'claimable_now')::boolean)
     or not exists (select 1 from jsonb_array_elements(v_cust->'benefits') b where b->>'benefit_id' = c_ben30::text
                   and (b->>'used')::int = 0 and (b->>'remaining')::int = 1 and (b->>'claimable_now')::boolean) then
    raise exception 'C%: after giving it back the readers do not both say used 0 / remaining 1 / claimable', n;
  end if;

  -- C8 a free_item perk is not a discount -----------------------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',c_owner,'role','authenticated')::text, true);
  begin
    v_res := public.evaluate_checkout(c_biz, c_branch, c_plat, v_lines, gen_random_uuid(), c_free, false);
  exception when others then
    v_res := jsonb_build_object('status', split_part(sqlerrm, ':', 1));
  end;
  reset role; perform set_config('request.jwt.claims','',true);
  if v_res->>'status' <> 'tier_benefit_not_available' then
    raise exception 'C%: a free_item perk went through the discount slot (%)', n, v_res->>'status';
  end if;

  -- C9 item-scoped perk lands on the highest-priced ELIGIBLE line only -------------------------------
  n := n + 1;
  v_lines := jsonb_build_array(
    jsonb_build_object('catalog_kind','service','catalog_id',c_svc188,'qty',1),   -- not eligible
    jsonb_build_object('catalog_kind','service','catalog_id',c_svc30,'qty',2));   -- eligible, $30 each
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',c_owner,'role','authenticated')::text, true);
  v_eval := public.evaluate_checkout(c_biz, c_branch, c_plat, v_lines, gen_random_uuid(), c_item10, false);
  reset role; perform set_config('request.jwt.claims','',true);
  select max((e->>'amount_cents')::int) into v_amt
    from jsonb_array_elements(v_eval->'applied_effects') e where e->>'tier_benefit_id' = c_item10::text;
  -- v657: ONE item per transaction — 10% of the $60 eligible line (qty 2 × $30), never of the $188.
  if v_eval->>'status' <> 'ok' or v_amt <> 600 or (v_eval->>'total_cents')::int <> 24200
     or not exists (select 1 from jsonb_array_elements(v_eval->'applied_effects') e
                     where e->>'tier_benefit_id' = c_item10::text and (e->>'tier_benefit_scoped')::boolean) then
    raise exception 'C%: item-scoped 10%% should take 600 off the eligible $60 line → 24200; got % off, total % (%)',
      n, v_amt, v_eval->>'total_cents', left(v_eval::text,500);
  end if;

  -- =========================================================== A7 (destructive to the ladder; last)
  n := n + 1;
  v_lines := jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',a_svc200,'qty',1));
  update public.loyalty_tiers set paused = true where id = a_tier_vvvip;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',a_owner,'role','authenticated')::text, true);
  v_eval := public.evaluate_checkout(a_biz, a_branch, a_vvvip, v_lines, gen_random_uuid(), null::uuid, false);
  begin
    v_res  := public.evaluate_checkout(a_biz, a_branch, a_vvvip, v_lines, gen_random_uuid(), a_ben20, false);
  exception when others then
    v_res := jsonb_build_object('status', split_part(sqlerrm, ':', 1));
  end;
  reset role; perform set_config('request.jwt.claims','',true);
  if v_eval->>'status' <> 'ok' or (v_eval->>'total_cents')::int <> 17000
     or not exists (select 1 from jsonb_array_elements(v_eval->'applied_effects') e where e->>'tier_benefit_id' = a_ben15::text) then
    raise exception 'A%: with VVVIP paused the quote should fall to VVIP 15%% (17000); got % (%)', n, v_eval->>'total_cents', left(v_eval::text,400);
  end if;
  if v_res->>'status' <> 'tier_benefit_not_available' then
    raise exception 'A%: a PAUSED tier''s perk could still be hand-applied (%)', n, v_res->>'status';
  end if;
  update public.loyalty_tiers set deleted_at = now() where id = a_tier_vvip;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',a_owner,'role','authenticated')::text, true);
  v_eval := public.evaluate_checkout(a_biz, a_branch, a_vvvip, v_lines, gen_random_uuid(), null::uuid, false);
  reset role; perform set_config('request.jwt.claims','',true);
  if v_eval->>'status' <> 'ok' or (v_eval->>'total_cents')::int <> 18000
     or not exists (select 1 from jsonb_array_elements(v_eval->'applied_effects') e where e->>'tier_benefit_id' = a_ben10::text) then
    raise exception 'A%: with VVVIP paused and VVIP deleted the quote should fall to VIP 10%% (18000); got % (%)', n, v_eval->>'total_cents', left(v_eval::text,400);
  end if;

  raise notice 'v820 tier benefits at checkout: % / % assertions passed', n, n;
end
$suite$;

rollback;
