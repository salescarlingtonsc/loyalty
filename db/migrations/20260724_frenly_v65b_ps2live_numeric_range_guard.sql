-- FRENLY v65b - PS-2 LIVE: NUMERIC-SAFE INTEGER RANGE GUARD (close the LOW residual from PASS V65A)
--
-- Forward-only, narrow. Do NOT edit/reapply v65 or v65a. CREATE-OR-REPLACE of exactly ONE function
-- (app.sv_plan_assert_config); no other function, no table, no schema change. Config-only: writes
-- zero sv_lot_movements/lots, never transitions sv_authority (stays 'unbuilt'). Pinned contract:
-- docs/design/ps2/PS2_LIVE_V65B_NUMERIC_RANGE_CONTRACT.md.
--
-- THE ONLY CHANGE vs the v65a body: the 5 integer RANGE comparisons cast to ::numeric instead of
-- ::bigint, so an input beyond BIGINT range reaches the "> int4_max" check and is rejected with the
-- existing typed 22023 rather than a raw 22003 from the ::bigint cast. Every other token is byte-
-- identical to v65a; the v65a<->v65b diff is ONLY the 5 ::bigint -> ::numeric tokens.

begin;

create or replace function app.sv_plan_assert_config(p_config jsonb, p_allow_plan_id boolean)
returns void language plpgsql immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  k text;
  v jsonb;
  allowed text[] := array['customer_facing_name','price_cents','bonus_cents','paid_expiry_days',
    'bonus_expiry_days','eligible_branch_ids','eligible_service_ids','eligible_product_ids',
    'eligible_service_categories','min_spend_cents','stacking_policy','max_balance_cents',
    'purchase_window_days','purchase_max_in_window','purchase_lifetime_cap','refund_policy',
    'spend_order','topup_purchase_earns_points','stored_value_spend_earns_points','customer_terms',
    'accounting_inputs','effective_at'];
  nullable_int text[] := array['paid_expiry_days','bonus_expiry_days','min_spend_cents','max_balance_cents',
    'purchase_window_days','purchase_max_in_window','purchase_lifetime_cap'];
  arr_uuid text[] := array['eligible_branch_ids','eligible_service_ids','eligible_product_ids'];
  int4_max constant bigint := 2147483647;
