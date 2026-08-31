-- nestly_v665 — a scanned perk lands in the sale, and a wrong redemption can be taken back.
--
-- OWNER RULING (2026-08-31, photos 1-5):
--   1. "when business scan the qrcode - it should auto act as if rewards has been added (photo2).
--       in the event the voucher was not used - it should not 'use up' the vouchers or rather it
--       should be refunded whichever is easier, because current way is - once scanned > used up or
--       not = used up. and the vouchers is not reflected in 'record sale'"
--   2. "for rewards redeemed > i need to reverse it in the event of wrong redemption."
--
-- WHAT WAS WRONG. staff_scan_gift_qr_v515 settles on sight: scanning a tier-perk QR calls
-- staff_issue_tier_benefit_v365 there and then, which writes a tier_benefit_issues_v365 row and
-- spends one of the customer's "1 per month". Nothing about that scan reaches the open Record
-- sale — the perk is neither applied to the bill nor listed anywhere on the screen — and if the
-- customer walks out, or the counter scanned the wrong person's QR, the allowance is gone with no
-- way back. The customer's own app then says "Used on 31 Aug 2026 · Back on 1 Sep 2026" for a
-- perk they never received. Both halves of that are fixed here.
--
-- TWO MECHANISMS, NOT ONE. The owner offered a choice ("or rather it should be refunded whichever
-- is easier") and both turned out to be worth having, for different reasons:
--
--   A. STAGING (staff_stage_gift_qr_v665) — a DISCOUNT perk scanned at the till is applied to the
--      open cart instead of being issued. This is exactly the state the "Apply" button of v656
--      produces, and it is v656's machinery that spends the allowance: app.ps1c_plan_checkout
--      re-prices with the perk named, and record_cart_sale issues it in the same transaction that
--      takes the money. Abandon the sale and nothing was spent — the QR is used, the allowance is
--      not, and the customer can mint a fresh QR because their perk is still claimable. This is
--      the "should not use it up" answer, and it is only possible for a discount: an unlimited
--      perk has no QR at all (v515's own ruling) and a free-item perk is a hand-over, not a price.
--
--   B. REVERSAL (staff_reverse_gift_redemption_v665) — everything that IS settled on sight can be
--      taken back: a tier-perk issue, a welcome gift, a bring-back voucher and a referral gift.
--      This is the "refunded" answer, and it is what closes ruling 2.
--
-- WHY THE $0 SALE IS NOT REVERSED. Redeeming a welcome / bring-back / referral gift writes a $0
-- `sales` row so the visit is recorded without inventing revenue. That row is left exactly as it
-- stands. app.enforce_sale_reversal_bounds refuses a zero-dollar reversal that cannot show
-- package-session provenance, and loosening a guard on the money path to tidy a $0 row would be a
-- far worse trade than leaving an honest record of something that did happen and was then handed
-- back. No money is misstated either way: the row is zero. The reversal is recorded beside it in
-- gift_redemption_reversals_v665, which is what the workspace reads to say so on the row.
--
-- WHY A COLUMN AND NOT A DELETE. The allowance is counted by five different readers. Deleting the
-- issue row would return the allowance everywhere for free, and destroy the evidence that it was
-- ever given. `reversed_at` keeps the row and every counter gains the same three words. All five
-- are replaced below with their live definitions (pulled with pg_get_functiondef, then patched by
-- exact anchor, so this file and the database cannot drift):
--   app.ps1c_plan_checkout                     — the pricing kernel's pre-check
--   public.staff_issue_tier_benefit_v365       — the replay lookup and BOTH allowance counts
--   public.staff_tier_benefits_for_client_v365 — what the till shows
--   public.customer_get_tier_benefits_v501     — what the customer's own app shows
--   public.customer_create_gift_intent_v515    — whether a fresh QR may be minted
-- The idempotency index becomes partial on the same predicate: a reversed issue must not block a
-- later, legitimate re-issue carrying the key that was used the first time.
--
-- AUTHORITY. Reversing is `refund_sales` + the sales module, which is the authority every other
-- reversal on this platform already requires (staff_get_reversal_workflows, reverse_sale_fast_v84,
-- reverse_loyalty_redemption). Staging is till-or-loyalty write, which is what issuing already
-- required — staging spends less than issuing does, so it cannot need more.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. A tier-benefit issue can be marked returned.
-- ---------------------------------------------------------------------------------------------
alter table public.tier_benefit_issues_v365
  add column if not exists reversed_at timestamptz;

comment on column public.tier_benefit_issues_v365.reversed_at is
  'nestly_v665: set when this issue was handed back. Every allowance counter ignores such a row; '
  'who reversed it and why live in public.gift_redemption_reversals_v665.';

-- A reversed issue must not hold the idempotency key hostage: the counter may legitimately give
-- the same perk again, and record_cart_sale would arrive with a key it has used before.
drop index if exists public.tier_benefit_issues_v365_idem_uk;
create unique index if not exists tier_benefit_issues_v365_idem_uk
  on public.tier_benefit_issues_v365 (benefit_id, client_id, idem_key)
  where reversed_at is null;
create index if not exists tier_benefit_issues_v365_reversed_idx
  on public.tier_benefit_issues_v365 (business_id, client_id, reversed_at);

-- ---------------------------------------------------------------------------------------------
-- 2. The evidence. One row per reversal, for all four gift families, so the workspace has one
--    place to read "this was given and then handed back, by whom, and why".
-- ---------------------------------------------------------------------------------------------
create table if not exists public.gift_redemption_reversals_v665(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  gift_kind text not null,
  grant_id uuid,                                       -- welcome / bringback / referral
  issue_id uuid references public.tier_benefit_issues_v365(id) on delete restrict,
  reward_label text not null,
  redeemed_sale_id uuid,                               -- the $0 sale, kept for the activity row
  reversed_at timestamptz not null default now(),
  reversed_by uuid not null,
  reason text not null,
  idempotency_key uuid not null,

  constraint gift_redemption_reversals_v665_kind_check
    check (gift_kind = any (array['welcome','bringback','referral','tier_perk'])),
  -- The three grant tables are different tables, so a polymorphic FK is impossible — the same
  -- reasoning, and the same shape check, as customer_gift_intents_v515.
  constraint gift_redemption_reversals_v665_shape_check
    check ((gift_kind = 'tier_perk' and issue_id is not null and grant_id is null)
        or (gift_kind in ('welcome','bringback','referral')
            and grant_id is not null and issue_id is null)),
  constraint gift_redemption_reversals_v665_reason_check
    check (length(btrim(reason)) >= 10)
);

-- One reversal per thing reversed, ever.
create unique index if not exists gift_redemption_reversals_v665_target_uk
  on public.gift_redemption_reversals_v665 (business_id, gift_kind, coalesce(grant_id, issue_id));
create unique index if not exists gift_redemption_reversals_v665_idem_uk
  on public.gift_redemption_reversals_v665 (business_id, idempotency_key);
create index if not exists gift_redemption_reversals_v665_client_idx
  on public.gift_redemption_reversals_v665 (business_id, client_id, reversed_at desc);

alter table public.gift_redemption_reversals_v665 enable row level security;
-- Zero policies and revoked from the browser roles, exactly as customer_gift_intents_v515: every
-- read and write goes through a SECURITY DEFINER RPC that checks its own authority.
revoke all on public.gift_redemption_reversals_v665 from anon, authenticated;

create or replace function app.v665_gift_reversal_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  raise exception 'gift redemption reversals are append-only' using errcode = '23001';
end
$function$;

drop trigger if exists trg_gift_redemption_reversals_v665_guard on public.gift_redemption_reversals_v665;
create trigger trg_gift_redemption_reversals_v665_guard
  before delete or update on public.gift_redemption_reversals_v665
  for each row execute function app.v665_gift_reversal_guard();

-- ---------------------------------------------------------------------------------------------
-- 3. The five allowance readers, live definitions with `reversed_at is null` added.
-- ---------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.ps1c_plan_checkout(p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_config uuid, p_tier_benefit uuid DEFAULT NULL::uuid)
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
end $function$
;

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
   where benefit_id=p_benefit and client_id=p_client and idem_key=v_key
     and reversed_at is null;
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
     where benefit_id=p_benefit and client_id=p_client and period_key=v_period_key
       and reversed_at is null;
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
         where benefit_id=p_benefit and client_id=p_client and period_key=v_period_key
           and reversed_at is null)) end);
