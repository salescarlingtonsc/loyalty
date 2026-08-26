-- NESTLY v537 - THE CAPABILITY MODULE GATE ASKS THE RIGHT QUESTION
--
-- Found by the C6 acceptance suite. Not a C6 bug: a v518 bug that C6 was simply
-- the first thing to stand on.
--
-- app.capability_state_v518 answers "does this business have the required
-- module?" by reading businesses.enabled_modules directly:
--
--     not (v_cap.required_modules <@ coalesce(v_biz.enabled_modules, '{}'))
--
-- But enabled_modules is only ONE of three sources. The canonical resolver is
-- app.effective_platform_module_mode_v94, whose precedence is
--   branch_override -> firm_override -> sector_entitlement(enabled_modules)
-- and a firm override SHORT-CIRCUITS before enabled_modules is ever consulted.
--
-- That matters because public.platform_module_overrides_v94 is the ONLY way to
-- grant a module to a single business: app.business_sector_modules_guard_v75
-- refuses a direct edit to enabled_modules with "business modules are fixed by
-- the assigned sector entitlement". So the two mechanisms disagreed exactly
-- where they are both used - a per-firm module grant, plus a capability that
-- requires that module.
--
-- Live proof before the fix: Cubbly SPA resolves 'support' to 'rw via
-- firm_override', its RLS gate lets staff read the Inbox, and
-- capability_state_v518 still answered 'module_not_enabled'. The Inbox was
-- visible and the capability behind it was unreachable.
--
-- BOTH seeded capabilities were affected - whatsapp_support_reply (support) and
-- whatsapp_appointment_notification (appointments) - so this would also have
-- silently blocked the appointment-notification capability for any firm whose
-- appointments module came from an override.
--
-- The fix asks the canonical resolver instead. It is strictly more permissive in
-- the override case and IDENTICAL everywhere else: with no override row, the
-- resolver's last branch returns 'rw' exactly when the key is in
-- enabled_modules, which is the old predicate. A module explicitly disabled by
-- an override now correctly fails the capability too, which the old code missed
-- in the other direction.
--
-- One deliberate consequence worth naming: effective_platform_module_mode_v94
-- returns 'disabled' unconditionally for 'customerintel' (a global platform
-- policy predating this). No capability requires customerintel today, and if one
-- ever does it SHOULD fail closed while that policy stands.

begin;

create or replace function app.capability_state_v518(
  p_business uuid,
  p_capability text,
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_cap public.platform_capabilities_v518%rowtype;
  v_grant public.business_capability_grants_v518%rowtype;
  v_biz public.businesses%rowtype;
  v_enabled boolean;
  v_limit integer;
  v_period text;
  v_period_key text;
  v_used integer;
  v_module text;
  v_mode text;
  v_missing text[] := '{}';
begin
  select * into v_cap from public.platform_capabilities_v518 where capability_key = p_capability;
  if not found then
    return jsonb_build_object('allowed', false, 'reason', 'capability_unknown');
  end if;
  if not v_cap.active then
    return jsonb_build_object('allowed', false, 'reason', 'capability_inactive');
  end if;

  select * into v_biz from public.businesses where id = p_business;
  if not found then
    return jsonb_build_object('allowed', false, 'reason', 'business_unknown');
  end if;

  if v_cap.eligible_industries is not null
     and not (v_biz.industry = any (v_cap.eligible_industries)) then
    return jsonb_build_object(
      'allowed', false, 'reason', 'industry_not_eligible',
      'industry', v_biz.industry, 'eligible_industries', to_jsonb(v_cap.eligible_industries));
  end if;

  -- v537: ask the canonical resolver, not the raw column. A firm override is the
  -- only way to grant one business a module, and it short-circuits before
  -- enabled_modules is read.
  if v_cap.required_modules is not null and array_length(v_cap.required_modules, 1) is not null then
    foreach v_module in array v_cap.required_modules loop
      select resolved.mode into v_mode
        from app.effective_platform_module_mode_v94(p_business, null, v_module) resolved;
      if coalesce(v_mode, 'disabled') = 'disabled' then
        v_missing := v_missing || v_module;
      end if;
    end loop;
    if array_length(v_missing, 1) is not null then
      return jsonb_build_object(
        'allowed', false, 'reason', 'module_not_enabled',
        'required_modules', to_jsonb(v_cap.required_modules),
        'missing_modules', to_jsonb(v_missing));
    end if;
  end if;

  select * into v_grant from public.business_capability_grants_v518
   where business_id = p_business and capability_key = p_capability;

  v_enabled := coalesce(v_grant.enabled, v_cap.default_enabled);
  v_limit   := case when coalesce(v_grant.limit_unlimited, false) then null
                    else coalesce(v_grant.limit_count, v_cap.default_limit_count) end;
  v_period  := coalesce(v_grant.limit_period, v_cap.default_limit_period);
  v_period_key := app.v365_period_key(v_period, p_at);

  select count(*)::integer into v_used
    from public.capability_usage_v518
   where business_id = p_business
     and capability_key = p_capability
     and period_key = v_period_key;

  if not v_enabled then
    return jsonb_build_object(
      'allowed', false, 'reason', 'not_enabled',
      'limit_count', v_limit, 'limit_period', v_period,
      'period_key', v_period_key, 'used', v_used);
  end if;

  if v_limit is not null and v_used >= v_limit then
    return jsonb_build_object(
      'allowed', false, 'reason', 'quota_exhausted',
      'limit_count', v_limit, 'limit_period', v_period,
      'period_key', v_period_key, 'used', v_used, 'remaining', 0);
  end if;

  return jsonb_build_object(
    'allowed', true, 'reason', 'ok',
    'limit_count', v_limit, 'limit_period', v_period,
    'period_key', v_period_key, 'used', v_used,
    'remaining', case when v_limit is null then null else v_limit - v_used end);
end
$fn$;

revoke all on function app.capability_state_v518(uuid, text, timestamptz)
  from public, anon, authenticated;

commit;
