-- nestly_v394 — a paused or soft-deleted tier grants nothing at the till
--
-- FINDING (2026-08-20, rolled-back probe against production): app.v365_client_tier — the
-- CHECKOUT tier authority — selects the customer's rung from public.loyalty_tiers without
-- filtering coalesce(paused,false)=false or deleted_at is null (those lifecycle columns
-- postdate v365). The v393 DISPLAY helper filters both, so since 2026-08-19 what a customer
-- SEES and what checkout GRANTS diverge. Proven end to end through the real planner on a
-- synthetic rolled-back tenant: with the tier paused (and again with it soft-deleted) the
-- customer app showed NO tier while app.ps1c_plan_checkout still applied the tier benefit's
-- 20% ($100.00 cut -> $80.00). v393's header records the deferral ("v365 is the CHECKOUT
-- authority and is deliberately not touched here"); this migration is the ruling that closes it.
--
-- OWNER RULING (2026-08-20): paused and soft-deleted tiers BOTH grant nothing — no checkout
-- discount, no staff-issuable benefit. The customer falls to the next live rung below,
-- exactly as the display already computes it. Checkout and display agree again.
--
-- Four sites, because the hole is two-dimensional (the customer's RUNG can come from a dead
-- tier, and a live rung can inherit a benefit DONATED by a dead tier down the ladder):
--   1. app.v365_client_tier             — the rung: filter paused/deleted from the ladder.
--   2. app.ps1c_plan_checkout           — the V370 auto tier discount joins loyalty_tiers for
--                                         the benefit's own tier; it checked the BENEFIT's
--                                         deleted_at/active but never the TIER's lifecycle.
--   3. public.staff_tier_benefits_for_client_v365 — same join, same hole: the staff Give
--                                         screen listed benefits of paused/deleted tiers.
--   4. public.staff_issue_tier_benefit_v365 — loaded the benefit's tier with no lifecycle
--                                         check, so such a benefit could actually be issued.
--
-- Everything else in the four bodies is byte-identical to production (patched from live
-- pg_get_functiondef output, not retyped). Exposure at ruling time was latent, not active:
-- the only paused/deleted tiers in production belong to the Cubbly demo tenant and none
-- carries an unlimited discount benefit.
--
-- Recorded, not changed here: staff_issue_tier_benefit_v365 still does not check the
-- benefit tier's effective_from/expires_at window (ps1c and the listing both do); a
-- benefit of an EXPIRED tier remains issuable via Give. Separate ruling if it matters.

begin;

set search_path = pg_catalog, public, app, pg_temp;

CREATE OR REPLACE FUNCTION app.v365_client_tier(p_business uuid, p_client uuid)
 RETURNS loyalty_tiers
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_basis text;
  v_metric numeric := 0;
  v_tier public.loyalty_tiers%rowtype;
begin
  select coalesce(tier_basis,'visits') into v_basis
    from public.loyalty_programs where business_id=p_business and active limit 1;
  if v_basis='spend' then
    select coalesce(sum(amount_cents),0)/100.0 into v_metric from public.sales
     where business_id=p_business and client_id=p_client and counts_as_revenue;
  elsif v_basis='points_earned' then
    select coalesce(sum(points),0) into v_metric from public.points_ledger
     where business_id=p_business and client_id=p_client and entry_type='earn';
  else
    select count(*) into v_metric from public.sales
     where business_id=p_business and client_id=p_client and counts_as_visit;
  end if;
  select * into v_tier from public.loyalty_tiers
   where business_id=p_business and threshold<=v_metric
     and coalesce(paused,false)=false and deleted_at is null
     and (effective_from is null or effective_from<=statement_timestamp())
     and (expires_at is null or expires_at>statement_timestamp())
   order by threshold desc, sort desc, id limit 1;
  return v_tier;
end $function$;

-- Restate the live ACL verbatim (proacl {postgres=X/postgres}): owner-only, no API role.

