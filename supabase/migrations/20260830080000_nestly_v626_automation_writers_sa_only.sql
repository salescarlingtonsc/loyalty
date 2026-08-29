-- NESTLY v626 — the two automation control-plane writers match the authority the console
-- already claims for them. platform_set_capability_grant_v518 (WhatsApp capability grants) and
-- platform_set_retention_hold_v574 (retention sending holds) render super-admin-only in the
-- console, but their server gate was v89_platform_can('automation','rw') — any delegated admin
-- holding automation:rw could call them straight over PostgREST. Client and server now agree:
-- super admin only. Bodies are byte-faithful re-emissions of the live production definitions
-- with only the gate line changed.

begin;

CREATE OR REPLACE FUNCTION public.platform_set_capability_grant_v518(p_business uuid, p_capability text, p_enabled boolean, p_limit_count integer, p_limit_period text, p_note text, p_expected_version bigint, p_limit_unlimited boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_current public.business_capability_grants_v518%rowtype;
  v_version bigint;
  v_actor uuid := auth.uid();
  v_unlimited boolean := coalesce(p_limit_unlimited, false);
begin
  if not app.is_super_admin() then
    raise exception 'platform automation write access required' using errcode = '42501';
  end if;
  if not exists (select 1 from public.platform_capabilities_v518 where capability_key = p_capability) then
    raise exception 'unknown capability' using errcode = '22023';
  end if;
  if p_limit_count is not null and p_limit_count < 0 then
    raise exception 'limit_count must not be negative' using errcode = '22023';
  end if;
  if v_unlimited and p_limit_count is not null then
    raise exception 'a firm cannot be both uncapped and capped at a number' using errcode = '22023';
  end if;
  if p_limit_period is not null and p_limit_period not in ('day','week','month','year','ever') then
    raise exception 'unsupported limit period' using errcode = '22023';
  end if;

  select * into v_current from public.business_capability_grants_v518
   where business_id = p_business and capability_key = p_capability
   for update;

  if coalesce(p_expected_version, 0) <> coalesce(v_current.version, 0) then
    raise exception 'capability grant changed since it was read' using errcode = '40001';
  end if;

  insert into public.business_capability_grants_v518(
    business_id, capability_key, enabled, limit_count, limit_period, limit_unlimited,
    note, version, granted_by)
  values (p_business, p_capability, p_enabled, p_limit_count, p_limit_period, v_unlimited,
          p_note, 1, v_actor)
  on conflict (business_id, capability_key) do update
    set enabled = excluded.enabled,
        limit_count = excluded.limit_count,
        limit_period = excluded.limit_period,
        limit_unlimited = excluded.limit_unlimited,
        note = excluded.note,
        version = public.business_capability_grants_v518.version + 1,
        granted_by = v_actor,
        updated_at = now()
  returning version into v_version;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'capability_grant_set', 'business_capability_grants_v518', p_business,
    jsonb_build_object(
      'capability_key', p_capability, 'enabled', p_enabled,
      'limit_count', p_limit_count, 'limit_unlimited', v_unlimited,
      'limit_period', p_limit_period, 'version', v_version));

  return jsonb_build_object('status', 'ok', 'version', v_version)
      || app.capability_state_v518(p_business, p_capability, now());
end
$function$;
revoke all on function public.platform_set_capability_grant_v518(uuid, text, boolean, integer, text, text, bigint, boolean) from public, anon;
grant execute on function public.platform_set_capability_grant_v518(uuid, text, boolean, integer, text, text, bigint, boolean) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.platform_set_retention_hold_v574(p_business uuid, p_campaign uuid, p_held boolean, p_reason text, p_expected_version bigint DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_current public.platform_retention_holds_v574%rowtype;
  v_version bigint;
begin
  if not app.is_super_admin() then
    raise exception 'platform automation write access required' using errcode = '42501';
  end if;
  if p_held is null then
    raise exception 'hold state is required' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 3 then
    -- A hold without a stated reason is an outage nobody can explain later.
    raise exception 'a hold requires a reason' using errcode = '22023';
  end if;
  if not exists (select 1 from public.businesses where id = p_business) then
    raise exception 'unknown business' using errcode = '22023';
  end if;
  if p_campaign is not null
     and not exists (select 1 from public.bringback_campaigns_v361
                      where id = p_campaign and business_id = p_business) then
    raise exception 'campaign does not belong to this business' using errcode = '22023';
  end if;

  select * into v_current from public.platform_retention_holds_v574
   where business_id = p_business
     and campaign_id is not distinct from p_campaign
   for update;

  if coalesce(p_expected_version, 0) <> coalesce(v_current.version, 0) then
    raise exception 'retention hold changed since it was read' using errcode = '40001';
  end if;

  if v_current.id is null then
    insert into public.platform_retention_holds_v574(
      business_id, campaign_id, held, reason, version,
      placed_by, placed_at,
      released_by, released_at, updated_at)
    values (p_business, p_campaign, p_held, btrim(p_reason), 1,
      case when p_held then v_actor end, now(),
      case when p_held then null else v_actor end,
      case when p_held then null else now() end, now())
    returning version into v_version;
  else
    update public.platform_retention_holds_v574
       set held = p_held,
           reason = btrim(p_reason),
           version = version + 1,
           placed_by = case when p_held then v_actor else placed_by end,
           placed_at = case when p_held then now() else placed_at end,
           released_by = case when p_held then null else v_actor end,
           released_at = case when p_held then null else now() end,
           updated_at = now()
     where id = v_current.id
    returning version into v_version;
  end if;

  -- The actor is the PLATFORM ADMINISTRATOR. Nothing here pretends the tenant
  -- performed this, and the merchant's own bringback_campaigns_v361.active is
  -- not touched by any statement above.
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor,
    case when p_held then 'retention.platform_held' else 'retention.platform_released' end,
    'platform_retention_holds_v574', coalesce(p_campaign, p_business),
    jsonb_build_object(
      'scope', case when p_campaign is null then 'business' else 'campaign' end,
      'campaign_id', p_campaign, 'business_id', p_business,
      'reason', btrim(p_reason), 'version', v_version,
      'actor_kind', 'platform_administrator'));

  return jsonb_build_object('status','ok','held',p_held,'version',v_version,
    'scope', case when p_campaign is null then 'business' else 'campaign' end);
end
$function$;
revoke all on function public.platform_set_retention_hold_v574(uuid, uuid, boolean, text, bigint) from public, anon;
grant execute on function public.platform_set_retention_hold_v574(uuid, uuid, boolean, text, bigint) to authenticated, service_role;

commit;
