-- FRENLY v59 - PROGRAM STUDIO PS-1C.1: LEGACY-CART HARDENING
--
-- Local review candidate. Production apply needs the owner's RELEASE APPROVED
-- phrase (CLAUDE.md standing gate). PS-1C is already authorized (PS-GATES.md); this
-- is a hardening increment ON TOP of v58's unified checkout kernel. It changes NO
-- authorized-phase surface set - it extends three existing kernel functions in place
-- (app.ps1c_plan_checkout, public.evaluate_checkout, public.record_cart_sale/9),
-- retires the legacy /7 cart entry, adds one owner-grantable permission and one
-- data-integrity guard. No new browser-writable table, no new executor surface.
--
-- WHAT THIS ADDS (the pinned PS-1C.1 contract)
--   A. CUSTOM MANUALLY-PRICED LINES. evaluate_checkout p_lines may now include a
--      custom line {catalog_kind:'custom', description, amount_cents, reason}. Only
--      owner + staff holding the new 'custom_price_lines' permission may enter one;
--      the amount is bounded by businesses.custom_line_limit_cents; description and
--      reason are mandatory (3..200 chars); qty is always 1. The custom amount is
--      NOT a client-priced catalog line - it is a server-recorded manual price with
--      full audit provenance (one CUSTOM_PRICE_LINE audit_log row per line).
--   B. ZERO-TOTAL is a TYPED result, not an ambiguous internal error. When discounts
--      take the total to 0, the plan returns 'total_zero_not_supported' and
--      evaluate_checkout raises a 22023 whose message starts 'total_zero_not_supported:'.
--      The finaliser carries a belt-guard for the same condition (22023, NOT a stale
--      P0001 - a zero total must never spin a client re-evaluation loop). No
--      zero-value sale is ever created.
--   C. record_cart_sale/7 (the v51 no-token cart path) is RETIRED from every browser
--      role. The function stays in place (house pattern: F2 revoked overloads rather
--      than dropping them), but EXECUTE is revoked from public/anon/authenticated, so
--      the kernel /9 token path is the ONLY browser cart entry. A retired /7 can no
--      longer smuggle a client-priced or impersonated line into the sale spine.
--   D. IMPERSONATION GUARD. evaluate_checkout already accepts only service|product
--      (+custom now); a DB-level BEFORE INSERT guard on sale_items additionally
--      rejects item_type in ('package','membership','gift_card') when the parent
--      sale.kind is 'quick_sale' or 'cart_sale' - the two kinds the generic cart /
--      quick-sale spine writes. Stored-value / plan lines belong to their dedicated
--      engines (sell_package -> kind='package', enroll_membership -> kind='membership',
--      issue_gift_card -> kind='gift_card'), none of which write sale_items, so the
--      guard breaks nothing legitimate and closes the only surface that ever wrote
--      such a row: the now-retired /7 cart path.
--
-- MUST NOT (unchanged owner scope): no studio points/credit effects; no stored-value
--   tender; the kernel still writes NO credit_ledger / points_ledger - a custom line
--   and any discount reduce sales.amount_cents BEFORE app.on_sale_recorded fires, so
--   loyalty earns on the final discounted total (correct). Legacy engines untouched.

begin;

-- =====================================================================
-- 1. businesses.custom_line_limit_cents - the per-firm cap on a single manually
--    priced (custom) checkout line. Default $500.00. A firm can lower or raise it;
--    it can never be negative. NULL is impossible (not null default).
-- =====================================================================
alter table public.businesses
  add column if not exists custom_line_limit_cents integer not null default 50000
    check (custom_line_limit_cents >= 0);

-- =====================================================================
-- 2. 'custom_price_lines' permission - owner-grantable, owner-controllable.
--    role_perms is the house static role->perm map (v10.1): the single call site the
--    rest of the schema knows about is app.has_perm(). We widen it so OWNER and
--    MANAGER carry 'custom_price_lines' and every other role does not. It is
--    owner-controllable because the owner alone assigns the manager role (staff_invites
--    / staff.role), so granting a till operator manual-price authority is a deliberate
--    owner act of promoting them to manager; a frontdesk/staff/bookkeeper login can
--    ring up a normal checkout (they keep create_sales) but cannot enter a manual
--    price. Owner is additionally allowed unconditionally in the kernel via
--    app.is_salon_owner (belt and suspenders). The existing six-perm map is preserved
--    byte-for-byte except for the two added tokens; no behaviour narrows.
-- =====================================================================
-- Byte-faithful to the AUTHORITATIVE v14d definition (which superseded v10.1 with
-- the canonical staff/bookkeeper roles, owner's manage_team/manage_billing, the
-- legacy stylist/receptionist aliases, and the pinned search_path) — plus exactly
-- ONE addition: 'custom_price_lines' on owner and manager.
create or replace function app.role_perms(p_role text)
returns text[] language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select case p_role
    when 'owner'      then array['view_sales','create_sales','refund_sales',
                                 'reclassify_sales','view_finance','manage_sale_policy',
                                 'manage_team','manage_billing','custom_price_lines']
    when 'manager'    then array['view_sales','create_sales','refund_sales','view_finance',
                                 'custom_price_lines']
    when 'staff'      then array['view_sales','create_sales']
    when 'frontdesk'  then array['view_sales','create_sales']
    when 'bookkeeper' then array['view_sales','view_finance']
    when 'stylist'      then array['view_sales','create_sales']
    when 'receptionist' then array['view_sales','create_sales']
    else array[]::text[]
  end
