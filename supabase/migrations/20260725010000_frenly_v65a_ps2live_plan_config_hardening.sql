-- FRENLY v65a - PS-2 LIVE INCREMENT 1 HARDENING (close-out of the accepted v65)
--
-- Forward-only hardening of the applied+accepted v65 (commit c23518c, PASS V65). v65 is NOT edited
-- or reapplied. CREATE-OR-REPLACE of 5 existing functions only; no new tables, no schema change, no
-- product scope. Still config-only: writes zero sv_lot_movements/lots, never transitions sv_authority
-- (stays 'unbuilt'). Pinned contract: docs/design/ps2/PS2_LIVE_V65A_HARDENING_CONTRACT.md.
--
-- Changes (each replaced body differs from its v65 form ONLY by these):
--   1. Idempotency request hashes now include every meaningful field: publish (+expected_revision,
--      +normalized override_reason), discard (+expected_revision, +normalized reason), retire
--      (+normalized reason), reactivate (+normalized reason). Same key + changed field -> typed
--      conflict; identical normalized request -> replay.
--   2. app.sv_plan_assert_config validates plan_id as a UUID (typed 22023, not raw 22P02).
--   3. publish updates sv_plans.name to the new customer_facing_name in-txn on a rename + audits
--      old/new (SV_PLAN_RENAMED); immutable version snapshots untouched.
--   4. Robustness: integer fields beyond int4 range -> typed 22023 before cast; a category array that
--      canonicalises to empty -> typed 22023; explicit v_active is true / is not true.

begin;

