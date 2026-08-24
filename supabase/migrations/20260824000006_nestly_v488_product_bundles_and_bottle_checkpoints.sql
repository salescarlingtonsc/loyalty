-- nestly_v488 — product bundle members + bottle expiry push at 7 / 3 / 0 days
-- (owner batch 2026-08-24, photos 1 and the bottle-expiry ruling; Sol review bypassed on the
--  owner's explicit instruction — neither half touches payments, auth or destructive prod ops)
--
-- HALF 1 — "i need product bundling as well (same as service bundle)".
--   bundle_items has been (bundle_id, service_id NOT NULL) since v6, so a bundle could only ever
--   hold services. A member row now carries EXACTLY ONE of service_id / product_id:
--     * schema: product_id added, service_id made nullable, the old two-column PK replaced by a
--       surrogate pair of partial unique indexes plus a one-of check;
--     * app.ps1c_bundle_lines_v204 (CREATE OR REPLACE, same name — ps1c_plan_checkout calls it
--       by name) prices the union of active service and product members, pro-rata off their own
--       list prices exactly as before. Each emitted line now states its own kind and item_id;
--       service lines STILL emit service_id, so a plan function from the pre-v488 bundle reads
--       them unchanged during the CDN window;
--     * app.ps1c_plan_checkout re-stated in full (extract-and-diff from the v394 authority, the
--       last migration to own it) with a two-line change in the bundle loop: member kind and id
--       are read from the line instead of being hardcoded 'service'. A product member therefore
--       becomes a plain kind='product' plan line — indistinguishable from a product rung up at
--       the till — so recording, reporting and stock deduction ride the existing rails and no
--       second "bundle product" concept exists anywhere downstream;
--     * create_bundle_v488 / update_bundle_v488: the v123/v285 writers with a p_product_ids
--       parameter. NEW NAMES, not overloads — an overload differing only in arity is the
--       PostgREST ambiguity v278/v279 already paid for. The v123/v285 writers stay deployed and
--       callable (the 4-hour CDN window serves bundles that still call them).
--
-- HALF 2 — "i need the push notification to happen when left 7 days to expiry and left 3 days
--   and today expiry (for this bottle expiry)".
--   app.v282_sweep_bottle_expiry sent ONE reminder per bottle, at an owner-configured number of
--   days, deduped forever on (identity, bottle, expires_at). It now fires at three fixed
--   checkpoints — 7 days, 3 days, day-of — each deduped separately (the checkpoint joins the
--   dedupe and idem keys). Per run a bottle fires at most the TIGHTEST matching checkpoint, so a
--   sweep that was down for days does not stack three alerts on resume. The events keep source
--   kind 'v282_bottle_expiry', which customer_push_event_eligible_v95 already lists, so the
--   existing dispatch turns them into real push notifications with no change there.
--   bar_expiry_reminder_days_v282 and its saved value stay deployed and untouched; the sweep
--   simply no longer reads it (owner ruling supersedes the configurable window).

begin;

-- ============================================================================================
-- 1. Schema: bundle_items learns products
-- ============================================================================================

alter table public.bundle_items
  add column if not exists product_id uuid references public.products(id) on delete cascade;

-- The PK was (bundle_id, service_id); with service_id nullable it can no longer stand — and it
-- must go FIRST, because a column inside a primary key refuses DROP NOT NULL (42P16, learned on
-- the first apply attempt). The replacement is the same uniqueness stated per member kind. No PK
-- remains on the table — RLS and both writers address rows only by bundle_id, and the
-- delete-then-insert writer never needed row identity.
alter table public.bundle_items drop constraint if exists bundle_items_pkey;

alter table public.bundle_items alter column service_id drop not null;

create unique index if not exists bundle_items_service_uniq
  on public.bundle_items (bundle_id, service_id) where service_id is not null;
create unique index if not exists bundle_items_product_uniq
  on public.bundle_items (bundle_id, product_id) where product_id is not null;

alter table public.bundle_items drop constraint if exists bundle_items_one_member_v488;
alter table public.bundle_items add constraint bundle_items_one_member_v488
  check ((service_id is null) <> (product_id is null));

-- ============================================================================================
-- 2. app.ps1c_bundle_lines_v204 — prices service AND product members
-- ============================================================================================

CREATE OR REPLACE FUNCTION app.ps1c_bundle_lines_v204(p_business uuid, p_bundle uuid, p_qty integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_price int; v_name text; v_active boolean;
  v_rows int; v_list bigint := 0; v_alloc bigint := 0; v_share int;
  v_out jsonb := '[]'::jsonb; r record; v_i int := 0; v_total bigint;
begin
  select b.price_cents, b.name, b.active into v_price, v_name, v_active
    from public.bundles b where b.id = p_bundle and b.business_id = p_business;
  if not found then
    return jsonb_build_object('status','unknown_bundle',
      'reason','this bundle does not belong to this business');
  end if;
  if not coalesce(v_active,false) then
    return jsonb_build_object('status','inactive_bundle',
      'reason','this bundle is not available for sale');
  end if;
  if coalesce(v_price,0) < 1 then
    return jsonb_build_object('status','unpriced_bundle',
      'reason','this bundle has no price set');
  end if;

  -- nestly_v488: the member list is the union of active services and active products. The
  -- column asymmetry (services price_cents, products retail_price_cents) is ps1b's own note.
  select count(*), coalesce(sum(greatest(m.list,0)),0)
    into v_rows, v_list
    from (
      select greatest(s.price_cents,0) as list
        from public.bundle_items bi
        join public.services s on s.id = bi.service_id and s.business_id = p_business
       where bi.bundle_id = p_bundle and s.active
      union all
      select greatest(pr.retail_price_cents,0) as list
        from public.bundle_items bi
        join public.products pr on pr.id = bi.product_id and pr.business_id = p_business
       where bi.bundle_id = p_bundle and pr.active
    ) m;
  if coalesce(v_rows,0) < 1 then
    return jsonb_build_object('status','empty_bundle',
      'reason','this bundle has no sellable items in it');
  end if;

  v_total := v_price::bigint * p_qty;

  for r in
    select m.kind, m.id, m.name, m.list from (
      select 'service'::text as kind, s.id, s.name, greatest(s.price_cents,0) as list
        from public.bundle_items bi
        join public.services s on s.id = bi.service_id and s.business_id = p_business
       where bi.bundle_id = p_bundle and s.active
      union all
      select 'product'::text as kind, pr.id, pr.name, greatest(pr.retail_price_cents,0) as list
        from public.bundle_items bi
        join public.products pr on pr.id = bi.product_id and pr.business_id = p_business
       where bi.bundle_id = p_bundle and pr.active
    ) m
    order by m.name, m.id
  loop
    v_i := v_i + 1;
    if v_i = v_rows then
      v_share := (v_total - v_alloc)::int;
    elsif v_list > 0 then
      v_share := floor(v_total * r.list / v_list)::int;
    else
      v_share := floor(v_total / v_rows)::int;
    end if;
    v_alloc := v_alloc + v_share;
    -- 'service_id' is kept on service lines VERBATIM so a pre-v488 ps1c_plan_checkout still
    -- reads this payload correctly through the CDN window. 'kind'/'item_id' are the v488 shape.
    v_out := v_out || jsonb_build_object(
      'kind', r.kind,
      'item_id', r.id,
      'service_id', case when r.kind = 'service' then r.id else null end,
      'name', r.name || ' · ' || v_name,
      'line_cents', greatest(v_share,0));
  end loop;

  return jsonb_build_object('status','ok','bundle_name',v_name,
    'total_cents', v_total, 'lines', v_out);
end
$function$;

-- Restate the live ACL verbatim (proacl {postgres=X/postgres}): owner-only, no API role.
revoke all on function app.ps1c_bundle_lines_v204(uuid, uuid, integer) from public, anon, authenticated;

-- ============================================================================================
-- 3. app.ps1c_plan_checkout — reads each bundle member's own kind (full restatement follows;
--    the only change from the v394 authority is the commented two-line patch in the bundle loop)
-- ============================================================================================

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
        -- nestly_v488 (owner: "i need product bundling as well, same as service bundle").
        -- ps1c_bundle_lines_v204 now states each member's own kind; a service member is
        -- byte-identical to before (kind 'service', service_id still emitted), and a product
        -- member becomes a plain kind='product' line — indistinguishable from a product line
        -- rung up at the till, so pricing, recording and stock deduction ride the existing rails.
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

-- ============================================================================================
-- 4. Bundle writers that accept products (new names, not overloads)
-- ============================================================================================

create or replace function public.create_bundle_v488(
  p_business uuid, p_name text, p_price_cents integer,
  p_service_ids uuid[], p_product_ids uuid[], p_idempotency_key text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_name text := btrim(coalesce(p_name,''));
  v_service_ids uuid[];
  v_product_ids uuid[];
  v_member_count integer;
  v_request_hash text;
  v_existing app.service_bundle_operations_v123%rowtype;
  v_bundle_id uuid;
  v_response jsonb;
begin
  if v_actor is null or p_business is null
     or not app.can_module_write(p_business,'services') then
    raise exception 'permission denied' using errcode='42501';
  end if;

  select array_agg(candidate order by candidate) into v_service_ids
    from (select distinct unnest(coalesce(p_service_ids,array[]::uuid[])) as candidate) s
   where candidate is not null;
  select array_agg(candidate order by candidate) into v_product_ids
    from (select distinct unnest(coalesce(p_product_ids,array[]::uuid[])) as candidate) s
   where candidate is not null;
  v_member_count := cardinality(coalesce(v_service_ids,array[]::uuid[]))
                  + cardinality(coalesce(v_product_ids,array[]::uuid[]));

  -- The v123 floor of 2 holds for the bundle as a whole, not per kind: one service plus one
  -- product is a real bundle. The 50 cap holds across both.
  if char_length(v_name) not between 2 and 120
     or p_price_cents is null or p_price_cents not between 0 and 100000000
     or p_idempotency_key is null
     or char_length(p_idempotency_key) not between 1 and 160
     or v_member_count not between 2 and 50 then
    raise exception 'invalid bundle' using errcode='22023';
  end if;

  v_request_hash := app.v41_request_hash(jsonb_build_object(
    'business_id',p_business,'name',v_name,'price_cents',p_price_cents,
    'service_ids',to_jsonb(coalesce(v_service_ids,array[]::uuid[])),
    'product_ids',to_jsonb(coalesce(v_product_ids,array[]::uuid[]))
  )::text);

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'v488:bundle:'||p_business::text||':'||v_actor::text||':'||p_idempotency_key, 488));

  select * into v_existing
    from app.service_bundle_operations_v123 operation
   where operation.business_id=p_business
     and operation.actor=v_actor
     and operation.idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_hash<>v_request_hash then
      raise exception 'idempotency key reused with a different bundle' using errcode='22023';
    end if;
    return v_existing.response||jsonb_build_object('replayed',true);
  end if;

  if v_service_ids is not null and (
    select count(*) from public.services service
     where service.business_id=p_business and service.active
       and service.id=any(v_service_ids)
  ) <> cardinality(v_service_ids) then
    raise exception 'bundle services must be active in this business' using errcode='22023';
  end if;
  if v_product_ids is not null and (
    select count(*) from public.products product
     where product.business_id=p_business and product.active
       and product.id=any(v_product_ids)
  ) <> cardinality(v_product_ids) then
    raise exception 'bundle products must be active in this business' using errcode='22023';
  end if;

  insert into public.bundles (business_id,name,price_cents)
  values (p_business,v_name,p_price_cents)
  returning id into v_bundle_id;

  insert into public.bundle_items (bundle_id,service_id)
  select v_bundle_id,service_id from unnest(coalesce(v_service_ids,array[]::uuid[])) service_id;
  insert into public.bundle_items (bundle_id,product_id)
  select v_bundle_id,product_id from unnest(coalesce(v_product_ids,array[]::uuid[])) product_id;

  v_response := jsonb_build_object('status','created','bundle_id',v_bundle_id,'replayed',false);

  insert into app.service_bundle_operations_v123 (
    business_id,actor,idempotency_key,request_hash,bundle_id,response
  ) values (
    p_business,v_actor,p_idempotency_key,v_request_hash,v_bundle_id,v_response
  );

  insert into public.audit_log (business_id,actor,action,entity,entity_id,detail)
  values (
    p_business,v_actor,'SERVICE_BUNDLE_CREATE','bundles',v_bundle_id,
    jsonb_build_object('name',v_name,'price_cents',p_price_cents,
      'service_count',cardinality(coalesce(v_service_ids,array[]::uuid[])),
      'product_count',cardinality(coalesce(v_product_ids,array[]::uuid[])))
  );

  return v_response;