$$;

-- =====================================================================
-- 3. sale_items impersonation guard (contract D). BEFORE INSERT on sale_items:
--    a 'package' / 'membership' / 'gift_card' line may never ride under a parent
--    sale whose kind is 'quick_sale' or 'cart_sale' (the generic cart / quick-sale
--    spine). Those instrument/plan item_types belong ONLY to their dedicated engines'
--    own sale kinds, and the dedicated engines write NO sale_items. The kernel
--    finaliser writes only 'service' / 'retail' / 'studio_discount' / 'custom' lines,
--    so it is never touched. The only historical writer of such a row under a
--    quick_sale parent was the v51 /7 cart path, which section 6 retires. SECURITY
--    DEFINER so it can read the parent sale.kind regardless of the caller's RLS.
-- =====================================================================
create or replace function app.sale_items_kind_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_parent_kind text;
begin
  if new.item_type in ('package', 'membership', 'gift_card') then
    select s.kind into v_parent_kind
      from public.sales s
     where s.id = new.sale_id and s.business_id = new.business_id;
    if v_parent_kind in ('quick_sale', 'cart_sale') then
      raise exception
        'sale_items_kind_guard: a % line cannot ride under a % sale; use its dedicated engine',
        new.item_type, v_parent_kind
        using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
revoke all privileges on function app.sale_items_kind_guard() from public, anon, authenticated;
drop trigger if exists trg_sale_items_kind_guard on public.sale_items;
create trigger trg_sale_items_kind_guard
  before insert on public.sale_items
  for each row execute function app.sale_items_kind_guard();