-- 1/2/4. app.sv_plan_assert_config - + plan_id UUID validation, + int4 range bound, + category-empty.
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
      if (v#>>'{}')::bigint < 0 then raise exception '% cannot be negative', k using errcode = '22023'; end if;
      if (v#>>'{}')::bigint > int4_max then raise exception '% is too large (max 2147483647)', k using errcode = '22023'; end if;
    elsif k = any(nullable_int) then
      if jsonb_typeof(v) <> 'null' then
        if not app.sv_jsonb_is_int(v) then raise exception '% must be a whole number or null', k using errcode = '22023'; end if;
        if k in ('paid_expiry_days','bonus_expiry_days','purchase_window_days','purchase_max_in_window','purchase_lifetime_cap')
           and (v#>>'{}')::bigint <= 0 then raise exception '% must be a positive whole number', k using errcode = '22023'; end if;
        if k in ('min_spend_cents','max_balance_cents') and (v#>>'{}')::bigint < 0 then
          raise exception '% cannot be negative', k using errcode = '22023'; end if;
        if (v#>>'{}')::bigint > int4_max then raise exception '% is too large (max 2147483647)', k using errcode = '22023'; end if;
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

-- 1/3/4. publish_sv_plan_version - hash includes expected_revision + normalized override_reason;
--        in-txn plan rename + SV_PLAN_RENAMED audit; explicit v_active is not true.
create or replace function public.publish_sv_plan_version(
  p_business uuid, p_draft uuid, p_expected_revision integer, p_idempotency_key uuid, p_override_reason text default null)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.sv_plan_drafts%rowtype;
  v_plan uuid; v_active boolean; v_old_name text; v_version uuid := gen_random_uuid(); v_version_no integer;
  v_val jsonb; v_disc integer; v_hard integer; v_reason text := nullif(btrim(coalesce(p_override_reason,'')),'');
  v_hash text; v_hit jsonb; v_new_plan boolean := false; v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  v_hash := app.ps1b_sha256(jsonb_build_object('op','publish','business',p_business,'draft',p_draft,
    'expected_revision',p_expected_revision,'override_reason',v_reason)::text);
  v_hit := app.sv_plan_idem_lookup(p_business, 'publish', p_idempotency_key, v_hash);
  if v_hit is not null then return v_hit; end if;

  select * into v_row from public.sv_plan_drafts where id = p_draft and business_id = p_business for update;
  if not found then raise exception 'stored-value plan draft not found in this business' using errcode = '22023'; end if;
  if v_row.status = 'published' then
    return jsonb_build_object('status','ok','plan_id',v_row.plan_id,'version_id',v_row.published_version_id,'replayed',true);
  end if;
  if v_row.status = 'discarded' then raise exception 'a discarded stored-value plan draft cannot be published' using errcode = '22023'; end if;
  if p_expected_revision is null or p_expected_revision <> v_row.revision then
    raise exception 'stored-value plan draft was changed in another session (expected revision %, current %)', p_expected_revision, v_row.revision using errcode = '22023';
  end if;

  -- structural validation gate (blocks; not overridable)
  v_val := app.sv_plan_validate(p_business, p_draft);
  if (v_val->>'publishable')::boolean is not true then
    raise exception 'plan is not publishable: %', (v_val->'validation_errors')::text using errcode = '22023';
  end if;
  v_disc := (v_val->>'effective_discount_bps')::integer;
  v_hard := (v_val->>'hard_threshold_bps')::integer;
  if v_disc >= v_hard and (v_reason is null or char_length(v_reason) < 3) then
    raise exception 'effective discount is at/above the firm hard limit - an override reason of at least 3 characters is required' using errcode = '22023';
  end if;

  -- bind or create the plan container; LOCK it before numbering (Sec 7)
  v_plan := v_row.plan_id;
  if v_plan is null then
    v_plan := gen_random_uuid(); v_new_plan := true;
    insert into public.sv_plans(id, business_id, name, active) values (v_plan, p_business, v_row.customer_facing_name, true);
    insert into public.sv_plan_status_events(business_id, plan_id, actor, prior_status, new_status, reason)
    values (p_business, v_plan, v_actor, null, 'active', 'plan created');
  end if;
  perform 1 from public.sv_plans where id = v_plan and business_id = p_business for update;
  select active, name into v_active, v_old_name from public.sv_plans where id = v_plan and business_id = p_business;
  if v_active is not true then
    raise exception 'stored-value plan is retired - reactivate it before publishing a new version' using errcode = '22023';
  end if;
  select coalesce(max(version_no),0) + 1 into v_version_no from public.sv_plan_versions where plan_id = v_plan and business_id = p_business;

  insert into public.sv_plan_versions(
    id, business_id, plan_id, version_no, price_cents, bonus_cents, expiry_days, terms_snapshot,
    customer_facing_name, paid_expiry_days, bonus_expiry_days, eligible_branch_ids, eligible_service_ids,
    eligible_product_ids, eligible_service_categories, min_spend_cents, stacking_policy, max_balance_cents,
    purchase_window_days, purchase_max_in_window, purchase_lifetime_cap, refund_policy, spend_order,
    topup_purchase_earns_points, stored_value_spend_earns_points, customer_terms, accounting_inputs,
    effective_at, source_draft_id)
  values (
    v_version, p_business, v_plan, v_version_no, v_row.price_cents, v_row.bonus_cents,
    coalesce(v_row.paid_expiry_days, v_row.bonus_expiry_days),
    jsonb_build_object('customer_terms', v_row.customer_terms, 'accounting_inputs', v_row.accounting_inputs, 'source_draft_id', v_row.id),
    v_row.customer_facing_name, v_row.paid_expiry_days, v_row.bonus_expiry_days, v_row.eligible_branch_ids,
    v_row.eligible_service_ids, v_row.eligible_product_ids, v_row.eligible_service_categories, v_row.min_spend_cents,
    v_row.stacking_policy, v_row.max_balance_cents, v_row.purchase_window_days, v_row.purchase_max_in_window,
    v_row.purchase_lifetime_cap, v_row.refund_policy, v_row.spend_order, v_row.topup_purchase_earns_points,
    v_row.stored_value_spend_earns_points, v_row.customer_terms, v_row.accounting_inputs, v_row.effective_at, v_row.id);

  update public.sv_plan_drafts set status = 'published', plan_id = v_plan, published_version_id = v_version
   where id = p_draft and business_id = p_business;

  -- display-name contract: keep sv_plans.name in step with the latest published version (in-txn, audited).
  if (not v_new_plan) and v_old_name is distinct from v_row.customer_facing_name then
    update public.sv_plans set name = v_row.customer_facing_name where id = v_plan and business_id = p_business;
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'SV_PLAN_RENAMED', 'sv_plans', v_plan, jsonb_build_object(
      'old_name', v_old_name, 'new_name', v_row.customer_facing_name, 'version_id', v_version));
  end if;

  v_result := jsonb_build_object('status','ok','plan_id',v_plan,'version_id',v_version,'version_no',v_version_no,
    'effective_discount_bps',v_disc,'override_applied',(v_disc >= v_hard),'new_plan',v_new_plan,'replayed',false);
  insert into public.sv_plan_operations(business_id, op_type, idempotency_key, request_hash, actor, result)
  values (p_business, 'publish', p_idempotency_key, v_hash, v_actor, v_result);
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_PLAN_PUBLISHED', 'sv_plan_versions', v_version, jsonb_build_object(
    'plan_id', v_plan, 'version_no', v_version_no, 'price_cents', v_row.price_cents, 'bonus_cents', v_row.bonus_cents,
    'effective_discount_bps', v_disc, 'override_reason', v_reason, 'override_applied', (v_disc >= v_hard)));
  return v_result;
end $$;
revoke all on function public.publish_sv_plan_version(uuid, uuid, integer, uuid, text) from public, anon, authenticated;
grant execute on function public.publish_sv_plan_version(uuid, uuid, integer, uuid, text) to authenticated;

-- 1. discard_sv_plan_draft - hash includes expected_revision + normalized reason.
create or replace function public.discard_sv_plan_draft(
  p_business uuid, p_draft uuid, p_expected_revision integer, p_idempotency_key uuid, p_reason text default null)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid(); v_row public.sv_plan_drafts%rowtype; v_hash text; v_hit jsonb; v_result jsonb;
  v_norm_reason text := nullif(btrim(coalesce(p_reason,'')),'');
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  v_hash := app.ps1b_sha256(jsonb_build_object('op','discard','business',p_business,'draft',p_draft,
    'expected_revision',p_expected_revision,'reason',v_norm_reason)::text);
  v_hit := app.sv_plan_idem_lookup(p_business, 'discard', p_idempotency_key, v_hash);
  if v_hit is not null then return v_hit; end if;

  select * into v_row from public.sv_plan_drafts where id = p_draft and business_id = p_business for update;
  if not found then raise exception 'stored-value plan draft not found in this business' using errcode = '22023'; end if;
  if v_row.status = 'discarded' then
    v_result := jsonb_build_object('status','ok','draft_id',p_draft,'discarded',true,'replayed',true);
  elsif v_row.status = 'published' then
    raise exception 'a published stored-value plan draft cannot be discarded' using errcode = '22023';
  else
    if p_expected_revision is null or p_expected_revision <> v_row.revision then
      raise exception 'stored-value plan draft was changed in another session (expected revision %, current %)', p_expected_revision, v_row.revision using errcode = '22023';
    end if;
    update public.sv_plan_drafts set status = 'discarded' where id = p_draft and business_id = p_business;
    v_result := jsonb_build_object('status','ok','draft_id',p_draft,'discarded',true,'replayed',false);
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'SV_PLAN_DRAFT_DISCARDED', 'sv_plan_drafts', p_draft, jsonb_build_object('reason', v_norm_reason));
  end if;
  insert into public.sv_plan_operations(business_id, op_type, idempotency_key, request_hash, actor, result)
  values (p_business, 'discard', p_idempotency_key, v_hash, v_actor, v_result);
  return v_result;
end $$;
revoke all on function public.discard_sv_plan_draft(uuid, uuid, integer, uuid, text) from public, anon, authenticated;
grant execute on function public.discard_sv_plan_draft(uuid, uuid, integer, uuid, text) to authenticated;

-- 1/4. retire_sv_plan - hash includes normalized reason; explicit v_active is true.
create or replace function public.retire_sv_plan(p_business uuid, p_plan uuid, p_reason text, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid(); v_reason text := nullif(btrim(coalesce(p_reason,'')),''); v_active boolean;
  v_hash text; v_hit jsonb; v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  if v_reason is null or char_length(v_reason) < 3 then raise exception 'retiring a stored-value plan requires a reason of at least 3 characters' using errcode = '22023'; end if;
  v_hash := app.ps1b_sha256(jsonb_build_object('op','retire','business',p_business,'plan',p_plan,'reason',v_reason)::text);
  v_hit := app.sv_plan_idem_lookup(p_business, 'retire', p_idempotency_key, v_hash);
  if v_hit is not null then return v_hit; end if;

  select active into v_active from public.sv_plans where id = p_plan and business_id = p_business for update;
  if not found then raise exception 'stored-value plan does not belong to this business' using errcode = '22023'; end if;
  if v_active is true then
    update public.sv_plans set active = false where id = p_plan and business_id = p_business;
    insert into public.sv_plan_status_events(business_id, plan_id, actor, prior_status, new_status, reason)
    values (p_business, p_plan, v_actor, 'active', 'retired', v_reason);
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'SV_PLAN_RETIRED', 'sv_plans', p_plan, jsonb_build_object('reason', v_reason));
    v_result := jsonb_build_object('status','ok','plan_id',p_plan,'active',false,'replayed',false);
  else
    v_result := jsonb_build_object('status','ok','plan_id',p_plan,'active',false,'replayed',true);
  end if;
  insert into public.sv_plan_operations(business_id, op_type, idempotency_key, request_hash, actor, result)
  values (p_business, 'retire', p_idempotency_key, v_hash, v_actor, v_result);
  return v_result;
end $$;
revoke all on function public.retire_sv_plan(uuid, uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.retire_sv_plan(uuid, uuid, text, uuid) to authenticated;

-- 1/4. reactivate_sv_plan - hash includes normalized reason; explicit v_active is not true.
create or replace function public.reactivate_sv_plan(p_business uuid, p_plan uuid, p_reason text, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid(); v_reason text := nullif(btrim(coalesce(p_reason,'')),''); v_active boolean;
  v_hash text; v_hit jsonb; v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  if v_reason is null or char_length(v_reason) < 3 then raise exception 'reactivating a stored-value plan requires a reason of at least 3 characters' using errcode = '22023'; end if;
  v_hash := app.ps1b_sha256(jsonb_build_object('op','reactivate','business',p_business,'plan',p_plan,'reason',v_reason)::text);
  v_hit := app.sv_plan_idem_lookup(p_business, 'reactivate', p_idempotency_key, v_hash);
  if v_hit is not null then return v_hit; end if;

  select active into v_active from public.sv_plans where id = p_plan and business_id = p_business for update;
  if not found then raise exception 'stored-value plan does not belong to this business' using errcode = '22023'; end if;
  if v_active is not true then
    update public.sv_plans set active = true where id = p_plan and business_id = p_business;
    insert into public.sv_plan_status_events(business_id, plan_id, actor, prior_status, new_status, reason)
    values (p_business, p_plan, v_actor, 'retired', 'active', v_reason);
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'SV_PLAN_REACTIVATED', 'sv_plans', p_plan, jsonb_build_object('reason', v_reason));
    v_result := jsonb_build_object('status','ok','plan_id',p_plan,'active',true,'replayed',false);
  else
    v_result := jsonb_build_object('status','ok','plan_id',p_plan,'active',true,'replayed',true);
  end if;
  insert into public.sv_plan_operations(business_id, op_type, idempotency_key, request_hash, actor, result)
  values (p_business, 'reactivate', p_idempotency_key, v_hash, v_actor, v_result);
  return v_result;
end $$;
revoke all on function public.reactivate_sv_plan(uuid, uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.reactivate_sv_plan(uuid, uuid, text, uuid) to authenticated;

commit;