end
$function$;

revoke all on function public.create_bundle_v488(uuid, text, integer, uuid[], uuid[], text) from public, anon;
grant execute on function public.create_bundle_v488(uuid, text, integer, uuid[], uuid[], text) to authenticated;
grant execute on function public.create_bundle_v488(uuid, text, integer, uuid[], uuid[], text) to service_role;

create or replace function public.update_bundle_v488(
  p_business uuid, p_bundle uuid, p_name text, p_price_cents integer,
  p_service_ids uuid[], p_product_ids uuid[], p_active boolean)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_service_ids uuid[];
  v_product_ids uuid[];
  v_replace_items boolean := p_service_ids is not null or p_product_ids is not null;
  v_member_count integer;
  v_bundle public.bundles%rowtype;
begin
  if v_actor is null or p_business is null or p_bundle is null
     or not app.can_module_write(p_business, 'services') then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  select * into v_bundle
    from public.bundles bundle
   where bundle.id = p_bundle and bundle.business_id = p_business
     for update;
  if not found then
    raise exception 'bundle not found' using errcode = '22023';
  end if;

  if v_name is not null and char_length(v_name) not between 2 and 120 then
    raise exception 'invalid bundle' using errcode = '22023';
  end if;
  if p_price_cents is not null and p_price_cents not between 0 and 100000000 then
    raise exception 'invalid bundle' using errcode = '22023';
  end if;

  -- v285 read a null p_service_ids as "leave the members alone". With two member lists that
  -- contract has one sharp edge: a caller replacing the members must send BOTH lists (either may
  -- be empty), because "replace the services, keep the products" is not a thing the till or the
  -- editor ever means — the editor always states the whole membership.
  if v_replace_items then
    select array_agg(candidate order by candidate) into v_service_ids
      from (select distinct unnest(coalesce(p_service_ids,array[]::uuid[])) as candidate) s
     where candidate is not null;
    select array_agg(candidate order by candidate) into v_product_ids
      from (select distinct unnest(coalesce(p_product_ids,array[]::uuid[])) as candidate) s
     where candidate is not null;
    v_member_count := cardinality(coalesce(v_service_ids,array[]::uuid[]))
                    + cardinality(coalesce(v_product_ids,array[]::uuid[]));
    if v_member_count not between 2 and 50 then
      raise exception 'a bundle holds between 2 and 50 items' using errcode = '22023';
    end if;
    if v_service_ids is not null and (
      select count(*) from public.services service
       where service.business_id = p_business and service.active
         and service.id = any(v_service_ids)
    ) <> cardinality(v_service_ids) then
      raise exception 'bundle services must be active in this business' using errcode = '22023';
    end if;
    if v_product_ids is not null and (
      select count(*) from public.products product
       where product.business_id = p_business and product.active
         and product.id = any(v_product_ids)
    ) <> cardinality(v_product_ids) then
      raise exception 'bundle products must be active in this business' using errcode = '22023';
    end if;
  end if;

  update public.bundles bundle
     set name = coalesce(v_name, bundle.name),
         price_cents = coalesce(p_price_cents, bundle.price_cents),
         active = coalesce(p_active, bundle.active)
   where bundle.id = p_bundle and bundle.business_id = p_business;

  if v_replace_items then
    delete from public.bundle_items item where item.bundle_id = p_bundle;
    insert into public.bundle_items (bundle_id, service_id)
    select p_bundle, service_id from unnest(coalesce(v_service_ids,array[]::uuid[])) service_id;
    insert into public.bundle_items (bundle_id, product_id)
    select p_bundle, product_id from unnest(coalesce(v_product_ids,array[]::uuid[])) product_id;
  end if;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (
    p_business, v_actor, 'SERVICE_BUNDLE_UPDATE', 'bundles', p_bundle,
    jsonb_build_object('name', v_name, 'price_cents', p_price_cents, 'active', p_active,
      'service_count', cardinality(coalesce(v_service_ids, array[]::uuid[])),
      'product_count', cardinality(coalesce(v_product_ids, array[]::uuid[])))
  );

  return jsonb_build_object('status', 'updated', 'bundle_id', p_bundle);