revoke all on function app.v365_client_tier(uuid, uuid) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION app.ps1c_plan_checkout(p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_config uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_line jsonb; v_ord int := 0; v_n int;
  v_kind text[]; v_id uuid[]; v_name text[]; v_unit int[]; v_qty int[]; v_ltot int[]; v_rem int[];
  v_entered_by uuid[]; v_lreason text[];
  v_subtotal bigint := 0; v_price jsonb; v_pstatus text; v_nm text;
  v_server jsonb := '[]'::jsonb; v_entry jsonb;
  v_payload jsonb; v_active_rules boolean := (p_config is not null);
  r record; v_eff jsonb; v_idx int; v_etype text; v_ckind text; v_cid uuid; v_level text;
  v_stackable boolean; v_cap int; v_period text;
  v_cand jsonb := '[]'::jsonb;
  v_applied jsonb := '[]'::jsonb;
  v_total_discount bigint := 0; v_any_line boolean := false; v_any_bill boolean := false;
  c jsonb; v_target int; v_base int; v_d int; v_reason text; v_suppressed boolean;
  -- V370: the automatic tier discount.
  v_nonstack_applied boolean := false;
  v_tier_benefit record; v_tier_base int; v_tier_d int;
  v_ps timestamptz; v_pe timestamptz; v_committed int; v_projected int;
  v_rule_proj jsonb := '{}'::jsonb; v_gst_reg boolean; v_gst_bps int; v_total int; v_gst int;
  j int;
  v_desc text; v_camt numeric; v_creason text; v_limit int; v_may_custom boolean;
  v_bundle jsonb; v_bline jsonb; v_bsrc uuid[]; v_bsrcqty int[];
  v_key text;
begin
  if jsonb_typeof(p_lines) <> 'array' then
    return jsonb_build_object('status', 'invalid', 'reason', 'lines must be a JSON array');
  end if;
  v_n := jsonb_array_length(p_lines);
  if v_n < 1 or v_n > 50 then
    return jsonb_build_object('status', 'invalid', 'reason', 'a cart must have between 1 and 50 lines');
  end if;

  select coalesce(custom_line_limit_cents, 50000) into v_limit from public.businesses where id = p_business;
  v_limit := coalesce(v_limit, 50000);
  v_may_custom := app.is_salon_owner(p_business) or app.has_perm(p_business, 'custom_price_lines');

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_ord := v_ord + 1;
    v_ckind := v_line->>'catalog_kind';
    if v_ckind is null or v_ckind not in ('service', 'product', 'custom', 'bundle') then
      return jsonb_build_object('status', 'bad_kind', 'line', v_ord,
        'reason', 'catalog_kind must be service, product, bundle or custom');
    end if;

    if v_ckind = 'custom' then
      for v_key in select jsonb_object_keys(v_line) loop
        if v_key not in ('catalog_kind', 'description', 'amount_cents', 'reason', 'qty') then
          return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
            'reason', 'custom_line_invalid: a custom line carries only catalog_kind, description, amount_cents and reason');
        end if;
      end loop;
      if not v_may_custom then
        return jsonb_build_object('status', 'custom_line_denied', 'line', v_ord,
          'reason', 'custom_line_denied: you do not have permission to enter a manual price (custom_price_lines)');
      end if;
      if v_line ? 'qty' then
        if jsonb_typeof(v_line->'qty') is distinct from 'number'
           or (v_line->>'qty')::numeric <> 1 then
          return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
            'reason', 'custom_line_invalid: a custom line quantity is always 1');
        end if;
      end if;
      if jsonb_typeof(v_line->'amount_cents') is distinct from 'number' then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: a custom line requires a numeric amount_cents');
      end if;
      v_camt := (v_line->>'amount_cents')::numeric;
      if v_camt <> trunc(v_camt) or v_camt = 0 then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: amount_cents must be a whole number of cents and cannot be zero');
      end if;
      if abs(v_camt) > v_limit then
        return jsonb_build_object('status', 'custom_line_limit', 'line', v_ord,
          'reason', 'custom_line_limit: amount_cents exceeds this business''s manual-price limit of '
                    || v_limit || ' cents');
      end if;
      v_desc := btrim(coalesce(v_line->>'description', ''));
      v_creason := btrim(coalesce(v_line->>'reason', ''));
      if length(v_desc) < 3 or length(v_desc) > 200 then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: a custom line needs a description of 3 to 200 characters');
      end if;
      if length(v_creason) > 200 then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: a custom line reason cannot exceed 200 characters');
      end if;
      v_kind := array_append(v_kind, 'custom');
      v_id := array_append(v_id, null::uuid);
      v_name := array_append(v_name, v_desc);
      v_unit := array_append(v_unit, v_camt::int);
      v_qty := array_append(v_qty, 1);
      v_ltot := array_append(v_ltot, v_camt::int);
      v_rem := array_append(v_rem, v_camt::int);
      v_entered_by := array_append(v_entered_by, auth.uid());
      v_lreason := array_append(v_lreason, v_creason);
      v_bsrc := array_append(v_bsrc, null::uuid);
      v_bsrcqty := array_append(v_bsrcqty, null::int);
      v_subtotal := v_subtotal + v_camt::int;
      continue;
    end if;

    if v_line ? 'unit_price_cents' or v_line ? 'price_cents' or v_line ? 'amount_cents'
       or v_line ? 'line_total_cents' or v_line ? 'unit_cents' or v_line ? 'discount' then
      return jsonb_build_object('status', 'client_priced', 'line', v_ord,
        'reason', 'checkout lines carry catalog_kind + catalog_id + qty ONLY; nothing is client-priceable');
    end if;
    if jsonb_typeof(v_line->'qty') is distinct from 'number' then
      return jsonb_build_object('status', 'bad_qty', 'line', v_ord, 'reason', 'qty must be a number');
    end if;
    if (v_line->>'qty')::numeric <> trunc((v_line->>'qty')::numeric)
       or (v_line->>'qty')::numeric < 1 or (v_line->>'qty')::numeric > 1000000 then
      return jsonb_build_object('status', 'bad_qty', 'line', v_ord, 'reason', 'qty must be a whole number 1..1000000');
    end if;
    v_cid := nullif(v_line->>'catalog_id', '')::uuid;
    if v_ckind = 'bundle' then
      v_bundle := app.ps1c_bundle_lines_v204(p_business, v_cid, (v_line->>'qty')::int);
      if v_bundle->>'status' <> 'ok' then
        return jsonb_build_object('status', 'price_error', 'line', v_ord,
          'catalog_kind', 'bundle', 'catalog_id', v_cid,
          'reason', (v_bundle->>'status') || ':' || coalesce(v_bundle->>'reason', ''));
      end if;
      for v_bline in select * from jsonb_array_elements(v_bundle->'lines') loop
        v_kind := array_append(v_kind, 'service');
        v_id := array_append(v_id, (v_bline->>'service_id')::uuid);
        v_name := array_append(v_name, v_bline->>'name');
        v_unit := array_append(v_unit, (v_bline->>'line_cents')::int);
        v_qty := array_append(v_qty, 1);
        v_ltot := array_append(v_ltot, (v_bline->>'line_cents')::int);
        v_rem := array_append(v_rem, (v_bline->>'line_cents')::int);
        v_entered_by := array_append(v_entered_by, null::uuid);
        v_lreason := array_append(v_lreason, null::text);
        v_bsrc := array_append(v_bsrc, v_cid);
        v_bsrcqty := array_append(v_bsrcqty, (v_line->>'qty')::int);
        v_subtotal := v_subtotal + (v_bline->>'line_cents')::int;
      end loop;
      continue;
    end if;
    v_price := app.ps1b_catalog_price(p_business, v_ckind, v_cid);
    v_pstatus := v_price->>'status';
    if v_pstatus <> 'ok' then
      return jsonb_build_object('status', 'price_error', 'line', v_ord, 'catalog_kind', v_ckind,
        'catalog_id', v_cid, 'reason', v_pstatus || ':' || coalesce(v_price->>'reason', ''));
    end if;
    if v_ckind = 'service' then
      select name into v_nm from public.services where id = v_cid and business_id = p_business;
    else
      select name into v_nm from public.products where id = v_cid and business_id = p_business;
    end if;
    v_kind := array_append(v_kind, v_ckind);
    v_id := array_append(v_id, v_cid);
    v_name := array_append(v_name, coalesce(v_nm, v_ckind));
    v_unit := array_append(v_unit, (v_price->>'price_cents')::int);
    v_qty := array_append(v_qty, (v_line->>'qty')::int);
    v_ltot := array_append(v_ltot, (v_price->>'price_cents')::int * (v_line->>'qty')::int);
    v_rem := array_append(v_rem, (v_price->>'price_cents')::int * (v_line->>'qty')::int);
    v_entered_by := array_append(v_entered_by, null::uuid);
    v_lreason := array_append(v_lreason, null::text);
    v_bsrc := array_append(v_bsrc, null::uuid);
    v_bsrcqty := array_append(v_bsrcqty, null::int);
    v_subtotal := v_subtotal + ((v_price->>'price_cents')::int * (v_line->>'qty')::int);
  end loop;

  if v_subtotal <= 0 then
    return jsonb_build_object('status', 'invalid', 'reason', 'a checkout must total more than zero');
  end if;
  if v_subtotal > 2147483647 then
    return jsonb_build_object('status', 'invalid', 'reason', 'checkout subtotal exceeds the supported maximum');
  end if;

  for j in 1 .. array_length(v_kind, 1) loop
    v_entry := jsonb_build_object(
      'catalog_kind', v_kind[j], 'catalog_id', v_id[j], 'name', v_name[j],
      'unit_price_cents', v_unit[j], 'qty', v_qty[j], 'line_total_cents', v_ltot[j]);
    if v_kind[j] = 'custom' then
      v_entry := v_entry || jsonb_build_object('entered_by', v_entered_by[j], 'reason', v_lreason[j]);
    end if;
    if v_bsrc[j] is not null then
      v_entry := v_entry || jsonb_build_object('bundle_id', v_bsrc[j], 'bundle_qty', v_bsrcqty[j]);
    end if;
    v_server := v_server || jsonb_build_array(v_entry);
  end loop;

  v_payload := jsonb_build_object('amount_cents', v_subtotal, 'kind', 'cart_sale',
    'branch_id', to_jsonb(p_branch::text), 'client_id', to_jsonb(coalesce(p_client::text, '')),
    'counts_as_visit', true, 'earns_points', true);
  if v_active_rules then
    for r in select c2.rule_id, c2.compiled from public.program_rules_compiled c2
              where c2.business_id = p_business and c2.config_version_id = p_config
                and c2.when_event = 'sale.completed' and c2.active
                and not exists (select 1 from public.studio_rule_emergency_pauses ep
                                 where ep.business_id = p_business and ep.rule_id = c2.rule_id
                                   and ep.lifted_at is null)
              order by c2.rule_id loop
      if not app.ps1b_eval_conditions(v_payload, r.compiled->'if') then continue; end if;
      v_stackable := coalesce((r.compiled->'using'->>'stackable')::boolean, true);
      v_cap := nullif(r.compiled->'with'->>'budget_cap_cents', '')::int;
      v_period := coalesce(r.compiled->'with'->>'budget_period', 'monthly');
      v_idx := 0;
      for v_eff in select * from jsonb_array_elements(coalesce(r.compiled->'then', '[]'::jsonb)) loop
        v_etype := v_eff->>'effect_type';
        if v_etype in ('apply_discount_pct', 'apply_discount_amount') then
          v_ckind := nullif(v_eff->>'catalog_kind', '');
          v_cid := nullif(v_eff->>'catalog_id', '')::uuid;
          v_level := case when v_ckind is not null and v_cid is not null then 'line' else 'bill' end;
          v_cand := v_cand || jsonb_build_array(jsonb_build_object(
            'rule_id', r.rule_id, 'effect_index', v_idx, 'effect_type', v_etype, 'level', v_level,
            'catalog_kind', v_ckind, 'catalog_id', v_cid,
            'discount_pct', v_eff->>'discount_pct', 'amount_cents', v_eff->>'amount_cents',
            'stackable', v_stackable, 'cap_cents', v_cap, 'period', v_period));
        end if;
        v_idx := v_idx + 1;
      end loop;
    end loop;
  end if;

  for c in
    select e from jsonb_array_elements(v_cand) e
     order by (e->>'level') desc,
              (e->>'rule_id'), (e->>'effect_index')::int
  loop
    v_suppressed := false; v_reason := null; v_d := 0; v_target := null;
    v_stackable := (c->>'stackable')::boolean;
    v_cap := nullif(c->>'cap_cents', '')::int;
    v_period := c->>'period';

    if not v_stackable and ((c->>'level' = 'line' and v_any_line) or (c->>'level' = 'bill' and v_any_bill)) then
      v_suppressed := true; v_reason := 'stacking';
    end if;

    if not v_suppressed then
      if c->>'level' = 'line' then
        v_target := null;
        for j in 1 .. array_length(v_kind, 1) loop
          if v_kind[j] = (c->>'catalog_kind') and v_id[j] = nullif(c->>'catalog_id', '')::uuid and v_rem[j] > 0 then
            v_target := j; exit;
          end if;
        end loop;
        if v_target is null then
          v_suppressed := true; v_reason := 'no_target';
        else
          v_base := v_rem[v_target];
        end if;
      else
        v_base := (v_subtotal - v_total_discount)::int;
        if v_base <= 0 then v_suppressed := true; v_reason := 'no_target'; end if;
      end if;
    end if;

    if not v_suppressed then
      if c->>'effect_type' = 'apply_discount_pct' then
        v_d := round(v_base::numeric * (c->>'discount_pct')::numeric / 100.0)::int;
      else
        v_d := least((c->>'amount_cents')::int, v_base);
      end if;
      if v_d > v_base then v_d := v_base; end if;
      if v_d < 0 then v_d := 0; end if;
      if v_d = 0 then v_suppressed := true; v_reason := 'no_target'; end if;
    end if;

    v_ps := null; v_pe := null;
    if v_cap is not null then
      select period_start, period_end into v_ps, v_pe from app.ps1c_period_bounds(now(), v_period);
    end if;
    if not v_suppressed and v_cap is not null then
      select coalesce(committed_cents, 0) into v_committed from public.budget_periods
       where business_id = p_business and rule_id = (c->>'rule_id')::uuid and period_start = v_ps;
      v_committed := coalesce(v_committed, 0);
      v_projected := coalesce((v_rule_proj->>(c->>'rule_id'))::int, 0);
      if v_committed + v_projected + v_d > v_cap then
        v_suppressed := true; v_reason := 'budget_exhausted';
      else
        v_rule_proj := v_rule_proj || jsonb_build_object(c->>'rule_id', v_projected + v_d);
      end if;
    end if;

    if v_suppressed then
      v_applied := v_applied || jsonb_build_array(jsonb_build_object(
        'rule_id', c->>'rule_id', 'effect_index', (c->>'effect_index')::int, 'effect_type', c->>'effect_type',
        'level', c->>'level', 'target_line_index', v_target, 'amount_cents', 0,
        'suppressed', true, 'suppression_reason', v_reason,
        'capped', v_cap is not null, 'cap_cents', v_cap,
        'period_start', v_ps, 'period_end', v_pe));
    else
      if c->>'level' = 'line' then
        v_rem[v_target] := v_rem[v_target] - v_d; v_any_line := true;
      else
        v_any_bill := true;
      end if;
      v_total_discount := v_total_discount + v_d;
      if not v_stackable then v_nonstack_applied := true; end if;
      v_applied := v_applied || jsonb_build_array(jsonb_build_object(
        'rule_id', c->>'rule_id', 'effect_index', (c->>'effect_index')::int, 'effect_type', c->>'effect_type',
        'level', c->>'level', 'target_line_index', v_target, 'amount_cents', v_d,
        'suppressed', false, 'suppression_reason', null,
        'capped', v_cap is not null, 'cap_cents', v_cap,
        'period_start', v_ps, 'period_end', v_pe));
    end if;
  end loop;

  -- ===========================================================================================
  -- V370 — THE AUTOMATIC TIER DISCOUNT (owner: "for tiers it will be automatic if there is a
  -- discount % allocated to it").
  -- It is applied HERE, inside the single pricing authority, rather than by the till: a discount
  -- the browser subtracted for itself would make the sale total and this engine disagree, which
  -- is the two-sources-of-truth failure this codebase keeps paying for.
  -- Four rules, each a decision worth stating:
  --   * ONE discount, never stacked. The best (highest) percentage the customer's rung entitles
  --     them to, inherited down the ladder like every other tier benefit. Stacking Gold's 10%
  --     under Diamond's 30% would compound into a number no owner chose.
  --   * UNLIMITED benefits only. A discount carrying a per-period limit has to be COUNTED when it
  --     is used, and counting belongs to the staff-pressed Give button that already does it
  --     (staff_issue_tier_benefit_v365). Applying a limited one here would spend it silently on
  --     every bill and never record the spend.
  --   * Suppressed when a NON-STACKABLE rule effect has already applied. That rule said it does
  --     not stack; a tier discount landing on top would break the promise the owner authored.
  --   * V394: the tier lifecycle is honoured — a paused or soft-deleted tier neither sets the
  --     customer's rung (app.v365_client_tier filters both since v394) nor donates its benefit
  --     down the ladder (this SELECT filters t.paused/t.deleted_at). Owner ruling 2026-08-20:
  --     paused and deleted tiers grant nothing, matching what customers see (v393 display).
  --   * It carries rule_id null and source 'tier_benefit'. public.checkout_discount_lines is keyed
  --     on a real rule and its rule_id is NOT NULL, so record_cart_sale skips that provenance row
  --     for this effect and records the fulfilment and the signed sale_items line instead.
  -- ===========================================================================================
  if p_client is not null then
    select b.id, b.tier_id, b.label, b.discount_percent
      into v_tier_benefit
      from public.tier_benefits_v365 b
      join public.loyalty_tiers t on t.id = b.tier_id and t.business_id = b.business_id
     where b.business_id = p_business
       and b.deleted_at is null and b.active
       and b.benefit_kind = 'discount_pct'
       and b.limit_count is null
       and coalesce(t.paused, false) = false and t.deleted_at is null
       and t.threshold <= coalesce((app.v365_client_tier(p_business, p_client)).threshold, -1)
       and (t.effective_from is null or t.effective_from <= statement_timestamp())
       and (t.expires_at is null or t.expires_at > statement_timestamp())
     order by b.discount_percent desc, t.threshold desc, b.id
     limit 1;

    if v_tier_benefit.id is not null and not v_nonstack_applied then
      v_tier_base := (v_subtotal - v_total_discount)::int;
      if v_tier_base > 0 then
        v_tier_d := round(v_tier_base::numeric * v_tier_benefit.discount_percent / 100.0)::int;
        if v_tier_d > 0 then
          v_total_discount := v_total_discount + v_tier_d;
          v_applied := v_applied || jsonb_build_array(jsonb_build_object(
            'rule_id', null, 'effect_index', 0, 'effect_type', 'apply_discount_pct',
            'level', 'bill', 'target_line_index', null, 'amount_cents', v_tier_d,
            'suppressed', false, 'suppression_reason', null,
            'capped', false, 'cap_cents', null,
            'period_start', null, 'period_end', null,
            'source', 'tier_benefit', 'tier_benefit_id', v_tier_benefit.id,
            'tier_id', v_tier_benefit.tier_id, 'label', v_tier_benefit.label,
            'discount_pct', v_tier_benefit.discount_percent));
        end if;
      end if;
    end if;
  end if;

  v_total := (v_subtotal - v_total_discount)::int;

  if v_total = 0 then
    return jsonb_build_object('status', 'total_zero_not_supported',
      'reason', 'total_zero_not_supported: this checkout is fully discounted to zero and a zero-value sale is not supported; adjust the cart or the discount');
  end if;

  select gst_registered, gst_rate_bps into v_gst_reg, v_gst_bps from public.businesses where id = p_business;
  if coalesce(v_gst_reg, false) and coalesce(v_gst_bps, 0) > 0 then
    v_gst := round(v_total::numeric * v_gst_bps / (10000 + v_gst_bps))::int;
  else
    v_gst_bps := 0; v_gst := 0;
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'server_lines', v_server,
    'subtotal_cents', v_subtotal::int,
    'applied_effects', v_applied,
    'discount_total_cents', v_total_discount::int,
    'total_cents', v_total,
    'gst_cents', v_gst,
    'gst_rate_bps', coalesce(v_gst_bps, 0),
    'cart_hash', app.ps1c_cart_hash(v_server));
