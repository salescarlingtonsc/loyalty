-- Rollback-only v59 PS-1C.1 legacy-cart hardening suite.
-- Run after the pending chain (through v59) in a disposable rehearsal database.
-- Covers the pinned PS-1C.1 contract on top of the v58 kernel:
--   1. LEGACY-PATH PROOF: every non-kernel value writer (sell_package, membership
--      enroll/renewal, appointment completion, gift-card issue/redeem, record_payment,
--      record_credit_tender, entitlement redemption) still works AND produces ZERO
--      checkout_discount_lines.
--   2. record_cart_sale/7 retired (no authenticated EXECUTE); /9 kernel is the only
--      browser cart entry.
--   3. Impersonation guard: a package/membership/gift_card kind is rejected typed at
--      evaluation, and a direct package sale_items line under a quick_sale parent is
--      rejected by the BEFORE INSERT guard; dedicated engines are untouched.
--   4. Custom manually-priced lines: owner path prices + finalises + audits; a
--      frontdesk without the permission is denied; over-limit, missing reason and a
--      non-1 qty are typed failures; a price key on a catalog line still fails closed.
--   5. Zero-total is a typed 'total_zero_not_supported' (never stale) and persists
--      nothing (no evaluation, no op-ledger row).
--   6. The plain v58 discount journey (evaluate -> finalise -> reverse) still passes.
-- The including transaction owns BEGIN/ROLLBACK; nothing commits.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v59_principal(p_uid uuid, p_role text)
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
    raise exception 'unsupported v59 principal';
  end if;
end $$;
grant execute on function pg_temp.as_v59_principal(uuid, text) to authenticated, anon;

do $v59_test$
declare
  v_business uuid; v_owner uuid; v_owner_staff uuid; v_client uuid; v_branch uuid; v_base uuid;
  v_cfg uuid; v_hash text; v_r_reg uuid; v_r_zero uuid;
  v_svc5000 uuid; v_svc500 uuid; v_svc_custom uuid; v_svc_appt uuid; v_svc_pkg uuid;
  v_pkg_plan uuid; v_mem_plan uuid; v_membership uuid;
  v_fd_user uuid := gen_random_uuid(); v_fd_staff uuid;
  v_before int; v_n int; v_gc jsonb; v_gckey uuid := gen_random_uuid();
  v_ev jsonb; v_res json; v_tok uuid; v_sale uuid; v_appt uuid; v_ent uuid; v_outcome text;
  v_lines_custom jsonb; v_eval_before int; v_op_before int; v_rate numeric;
  v_credit_before int; v_pay_sale uuid; v_tender_sale uuid;
