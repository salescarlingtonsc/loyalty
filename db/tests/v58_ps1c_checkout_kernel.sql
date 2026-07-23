-- Rollback-only v58 PS-1C unified checkout kernel suite.
-- Run after the pending chain (through v58) in a disposable rehearsal database.
-- Covers the owner's exact list: token replay, double-click finalisation, stale
-- (expired / changed price / changed config), budget cap suppression, cross-tenant,
-- unpaid + partial payment, one-cent rounding, failure injection (whole-txn rollback,
-- token still usable), reversal (compensating fulfilment + budget release + Σ
-- invariant), kernel-surface replay (SAFE WRAPPER + LEGACY paths produce ZERO
-- checkout_discount_lines), no-silent-zero (clamp; negative totals impossible),
-- permission block, and the legacy-earn assertion (points earn on the DISCOUNTED
-- total). The including transaction owns BEGIN/ROLLBACK; nothing commits.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v58_principal(p_uid uuid, p_role text)
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  if p_role = 'anon' then
    execute 'set local role anon';
    perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  elsif p_role = 'authenticated' and p_uid is not null then
    execute 'set local role authenticated';
    perform set_config('request.jwt.claim.sub', p_uid::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  else
    raise exception 'unsupported v58 principal';
  end if;
end $$;
grant execute on function pg_temp.as_v58_principal(uuid, text) to authenticated, anon;

do $v58_test$
declare
  v_business uuid; v_owner uuid; v_owner_staff uuid; v_client uuid; v_branch uuid; v_base uuid;
  v_biz_b uuid; v_owner_b uuid; v_branch_b uuid; v_svc_b uuid; v_xten uuid := gen_random_uuid();
  v_cfg1 uuid; v_cfg2 uuid; v_hash text;
  v_svc5000 uuid; v_svc2000 uuid; v_svc_cp uuid; v_r1 uuid; v_r2 uuid; v_r3 uuid; v_r4 uuid; v_r5 uuid;
  v_svc_a uuid; v_svc_b1 uuid; v_svc_r1 uuid; v_svc_r2 uuid; v_svc_r3 uuid;
  v_ev jsonb; v_ev2 jsonb; v_res json; v_res2 json; v_tok uuid; v_tok2 uuid; v_sale uuid;
  v_rate numeric; v_expect int; v_n int; v_committed int; v_reserved int; v_released int;
  v_gc jsonb; v_before int; v_pay1 json; v_gckey uuid := gen_random_uuid();
  v_lines_5000 jsonb; v_lines_305 jsonb; v_lines_4000 jsonb; v_lines_line jsonb;
begin
  -- ---- 0. Fixtures ----
  reset role;
  select s.business_id, s.user_id, s.id into v_business, v_owner, v_owner_staff
    from public.staff s join public.businesses b on b.id = s.business_id
   where s.role = 'owner' and s.active and s.user_id is not null and b.name = 'Pristine chain fixture A'
   order by s.created_at limit 1;
  select s.business_id, s.user_id into v_biz_b, v_owner_b
    from public.staff s join public.businesses b on b.id = s.business_id
   where s.role = 'owner' and s.active and s.user_id is not null and b.name = 'Pristine chain fixture B'
   order by s.created_at limit 1;
  if v_business is null or v_biz_b is null then raise exception 'v58 needs both fixture businesses'; end if;
  select id into v_client from public.clients where business_id = v_business order by created_at limit 1;
  select id into v_branch from public.branches where business_id = v_business and active order by is_default desc, created_at limit 1;
  select id into v_branch_b from public.branches where business_id = v_biz_b and active order by is_default desc, created_at limit 1;
  select active_config_version_id into v_base from public.businesses where id = v_business;

  insert into public.services(business_id, name, price_cents, duration_min) values
    (v_business, 'v58 five thousand', 5000, 30),
    (v_business, 'v58 two thousand', 2000, 30),
    (v_business, 'v58 changed price', 5000, 30),
    (v_business, 'v58 line svc A', 5000, 30),
    (v_business, 'v58 line svc B', 2000, 30),
    (v_business, 'v58 round 1', 100, 15),
    (v_business, 'v58 round 2', 100, 15),
    (v_business, 'v58 round 3', 105, 15)
  ;
  select id into v_svc5000 from public.services where business_id = v_business and name = 'v58 five thousand';
  select id into v_svc2000 from public.services where business_id = v_business and name = 'v58 two thousand';
  select id into v_svc_cp from public.services where business_id = v_business and name = 'v58 changed price';
  select id into v_svc_a from public.services where business_id = v_business and name = 'v58 line svc A';
  select id into v_svc_b1 from public.services where business_id = v_business and name = 'v58 line svc B';
  select id into v_svc_r1 from public.services where business_id = v_business and name = 'v58 round 1';
  select id into v_svc_r2 from public.services where business_id = v_business and name = 'v58 round 2';
  select id into v_svc_r3 from public.services where business_id = v_business and name = 'v58 round 3';
  insert into public.services(business_id, name, price_cents, duration_min) values (v_biz_b, 'v58 B svc', 3000, 30);
  select id into v_svc_b from public.services where business_id = v_biz_b and name = 'v58 B svc';

  -- ---- 1. Author + publish discount rules (when_event = sale.completed). ----
  perform pg_temp.as_v58_principal(v_owner, 'authenticated');
  v_cfg1 := (public.create_loyalty_config_draft(v_business, v_base, 'v58_discounts')::jsonb->>'version_id')::uuid;
  v_r1 := gen_random_uuid(); v_r2 := gen_random_uuid(); v_r3 := gen_random_uuid(); v_r4 := gen_random_uuid(); v_r5 := gen_random_uuid();
  -- R1: bill 10% off when subtotal == 5000.
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_cfg1;
  perform public.save_program_rule_draft(v_cfg1, v_r1, jsonb_build_object(
    'name', 'R1 bill 10pct at 5000', 'when_event', 'sale.completed', 'active', true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field', 'amount_cents', 'op', 'eq', 'value', 5000)),
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type', 'apply_discount_pct', 'discount_pct', 10))), v_hash);
  -- R2: bill 50% off when subtotal == 305 (half-up rounding: 152.5 -> 153).
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_cfg1;
  perform public.save_program_rule_draft(v_cfg1, v_r2, jsonb_build_object(
    'name', 'R2 bill 50pct at 305', 'when_event', 'sale.completed', 'active', true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field', 'amount_cents', 'op', 'eq', 'value', 305)),
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type', 'apply_discount_pct', 'discount_pct', 50))), v_hash);
  -- R3: line-level fixed 999999 off svc_a when subtotal == 7000 (clamps to the 5000 line).
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_cfg1;
  perform public.save_program_rule_draft(v_cfg1, v_r3, jsonb_build_object(
    'name', 'R3 line clamp at 7000', 'when_event', 'sale.completed', 'active', true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field', 'amount_cents', 'op', 'eq', 'value', 7000)),
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type', 'apply_discount_amount', 'amount_cents', 999999,
      'catalog_kind', 'service', 'catalog_id', v_svc_a))), v_hash);
  -- R4: bill 1000 off when subtotal == 4000, capped at 1000/month (one grant only).
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_cfg1;
  perform public.save_program_rule_draft(v_cfg1, v_r4, jsonb_build_object(
    'name', 'R4 capped 1000 at 4000', 'when_event', 'sale.completed', 'active', true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field', 'amount_cents', 'op', 'eq', 'value', 4000)),
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type', 'apply_discount_amount', 'amount_cents', 1000)),
    'with_params', jsonb_build_object('budget_cap_cents', 1000, 'budget_period', 'monthly')), v_hash);
  -- R5: bill 10% off svc_cp cart (subtotal == 5001) for the changed-price token.
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_cfg1;
  perform public.save_program_rule_draft(v_cfg1, v_r5, jsonb_build_object(
    'name', 'R5 bill 10pct at 5001', 'when_event', 'sale.completed', 'active', true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field', 'amount_cents', 'op', 'eq', 'value', 5001)),
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type', 'apply_discount_pct', 'discount_pct', 10))), v_hash);
  perform public.publish_loyalty_config(v_cfg1);
  select active_config_version_id into v_cfg1 from public.businesses where id = v_business;
  if not exists (select 1 from public.program_rules_compiled where rule_id = v_r1 and config_version_id = v_cfg1 and when_event = 'sale.completed') then
    raise exception 'discount rule did not compile into the kernel surface';
  end if;

  v_lines_5000 := jsonb_build_array(jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_svc5000, 'qty', 1));
  v_lines_305  := jsonb_build_array(
    jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_svc_r1, 'qty', 1),
    jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_svc_r2, 'qty', 1),
    jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_svc_r3, 'qty', 1));
  v_lines_4000 := jsonb_build_array(jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_svc2000, 'qty', 2));
  v_lines_line := jsonb_build_array(
    jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_svc_a, 'qty', 1),
    jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_svc_b1, 'qty', 1));

  -- ---- 2. Token replay: same idempotency key returns the SAME evaluation. ----
  v_ev := public.evaluate_checkout(v_business, v_branch, v_client, v_lines_5000, gen_random_uuid());
  if (v_ev->>'total_cents')::int <> 4500 or (v_ev->>'discount_total_cents')::int <> 500 then
    raise exception 'R1 bill 10pct did not price 5000 -> 4500 (got %/%)', v_ev->>'total_cents', v_ev->>'discount_total_cents';
  end if;
  v_tok := (v_ev->>'evaluation_id')::uuid;
  declare v_key uuid := gen_random_uuid(); begin
    v_ev := public.evaluate_checkout(v_business, v_branch, v_client, v_lines_5000, v_key);
    v_ev2 := public.evaluate_checkout(v_business, v_branch, v_client, v_lines_5000, v_key);
    if (v_ev->>'evaluation_id') <> (v_ev2->>'evaluation_id') or (v_ev2->>'replayed')::boolean is not true then
      raise exception 'evaluate replay did not return the same token';
    end if;
    v_tok := (v_ev->>'evaluation_id')::uuid;
  end;

  -- ---- 3. Double-click finalisation: same finalise key -> one sale, replay. ----
  declare v_fk text := 'v58-fin-' || substr(md5(clock_timestamp()::text), 1, 12); begin
    v_res := public.record_cart_sale(v_business, v_client, v_branch, v_owner_staff, 'cash', v_fk, null, v_tok, true);
    v_sale := (v_res->>'sale_id')::uuid;
    if (v_res->>'total_cents')::int <> 4500 or (v_res->>'discount_total_cents')::int <> 500 then
      raise exception 'kernel sale did not book the discounted total';
    end if;
    v_res2 := public.record_cart_sale(v_business, v_client, v_branch, v_owner_staff, 'cash', v_fk, null, v_tok, true);
    if (v_res2->>'status') <> 'duplicate_ignored' or (v_res2->>'sale_id')::uuid <> v_sale then
      raise exception 'double-click finalisation created a second sale';
    end if;
  end;
  if (select count(*) from public.sales where reversal_of is null and note = 'cart checkout (kernel)' and id = v_sale) <> 1 then
    raise exception 'exactly one kernel sale expected';
  end if;
  -- Σ sale_items reconciles to sales.amount_cents; one signed discount line.
  if (select sum(line_cents) from public.sale_items where sale_id = v_sale)
     <> (select amount_cents from public.sales where id = v_sale) then
    raise exception 'sale_items do not reconcile to sales.amount_cents';
  end if;
  if (select count(*) from public.sale_items where sale_id = v_sale and item_type = 'studio_discount' and line_cents = -500) <> 1 then
    raise exception 'the signed studio_discount line is missing or wrong';
  end if;
  if (select count(*) from public.checkout_discount_lines where sale_id = v_sale) <> 1 then
    raise exception 'exactly one discount provenance row expected';
  end if;
  -- provenance + fulfilment reconcile.
  if (select amount_cents from public.checkout_discount_lines where sale_id = v_sale)
     <> (select face_value_cents from public.benefit_fulfilments f
          join public.checkout_discount_lines cdl on cdl.benefit_fulfilment_id = f.id where cdl.sale_id = v_sale) then
    raise exception 'discount line amount does not equal its fulfilment face';
  end if;

  -- ---- 4. Legacy-earn: points earn on the DISCOUNTED total (4500), not 5000. ----
  select earn_points_per_dollar into v_rate from public.loyalty_programs where business_id = v_business and active limit 1;
  if v_rate is not null and v_rate > 0 then
    v_expect := floor(4500 / 100.0 * v_rate)::int;
    if coalesce((select sum(points) from public.points_ledger where sale_id = v_sale and entry_type = 'earn'), 0) <> v_expect then
      raise exception 'points did not earn on the discounted total (expected % for 4500)', v_expect;
    end if;
    if v_expect >= floor(5000 / 100.0 * v_rate)::int then
      raise exception 'discounted earn is not strictly below the undiscounted earn';
    end if;
  else
    raise notice 'v58: no active loyalty program on the fixture; skipping legacy-earn magnitude assertion';
  end if;

  -- ---- 5. One-cent rounding: 3 lines, bill 50% half-up (305 -> 153); GST-inclusive
  --         extraction rounds on the discounted total (152 * 900/10900 -> 13).
  reset role;
  update public.businesses set gst_registered = true, gst_rate_bps = 900 where id = v_business;
  perform pg_temp.as_v58_principal(v_owner, 'authenticated');
  v_ev := public.evaluate_checkout(v_business, v_branch, v_client, v_lines_305, gen_random_uuid());
  if (v_ev->>'discount_total_cents')::int <> 153 or (v_ev->>'total_cents')::int <> 152 then
    raise exception 'half-up rounding wrong: 50%% of 305 must be 153 (got %/%)', v_ev->>'discount_total_cents', v_ev->>'total_cents';
  end if;
  if (v_ev->>'gst_cents')::int <> round(152 * 900 / 10900.0)::int then
    raise exception 'GST-inclusive extraction wrong: expected % got %', round(152 * 900 / 10900.0)::int, v_ev->>'gst_cents';
  end if;
  v_res := public.record_cart_sale(v_business, v_client, v_branch, v_owner_staff, 'cash',
    'v58-round-' || substr(md5(clock_timestamp()::text), 1, 10), null, (v_ev->>'evaluation_id')::uuid, true);
  if (select sum(line_cents) from public.sale_items where sale_id = (v_res->>'sale_id')::uuid) <> 152 then
    raise exception 'rounded cart does not reconcile to 152';
  end if;

  -- ---- 6. No-silent-zero: line-level clamp; discount never exceeds its target; ----
  --         negative totals impossible (subtotal 7000, 999999 off svc_a -> 5000).
  v_ev := public.evaluate_checkout(v_business, v_branch, v_client, v_lines_line, gen_random_uuid());
  if (v_ev->>'discount_total_cents')::int <> 5000 or (v_ev->>'total_cents')::int <> 2000 then
    raise exception 'line-level clamp wrong: 999999 off a 5000 line must clamp to 5000 (got %/%)', v_ev->>'discount_total_cents', v_ev->>'total_cents';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_ev->'applied_effects') e where e->>'level' = 'line' and (e->>'amount_cents')::int = 5000) then
    raise exception 'the applied effect was not recorded as a clamped line discount';
  end if;
  reset role;
  begin
    insert into public.checkout_evaluations(business_id, branch_id, server_lines, cart_hash, subtotal_cents,
      discount_total_cents, total_cents, expires_at)
    values (v_business, v_branch, '[]'::jsonb, repeat('a', 64), 100, 200, -100, now() + interval '10 minutes');
    raise exception 'a negative total was insertable into checkout_evaluations';
  exception when check_violation then null; end;

  -- ---- 7. Stale: expired token -> stale_evaluation, nothing written. ----
  perform pg_temp.as_v58_principal(v_owner, 'authenticated');
  v_ev := public.evaluate_checkout(v_business, v_branch, v_client, v_lines_5000, gen_random_uuid());
  v_tok := (v_ev->>'evaluation_id')::uuid;
  reset role;
  alter table public.checkout_evaluations disable trigger trg_checkout_evaluations_guard;
  update public.checkout_evaluations set expires_at = now() - interval '1 minute' where id = v_tok;
  alter table public.checkout_evaluations enable trigger trg_checkout_evaluations_guard;
  perform pg_temp.as_v58_principal(v_owner, 'authenticated');
  begin
    perform public.record_cart_sale(v_business, v_client, v_branch, v_owner_staff, 'cash',
      'v58-exp-' || substr(md5(clock_timestamp()::text), 1, 10), null, v_tok, true);
    raise exception 'an expired token finalised';
  exception when sqlstate 'P0001' then
    if (select consumed_at from public.checkout_evaluations where id = v_tok) is not null then
      raise exception 'an expired finalisation still consumed the token';
    end if;
  end;

  -- ---- 8. Stale: changed price (edit svc after evaluation) -> stale_evaluation. ----
  v_ev := public.evaluate_checkout(v_business, v_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_svc_cp, 'qty', 1)), gen_random_uuid());
  v_tok := (v_ev->>'evaluation_id')::uuid;
  reset role;
  update public.services set price_cents = 5500 where id = v_svc_cp;
  perform pg_temp.as_v58_principal(v_owner, 'authenticated');
  begin
    perform public.record_cart_sale(v_business, v_client, v_branch, v_owner_staff, 'cash',
      'v58-price-' || substr(md5(clock_timestamp()::text), 1, 10), null, v_tok, true);
    raise exception 'a changed-price token finalised';
  exception when sqlstate 'P0001' then null; end;
  if (select consumed_at from public.checkout_evaluations where id = v_tok) is not null then
    raise exception 'a changed-price finalisation consumed the token';
  end if;

  -- ---- 9. Stale: changed config (publish a new version) -> stale_evaluation. ----
  v_ev := public.evaluate_checkout(v_business, v_branch, v_client, v_lines_5000, gen_random_uuid());
  v_tok := (v_ev->>'evaluation_id')::uuid;
  v_cfg2 := (public.create_loyalty_config_draft(v_business, v_cfg1, 'v58_rev2')::jsonb->>'version_id')::uuid;
  perform public.publish_loyalty_config(v_cfg2);
  select active_config_version_id into v_cfg2 from public.businesses where id = v_business;
  begin
    perform public.record_cart_sale(v_business, v_client, v_branch, v_owner_staff, 'cash',
      'v58-cfg-' || substr(md5(clock_timestamp()::text), 1, 10), null, v_tok, true);
    raise exception 'a stale-config token finalised';
  exception when sqlstate 'P0001' then null; end;

  -- ---- 10. Budget cap: first checkout discounted + commits; second suppressed. ----
  v_ev := public.evaluate_checkout(v_business, v_branch, v_client, v_lines_4000, gen_random_uuid());
  if (v_ev->>'discount_total_cents')::int <> 1000 then raise exception 'first capped checkout was not discounted'; end if;
  v_res := public.record_cart_sale(v_business, v_client, v_branch, v_owner_staff, 'cash',
    'v58-cap1-' || substr(md5(clock_timestamp()::text), 1, 10), null, (v_ev->>'evaluation_id')::uuid, true);
  v_sale := (v_res->>'sale_id')::uuid;   -- retained for the reversal test
  select committed_cents into v_committed from public.budget_periods where business_id = v_business and rule_id = v_r4;
  if coalesce(v_committed, 0) <> 1000 then raise exception 'budget counter did not commit the first grant'; end if;
  v_ev2 := public.evaluate_checkout(v_business, v_branch, v_client, v_lines_4000, gen_random_uuid());
  if (v_ev2->>'discount_total_cents')::int <> 0 or (v_ev2->>'total_cents')::int <> 4000 then
    raise exception 'the second capped checkout was still discounted past the exhausted budget';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_ev2->'applied_effects') e
                  where (e->>'suppressed')::boolean and e->>'suppression_reason' = 'budget_exhausted') then
    raise exception 'budget exhaustion was not surfaced with the budget_exhausted reason at evaluation';
  end if;

  -- ---- 11. Reversal: reverse the capped sale -> compensating fulfilment + budget ----
  --          release; committed reconciles to Σreservations − Σreleases.
  v_res := public.reverse_sale(v_business, v_sale, 'v58 reversal of a discounted kernel sale',
    'v58-rev-' || substr(md5(clock_timestamp()::text), 1, 10));
  if (v_res->>'reversal_sale_id') is null then raise exception 'reversal did not produce a reversing sale'; end if;
  if not exists (select 1 from public.benefit_fulfilments where source_engine = 'checkout'
                  and fulfilment_kind = 'checkout_discount_reversal' and business_id = v_business and face_value_cents < 0) then
    raise exception 'the compensating (negative) discount fulfilment is missing';
  end if;
  select coalesce(sum(br.amount_cents), 0) into v_reserved from public.budget_reservations br
    join public.budget_periods bp on bp.id = br.budget_period_id where bp.business_id = v_business and bp.rule_id = v_r4;
  select coalesce(sum(rel.amount_cents), 0) into v_released from public.budget_commitment_releases rel
    join public.budget_periods bp on bp.id = rel.budget_period_id where bp.business_id = v_business and bp.rule_id = v_r4;
  select committed_cents into v_committed from public.budget_periods where business_id = v_business and rule_id = v_r4;
  if v_committed <> v_reserved - v_released or v_committed < 0 then
    raise exception 'budget invariant broke after release: committed=% reserved=% released=%', v_committed, v_reserved, v_released;
  end if;
  if v_committed <> 0 then raise exception 'the released capped budget did not return to 0 (got %)', v_committed; end if;
  -- Idempotent reversal replay: same key -> no second release.
  -- (the sale_reversal operation row stores the ORIGINAL sale's id, v20:3385)
  v_res := public.reverse_sale(v_business, v_sale, 'v58 reversal of a discounted kernel sale',
    (select idempotency_key from public.financial_operations
      where business_id = v_business and sale_id = v_sale and operation_type = 'sale_reversal' limit 1));
  select coalesce(sum(rel.amount_cents), 0) into v_n from public.budget_commitment_releases rel
    join public.budget_periods bp on bp.id = rel.budget_period_id where bp.business_id = v_business and bp.rule_id = v_r4;
  if v_n <> v_released then raise exception 'a replayed reversal double-released the budget'; end if;

  -- ---- 12. Unpaid + partial payment: paid=false -> sale exists, payments 0. ----
  v_ev := public.evaluate_checkout(v_business, v_branch, v_client, v_lines_5000, gen_random_uuid());
  v_res := public.record_cart_sale(v_business, v_client, v_branch, v_owner_staff, 'cash',
    'v58-unpaid-' || substr(md5(clock_timestamp()::text), 1, 10), null, (v_ev->>'evaluation_id')::uuid, false);
  v_sale := (v_res->>'sale_id')::uuid;
  if (select coalesce(sum(amount_cents), 0) from public.payments where sale_id = v_sale) <> 0 then
    raise exception 'an unpaid kernel sale already had payments';
  end if;
  if (select amount_cents from public.sales where id = v_sale) <> 4500 then raise exception 'unpaid sale total wrong'; end if;
  perform public.record_payment(p_business => v_business, p_method => 'cash', p_amount_cents => 2000, p_sale => v_sale,
    p_client => v_client, p_staff => v_owner_staff, p_branch => v_branch,
    p_idempotency_key => 'v58-pay1-' || substr(md5(clock_timestamp()::text), 1, 8));
  perform public.record_payment(p_business => v_business, p_method => 'card', p_amount_cents => 2500, p_sale => v_sale,
    p_client => v_client, p_staff => v_owner_staff, p_branch => v_branch,
    p_idempotency_key => 'v58-pay2-' || substr(md5(clock_timestamp()::text), 1, 8));
  if (select coalesce(sum(amount_cents), 0) from public.payments where sale_id = v_sale) <> 4500 then
    raise exception 'partial then rest did not reconcile to the discounted total';
  end if;
  if (select count(*) from public.checkout_discount_lines where sale_id = v_sale) <> 1 then
    raise exception 'the discount provenance changed under tendering';
  end if;

  -- ---- 13. Failure injection: a trigger raising inside finalisation rolls the ----
  --          whole txn back (no sale, token unconsumed, no provenance/budget), and
  --          the token stays usable.
  v_ev := public.evaluate_checkout(v_business, v_branch, v_client, v_lines_5000, gen_random_uuid());
  v_tok := (v_ev->>'evaluation_id')::uuid;
  reset role;
  execute 'create or replace function public.v58_boom_trg() returns trigger language plpgsql as ' ||
          '$b$ begin raise exception ''v58 injected finalisation failure''; end $b$';
  execute 'create trigger v58_boom before insert on public.sale_items for each row execute function public.v58_boom_trg()';
  perform pg_temp.as_v58_principal(v_owner, 'authenticated');
  begin
    perform public.record_cart_sale(v_business, v_client, v_branch, v_owner_staff, 'cash',
      'v58-boom-' || substr(md5(clock_timestamp()::text), 1, 10), null, v_tok, true);
    raise exception 'finalisation did not fail under trigger injection';
  exception when others then
    if position('v58 injected' in sqlerrm) = 0 then raise; end if;
  end;
  reset role;
  execute 'drop trigger v58_boom on public.sale_items';
  execute 'drop function public.v58_boom_trg()';
  if (select consumed_at from public.checkout_evaluations where id = v_tok) is not null then
    raise exception 'a failed finalisation still consumed the token';
  end if;
  -- token still usable after the injected failure rolled back.
  perform pg_temp.as_v58_principal(v_owner, 'authenticated');
  v_res := public.record_cart_sale(v_business, v_client, v_branch, v_owner_staff, 'cash',
    'v58-boom2-' || substr(md5(clock_timestamp()::text), 1, 10), null, v_tok, true);
  if (v_res->>'status') <> 'ok' then raise exception 'the token was not usable after a rolled-back failure'; end if;

  -- ---- 14. Kernel-surface replay: SAFE WRAPPER + LEGACY paths still work and ----
  --          produce ZERO checkout_discount_lines.
  select count(*) into v_before from public.checkout_discount_lines where business_id = v_business;
  perform public.record_quick_sale(v_business, 3300, 'cash', v_client, v_owner_staff, v_branch, 'v58 quick',
    'v58-qs-' || substr(md5(clock_timestamp()::text), 1, 10), true);
  -- no-token cart (v51 7-arg): STRENGTHENED at v59 (PS-1C.1) — the client-priced
  -- /7 overload is RETIRED (browser execution revoked); the tokenised /9 kernel is
  -- the only cart entry. Assert the revoke held instead of exercising the old path.
  begin
    perform public.record_cart_sale(v_business, v_client, v_branch, v_owner_staff, 'cash',
      'v58-cart7-' || substr(md5(clock_timestamp()::text), 1, 10),
      jsonb_build_array(jsonb_build_object('item_type', 'service', 'ref_id', v_svc2000, 'qty', 1, 'unit_cents', 2000)));
    raise exception 'the retired 7-arg record_cart_sale was still browser-executable';
  exception when insufficient_privilege then null; end;
  -- phone till (delegates to record_quick_sale).
  perform public.record_sale_by_phone(v_business, '+6590000001', 1500, 'quick_sale', 'v58 phone', v_owner_staff,
    'v58-phone-' || substr(md5(clock_timestamp()::text), 1, 10), v_branch, 'cash');
  -- gift-card issue + redeem (cash collected / load; no discount).
  v_gc := public.issue_gift_card(v_business, 4000, v_client, 'v58gc@example.test', v_gckey);
  perform public.redeem_gift_card_v41(v_business, v_gc->>'code', v_client, 1000);
  if (select count(*) from public.checkout_discount_lines where business_id = v_business) <> v_before then
    raise exception 'a non-kernel surface produced a checkout discount line';
  end if;
  -- The PS-1B executor SHADOW-LOGS apply_discount_* (family checkout); it must NEVER
  -- fulfil one. Every checkout-family fulfilment traces to a kernel discount line.
  reset role;
  perform app.run_studio_executor(500);
  if exists (select 1 from public.benefit_fulfilments f
              where f.business_id = v_business and f.source_engine = 'checkout' and f.fulfilment_kind = 'checkout_discount'
                and not exists (select 1 from public.checkout_discount_lines cdl
                                 where cdl.benefit_fulfilment_id = f.id and cdl.business_id = f.business_id)) then
    raise exception 'the studio executor produced a checkout-family fulfilment (discounts are kernel-only)';
  end if;

  -- ---- 15. Permission + cross-tenant fail closed. ----
  -- The fixture's B owner (v_owner_b) is deliberately a super_admin (sa_read scope),
  -- so genuine cross-tenant denial needs a FRESH non-SA owner of business B.
  reset role;
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_xten, 'authenticated', 'authenticated',
    'v58-xten-' || substr(v_xten::text, 1, 8) || '@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, full_name, active) values (v_biz_b, v_xten, 'owner', 'v58 B owner', true);

  -- The non-SA B owner mints a B token (B has no discount config -> zero discount).
  perform pg_temp.as_v58_principal(v_xten, 'authenticated');
  v_ev := public.evaluate_checkout(v_biz_b, v_branch_b, null,
    jsonb_build_array(jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_svc_b, 'qty', 1)), gen_random_uuid());
  v_tok2 := (v_ev->>'evaluation_id')::uuid;
  -- B staff cannot finalise for A (no create_sales in A).
  begin
    perform public.record_cart_sale(v_business, null, v_branch, null, 'cash',
      'v58-xt1-' || substr(md5(clock_timestamp()::text), 1, 10), null, v_tok2, true);
    raise exception 'B staff finalised for A';
  exception when sqlstate '42501' then null; when sqlstate 'P0001' then null; end;
  -- The non-SA B owner cannot read A's discount report.
  begin perform public.get_checkout_discount_report(v_business, current_date - 1, current_date + 1);
    raise exception 'a non-owner/non-SA read A''s discount report'; exception when sqlstate '42501' then null; end;

  -- A owner cannot finalise B's token (token not found in A) nor price a checkout in B.
  perform pg_temp.as_v58_principal(v_owner, 'authenticated');
  begin
    perform public.record_cart_sale(v_business, null, v_branch, v_owner_staff, 'cash',
      'v58-xt2-' || substr(md5(clock_timestamp()::text), 1, 10), null, v_tok2, true);
    raise exception 'A owner finalised a B token';
  exception when sqlstate '42501' then null; when sqlstate 'P0001' then null; end;
  begin
    perform public.evaluate_checkout(v_biz_b, v_branch_b, null,
      jsonb_build_array(jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_svc_b, 'qty', 1)), gen_random_uuid());
    raise exception 'A owner priced a checkout in B';
  exception when sqlstate '42501' then null; end;

  -- anon is denied on evaluate + report by the ACL.
  perform pg_temp.as_v58_principal(null, 'anon');
  begin perform public.evaluate_checkout(v_business, v_branch, v_client, v_lines_5000, gen_random_uuid());
    raise exception 'anon evaluated a checkout'; exception when insufficient_privilege then null; end;
  begin perform public.get_checkout_discount_report(v_business, current_date - 1, current_date + 1);
    raise exception 'anon read the discount report'; exception when insufficient_privilege then null; end;
  -- the fixture super admin (B owner) DOES read cross-tenant (v14 read-everything scope).
  perform pg_temp.as_v58_principal(v_owner_b, 'authenticated');
  if (public.get_checkout_discount_report(v_business, current_date - 1, current_date + 1)->>'business_id') is null then
    raise exception 'super admin read-everything scope regressed for the discount report';
  end if;

  -- ---- 16. Report reconciliation: grand-total discount = Σ discount lines = Σ ----
  --          positive checkout fulfilment face.
  perform pg_temp.as_v58_principal(v_owner, 'authenticated');
  v_res := public.get_checkout_discount_report(v_business, current_date - 1, current_date + 1)::json;
  if ((v_res->'grand_totals'->>'discount_cents')::int)
     <> (select coalesce(sum(amount_cents), 0)::int from public.checkout_discount_lines where business_id = v_business) then
    raise exception 'report grand total does not equal Σ checkout_discount_lines';
  end if;
  if ((v_res->'grand_totals'->>'discount_cents')::int)
     <> (select coalesce(sum(face_value_cents), 0)::int from public.benefit_fulfilments
          where business_id = v_business and source_engine = 'checkout' and face_value_cents > 0) then
    raise exception 'report grand total does not equal Σ positive checkout benefit_fulfilments face';
  end if;
  if (v_res->>'csv') is null or position('date,rule_id,rule_name' in (v_res->>'csv')) <> 1 then
    raise exception 'report CSV header is missing';
  end if;

  -- ---- 17. Browser-write ACL contract: PS-1C tables are read-only to browsers. ----
  reset role;
  if has_table_privilege('authenticated', 'public.checkout_evaluations', 'insert')
     or has_table_privilege('authenticated', 'public.checkout_discount_lines', 'insert')
     or has_table_privilege('authenticated', 'public.checkout_evaluation_operations', 'insert')
     or has_table_privilege('authenticated', 'public.budget_commitment_releases', 'insert') then
    raise exception 'browser roles retain direct writes to PS-1C tables';
  end if;
  begin update public.checkout_discount_lines set amount_cents = 1 where business_id = v_business;
    raise exception 'checkout_discount_lines was mutable'; exception when restrict_violation then null; end;

  raise notice 'v58 PS-1C unified checkout kernel suite: ALL PASS';
end $v58_test$;

reset role;
rollback;