end
$function$;

revoke all on function public.update_bundle_v488(uuid, uuid, text, integer, uuid[], uuid[], boolean) from public, anon;
grant execute on function public.update_bundle_v488(uuid, uuid, text, integer, uuid[], uuid[], boolean) to authenticated;
grant execute on function public.update_bundle_v488(uuid, uuid, text, integer, uuid[], uuid[], boolean) to service_role;

-- ============================================================================================
-- 5. Bottle expiry: three fixed push checkpoints — 7 days, 3 days, day-of
-- ============================================================================================

CREATE OR REPLACE FUNCTION app.v282_sweep_bottle_expiry(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_expired integer := 0;
  v_reminded integer := 0;
begin
  with lapsed as (
    update public.bar_bottles bottle
       set status = 'expired', updated_at = v_now
     where bottle.status = 'stored'
       and bottle.expires_at <= v_now
    returning bottle.id, bottle.business_id, bottle.expires_at
  ), evidenced as (
    insert into public.bar_bottle_events (
      business_id, bottle_id, kind, actor, idem_key, detail
    )
    select
      lapsed.business_id, lapsed.id, 'expire', null::uuid,
      'v282-expire:' || lapsed.id::text,
      jsonb_build_object('swept_at', v_now, 'expires_at', lapsed.expires_at)
    from lapsed
    on conflict do nothing
    returning 1
  )
  select count(*)::integer into v_expired from lapsed;

  -- nestly_v488 (owner: "push notification when left 7 days to expiry and left 3 days and today
  -- expiry"). Three FIXED checkpoints replace the configurable single window. Per run a bottle
  -- fires at most the TIGHTEST checkpoint it has entered (min over matches), so a sweep that was
  -- down for days does not stack three alerts on resume; per lifetime each checkpoint fires at
  -- most once, because the checkpoint is part of the dedupe key. Source kind stays
  -- 'v282_bottle_expiry' — already listed by customer_push_event_eligible_v95 — so these become
  -- real push notifications through the existing dispatch with no change there.
  with due as (
    select
      bottle.id as bottle_id,
      bottle.business_id,
      bottle.expires_at,
      coalesce(nullif(btrim(bottle.label), ''), 'Your bottle') as bottle_name,
      link.id as link_id,
      link.identity_id,
      link.auth_user_id,
      link.client_id,
      (select min(checkpoint.days) from (values (7),(3),(0)) as checkpoint(days)
        where bottle.expires_at <= v_now + make_interval(days => checkpoint.days + 1)
      ) as checkpoint_days
    from public.bar_bottles bottle
    join public.customer_links link
      on link.business_id = bottle.business_id
     and link.client_id = bottle.client_id
     and link.state = 'verified'
     and link.unlinked_at is null
    left join public.customer_notification_preferences preference
      on preference.business_id = link.business_id
     and preference.identity_id = link.identity_id
     and preference.auth_user_id = link.auth_user_id
     and preference.link_id = link.id
     and preference.channel = 'in_app'
     and preference.topic = 'value_expiry'
    where bottle.status = 'stored'
      and bottle.expires_at > v_now
      and bottle.expires_at <= v_now + make_interval(days => 8)
      and coalesce(preference.opted_in, true)
      and app.customer_communication_allows_v263(
        link.identity_id, 'rewards_and_points', 'in_app'
      )
  ), enqueued as (
    insert into public.customer_in_app_inbox_events (
      business_id, identity_id, auth_user_id, link_id, client_id,
      source_kind, topic, route_key, source_fingerprint, dedupe_key,
      title, body, deadline_at
    )
    select
      due.business_id, due.identity_id, due.auth_user_id, due.link_id, due.client_id,
      'v282_bottle_expiry', 'value_expiry', 'wallet_business',
      app.c46_sha256_hex(jsonb_build_object(
        'bottle_id', due.bottle_id, 'expires_at', due.expires_at,
        'checkpoint', due.checkpoint_days)::text),
      app.c46_sha256_hex(jsonb_build_object(
        'identity_id', due.identity_id, 'bottle_id', due.bottle_id,
        'expires_at', due.expires_at, 'checkpoint', due.checkpoint_days)::text),
      case due.checkpoint_days
        when 0 then 'Your bottle expires today'
        when 3 then 'Your bottle expires in 3 days'
        else 'Your bottle expires in 7 days'
      end,
      due.bottle_name || ' is kept for you until '
        || to_char(due.expires_at at time zone 'Asia/Singapore', 'DD Mon YYYY')
        || '. Come by and enjoy it before then.',
      due.expires_at
    from due
    where due.checkpoint_days is not null
    on conflict (identity_id, dedupe_key) do nothing
    returning id, business_id
  ), noted as (
    insert into public.bar_bottle_events (
      business_id, bottle_id, kind, actor, idem_key, detail
    )
    select
      due.business_id, due.bottle_id, 'reminder', null::uuid,
      'v488-remind:' || due.bottle_id::text || ':' || due.expires_at::text
        || ':' || due.checkpoint_days::text,
      jsonb_build_object('delivery', 'in_app', 'automated', true,
        'expires_at', due.expires_at, 'checkpoint_days', due.checkpoint_days)
    from due
    where due.checkpoint_days is not null
    on conflict do nothing
    returning 1
  )
  select count(*)::integer into v_reminded from enqueued;

  return jsonb_build_object(
    'swept_at', v_now, 'expired', v_expired, 'reminded', v_reminded);
end
$function$;

-- Restate the live ACL verbatim (proacl {postgres=X/postgres,service_role=X/postgres}).
revoke all on function app.v282_sweep_bottle_expiry(timestamp with time zone) from public, anon, authenticated;
grant execute on function app.v282_sweep_bottle_expiry(timestamp with time zone) to service_role;

commit;