end $function$;

-- Restate the live ACL verbatim (proacl {postgres=X/postgres}): owner-only, no API role.

revoke all on function app.ps1c_plan_checkout(uuid, uuid, uuid, jsonb, uuid) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.staff_tier_benefits_for_client_v365(p_business uuid, p_client uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_tier public.loyalty_tiers%rowtype;
  v_rows jsonb;
  v_birthday boolean;
begin
  if auth.uid() is null then raise exception 'authenticated staff required' using errcode='42501'; end if;
  if not (app.is_salon_owner(p_business) or app.can_module_read(p_business,'till')
          or app.can_module_read(p_business,'loyalty')) then
    raise exception 'till or loyalty access required' using errcode='42501';
  end if;
  perform 1 from public.clients where id=p_client and business_id=p_business;
  if not found then raise exception 'client not found in this business' using errcode='42704'; end if;

  v_tier := app.v365_client_tier(p_business,p_client);
  if v_tier.id is null then
    return jsonb_build_object('status','ok','tier',null,'benefits','[]'::jsonb);
  end if;
  v_birthday := coalesce(app.v367_in_birthday_month(p_client, now()), false);

  select coalesce(jsonb_agg(jsonb_build_object(
      'benefit_id',b.id,'tier_id',b.tier_id,'tier_label',t.name,'label',b.label,
      'benefit_kind',b.benefit_kind,'discount_percent',b.discount_percent,
      'product_id',b.product_id,
      'item_label',coalesce((select p.name from public.products p where p.id=b.product_id),b.item_label),
      'limit_count',b.limit_count,'limit_period',b.limit_period,
      'sentence',app.v365_benefit_sentence(b.label,b.limit_count,b.limit_period),
      'used',used.count_in_period,
      'remaining',case when b.limit_count is null then null
                       else greatest(0,b.limit_count-used.count_in_period) end,
      'claimable_now',(b.limit_period<>'birthday_month' or v_birthday)
        and (b.limit_count is null or used.count_in_period < b.limit_count),
      'blocked_reason',case when b.limit_period='birthday_month' and not v_birthday then 'not_birthday_month'
                            when b.limit_count is not null and used.count_in_period >= b.limit_count then 'used_up'
                            else null end
    ) order by t.threshold desc, b.sort, b.id),'[]'::jsonb) into v_rows
    from public.tier_benefits_v365 b
    join public.loyalty_tiers t on t.id=b.tier_id and t.business_id=b.business_id
    cross join lateral (
      select count(*)::integer as count_in_period from public.tier_benefit_issues_v365 i
       where i.benefit_id=b.id and i.client_id=p_client
         and i.period_key=app.v365_period_key(b.limit_period,now())
    ) used
   where b.business_id=p_business and b.deleted_at is null and b.active
     and coalesce(t.paused,false)=false and t.deleted_at is null
     and t.threshold<=v_tier.threshold
     and (t.effective_from is null or t.effective_from<=statement_timestamp())
     and (t.expires_at is null or t.expires_at>statement_timestamp());

  return jsonb_build_object('status','ok',
    'tier',jsonb_build_object('id',v_tier.id,'label',v_tier.name,'threshold',v_tier.threshold),
    'in_birthday_month',v_birthday,
    'benefits',v_rows);
end $function$;

-- Restate the live ACL verbatim ({postgres,authenticated,service_role}=X/postgres).

revoke all on function public.staff_tier_benefits_for_client_v365(uuid, uuid) from public, anon;

grant execute on function public.staff_tier_benefits_for_client_v365(uuid, uuid) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.staff_issue_tier_benefit_v365(p_business uuid, p_client uuid, p_benefit uuid, p_branch uuid DEFAULT NULL::uuid, p_idempotency_key uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_key uuid := coalesce(p_idempotency_key, gen_random_uuid());
  v_benefit public.tier_benefits_v365%rowtype;
  v_tier public.loyalty_tiers%rowtype;
  v_benefit_tier public.loyalty_tiers%rowtype;
  v_period_key text;
  v_used integer;
  v_existing public.tier_benefit_issues_v365%rowtype;
  v_id uuid;
  v_birth date;
begin
  if v_actor is null then raise exception 'authenticated staff required' using errcode='42501'; end if;
  if not (app.is_salon_owner(p_business) or app.can_module_write(p_business,'till')
          or app.can_module_write(p_business,'loyalty')) then
    raise exception 'till or loyalty write authorization required' using errcode='42501';
  end if;

  select * into v_benefit from public.tier_benefits_v365
   where id=p_benefit and business_id=p_business and deleted_at is null and active;
  if not found then raise exception 'tier_benefit_not_found' using errcode='42704'; end if;
  select * into v_benefit_tier from public.loyalty_tiers
   where id=v_benefit.tier_id and business_id=p_business
     and coalesce(paused,false)=false and deleted_at is null;
  if not found then raise exception 'tier_benefit_not_found' using errcode='42704'; end if;

  -- Replay BEFORE the limit check: a double-tap must return the first issue, never be counted as
  -- a second one and never be reported as "limit reached".
  select * into v_existing from public.tier_benefit_issues_v365
   where benefit_id=p_benefit and client_id=p_client and idem_key=v_key;
  if found then
    return jsonb_build_object('status','duplicate_ignored','issue_id',v_existing.id,
      'label',v_existing.label,'period_key',v_existing.period_key);
  end if;

  -- One customer, one benefit, one period at a time: two counters racing would both read "0 used".
  perform pg_advisory_xact_lock(hashtextextended('v365:issue:'||p_benefit::text||':'||p_client::text,0));

  v_tier := app.v365_client_tier(p_business,p_client);
  if v_tier.id is null or v_tier.threshold < v_benefit_tier.threshold then
    raise exception 'tier_benefit_not_earned' using errcode='42501';
  end if;

  -- V367: the birthday-month test. Refused loudly when the profile carries no birth date rather
  -- than allowed — see the migration header.
  if v_benefit.limit_period='birthday_month' then
    select birth_date into v_birth from public.clients where id=p_client and business_id=p_business;
    if v_birth is null then
      raise exception 'tier_benefit_birthday_unknown' using errcode='22023';
    end if;
    if not app.v367_in_birthday_month(p_client, now()) then
      raise exception 'tier_benefit_not_birthday_month' using errcode='22023';
    end if;
  end if;

  v_period_key := app.v365_period_key(v_benefit.limit_period, now());
  if v_benefit.limit_count is not null then
    select count(*) into v_used from public.tier_benefit_issues_v365
     where benefit_id=p_benefit and client_id=p_client and period_key=v_period_key;
    if v_used >= v_benefit.limit_count then
      raise exception 'tier_benefit_limit_reached' using errcode='22023';
    end if;
  end if;

  if p_branch is not null then
    perform 1 from public.branches branch
     where branch.id=p_branch and branch.business_id=p_business and branch.active
       and app.can_see_branch(p_business, branch.id);
    if not found then raise exception 'tier_benefit_branch_not_permitted' using errcode='42501'; end if;
  end if;

  insert into public.tier_benefit_issues_v365(
    business_id,benefit_id,client_id,tier_id,label,limit_count,limit_period,period_key,
    branch_id,issued_by,idem_key)
  values(p_business,p_benefit,p_client,v_benefit.tier_id,v_benefit.label,v_benefit.limit_count,
    v_benefit.limit_period,v_period_key,p_branch,v_actor,v_key)
  returning id into v_id;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,v_actor,'TIER_BENEFIT_ISSUED_V365','tier_benefit_issues_v365',v_id,
    jsonb_build_object('client_id',p_client,'benefit_id',p_benefit,'label',v_benefit.label,
                       'period_key',v_period_key,'branch_id',p_branch));

  return jsonb_build_object('status','issued','issue_id',v_id,'label',v_benefit.label,
    'period_key',v_period_key,
    'remaining',case when v_benefit.limit_count is null then null
      else greatest(0,v_benefit.limit_count-(
        select count(*) from public.tier_benefit_issues_v365
         where benefit_id=p_benefit and client_id=p_client and period_key=v_period_key)) end);
end $function$;

-- Restate the live ACL verbatim ({postgres,authenticated,service_role}=X/postgres).

revoke all on function public.staff_issue_tier_benefit_v365(uuid, uuid, uuid, uuid, uuid) from public, anon;

grant execute on function public.staff_issue_tier_benefit_v365(uuid, uuid, uuid, uuid, uuid) to authenticated, service_role;

commit;