-- =====================================================================
-- 4. app.ps1c_plan_checkout - REPLACED to admit custom lines and to type the
--    zero-total outcome. Everything else (service/product resolution, discount
--    gathering/application, budget projection, GST extraction) is preserved exactly
--    from v58; the deltas are:
--      * catalog_kind may be 'custom'; a custom line accepts ONLY
--        {catalog_kind, description, amount_cents, reason, qty(=1)} and is validated
--        for permission, limit, and field lengths (typed custom_line_* failures);
--      * service/product lines still HARD-REJECT any price key (client_priced) - the
--        rejection is restructured to run only on catalog lines, never on the custom
--        line's own amount_cents;
--      * after discounts, total_cents = 0 -> typed 'total_zero_not_supported'.
--    Custom lines carry a null catalog_id, so a line-level discount (which matches a
--    concrete service/product ref) can never target them; a bill-level discount still
--    applies to the whole discounted subtotal, custom amounts included.
-- =====================================================================
create or replace function app.ps1c_plan_checkout(
  p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_config uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_line jsonb; v_ord int := 0; v_n int;
  v_kind text[]; v_id uuid[]; v_name text[]; v_unit int[]; v_qty int[]; v_ltot int[]; v_rem int[];
  v_entered_by uuid[]; v_lreason text[];
  v_subtotal bigint := 0; v_price jsonb; v_pstatus text; v_nm text;
  v_server jsonb := '[]'::jsonb; v_entry jsonb;
  v_payload jsonb; v_active_rules boolean := (p_config is not null);
  r record; v_eff jsonb; v_idx int; v_etype text; v_ckind text; v_cid uuid; v_level text;
  v_stackable boolean; v_cap int; v_period text;
  v_cand jsonb := '[]'::jsonb;   -- gathered discount candidates
  v_applied jsonb := '[]'::jsonb;
  v_total_discount bigint := 0; v_any_line boolean := false; v_any_bill boolean := false;
  c jsonb; v_target int; v_base int; v_d int; v_reason text; v_suppressed boolean;
  v_ps timestamptz; v_pe timestamptz; v_committed int; v_projected int;
  v_rule_proj jsonb := '{}'::jsonb; v_gst_reg boolean; v_gst_bps int; v_total int; v_gst int;
  j int;
  -- custom-line locals
  v_desc text; v_camt numeric; v_creason text; v_limit int; v_may_custom boolean;
  v_key text;
begin
  if jsonb_typeof(p_lines) <> 'array' then
    return jsonb_build_object('status', 'invalid', 'reason', 'lines must be a JSON array');
  end if;
  v_n := jsonb_array_length(p_lines);
  if v_n < 1 or v_n > 50 then
    return jsonb_build_object('status', 'invalid', 'reason', 'a cart must have between 1 and 50 lines');
  end if;

  -- The manual-price cap and the caller's manual-price authority are resolved ONCE.
  -- app.is_salon_owner / app.has_perm read auth.uid() (the evaluating staff), which is
  -- valid inside this definer function (it is only ever called by evaluate_checkout,
  -- which has already established an authenticated actor with create_sales).
  select coalesce(custom_line_limit_cents, 50000) into v_limit from public.businesses where id = p_business;
  v_limit := coalesce(v_limit, 50000);
  v_may_custom := app.is_salon_owner(p_business) or app.has_perm(p_business, 'custom_price_lines');

  -- 4.1 Resolve every line (fail closed). Read catalog_kind FIRST, then branch:
  --     custom lines are self-priced-and-audited; service/product lines are catalog
  --     priced and reject ALL price keys.
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_ord := v_ord + 1;
    v_ckind := v_line->>'catalog_kind';
    if v_ckind is null or v_ckind not in ('service', 'product', 'custom') then
      return jsonb_build_object('status', 'bad_kind', 'line', v_ord,
        'reason', 'catalog_kind must be service, product or custom');
    end if;

    if v_ckind = 'custom' then
      -- Custom line accepts ONLY {catalog_kind, description, amount_cents, reason, qty}.
      -- Any other key (a price key, a catalog_id, anything) is rejected as invalid.
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
      -- qty must be exactly 1 (absent defaults to 1).
      if v_line ? 'qty' then
        if jsonb_typeof(v_line->'qty') is distinct from 'number'
           or (v_line->>'qty')::numeric <> 1 then
          return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
            'reason', 'custom_line_invalid: a custom line quantity is always 1');
        end if;
      end if;
      -- amount_cents must be a whole positive number within the firm limit.
      if jsonb_typeof(v_line->'amount_cents') is distinct from 'number' then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: a custom line requires a numeric amount_cents');
      end if;
      v_camt := (v_line->>'amount_cents')::numeric;
      if v_camt <> trunc(v_camt) or v_camt < 1 then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: amount_cents must be a whole number of at least 1 cent');
      end if;
      if v_camt > v_limit then
        return jsonb_build_object('status', 'custom_line_limit', 'line', v_ord,
          'reason', 'custom_line_limit: amount_cents exceeds this business''s manual-price limit of '
                    || v_limit || ' cents');
      end if;
      -- description and reason are mandatory, 3..200 chars after trim.
      v_desc := btrim(coalesce(v_line->>'description', ''));
      v_creason := btrim(coalesce(v_line->>'reason', ''));
      if length(v_desc) < 3 or length(v_desc) > 200 then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: a custom line needs a description of 3 to 200 characters');
      end if;
      if length(v_creason) < 3 or length(v_creason) > 200 then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: a custom line needs a reason of 3 to 200 characters');
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
      v_subtotal := v_subtotal + v_camt::int;
      continue;
    end if;

    -- service / product line: NOTHING is client-priceable.
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
      -- entered_by + reason are server-owned provenance, frozen inside the immutable
      -- token; they are NOT part of the price-relevant cart_hash projection.
      v_entry := v_entry || jsonb_build_object('entered_by', v_entered_by[j], 'reason', v_lreason[j]);
    end if;
    v_server := v_server || jsonb_build_array(v_entry);
  end loop;

  -- 4.2 Gather discount candidates from ACTIVE sale.completed rules. Custom lines have
  --     a null catalog_id so a line-level discount never matches them; bill discounts
  --     apply to the whole discounted subtotal, custom amounts included.
  v_payload := jsonb_build_object('amount_cents', v_subtotal, 'kind', 'cart_sale',
    'branch_id', to_jsonb(p_branch::text), 'client_id', to_jsonb(coalesce(p_client::text, '')),
    'counts_as_visit', true, 'earns_points', true);
  if v_active_rules then
    for r in select c2.rule_id, c2.compiled from public.program_rules_compiled c2
              where c2.business_id = p_business and c2.config_version_id = p_config
                and c2.when_event = 'sale.completed' and c2.active
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

  -- 4.3 Apply candidates in deterministic order (line effects first, then bill).
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
      v_applied := v_applied || jsonb_build_array(jsonb_build_object(
        'rule_id', c->>'rule_id', 'effect_index', (c->>'effect_index')::int, 'effect_type', c->>'effect_type',
        'level', c->>'level', 'target_line_index', v_target, 'amount_cents', v_d,
        'suppressed', false, 'suppression_reason', null,
        'capped', v_cap is not null, 'cap_cents', v_cap,
        'period_start', v_ps, 'period_end', v_pe));
    end if;
  end loop;

  v_total := (v_subtotal - v_total_discount)::int;

  -- 4.4 Zero-total is a TYPED result (contract B): a fully-discounted cart cannot be
  --     recorded (no zero-value-sale contract exists). Returned BEFORE the token is
  --     minted, so evaluate_checkout never persists an evaluation or an op-ledger row
  --     for it.
  if v_total = 0 then
    return jsonb_build_object('status', 'total_zero_not_supported',
      'reason', 'total_zero_not_supported: this checkout is fully discounted to zero and a zero-value sale is not supported; adjust the cart or the discount');
  end if;

  -- 4.5 GST-INCLUSIVE extraction (informational; total unchanged). ⚖️ reviewable.
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
end $$;
revoke all on function app.ps1c_plan_checkout(uuid, uuid, uuid, jsonb, uuid) from public, anon, authenticated;

