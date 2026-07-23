-- Rollback-only v60 PS-1C.2 truthful-execution-state + emergency-pause suite.
-- Run after the pending chain (through v60) in a disposable rehearsal database.
-- Proves the owner's §5 states on the REAL engines: a published apply_discount_amount
-- checkout rule -> live (and the kernel applies it); a published grant_free_item recurring
-- rule -> live (and the executor materialises it); grant_credit -> shadow_testing (executor
-- shadow-logs; NO studio credit_ledger / points_loyalty fulfilment); tier_multiplier-only ->
-- ready_for_activation; send_notification-only -> ready_for_activation; a mixed
-- (apply_discount_amount + tier_multiplier) rule -> partially_live with per-effect
-- effect_states [live, unbuilt]; active=false -> paused; a superseded-version rule -> retired;
-- draft rules -> validated / draft / validation_failed. The teeth: an emergency pause on a
-- live checkout rule flips it to paused AND a subsequent evaluate_checkout stops applying the
-- discount, while EVERY prior checkout_discount_line / benefit_fulfilment / budget row remains;
-- lift restores both the state and the discount. The executor teeth: an emergency-paused
-- recurring rule materialises NOTHING; lifting restores materialisation. preview_publish_impact
-- flags requires_confirmation for a live-financial draft and clears it for an unbuilt-only draft.
-- Permission: emergency_pause / lift / set_active / preview are owner-only (anon + non-owner
-- denied). Regression: the plain v58/v59 discount journey still finalises, and
-- get_programs_overview carries the new keys without dropping the old ones. The including
-- transaction owns BEGIN/ROLLBACK; nothing commits.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v60_principal(p_uid uuid, p_role text)
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
    raise exception 'unsupported v60 principal';
  end if;
end $$;
grant execute on function pg_temp.as_v60_principal(uuid, text) to authenticated, anon;

-- Fetch one studio-rule object (by logical rule_id + config status) from the owner overview.
create or replace function pg_temp.overview_rule(p_business uuid, p_rule uuid, p_status text)
returns jsonb language sql stable as $$
  select e
    from jsonb_array_elements(public.get_programs_overview(p_business)->'studio_rules') as t(e)
   where (e->>'rule_id')::uuid = p_rule and e->>'config_status' = p_status
   order by e->>'config_version_id'
   limit 1;
$$;
grant execute on function pg_temp.overview_rule(uuid, uuid, text) to authenticated;

do $v60_test$
declare
  v_business uuid; v_owner uuid; v_owner_staff uuid; v_client uuid; v_branch uuid; v_base uuid;
  v_cfg uuid; v_cfg2 uuid; v_hash text;
  v_svc_disc uuid; v_svc_free uuid;
  v_r_disc uuid; v_r_free uuid; v_r_credit uuid; v_r_tier uuid; v_r_notify uuid; v_r_mixed uuid;
  v_r_paused uuid; v_r_free2 uuid;
  v_id_disc uuid; v_id_free uuid; v_id_credit uuid; v_id_tier uuid; v_id_notify uuid;
  v_id_mixed uuid; v_id_paused uuid; v_id_disc_super uuid;
  v_lines_disc jsonb; v_ev jsonb; v_res json; v_obj jsonb; v_effs jsonb;
  v_cdl_before int; v_ful_before int; v_bud_before int; v_state text;
  v_fresh uuid := gen_random_uuid(); v_fresh_staff uuid;
  v_pd uuid; v_prev jsonb; v_rt uuid; v_id_draft uuid;