begin
  if p_config is null or jsonb_typeof(p_config) <> 'object' then
    raise exception 'plan configuration must be a JSON object' using errcode = '22023';
  end if;
  if p_allow_plan_id then allowed := array_append(allowed, 'plan_id'); end if;

  for k, v in select key, value from jsonb_each(p_config) loop
    if not (k = any(allowed)) then
      raise exception 'unknown plan configuration key: %', k using errcode = '22023';
    end if;

    if k = 'plan_id' then
      if jsonb_typeof(v) <> 'string' then raise exception 'plan_id must be a UUID string' using errcode = '22023'; end if;
      begin perform (v#>>'{}')::uuid; exception when others then raise exception 'plan_id is not a valid UUID' using errcode = '22023'; end;
    elsif k in ('price_cents','bonus_cents') then
      if not app.sv_jsonb_is_int(v) then raise exception '% must be a whole number', k using errcode = '22023'; end if;
      if (v#>>'{}')::numeric < 0 then raise exception '% cannot be negative', k using errcode = '22023'; end if;
      if (v#>>'{}')::numeric > int4_max then raise exception '% is too large (max 2147483647)', k using errcode = '22023'; end if;
    elsif k = any(nullable_int) then
      if jsonb_typeof(v) <> 'null' then
        if not app.sv_jsonb_is_int(v) then raise exception '% must be a whole number or null', k using errcode = '22023'; end if;
        if k in ('paid_expiry_days','bonus_expiry_days','purchase_window_days','purchase_max_in_window','purchase_lifetime_cap')
           and (v#>>'{}')::numeric <= 0 then raise exception '% must be a positive whole number', k using errcode = '22023'; end if;
        if k in ('min_spend_cents','max_balance_cents') and (v#>>'{}')::numeric < 0 then
          raise exception '% cannot be negative', k using errcode = '22023'; end if;
        if (v#>>'{}')::numeric > int4_max then raise exception '% is too large (max 2147483647)', k using errcode = '22023'; end if;
      end if;
    elsif k = any(arr_uuid) then
      if jsonb_typeof(v) not in ('array','null') then raise exception '% must be a JSON array of ids or null', k using errcode = '22023'; end if;
      if jsonb_typeof(v) = 'array' and jsonb_array_length(v) = 0 then
        raise exception '% cannot be an empty list (use null to mean all, or list at least one)', k using errcode = '22023'; end if;
    elsif k = 'eligible_service_categories' then
      if jsonb_typeof(v) not in ('array','null') then raise exception 'eligible_service_categories must be a JSON array or null' using errcode = '22023'; end if;
      if jsonb_typeof(v) = 'array' and jsonb_array_length(v) = 0 then
        raise exception 'eligible_service_categories cannot be an empty list (use null to mean all)' using errcode = '22023'; end if;
      if jsonb_typeof(v) = 'array' and not exists (select 1 from jsonb_array_elements_text(v) e where btrim(e) <> '') then
        raise exception 'eligible_service_categories has no non-blank values (use null to mean all)' using errcode = '22023'; end if;
    elsif k = 'stacking_policy' then
      if jsonb_typeof(v) <> 'string' or (v#>>'{}') not in ('stackable','not_with_other_discounts','exclusive') then
        raise exception 'stacking_policy must be stackable/not_with_other_discounts/exclusive' using errcode = '22023'; end if;
    elsif k = 'refund_policy' then
      if jsonb_typeof(v) <> 'string' or (v#>>'{}') not in ('full_unused','proportional','unused_only','no_refund') then
        raise exception 'refund_policy must be full_unused/proportional/unused_only/no_refund' using errcode = '22023'; end if;
    elsif k = 'spend_order' then
      if jsonb_typeof(v) <> 'string' or (v#>>'{}') not in ('bonus_first','paid_first','earliest_expiry_first','proportional') then
        raise exception 'spend_order must be bonus_first/paid_first/earliest_expiry_first/proportional' using errcode = '22023'; end if;
    elsif k in ('topup_purchase_earns_points','stored_value_spend_earns_points') then
      if jsonb_typeof(v) <> 'boolean' then raise exception '% must be true or false', k using errcode = '22023'; end if;
    elsif k = 'customer_facing_name' then
      if jsonb_typeof(v) <> 'string' then raise exception 'customer_facing_name must be text' using errcode = '22023'; end if;
      if char_length(btrim(v#>>'{}')) > 200 then raise exception 'customer_facing_name is too long (max 200 chars)' using errcode = '22023'; end if;
    elsif k = 'customer_terms' then
      if jsonb_typeof(v) not in ('string','null') then raise exception 'customer_terms must be text or null' using errcode = '22023'; end if;
      if jsonb_typeof(v) = 'string' and char_length(v#>>'{}') > 5000 then raise exception 'customer_terms is too long (max 5000 chars)' using errcode = '22023'; end if;
    elsif k = 'accounting_inputs' then
      if jsonb_typeof(v) <> 'object' then raise exception 'accounting_inputs must be a JSON object' using errcode = '22023'; end if;
    elsif k = 'effective_at' then
      if jsonb_typeof(v) not in ('string','null') then raise exception 'effective_at must be a timestamp string or null' using errcode = '22023'; end if;
      if jsonb_typeof(v) = 'string' then
        begin perform (v#>>'{}')::timestamptz; exception when others then raise exception 'effective_at is not a valid timestamp' using errcode = '22023'; end;
      end if;
    end if;
  end loop;
end $$;
revoke all on function app.sv_plan_assert_config(jsonb, boolean) from public, anon, authenticated;

commit;
