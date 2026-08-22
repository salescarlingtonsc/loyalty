-- EXECUTED acceptance for nestly_v427, run end to end on a scratch PostgreSQL 17 instance.
--
-- WHY THIS FILE EXISTS SEPARATELY FROM db/tests/v427_entitlement_visibility.sql.
-- That suite is the production one: it runs against the live database as an owner, uses the real
-- firm's rows, and rolls back. This one is the suite that was actually EXECUTED while the
-- migration was being written, on a throwaway postgres, because the author held read-only access
-- to production. It is self-contained: it builds a minimal schema whose column shapes and check
-- constraints were copied from production (information_schema.columns / pg_constraint on
-- gadpooereceldfpfxsod), installs the four functions the migration ships plus the two verbatim
-- production redemption RPCs it must round-trip through, and asserts.
--
-- HOW TO RUN IT (one command, from the repo root):
--   D=/tmp/pg54427
--   LC_ALL=C initdb -D "$D" -U postgres --auth=trust
--   LC_ALL=C pg_ctl -D "$D" -o "-p 54427 -k /tmp" -l "$D/log" start
--   LC_ALL=C psql -h /tmp -p 54427 -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     -f db/tests/executed/v427_entitlements.sql
--
-- WHAT IT IS NOT. It is not a substitute for the production suite. The wallet context, the
-- redemption RPCs and the grant tables are the real bodies and the real shapes, but the
-- permission helpers (app.has_perm, app.can_see_branch, app.role_perms,
-- app.business_workspace_open_v94, app.platform_feature_enabled) are stand-ins, and RLS is not
-- modelled at all — every function under test is SECURITY DEFINER and bypasses it in production
-- too, but a scratch instance cannot prove that. Run the production suite before shipping.
--
-- FAIL rows are failures. The assertions live in one transaction that rolls back.

\set ON_ERROR_STOP on

-- ============================================================================================
-- PART A — the scratch schema (production column shapes, trimmed to what is read)
-- ============================================================================================
drop schema if exists app cascade;
drop schema if exists auth cascade;
drop schema if exists public cascade;
create schema public;
create schema app;
create schema auth;
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role; end if;
end $$;

create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claims', true)::jsonb->>'sub','')::uuid
$$;

create table public.businesses(
  id uuid primary key, slug text unique, name text, industry text, currency text,
  enabled_modules text[] not null default '{}');