begin
  -- ---- 0. Fixtures ----
  reset role;
  select s.business_id, s.user_id, s.id into v_business, v_owner, v_owner_staff
    from public.staff s join public.businesses b on b.id = s.business_id
   where s.role = 'owner' and s.active and s.user_id is not null and b.name = 'Pristine chain fixture A'
   order by s.created_at limit 1;
  if v_business is null then raise exception 'v60 needs the pristine fixture A'; end if;
  select id into v_client from public.clients where business_id = v_business order by created_at limit 1;
  select id into v_branch from public.branches where business_id = v_business and active order by is_default desc, created_at limit 1;
  select active_config_version_id into v_base from public.businesses where id = v_business;

  -- The fixture is created AFTER the v58 registry cutover, so its recurring + checkout
  -- families are 'studio' (live) and tier is 'unbuilt'. Assert the precondition so a later
  -- registry change can never silently invalidate the state expectations below.
  if (select cutover_status from public.benefit_registry where business_id = v_business and source_engine = 'checkout') <> 'studio'
     or (select cutover_status from public.benefit_registry where business_id = v_business and source_engine = 'recurring') <> 'studio'
     or (select cutover_status from public.benefit_registry where business_id = v_business and source_engine = 'tier') <> 'unbuilt' then
    raise exception 'v60 precondition: expected checkout/recurring=studio, tier=unbuilt in the registry';
  end if;

  insert into public.services(business_id, name, price_cents, duration_min) values
    (v_business, 'v60 disc svc', 5000, 30),
    (v_business, 'v60 free svc', 3000, 30);
  select id into v_svc_disc from public.services where business_id = v_business and name = 'v60 disc svc';
  select id into v_svc_free from public.services where business_id = v_business and name = 'v60 free svc';

  -- ---- 1. Author + publish the rule set. ----
  perform pg_temp.as_v60_principal(v_owner, 'authenticated');
  v_cfg := (public.create_loyalty_config_draft(v_business, v_base, 'v60_states')::jsonb->>'version_id')::uuid;
  v_r_disc := gen_random_uuid(); v_r_free := gen_random_uuid(); v_r_credit := gen_random_uuid();
  v_r_tier := gen_random_uuid(); v_r_notify := gen_random_uuid(); v_r_mixed := gen_random_uuid();
  v_r_paused := gen_random_uuid(); v_r_free2 := gen_random_uuid();

  -- live checkout: 1000 off (bill) when subtotal == 5000, capped 100000/month.
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_cfg;
  perform public.save_program_rule_draft(v_cfg, v_r_disc, jsonb_build_object(
    'name', 'Disc 1000 at 5000', 'when_event', 'sale.completed', 'active', true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field', 'amount_cents', 'op', 'eq', 'value', 5000)),
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type', 'apply_discount_amount', 'amount_cents', 1000)),
    'with_params', jsonb_build_object('budget_cap_cents', 100000, 'budget_period', 'monthly')), v_hash);
  -- live recurring: free item when subtotal == 6000.
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_cfg;
  perform public.save_program_rule_draft(v_cfg, v_r_free, jsonb_build_object(
    'name', 'Free item at 6000', 'when_event', 'sale.completed', 'active', true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field', 'amount_cents', 'op', 'eq', 'value', 6000)),
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type', 'grant_free_item',
      'catalog_kind', 'service', 'catalog_id', v_svc_free))), v_hash);
  -- shadow points_loyalty: grant_credit when subtotal == 7000.
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_cfg;
  perform public.save_program_rule_draft(v_cfg, v_r_credit, jsonb_build_object(
    'name', 'Credit 500 at 7000', 'when_event', 'sale.completed', 'active', true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field', 'amount_cents', 'op', 'eq', 'value', 7000)),
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type', 'grant_credit', 'amount_cents', 500))), v_hash);
  -- unbuilt tier: tier_multiplier only.
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_cfg;
  perform public.save_program_rule_draft(v_cfg, v_r_tier, jsonb_build_object(
    'name', 'Tier x2 at 8000', 'when_event', 'sale.completed', 'active', true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field', 'amount_cents', 'op', 'eq', 'value', 8000)),
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type', 'tier_multiplier', 'multiplier', 2))), v_hash);
  -- unbuilt comms: send_notification only.
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_cfg;
  perform public.save_program_rule_draft(v_cfg, v_r_notify, jsonb_build_object(
    'name', 'Notify at 8500', 'when_event', 'sale.completed', 'active', true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field', 'amount_cents', 'op', 'eq', 'value', 8500)),
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type', 'send_notification'))), v_hash);
  -- mixed: apply_discount_amount (live) FIRST, tier_multiplier (unbuilt) SECOND.
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_cfg;
  perform public.save_program_rule_draft(v_cfg, v_r_mixed, jsonb_build_object(
    'name', 'Mixed at 12345', 'when_event', 'sale.completed', 'active', true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field', 'amount_cents', 'op', 'eq', 'value', 12345)),
    'then_effects', jsonb_build_array(
      jsonb_build_object('effect_type', 'apply_discount_amount', 'amount_cents', 500),
      jsonb_build_object('effect_type', 'tier_multiplier', 'multiplier', 2))), v_hash);
  -- paused: a live-family effect but active=false.
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_cfg;
  perform public.save_program_rule_draft(v_cfg, v_r_paused, jsonb_build_object(
    'name', 'Paused disc at 9000', 'when_event', 'sale.completed', 'active', false,
    'if_conditions', jsonb_build_array(jsonb_build_object('field', 'amount_cents', 'op', 'eq', 'value', 9000)),
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type', 'apply_discount_amount', 'amount_cents', 500))), v_hash);
  -- recurring rule reserved for the executor emergency-pause teeth (subtotal == 6500).
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_cfg;
  perform public.save_program_rule_draft(v_cfg, v_r_free2, jsonb_build_object(
    'name', 'Free item at 6500', 'when_event', 'sale.completed', 'active', true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field', 'amount_cents', 'op', 'eq', 'value', 6500)),
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type', 'grant_free_item',
      'catalog_kind', 'service', 'catalog_id', v_svc_free))), v_hash);

  perform public.publish_loyalty_config(v_cfg);
  select active_config_version_id into v_cfg from public.businesses where id = v_business;

  select id into v_id_disc   from public.program_rules where rule_id = v_r_disc   and config_version_id = v_cfg;
  select id into v_id_free   from public.program_rules where rule_id = v_r_free   and config_version_id = v_cfg;
  select id into v_id_credit from public.program_rules where rule_id = v_r_credit and config_version_id = v_cfg;
  select id into v_id_tier   from public.program_rules where rule_id = v_r_tier   and config_version_id = v_cfg;
  select id into v_id_notify from public.program_rules where rule_id = v_r_notify and config_version_id = v_cfg;
  select id into v_id_mixed  from public.program_rules where rule_id = v_r_mixed  and config_version_id = v_cfg;
  select id into v_id_paused from public.program_rules where rule_id = v_r_paused and config_version_id = v_cfg;

  -- ---- 2. Published aggregate states through the owner overview (proves the repoint). ----
  if (pg_temp.overview_rule(v_business, v_r_disc,   'published')->>'aggregate_state') <> 'live' then
    raise exception 'v60: apply_discount_amount checkout rule is not live (got %)', pg_temp.overview_rule(v_business, v_r_disc, 'published')->>'aggregate_state'; end if;
  if (pg_temp.overview_rule(v_business, v_r_free,   'published')->>'aggregate_state') <> 'live' then
    raise exception 'v60: grant_free_item recurring rule is not live'; end if;
  if (pg_temp.overview_rule(v_business, v_r_credit, 'published')->>'aggregate_state') <> 'shadow_testing' then
    raise exception 'v60: grant_credit rule is not shadow_testing (got %)', pg_temp.overview_rule(v_business, v_r_credit, 'published')->>'aggregate_state'; end if;
  if (pg_temp.overview_rule(v_business, v_r_tier,   'published')->>'aggregate_state') <> 'ready_for_activation' then
    raise exception 'v60: tier_multiplier-only rule is not ready_for_activation'; end if;
  if (pg_temp.overview_rule(v_business, v_r_notify, 'published')->>'aggregate_state') <> 'ready_for_activation' then
    raise exception 'v60: send_notification-only rule is not ready_for_activation'; end if;
  if (pg_temp.overview_rule(v_business, v_r_paused, 'published')->>'aggregate_state') <> 'paused' then
    raise exception 'v60: active=false rule is not paused'; end if;

  -- Mixed rule: partially_live, with per-effect effect_states [live, unbuilt].
  v_obj := pg_temp.overview_rule(v_business, v_r_mixed, 'published');
  if (v_obj->>'aggregate_state') <> 'partially_live' then
    raise exception 'v60: mixed rule is not partially_live (got %)', v_obj->>'aggregate_state'; end if;
  v_effs := v_obj->'effect_states';
  if jsonb_array_length(v_effs) <> 2
     or (v_effs->0->>'state') <> 'live'    or (v_effs->0->>'effect_type') <> 'apply_discount_amount'
     or (v_effs->1->>'state') <> 'unbuilt' or (v_effs->1->>'effect_type') <> 'tier_multiplier'
     or (v_effs->0->>'family') <> 'checkout' or (v_effs->1->>'family') <> 'tier' then
    raise exception 'v60: mixed effect_states are not [live checkout, unbuilt tier]: %', v_effs; end if;
  -- back-compat: execution_state == aggregate_state.
  if (v_obj->>'execution_state') <> (v_obj->>'aggregate_state') then
    raise exception 'v60: execution_state and aggregate_state diverged'; end if;

  -- ---- 3. The kernel ACTUALLY applies the live discount; the executor materialises the ----
  --         live recurring grant; the shadow rule stays shadow (no studio fulfilment).
  v_lines_disc := jsonb_build_array(jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_svc_disc, 'qty', 1));
  v_ev := public.evaluate_checkout(v_business, v_branch, v_client, v_lines_disc, gen_random_uuid());
  if (v_ev->>'total_cents')::int <> 4000 or (v_ev->>'discount_total_cents')::int <> 1000 then
    raise exception 'v60: live checkout rule did not drop 5000 -> 4000 (got %/%)', v_ev->>'total_cents', v_ev->>'discount_total_cents'; end if;
  v_res := public.record_cart_sale(v_business, v_client, v_branch, v_owner_staff, 'cash',
    'v60-disc-' || substr(md5(clock_timestamp()::text), 1, 10), null, (v_ev->>'evaluation_id')::uuid, true);
  if (v_res->>'discount_total_cents')::int <> 1000 then raise exception 'v60: kernel did not finalise the live discount'; end if;

  -- executor materialises the recurring grant + shadow-logs grant_credit.
  perform pg_temp.as_v60_principal(v_owner, 'authenticated');
  perform public.record_quick_sale(v_business, 6000, 'cash', v_client, v_owner_staff, v_branch, 'v60 free trigger',
    'v60-free-' || substr(md5(clock_timestamp()::text), 1, 10), true);
  perform public.record_quick_sale(v_business, 7000, 'cash', v_client, v_owner_staff, v_branch, 'v60 credit trigger',
    'v60-credit-' || substr(md5(clock_timestamp()::text), 1, 10), true);
  reset role;
  perform app.run_studio_executor(500);
  if not exists (select 1 from public.benefit_fulfilments
                  where business_id = v_business and source_engine = 'recurring'
                    and canonical_benefit_key like 'recurring:' || v_r_free::text || ':%') then
    raise exception 'v60: the live recurring rule did not materialise a fulfilment'; end if;
  -- grant_credit is shadow ONLY: a shadow evaluation exists; NO studio points_loyalty fulfilment.
  if not exists (select 1 from public.benefit_shadow_evaluations
                  where business_id = v_business and source_engine = 'points_loyalty' and rule_id = v_r_credit) then
    raise exception 'v60: grant_credit did not shadow-log'; end if;
  if exists (select 1 from public.benefit_fulfilments where business_id = v_business and source_engine = 'points_loyalty') then
    raise exception 'v60: grant_credit produced a studio points_loyalty fulfilment (must be shadow-only)'; end if;

  -- ---- 4. EMERGENCY PAUSE TEETH (checkout): pause a live rule -> state paused; a later ----
  --         evaluate_checkout stops applying it; ALL prior provenance/fulfilment/budget
  --         rows remain; lift restores state + the discount.
  select count(*) into v_cdl_before from public.checkout_discount_lines where business_id = v_business;
  select count(*) into v_ful_before from public.benefit_fulfilments where business_id = v_business and source_engine = 'checkout';
  select count(*) into v_bud_before from public.budget_periods where business_id = v_business and rule_id = v_r_disc;
  if v_bud_before < 1 then raise exception 'v60: the capped live discount did not create a budget period'; end if;

  perform pg_temp.as_v60_principal(v_owner, 'authenticated');
  perform public.emergency_pause_studio_rule(v_business, v_r_disc, 'stop the 5000 discount now');
  if (pg_temp.overview_rule(v_business, v_r_disc, 'published')->>'aggregate_state') <> 'paused' then
    raise exception 'v60: an emergency-paused live rule did not read paused'; end if;
  -- the teeth: the discount no longer applies.
  v_ev := public.evaluate_checkout(v_business, v_branch, v_client, v_lines_disc, gen_random_uuid());
  if (v_ev->>'discount_total_cents')::int <> 0 or (v_ev->>'total_cents')::int <> 5000 then
    raise exception 'v60: an emergency-paused rule still discounted the cart (got %/%)', v_ev->>'discount_total_cents', v_ev->>'total_cents'; end if;
  -- history preserved: nothing deleted.
  if (select count(*) from public.checkout_discount_lines where business_id = v_business) <> v_cdl_before
     or (select count(*) from public.benefit_fulfilments where business_id = v_business and source_engine = 'checkout') <> v_ful_before
     or (select count(*) from public.budget_periods where business_id = v_business and rule_id = v_r_disc) <> v_bud_before then
    raise exception 'v60: an emergency pause deleted historical value rows'; end if;
  -- idempotent re-pause returns the same active pause (one active row).
  perform public.emergency_pause_studio_rule(v_business, v_r_disc, 're-pausing is a no-op');
  if (select count(*) from public.studio_rule_emergency_pauses
       where business_id = v_business and rule_id = v_r_disc and lifted_at is null) <> 1 then
    raise exception 'v60: emergency pause is not idempotent (more than one active pause)'; end if;
  -- lift restores.
  perform public.lift_emergency_pause(v_business, v_r_disc, 'crisis over');
  if (pg_temp.overview_rule(v_business, v_r_disc, 'published')->>'aggregate_state') <> 'live' then
    raise exception 'v60: lifting an emergency pause did not restore live'; end if;
  v_ev := public.evaluate_checkout(v_business, v_branch, v_client, v_lines_disc, gen_random_uuid());
  if (v_ev->>'discount_total_cents')::int <> 1000 then
    raise exception 'v60: the discount did not resume after lifting the emergency pause'; end if;

  -- ---- 5. EMERGENCY PAUSE TEETH (executor): a paused recurring rule materialises nothing; ----
  --         lifting restores materialisation.
  perform public.emergency_pause_studio_rule(v_business, v_r_free2, 'freeze the free-item grant');
  perform public.record_quick_sale(v_business, 6500, 'cash', v_client, v_owner_staff, v_branch, 'v60 free2 while paused',
    'v60-f2p-' || substr(md5(clock_timestamp()::text), 1, 10), true);
  reset role;
  perform app.run_studio_executor(500);
  if exists (select 1 from public.benefit_fulfilments
              where business_id = v_business and canonical_benefit_key like 'recurring:' || v_r_free2::text || ':%') then
    raise exception 'v60: the executor materialised an emergency-paused recurring rule'; end if;
  perform pg_temp.as_v60_principal(v_owner, 'authenticated');
  perform public.lift_emergency_pause(v_business, v_r_free2, 'unfreeze');
  perform public.record_quick_sale(v_business, 6500, 'cash', v_client, v_owner_staff, v_branch, 'v60 free2 after lift',
    'v60-f2l-' || substr(md5(clock_timestamp()::text), 1, 10), true);
  reset role;
  perform app.run_studio_executor(500);
  if not exists (select 1 from public.benefit_fulfilments
                  where business_id = v_business and canonical_benefit_key like 'recurring:' || v_r_free2::text || ':%') then
    raise exception 'v60: the executor did not materialise after lifting the emergency pause'; end if;

  -- ---- 6. NORMAL versioned pause via set_studio_rule_active (owner clone-flip-publish). ----
  perform pg_temp.as_v60_principal(v_owner, 'authenticated');
  v_res := public.set_studio_rule_active(v_business, v_r_tier, false);
  if (v_res->>'changed')::boolean is not true then raise exception 'v60: set_studio_rule_active did not version a change'; end if;
  select active_config_version_id into v_cfg2 from public.businesses where id = v_business;
  if v_cfg2 = v_cfg then raise exception 'v60: set_studio_rule_active did not publish a new active version'; end if;
  if (pg_temp.overview_rule(v_business, v_r_tier, 'published')->>'aggregate_state') <> 'paused' then
    raise exception 'v60: a normally-paused (active=false) rule is not paused in the new version'; end if;
  -- a no-op (already inactive) creates NO new version.
  v_res := public.set_studio_rule_active(v_business, v_r_tier, false);
  if (v_res->>'changed')::boolean is not false then raise exception 'v60: a no-op set_active still versioned'; end if;
  if (select active_config_version_id from public.businesses where id = v_business) <> v_cfg2 then
    raise exception 'v60: a no-op set_active changed the active version'; end if;

  -- ---- 7. SUPERSEDED -> retired (v_cfg was superseded by the set_active publish). ----
  reset role;
  if (select status from public.firm_config_versions where id = v_cfg) <> 'superseded' then
    raise exception 'v60: the prior config version was not superseded by set_active'; end if;
  select id into v_id_disc_super from public.program_rules where rule_id = v_r_disc and config_version_id = v_cfg;
  if app.ps1c2_rule_state(v_business, v_id_disc_super, 'superseded', true) <> 'retired' then
    raise exception 'v60: a superseded-version rule is not retired'; end if;

  -- ---- 8. DRAFT branch: validated / draft / validation_failed as authored. ----
  perform pg_temp.as_v60_principal(v_owner, 'authenticated');
  v_pd := (public.create_loyalty_config_draft(v_business, v_cfg2, 'v60_draft_states')::jsonb->>'version_id')::uuid;
  v_rt := gen_random_uuid();
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_pd;
  -- a valid, effect-bearing draft rule -> validated.
  perform public.save_program_rule_draft(v_pd, v_rt, jsonb_build_object(
    'name', 'Draft valid', 'when_event', 'sale.completed', 'active', true,
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type', 'apply_discount_amount', 'amount_cents', 250))), v_hash);
  reset role;
  select id into v_id_draft from public.program_rules where rule_id = v_rt and config_version_id = v_pd;
  if app.ps1c2_rule_state(v_business, v_id_draft, 'draft', true) <> 'validated' then
    raise exception 'v60: a valid effect-bearing draft rule is not validated'; end if;
  -- zero effects -> draft.
  update public.program_rules set then_effects = '[]'::jsonb where id = v_id_draft;
  if app.ps1c2_rule_state(v_business, v_id_draft, 'draft', true) <> 'draft' then
    raise exception 'v60: a zero-effect draft rule is not draft'; end if;
  -- an invalid effect -> validation_failed.
  update public.program_rules set then_effects = jsonb_build_array(jsonb_build_object('effect_type', 'not_a_real_effect'))
   where id = v_id_draft;
  if app.ps1c2_rule_state(v_business, v_id_draft, 'draft', true) <> 'validation_failed' then
    raise exception 'v60: an invalid draft rule is not validation_failed'; end if;

  -- ---- 9. preview_publish_impact: live-financial draft requires confirmation; ----
  --         an unbuilt-only draft does not.
  perform pg_temp.as_v60_principal(v_owner, 'authenticated');
  -- (a) clone the live active config (carries the live checkout rule) -> requires_confirmation.
  v_pd := (public.create_loyalty_config_draft(v_business, v_cfg2, 'v60_preview_live')::jsonb->>'version_id')::uuid;
  v_prev := public.preview_publish_impact(v_pd);
  if (v_prev->>'requires_confirmation')::boolean is not true
     or (v_prev->>'will_activate_live_financial')::boolean is not true then
    raise exception 'v60: preview of a live-financial draft did not require confirmation'; end if;
  -- (b) a draft based on the pristine base (no studio rules) with a single unbuilt tier rule.
  v_pd := (public.create_loyalty_config_draft(v_business, v_base, 'v60_preview_unbuilt')::jsonb->>'version_id')::uuid;
  v_rt := gen_random_uuid();
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_pd;
  perform public.save_program_rule_draft(v_pd, v_rt, jsonb_build_object(
    'name', 'Unbuilt tier only', 'when_event', 'sale.completed', 'active', true,
    'then_effects', jsonb_build_array(jsonb_build_object('effect_type', 'tier_multiplier', 'multiplier', 2))), v_hash);
  v_prev := public.preview_publish_impact(v_pd);
  if (v_prev->>'requires_confirmation')::boolean is not false
     or (v_prev->>'will_activate_live_financial')::boolean is not false then
    raise exception 'v60: preview of an unbuilt-only draft wrongly required confirmation'; end if;

  -- ---- 10. Permission: owner-only mutations; anon + non-owner denied. ----
  -- anon.
  perform pg_temp.as_v60_principal(null, 'anon');
  begin perform public.emergency_pause_studio_rule(v_business, v_r_disc, 'anon attempt');
    raise exception 'v60: anon paused a rule'; exception when insufficient_privilege then null; end;
  begin perform public.set_studio_rule_active(v_business, v_r_disc, false);
    raise exception 'v60: anon set a rule active'; exception when insufficient_privilege then null; end;
  begin perform public.preview_publish_impact(v_cfg2);
    raise exception 'v60: anon previewed publish impact'; exception when insufficient_privilege then null; end;
  -- non-owner staff of the SAME business (frontdesk: create_sales but not owner).
  reset role;
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_fresh, 'authenticated', 'authenticated',
    'v60-fd-' || substr(v_fresh::text, 1, 8) || '@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, full_name, active)
  values (v_business, v_fresh, 'frontdesk', 'v60 frontdesk', true) returning id into v_fresh_staff;
  perform pg_temp.as_v60_principal(v_fresh, 'authenticated');
  begin perform public.emergency_pause_studio_rule(v_business, v_r_disc, 'frontdesk attempt');
    raise exception 'v60: a non-owner paused a rule'; exception when sqlstate '42501' then null; end;
  begin perform public.lift_emergency_pause(v_business, v_r_disc, 'frontdesk attempt');
    raise exception 'v60: a non-owner lifted a pause'; exception when sqlstate '42501' then null; end;
  begin perform public.set_studio_rule_active(v_business, v_r_disc, false);
    raise exception 'v60: a non-owner set a rule active'; exception when sqlstate '42501' then null; end;
  begin perform public.preview_publish_impact(v_cfg2);
    raise exception 'v60: a non-owner previewed publish impact'; exception when sqlstate '42501' then null; end;

  -- ---- 11. Regression: the v58/v59 discount journey still finalises, and the overview ----
  --          carries the new keys without dropping the old ones.
  perform pg_temp.as_v60_principal(v_owner, 'authenticated');
  v_ev := public.evaluate_checkout(v_business, v_branch, v_client, v_lines_disc, gen_random_uuid());
  v_res := public.record_cart_sale(v_business, v_client, v_branch, v_owner_staff, 'cash',
    'v60-reg-' || substr(md5(clock_timestamp()::text), 1, 10), null, (v_ev->>'evaluation_id')::uuid, true);
  if (v_res->>'status') <> 'ok' or (v_res->>'discount_total_cents')::int <> 1000 then
    raise exception 'v60: the plain v58/v59 discount journey regressed'; end if;
  v_obj := pg_temp.overview_rule(v_business, v_r_disc, 'published');
  if not (v_obj ? 'aggregate_state' and v_obj ? 'effect_states' and v_obj ? 'execution_state'
          and v_obj ? 'name' and v_obj ? 'active' and v_obj ? 'when_event' and v_obj ? 'then_effects') then
    raise exception 'v60: get_programs_overview lost an old key or is missing a new one'; end if;

  -- browser-write ACL: the emergency-pause table is read-only to browsers.
  reset role;
  if has_table_privilege('authenticated', 'public.studio_rule_emergency_pauses', 'insert')
     or has_table_privilege('authenticated', 'public.studio_rule_emergency_pauses', 'update')
     or has_table_privilege('authenticated', 'public.studio_rule_emergency_pauses', 'delete') then
    raise exception 'v60: browser roles retain direct writes to studio_rule_emergency_pauses'; end if;

  raise notice 'v60 PS-1C.2 truthful-execution-state + emergency-pause suite: ALL PASS';
end $v60_test$;

reset role;
rollback;
