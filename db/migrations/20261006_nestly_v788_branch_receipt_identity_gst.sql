-- NESTLY v788 — the company on the receipt, and GST, belong to the BRANCH.
--
-- OWNER RULING (2026-09-06): "shift the company name & UEN number and (GST or not) to individual
-- branches, because branches may be different ACRA (operating under same boss). So when a user
-- from a different branch opens Record sale and makes a transaction, the company name and UEN
-- follow, including GST or no GST. Record sale is the only area that matters for GST / company
-- name & UEN." Clarified in two follow-ups: real GST at checkout, all listed prices are BEFORE
-- GST, and the two business-level fields move entirely to branches.
--
-- WHAT WAS TRUE BEFORE. businesses.legal_name / registration_number were the only receipt
-- identity (v79 columns, v188 form, v654 receipt wording) and businesses.gst_registered was
-- read by the pricing kernel — but NO merchant screen could switch it on, so every business in
-- production computed zero GST and every receipt said "Not GST registered" (0 of 23 businesses
-- registered, 0 evaluations with gst on the day this was written). The kernel's formula was
-- GST-INCLUSIVE (carved out of an unchanged total), the opposite of the ruling.
--
-- WHAT THIS MIGRATION DOES
--   1. branches gains legal_name, registration_number, gst_registered (default false),
--      gst_registration_number and gst_rate_bps (default 900 = 9%, the Singapore rate).
--   2. Backfill: every existing branch inherits its business's legal_name / registration_number
--      where the branch's own is null, so no receipt loses the name it printed yesterday.
--   3. checkout_evaluations_totals_check becomes total = subtotal - discount + gst.
--   4. app.ps1c_plan_checkout (the single pricing authority, restated verbatim from nestly_v752
--      — the live body was hash-compared to the repo text before this was written) reads the
--      branch's registration instead of the business's and ADDS the rate on top of the
--      discounted net. Everything else in the function is untouched.
--
-- WHAT IT DELIBERATELY DOES NOT DO
--   * It does not drop businesses.legal_name / registration_number / gst_registered. Self-serve
--     onboarding and the platform console still write the first two (they are the firm's
--     application identity, indexed by v654); only the merchant Business Profile form and the
--     till receipts stop using them. The gst flag on businesses is left in place, unread.
--   * It does not change what a sale EARNS on. sales.amount_cents is still the collected total
--     (record_cart_sale passes v_eval.total_cents to record_quick_sale), exactly as it was under
--     the inclusive model — so points and stamps earn on the amount the customer paid. Flagged
--     for an owner ruling in the ship note; changing the earn basis is a separate decision.
--   * The GST amount is computed once at the end, on the bill: round(net * rate / 10000). A
--     per-line split would be a different receipt shape and is not asked for.

begin;

-- 1. the branch owns its registration -------------------------------------------------------
alter table public.branches
  add column if not exists legal_name text,
  add column if not exists registration_number text,
  add column if not exists gst_registered boolean not null default false,
  add column if not exists gst_registration_number text,
  add column if not exists gst_rate_bps integer not null default 900;

alter table public.branches drop constraint if exists branches_gst_rate_bps_v788;
alter table public.branches add constraint branches_gst_rate_bps_v788
  check (gst_rate_bps >= 0 and gst_rate_bps <= 2000);
alter table public.branches drop constraint if exists branches_identity_lengths_v788;
alter table public.branches add constraint branches_identity_lengths_v788
  check (
    (legal_name is null or length(legal_name) <= 200)
    and (registration_number is null or length(registration_number) <= 60)
    and (gst_registration_number is null or length(gst_registration_number) <= 60));

comment on column public.branches.legal_name is
  'nestly_v788: the registered (ACRA) company name printed on this branch''s receipts; null = the workspace name';
comment on column public.branches.registration_number is
  'nestly_v788: this branch''s UEN, printed on its receipts';
comment on column public.branches.gst_registered is
  'nestly_v788: whether THIS branch charges GST at Record sale; listed prices are before GST';
comment on column public.branches.gst_registration_number is
  'nestly_v788: the GST registration number printed on a registered branch''s receipts';
