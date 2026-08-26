-- NESTLY v518a - "UNLIMITED FOR THIS FIRM" IS A STATE v518 COULD NOT EXPRESS
--
-- Found by v518's own acceptance suite, check 08, before any caller existed.
--
-- v518 documented every grant column as nullable-means-inherit, and the resolver
-- implements exactly that:
--     v_limit := coalesce(v_grant.limit_count, v_cap.default_limit_count);
-- So a NULL limit_count on the grant inherits the registry default. That is the
-- right meaning for "inherit" - and it leaves no way to say "this firm has NO
-- monthly cap" while the registry default is a number.
--
-- The owner's question was "how many times they able to use per month", and for
-- a flagship or pilot firm the correct answer is sometimes "as many as they
-- like". Under v518 the only way to express that was to set the registry default
-- to NULL, which would have made EVERY firm unlimited. That is a foot-gun sitting
-- one click away in a console that does not exist yet.
--
-- A nullable integer carries two states (inherit, a number). Three are needed.
-- This adds the missing bit explicitly rather than by sentinel: a limit_count of
-- -1 would have collided with the >= 0 CHECK and, worse, would have read as a
-- number to every future caller that did arithmetic on it.
--
-- Precedence, unchanged except for the new first clause:
--   1. grant.limit_unlimited  -> no cap at all
--   2. grant.limit_count      -> this firm's own number
--   3. registry default       -> the platform's number (NULL here = unlimited)
--
-- Additive and inert: the column defaults false, so every existing grant resolves
-- exactly as it did a moment ago. v518 landed minutes before this and has no
-- callers yet, so nothing in production changes behaviour.

begin;

alter table public.business_capability_grants_v518
  add column if not exists limit_unlimited boolean not null default false;

comment on column public.business_capability_grants_v518.limit_unlimited is
  'v518a: true means this firm has no cap, overriding both limit_count and the registry default. Distinct from limit_count IS NULL, which means inherit.';

-- A firm cannot be both uncapped and capped at a number; storing both is a
-- contradiction the console could otherwise write silently.
alter table public.business_capability_grants_v518
  drop constraint if exists business_capability_grants_v518_unlimited_shape_check;
alter table public.business_capability_grants_v518
  add constraint business_capability_grants_v518_unlimited_shape_check
  check (not (limit_unlimited and limit_count is not null));

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

  if v_cap.required_modules is not null and array_length(v_cap.required_modules, 1) is not null
     and not (v_cap.required_modules <@ coalesce(v_biz.enabled_modules, array[]::text[])) then
    return jsonb_build_object(
      'allowed', false, 'reason', 'module_not_enabled',
      'required_modules', to_jsonb(v_cap.required_modules));
  end if;

  select * into v_grant from public.business_capability_grants_v518
   where business_id = p_business and capability_key = p_capability;

  v_enabled := coalesce(v_grant.enabled, v_cap.default_enabled);
  -- v518a: an explicit per-firm "no cap" wins over both the firm's number and
  -- the platform default. NULL limit_count still means inherit, as documented.
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

-- The setter gains the flag. Signature CHANGES, so the old overload is dropped
-- rather than left behind: two overloads differing by one trailing argument is
-- how PostgREST starts returning PGRST203 and every save fails.
drop function if exists public.platform_set_capability_grant_v518(uuid, text, boolean, integer, text, text, bigint);

create or replace function public.platform_set_capability_grant_v518(
  p_business uuid,
  p_capability text,
  p_enabled boolean,
  p_limit_count integer,
  p_limit_period text,
  p_note text,
  p_expected_version bigint,
  p_limit_unlimited boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_current public.business_capability_grants_v518%rowtype;
  v_version bigint;
  v_actor uuid := auth.uid();
  v_unlimited boolean := coalesce(p_limit_unlimited, false);
begin
  if not app.v89_platform_can('automation', 'rw') then
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
$fn$;

revoke all on function public.platform_set_capability_grant_v518(uuid, text, boolean, integer, text, text, bigint, boolean)
  from public, anon, authenticated;
grant execute on function public.platform_set_capability_grant_v518(uuid, text, boolean, integer, text, text, bigint, boolean)
  to authenticated, service_role;

-- The console needs to render the flag it is about to write back.
create or replace function public.platform_get_capability_matrix_v518(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_rows jsonb;
begin
  if not app.v89_platform_can('automation', 'r') then
    raise exception 'platform automation read access required' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(entry order by entry->>'capability_key'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'capability_key', cap.capability_key,
      'title', cap.title,
      'description', cap.description,
      'active', cap.active,
      'eligible_industries', to_jsonb(cap.eligible_industries),
      'required_modules', to_jsonb(cap.required_modules),
      'default_enabled', cap.default_enabled,
      'default_limit_count', cap.default_limit_count,
      'default_limit_period', cap.default_limit_period,
      'version', coalesce(grant_row.version, 0),
      'grant_enabled', grant_row.enabled,
      'grant_limit_count', grant_row.limit_count,
      'grant_limit_unlimited', coalesce(grant_row.limit_unlimited, false),
      'grant_limit_period', grant_row.limit_period,
      'note', grant_row.note,
      'state', app.capability_state_v518(p_business, cap.capability_key, now())
    ) as entry
    from public.platform_capabilities_v518 cap
    left join public.business_capability_grants_v518 grant_row
      on grant_row.business_id = p_business and grant_row.capability_key = cap.capability_key
  ) rows;

  return jsonb_build_object('business_id', p_business, 'capabilities', v_rows);
end
$fn$;

revoke all on function public.platform_get_capability_matrix_v518(uuid)
  from public, anon, authenticated;
grant execute on function public.platform_get_capability_matrix_v518(uuid) to authenticated, service_role;

commit;