end $function$
;

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
      /* nestly_v656: the items this discount covers, by name, so the till can print the second
         line the owner asked for without a second round trip. Empty means the whole bill. */
      'scope_items',to_jsonb(app.v656_scope_names(b.id)),
      /* nestly_v657: which of the two shapes, and the money ceiling on a whole-bill one. */
      'discount_scope',b.discount_scope,'max_discount_cents',b.max_discount_cents,
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
         and i.reversed_at is null
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
end $function$
;

CREATE OR REPLACE FUNCTION public.customer_get_tier_benefits_v501(p_business_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_context record;
  v_tier public.loyalty_tiers%rowtype;
  v_birthday boolean;
  v_rows jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  select * into v_context from app.v32_customer_wallet_context(p_business_slug) limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  if not ('loyalty' = any(v_context.enabled_modules)) then
    return jsonb_build_object('status','ok','tier',null,'benefits','[]'::jsonb);
  end if;
  if not exists (
    select 1 from public.business_programmes spine
     where spine.business_id = v_context.business_id and spine.kind = 'tiers' and spine.active
  ) then
    return jsonb_build_object('status','ok','tier',null,'benefits','[]'::jsonb);
  end if;

  v_tier := app.v365_client_tier(v_context.business_id, v_context.client_id);
  if v_tier.id is null then
    return jsonb_build_object('status','ok','tier',null,'benefits','[]'::jsonb);
  end if;
  v_birthday := coalesce(app.v367_in_birthday_month(v_context.client_id, now()), false);

  select coalesce(jsonb_agg(jsonb_build_object(
      'benefit_id', b.id,
      'tier_id', b.tier_id,
      'tier_label', t.name,
      'label', b.label,
      'benefit_kind', b.benefit_kind,
      'discount_percent', b.discount_percent,
      'item_label', coalesce((select p.name from public.products p where p.id = b.product_id), b.item_label),
      'limit_count', b.limit_count,
      'limit_period', b.limit_period,
      'sentence', app.v365_benefit_sentence(b.label, b.limit_count, b.limit_period),
      /* nestly_v656: the items this discount covers, by name. Empty means the whole bill. */
      'scope_items', to_jsonb(app.v656_scope_names(b.id)),
      'discount_scope', b.discount_scope, 'max_discount_cents', b.max_discount_cents,
      'used', used.count_in_period,
      /* nestly_v654: the same lateral, so the date and the count can never describe different
         windows. Null when the perk has no use in this period — the client then prints exactly
         what it printed before. */
      'last_used_at', used.last_in_period,
      'remaining', case when b.limit_count is null then null
                        else greatest(0, b.limit_count - used.count_in_period) end,
      'period_ends_at', case when b.limit_count is null then null
                             else app.v501_period_ends_at(b.limit_period, now()) end,
      'claimable_now', (b.limit_period <> 'birthday_month' or v_birthday)
        and (b.limit_count is null or used.count_in_period < b.limit_count),
      'blocked_reason', case
        when b.limit_period = 'birthday_month' and not v_birthday then 'not_birthday_month'
        when b.limit_count is not null and used.count_in_period >= b.limit_count then 'used_up'
        else null end
    ) order by t.threshold desc, b.sort, b.id), '[]'::jsonb) into v_rows
    from public.tier_benefits_v365 b
    join public.loyalty_tiers t on t.id = b.tier_id and t.business_id = b.business_id
    cross join lateral (
      select count(*)::integer as count_in_period,
             max(i.issued_at) as last_in_period
        from public.tier_benefit_issues_v365 i
       where i.benefit_id = b.id and i.client_id = v_context.client_id
         and i.period_key = app.v365_period_key(b.limit_period, now())
         and i.reversed_at is null
    ) used
   where b.business_id = v_context.business_id
     and b.deleted_at is null and b.active
     and coalesce(t.paused, false) = false and t.deleted_at is null
     and t.threshold <= v_tier.threshold
     and (t.effective_from is null or t.effective_from <= statement_timestamp())
     and (t.expires_at is null or t.expires_at > statement_timestamp());

  return jsonb_build_object(
    'status','ok',
    'tier', jsonb_build_object('id', v_tier.id, 'label', v_tier.name, 'threshold', v_tier.threshold),
    'in_birthday_month', v_birthday,
    'benefits', v_rows);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.customer_create_gift_intent_v515(p_business uuid, p_gift_kind text, p_target uuid, p_idempotency_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_kind text := lower(btrim(coalesce(p_gift_kind,'')));
  v_identity uuid; v_client uuid;
  v_existing public.customer_gift_intents_v515%rowtype;
  v_request_hash text; v_token text; v_id uuid := gen_random_uuid();
  v_label text; v_min_spend integer := 0; v_period_key text; v_terms jsonb := '{}'::jsonb;
  v_benefit public.tier_benefits_v365%rowtype;
  v_tier public.loyalty_tiers%rowtype;
  v_used integer;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode='28000';
  end if;
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode='22023';
  end if;
  if v_kind not in ('welcome','bringback','referral','tier_perk') then
    raise exception 'unsupported gift kind' using errcode='22023';
  end if;
  if p_target is null then
    raise exception 'gift target is required' using errcode='22023';
  end if;

  select ci.id, l.client_id into v_identity, v_client
    from public.customer_identities ci
    join public.customer_links l
      on l.identity_id = ci.id and l.auth_user_id = v_actor and l.state = 'verified'
   where ci.auth_user_id = v_actor and ci.status = 'active' and l.business_id = p_business
   limit 1;
  if v_identity is null then
    raise exception 'verified customer link required' using errcode='42501';
  end if;
  if not app.v89_business_module_enabled(p_business,'loyalty') then
    raise exception 'this business is not running a customer programme' using errcode='42501';
  end if;

  v_request_hash := app.v89_sha256(p_business::text||':'||v_kind||':'||p_target::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v515:gift-intent:'||v_identity::text||':'||p_idempotency_key::text, 0));

  select * into v_existing from public.customer_gift_intents_v515 intent
   where intent.identity_id = v_identity and intent.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.request_hash <> v_request_hash then
      raise exception 'idempotency key conflicts with another gift intent' using errcode='23505';
    end if;
    return jsonb_build_object('intent_id',v_existing.id,'status',v_existing.status,
      'gift_kind',v_existing.gift_kind,'reward_label',v_existing.quoted_label,
      'min_spend_cents',v_existing.quoted_min_spend_cents,
      'qr_token',app.v89_redemption_token(v_identity,p_business,
        v_existing.gift_kind||'_v515',coalesce(v_existing.grant_id,v_existing.benefit_id),
        p_idempotency_key),
      'expires_at',v_existing.expires_at,'replayed',true);
  end if;

  -- Stand down any stale pending QR for this same gift so open_uk cannot block a fresh one.
  update public.customer_gift_intents_v515
     set status='expired'
   where business_id=p_business and client_id=v_client and status='pending'
     and coalesce(grant_id,benefit_id)=p_target and expires_at<=now();

  if v_kind = 'welcome' then
    select g.reward_label, coalesce(g.min_spend_cents,0) into v_label, v_min_spend
      from public.welcome_offer_grants_v215 g
     where g.id=p_target and g.business_id=p_business and g.client_id=v_client
       and g.status='granted' and (g.expires_at is null or g.expires_at>now());
    if v_label is null then
      raise exception 'this welcome gift is not available' using errcode='22023';
    end if;
  elsif v_kind = 'bringback' then
    select g.reward_label into v_label
      from public.bringback_grants_v361 g
     where g.id=p_target and g.business_id=p_business and g.client_id=v_client
       and g.status='granted' and (g.expires_at is null or g.expires_at>now());
    if v_label is null then
      raise exception 'this bring-back voucher is not available' using errcode='22023';
    end if;
  elsif v_kind = 'referral' then
    select g.reward_label into v_label
      from public.referral_grants_v420 g
     where g.id=p_target and g.business_id=p_business and g.client_id=v_client
       and g.status='granted' and (g.expires_at is null or g.expires_at>now());
    if v_label is null then
      raise exception 'this referral gift is not available' using errcode='22023';
    end if;
  else
    select * into v_benefit from public.tier_benefits_v365 b
     where b.id=p_target and b.business_id=p_business and b.active and b.deleted_at is null;
    if not found then
      raise exception 'this perk is not available' using errcode='22023';
    end if;
    -- Owner ruling: an UNLIMITED automatic perk gets no QR — checkout already applies it.
    if v_benefit.limit_count is null then
      raise exception 'this perk is applied automatically at payment' using errcode='22023';
    end if;
    select * into v_tier from public.loyalty_tiers t
     where t.id=v_benefit.tier_id and t.business_id=p_business;
    if not found or coalesce(v_tier.paused,false) or v_tier.deleted_at is not null then
      raise exception 'this perk is not available' using errcode='22023';
    end if;
    if coalesce((select ct.threshold from app.v365_client_tier(p_business, v_client) ct), -1)
       < coalesce(v_tier.threshold, 0) then
      raise exception 'this perk belongs to a tier you have not reached' using errcode='22023';
    end if;
    if v_benefit.limit_period = 'birthday_month'
       and not app.v367_in_birthday_month(v_client, now()) then
      raise exception 'this perk is only available in your birthday month' using errcode='22023';
    end if;
    v_period_key := app.v365_period_key(v_benefit.limit_period, now());
    select count(*) into v_used from public.tier_benefit_issues_v365 i
     where i.benefit_id=v_benefit.id and i.client_id=v_client and i.period_key=v_period_key
       and i.reversed_at is null;
    if v_used >= v_benefit.limit_count then
      raise exception 'you have used this perk for this period' using errcode='22023';
    end if;
    v_label := v_benefit.label;
    v_terms := jsonb_build_object('limit_count',v_benefit.limit_count,
                 'limit_period',v_benefit.limit_period,'used',v_used);
  end if;

  insert into public.customer_gift_intents_v515(
    id, business_id, identity_id, auth_user_id, client_id, gift_kind,
    grant_id, benefit_id, quoted_label, quoted_min_spend_cents, quoted_period_key,
    quoted_terms, token_hash, idempotency_key, request_hash, expires_at
  ) values (
    v_id, p_business, v_identity, v_actor, v_client, v_kind,
    case when v_kind='tier_perk' then null else p_target end,
    case when v_kind='tier_perk' then p_target else null end,
    v_label, v_min_spend, v_period_key, v_terms,
    app.v89_sha256(app.v89_redemption_token(v_identity,p_business,v_kind||'_v515',p_target,p_idempotency_key)),
    p_idempotency_key, v_request_hash, now() + interval '15 minutes'
  );

  v_token := app.v89_redemption_token(v_identity,p_business,v_kind||'_v515',p_target,p_idempotency_key);
  return jsonb_build_object('intent_id',v_id,'status','pending','gift_kind',v_kind,
    'reward_label',v_label,'min_spend_cents',v_min_spend,
    'qr_token',v_token,'expires_at',now()+interval '15 minutes','replayed',false);
end
$function$
;

-- ---------------------------------------------------------------------------------------------
-- 4. Staging: a discount perk scanned at the till goes onto the bill, not into the ledger.
-- ---------------------------------------------------------------------------------------------
create or replace function public.staff_stage_gift_qr_v665(
  p_business uuid, p_client uuid, p_qr_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_intent public.customer_gift_intents_v515%rowtype;
  v_benefit public.tier_benefits_v365%rowtype;
  v_period_now text;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '42501';
  end if;
  -- The same authority issuing already required. Staging spends strictly less.
  if not (app.is_salon_owner(p_business) or app.can_module_write(p_business,'till')
          or app.can_module_write(p_business,'loyalty')) then
    raise exception 'till or loyalty write authorization required' using errcode = '42501';
  end if;
  if p_qr_token is null or length(btrim(p_qr_token)) < 32 then
    raise exception 'gift QR is invalid' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'v515:scan:'||p_business::text||':'||app.v89_sha256(p_qr_token), 0));

  select * into v_intent from public.customer_gift_intents_v515
   where business_id = p_business and token_hash = app.v89_sha256(p_qr_token)
   for update;

  -- EVERY refusal here is a soft one. The caller falls straight through to
  -- staff_scan_gift_qr_v515, which owns the real error wording for an unknown, expired or
  -- already-used QR — two sources of truth for "why was that QR refused" is how they diverge.
  if not found then
    return jsonb_build_object('status','not_stageable','reason','unknown_token');
  end if;
  if v_intent.status <> 'pending' or v_intent.expires_at <= now() then
    return jsonb_build_object('status','not_stageable','reason','not_pending');
  end if;
  if v_intent.gift_kind <> 'tier_perk' then
    return jsonb_build_object('status','not_stageable','reason','not_a_tier_perk');
  end if;
  -- A QR belonging to somebody else must never be quietly applied to the customer on screen.
  if p_client is not null and v_intent.client_id is distinct from p_client then
    return jsonb_build_object('status','wrong_customer');
  end if;

  select * into v_benefit from public.tier_benefits_v365
   where id = v_intent.benefit_id and business_id = p_business
     and deleted_at is null and active;
  if not found then
    return jsonb_build_object('status','not_stageable','reason','benefit_gone');
  end if;
  -- Only a metered DISCOUNT can be staged: it is the only kind the checkout kernel can price,
  -- and pricing it is what defers the allowance to the moment money changes hands. A free item
  -- is a hand-over with no price to move, so it keeps the settle-on-scan path.
  if v_benefit.benefit_kind <> 'discount_pct'
     or coalesce(v_benefit.discount_percent, 0) <= 0
     or v_benefit.limit_count is null then
    return jsonb_build_object('status','not_stageable','reason','not_a_metered_discount');
  end if;

  -- The same period re-check staff_scan_gift_qr_v515 does: a QR minted at 23:58 on the 31st must
  -- not silently spend next month's allowance.
  v_period_now := app.v365_period_key(v_benefit.limit_period, now());
  if v_period_now is distinct from v_intent.quoted_period_key then
    raise exception 'this perk''s period rolled over; ask the customer for a new QR'
      using errcode = '23514';
  end if;

  v_result := jsonb_build_object('status','staged','gift_kind','tier_perk',
    'intent_id',v_intent.id,'benefit_id',v_benefit.id,'client_id',v_intent.client_id,
    'reward_label',v_intent.quoted_label,'discount_percent',v_benefit.discount_percent,
    'staged_at',now());

  -- The QR is spent; the ALLOWANCE is not. That asymmetry is the whole point: a customer whose
  -- sale is abandoned keeps their "1 per month" and simply shows a fresh QR.
  update public.customer_gift_intents_v515
     set status='completed', completed_at=now(), completed_by=v_actor, completion_result=v_result
   where id = v_intent.id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'TIER_PERK_STAGED_V665', 'customer_gift_intents_v515', v_intent.id,
    jsonb_build_object('client_id',v_intent.client_id,'benefit_id',v_benefit.id,
                       'label',v_intent.quoted_label));

  return v_result;
end
$function$;

-- ---------------------------------------------------------------------------------------------
-- 5. Reversal: a gift or perk given by mistake goes back to the customer.
-- ---------------------------------------------------------------------------------------------
create or replace function public.staff_reverse_gift_redemption_v665(
  p_business uuid, p_gift_kind text, p_target uuid, p_reason text, p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_kind text := lower(btrim(coalesce(p_gift_kind,'')));
  v_reason text := btrim(coalesce(p_reason,''));
  v_existing public.gift_redemption_reversals_v665%rowtype;
  v_client uuid; v_label text; v_sale uuid; v_branch uuid;
  v_grant uuid; v_issue uuid; v_id uuid;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode = '22023';
  end if;
  if v_kind not in ('welcome','bringback','referral','tier_perk') then
    raise exception 'unsupported gift kind' using errcode = '22023';
  end if;
  if length(v_reason) < 10 then
    raise exception 'a reason of at least 10 characters is required' using errcode = '22023';
  end if;
  -- The authority every other reversal on this platform requires. Deliberately NOT the till's
  -- write permission: giving a perk and taking one back are different acts.
  if not app.has_perm(p_business,'refund_sales') or not app.can_module(p_business,'sales') then
    raise exception 'refund_sales permission required' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'v665:gift-reversal:'||p_business::text||':'||p_target::text, 0));

  select * into v_existing from public.gift_redemption_reversals_v665
   where business_id = p_business and idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('status','completed','replayed',true,'reversal_id',v_existing.id,
      'gift_kind',v_existing.gift_kind,'reward_label',v_existing.reward_label,
      'client_id',v_existing.client_id,'redeemed_sale_id',v_existing.redeemed_sale_id);
  end if;

  if v_kind = 'tier_perk' then
    select i.client_id, i.label, i.branch_id into v_client, v_label, v_branch
      from public.tier_benefit_issues_v365 i
     where i.id = p_target and i.business_id = p_business and i.reversed_at is null
     for update;
    if v_client is null then
      raise exception 'gift_reversal_target_not_found' using errcode = '22023';
    end if;
    update public.tier_benefit_issues_v365 set reversed_at = now() where id = p_target;
    v_issue := p_target;
  elsif v_kind = 'welcome' then
    select g.client_id, g.reward_label, g.redeemed_sale_id into v_client, v_label, v_sale
      from public.welcome_offer_grants_v215 g
     where g.id = p_target and g.business_id = p_business and g.status = 'redeemed'
     for update;
    if v_client is null then
      raise exception 'gift_reversal_target_not_found' using errcode = '22023';
    end if;
    -- Back to 'granted' in one statement: welcome_offer_grants_v215_redeem_shape refuses any
    -- half-way state, which is exactly the protection wanted here.
    update public.welcome_offer_grants_v215
       set status = 'granted', redeemed_at = null, redeemed_sale_id = null, redeemed_by = null,
           qualifying_sale_id = null, redeem_idempotency_key = null
     where id = p_target;
    v_grant := p_target;
  elsif v_kind = 'bringback' then
    select g.client_id, g.reward_label, g.redeemed_sale_id into v_client, v_label, v_sale
      from public.bringback_grants_v361 g
     where g.id = p_target and g.business_id = p_business and g.status = 'redeemed'
     for update;
    if v_client is null then
      raise exception 'gift_reversal_target_not_found' using errcode = '22023';
    end if;
    update public.bringback_grants_v361
       set status = 'granted', redeemed_at = null, redeemed_sale_id = null, redeemed_by = null
     where id = p_target;
    v_grant := p_target;
  else
    select g.client_id, g.reward_label, g.redeemed_sale_id into v_client, v_label, v_sale
      from public.referral_grants_v420 g
     where g.id = p_target and g.business_id = p_business and g.status = 'redeemed'
     for update;
    if v_client is null then
      raise exception 'gift_reversal_target_not_found' using errcode = '22023';
    end if;
    update public.referral_grants_v420
       set status = 'granted', redeemed_at = null, redeemed_sale_id = null, redeemed_by = null
     where id = p_target;
    v_grant := p_target;
  end if;

  -- Branch scope is checked on the thing being reversed, not on the actor's default branch: a
  -- manager who cannot see the branch where a perk was given cannot take it back either.
  if v_branch is not null and not app.can_see_branch(p_business, v_branch) then
    raise exception 'gift_reversal_branch_not_permitted' using errcode = '42501';
  end if;

  insert into public.gift_redemption_reversals_v665(
    business_id, client_id, gift_kind, grant_id, issue_id, reward_label,
    redeemed_sale_id, reversed_by, reason, idempotency_key)
  values (p_business, v_client, v_kind, v_grant, v_issue, v_label,
          v_sale, v_actor, v_reason, p_idempotency_key)
  returning id into v_id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'GIFT_REDEMPTION_REVERSED_V665',
          'gift_redemption_reversals_v665', v_id,
    jsonb_build_object('client_id',v_client,'gift_kind',v_kind,'target_id',p_target,
                       'reward_label',v_label,'redeemed_sale_id',v_sale,'reason',v_reason));

  return jsonb_build_object('status','completed','replayed',false,'reversal_id',v_id,
    'gift_kind',v_kind,'reward_label',v_label,'client_id',v_client,'redeemed_sale_id',v_sale);