comment on column public.branches.gst_rate_bps is
  'nestly_v788: GST rate in basis points, added on top of the discounted net (900 = 9%)';

-- 2. no receipt loses the name it printed yesterday -----------------------------------------
update public.branches br
   set legal_name = coalesce(br.legal_name, bz.legal_name),
       registration_number = coalesce(br.registration_number, bz.registration_number)
  from public.businesses bz
 where bz.id = br.business_id
   and (bz.legal_name is not null or bz.registration_number is not null)
   and (br.legal_name is null or br.registration_number is null);

-- 3. the evaluation's own arithmetic check follows the new shape -----------------------------
alter table public.checkout_evaluations drop constraint if exists checkout_evaluations_totals_check;
alter table public.checkout_evaluations add constraint checkout_evaluations_totals_check
  check (total_cents = subtotal_cents - discount_total_cents + gst_cents);

-- 4. the pricing authority ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.ps1c_plan_checkout(p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_config uuid, p_tier_benefit uuid DEFAULT NULL::uuid, p_birthday boolean DEFAULT false)
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
  -- nestly_v656: the scope of the chosen discount, and whether it was chosen by hand.
  v_tier_scoped boolean := false; v_tier_used int; v_tier_names text[];
  -- nestly_v657: which of the two shapes this discount is, and the line it landed on.
  v_tier_target int; v_tier_best int;
  v_ps timestamptz; v_pe timestamptz; v_committed int; v_projected int;
  v_rule_proj jsonb := '{}'::jsonb; v_gst_reg boolean; v_gst_bps int; v_total int; v_gst int;
  -- nestly_v788: the amount before GST, which is what every listed price is.
  v_net int;
  j int;
  v_desc text; v_camt numeric; v_creason text; v_limit int; v_may_custom boolean;
  v_bundle jsonb; v_bline jsonb; v_bsrc uuid[]; v_bsrcqty int[];
  v_key text;
  -- nestly_v752: the hand-applied birthday discount, staged by staff_stage_gift_qr_v665
  -- exactly like the v656 hand-applied tier discount above.
  v_bday_entitlement public.customer_birthday_entitlements%rowtype;
  v_bday_program public.birthday_program_versions%rowtype;
  v_bday_scoped boolean := false; v_bday_target int; v_bday_best int;
  v_bday_base int; v_bday_d int;
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
        v_kind := array_append(v_kind, coalesce(v_bline->>'kind', 'service'));
        v_id := array_append(v_id, coalesce(nullif(v_bline->>'item_id',''), v_bline->>'service_id')::uuid);
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
    if p_tier_benefit is not null then
      -- nestly_v656 — THE HAND-APPLIED DISCOUNT (owner: "when i 'use' the voucher it must deduct
      -- the overall amount by 10%"). A LIMITED discount could not come off a bill at all: v370
      -- deliberately excluded it here because spending an allowance has to be COUNTED, and the
      -- only thing that counted was the staff Give button, which moves no money. So staff pressed
      -- Give, Peekaa recorded that a 20%-off perk had been handed over, and then charged the
      -- customer full price.
      -- The answer is not to auto-apply it — that would spend it on every bill — but to let it be
      -- chosen, here, once, for THIS sale. The count is written by record_cart_sale in the same
      -- transaction that takes the money, so the discount and the spend can never disagree.
      -- Everything the automatic path checks is checked again: the benefit is this business's, it
      -- is a live discount on a tier the customer has actually reached, and it is in date.
      select b.id, b.tier_id, b.label, b.discount_percent, b.limit_count, b.limit_period,
             b.discount_scope, b.max_discount_cents
        into v_tier_benefit
        from public.tier_benefits_v365 b
        join public.loyalty_tiers t on t.id = b.tier_id and t.business_id = b.business_id
       where b.id = p_tier_benefit
         and b.business_id = p_business
         and b.deleted_at is null and b.active
         and b.benefit_kind = 'discount_pct'
         and coalesce(t.paused, false) = false and t.deleted_at is null
         and t.threshold <= coalesce((app.v365_client_tier(p_business, p_client)).threshold, -1)
         and (t.effective_from is null or t.effective_from <= statement_timestamp())
         and (t.expires_at is null or t.expires_at > statement_timestamp());
      if v_tier_benefit.id is null then
        return jsonb_build_object('status', 'tier_benefit_not_available',
          'reason', 'tier_benefit_not_available: that tier discount is not available to this customer');
      end if;
      -- Birthday-month perks are only live in the customer's birthday month, exactly as the
      -- Give button and the customer's own card judge them.
      if v_tier_benefit.limit_period = 'birthday_month'
         and not coalesce(app.v367_in_birthday_month(p_client, now()), false) then
        return jsonb_build_object('status', 'tier_benefit_not_available',
          'reason', 'tier_benefit_not_available: this perk is only available in the customer''s birthday month');
      end if;
      -- The allowance is checked HERE so the till can say so before the customer is charged;
      -- staff_issue_tier_benefit_v365 checks it again under a lock when the sale is finalised.
      if v_tier_benefit.limit_count is not null then
        select count(*)::int into v_tier_used
          from public.tier_benefit_issues_v365 i
         where i.benefit_id = v_tier_benefit.id and i.client_id = p_client
           and i.period_key = app.v365_period_key(v_tier_benefit.limit_period, now())
           and i.reversed_at is null;
        if v_tier_used >= v_tier_benefit.limit_count then
          return jsonb_build_object('status', 'tier_benefit_used_up',
            'reason', 'tier_benefit_used_up: this customer has already used that perk for this period');
        end if;
      end if;
    else
    select b.id, b.tier_id, b.label, b.discount_percent, b.limit_count, b.limit_period,
           b.discount_scope, b.max_discount_cents
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
    end if;

    if v_tier_benefit.id is not null and not v_nonstack_applied then
      -- nestly_v656 — WHAT THE PERCENTAGE COMES OFF (owner: "10% off selected products able to
      -- select the product/services ... if blanket 10% also allow that selection"). A benefit
      -- that names no item keeps v370's behaviour exactly: the whole remaining bill. A benefit
      -- that names items is worth its percentage of THOSE LINES only, and it reads them from
      -- v_rem[] — each line's remainder AFTER the Studio rules have taken their cut — so a line
      -- already discounted cannot be discounted twice off its full price.
      -- nestly_v657 — TWO SHAPES, AND ONLY TWO (owner ruling 2026-08-31, after seeing v656's
      -- tick-list discount every ticked item at once):
      --   'bill' — a percentage off the whole bill, optionally capped in money.
      --   'item' — a percentage off ONE item per transaction. The tick-list stops being "which
      --            items are discounted" and becomes "which items are ELIGIBLE"; exactly one of
      --            them is discounted, and the owner's ruling for which is the HIGHEST-PRICED
      --            eligible line on this bill — deterministic, needs no decision at the counter,
      --            and it is the line the customer would have chosen themselves.
      v_tier_scoped := coalesce(v_tier_benefit.discount_scope, 'bill') = 'item';
      v_tier_target := null;
      if v_tier_scoped then
        v_tier_best := 0;
        for j in 1 .. coalesce(array_length(v_rem, 1), 0) loop
          if v_rem[j] > v_tier_best and v_id[j] is not null and exists(
               select 1 from public.tier_benefit_scope_v656 sc
                where sc.benefit_id = v_tier_benefit.id
                  and ((v_kind[j] = 'product' and sc.product_id = v_id[j])
                    or (v_kind[j] = 'service' and sc.service_id = v_id[j]))) then
            v_tier_best := v_rem[j];
            v_tier_target := j;
          end if;
        end loop;
        -- Nothing eligible on this bill is not an error for the AUTOMATIC path — the perk simply
        -- does not apply. For a perk the counter chose by hand it IS an error, because the till
        -- quoted it and staff need to be told why it went; that refusal is raised below.
        v_tier_base := coalesce(v_tier_best, 0);
        if v_tier_base = 0 and p_tier_benefit is not null then
          return jsonb_build_object('status', 'tier_benefit_no_eligible_item',
            'reason', 'tier_benefit_no_eligible_item: nothing on this bill is covered by that perk');
        end if;
        -- A bill-level rule discount is not reflected in v_rem, so the base is capped at what is
        -- actually still payable. Without this a bill-level rule plus a tier discount could
        -- together exceed the subtotal.
        v_tier_base := least(v_tier_base, (v_subtotal - v_total_discount)::int);
      else
        v_tier_base := (v_subtotal - v_total_discount)::int;
      end if;
      if v_tier_base > 0 then
        v_tier_d := round(v_tier_base::numeric * v_tier_benefit.discount_percent / 100.0)::int;
        -- nestly_v657 (owner: "Merchant sets a maximum discount, e.g. 10% off, capped at $20").
        -- The ceiling is money, not a percentage, and it is applied AFTER the percentage so the
        -- owner's cap is what the customer's bill actually honours.
        if v_tier_benefit.max_discount_cents is not null then
          v_tier_d := least(v_tier_d, v_tier_benefit.max_discount_cents);
        end if;
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
            'discount_pct', v_tier_benefit.discount_percent,
            /* nestly_v656: record_cart_sale reads these two. `limited` is what tells it to spend
               the customer's allowance when the sale is finalised; `scoped` is provenance for the
               receipt line and for anyone reading an evaluation later. */
            'tier_benefit_limited', v_tier_benefit.limit_count is not null,
            'tier_benefit_scoped', v_tier_scoped,
            /* nestly_v657: the shape, and — for a single-item discount — the line it landed on,
               so the till can name it instead of saying "(whole bill)" about one item. */
            'tier_benefit_mode', coalesce(v_tier_benefit.discount_scope, 'bill'),
            'tier_benefit_item', case when v_tier_target is null then null else v_name[v_tier_target] end,
            'tier_benefit_capped', v_tier_benefit.max_discount_cents is not null
              and v_tier_d = v_tier_benefit.max_discount_cents));
        end if;
      end if;
    end if;
  end if;


  -- ===========================================================================================
  -- NESTLY v752 — THE HAND-APPLIED BIRTHDAY DISCOUNT (owner ruling 2026-09-04: birthday gets the
  -- same mechanism as a tier benefit). Modelled exactly on the nestly_v656/v657 hand-applied tier
  -- discount immediately above: staff_stage_gift_qr_v665 has already staged this specific
  -- customer's specific entitlement onto the counter, so it is re-verified here (live, in date,
  -- unused) rather than trusted, and it is priced with the SAME whole-bill-or-one-item/cap shape.
  -- A free_item birthday benefit never reaches this function at all — it settles on scan via
  -- public.staff_confirm_birthday_free_item_v752, the same way a tier free_item does.
  -- ===========================================================================================
  if p_birthday and p_client is not null then
    select * into v_bday_entitlement
      from public.customer_birthday_entitlements e
     where e.business_id = p_business and e.client_id = p_client
       and e.status = 'available' and e.valid_from <= now() and e.valid_until > now()
     order by e.valid_until desc, e.activated_at desc
     limit 1;
    if v_bday_entitlement.id is not null then
      select * into v_bday_program from public.birthday_program_versions
       where id = v_bday_entitlement.birthday_program_version_id
         and business_id = v_bday_entitlement.business_id
         and fulfillment_kind = 'discount_pct';
    end if;
    if v_bday_entitlement.id is null or v_bday_program.id is null then
      return jsonb_build_object('status', 'birthday_benefit_not_available',
        'reason', 'birthday_benefit_not_available: this customer has no live birthday discount');
    end if;

    v_bday_scoped := coalesce(v_bday_program.discount_scope, 'bill') = 'item';
    v_bday_target := null;
    if v_bday_scoped then
      v_bday_best := 0;
      for j in 1 .. coalesce(array_length(v_rem, 1), 0) loop
        if v_rem[j] > v_bday_best and v_id[j] is not null and exists(
             select 1 from public.birthday_benefit_scope_v752 sc
              where sc.program_version_id = v_bday_program.id
                and ((v_kind[j] = 'product' and sc.product_id = v_id[j])
                  or (v_kind[j] = 'service' and sc.service_id = v_id[j]))) then
          v_bday_best := v_rem[j];
          v_bday_target := j;
        end if;
      end loop;
      v_bday_base := coalesce(v_bday_best, 0);
      if v_bday_base = 0 then
        return jsonb_build_object('status', 'birthday_benefit_no_eligible_item',
          'reason', 'birthday_benefit_no_eligible_item: nothing on this bill is covered by that birthday gift');
      end if;
      v_bday_base := least(v_bday_base, (v_subtotal - v_total_discount)::int);
    else
      v_bday_base := (v_subtotal - v_total_discount)::int;
    end if;
    if v_bday_base > 0 then
      v_bday_d := round(v_bday_base::numeric * v_bday_program.discount_percent / 100.0)::int;
      if v_bday_program.max_discount_cents is not null then
        v_bday_d := least(v_bday_d, v_bday_program.max_discount_cents);
      end if;
      if v_bday_d > 0 then
        v_total_discount := v_total_discount + v_bday_d;
        v_applied := v_applied || jsonb_build_array(jsonb_build_object(
          'rule_id', null, 'effect_index', 0, 'effect_type', 'apply_discount_pct',
          'level', 'bill', 'target_line_index', null, 'amount_cents', v_bday_d,
          'suppressed', false, 'suppression_reason', null,
          'capped', false, 'cap_cents', null,
          'period_start', null, 'period_end', null,
          'source', 'birthday_benefit', 'birthday_entitlement_id', v_bday_entitlement.id,
          'label', v_bday_entitlement.benefit_snapshot->>'label',
          'discount_pct', v_bday_program.discount_percent,
          'birthday_benefit_scoped', v_bday_scoped,
          'birthday_benefit_mode', coalesce(v_bday_program.discount_scope, 'bill'),
          'birthday_benefit_item', case when v_bday_target is null then null else v_name[v_bday_target] end,
          'birthday_benefit_capped', v_bday_program.max_discount_cents is not null
            and v_bday_d = v_bday_program.max_discount_cents));
      end if;
    end if;
  end if;

  v_net := (v_subtotal - v_total_discount)::int;

  if v_net = 0 then
    return jsonb_build_object('status', 'total_zero_not_supported',
      'reason', 'total_zero_not_supported: this checkout is fully discounted to zero and a zero-value sale is not supported; adjust the cart or the discount');
  end if;

  -- nestly_v788 — GST IS THE BRANCH'S, AND IT IS ADDED ON TOP (owner ruling 2026-09-06: "all
  -- prices set are before GST; GST is toggled in branches module, on or off accordingly").
  -- Two things changed here and nothing else in this function did:
  --   * WHOSE registration. Branches of one workspace may be different ACRA entities under the
  --     same boss, so the flag and the rate are read from the branch this checkout is priced
  --     for — p_branch, which evaluate_checkout has already resolved and verified — never from
  --     the business row (whose gst_registered stays in place and is simply no longer read).
  --   * WHICH WAY. Every listed price is before GST, so a registered branch charges the rate on
  --     top of the discounted amount: total = net + gst. The old formula carved an inclusive
  --     portion out of an unchanged total, which no branch had ever switched on (0 rows).
  --     checkout_evaluations_totals_check is restated below to match (total = subtotal -
  --     discount + gst); every existing row has gst 0, so it holds for history too.
  select b.gst_registered, b.gst_rate_bps into v_gst_reg, v_gst_bps
    from public.branches b where b.id = p_branch and b.business_id = p_business;
  if coalesce(v_gst_reg, false) and coalesce(v_gst_bps, 0) > 0 then
    v_gst := round(v_net::numeric * v_gst_bps / 10000)::int;
  else
    v_gst_bps := 0; v_gst := 0;
  end if;
  v_total := v_net + v_gst;

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

-- Grants restated verbatim from the live proacl ({postgres=X/postgres}): internal to the
-- kernel, callable by nobody through the API.
revoke all on function app.ps1c_plan_checkout(uuid, uuid, uuid, jsonb, uuid, uuid, boolean)
  from public, anon, authenticated;

commit;