-- =====================================================================
-- 5. public.evaluate_checkout - REPLACED only to surface the plan's typed failure
--    verbatim (contract A/B): the raised 22023 message now begins with the plan
--    status token, so a caller sees 'custom_line_denied:', 'custom_line_limit:',
--    'custom_line_invalid:', 'total_zero_not_supported:', 'client_priced:',
--    'bad_kind:' ... . Token minting, idempotency and the op-ledger ordering (the op
--    row is written AFTER a successful plan, never for a failed one) are preserved
--    exactly from v58.
-- =====================================================================
create or replace function public.evaluate_checkout(
  p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_branch uuid;
  v_config uuid;
  v_hash text;
  v_existing public.checkout_evaluation_operations%rowtype;
  v_eval public.checkout_evaluations%rowtype;
  v_plan jsonb;
  v_eval_id uuid;
  v_msg text;
begin
  if v_actor is null then
    raise exception 'authenticated staff required to evaluate a checkout' using errcode = '42501';
  end if;
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to price a checkout in this business (create_sales)'
      using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'a checkout evaluation idempotency key is required' using errcode = '22023';
  end if;
  v_branch := coalesce(p_branch, app.default_branch(p_business));
  if v_branch is null or not exists (
    select 1 from public.branches b where b.id = v_branch and b.business_id = p_business and b.active) then
    raise exception 'checkout branch is missing, inactive, or belongs to another business' using errcode = '22023';
  end if;
  if not app.can_see_branch(p_business, v_branch) then
    raise exception 'you are not permitted to price a checkout for this branch scope' using errcode = '42501';
  end if;
  if p_client is not null and not exists (
    select 1 from public.clients c where c.id = p_client and c.business_id = p_business) then
    raise exception 'checkout client does not belong to this business' using errcode = '22023';
  end if;

  v_hash := app.ps1b_sha256(jsonb_build_object(
    'business_id', p_business, 'branch_id', v_branch, 'client_id', p_client, 'lines', p_lines)::text);

  perform pg_advisory_xact_lock(hashtextextended(
    'v58:evaluate:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.checkout_evaluation_operations o
   where o.business_id = p_business and o.idempotency_key = p_idempotency_key for update;
  if found then
    if v_existing.actor is distinct from v_actor or v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different checkout evaluation' using errcode = '22023';
    end if;
    select * into v_eval from public.checkout_evaluations where id = v_existing.evaluation_id;
    if v_eval.consumed_at is not null or v_eval.expires_at <= now() then
      raise exception 'stale: this checkout evaluation is already consumed or expired; re-evaluate' using errcode = '22023';
    end if;
    return jsonb_build_object(
      'status', 'ok', 'replayed', true, 'evaluation_id', v_eval.id, 'expires_at', v_eval.expires_at,
      'server_lines', v_eval.server_lines, 'applied_effects', v_eval.applied_effects,
      'subtotal_cents', v_eval.subtotal_cents, 'discount_total_cents', v_eval.discount_total_cents,
      'total_cents', v_eval.total_cents, 'gst_cents', v_eval.gst_cents);
  end if;

  select active_config_version_id into v_config from public.businesses where id = p_business;

  v_plan := app.ps1c_plan_checkout(p_business, v_branch, p_client, p_lines, v_config);
  if v_plan->>'status' <> 'ok' then
    -- Surface the typed status as the message prefix. When the plan already provides a
    -- prefixed human sentence in 'reason' (custom_line_*, total_zero_not_supported) use
    -- it as-is; otherwise compose '<status>: <reason> (line N)'.
    if v_plan->>'reason' is not null and position((v_plan->>'status') || ':' in (v_plan->>'reason')) = 1 then
      v_msg := v_plan->>'reason';
    else
      v_msg := (v_plan->>'status') || ': ' || coalesce(v_plan->>'reason', 'checkout could not be priced')
               || case when v_plan->>'line' is not null then ' (line ' || (v_plan->>'line') || ')' else '' end;
    end if;
    raise exception '%', v_msg using errcode = '22023';
  end if;

  insert into public.checkout_evaluations(
    business_id, branch_id, client_id, server_lines, cart_hash, config_version_id, applied_effects,
    subtotal_cents, discount_total_cents, total_cents, gst_cents, gst_rate_bps, expires_at)
  values(
    p_business, v_branch, p_client, v_plan->'server_lines', v_plan->>'cart_hash', v_config,
    v_plan->'applied_effects', (v_plan->>'subtotal_cents')::int, (v_plan->>'discount_total_cents')::int,
    (v_plan->>'total_cents')::int, (v_plan->>'gst_cents')::int, (v_plan->>'gst_rate_bps')::int,
    now() + interval '10 minutes')
  returning id into v_eval_id;

  insert into public.checkout_evaluation_operations(business_id, actor, idempotency_key, request_hash, evaluation_id)
  values(p_business, v_actor, p_idempotency_key, v_hash, v_eval_id);

  return jsonb_build_object(
    'status', 'ok', 'replayed', false, 'evaluation_id', v_eval_id,
    'expires_at', now() + interval '10 minutes',
    'server_lines', v_plan->'server_lines', 'applied_effects', v_plan->'applied_effects',
    'subtotal_cents', (v_plan->>'subtotal_cents')::int, 'discount_total_cents', (v_plan->>'discount_total_cents')::int,
    'total_cents', (v_plan->>'total_cents')::int, 'gst_cents', (v_plan->>'gst_cents')::int);
end $$;
revoke all on function public.evaluate_checkout(uuid, uuid, uuid, jsonb, uuid) from public, anon, authenticated;
grant execute on function public.evaluate_checkout(uuid, uuid, uuid, jsonb, uuid) to authenticated;

-- =====================================================================
-- 6. RETIRE record_cart_sale/7 (contract C). The v51 no-token cart path is revoked
--    from every browser role; the function definition stays in place. The kernel /9
--    token overload (re-created below) is now the ONLY browser cart entry.
-- =====================================================================
revoke all on function public.record_cart_sale(uuid, uuid, uuid, uuid, text, text, jsonb)
  from public, anon, authenticated;

-- =====================================================================
-- 7. public.record_cart_sale/9 - REPLACED to finalise custom lines and to belt-guard
--    a zero total. Everything else (token lock, single-use, stale re-validation,
--    budget commit, signed studio_discount lines, provenance, token consume) is
--    preserved exactly from v58. Deltas:
--      * the re-resolve loop does NOT call ps1b_catalog_price for a custom line - it
--        re-projects it AS-IS from the immutable token (the token is server-owned);
--      * a zero total raises the SAME typed 22023 as the plan (never stale P0001);
--      * server-line sale_items map custom -> item_type 'custom' (ref/product null);
--      * one CUSTOM_PRICE_LINE audit_log row is written per custom line, recording the
--        finalising actor plus the entered_by/reason provenance carried in the token.
-- =====================================================================
create or replace function public.record_cart_sale(
  p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text,
  p_idempotency_key text, p_lines jsonb, p_evaluation_id uuid, p_paid boolean default true)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_key text := nullif(btrim(p_idempotency_key), '');
  v_method text := lower(nullif(btrim(p_method), ''));
  v_paid boolean := coalesce(p_paid, true);
  v_eval public.checkout_evaluations%rowtype;
  v_line jsonb; v_ord int; v_rehash text; v_price jsonb;
  v_kind text; v_cid uuid; v_qty int; v_unit int;
  v_reproj jsonb := '[]'::jsonb;
  v_retail_lines int := 0; v_stamp_product uuid; v_stamp_qty int;
  v_financial jsonb; v_sale_id uuid; v_replayed boolean;
  eff jsonb; v_ps timestamptz; v_amt int; v_ful uuid; v_key_ben text; v_rule uuid; v_rule_name text;
  bp record; v_bp_id uuid; v_committed int; v_points int := 0; v_items json;
begin
  if v_actor is null then
    raise exception 'authenticated staff required to finalise a cart sale' using errcode = '42501';
  end if;
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to record a sale in this business (create_sales)' using errcode = '42501';
  end if;
  if v_key is null or length(v_key) < 8 then
    raise exception 'a cart-sale idempotency key of at least 8 characters is required' using errcode = '22023';
  end if;
  if v_method is null or v_method not in ('cash', 'card', 'paynow', 'other') then
    raise exception 'choose Cash, Card, PayNow or Other' using errcode = '22023';
  end if;
  if p_evaluation_id is null then
    raise exception 'the kernel finaliser requires a checkout evaluation token' using errcode = '22023';
  end if;

  -- 7.1 Lock the token. Single-use + tenant + scope validation.
  select * into v_eval from public.checkout_evaluations
   where id = p_evaluation_id and business_id = p_business for update;
  if not found then
    raise exception 'checkout evaluation not found in this business' using errcode = '42501';
  end if;
  if p_branch is not null and p_branch is distinct from v_eval.branch_id then
    raise exception 'stale_evaluation: branch does not match the evaluation token' using errcode = 'P0001';
  end if;
  if p_client is not null and p_client is distinct from v_eval.client_id then
    raise exception 'stale_evaluation: client does not match the evaluation token' using errcode = 'P0001';
  end if;

  -- 7.2 If already consumed: exact replay of THIS key, or a same-token/different-key
  --     loser (which must fail stale, never double-sell).
  if v_eval.consumed_at is not null then
    if exists (select 1 from public.financial_operations fo
                where fo.business_id = p_business and fo.sale_id = v_eval.consumed_sale_id
                  and fo.operation_type = 'quick_sale' and fo.idempotency_key = v_key) then
      select coalesce(sum(pl.points), 0) into v_points from public.points_ledger pl
       where pl.business_id = p_business and pl.sale_id = v_eval.consumed_sale_id and pl.entry_type = 'earn';
      select coalesce(json_agg(row_to_json(si) order by si.created_at, si.id), '[]'::json) into v_items
        from public.sale_items si where si.business_id = p_business and si.sale_id = v_eval.consumed_sale_id;
      return json_build_object('status', 'duplicate_ignored', 'sale_id', v_eval.consumed_sale_id,
        'business_id', p_business, 'total_cents', v_eval.total_cents, 'discount_total_cents', v_eval.discount_total_cents,
        'replayed', true, 'points_earned', 0, 'evaluation_id', v_eval.id, 'items', v_items);
    end if;
    raise exception 'stale_evaluation: this checkout evaluation was already consumed by another sale' using errcode = 'P0001';
  end if;
  if v_eval.expires_at <= now() then
    raise exception 'stale_evaluation: the checkout evaluation has expired; re-evaluate' using errcode = 'P0001';
  end if;

  -- 7.3 Config drift: the active config version must be UNCHANGED since evaluation.
  if v_eval.config_version_id is distinct from
     (select active_config_version_id from public.businesses where id = p_business) then
    raise exception 'stale_evaluation: the active configuration changed since evaluation; re-evaluate' using errcode = 'P0001';
  end if;

  -- 7.4 Price drift: re-resolve every server line and recompute the cart hash. A
  --     custom line is re-projected AS-IS from the immutable token - it has no catalog
  --     price to re-resolve, and the token being server-owned makes its amount
  --     tamper-proof already.
  v_ord := 0;
  for v_line in select * from jsonb_array_elements(v_eval.server_lines) loop
    v_ord := v_ord + 1;
    v_kind := v_line->>'catalog_kind';
    v_cid := nullif(v_line->>'catalog_id', '')::uuid;
    v_qty := (v_line->>'qty')::int;
    if v_kind = 'custom' then
      v_unit := (v_line->>'unit_price_cents')::int;
    else
      v_price := app.ps1b_catalog_price(p_business, v_kind, v_cid);
      if v_price->>'status' <> 'ok' then
        raise exception 'stale_evaluation: line % can no longer be priced (%); re-evaluate', v_ord, v_price->>'status'
          using errcode = 'P0001';
      end if;
      v_unit := (v_price->>'price_cents')::int;
      if v_kind = 'product' then v_retail_lines := v_retail_lines + 1; v_stamp_product := v_cid; v_stamp_qty := v_qty; end if;
    end if;
    v_reproj := v_reproj || jsonb_build_array(jsonb_build_object(
      'catalog_kind', v_kind, 'catalog_id', v_cid, 'name', v_line->>'name',
      'unit_price_cents', v_unit, 'qty', v_qty, 'line_total_cents', v_unit * v_qty));
  end loop;
  v_rehash := app.ps1c_cart_hash(v_reproj);
  if v_rehash is distinct from v_eval.cart_hash then
    raise exception 'stale_evaluation: catalog prices changed since evaluation; re-evaluate' using errcode = 'P0001';
  end if;

  -- 7.5 Budget re-check + COMMIT, atomically, under a deterministic
  --     (business_id, rule_id, period_start) lock order.
  for eff in select e from jsonb_array_elements(v_eval.applied_effects) e
              where (e->>'suppressed')::boolean is not true and coalesce((e->>'capped')::boolean, false) loop
    insert into public.budget_periods(business_id, rule_id, period_start, period_end, cap_cents)
    values(p_business, (eff->>'rule_id')::uuid, (eff->>'period_start')::timestamptz,
           (eff->>'period_end')::timestamptz, (eff->>'cap_cents')::int)
    on conflict (business_id, rule_id, period_start) do nothing;
  end loop;
  for bp in select (e->>'rule_id')::uuid as rule_id, (e->>'period_start')::timestamptz as ps,
                    (e->>'cap_cents')::int as cap, sum((e->>'amount_cents')::int) as amt
              from jsonb_array_elements(v_eval.applied_effects) e
             where (e->>'suppressed')::boolean is not true and coalesce((e->>'capped')::boolean, false)
             group by 1, 2, 3
             order by 1, 2 loop
    select coalesce(committed_cents, 0) into v_committed from public.budget_periods
     where business_id = p_business and rule_id = bp.rule_id and period_start = bp.ps
     for update;
    if coalesce(v_committed, 0) + bp.amt > bp.cap then
      raise exception 'stale_evaluation: rule budget was exhausted since evaluation; re-evaluate' using errcode = 'P0001';
    end if;
  end loop;

  -- 7.6 Belt-guard (contract B): a zero total must NEVER create a sale, and must fail
  --     as a TYPED 22023 (not a stale P0001 that would spin a client re-evaluation
  --     loop). evaluate_checkout never mints a zero-total token, so this only fires on
  --     a hand-crafted / pre-migration token.
  if v_eval.total_cents = 0 then
    raise exception 'total_zero_not_supported: this checkout totals zero after discounts and cannot be recorded; re-price it'
      using errcode = '22023';
  end if;

  -- 7.7 Create the parent sale for the DISCOUNTED total via the kernel candidate.
  perform set_config('app.cart_line_product_id',
    coalesce(case when v_retail_lines = 1 then v_stamp_product::text end, ''), true);
  perform set_config('app.cart_line_qty',
    coalesce(case when v_retail_lines = 1 then v_stamp_qty::text end, ''), true);
  v_financial := public.record_quick_sale(
    p_business => p_business, p_amount_cents => v_eval.total_cents, p_method => v_method,
    p_client => v_eval.client_id, p_staff => p_staff, p_branch => v_eval.branch_id, p_note => 'cart checkout (kernel)',
    p_idempotency_key => v_key, p_paid => v_paid)::jsonb;
  perform set_config('app.cart_line_product_id', '', true);
  perform set_config('app.cart_line_qty', '', true);

  v_sale_id := nullif(v_financial #>> '{sale,id}', '')::uuid;
  v_replayed := coalesce((v_financial->>'replayed')::boolean, false);
  if v_sale_id is null then
    raise exception 'kernel finaliser did not produce a parent sale row' using errcode = 'XX001';
  end if;
  if v_replayed then
    raise exception 'stale_evaluation: this idempotency key already produced a sale for a different token' using errcode = 'P0001';
  end if;

  -- 7.8 Write server-line sale_items (positive; custom -> item_type 'custom') then one
  --     signed studio_discount line per applied effect (negative).
  insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents, product_id)
  select v_sale_id, p_business,
         case e->>'catalog_kind' when 'service' then 'service' when 'product' then 'retail' else 'custom' end,
         nullif(e->>'catalog_id', '')::uuid, e->>'name', (e->>'qty')::int, (e->>'unit_price_cents')::int,
         (e->>'unit_price_cents')::int * (e->>'qty')::int,
         case when e->>'catalog_kind' = 'product' then nullif(e->>'catalog_id', '')::uuid end
    from jsonb_array_elements(v_eval.server_lines) e;

  -- 7.8b One CUSTOM_PRICE_LINE audit row per custom line: complete provenance
  --       (finalising actor + the entered_by/reason frozen in the token).
  for eff in select e from jsonb_array_elements(v_eval.server_lines) e where e->>'catalog_kind' = 'custom' loop
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values(p_business, v_actor, 'CUSTOM_PRICE_LINE', 'sale_items', v_sale_id,
      jsonb_build_object(
        'description', eff->>'name',
        'amount_cents', (eff->>'unit_price_cents')::int,
        'reason', eff->>'reason',
        'entered_by', eff->>'entered_by'));
  end loop;

  -- 7.9 Per applied (non-suppressed) discount: fulfilment registry row, provenance
  --     line, signed sale_items line, and (if capped) a committed budget reservation.
  for eff in select e from jsonb_array_elements(v_eval.applied_effects) e
              where (e->>'suppressed')::boolean is not true and (e->>'amount_cents')::int > 0
              order by (e->>'rule_id'), (e->>'effect_index')::int loop
    v_rule := (eff->>'rule_id')::uuid;
    v_amt := (eff->>'amount_cents')::int;
    select name into v_rule_name from public.program_rules
      where rule_id = v_rule and config_version_id = v_eval.config_version_id and business_id = p_business;
    v_rule_name := coalesce(v_rule_name, 'Studio discount');

    v_key_ben := 'discount:' || v_sale_id::text || ':' || v_rule::text || ':' || (eff->>'effect_index');
    insert into public.benefit_fulfilments(
      business_id, canonical_benefit_key, source_engine, fulfilment_kind, client_id, detail_ref,
      face_value_cents, estimated_cost_cents, cost_basis, cost_confidence, config_version_id, occurred_at)
    values(p_business, v_key_ben, 'checkout', 'checkout_discount', v_eval.client_id, v_sale_id,
      v_amt, v_amt, 'discount_face', 'high', v_eval.config_version_id, now())
    returning id into v_ful;

    insert into public.checkout_discount_lines(
      business_id, sale_id, evaluation_id, rule_id, effect_index, effect_type, level, target_line_index,
      amount_cents, benefit_fulfilment_id, config_version_id)
    values(p_business, v_sale_id, v_eval.id, v_rule, (eff->>'effect_index')::int, eff->>'effect_type',
      eff->>'level', nullif(eff->>'target_line_index', '')::int, v_amt, v_ful, v_eval.config_version_id);

    insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents)
    values(v_sale_id, p_business, 'studio_discount', v_rule, left('Discount: ' || v_rule_name, 200), 1, -v_amt, -v_amt);

    if coalesce((eff->>'capped')::boolean, false) then
      v_ps := (eff->>'period_start')::timestamptz;
      select id into v_bp_id from public.budget_periods
        where business_id = p_business and rule_id = v_rule and period_start = v_ps;
      insert into public.budget_reservations(business_id, budget_period_id, discount_fulfilment_id, amount_cents)
      values(p_business, v_bp_id, v_ful, v_amt);
      update public.budget_periods set committed_cents = committed_cents + v_amt, updated_at = now()
       where id = v_bp_id;
    end if;
  end loop;

  -- 7.10 Consume the token (single-use).
  update public.checkout_evaluations set consumed_at = now(), consumed_sale_id = v_sale_id
   where id = v_eval.id and consumed_at is null;
  if not found then
    raise exception 'stale_evaluation: token consumed concurrently; re-evaluate' using errcode = 'P0001';
  end if;

  if v_eval.client_id is not null then
    select coalesce(sum(pl.points), 0) into v_points from public.points_ledger pl
     where pl.business_id = p_business and pl.client_id = v_eval.client_id and pl.sale_id = v_sale_id and pl.entry_type = 'earn';
  end if;
  select coalesce(json_agg(row_to_json(si) order by si.created_at, si.id), '[]'::json) into v_items
    from public.sale_items si where si.business_id = p_business and si.sale_id = v_sale_id;

  return json_build_object(
    'status', 'ok', 'sale_id', v_sale_id, 'business_id', p_business,
    'subtotal_cents', v_eval.subtotal_cents, 'discount_total_cents', v_eval.discount_total_cents,
    'total_cents', v_eval.total_cents, 'gst_cents', v_eval.gst_cents,
    'replayed', false, 'points_earned', v_points, 'evaluation_id', v_eval.id,
    'sale', v_financial->'sale', 'items', v_items);
end $$;
revoke all on function public.record_cart_sale(uuid, uuid, uuid, uuid, text, text, jsonb, uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.record_cart_sale(uuid, uuid, uuid, uuid, text, text, jsonb, uuid, boolean)
  to authenticated;

commit;