begin
  -- ---- 0. Fixtures ----
  reset role;
  select s.business_id, s.user_id, s.id into v_business, v_owner, v_owner_staff
    from public.staff s join public.businesses b on b.id = s.business_id
   where s.role = 'owner' and s.active and s.user_id is not null and b.name = 'Pristine chain fixture A'
   order by s.created_at limit 1;
  if v_business is null then raise exception 'v59 needs fixture business A'; end if;
  select id into v_client from public.clients where business_id = v_business order by created_at limit 1;
  select id into v_branch from public.branches where business_id = v_business and active order by is_default desc, created_at limit 1;
  select active_config_version_id into v_base from public.businesses where id = v_business;

  insert into public.services(business_id, name, price_cents, duration_min) values
    (v_business, 'v59 five thousand', 5000, 30),
    (v_business, 'v59 five hundred', 500, 15),
    (v_business, 'v59 custom svc', 2500, 30),
    (v_business, 'v59 appt svc', 1200, 30),
    (v_business, 'v59 pkg svc', 1000, 30);
  select id into v_svc5000 from public.services where business_id = v_business and name = 'v59 five thousand';
  select id into v_svc500 from public.services where business_id = v_business and name = 'v59 five hundred';
  select id into v_svc_custom from public.services where business_id = v_business and name = 'v59 custom svc';
  select id into v_svc_appt from public.services where business_id = v_business and name = 'v59 appt svc';
  select id into v_svc_pkg from public.services where business_id = v_business and name = 'v59 pkg svc';

  insert into public.package_plans(business_id, name, price_cents, sessions, service_id, active)
  values (v_business, 'v59 package', 3000, 5, v_svc_pkg, true) returning id into v_pkg_plan;
  insert into public.membership_plans(business_id, name, price_cents, cadence, credit_cents, active)
  values (v_business, 'v59 membership', 8000, 'monthly', 6000, true) returning id into v_mem_plan;

  -- ---- 1. Author + publish discount rules (when_event = sale.completed). ----
  perform pg_temp.as_v59_principal(v_owner, 'authenticated');
  v_cfg := (public.create_loyalty_config_draft(v_business, v_base, 'v59_discounts')::jsonb->>'version_id')::uuid;
  v_r_reg := gen_random_uuid(); v_r_zero := gen_random_uuid();
  -- R_REG: bill 10% off when subtotal == 5000 (regression + finalise/reverse journey).
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_cfg;
  perform public.save_program_rule_draft(v_cfg, v_r_reg, jsonb_build_object(
    'name', 'v59 bill 10pct at 5000', 'when_event', 'sale.completed', 'active', true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field', 'amount_cents', 'op', 'eq', 'value', 5000)),
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type', 'apply_discount_pct', 'discount_pct', 10))), v_hash);
  -- R_ZERO: bill 100% off when subtotal == 500 (typed zero-total).
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_cfg;
  perform public.save_program_rule_draft(v_cfg, v_r_zero, jsonb_build_object(
    'name', 'v59 bill 100pct at 500', 'when_event', 'sale.completed', 'active', true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field', 'amount_cents', 'op', 'eq', 'value', 500)),
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type', 'apply_discount_pct', 'discount_pct', 100))), v_hash);
  perform public.publish_loyalty_config(v_cfg);
  select active_config_version_id into v_cfg from public.businesses where id = v_business;

  -- =====================================================================
  -- 1. LEGACY-PATH PROOF: each engine works AND writes ZERO discount lines.
  -- =====================================================================
  select count(*) into v_before from public.checkout_discount_lines where business_id = v_business;

  -- 1a. sell_package (kind='package').
  perform public.sell_package(v_business, v_client, v_pkg_plan, gen_random_uuid());
  if not exists (select 1 from public.client_packages where business_id = v_business and client_id = v_client and plan_id = v_pkg_plan) then
    raise exception 'sell_package did not create a client package';
  end if;

  -- 1b. enroll_membership_v41 (kind='membership') + membership credit.
  v_res := public.enroll_membership_v41(v_business, v_client, v_mem_plan, gen_random_uuid());
  v_membership := (v_res->>'id')::uuid;
  if not exists (select 1 from public.credit_ledger where business_id = v_business and client_id = v_client
                  and entry_type = 'membership_credit' and amount_cents = 6000) then
    raise exception 'membership enrollment did not link its credit';
  end if;

  -- 1c. run_membership_renewals: age the membership then sweep -> one more credit.
  reset role;
  update public.memberships set current_period_start = now() - interval '1 month 1 day',
         current_period_end = now() - interval '1 day' where id = v_membership;
  select count(*) into v_n from public.credit_ledger where business_id = v_business
     and client_id = v_client and entry_type = 'membership_credit';
  perform app.run_membership_renewals();
  if (select count(*) from public.credit_ledger where business_id = v_business
        and client_id = v_client and entry_type = 'membership_credit') <> v_n + 1 then
    raise exception 'membership renewal did not append exactly one credit';
  end if;

  -- 1d. appointment completion (kind='service' via the completion trigger).
  reset role;
  insert into public.appointments(business_id, branch_id, client_id, staff_id, service_id, starts_at, ends_at, status, total_cents)
  values (v_business, v_branch, v_client, v_owner_staff, v_svc_appt,
          now() + interval '1 hour', now() + interval '2 hours', 'booked', 1200)
  returning id into v_appt;
  update public.appointments set status = 'completed' where id = v_appt;
  if not exists (select 1 from public.sales where business_id = v_business and appointment_id = v_appt
                  and kind = 'service' and amount_cents = 1200 and note = 'appointment completed') then
    raise exception 'appointment completion did not post its service sale';
  end if;

  -- 1e. gift-card issue + redeem (cash collected / load into credit_ledger).
  -- (table assertions run as postgres: gift_cards has no browser SELECT surface)
  perform pg_temp.as_v59_principal(v_owner, 'authenticated');
  v_gc := public.issue_gift_card(v_business, 4000, v_client, 'v59gc@example.test', v_gckey);
  reset role;
  if not exists (select 1 from public.gift_cards where business_id = v_business and code = v_gc->>'code') then
    raise exception 'issue_gift_card did not create a gift card';
  end if;
  select coalesce(sum(amount_cents), 0) into v_credit_before from public.credit_ledger
   where business_id = v_business and client_id = v_client;
  perform pg_temp.as_v59_principal(v_owner, 'authenticated');
  perform public.redeem_gift_card_v41(v_business, v_gc->>'code', v_client, 2000);
  reset role;
  if (select coalesce(sum(amount_cents), 0) from public.credit_ledger where business_id = v_business and client_id = v_client)
     <> v_credit_before + 2000 then
    raise exception 'redeem_gift_card_v41 did not load credit';
  end if;
  perform pg_temp.as_v59_principal(v_owner, 'authenticated');

  -- 1f. record_payment against an unpaid sale.
  v_res := public.record_quick_sale(v_business, 1500, 'cash', v_client, v_owner_staff, v_branch, 'v59 unpaid',
    'v59-unpaid-' || substr(md5(clock_timestamp()::text), 1, 10), false);
  v_pay_sale := (v_res #>> '{sale,id}')::uuid;
  perform public.record_payment(p_business => v_business, p_method => 'cash', p_amount_cents => 1500, p_sale => v_pay_sale,
    p_client => v_client, p_staff => v_owner_staff, p_branch => v_branch,
    p_idempotency_key => 'v59-pay-' || substr(md5(clock_timestamp()::text), 1, 8));
  if (select coalesce(sum(amount_cents), 0) from public.payments where sale_id = v_pay_sale) <> 1500 then
    raise exception 'record_payment did not settle the unpaid sale';
  end if;

  -- 1g. record_credit_tender spends the loaded gift-card credit.
  v_res := public.record_quick_sale(v_business, 1000, 'cash', v_client, v_owner_staff, v_branch, 'v59 credit-spend',
    'v59-cspend-' || substr(md5(clock_timestamp()::text), 1, 10), false);
  v_tender_sale := (v_res #>> '{sale,id}')::uuid;
  perform public.record_credit_tender(v_business, v_tender_sale, 1000, 'v59 spend store credit',
    'v59-tender-' || substr(md5(clock_timestamp()::text), 1, 8));
  if not exists (select 1 from public.credit_ledger where business_id = v_business
        and sale_id = v_tender_sale and entry_type = 'spend' and amount_cents = -1000) then
    raise exception 'record_credit_tender did not append a negative store-credit spend';
  end if;

  -- 1h. entitlement redemption (promise-only status flip; PS-1B).
  reset role;
  select entitlement_id, outcome into v_ent, v_outcome from app.ps1b_materialise_entitlement(
    v_business, v_client, v_r_reg, v_cfg, 'v59-manual', 'free_item', '{}'::jsonb,
    now(), now() + interval '30 days', 0, null, now(), now() + interval '1 month');
  if v_ent is null then raise exception 'entitlement did not materialise'; end if;
  perform pg_temp.as_v59_principal(v_owner, 'authenticated');
  v_res := public.redeem_program_entitlement(v_ent, gen_random_uuid());
  if v_res->>'status' <> 'redeemed' then raise exception 'entitlement redemption did not flip status'; end if;

  -- The whole legacy sweep produced NO checkout discount lines.
  if (select count(*) from public.checkout_discount_lines where business_id = v_business) <> v_before then
    raise exception 'a legacy value path produced a checkout discount line';
  end if;

  -- =====================================================================
  -- 2. record_cart_sale/7 RETIRED; /9 kernel is executable.
  -- =====================================================================
  reset role;
  if has_function_privilege('authenticated', 'public.record_cart_sale(uuid,uuid,uuid,uuid,text,text,jsonb)', 'execute') then
    raise exception 'the v51 record_cart_sale/7 cart path is still browser-executable';
  end if;
  if not has_function_privilege('authenticated', 'public.record_cart_sale(uuid,uuid,uuid,uuid,text,text,jsonb,uuid,boolean)', 'execute') then
    raise exception 'the kernel record_cart_sale/9 finaliser is not browser-executable';
  end if;

  -- =====================================================================
  -- 3. Impersonation guard (evaluation-level + DB-level).
  -- =====================================================================
  -- 3a. A package kind is rejected typed at evaluation.
  perform pg_temp.as_v59_principal(v_owner, 'authenticated');
  begin
    perform public.evaluate_checkout(v_business, v_branch, v_client,
      jsonb_build_array(jsonb_build_object('catalog_kind', 'package', 'catalog_id', gen_random_uuid(), 'qty', 1)),
      gen_random_uuid());
    raise exception 'a package line priced through the checkout kernel';
  exception when sqlstate '22023' then
    if position('bad_kind' in sqlerrm) = 0 then raise exception 'package rejection was not the typed bad_kind (got %)', sqlerrm; end if;
  end;

  -- 3b. A direct package sale_items line under a quick_sale parent is rejected by the guard.
  v_res := public.record_quick_sale(v_business, 3300, 'cash', v_client, v_owner_staff, v_branch, 'v59 guard parent',
    'v59-guard-' || substr(md5(clock_timestamp()::text), 1, 10), true);
  v_sale := (v_res #>> '{sale,id}')::uuid;
  reset role;
  begin
    insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents)
    values (v_sale, v_business, 'package', null, 'impersonated package', 1, 100, 100);
    raise exception 'a package line rode under a quick_sale parent';
  exception when sqlstate '23514' then
    if position('sale_items_kind_guard' in sqlerrm) = 0 then raise exception 'guard fired with an unexpected error (%)', sqlerrm; end if;
  end;
  -- Positive control: a normal service line under the same parent is allowed (guard is narrow).
  insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents)
  values (v_sale, v_business, 'service', v_svc_pkg, 'legit service line', 1, 1000, 1000);
  if not exists (select 1 from public.sale_items where sale_id = v_sale and item_type = 'service') then
    raise exception 'the guard wrongly rejected a legitimate service line';
  end if;

  -- =====================================================================
  -- 4. Custom manually-priced lines.
  -- =====================================================================
  v_lines_custom := jsonb_build_array(
    jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_svc_custom, 'qty', 1),
    jsonb_build_object('catalog_kind', 'custom', 'description', 'Ad-hoc styling', 'amount_cents', 3000, 'reason', 'walk-in special'));

  -- 4a. Owner prices a custom+service cart: no discount rule matches 5500.
  perform pg_temp.as_v59_principal(v_owner, 'authenticated');
  v_ev := public.evaluate_checkout(v_business, v_branch, v_client, v_lines_custom, gen_random_uuid());
  if (v_ev->>'total_cents')::int <> 5500 or (v_ev->>'discount_total_cents')::int <> 0 then
    raise exception 'custom cart priced wrong (got %/%)', v_ev->>'total_cents', v_ev->>'discount_total_cents';
  end if;
  v_tok := (v_ev->>'evaluation_id')::uuid;
  v_res := public.record_cart_sale(v_business, v_client, v_branch, v_owner_staff, 'cash',
    'v59-custom-' || substr(md5(clock_timestamp()::text), 1, 10), null, v_tok, true);
  v_sale := (v_res->>'sale_id')::uuid;
  if (v_res->>'total_cents')::int <> 5500 then raise exception 'custom finalise total wrong'; end if;
  if (select sum(line_cents) from public.sale_items where sale_id = v_sale) <> 5500 then
    raise exception 'custom sale_items do not reconcile to the sale total';
  end if;
  if (select count(*) from public.sale_items where sale_id = v_sale and item_type = 'custom'
        and unit_cents = 3000 and description = 'Ad-hoc styling') <> 1 then
    raise exception 'the custom sale_items line is missing or wrong';
  end if;
  if (select count(*) from public.checkout_discount_lines where sale_id = v_sale) <> 0 then
    raise exception 'a no-discount custom cart still produced a discount line';
  end if;
  -- Provenance: exactly one CUSTOM_PRICE_LINE audit row, finalising actor + entered_by + reason.
  if (select count(*) from public.audit_log where entity = 'sale_items' and action = 'CUSTOM_PRICE_LINE'
        and entity_id = v_sale and actor = v_owner
        and detail->>'reason' = 'walk-in special' and detail->>'entered_by' = v_owner::text
        and (detail->>'amount_cents')::int = 3000) <> 1 then
    raise exception 'the CUSTOM_PRICE_LINE audit provenance is missing or wrong';
  end if;

  -- 4b. A frontdesk staff WITHOUT custom_price_lines is denied.
  reset role;
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_fd_user, 'authenticated', 'authenticated',
    'v59-fd-' || substr(v_fd_user::text, 1, 8) || '@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, full_name, active)
  values (v_business, v_fd_user, 'frontdesk', 'v59 frontdesk', true) returning id into v_fd_staff;
  insert into public.staff_branches(business_id, staff_id, branch_id) values (v_business, v_fd_staff, v_branch);
  perform pg_temp.as_v59_principal(v_fd_user, 'authenticated');
  begin
    perform public.evaluate_checkout(v_business, v_branch, null,
      jsonb_build_array(jsonb_build_object('catalog_kind', 'custom', 'description', 'Ad-hoc', 'amount_cents', 1000, 'reason', 'no rights')),
      gen_random_uuid());
    raise exception 'a frontdesk without custom_price_lines entered a manual price';
  exception when sqlstate '22023' then
    if position('custom_line_denied' in sqlerrm) = 0 then raise exception 'custom denial was not typed custom_line_denied (got %)', sqlerrm; end if;
  end;

  -- 4c. Over-limit amount is a typed custom_line_limit (default cap 50000).
  perform pg_temp.as_v59_principal(v_owner, 'authenticated');
  begin
    perform public.evaluate_checkout(v_business, v_branch, null,
      jsonb_build_array(jsonb_build_object('catalog_kind', 'custom', 'description', 'Too big', 'amount_cents', 60000, 'reason', 'over the cap')),
      gen_random_uuid());
    raise exception 'an over-limit custom amount was accepted';
  exception when sqlstate '22023' then
    if position('custom_line_limit' in sqlerrm) = 0 then raise exception 'over-limit rejection was not typed custom_line_limit (got %)', sqlerrm; end if;
  end;

  -- 4d. A missing reason is a typed custom_line_invalid.
  begin
    perform public.evaluate_checkout(v_business, v_branch, null,
      jsonb_build_array(jsonb_build_object('catalog_kind', 'custom', 'description', 'No reason', 'amount_cents', 3000)),
      gen_random_uuid());
    raise exception 'a custom line without a reason was accepted';
  exception when sqlstate '22023' then
    if position('custom_line_invalid' in sqlerrm) = 0 then raise exception 'missing-reason rejection was not typed custom_line_invalid (got %)', sqlerrm; end if;
  end;

  -- 4e. A custom qty other than 1 is rejected.
  begin
    perform public.evaluate_checkout(v_business, v_branch, null,
      jsonb_build_array(jsonb_build_object('catalog_kind', 'custom', 'description', 'Two of a kind', 'amount_cents', 3000, 'reason', 'bad qty', 'qty', 2)),
      gen_random_uuid());
    raise exception 'a custom line with qty 2 was accepted';
  exception when sqlstate '22023' then
    if position('custom_line_invalid' in sqlerrm) = 0 then raise exception 'custom qty rejection was not typed custom_line_invalid (got %)', sqlerrm; end if;
  end;

  -- 4f. Regression: a price key on a SERVICE line still fails closed (client_priced).
  begin
    perform public.evaluate_checkout(v_business, v_branch, null,
      jsonb_build_array(jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_svc_custom, 'qty', 1, 'unit_price_cents', 100)),
      gen_random_uuid());
    raise exception 'a client-priced service line was accepted';
  exception when sqlstate '22023' then
    if position('client_priced' in sqlerrm) = 0 then raise exception 'catalog price-key rejection was not typed client_priced (got %)', sqlerrm; end if;
  end;

  -- =====================================================================
  -- 5. Zero-total is typed and persists nothing.
  -- =====================================================================
  select count(*) into v_eval_before from public.checkout_evaluations where business_id = v_business;
  select count(*) into v_op_before from public.checkout_evaluation_operations where business_id = v_business;
  begin
    perform public.evaluate_checkout(v_business, v_branch, v_client,
      jsonb_build_array(jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_svc500, 'qty', 1)),
      gen_random_uuid());
    raise exception 'a 100%%-discounted cart minted a token';
  exception when sqlstate '22023' then
    if position('total_zero_not_supported' in sqlerrm) <> 1 then
      raise exception 'zero-total rejection was not the typed total_zero_not_supported prefix (got %)', sqlerrm;
    end if;
  end;
  -- Nothing persisted: the op-ledger row is written only AFTER a successful plan.
  if (select count(*) from public.checkout_evaluations where business_id = v_business) <> v_eval_before then
    raise exception 'a failed zero-total plan still persisted an evaluation';
  end if;
  if (select count(*) from public.checkout_evaluation_operations where business_id = v_business) <> v_op_before then
    raise exception 'a failed zero-total plan still wrote an op-ledger row';
  end if;

  -- =====================================================================
  -- 6. Regression: the v58 discount journey evaluate -> finalise -> reverse.
  -- =====================================================================
  v_ev := public.evaluate_checkout(v_business, v_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_svc5000, 'qty', 1)), gen_random_uuid());
  if (v_ev->>'total_cents')::int <> 4500 or (v_ev->>'discount_total_cents')::int <> 500 then
    raise exception 'regression: 5000 -> 4500 discount did not price (got %/%)', v_ev->>'total_cents', v_ev->>'discount_total_cents';
  end if;
  v_tok := (v_ev->>'evaluation_id')::uuid;
  v_res := public.record_cart_sale(v_business, v_client, v_branch, v_owner_staff, 'cash',
    'v59-reg-' || substr(md5(clock_timestamp()::text), 1, 10), null, v_tok, true);
  v_sale := (v_res->>'sale_id')::uuid;
  if (select sum(line_cents) from public.sale_items where sale_id = v_sale) <> 4500 then
    raise exception 'regression: sale_items do not reconcile to 4500';
  end if;
  if (select count(*) from public.sale_items where sale_id = v_sale and item_type = 'studio_discount' and line_cents = -500) <> 1 then
    raise exception 'regression: signed studio_discount line missing';
  end if;
  if (select count(*) from public.checkout_discount_lines where sale_id = v_sale) <> 1 then
    raise exception 'regression: exactly one discount provenance row expected';
  end if;
  -- Points earn on the DISCOUNTED total (4500), not 5000.
  select earn_points_per_dollar into v_rate from public.loyalty_programs where business_id = v_business and active limit 1;
  if v_rate is not null and v_rate > 0 then
    if coalesce((select sum(points) from public.points_ledger where sale_id = v_sale and entry_type = 'earn'), 0)
       <> floor(4500 / 100.0 * v_rate)::int then
      raise exception 'regression: points did not earn on the discounted total';
    end if;
  end if;
  -- Reverse: a compensating (negative) discount fulfilment lands; provenance is append-only.
  v_res := public.reverse_sale(v_business, v_sale, 'v59 reverse a discounted kernel sale',
    'v59-rev-' || substr(md5(clock_timestamp()::text), 1, 10));
  if (v_res->>'reversal_sale_id') is null then raise exception 'regression: reversal produced no reversing sale'; end if;
  if not exists (select 1 from public.benefit_fulfilments where business_id = v_business and source_engine = 'checkout'
                  and fulfilment_kind = 'checkout_discount_reversal' and face_value_cents < 0) then
    raise exception 'regression: the compensating negative discount fulfilment is missing';
  end if;

  raise notice 'v59 PS-1C.1 legacy-cart hardening suite: ALL PASS';
end $v59_test$;

reset role;
rollback;