end
$function$;

-- ---------------------------------------------------------------------------------------------
-- 6. The read model behind both the till's "already given" list and the Reverse control on the
--    customer's activity history. Deliberately a SIBLING of staff_get_reversal_workflows rather
--    than a widening of it: that function is gated on refund_sales, and the till needs this list
--    for a cashier who has no such permission. `can_reverse` therefore states the actor's own
--    authority rather than assuming it.
-- ---------------------------------------------------------------------------------------------
create or replace function public.staff_gift_reversal_workflows_v665(
  p_business uuid, p_client uuid default null, p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_may_reverse boolean;
  v_rows jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '42501';
  end if;
  if not (app.is_salon_owner(p_business) or app.can_module_read(p_business,'till')
          or app.can_module_read(p_business,'loyalty')
          or app.can_module_read(p_business,'sales')) then
    raise exception 'till, loyalty or sales access required' using errcode = '42501';
  end if;
  v_may_reverse := app.has_perm(p_business,'refund_sales') and app.can_module(p_business,'sales');

  select coalesce(jsonb_agg(listed.item order by listed.given_at desc), '[]'::jsonb) into v_rows
  from (
    select given_at, jsonb_build_object(
             'id', target_id, 'gift_kind', gift_kind, 'client_id', client_id,
             'customer_name', customer_name, 'reward_label', reward_label,
             'given_at', given_at, 'sale_id', sale_id, 'branch_id', branch_id,
             'reversed_at', reversed_at, 'reversed_reason', reversed_reason,
             'can_reverse', v_may_reverse and reversed_at is null,
             'refusal_reason', case
               when reversed_at is not null then 'This has already been handed back.'
               when not v_may_reverse then 'Reversing a gift needs refund permission.'
               else null end
           ) as item
    from (
      select i.id as target_id, 'tier_perk'::text as gift_kind, i.client_id,
             c.full_name as customer_name, i.label as reward_label,
             i.issued_at as given_at, null::uuid as sale_id, i.branch_id,
             i.reversed_at, r.reason as reversed_reason
        from public.tier_benefit_issues_v365 i
        join public.clients c on c.id = i.client_id and c.business_id = i.business_id
        left join public.gift_redemption_reversals_v665 r
          on r.business_id = i.business_id and r.issue_id = i.id
       where i.business_id = p_business
         and (p_client is null or i.client_id = p_client)
         and app.can_see_branch(p_business, i.branch_id)
      union all
      select g.id, 'welcome', g.client_id, c.full_name, g.reward_label,
             coalesce(g.redeemed_at, r.reversed_at), coalesce(g.redeemed_sale_id, r.redeemed_sale_id), s.branch_id,
             r.reversed_at, r.reason
        from public.welcome_offer_grants_v215 g
        join public.clients c on c.id = g.client_id and c.business_id = g.business_id
        left join public.gift_redemption_reversals_v665 r
          on r.business_id = g.business_id and r.grant_id = g.id and r.gift_kind = 'welcome'
        left join public.sales s on s.id = coalesce(g.redeemed_sale_id, r.redeemed_sale_id)
                               and s.business_id = g.business_id
       where g.business_id = p_business
         and (p_client is null or g.client_id = p_client)
         and (g.status = 'redeemed' or r.id is not null)
      union all
      select g.id, 'bringback', g.client_id, c.full_name, g.reward_label,
             coalesce(g.redeemed_at, r.reversed_at), coalesce(g.redeemed_sale_id, r.redeemed_sale_id), s.branch_id,
             r.reversed_at, r.reason
        from public.bringback_grants_v361 g
        join public.clients c on c.id = g.client_id and c.business_id = g.business_id
        left join public.gift_redemption_reversals_v665 r
          on r.business_id = g.business_id and r.grant_id = g.id and r.gift_kind = 'bringback'
        left join public.sales s on s.id = coalesce(g.redeemed_sale_id, r.redeemed_sale_id)
                               and s.business_id = g.business_id
       where g.business_id = p_business
         and (p_client is null or g.client_id = p_client)
         and (g.status = 'redeemed' or r.id is not null)
      union all
      select g.id, 'referral', g.client_id, c.full_name, g.reward_label,
             coalesce(g.redeemed_at, r.reversed_at), coalesce(g.redeemed_sale_id, r.redeemed_sale_id), s.branch_id,
             r.reversed_at, r.reason
        from public.referral_grants_v420 g
        join public.clients c on c.id = g.client_id and c.business_id = g.business_id
        left join public.gift_redemption_reversals_v665 r
          on r.business_id = g.business_id and r.grant_id = g.id and r.gift_kind = 'referral'
        left join public.sales s on s.id = coalesce(g.redeemed_sale_id, r.redeemed_sale_id)
                               and s.business_id = g.business_id
       where g.business_id = p_business
         and (p_client is null or g.client_id = p_client)
         and (g.status = 'redeemed' or r.id is not null)
    ) unioned
    order by given_at desc nulls last
    limit v_limit
  ) listed;

  return jsonb_build_object('status','ok','may_reverse',v_may_reverse,'gifts',v_rows);
end
$function$;

-- ---------------------------------------------------------------------------------------------
-- 7. Grants. Restated verbatim from the live proacl for everything replaced, and set explicitly
--    for the three new functions. app.ps1c_plan_checkout has never been callable by a browser
--    role and stays that way.
-- ---------------------------------------------------------------------------------------------
revoke all on function app.ps1c_plan_checkout(uuid,uuid,uuid,jsonb,uuid,uuid) from public, anon, authenticated;

revoke all on function public.staff_issue_tier_benefit_v365(uuid,uuid,uuid,uuid,uuid) from public, anon;
grant execute on function public.staff_issue_tier_benefit_v365(uuid,uuid,uuid,uuid,uuid) to authenticated, service_role;

revoke all on function public.staff_tier_benefits_for_client_v365(uuid,uuid) from public, anon;
grant execute on function public.staff_tier_benefits_for_client_v365(uuid,uuid) to authenticated, service_role;

revoke all on function public.customer_get_tier_benefits_v501(text) from public, anon;
grant execute on function public.customer_get_tier_benefits_v501(text) to authenticated, service_role;

revoke all on function public.customer_create_gift_intent_v515(uuid,text,uuid,uuid) from public, anon;
grant execute on function public.customer_create_gift_intent_v515(uuid,text,uuid,uuid) to authenticated, service_role;

revoke all on function public.staff_stage_gift_qr_v665(uuid,uuid,text) from public, anon;
grant execute on function public.staff_stage_gift_qr_v665(uuid,uuid,text) to authenticated;

revoke all on function public.staff_reverse_gift_redemption_v665(uuid,text,uuid,text,uuid) from public, anon;
grant execute on function public.staff_reverse_gift_redemption_v665(uuid,text,uuid,text,uuid) to authenticated;

revoke all on function public.staff_gift_reversal_workflows_v665(uuid,uuid,integer) from public, anon;
grant execute on function public.staff_gift_reversal_workflows_v665(uuid,uuid,integer) to authenticated;

commit;