create table public.branches(
  id uuid primary key default gen_random_uuid(), business_id uuid not null, name text,
  active boolean not null default true, timezone text not null default 'Asia/Singapore',
  is_default boolean not null default true, billing_state text not null default 'active',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table public.platform_module_overrides_v94(
  id uuid primary key default gen_random_uuid(), business_id uuid not null, branch_scope uuid,
  module_key text not null, mode text not null, version bigint not null default 1,
  reason text not null default '', updated_by uuid, updated_at timestamptz not null default now());
create table public.customer_identities(
  id uuid primary key default gen_random_uuid(), auth_user_id uuid not null, status text not null,
  created_via text not null default 'test', created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(), qr_token_version integer not null default 1);
create table public.customer_links(
  id uuid primary key default gen_random_uuid(), business_id uuid not null, identity_id uuid not null,
  auth_user_id uuid not null, client_id uuid not null, state text not null,
  verification_method text not null default 'test', verified_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table public.clients(id uuid primary key default gen_random_uuid(), business_id uuid not null, name text);
create table public.staff(
  id uuid primary key default gen_random_uuid(), business_id uuid not null, user_id uuid,
  name text, role text not null, active boolean not null default true,
  access_state text not null default 'approved', created_at timestamptz not null default now());
create table public.sales(
  id uuid primary key default gen_random_uuid(), business_id uuid not null, client_id uuid,
  kind text not null default 'retail', amount_cents integer not null default 0, note text,
  branch_id uuid, staff_id uuid, reversal_of uuid, created_at timestamptz not null default now());

-- Entitlement tables: shapes and check constraints copied from production.
create table public.welcome_offer_grants_v215(
  id uuid primary key default gen_random_uuid(), business_id uuid not null, client_id uuid not null,
  min_spend_cents integer not null, reward_catalog_kind text not null, reward_catalog_id uuid,
  reward_label text not null, status text not null default 'granted',
  granted_at timestamptz not null default now(), expires_at timestamptz,
  redeemed_at timestamptz, redeemed_sale_id uuid, redeemed_by uuid,
  qualifying_sale_id uuid, redeem_idempotency_key text,
  constraint welcome_offer_grants_v215_kind_check check (reward_catalog_kind = any(array['service','product','custom'])),
  constraint welcome_offer_grants_v215_min_spend_check check (min_spend_cents >= 0),
  constraint welcome_offer_grants_v215_status_check check (status = any(array['granted','redeemed','expired'])),
  constraint welcome_offer_grants_v215_redeem_shape check (
    ((status='redeemed') and (redeemed_at is not null) and (redeemed_sale_id is not null))
    or ((status<>'redeemed') and (redeemed_at is null) and (redeemed_sale_id is null))));
create unique index welcome_offer_grants_v215_client_uk on public.welcome_offer_grants_v215(business_id, client_id);

create table public.bringback_campaigns_v361(
  id uuid primary key default gen_random_uuid(), business_id uuid not null, name text not null,
  reward_label text not null, away_days integer not null, expiry_days integer,
  active boolean not null default true, created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(), updated_by uuid, deleted_at timestamptz);
create table public.bringback_grants_v361(
  id uuid primary key default gen_random_uuid(), business_id uuid not null, campaign_id uuid not null,
  client_id uuid not null, reward_label text not null, away_days integer not null,
  cycle_key date not null, status text not null default 'granted',
  granted_at timestamptz not null default now(), expires_at timestamptz,
  redeemed_at timestamptz, redeemed_sale_id uuid, redeemed_by uuid,
  constraint bringback_grants_v361_status_check check (status = any(array['granted','redeemed','expired'])),
  constraint bringback_grants_v361_redeem_shape check (
    ((status='redeemed') and (redeemed_at is not null) and (redeemed_sale_id is not null))
    or ((status<>'redeemed') and (redeemed_at is null) and (redeemed_sale_id is null))));
create unique index bringback_grants_v361_cycle_uk on public.bringback_grants_v361(campaign_id, client_id, cycle_key);

create table public.referral_grants_v420(
  id uuid primary key default gen_random_uuid(), business_id uuid not null, client_id uuid not null,
  referral_id uuid not null, reward_label text not null, status text not null default 'granted',
  granted_at timestamptz not null default now(), expires_at timestamptz,
  redeemed_at timestamptz, redeemed_sale_id uuid, redeemed_by uuid,
  beneficiary text not null default 'referrer',
  constraint referral_grants_v420_status_check check (status = any(array['granted','redeemed','expired'])),
  constraint referral_grants_v420_beneficiary_check check (beneficiary = any(array['referrer','friend'])));
create unique index referral_grants_v421_once_per_side on public.referral_grants_v420(referral_id, beneficiary);

create table public.loyalty_redemptions(
  id uuid primary key default gen_random_uuid(), business_id uuid not null, client_id uuid not null,
  reward_id uuid, reward_name text not null, points_spent integer not null default 0,
  credit_cents integer not null default 0, redeemed_at timestamptz not null default now(),
  actor uuid, config_version_id uuid, reward_version_id uuid, reward_snapshot jsonb,
  eligibility_snapshot jsonb, fulfillment_kind text, entitlement_expires_at timestamptz,
  usage_number integer, consumes_balance boolean not null default true);
create table public.loyalty_redemption_reversals(
  id uuid primary key default gen_random_uuid(), business_id uuid not null, redemption_id uuid not null,
  provenance_id uuid not null default gen_random_uuid(), client_id uuid not null,
  actor uuid not null default gen_random_uuid(), idempotency_key text not null default '',
  request_payload jsonb not null default '{}', request_hash text not null default '',
  restored_points_ledger_id uuid not null default gen_random_uuid(),
  reversed_credit_ledger_id uuid, result jsonb not null default '{}',
  created_at timestamptz not null default now());

create table public.business_programmes(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  kind text not null, active boolean not null default true, sort smallint not null default 0,
  created_at timestamptz not null default now());
create table public.points_ledger(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  client_id uuid not null, entry_type text not null, points integer not null default 0, sale_id uuid,
  reference text, created_at timestamptz not null default now(), actor uuid, config_version_id uuid,
  programme_id uuid not null);
create table public.loyalty_programs(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  kind text not null default 'points', loyalty_model text not null default 'points',
  active boolean not null default true);
create table public.loyalty_rewards(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  name text not null, cost_points integer not null default 0, active boolean not null default true,
  created_at timestamptz not null default now(), customer_name text not null default '',
  programme_id uuid not null default gen_random_uuid());
create table public.retention_programs(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  name text not null, goal_visits integer not null default 1, period_days integer not null default 30,
  reward_type text not null default 'credit', reward_value numeric not null default 0,
  starts_on date not null default current_date, active boolean not null default true,
  created_at timestamptz not null default now(), reward_taxonomy_id uuid not null default gen_random_uuid(),
  deleted_at timestamptz);
create table public.reward_grants(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  program_id uuid not null, client_id uuid not null, period_index integer not null default 1,
  reward_type text not null default 'credit', reward_value numeric not null default 0,
  status text not null default 'granted', granted_at timestamptz not null default now(),
  reward_taxonomy_id uuid not null default gen_random_uuid(), reward_label text not null default '',
  fulfillment_kind text not null default 'manual_item',
  retention_program_version_id uuid not null default gen_random_uuid(),
  period_start timestamptz not null default now(), period_end timestamptz not null default now());
create table public.birthday_programs(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  created_at timestamptz not null default now());
create table public.customer_birthday_redemptions(id uuid primary key default gen_random_uuid(),
  entitlement_id uuid not null default gen_random_uuid(), business_id uuid not null, client_id uuid not null,
  branch_id uuid not null default gen_random_uuid(), actor uuid not null default gen_random_uuid(),
  operation_kind text not null default 'redeem', idempotency_key uuid not null default gen_random_uuid(),
  request_hash text not null default '', active boolean not null default true,
  created_at timestamptz not null default now());
create table public.business_welcome_offers_v215(business_id uuid primary key, active boolean not null default false,
  min_spend_cents integer not null default 0, reward_catalog_kind text not null, reward_catalog_id uuid,
  reward_label text not null, expiry_days integer, version integer not null default 1, updated_by uuid,
  updated_at timestamptz not null default now(), custom_label text);
create table public.referral_programs(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  enabled boolean not null default false, reward_cents integer not null default 1000,
  created_at timestamptz not null default now(), reward_kind text not null default 'points');
create table public.referrals(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  referrer_client_id uuid not null, referred_client_id uuid, status text not null default 'pending',
  reward_cents integer not null default 0, qualified_at timestamptz,
  created_at timestamptz not null default now(), reward_points integer not null default 0);
create table public.membership_plans(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  name text not null, price_cents integer not null default 0, active boolean not null default true,
  created_at timestamptz not null default now(), deleted_at timestamptz);
create table public.memberships(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  client_id uuid not null, plan_id uuid not null, status text not null default 'active',
  started_at timestamptz not null default now(), created_at timestamptz not null default now());
create table public.services(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  name text not null, active boolean not null default true);
create table public.products(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  name text not null, active boolean not null default true);
create table public.audit_log(id uuid primary key default gen_random_uuid(), business_id uuid,
  actor uuid, action text, entity text, entity_id uuid, detail jsonb,
  created_at timestamptz not null default now());

-- ---- permission helpers: stand-ins, but driven off the SAME staff table production reads -----
create or replace function app.platform_feature_enabled(p_key text) returns boolean
  language sql stable as $$ select true $$;
create or replace function app.business_workspace_open_v94(p_business uuid) returns boolean
  language sql stable as $$ select true $$;
create or replace function app.is_super_admin() returns boolean language sql stable as $$ select false $$;
create or replace function app.is_salon_owner(p_salon uuid) returns boolean
  language sql stable security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select app.business_workspace_open_v94(p_salon) and exists(
    select 1 from public.staff staff_row
     where staff_row.business_id=p_salon and staff_row.user_id=auth.uid() and staff_row.active
       and staff_row.access_state='approved' and staff_row.role='owner') $$;
create or replace function app.can_module_read(p_business uuid, p_module text) returns boolean
  language sql stable security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select exists(select 1 from public.staff s where s.business_id=p_business and s.user_id=auth.uid()
                 and s.active and s.access_state='approved' and s.role in ('owner','manager')) $$;
create or replace function app.can_module_write(p_business uuid, p_module text) returns boolean
  language sql stable security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select exists(select 1 from public.staff s where s.business_id=p_business and s.user_id=auth.uid()
                 and s.active and s.access_state='approved' and s.role in ('owner','manager')) $$;
create or replace function app.has_perm(p_business uuid, p_perm text) returns boolean
  language sql stable security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select exists(select 1 from public.staff s where s.business_id=p_business and s.user_id=auth.uid()
                 and s.active and s.access_state='approved' and s.role in ('owner','manager')) $$;
create or replace function app.role_perms(p_role text) returns text[]
  language sql immutable as $$ select array['create_sales']::text[] $$;
create or replace function app.can_see_branch(p_business uuid, p_branch uuid) returns boolean
  language sql stable as $$ select true $$;

-- ---- app.v32_customer_wallet_context: the REAL body, copied from production ------------------
CREATE OR REPLACE FUNCTION app.v32_customer_wallet_context(p_business_slug text DEFAULT NULL::text)
 RETURNS TABLE(identity_id uuid, business_id uuid, client_id uuid, business_name text, business_slug text, business_industry text, business_currency text, enabled_modules text[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();
  v_slug text:=nullif(lower(btrim(coalesce(p_business_slug,''))),'');
begin
  if v_actor is null then
    raise exception 'authenticated customer session required'
      using errcode='28000';
  end if;
  if not app.platform_feature_enabled('customer_wallet') then
    raise exception 'customer wallet is not enabled' using errcode='0A000';
  end if;
  perform 1
  from public.customer_identities identity
  where identity.auth_user_id=v_actor and identity.status='active';
  if not found then
    raise exception 'active customer identity required' using errcode='42501';
  end if;

  return query
  select identity.id,link.business_id,link.client_id,
    business.name,business.slug,business.industry,business.currency,
    coalesce((
      select array_agg(key.module_key order by key.module_key)
      from (
        select unnest(coalesce(business.enabled_modules,'{}'::text[])) module_key
        union
        select override_row.module_key
        from public.platform_module_overrides_v94 override_row
        where override_row.business_id=business.id
      ) key
      where app.business_workspace_open_v94(business.id)
        and exists(
          select 1
          from (
            select branch.id as branch_id
            from public.branches branch
            where branch.business_id=business.id and branch.active
            union all
            select null::uuid
            where not exists(
              select 1 from public.branches branch
              where branch.business_id=business.id and branch.active
            )
          ) scope
          where (case when key.module_key='customerintel' then 'disabled'
            else coalesce(
              (select override_row.mode
                 from public.platform_module_overrides_v94 override_row
                where override_row.business_id=business.id
                  and override_row.branch_scope=scope.branch_id
                  and override_row.module_key=key.module_key
                  and override_row.mode<>'inherit'),
              (select override_row.mode
                 from public.platform_module_overrides_v94 override_row
                where override_row.business_id=business.id
                  and override_row.branch_scope is null
                  and override_row.module_key=key.module_key
                  and override_row.mode<>'inherit'),
              (select case when key.module_key=any(inner_business.enabled_modules)
                        then 'rw' else 'disabled' end
                 from public.businesses inner_business
                where inner_business.id=business.id)
            ) end) in ('r','rw')
        )
    ),'{}'::text[])
  from public.customer_identities identity
  join public.customer_links link
    on link.identity_id=identity.id
   and link.auth_user_id=v_actor
   and link.state='verified'
  join public.businesses business on business.id=link.business_id
  where identity.auth_user_id=v_actor
    and identity.status='active'
    and (v_slug is null or business.slug=v_slug)
  order by business.slug,link.id;
end
$function$;

-- ---- the two redemption RPCs, verbatim from production (pg_get_functiondef, 2026-08-22) ------
-- They are the authority on canonical entitlement state, so the round trip must go through them
-- and not through a hand-written UPDATE that could quietly disagree with the real thing.
CREATE OR REPLACE FUNCTION public.staff_redeem_welcome_offer_v215(p_business uuid, p_client uuid, p_branch uuid, p_qualifying_sale uuid, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_grant public.welcome_offer_grants_v215%rowtype;
  v_sale_id uuid := gen_random_uuid();
  v_spend bigint := 0;
  v_result jsonb;
begin
  p_idempotency_key := btrim(p_idempotency_key);
  if v_actor is null or p_idempotency_key is null or length(p_idempotency_key) < 8 then
    raise exception 'authenticated staff and valid idempotency key required' using errcode='22023';
  end if;
  if not app.has_perm(p_business,'create_sales')
     or not (app.can_module_write(p_business,'till')
             or app.can_module_write(p_business,'sales')) then
    raise exception 'welcome offer redemption authorization required' using errcode='42501';
  end if;

  select staff_row.id into v_staff
  from public.staff staff_row
  where staff_row.business_id = p_business
    and staff_row.user_id = v_actor
    and staff_row.active
    and 'create_sales' = any(app.role_perms(staff_row.role))
  order by case staff_row.role when 'owner' then 0 when 'manager' then 1 else 2 end,
           staff_row.created_at, staff_row.id
  limit 1;
  if v_staff is null then
    raise exception 'active staff authorization required' using errcode='42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'v215:welcome-offer:'||p_business::text||':'||p_idempotency_key, 0));

  select * into v_grant
  from public.welcome_offer_grants_v215
  where business_id = p_business and client_id = p_client
  for update;
  if not found then
    raise exception 'welcome_offer_not_found' using errcode='22023';
  end if;

  if v_grant.status = 'redeemed' then
    if v_grant.redeem_idempotency_key is not distinct from p_idempotency_key then
      return jsonb_build_object('status','completed','replayed',true,
        'grant_id',v_grant.id,'sale_id',v_grant.redeemed_sale_id,
        'reward_label',v_grant.reward_label);
    end if;
    raise exception 'welcome_offer_already_redeemed' using errcode='22023';
  end if;
  if v_grant.status <> 'granted' then
    raise exception 'welcome_offer_not_redeemable' using errcode='22023';
  end if;
  if v_grant.expires_at is not null and v_grant.expires_at <= now() then
    update public.welcome_offer_grants_v215 set status='expired' where id = v_grant.id;
    raise exception 'welcome_offer_expired' using errcode='22023';
  end if;

  perform 1 from public.branches branch
  where branch.id = p_branch and branch.business_id = p_business and branch.active
    and app.can_see_branch(p_business, branch.id);
  if not found then
    raise exception 'welcome_offer_branch_not_permitted' using errcode='42501';
  end if;

  if v_grant.min_spend_cents > 0 then
    if p_qualifying_sale is null then
      raise exception 'welcome_offer_requires_qualifying_sale' using errcode='22023';
    end if;
    select sale.amount_cents into v_spend
    from public.sales sale
    where sale.id = p_qualifying_sale
      and sale.business_id = p_business
      and sale.client_id = p_client
      and sale.reversal_of is null
      and not exists(select 1 from public.sales reversal
                     where reversal.reversal_of = sale.id)
    for share;
    if v_spend is null then
      raise exception 'welcome_offer_qualifying_sale_not_found' using errcode='22023';
    end if;
    if v_spend < v_grant.min_spend_cents then
      raise exception 'welcome_offer_min_spend_not_met' using errcode='22023';
    end if;
  end if;

  insert into public.sales(id, business_id, client_id, kind, amount_cents, note, branch_id, staff_id)
  values (v_sale_id, p_business, p_client,
          case when v_grant.reward_catalog_kind = 'service' then 'service' else 'retail' end,
          0, 'welcome offer redeemed: '||v_grant.reward_label, p_branch, v_staff);

  update public.welcome_offer_grants_v215
  set status='redeemed', redeemed_at=now(), redeemed_sale_id=v_sale_id,
      redeemed_by=v_actor, qualifying_sale_id=p_qualifying_sale,
      redeem_idempotency_key=p_idempotency_key
  where id = v_grant.id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'WELCOME_OFFER_REDEEMED_V215',
          'welcome_offer_grants_v215', v_grant.id, jsonb_build_object(
    'grant_id', v_grant.id, 'client_id', p_client, 'branch_id', p_branch,
    'sale_id', v_sale_id, 'reward_label', v_grant.reward_label,
    'min_spend_cents', v_grant.min_spend_cents,
    'qualifying_sale_id', p_qualifying_sale, 'qualifying_amount_cents', v_spend));

  v_result := jsonb_build_object('status','completed','replayed',false,
    'grant_id',v_grant.id,'sale_id',v_sale_id,'reward_label',v_grant.reward_label,
    'reward_catalog_kind',v_grant.reward_catalog_kind);
  return v_result;
end
$function$;

CREATE OR REPLACE FUNCTION public.staff_redeem_bringback_v361(p_business uuid, p_client uuid, p_branch uuid, p_grant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_grant public.bringback_grants_v361%rowtype;
  v_sale_id uuid := gen_random_uuid();
begin
  if v_actor is null then raise exception 'authenticated staff required' using errcode='42501'; end if;
  if not (app.is_salon_owner(p_business) or app.can_module_write(p_business,'till')
          or app.can_module_write(p_business,'loyalty')) then
    raise exception 'bringback redemption authorization required' using errcode='42501';
  end if;

  select * into v_grant from public.bringback_grants_v361
   where id=p_grant and business_id=p_business and client_id=p_client for update;
  if not found then raise exception 'bringback_grant_not_found' using errcode='22023'; end if;
  if v_grant.status='redeemed' then raise exception 'bringback_already_redeemed' using errcode='22023'; end if;
  if v_grant.status<>'granted' then raise exception 'bringback_not_redeemable' using errcode='22023'; end if;
  if v_grant.expires_at is not null and v_grant.expires_at<=now() then
    update public.bringback_grants_v361 set status='expired' where id=v_grant.id;
    raise exception 'bringback_expired' using errcode='22023';
  end if;

  perform 1 from public.branches branch
   where branch.id=p_branch and branch.business_id=p_business and branch.active
     and app.can_see_branch(p_business, branch.id);
  if not found then raise exception 'bringback_branch_not_permitted' using errcode='42501'; end if;

  insert into public.sales(id,business_id,client_id,kind,amount_cents,note,branch_id)
  values (v_sale_id,p_business,p_client,'retail',0,'bring-back voucher redeemed: '||v_grant.reward_label,p_branch);

  update public.bringback_grants_v361
     set status='redeemed', redeemed_at=now(), redeemed_sale_id=v_sale_id, redeemed_by=v_actor
   where id=v_grant.id;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,v_actor,'BRINGBACK_REDEEMED_V361','bringback_grants_v361',v_grant.id,
    jsonb_build_object('client_id',p_client,'branch_id',p_branch,'sale_id',v_sale_id,
                       'reward_label',v_grant.reward_label));

  return jsonb_build_object('status','completed','grant_id',v_grant.id,'sale_id',v_sale_id,
    'reward_label',v_grant.reward_label);
end $function$;

grant usage on schema public, app, auth to authenticated, anon, service_role;
grant select, insert, update, delete on all tables in schema public to authenticated, anon, service_role;
grant execute on all functions in schema app to authenticated, anon, service_role;
grant execute on function auth.uid() to authenticated, anon, service_role;

-- ============================================================================================
-- PART B — the migration under test
-- ============================================================================================
\ir ../../migrations/20260822_nestly_v427_entitlements_reach_customers.sql

grant select, insert, update, delete on all tables in schema public to authenticated, anon, service_role;

-- ============================================================================================
-- PART C — the assertions
-- ============================================================================================
begin;

create temp table _r(k text, v text) on commit drop;
grant insert, select on _r to authenticated, anon;

do $$
declare
  v_biz uuid := '11111111-1111-4111-8111-111111111111';
  v_slug text := 'v427-fixture-firm';
  v_branch uuid := '22222222-2222-4222-8222-222222222222';
  v_owner_user uuid := '33333333-3333-4333-8333-333333333333';
  v_manager_user uuid := '44444444-4444-4444-8444-444444444444';
  v_client_a uuid := '55555555-5555-4555-8555-555555555555';
  v_auth_a   uuid := '66666666-6666-4666-8666-666666666666';
  v_client_b uuid := '77777777-7777-4777-8777-777777777777';
  v_auth_b   uuid := '88888888-8888-4888-8888-888888888888';
  v_campaign uuid;
  v_legacy_program uuid;
  v_referral uuid;
  v_welcome_grant uuid; v_bringback_grant uuid; v_referral_grant uuid; v_lapsed_grant uuid;
  v_reward_redemption uuid;
  v_payload jsonb; v_history jsonb; v_usage jsonb; v_row jsonb;
  v_acl text; v_msg text; v_code text; v_count integer;
begin
  -- ---- fixtures --------------------------------------------------------------------------
  insert into public.businesses(id, slug, name, industry, currency, enabled_modules)
    values (v_biz, v_slug, 'V427 Fixture Firm', 'fnb', 'SGD', array['loyalty','till','sales']);
  insert into public.branches(id, business_id, name) values (v_branch, v_biz, 'Main');
  insert into public.staff(business_id, user_id, name, role) values (v_biz, v_owner_user, 'Owner', 'owner');
  insert into public.clients(id, business_id, name) values (v_client_a, v_biz, 'Customer A'), (v_client_b, v_biz, 'Customer B');
  insert into public.customer_identities(id, auth_user_id, status)
    values ('99999999-9999-4999-8999-999999999991', v_auth_a, 'active'),
           ('99999999-9999-4999-8999-999999999992', v_auth_b, 'active');
  insert into public.customer_links(business_id, identity_id, auth_user_id, client_id, state, verified_at)
    values (v_biz, '99999999-9999-4999-8999-999999999991', v_auth_a, v_client_a, 'verified', now()),
           (v_biz, '99999999-9999-4999-8999-999999999992', v_auth_b, v_client_b, 'verified', now());

  insert into public.bringback_campaigns_v361(business_id, name, reward_label, away_days, expiry_days)
    values (v_biz, 'We Miss You', 'V427 free coffee', 60, 30) returning id into v_campaign;
  insert into public.retention_programs(business_id, name) values (v_biz, 'Legacy frequency rule')
    returning id into v_legacy_program;
  -- one legacy grant, so the audit row keeps a non-zero figure
  insert into public.reward_grants(business_id, program_id, client_id) values (v_biz, v_legacy_program, v_client_b);

  insert into public.welcome_offer_grants_v215(
      business_id, client_id, min_spend_cents, reward_catalog_kind, reward_label, expires_at)
    values (v_biz, v_client_a, 0, 'custom', 'V427 welcome pastry', now() + interval '30 days')
    returning id into v_welcome_grant;
  insert into public.bringback_grants_v361(
      business_id, campaign_id, client_id, reward_label, away_days, cycle_key, expires_at)
    values (v_biz, v_campaign, v_client_a, 'V427 free coffee', 60, (now() - interval '61 days')::date,
            now() + interval '30 days')
    returning id into v_bringback_grant;
  insert into public.referrals(business_id, referrer_client_id, referred_client_id, status, qualified_at)
    values (v_biz, v_client_a, v_client_b, 'qualified', now()) returning id into v_referral;
  insert into public.referral_grants_v420(business_id, client_id, referral_id, reward_label, beneficiary, expires_at)
    values (v_biz, v_client_a, v_referral, 'V427 referral treat', 'referrer', now() + interval '30 days')
    returning id into v_referral_grant;
  -- lapsed, but stored status is still 'granted' — the shape the tables really hold
  insert into public.referral_grants_v420(business_id, client_id, referral_id, reward_label, beneficiary, expires_at)
    values (v_biz, v_client_a, v_referral, 'V427 lapsed treat', 'friend', now() - interval '1 day')
    returning id into v_lapsed_grant;
  -- a pre-existing points redemption, so the v422 extension can be shown to be ADDITIVE
  insert into public.loyalty_redemptions(business_id, client_id, reward_name, points_spent,
      consumes_balance, fulfillment_kind, redeemed_at, reward_snapshot)
    values (v_biz, v_client_a, 'V427 points gift', 120, true, 'manual_item', now() - interval '2 days',
            jsonb_build_object('image_ref','gift/photo.png'))
    returning id into v_reward_redemption;

  -- ---- 01 ACL ------------------------------------------------------------------------------
  select coalesce(array_to_string(proacl, ' '), '') into v_acl
    from pg_proc where oid = 'public.customer_get_entitlements_v427(text)'::regprocedure;
  insert into _r values('01_acl_no_anon',
    case when v_acl not like '%anon=X%' and v_acl like '%authenticated=X%'
         then 'PASS authenticated may execute it; anon may not'
         else 'FAIL unexpected ACL: ' || v_acl end);

  -- ---- 02/04/05 the customer's own view ----------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_auth_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_payload := public.customer_get_entitlements_v427(v_slug);

  insert into _r values('02_contract',
    case when v_payload->>'contract' = 'v427' and (v_payload->>'business_id')::uuid = v_biz
          and (v_payload->>'active_count')::int = jsonb_array_length(v_payload->'active')
         then 'PASS' else 'FAIL ' || coalesce(v_payload::text,'null') end);
  select count(*)::int into v_count from jsonb_array_elements(v_payload->'active') item
   where (item->>'id')::uuid in (v_welcome_grant, v_bringback_grant, v_referral_grant);
  insert into _r values('02_three_active',
    case when v_count = 3 and jsonb_array_length(v_payload->'active') = 3
         then 'PASS all three earned entitlements are visible, and nothing else'
         else 'FAIL saw ' || v_count || ' of 3 (active length '
              || jsonb_array_length(v_payload->'active') || ')' end);

  select item into v_row from jsonb_array_elements(v_payload->'active') item
   where (item->>'id')::uuid = v_welcome_grant;
  insert into _r values('02_welcome_shape',
    case when v_row->>'source'='welcome' and v_row->>'label'='V427 welcome pastry'
          and v_row->>'status'='active' and v_row->>'granted_at' is not null
          and v_row->>'expires_at' is not null and v_row->>'instructions' is not null
          and (v_row->>'min_spend_cents')::int = 0
         then 'PASS' else 'FAIL ' || coalesce(v_row::text,'missing') end);
  select item into v_row from jsonb_array_elements(v_payload->'active') item
   where (item->>'id')::uuid = v_bringback_grant;
  insert into _r values('04_bringback_shape',
    case when v_row->>'source'='bringback' and (v_row->>'away_days')::int=60
         then 'PASS' else 'FAIL ' || coalesce(v_row::text,'missing') end);
  select item into v_row from jsonb_array_elements(v_payload->'active') item
   where (item->>'id')::uuid = v_referral_grant;
  insert into _r values('04_referral_shape',
    case when v_row->>'source'='referral' and v_row->>'beneficiary'='referrer'
         then 'PASS' else 'FAIL ' || coalesce(v_row::text,'missing') end);

  select count(*)::int into v_count from jsonb_array_elements(v_payload->'active') item
   where (item->>'id')::uuid = v_lapsed_grant;
  insert into _r values('05_lapsed_not_active',
    case when v_count=0 then 'PASS a lapsed grant is not offered'
         else 'FAIL an expired entitlement was offered as claimable' end);
  select item into v_row from jsonb_array_elements(v_payload->'history') item
   where (item->>'id')::uuid = v_lapsed_grant;
  insert into _r values('05_lapsed_in_history',
    case when v_row->>'status'='expired' then 'PASS it is reported as expired'
         else 'FAIL ' || coalesce(v_row::text,'missing') end);

  -- ---- 03 isolation ------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_auth_b, 'role', 'authenticated')::text, true);
  v_payload := public.customer_get_entitlements_v427(v_slug);
  select count(*)::int into v_count
    from jsonb_array_elements((v_payload->'active') || (v_payload->'history')) item;
  insert into _r values('03_isolation',
    case when v_count=0 then 'PASS customer B sees none of customer A''s entitlements'
         else 'FAIL customer B saw ' || v_count || ' entitlement(s)' end);

  -- ---- 08/09 refusals ----------------------------------------------------------------------
  begin
    perform public.customer_get_entitlements_v427('a-slug-with-no-link');
    insert into _r values('08_unlinked_refused', 'FAIL an unlinked business returned a payload');
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    insert into _r values('08_unlinked_refused',
      case when v_code='42501' then 'PASS refused 42501' else 'FAIL ' || v_code end);
  end;
  reset role;
  perform set_config('request.jwt.claims', null, true);
  set local role anon;
  begin
    perform public.customer_get_entitlements_v427(v_slug);
    insert into _r values('09_anon_refused', 'FAIL anon executed it');
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    insert into _r values('09_anon_refused',
      case when v_code in ('42501','28000','42883') then 'PASS refused ' || v_code
           else 'FAIL ' || v_code end);
  end;
  reset role;

  -- ---- 06/07 redemption round trip ---------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.staff_redeem_welcome_offer_v215(v_biz, v_client_a, v_branch, null, 'v427-welcome-idem');
  perform public.staff_redeem_bringback_v361(v_biz, v_client_a, v_branch, v_bringback_grant);
  reset role;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_auth_a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_payload := public.customer_get_entitlements_v427(v_slug);
  v_history := public.customer_get_reward_history_v422(v_slug, 100);

  select count(*)::int into v_count from jsonb_array_elements(v_payload->'active') item
   where (item->>'id')::uuid in (v_welcome_grant, v_bringback_grant);
  insert into _r values('06_left_active',
    case when v_count=0 then 'PASS redeemed entitlements are no longer claimable'
         else 'FAIL ' || v_count || ' redeemed entitlement(s) still offered' end);
  select count(*)::int into v_count from jsonb_array_elements(v_payload->'history') item
   where (item->>'id')::uuid in (v_welcome_grant, v_bringback_grant)
     and item->>'status'='redeemed' and item->>'redeemed_at' is not null;
  insert into _r values('06_in_v427_history',
    case when v_count=2 then 'PASS both appear in v427 history as redeemed'
         else 'FAIL only ' || v_count || ' of 2 in v427 history' end);
  select count(*)::int into v_count from jsonb_array_elements(v_history->'items') item
   where (item->>'id')::uuid in (v_welcome_grant, v_bringback_grant);
  insert into _r values('07_in_v422_history',
    case when v_count=2 then 'PASS both appear in the customer''s Rewards -> History list'
         else 'FAIL only ' || v_count || ' of 2 in v422 history' end);
  select item into v_row from jsonb_array_elements(v_history->'items') item
   where (item->>'id')::uuid = v_welcome_grant;
  insert into _r values('07_v422_row_shape',
    case when v_row->>'source'='welcome' and v_row->>'reward_name'='V427 welcome pastry'
          and (v_row->>'consumes_balance')::boolean = false and (v_row->>'points_spent')::int = 0
          and v_row->>'sale_id' is not null and v_row ? 'image_ref' and v_row ? 'fulfillment_kind'
         then 'PASS' else 'FAIL ' || coalesce(v_row::text,'missing') end);

  -- ADDITIVE: the pre-existing points redemption is unchanged apart from the new `source` key.
  select item into v_row from jsonb_array_elements(v_history->'items') item
   where (item->>'id')::uuid = v_reward_redemption;
  insert into _r values('07_v422_additive',
    case when v_row->>'source'='reward' and v_row->>'reward_name'='V427 points gift'
          and (v_row->>'points_spent')::int=120 and (v_row->>'consumes_balance')::boolean=true
          and v_row->>'fulfillment_kind'='manual_item' and v_row->>'image_ref'='gift/photo.png'
         then 'PASS the existing rows are untouched' else 'FAIL ' || coalesce(v_row::text,'missing') end);
  -- and the merged list is newest-first across BOTH kinds
  insert into _r values('07_v422_merged_order',
    case when (v_history->'items'->0->>'id')::uuid in (v_welcome_grant, v_bringback_grant)
          and (v_history->'items'->2->>'id')::uuid = v_reward_redemption
         then 'PASS newest first across both row kinds'
         else 'FAIL order was ' || (v_history->'items')::text end);

  -- an EXPIRED grant must not be listed as claimed
  select count(*)::int into v_count from jsonb_array_elements(v_history->'items') item
   where (item->>'id')::uuid = v_lapsed_grant;
  insert into _r values('07_expired_not_claimed',
    case when v_count=0 then 'PASS an expired grant is not in the claimed list'
         else 'FAIL an expired grant was reported as claimed' end);
  reset role;

  -- ---- 10 owner-only welcome writer --------------------------------------------------------
  insert into public.staff(business_id, user_id, name, role) values (v_biz, v_manager_user, 'Manager', 'manager');
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_manager_user, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into _r values('10_manager_has_module_write',
    case when app.can_module_write(v_biz,'loyalty')
         then 'PASS the fixture manager really does hold loyalty write'
         else 'FAIL the fixture manager has no loyalty write, so the refusal proves nothing' end);
  begin
    perform public.business_set_welcome_offer_v215(v_biz, true, 0, 'custom', null, null, 'V427 manager attempt');
    insert into _r values('10_manager_refused', 'FAIL a manager configured the welcome offer');
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    insert into _r values('10_manager_refused',
      case when v_code='42501' then 'PASS refused 42501' else 'FAIL ' || v_code end);
  end;
  reset role;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    v_row := public.business_set_welcome_offer_v215(v_biz, true, 0, 'custom', null, null, 'V427 owner attempt');
    insert into _r values('10_owner_accepted',
      case when v_row->>'status'='ok' and v_row->>'reward_label'='V427 owner attempt'
           then 'PASS the owner may still configure it' else 'FAIL ' || v_row::text end);
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate, v_msg = message_text;
    insert into _r values('10_owner_accepted', 'FAIL owner refused ' || v_code || ' ' || v_msg);
  end;

  -- ---- 11/12 the business-side bring-back figure --------------------------------------------
  v_usage := public.business_programme_usage_v271(v_biz);
  select item into v_row from jsonb_array_elements(v_usage->'retention') item
   where (item->>'program_id')::uuid = v_campaign;
  insert into _r values('11_campaign_listed',
    case when v_row is not null and v_row->>'source'='bringback_v361'
         then 'PASS the v361 campaign is in the retention array'
         else 'FAIL the canonical bring-back campaign is not counted' end);
  insert into _r values('11_counts_redeemed',
    case when (v_row->>'customers')::int=1 then 'PASS one customer redeemed a bring-back voucher'
         else 'FAIL expected 1, got ' || coalesce(v_row->>'customers','null') end);
  select count(*)::int into v_count from jsonb_array_elements(v_usage->'bringback') item
   where (item->>'program_id')::uuid = v_campaign;
  insert into _r values('11_bringback_alias',
    case when v_count=1 then 'PASS the bringback alias carries the same row'
         else 'FAIL the bringback key does not name the campaign' end);
  select item into v_row from jsonb_array_elements(v_usage->'retention') item
   where (item->>'program_id')::uuid = v_legacy_program;
  insert into _r values('11_legacy_kept',
    case when v_row->>'source'='retention_legacy' and (v_row->>'customers')::int=1
         then 'PASS the legacy engine''s audit figure survives unchanged'
         else 'FAIL ' || coalesce(v_row::text,'missing') end);

  -- a granted-but-not-redeemed bring-back must NOT count as used
  insert into public.bringback_grants_v361(
      business_id, campaign_id, client_id, reward_label, away_days, cycle_key)
    values (v_biz, v_campaign, v_client_b, 'V427 free coffee', 60, (now() - interval '90 days')::date);
  v_usage := public.business_programme_usage_v271(v_biz);
  select item into v_row from jsonb_array_elements(v_usage->'retention') item
   where (item->>'program_id')::uuid = v_campaign;
  insert into _r values('11_granted_is_not_used',
    case when (v_row->>'customers')::int=1
         then 'PASS an un-redeemed grant does not count as a customer who used it'
         else 'FAIL got ' || coalesce(v_row->>'customers','null') || ', expected 1' end);

  insert into _r values('12_unbounded_equals_v271',
    case when ((public.business_programme_usage_v386(v_biz) - 'as_of' - 'window')
             = (public.business_programme_usage_v271(v_biz) - 'as_of'))
         then 'PASS' else 'FAIL the windowless read drifted from v271' end);
  select item into v_row from jsonb_array_elements(
      public.business_programme_usage_v386(v_biz,'2020-01-01'::date,'2020-01-02'::date)->'retention') item
   where (item->>'program_id')::uuid = v_campaign;
  insert into _r values('12_window_excludes',
    case when (v_row->>'customers')::int=0 then 'PASS an old window reports 0 for the campaign'
         else 'FAIL got ' || coalesce(v_row->>'customers','null') end);
  reset role;
exception when others then
  reset role;
  get stacked diagnostics v_code = returned_sqlstate, v_msg = message_text;
  insert into _r values('99_suite_aborted', 'FAIL ' || v_code || ' ' || v_msg);
end $$;

select k, v from _r order by k;

rollback;
