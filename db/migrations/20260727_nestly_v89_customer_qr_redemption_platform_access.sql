-- NESTLY v89 — QR-only customer enrolment, merchant-confirmed redemption,
-- customer capability gates, canonical relationship readers, and scoped
-- platform operator access.
--
-- Additive local review candidate. Do not apply outside an accepted release.

begin;

insert into app.platform_feature_flags(feature_key,enabled)
values
  ('customer_qr_join',true),
  ('customer_qr_redemption',true)
on conflict(feature_key) do update set enabled=excluded.enabled;

-- A customer relationship may now be established by an authenticated customer
-- presenting a merchant-issued opaque QR token. Slug/name/global contact scans
-- are no longer relationship authority.
alter table public.customer_links
  drop constraint customer_links_verification_method_check,
  add constraint customer_links_verification_method_check
  check(verification_method in ('email_claim','firm_invitation','phone_claim','qr_join'));

alter table public.customer_link_claim_attempts
  drop constraint customer_link_claim_attempts_operation_check,
  add constraint customer_link_claim_attempts_operation_check
  check(operation in (
    'email_claim','invitation_claim','phone_claim','relationship_sync','qr_join'
  ));

alter table public.customer_link_audit_events
  drop constraint customer_link_audit_events_event_type_check,
  add constraint customer_link_audit_events_event_type_check
  check(event_type in (
    'email_claim_linked','email_claim_not_linked','email_claim_rate_limited',
    'phone_claim_linked','phone_claim_not_linked','phone_claim_rate_limited',
    'invitation_issued','invitation_claim_linked','invitation_claim_not_linked',
    'invitation_claim_rate_limited','link_unlinked','relationship_sync_linked',
    'qr_join_linked','qr_join_replayed','qr_join_not_linked'
  ));

create table public.business_customer_capabilities_v89(
  business_id uuid primary key references public.businesses(id) on delete cascade,
  booking_enabled boolean not null default false,
  redemption_enabled boolean not null default false,
  appointment_changes_enabled boolean not null default false,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table public.business_customer_join_qr_v89(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  token_hash text not null unique check(token_hash~'^[0-9a-f]{64}$'),
  status text not null default 'active' check(status in ('active','revoked','expired')),
  expires_at timestamptz not null,
  issued_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  constraint business_customer_join_qr_v89_expiry_check
    check(expires_at>created_at and expires_at<=created_at+interval '370 days'),
  constraint business_customer_join_qr_v89_state_shape_check check(
    (status='active' and revoked_at is null)
    or (status in ('revoked','expired') and revoked_at is not null)
  ),
  constraint business_customer_join_qr_v89_id_business_uk unique(id,business_id)
);
create index business_customer_join_qr_v89_active_idx
  on public.business_customer_join_qr_v89(business_id,expires_at desc)
  where status='active';

create table public.customer_redemption_intents_v89(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  client_id uuid not null,
  redemption_kind text not null
    check(redemption_kind in ('classic_points','catalog_reward')),
  reward_id uuid references public.loyalty_rewards(id) on delete restrict,
  quoted_program_id uuid not null
    references public.loyalty_programs(id) on delete restrict,
  quoted_config_version_id uuid
    references public.firm_config_versions(id) on delete restrict,
  quoted_reward_version_id uuid
    references public.loyalty_reward_versions(id) on delete restrict,
  quoted_points_spent integer not null check(quoted_points_spent>0),
  quoted_credit_cents integer not null check(quoted_credit_cents>=0),
  quoted_terms jsonb not null check(jsonb_typeof(quoted_terms)='object'),
  token_hash text not null unique check(token_hash~'^[0-9a-f]{64}$'),
  status text not null default 'pending'
    check(status in ('pending','completed','expired','cancelled')),
  idempotency_key uuid not null,
  request_hash text not null check(request_hash~'^[0-9a-f]{64}$'),
  expires_at timestamptz not null,
  completed_at timestamptz,
  completed_by uuid references auth.users(id) on delete restrict,
  completion_idempotency_key uuid,
  redemption_id uuid references public.loyalty_redemptions(id) on delete restrict,
  completion_operation_id uuid references public.loyalty_operations(id) on delete restrict,
  completion_result jsonb,
  created_at timestamptz not null default now(),
  constraint customer_redemption_intents_v89_identity_fk
    foreign key(identity_id,auth_user_id)
    references public.customer_identities(id,auth_user_id) on delete restrict,
  constraint customer_redemption_intents_v89_client_fk
    foreign key(business_id,client_id)
    references public.clients(business_id,id) on delete restrict,
  constraint customer_redemption_intents_v89_expiry_check
    check(expires_at>created_at and expires_at<=created_at+interval '15 minutes'),
  constraint customer_redemption_intents_v89_kind_shape_check check(
    (redemption_kind='classic_points' and reward_id is null
      and quoted_reward_version_id is null)
    or (redemption_kind='catalog_reward' and reward_id is not null
      and quoted_config_version_id is not null
      and quoted_reward_version_id is not null)
  ),
  constraint customer_redemption_intents_v89_state_check check(
    (status='pending' and completed_at is null and completed_by is null
      and completion_idempotency_key is null and redemption_id is null
      and completion_operation_id is null and completion_result is null)
    or (status='completed' and completed_at is not null and completed_by is not null
      and completion_idempotency_key is not null
      and completion_operation_id is not null and completion_result is not null
      and (
        (redemption_kind='classic_points' and redemption_id is null)
        or (redemption_kind='catalog_reward' and redemption_id is not null)
      ))
    or (status in ('expired','cancelled') and completed_at is null
      and completed_by is null and completion_idempotency_key is null
      and redemption_id is null and completion_operation_id is null
      and completion_result is null)
  ),
  constraint customer_redemption_intents_v89_customer_idem_uk
    unique(identity_id,idempotency_key),
  constraint customer_redemption_intents_v89_id_business_uk unique(id,business_id)
);
create index customer_redemption_intents_v89_customer_idx
  on public.customer_redemption_intents_v89(identity_id,created_at desc);
create index customer_redemption_intents_v89_merchant_idx
  on public.customer_redemption_intents_v89(business_id,status,expires_at);

create table public.customer_redemption_events_v89(
  id uuid primary key default gen_random_uuid(),
  intent_id uuid not null,
  business_id uuid not null,
  actor uuid not null references auth.users(id) on delete restrict,
  event_type text not null check(event_type in (
    'intent_created','scan_completed','scan_replayed','intent_expired',
    'intent_cancelled'
  )),
  idempotency_key uuid not null,
  detail jsonb not null check(jsonb_typeof(detail)='object'),
  created_at timestamptz not null default now(),
  constraint customer_redemption_events_v89_intent_fk
    foreign key(intent_id,business_id)
    references public.customer_redemption_intents_v89(id,business_id) on delete restrict,
  constraint customer_redemption_events_v89_idem_uk
    unique(intent_id,event_type,idempotency_key)
);

create table public.platform_access_grants_v89(
  user_id uuid primary key references auth.users(id) on delete restrict,
  role text not null check(role in ('admin','sales_staff')),
  module_perms jsonb not null check(
    jsonb_typeof(module_perms)='object'
    and not jsonb_path_exists(module_perms,'$.* ? (@ != "r" && @ != "rw")')
  ),
  active boolean not null default true,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_by uuid not null references auth.users(id) on delete restrict,
  updated_at timestamptz not null default now()
);

create table public.platform_access_audit_v89(
  id uuid primary key default gen_random_uuid(),
  subject_user_id uuid not null references auth.users(id) on delete restrict,
  actor uuid not null references auth.users(id) on delete restrict,
  event_type text not null check(event_type in ('grant_created','grant_updated','grant_disabled')),
  before_value jsonb,
  after_value jsonb not null check(jsonb_typeof(after_value)='object'),
  created_at timestamptz not null default now()
);

-- Generated independently in every database at migration time. It never enters
-- source control and lets an exact idempotent retry reproduce the same short-
-- lived opaque redemption QR without storing raw bearer material.
create table app.v89_token_secrets(
  secret_key text primary key,
  secret_value bytea not null,
  created_at timestamptz not null default now()
);
insert into app.v89_token_secrets(secret_key,secret_value)
values('customer_redemption',extensions.gen_random_bytes(32));

alter table public.business_customer_capabilities_v89 enable row level security;
alter table public.business_customer_join_qr_v89 enable row level security;
alter table public.customer_redemption_intents_v89 enable row level security;
alter table public.customer_redemption_events_v89 enable row level security;
alter table public.platform_access_grants_v89 enable row level security;
alter table public.platform_access_audit_v89 enable row level security;

revoke all privileges on table public.business_customer_capabilities_v89
  from public,anon,authenticated;
revoke all privileges on table public.business_customer_join_qr_v89
  from public,anon,authenticated;
revoke all privileges on table public.customer_redemption_intents_v89
  from public,anon,authenticated;
revoke all privileges on table public.customer_redemption_events_v89
  from public,anon,authenticated;
revoke all privileges on table public.platform_access_grants_v89
  from public,anon,authenticated;
revoke all privileges on table public.platform_access_audit_v89
  from public,anon,authenticated;
revoke all privileges on table app.v89_token_secrets
  from public,anon,authenticated;

create or replace function app.v89_sha256(p_value text)
returns text language sql immutable strict
set search_path to 'pg_catalog','extensions','pg_temp'
as $$select encode(extensions.digest(convert_to(p_value,'UTF8'),'sha256'),'hex')$$;

create or replace function app.v89_redemption_token(
  p_identity uuid,p_business uuid,p_redemption_kind text,p_reward uuid,
  p_idempotency_key uuid
)
returns text language sql stable security definer
set search_path to 'pg_catalog','public','app','extensions','pg_temp'
as $$
  select encode(extensions.hmac(
    convert_to(concat_ws(':',p_identity,p_business,p_redemption_kind,
      coalesce(p_reward::text,'classic'),p_idempotency_key),'UTF8'),
    secret.secret_value,'sha256'),'hex')
  from app.v89_token_secrets secret
  where secret.secret_key='customer_redemption'
$$;

create or replace function app.v89_platform_role()
returns text language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select case
    when app.is_super_admin() then 'super_admin'
    else (select grant_row.role from public.platform_access_grants_v89 grant_row
      where grant_row.user_id=auth.uid() and grant_row.active)
  end
$$;

create or replace function app.v89_platform_can(
  p_module text,p_mode text default 'r'
)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select case
    when app.is_super_admin() then true
    when p_mode not in ('r','rw') then false
    else coalesce((
      select case p_mode
        when 'r' then coalesce(
          grant_row.module_perms->>p_module,
          grant_row.module_perms->>'*'
        ) in ('r','rw')
        else coalesce(
          grant_row.module_perms->>p_module,
          grant_row.module_perms->>'*'
        )='rw'
      end
      from public.platform_access_grants_v89 grant_row
      where grant_row.user_id=auth.uid() and grant_row.active
    ),false)
  end
$$;

create or replace function app.v89_business_module_enabled(
  p_business uuid,p_module text
)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select coalesce(p_module=any(business.enabled_modules),false)
  from public.businesses business where business.id=p_business
$$;

-- All legacy platform RPCs use this coarse helper. Sales is always refused and
-- uses only auth.uid()-scoped v89 RPCs. For admins, the trusted PL/pgSQL call
-- context maps the legacy RPC to a platform module and read/write mode, keeping
-- customized admins usable without allowing a disabled module through direct RPC.
create or replace function app.is_platform_operator_v75()
returns boolean language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_context text;v_module text;v_mode text;
begin
  if app.is_super_admin() then return true;end if;
  if app.v89_platform_role()<>'admin' then return false;end if;
  get diagnostics v_context=pg_context;
  v_context:=lower(v_context);
  v_module:=case
    when v_context like '%report%' then 'reports'
    when v_context like '%billing%' or v_context like '%subscription%' then 'billing'
    when v_context~'(commission|accrual|payout)' then 'commissions'
    when v_context like '%sector%' or v_context like '%consultant%' then 'sectors'
    when v_context like '%automation%' then 'automation'
    when v_context like '%enterprise%' or v_context like '%hierarchy%'
      or v_context like '%customer%' then 'firms'
    else 'onboarding' end;
  v_mode:=case when v_context~'(create|upsert|update|assign|add|complete|move|stage|commit|record|publish|set|decide|reverse|rollback|refresh|request|approve|confirm|forfeit)'
    then 'rw' else 'r' end;
  return app.v89_platform_can(v_module,v_mode);
end
$$;

create or replace function app.v89_sales_consultant_id()
returns uuid language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select consultant.id from public.platform_consultants consultant
  where consultant.user_id=auth.uid() and consultant.active
  order by consultant.created_at,consultant.id limit 1
$$;

create or replace function app.v89_prospect_in_role_scope(p_prospect uuid)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select case app.v89_platform_role()
    when 'super_admin' then true
    when 'admin' then true
    when 'sales_staff' then exists(
      select 1 from public.sme_prospects prospect
      where prospect.id=p_prospect and (
        prospect.created_by=auth.uid()
        or prospect.assigned_consultant_id=app.v89_sales_consultant_id()
      )
    )
    else false end
$$;

create or replace function app.v89_business_in_role_scope(p_business uuid)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select case app.v89_platform_role()
    when 'super_admin' then true
    when 'admin' then true
    when 'sales_staff' then exists(
      select 1 from public.sme_prospects prospect
      where (prospect.converted_business_id=p_business
        or exists(select 1 from public.businesses business
          where business.id=p_business and business.source_prospect_id=prospect.id))
        and (prospect.created_by=auth.uid()
          or prospect.assigned_consultant_id=app.v89_sales_consultant_id())
    )
    else false end
$$;

create or replace function app.v89_can_access_prospect(p_prospect uuid)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select case app.v89_platform_role()
    when 'super_admin' then true
    when 'admin' then app.v89_platform_can('onboarding','r')
    when 'sales_staff' then app.v89_platform_can('onboarding','r')
      and app.v89_prospect_in_role_scope(p_prospect)
    else false end
$$;

create or replace function app.v89_can_access_business(p_business uuid)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select case app.v89_platform_role()
    when 'super_admin' then true
    when 'admin' then app.v89_platform_can('firms','r')
    when 'sales_staff' then app.v89_business_in_role_scope(p_business)
    else false end
$$;

-- Legacy self-link routes are removed from the browser allowlist. Existing
-- verified links remain intact; firm-issued invitation claims remain available.
revoke all on function public.customer_claim_link_by_email(text,text)
  from public,anon,authenticated;
revoke all on function public.customer_claim_link_by_verified_phone(text,text)
  from public,anon,authenticated;
revoke all on function public.customer_sync_verified_relationships_v81(text)
  from public,anon,authenticated;
revoke all on function public.join_program(text,text,text,text,boolean)
  from public,anon,authenticated;
revoke all on function public.get_join_page(text)
  from public,anon,authenticated;
revoke all on function public.internal_public_join_page(text)
  from public,anon,authenticated,service_role;
revoke all on function public.internal_public_join(text,text,text,text,boolean)
  from public,anon,authenticated,service_role;

create or replace function public.internal_public_join_page_v89(p_join_token text)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_result jsonb;
begin
  if length(coalesce(p_join_token,''))<32 then
    return null;
  end if;
  select jsonb_build_object(
    'name',business.name,'brand_color',business.brand_color,
    'industry',business.industry,'join_token',p_join_token,
    'expires_at',qr.expires_at
  ) into v_result
  from public.business_customer_join_qr_v89 qr
  join public.businesses business on business.id=qr.business_id
  where qr.token_hash=app.v89_sha256(p_join_token)
    and qr.status='active' and qr.expires_at>now() and business.join_enabled;
  return v_result;
end
$$;

create or replace function public.internal_public_join_v89(
  p_join_token text,p_name text,p_phone text,p_email text default null,
  p_consent boolean default false
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_business uuid;v_name text:=nullif(btrim(p_name),'');
  v_phone text:=app.norm_phone(p_phone);v_client uuid;v_business_name text;
begin
  select qr.business_id,business.name into v_business,v_business_name
  from public.business_customer_join_qr_v89 qr
  join public.businesses business on business.id=qr.business_id
  where qr.token_hash=app.v89_sha256(p_join_token)
    and qr.status='active' and qr.expires_at>now() and business.join_enabled
  for share;
  if v_business is null then
    raise exception 'This join QR is not active.' using errcode='22023';
  end if;
  if v_name is null or length(v_name) not between 2 and 80 or v_phone is null then
    raise exception 'Enter a valid name and Singapore mobile number.'
      using errcode='22023';
  end if;
  insert into public.clients(
    business_id,full_name,phone,email,marketing_consent
  ) values(
    v_business,v_name,v_phone,nullif(btrim(coalesce(p_email,'')),''),
    coalesce(p_consent,false)
  ) on conflict(business_id,phone_norm) where phone_norm is not null
    do nothing returning id into v_client;
  if v_client is not null then
    insert into public.consents(business_id,client_id,channel,action,source)
    values(v_business,v_client,'marketing',
      case when coalesce(p_consent,false) then 'granted' else 'withdrawn' end,
      'qr_join_v89');
    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values(v_business,null,'CUSTOMER_QR_SIGNUP_V89','clients',v_client,
      jsonb_build_object('consent',coalesce(p_consent,false)));
  end if;
  -- Deliberately uniform for new/existing numbers. The token is handed through
  -- to the post-OTP authenticated QR claim; no link is created here.
  return jsonb_build_object('status','ok','business_name',v_business_name,
    'join_token',p_join_token,'next','customer_auth');
end
$$;

create or replace function public.business_set_customer_capabilities_v89(
  p_business uuid,p_booking_enabled boolean,p_redemption_enabled boolean,
  p_appointment_changes_enabled boolean default false
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_row public.business_customer_capabilities_v89%rowtype;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'business owner access is required' using errcode='42501';
  end if;
  insert into public.business_customer_capabilities_v89(
    business_id,booking_enabled,redemption_enabled,
    appointment_changes_enabled,updated_by
  ) values(
    p_business,coalesce(p_booking_enabled,false),
    coalesce(p_redemption_enabled,false),
    coalesce(p_appointment_changes_enabled,false),auth.uid()
  )
  on conflict(business_id) do update set
    booking_enabled=excluded.booking_enabled,
    redemption_enabled=excluded.redemption_enabled,
    appointment_changes_enabled=excluded.appointment_changes_enabled,
    updated_by=auth.uid(),updated_at=now()
  returning * into v_row;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'SET_CUSTOMER_CAPABILITIES_V89',
    'business_customer_capabilities_v89',p_business,
    jsonb_build_object('booking_enabled',v_row.booking_enabled,
      'redemption_enabled',v_row.redemption_enabled,
      'appointment_changes_enabled',v_row.appointment_changes_enabled));
  return jsonb_build_object(
    'business_id',p_business,
    'booking_enabled',v_row.booking_enabled
      and app.v89_business_module_enabled(p_business,'bookings'),
    'redemption_enabled',v_row.redemption_enabled
      and app.v89_business_module_enabled(p_business,'loyalty'),
    'appointment_changes_enabled',v_row.appointment_changes_enabled
      and app.v89_business_module_enabled(p_business,'appointments'),
    'configured',jsonb_build_object(
      'booking_enabled',v_row.booking_enabled,
      'redemption_enabled',v_row.redemption_enabled,
      'appointment_changes_enabled',v_row.appointment_changes_enabled),
    'updated_at',v_row.updated_at
  );
end
$$;

create or replace function public.business_get_customer_capabilities_v89(
  p_business uuid
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_result jsonb;
begin
  if not (app.is_salon_member(p_business) or app.is_super_admin()) then
    raise exception 'business staff access is required' using errcode='42501';
  end if;
  select jsonb_build_object(
    'business_id',p_business,
    'booking_enabled',coalesce(capability.booking_enabled,false)
      and app.v89_business_module_enabled(p_business,'bookings'),
    'redemption_enabled',coalesce(capability.redemption_enabled,false)
      and app.v89_business_module_enabled(p_business,'loyalty'),
    'appointment_changes_enabled',
      coalesce(capability.appointment_changes_enabled,false)
      and app.v89_business_module_enabled(p_business,'appointments'),
    'configured',jsonb_build_object(
      'booking_enabled',coalesce(capability.booking_enabled,false),
      'redemption_enabled',coalesce(capability.redemption_enabled,false),
      'appointment_changes_enabled',
        coalesce(capability.appointment_changes_enabled,false))
  ) into v_result
  from (select p_business business_id) requested
  left join public.business_customer_capabilities_v89 capability
    on capability.business_id=requested.business_id;
  return v_result;
end
$$;

create or replace function public.business_create_customer_join_qr_v89(
  p_business uuid,p_expires_at timestamptz default now()+interval '365 days'
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','extensions','pg_temp'
as $$
declare v_token text;v_qr public.business_customer_join_qr_v89%rowtype;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'business owner access is required' using errcode='42501';
  end if;
  if p_expires_at<=now()+interval '5 minutes'
     or p_expires_at>now()+interval '370 days' then
    raise exception 'join QR expiry must be between 5 minutes and 370 days'
      using errcode='22023';
  end if;
  v_token:=encode(extensions.gen_random_bytes(32),'hex');
  insert into public.business_customer_join_qr_v89(
    business_id,token_hash,expires_at,issued_by
  ) values(p_business,app.v89_sha256(v_token),p_expires_at,auth.uid())
  returning * into v_qr;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'CREATE_CUSTOMER_JOIN_QR_V89',
    'business_customer_join_qr_v89',v_qr.id,
    jsonb_build_object('expires_at',v_qr.expires_at));
  return jsonb_build_object('qr_id',v_qr.id,'join_token',v_token,
    'expires_at',v_qr.expires_at);
end
$$;

create or replace function public.customer_join_business_from_qr_v89(
  p_join_token text,p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_identity uuid;
  v_qr public.business_customer_join_qr_v89%rowtype;
  v_auth_phone text;v_phone_confirmed_at timestamptz;v_phone text;
  v_profile public.customer_profiles%rowtype;
  v_client uuid;v_link uuid;v_existing public.customer_link_claim_attempts%rowtype;
  v_hash text;v_response jsonb;v_event text;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode='28000';
  end if;
  if not app.platform_feature_enabled('customer_qr_join') then
    raise exception 'customer QR join is unavailable' using errcode='0A000';
  end if;
  if p_idempotency_key is null or length(coalesce(p_join_token,''))<32 then
    raise exception 'invalid QR join request' using errcode='22023';
  end if;
  v_identity:=app.v31_current_identity();
  v_hash:=app.v89_sha256(p_join_token);
  perform pg_advisory_xact_lock(hashtextextended(
    'v89:join:'||v_identity::text||':'||p_idempotency_key::text,0));
  select * into v_existing from public.customer_link_claim_attempts attempt
  where attempt.identity_id=v_identity and attempt.operation='qr_join'
    and attempt.idempotency_key=p_idempotency_key::text for update;
  if found then
    if v_existing.request_hash<>v_hash then
      raise exception 'idempotency key conflicts with another QR join'
        using errcode='23505';
    end if;
    return v_existing.response||jsonb_build_object('replayed',true);
  end if;

  select * into v_qr from public.business_customer_join_qr_v89 qr
  where qr.token_hash=v_hash and qr.status='active' and qr.expires_at>now()
  for share;
  if not found then
    raise exception 'join QR is invalid or expired' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'v89:business-customer:'||v_qr.business_id::text||':'||v_identity::text,0));
  select link.id,link.client_id into v_link,v_client
  from public.customer_links link
  where link.business_id=v_qr.business_id and link.identity_id=v_identity
    and link.auth_user_id=v_actor and link.state='verified' for update;
  if found then
    v_response:=jsonb_build_object('outcome','linked','business_id',
      v_qr.business_id,'link_id',v_link,'replayed',true);
    v_event:='qr_join_replayed';
  else
    select auth_user.phone,auth_user.phone_confirmed_at
      into v_auth_phone,v_phone_confirmed_at
      from auth.users auth_user where auth_user.id=v_actor for share;
    v_phone:=app.norm_phone(v_auth_phone);
    if v_phone_confirmed_at is null or v_phone is null then
      raise exception 'verified customer mobile is required' using errcode='42501';
    end if;
    select * into v_profile from public.customer_profiles profile
      where profile.identity_id=v_identity and profile.auth_user_id=v_actor;
    if not found then
      raise exception 'completed customer profile is required' using errcode='42501';
    end if;
    select client.id into v_client from public.clients client
      where client.business_id=v_qr.business_id and client.phone_norm=v_phone
      for update;
    if found and exists(select 1 from public.customer_links prior
      where prior.business_id=v_qr.business_id and prior.client_id=v_client
        and prior.state='verified') then
      raise exception 'this business relationship cannot be joined automatically'
        using errcode='42501';
    end if;
    if v_client is null then
      insert into public.clients(
        business_id,full_name,phone,birth_date,marketing_consent
      ) values(
        v_qr.business_id,v_profile.full_name,v_phone,v_profile.birth_date,false
      ) returning id into v_client;
    end if;
    v_link:=gen_random_uuid();
    perform set_config('app.customer_link_insert_id',v_link::text,true);
    insert into public.customer_links(
      id,business_id,identity_id,auth_user_id,client_id,state,
      verification_method,verified_at
    ) values(
      v_link,v_qr.business_id,v_identity,v_actor,v_client,'verified','qr_join',now()
    );
    perform set_config('app.customer_link_insert_id','',true);
    v_response:=jsonb_build_object('outcome','linked','business_id',
      v_qr.business_id,'link_id',v_link,'replayed',false);
    v_event:='qr_join_linked';
  end if;
  insert into public.customer_link_claim_attempts(
    identity_id,auth_user_id,business_id,link_id,operation,idempotency_key,
    request_hash,outcome,response
  ) values(
    v_identity,v_actor,v_qr.business_id,v_link,'qr_join',
    p_idempotency_key::text,v_hash,'linked',v_response
  );
  insert into public.customer_link_audit_events(
    identity_id,actor_auth_user_id,business_id,client_id,link_id,event_type,
    idempotency_key,request_hash,response
  ) values(
    v_identity,v_actor,v_qr.business_id,v_client,v_link,v_event,
    p_idempotency_key::text,v_hash,v_response
  );
  return v_response;
end
$$;

create or replace function public.customer_list_programmes_v89()
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_identity uuid;v_result jsonb;
begin
  v_identity:=app.v31_current_identity();
  select jsonb_build_object(
    'programmes',coalesce(jsonb_agg(jsonb_build_object(
      'business',jsonb_build_object(
        'id',row_data.business_id,'slug',row_data.slug,'name',row_data.name,
        'industry',row_data.industry,'currency',row_data.currency),
      'capabilities',jsonb_build_object(
        'booking_enabled',row_data.booking_enabled,
        'redemption_enabled',row_data.redemption_enabled,
        'appointment_changes_enabled',row_data.appointment_changes_enabled),
      'loyalty',jsonb_build_object(
        'balance',row_data.points_balance,'unit',row_data.unit),
      'upcoming_appointments',jsonb_build_object('count',row_data.upcoming_count)
    ) order by lower(row_data.name),row_data.business_id),'[]'::jsonb),
    'truncated',false
  ) into v_result
  from (
    select business.id business_id,business.slug,business.name,business.industry,
      business.currency,
      coalesce(capability.booking_enabled,false)
      and app.v89_business_module_enabled(business.id,'bookings') and exists(
        select 1 from public.services service
        where service.business_id=business.id and service.active
          and service.show_on_booking_page
      ) booking_enabled,
      coalesce(capability.redemption_enabled,false)
        and app.v89_business_module_enabled(business.id,'loyalty')
        and program.id is not null redemption_enabled,
      coalesce(capability.appointment_changes_enabled,false)
        and app.v89_business_module_enabled(business.id,'appointments')
        appointment_changes_enabled,
      coalesce((select sum(ledger.points)::integer from public.points_ledger ledger
        where ledger.business_id=link.business_id
          and ledger.client_id=link.client_id),0) points_balance,
      case when program.loyalty_model='stamps' then 'stamps' else 'points' end unit,
      (select count(*)::integer from public.appointments appointment
        where appointment.business_id=link.business_id
          and appointment.client_id=link.client_id
          and appointment.status='booked' and appointment.starts_at>=now()) upcoming_count
    from public.customer_links link
    join public.customer_identities identity
      on identity.id=link.identity_id and identity.auth_user_id=link.auth_user_id
    join public.businesses business on business.id=link.business_id
    left join public.business_customer_capabilities_v89 capability
      on capability.business_id=business.id
    left join lateral(
      select programme.id,programme.loyalty_model
      from public.loyalty_programs programme
      where programme.business_id=business.id and programme.active
      order by (programme.current_config_version_id is not null) desc,
        programme.id
      limit 1
    ) program on true
    where link.identity_id=v_identity and link.auth_user_id=auth.uid()
      and link.state='verified' and identity.status='active'
  ) row_data;
  return v_result;
end
$$;

-- Keep the anonymous booking catalogue identical to the service predicate
-- enforced by internal_public_booking_submit. A service that the merchant has
-- hidden from online booking must never be advertised by the public GET.
create or replace function public.get_business_public(p_slug text)
returns json language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select json_build_object(
    'id',business.id,
    'name',business.name,
    'industry',business.industry,
    'currency',business.currency,
    'booking_policy',business.booking_policy,
    'brand_color',business.brand_color,
    'services',coalesce((
      select json_agg(json_build_object(
        'id',service.id,
        'name',service.name,
        'price_cents',service.price_cents,
        'duration_min',service.duration_min
      ) order by lower(service.name),service.id)
      from public.services service
      where service.business_id=business.id
        and service.active
        and service.show_on_booking_page
    ),'[]'::json)
  )
  from public.businesses business
  where business.slug=p_slug
$$;

create or replace function public.customer_get_business_actions_v89(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_identity uuid;v_client uuid;v_result jsonb;
  v_balance integer;v_batch_balance integer;
  v_program public.loyalty_programs%rowtype;
begin
  v_identity:=app.v31_current_identity();
  select link.client_id into v_client from public.customer_links link
  where link.identity_id=v_identity and link.auth_user_id=auth.uid()
    and link.business_id=p_business and link.state='verified';
  if not found then raise exception 'verified customer link required' using errcode='42501';end if;
  select coalesce(sum(points),0)::integer into v_balance from public.points_ledger
    where business_id=p_business and client_id=v_client;
  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0;
  select * into v_program from public.loyalty_programs program
    where program.business_id=p_business and program.active
    order by program.id limit 1;
  select jsonb_build_object(
    'business',jsonb_build_object('id',business.id,'slug',business.slug,
      'name',business.name,'industry',business.industry,'currency',business.currency),
    'booking',jsonb_build_object('enabled',
      coalesce(capability.booking_enabled,false)
      and app.v89_business_module_enabled(p_business,'bookings') and exists(
        select 1 from public.services service where service.business_id=p_business
          and service.active and service.show_on_booking_page),
      'public_slug',case when coalesce(capability.booking_enabled,false)
        and app.v89_business_module_enabled(p_business,'bookings') and exists(
        select 1 from public.services service where service.business_id=p_business
          and service.active and service.show_on_booking_page)
        then business.slug else null end),
    'redemption',jsonb_build_object(
      'enabled',coalesce(capability.redemption_enabled,false)
        and app.v89_business_module_enabled(p_business,'loyalty')
        and v_program.id is not null,
      'classic',case when v_program.loyalty_model='classic'
        and v_program.kind='points'
        and v_program.redeem_points>0 and v_program.reward_credit_cents>0
        then jsonb_build_object(
          'redemption_kind','classic_points',
          'name',concat('Redeem ',v_program.redeem_points,' points'),
          'cost_points',v_program.redeem_points,
          'credit_cents',v_program.reward_credit_cents,
          'availability',case
            when not coalesce(capability.redemption_enabled,false)
              or not app.v89_business_module_enabled(p_business,'loyalty')
              then 'disabled'
            when least(v_balance,v_batch_balance)<v_program.redeem_points
              then 'insufficient_balance'
            else 'available_at_counter' end)
        else null end),
    'appointment_changes',jsonb_build_object(
      'enabled',coalesce(capability.appointment_changes_enabled,false)
        and app.v89_business_module_enabled(p_business,'appointments')),
    'rewards',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',reward.id,'name',coalesce(reward.customer_name,reward.name),
        'redemption_kind','catalog_reward',
        'cost_points',reward_version.cost_points,
        'availability',case
          when not coalesce(capability.redemption_enabled,false)
            or not app.v89_business_module_enabled(p_business,'loyalty')
            then 'disabled'
          when reward_version.claim_available_from is not null
            and reward_version.claim_available_from>now() then 'not_started'
          when reward_version.claim_available_until is not null
            and reward_version.claim_available_until<=now() then 'ended'
          when reward_version.usage_limit is not null and (
            select count(*) from public.loyalty_redemptions redemption
            where redemption.business_id=p_business
              and redemption.client_id=v_client
              and redemption.reward_id=reward.id
          )>=reward_version.usage_limit then 'limit_reached'
          when least(v_balance,v_batch_balance)<reward_version.cost_points
            then 'insufficient_balance'
          else 'available_at_counter' end
      ) order by reward.sort,reward.id)
      from public.loyalty_rewards reward
      join public.loyalty_reward_versions reward_version
        on reward_version.reward_id=reward.id
       and reward_version.business_id=reward.business_id
      where reward.business_id=p_business and reward.active
        and v_program.loyalty_model in ('points_tiers','stamps')
        and reward_version.config_version_id=business.active_config_version_id
        and reward_version.active
        -- Customer QR redemption carries no visit context in v89. Restricted
        -- rewards remain visible through the ordinary wallet catalog, but are
        -- truthfully excluded from this actionable scan list.
        and not exists(select 1 from public.loyalty_reward_branches restriction
          where restriction.reward_version_id=reward_version.id)
        and not exists(select 1 from public.loyalty_reward_services restriction
          where restriction.reward_version_id=reward_version.id)
        and not exists(select 1 from public.loyalty_reward_products restriction
          where restriction.reward_version_id=reward_version.id)
    ),'[]'::jsonb)
  ) into v_result
  from public.businesses business
  left join public.business_customer_capabilities_v89 capability
    on capability.business_id=business.id
  where business.id=p_business;
  return v_result;
end
$$;

-- Customer-bound booking requests cannot bypass the merchant's app-booking
-- switch, even if a stale client calls the older public booking endpoint.
create or replace function app.v89_customer_booking_gate()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if new.customer_client_id is not null and not coalesce((
    select capability.booking_enabled
    from public.business_customer_capabilities_v89 capability
    where capability.business_id=new.business_id
  ),false)
  or (new.customer_client_id is not null
    and not app.v89_business_module_enabled(new.business_id,'bookings')) then
    raise exception 'customer app booking is disabled for this business'
      using errcode='42501';
  end if;
  return new;
end
$$;
create trigger trg_booking_requests_customer_gate_v89
before insert on public.booking_requests
for each row execute function app.v89_customer_booking_gate();

create or replace function app.v89_customer_appointment_change_gate()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not app.v89_business_module_enabled(new.business_id,'appointments')
     or not coalesce((
    select capability.appointment_changes_enabled
    from public.business_customer_capabilities_v89 capability
    where capability.business_id=new.business_id
  ),false) then
    raise exception 'customer appointment changes are disabled for this business'
      using errcode='42501';
  end if;
  return new;
end
$$;
create trigger trg_customer_appointment_action_gate_v89
before insert on public.customer_appointment_action_requests
for each row execute function app.v89_customer_appointment_change_gate();

create or replace function public.customer_create_redemption_intent_v89(
  p_business uuid,p_reward uuid,p_idempotency_key uuid,
  p_redemption_kind text default 'catalog_reward'
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','extensions','pg_temp'
as $$
declare
  v_identity uuid;v_client uuid;v_reward public.loyalty_rewards%rowtype;
  v_program public.loyalty_programs%rowtype;
  v_reward_version public.loyalty_reward_versions%rowtype;
  v_existing public.customer_redemption_intents_v89%rowtype;
  v_token text;v_hash text;v_request_hash text;
  v_quote jsonb;
  v_balance integer;v_batch_balance integer;v_cost_points integer;
  v_kind text:=lower(btrim(coalesce(p_redemption_kind,'')));
  v_intent uuid:=gen_random_uuid();
  v_expires timestamptz:=now()+interval '5 minutes';v_response jsonb;
begin
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode='22023';
  end if;
  if v_kind not in ('classic_points','catalog_reward') then
    raise exception 'unsupported redemption kind' using errcode='22023';
  end if;
  if (v_kind='classic_points' and p_reward is not null)
     or (v_kind='catalog_reward' and p_reward is null) then
    raise exception 'redemption kind and reward do not match' using errcode='22023';
  end if;
  if not app.platform_feature_enabled('customer_qr_redemption') then
    raise exception 'customer QR redemption is unavailable' using errcode='0A000';
  end if;
  v_identity:=app.v31_current_identity();
  v_request_hash:=app.v89_sha256(p_business::text||':'||v_kind||':'||
    coalesce(p_reward::text,'classic'));
  perform pg_advisory_xact_lock(hashtextextended(
    'v89:redemption-intent:'||v_identity::text||':'||p_idempotency_key::text,0));
  select * into v_existing from public.customer_redemption_intents_v89 intent
  where intent.identity_id=v_identity and intent.idempotency_key=p_idempotency_key
  for update;
  if found then
    if v_existing.request_hash<>v_request_hash then
      raise exception 'idempotency key conflicts with another redemption intent'
        using errcode='23505';
    end if;
    return jsonb_build_object('intent_id',v_existing.id,'status',v_existing.status,
      'redemption_kind',v_existing.redemption_kind,
      'qr_token',app.v89_redemption_token(v_identity,p_business,
        v_existing.redemption_kind,v_existing.reward_id,p_idempotency_key),
      'expires_at',v_existing.expires_at,'replayed',true);
  end if;
  if not coalesce((select capability.redemption_enabled
    from public.business_customer_capabilities_v89 capability
    where capability.business_id=p_business),false)
     or not app.v89_business_module_enabled(p_business,'loyalty') then
    raise exception 'customer redemption is disabled for this business'
      using errcode='42501';
  end if;
  select link.client_id into v_client from public.customer_links link
  where link.identity_id=v_identity and link.auth_user_id=auth.uid()
    and link.business_id=p_business and link.state='verified' for share;
  if not found then raise exception 'verified customer link required' using errcode='42501';end if;
  select * into v_program from public.loyalty_programs program
  where program.business_id=p_business and program.active order by program.id limit 1;
  if not found then raise exception 'loyalty redemption is unavailable' using errcode='22023';end if;
  if v_kind='classic_points' then
    if v_program.kind<>'points' or v_program.loyalty_model<>'classic'
       or v_program.redeem_points<=0 or v_program.reward_credit_cents<=0 then
      raise exception 'classic points redemption is unavailable' using errcode='22023';
    end if;
    v_cost_points:=v_program.redeem_points;
    v_quote:=jsonb_build_object(
      'program_id',v_program.id,
      'config_version_id',v_program.current_config_version_id,
      'loyalty_model',v_program.loyalty_model,'kind',v_program.kind,
      'points_spent',v_program.redeem_points,
      'credit_cents',v_program.reward_credit_cents);
  else
    if v_program.loyalty_model not in ('points_tiers','stamps') then
      raise exception 'catalog redemption is unavailable' using errcode='22023';
    end if;
    select * into v_reward from public.loyalty_rewards reward
    where reward.id=p_reward and reward.business_id=p_business and reward.active;
    if not found then
      raise exception 'reward is unavailable' using errcode='22023';
    end if;
    select reward_version.* into v_reward_version
    from public.loyalty_reward_versions reward_version
    join public.businesses business on business.id=reward_version.business_id
    where reward_version.reward_id=p_reward
      and reward_version.business_id=p_business
      and reward_version.config_version_id=business.active_config_version_id
      and reward_version.active;
    if not found
       or (v_reward_version.claim_available_from is not null
         and v_reward_version.claim_available_from>now())
       or (v_reward_version.claim_available_until is not null
         and v_reward_version.claim_available_until<=now()) then
      raise exception 'reward is unavailable' using errcode='22023';
    end if;
    if exists(select 1 from public.loyalty_reward_branches restriction
         where restriction.reward_version_id=v_reward_version.id)
       or exists(select 1 from public.loyalty_reward_services restriction
         where restriction.reward_version_id=v_reward_version.id)
       or exists(select 1 from public.loyalty_reward_products restriction
         where restriction.reward_version_id=v_reward_version.id) then
      raise exception 'context-restricted rewards require staff-assisted redemption'
        using errcode='22023';
    end if;
    if v_reward_version.usage_limit is not null and (
      select count(*) from public.loyalty_redemptions redemption
      where redemption.business_id=p_business
        and redemption.client_id=v_client and redemption.reward_id=p_reward
    )>=v_reward_version.usage_limit then
      raise exception 'reward usage limit reached' using errcode='23514';
    end if;
    v_cost_points:=v_reward_version.cost_points;
    v_quote:=jsonb_build_object(
      'program_id',v_program.id,
      'config_version_id',v_reward_version.config_version_id,
      'reward_version_id',v_reward_version.id,'reward_id',p_reward,
      'points_spent',v_reward_version.cost_points,
      'credit_cents',v_reward_version.credit_cents,
      'fulfillment_kind',v_reward_version.fulfillment_kind,
      'claim_available_from',v_reward_version.claim_available_from,
      'claim_available_until',v_reward_version.claim_available_until,
      'usage_limit',v_reward_version.usage_limit,
      'active',v_reward_version.active);
  end if;
  select coalesce(sum(points),0)::integer into v_balance from public.points_ledger
  where business_id=p_business and client_id=v_client;
  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0;
  if least(v_balance,v_batch_balance)<v_cost_points then
    raise exception 'insufficient points' using errcode='23514';
  end if;
  v_token:=app.v89_redemption_token(
    v_identity,p_business,v_kind,p_reward,p_idempotency_key);
  v_hash:=app.v89_sha256(v_token);
  insert into public.customer_redemption_intents_v89(
    id,business_id,identity_id,auth_user_id,client_id,redemption_kind,reward_id,
    quoted_program_id,quoted_config_version_id,quoted_reward_version_id,
    quoted_points_spent,quoted_credit_cents,quoted_terms,
    token_hash,idempotency_key,request_hash,expires_at
  ) values(
    v_intent,p_business,v_identity,auth.uid(),v_client,v_kind,p_reward,
    v_program.id,
    case when v_kind='catalog_reward' then v_reward_version.config_version_id
      else v_program.current_config_version_id end,
    case when v_kind='catalog_reward' then v_reward_version.id else null end,
    v_cost_points,
    case when v_kind='catalog_reward' then v_reward_version.credit_cents
      else v_program.reward_credit_cents end,
    v_quote,
    v_hash,p_idempotency_key,v_request_hash,v_expires
  );
  insert into public.customer_redemption_events_v89(
    intent_id,business_id,actor,event_type,idempotency_key,detail
  ) values(
    v_intent,p_business,auth.uid(),'intent_created',p_idempotency_key,
    jsonb_build_object('redemption_kind',v_kind,'reward_id',p_reward,
      'expires_at',v_expires)
  );
  v_response:=jsonb_build_object('intent_id',v_intent,'status','pending',
    'redemption_kind',v_kind,'qr_token',v_token,'expires_at',v_expires,
    'replayed',false);
  return v_response;
end
$$;

create or replace function public.merchant_scan_redemption_qr_v89(
  p_business uuid,p_qr_token text,p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_intent public.customer_redemption_intents_v89%rowtype;
  v_result jsonb;v_redemption uuid;v_operation uuid;v_operation_type text;
  v_program public.loyalty_programs%rowtype;
  v_reward_version public.loyalty_reward_versions%rowtype;
  v_current_quote jsonb;
  v_customer_name text;v_reward_label text;
begin
  if p_idempotency_key is null or length(coalesce(p_qr_token,''))<32 then
    raise exception 'invalid redemption QR scan' using errcode='22023';
  end if;
  if not app.can_module_write(p_business,'loyalty')
     or not app.has_perm(p_business,'create_sales') then
    raise exception 'merchant loyalty redemption access is required'
      using errcode='42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'v89:scan:'||p_business::text||':'||app.v89_sha256(p_qr_token),0));
  select * into v_intent from public.customer_redemption_intents_v89 intent
  where intent.business_id=p_business
    and intent.token_hash=app.v89_sha256(p_qr_token) for update;
  if not found then raise exception 'redemption QR is invalid' using errcode='22023';end if;
  if v_intent.status='completed' then
    insert into public.customer_redemption_events_v89(
      intent_id,business_id,actor,event_type,idempotency_key,detail
    ) values(v_intent.id,p_business,auth.uid(),'scan_replayed',p_idempotency_key,
      jsonb_build_object('redemption_kind',v_intent.redemption_kind,
        'redemption_id',v_intent.redemption_id,
        'operation_id',v_intent.completion_operation_id))
    on conflict(intent_id,event_type,idempotency_key) do nothing;
    return v_intent.completion_result||jsonb_build_object('replayed',true);
  end if;
  if v_intent.status<>'pending' then
    raise exception 'redemption QR is no longer pending' using errcode='22023';
  end if;
  if v_intent.expires_at<=now() then
    perform set_config('app.v89_redemption_intent_id',v_intent.id::text,true);
    update public.customer_redemption_intents_v89 set status='expired'
      where id=v_intent.id;
    perform set_config('app.v89_redemption_intent_id','',true);
    insert into public.customer_redemption_events_v89(
      intent_id,business_id,actor,event_type,idempotency_key,detail
    ) values(v_intent.id,p_business,auth.uid(),'intent_expired',p_idempotency_key,
      jsonb_build_object('expired_at',v_intent.expires_at));
    return jsonb_build_object('intent_id',v_intent.id,'status','expired',
      'expires_at',v_intent.expires_at,'replayed',false);
  end if;
  if not app.platform_feature_enabled('customer_qr_redemption')
     or not coalesce((select capability.redemption_enabled
       from public.business_customer_capabilities_v89 capability
       where capability.business_id=p_business),false)
     or not app.v89_business_module_enabled(p_business,'loyalty') then
    raise exception 'customer redemption is disabled for this business'
      using errcode='42501';
  end if;
  select * into v_program from public.loyalty_programs program
  where program.id=v_intent.quoted_program_id
    and program.business_id=p_business and program.active for share;
  if not found then
    raise exception 'redemption configuration changed; create a new QR'
      using errcode='23514';
  end if;
  select client.full_name into v_customer_name from public.clients client
  where client.id=v_intent.client_id and client.business_id=p_business;
  if v_intent.redemption_kind='classic_points' then
    v_current_quote:=jsonb_build_object(
      'program_id',v_program.id,
      'config_version_id',v_program.current_config_version_id,
      'loyalty_model',v_program.loyalty_model,'kind',v_program.kind,
      'points_spent',v_program.redeem_points,
      'credit_cents',v_program.reward_credit_cents);
    if v_current_quote is distinct from v_intent.quoted_terms then
      raise exception 'classic redemption terms changed; create a new QR'
        using errcode='23514';
    end if;
    v_reward_label:='Store credit';
    v_operation_type:='redeem_points';
    v_result:=public.redeem_points(
      p_business,v_intent.client_id,'v89:'||v_intent.id::text
    )::jsonb;
  else
    select reward_version.* into v_reward_version
    from public.loyalty_reward_versions reward_version
    join public.businesses business on business.id=reward_version.business_id
    where reward_version.id=v_intent.quoted_reward_version_id
      and reward_version.reward_id=v_intent.reward_id
      and reward_version.business_id=p_business
      and reward_version.config_version_id=business.active_config_version_id
      and reward_version.active for share;
    if not found
       or exists(select 1 from public.loyalty_reward_branches restriction
         where restriction.reward_version_id=v_intent.quoted_reward_version_id)
       or exists(select 1 from public.loyalty_reward_services restriction
         where restriction.reward_version_id=v_intent.quoted_reward_version_id)
       or exists(select 1 from public.loyalty_reward_products restriction
         where restriction.reward_version_id=v_intent.quoted_reward_version_id) then
      raise exception 'catalog redemption terms changed; create a new QR'
        using errcode='23514';
    end if;
    v_current_quote:=jsonb_build_object(
      'program_id',v_program.id,
      'config_version_id',v_reward_version.config_version_id,
      'reward_version_id',v_reward_version.id,'reward_id',v_intent.reward_id,
      'points_spent',v_reward_version.cost_points,
      'credit_cents',v_reward_version.credit_cents,
      'fulfillment_kind',v_reward_version.fulfillment_kind,
      'claim_available_from',v_reward_version.claim_available_from,
      'claim_available_until',v_reward_version.claim_available_until,
      'usage_limit',v_reward_version.usage_limit,
      'active',v_reward_version.active);
    if v_current_quote is distinct from v_intent.quoted_terms then
      raise exception 'catalog redemption terms changed; create a new QR'
        using errcode='23514';
    end if;
    v_reward_label:=coalesce(v_reward_version.customer_name,'Reward');
    v_operation_type:='redeem_reward';
    v_result:=public.redeem_reward(
      p_business,v_intent.client_id,v_intent.reward_id,
      'v89:'||v_intent.id::text
    )::jsonb;
  end if;
  select operation.id into v_operation from public.loyalty_operations operation
  where operation.business_id=p_business
    and operation.operation_type=v_operation_type
    and operation.idempotency_key='v89:'||v_intent.id::text
    and operation.status='completed';
  if not found then
    raise exception 'canonical redemption operation was not recorded'
      using errcode='40001';
  end if;
  if v_intent.redemption_kind='catalog_reward' then
    select provenance.redemption_id into v_redemption
    from public.loyalty_redemption_provenance provenance
    where provenance.business_id=p_business
      and provenance.operation_id=v_operation;
    if not found then
      raise exception 'canonical catalog redemption was not recorded'
        using errcode='40001';
    end if;
  end if;
  v_result:=jsonb_build_object('intent_id',v_intent.id,'status','completed',
    'redemption_kind',v_intent.redemption_kind,'completed_at',now(),
    'operation_id',v_operation,'redemption_id',v_redemption,
    'customer_name',v_customer_name,'reward_label',v_reward_label,
    'points_spent',v_intent.quoted_points_spent,
    'credit_cents',v_intent.quoted_credit_cents,
    'result',v_result,'replayed',false);
  perform set_config('app.v89_redemption_intent_id',v_intent.id::text,true);
  update public.customer_redemption_intents_v89 set
    status='completed',completed_at=now(),completed_by=auth.uid(),
    completion_idempotency_key=p_idempotency_key,redemption_id=v_redemption,
    completion_operation_id=v_operation,
    completion_result=v_result where id=v_intent.id;
  perform set_config('app.v89_redemption_intent_id','',true);
  insert into public.customer_redemption_events_v89(
    intent_id,business_id,actor,event_type,idempotency_key,detail
  ) values(v_intent.id,p_business,auth.uid(),'scan_completed',p_idempotency_key,
    jsonb_build_object('redemption_kind',v_intent.redemption_kind,
      'redemption_id',v_redemption,'operation_id',v_operation));
  return v_result;
end
$$;

create or replace function public.customer_get_redemption_intent_v89(p_intent uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_identity uuid:=app.v31_current_identity();
  v_intent public.customer_redemption_intents_v89%rowtype;
begin
  select * into v_intent from public.customer_redemption_intents_v89 intent
  where intent.id=p_intent and intent.identity_id=v_identity
    and intent.auth_user_id=auth.uid();
  if not found then
    raise exception 'redemption intent was not found' using errcode='42501';
  end if;
  return jsonb_build_object(
    'intent_id',v_intent.id,
    'business_id',v_intent.business_id,
    'reward_id',v_intent.reward_id,
    'status',case when v_intent.status='pending' and v_intent.expires_at<=now()
      then 'expired' else v_intent.status end,
    'expires_at',v_intent.expires_at,
    'completed_at',v_intent.completed_at,
    'result',v_intent.completion_result
  );
end
$$;

create or replace function public.customer_cancel_redemption_intent_v89(
  p_intent uuid,p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_identity uuid:=app.v31_current_identity();
  v_intent public.customer_redemption_intents_v89%rowtype;
  v_status text;
begin
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode='22023';
  end if;
  select * into v_intent from public.customer_redemption_intents_v89 intent
  where intent.id=p_intent and intent.identity_id=v_identity
    and intent.auth_user_id=auth.uid() for update;
  if not found then
    raise exception 'redemption intent was not found' using errcode='42501';
  end if;
  if v_intent.status='completed' then
    raise exception 'completed redemption cannot be cancelled' using errcode='23514';
  end if;
  v_status:=case when v_intent.status='pending' and v_intent.expires_at<=now()
    then 'expired' else v_intent.status end;
  if v_status='expired' and v_intent.status='pending' then
    perform set_config('app.v89_redemption_intent_id',v_intent.id::text,true);
    update public.customer_redemption_intents_v89 set status='expired'
      where id=v_intent.id;
    perform set_config('app.v89_redemption_intent_id','',true);
    insert into public.customer_redemption_events_v89(
      intent_id,business_id,actor,event_type,idempotency_key,detail
    ) values(v_intent.id,v_intent.business_id,auth.uid(),'intent_expired',
      p_idempotency_key,jsonb_build_object('expired_at',v_intent.expires_at))
    on conflict(intent_id,event_type,idempotency_key) do nothing;
  elsif v_status='pending' then
    perform set_config('app.v89_redemption_intent_id',v_intent.id::text,true);
    update public.customer_redemption_intents_v89 set status='cancelled'
      where id=v_intent.id;
    perform set_config('app.v89_redemption_intent_id','',true);
    insert into public.customer_redemption_events_v89(
      intent_id,business_id,actor,event_type,idempotency_key,detail
    ) values(v_intent.id,v_intent.business_id,auth.uid(),'intent_cancelled',
      p_idempotency_key,'{}'::jsonb)
    on conflict(intent_id,event_type,idempotency_key) do nothing;
    v_status:='cancelled';
  end if;
  return jsonb_build_object('intent_id',v_intent.id,'status',v_status,
    'expires_at',v_intent.expires_at);
end
$$;

create or replace function app.v89_redemption_intent_guard()
returns trigger language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if tg_op='DELETE' or nullif(current_setting(
    'app.v89_redemption_intent_id',true),'') is distinct from old.id::text then
    raise exception 'redemption intent evidence is protected' using errcode='23001';
  end if;
  if (new.id,new.business_id,new.identity_id,new.auth_user_id,new.client_id,
      new.redemption_kind,new.reward_id,new.quoted_program_id,
      new.quoted_config_version_id,new.quoted_reward_version_id,
      new.quoted_points_spent,new.quoted_credit_cents,new.quoted_terms,
      new.token_hash,new.idempotency_key,new.request_hash,new.expires_at,
      new.created_at)
     is distinct from
    (old.id,old.business_id,old.identity_id,old.auth_user_id,old.client_id,
      old.redemption_kind,old.reward_id,old.quoted_program_id,
      old.quoted_config_version_id,old.quoted_reward_version_id,
      old.quoted_points_spent,old.quoted_credit_cents,old.quoted_terms,
      old.token_hash,old.idempotency_key,old.request_hash,old.expires_at,
      old.created_at) then
    raise exception 'redemption intent provenance is immutable' using errcode='23001';
  end if;
  return new;
end
$$;
create trigger trg_customer_redemption_intents_v89_guard
before update or delete on public.customer_redemption_intents_v89
for each row execute function app.v89_redemption_intent_guard();

create trigger trg_customer_redemption_events_v89_immutable
before update or delete on public.customer_redemption_events_v89
for each row execute function app.v31_evidence_immutable_guard();
create trigger trg_platform_access_audit_v89_immutable
before update or delete on public.platform_access_audit_v89
for each row execute function app.v31_evidence_immutable_guard();

create or replace function public.platform_list_my_access_v89()
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_role text:=app.v89_platform_role();v_perms jsonb;
begin
  if v_role is null then raise exception 'platform access is required' using errcode='42501';end if;
  v_perms:=case when v_role='super_admin' then jsonb_build_object('*','rw')
    else coalesce((select module_perms from public.platform_access_grants_v89
      where user_id=auth.uid() and active),'{}'::jsonb) end;
  return jsonb_build_object('role',v_role,'module_perms',v_perms,
    'scope',case when v_role='sales_staff' then 'own_created_or_assigned' else 'all' end);
end
$$;

create or replace function public.platform_list_access_grants_v89()
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_result jsonb;
begin
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode='42501';
  end if;
  select jsonb_build_object('items',coalesce(jsonb_agg(jsonb_build_object(
    'user_id',grant_row.user_id,'email',auth_user.email,'role',grant_row.role,
    'module_perms',grant_row.module_perms,'active',grant_row.active,
    'updated_at',grant_row.updated_at
  ) order by lower(auth_user.email),grant_row.user_id),'[]'::jsonb))
  into v_result from public.platform_access_grants_v89 grant_row
  join auth.users auth_user on auth_user.id=grant_row.user_id;
  return v_result;
end
$$;

create or replace function public.platform_upsert_access_grant_v89(
  p_user uuid,p_role text,p_module_perms jsonb,p_active boolean default true
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_before public.platform_access_grants_v89%rowtype;
  v_after public.platform_access_grants_v89%rowtype;v_event text;
begin
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode='42501';
  end if;
  if p_user is null or p_role not in ('admin','sales_staff')
     or jsonb_typeof(p_module_perms)<>'object'
     or jsonb_path_exists(p_module_perms,'$.* ? (@ != "r" && @ != "rw")') then
    raise exception 'invalid platform access grant' using errcode='22023';
  end if;
  if exists(
    select 1 from jsonb_object_keys(p_module_perms) permission_key
    where permission_key not in(
      '*','overview','onboarding','firms','reports','billing','commissions',
      'sectors','automation'
    )
  ) then
    raise exception 'unknown platform module permission' using errcode='22023';
  end if;
  if p_role='sales_staff' and (
    coalesce(p_module_perms->>'onboarding','')<>'rw'
    or coalesce(p_module_perms->>'reports','') not in ('r','rw')
  ) then
    raise exception 'sales staff require onboarding rw and reports read access'
      using errcode='22023';
  end if;
  if p_role='sales_staff' and not exists(
    select 1 from public.platform_consultants consultant
    where consultant.user_id=p_user and consultant.active
  ) then
    raise exception 'sales staff require an active consultant profile'
      using errcode='22023';
  end if;
  if p_role='admin' and not(p_module_perms?'*') then
    -- Explicit per-module maps are supported; an empty admin map is not.
    if (select count(*) from jsonb_object_keys(p_module_perms))=0 then
      raise exception 'admin module permissions must not be empty' using errcode='22023';
    end if;
  end if;
  select * into v_before from public.platform_access_grants_v89
    where user_id=p_user for update;
  insert into public.platform_access_grants_v89(
    user_id,role,module_perms,active,created_by,updated_by
  ) values(
    p_user,p_role,p_module_perms,coalesce(p_active,true),auth.uid(),auth.uid()
  ) on conflict(user_id) do update set
    role=excluded.role,module_perms=excluded.module_perms,active=excluded.active,
    updated_by=auth.uid(),updated_at=now()
  returning * into v_after;
  v_event:=case when v_before.user_id is null then 'grant_created'
    when not v_after.active then 'grant_disabled' else 'grant_updated' end;
  insert into public.platform_access_audit_v89(
    subject_user_id,actor,event_type,before_value,after_value
  ) values(p_user,auth.uid(),v_event,
    case when v_before.user_id is null then null else to_jsonb(v_before) end,
    to_jsonb(v_after));
  return jsonb_build_object('user_id',v_after.user_id,'role',v_after.role,
    'module_perms',v_after.module_perms,'active',v_after.active,
    'updated_at',v_after.updated_at);
end
$$;

create or replace function public.platform_create_my_prospect_v89(
  p_company_name text,p_sector_key text default null,p_phone text default null,
  p_email text default null,p_contact_name text default null
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_name text:=nullif(btrim(p_company_name),'');
  v_sector text:=nullif(btrim(p_sector_key),'');
  v_phone text:=nullif(btrim(p_phone),'');
  v_email text:=nullif(lower(btrim(p_email)),'');
  v_contact text:=nullif(btrim(p_contact_name),'');
  v_company uuid;v_prospect uuid;v_consultant uuid;
begin
  if not app.v89_platform_can('onboarding','rw') then
    raise exception 'platform onboarding write access is required' using errcode='42501';
  end if;
  if length(coalesce(v_name,'')) not between 2 and 200
     or (v_phone is null and v_email is null) then
    raise exception 'company name and a phone or email are required' using errcode='22023';
  end if;
  if v_email is not null and v_email!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'invalid company email' using errcode='22023';
  end if;
  if v_sector is not null and not exists(
    select 1 from public.sector_profiles profile where profile.sector_key=v_sector
  ) then
    raise exception 'unknown sector' using errcode='22023';
  end if;
  if app.v89_platform_role()='sales_staff' then
    v_consultant:=app.v89_sales_consultant_id();
    if v_consultant is null then
      raise exception 'active sales consultant profile is required' using errcode='42501';
    end if;
  end if;
  insert into public.sme_companies(
    trading_name,sector_key,phone,email
  ) values(v_name,v_sector,v_phone,v_email)
  returning id into v_company;
  insert into public.sme_prospects(
    company_id,current_stage_key,assigned_consultant_id,created_by,updated_by
  ) values(v_company,'new_lead',v_consultant,auth.uid(),auth.uid())
  returning id into v_prospect;
  if v_phone is not null or v_email is not null then
    insert into public.sme_prospect_contacts(
      prospect_id,full_name,email,phone,is_primary
    ) values(v_prospect,coalesce(v_contact,v_name),v_email,v_phone,true);
  end if;
  insert into public.sme_prospect_stage_history(
    prospect_id,to_stage_key,reason_detail,actor
  ) values(v_prospect,'new_lead','created in scoped v89 platform console',auth.uid());
  if v_consultant is not null then
    insert into public.sme_prospect_assignments(
      prospect_id,consultant_id,assigned_by,reason
    ) values(v_prospect,v_consultant,auth.uid(),'self-created sales prospect');
  end if;
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(null,auth.uid(),'PLATFORM_CREATE_MY_PROSPECT_V89','sme_prospects',
    v_prospect,jsonb_build_object('company_id',v_company,'sector_key',v_sector,
      'assigned_consultant_id',v_consultant));
  return jsonb_build_object('prospect_id',v_prospect,'company_id',v_company,
    'stage_key','new_lead','version',1,'scope',
    case when app.v89_platform_role()='sales_staff'
      then 'own_created_or_assigned' else 'all' end);
end
$$;

create or replace function public.platform_list_my_firms_v89(
  p_search text default null,p_limit integer default 100
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_limit integer:=least(greatest(coalesce(p_limit,100),1),250);
  v_result jsonb;
begin
  if not (
    app.v89_platform_can('overview','r')
    or app.v89_platform_can('onboarding','r')
    or app.v89_platform_can('firms','r')
    or app.v89_platform_can('reports','r')
  ) then
    raise exception 'platform firm-list read access is required' using errcode='42501';
  end if;
  select jsonb_build_object('items',coalesce(jsonb_agg(row_data.payload
    order by row_data.updated_at desc,row_data.row_id desc),'[]'::jsonb),
    'scope',case when app.v89_platform_role()='sales_staff'
      then 'own_created_or_assigned' else 'all' end,
    'truncated',(select count(*)>v_limit from app.platform_firm_rows_v88(now()) all_rows
      where (
        (all_rows.prospect_id is not null
          and app.v89_prospect_in_role_scope(all_rows.prospect_id))
        or (all_rows.prospect_id is null
          and app.v89_platform_role() in ('super_admin','admin'))
      )
        and (nullif(btrim(p_search),'') is null or lower(concat_ws(' ',
          all_rows.name,all_rows.legal_name,all_rows.registration_number,
          all_rows.boss_name,all_rows.boss_email,all_rows.boss_phone))
          like '%'||lower(btrim(p_search))||'%'))
  ) into v_result
  from (
    select row_source.row_id,row_source.updated_at,to_jsonb(row_source) payload
    from app.platform_firm_rows_v88(now()) row_source
    where (
      (row_source.prospect_id is not null
        and app.v89_prospect_in_role_scope(row_source.prospect_id))
      or (row_source.prospect_id is null
        and app.v89_platform_role() in ('super_admin','admin'))
    )
      and (nullif(btrim(p_search),'') is null or lower(concat_ws(' ',
        row_source.name,row_source.legal_name,row_source.registration_number,
        row_source.boss_name,row_source.boss_email,row_source.boss_phone))
        like '%'||lower(btrim(p_search))||'%')
    order by row_source.updated_at desc,row_source.row_id desc limit v_limit
  ) row_data;
  return v_result;
end
$$;

create or replace function public.platform_move_my_prospect_stage_v89(
  p_prospect uuid,p_to_stage text,p_expected_version bigint,p_reason text default null
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_row public.sme_prospects%rowtype;v_from text;
begin
  if not app.v89_platform_can('onboarding','rw')
     or not app.v89_can_access_prospect(p_prospect) then
    raise exception 'scoped onboarding write access is required' using errcode='42501';
  end if;
  select * into v_row from public.sme_prospects where id=p_prospect for update;
  if not found or v_row.version<>p_expected_version then
    raise exception 'prospect version conflict' using errcode='40001';
  end if;
  if not exists(select 1 from public.sme_pipeline_stages where stage_key=p_to_stage) then
    raise exception 'unknown prospect stage' using errcode='22023';
  end if;
  v_from:=v_row.current_stage_key;
  update public.sme_prospects set current_stage_key=p_to_stage,
    stage_entered_at=now(),version=version+1,updated_by=auth.uid(),updated_at=now()
  where id=p_prospect returning * into v_row;
  insert into public.sme_prospect_stage_history(
    prospect_id,from_stage_key,to_stage_key,reason_detail,actor
  ) values(p_prospect,v_from,p_to_stage,nullif(btrim(p_reason),''),auth.uid());
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_row.converted_business_id,auth.uid(),'PLATFORM_MOVE_MY_PROSPECT_STAGE_V89',
    'sme_prospects',p_prospect,jsonb_build_object(
      'from_stage',v_from,'to_stage',p_to_stage,'version',v_row.version));
  return jsonb_build_object('prospect_id',p_prospect,'stage_key',p_to_stage,
    'version',v_row.version,'updated_at',v_row.updated_at);
end
$$;

create or replace function public.platform_generate_my_report_v89(
  p_business_ids uuid[]
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_ids uuid[];v_result jsonb;
begin
  if not app.v89_platform_can('reports','r') then
    raise exception 'platform reports access is required' using errcode='42501';
  end if;
  select coalesce(array_agg(distinct requested.id order by requested.id),'{}'::uuid[])
    into v_ids from unnest(coalesce(p_business_ids,'{}'::uuid[])) requested(id);
  if cardinality(v_ids)=0 or exists(select 1 from unnest(v_ids) id
    where not app.v89_business_in_role_scope(id)) then
    raise exception 'report contains an out-of-scope business' using errcode='42501';
  end if;
  select jsonb_build_object(
    'scope',jsonb_build_object('business_ids',to_jsonb(v_ids),
      'generated_at',now(),'currency','SGD'),
    'summary',jsonb_build_object(
      'business_count',cardinality(v_ids),
      'customer_count',(select count(*) from public.clients where business_id=any(v_ids)),
      'sales_count',(select count(*) from public.sales where business_id=any(v_ids)
        and reversal_of is null),
      'revenue_cents',coalesce((select sum(amount_cents)::bigint
        from public.sales where business_id=any(v_ids)
          and reversal_of is null and counts_as_revenue),0),
      'appointment_count',(select count(*) from public.appointments
        where business_id=any(v_ids)),
      'completed_appointments',(select count(*) from public.appointments
        where business_id=any(v_ids) and status='completed')
    ),
    'businesses',coalesce((select jsonb_agg(jsonb_build_object(
      'id',business.id,'name',business.name,'industry',business.industry,
      'customers',(select count(*) from public.clients where business_id=business.id),
      'revenue_cents',coalesce((select sum(amount_cents)::bigint
        from public.sales where business_id=business.id
          and reversal_of is null and counts_as_revenue),0)
    ) order by lower(business.name),business.id)
      from public.businesses business where business.id=any(v_ids)),'[]'::jsonb)
  ) into v_result;
  return v_result;
end
$$;

create or replace function public.platform_get_my_prospect_v89(p_prospect uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_result jsonb;
begin
  if not app.v89_platform_can('onboarding','r')
     or not app.v89_can_access_prospect(p_prospect) then
    raise exception 'scoped onboarding read access is required' using errcode='42501';
  end if;
  select jsonb_build_object(
    'prospect',to_jsonb(prospect),
    'company',to_jsonb(company),
    'contacts',coalesce((select jsonb_agg(to_jsonb(contact)
      order by contact.is_primary desc,contact.created_at,contact.id)
      from public.sme_prospect_contacts contact
      where contact.prospect_id=prospect.id and contact.active),'[]'::jsonb),
    'activities',coalesce((select jsonb_agg(to_jsonb(activity)
      order by activity.occurred_at desc,activity.id desc)
      from (select * from public.sme_prospect_activities activity_source
        where activity_source.prospect_id=prospect.id
        order by activity_source.occurred_at desc,activity_source.id desc
        limit 100) activity),'[]'::jsonb),
    'tasks',coalesce((select jsonb_agg(to_jsonb(task)
      order by task.status,task.due_at,task.id)
      from public.sme_prospect_tasks task
      where task.prospect_id=prospect.id),'[]'::jsonb)
  ) into v_result
  from public.sme_prospects prospect
  join public.sme_companies company on company.id=prospect.company_id
  where prospect.id=p_prospect;
  return v_result;
end
$$;

create or replace function public.platform_add_my_prospect_activity_v89(
  p_prospect uuid,p_activity_type text,p_summary text,p_detail text default null,
  p_occurred_at timestamptz default now()
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_id uuid;v_type text:=lower(btrim(coalesce(p_activity_type,'')));
  v_summary text:=nullif(btrim(p_summary),'');
begin
  if not app.v89_platform_can('onboarding','rw')
     or not app.v89_can_access_prospect(p_prospect) then
    raise exception 'scoped onboarding write access is required' using errcode='42501';
  end if;
  if v_type not in(
    'note','call','email','whatsapp','meeting','demo','task','document_sent',
    'proposal_sent','contract_sent','payment','onboarding_session','npu_attempt',
    'system'
  ) or length(coalesce(v_summary,'')) not between 2 and 240
     or p_occurred_at>now()+interval '5 minutes' then
    raise exception 'invalid prospect activity' using errcode='22023';
  end if;
  insert into public.sme_prospect_activities(
    prospect_id,consultant_id,activity_type,summary,detail,occurred_at,created_by
  ) values(
    p_prospect,app.v89_sales_consultant_id(),v_type,v_summary,
    nullif(btrim(p_detail),''),p_occurred_at,auth.uid()
  ) returning id into v_id;
  update public.sme_prospects set updated_by=auth.uid(),updated_at=now(),
    version=version+1 where id=p_prospect;
  return jsonb_build_object('activity_id',v_id,'prospect_id',p_prospect,
    'status','created');
end
$$;

create or replace function public.platform_create_my_prospect_task_v89(
  p_prospect uuid,p_title text,p_due_at timestamptz
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_id uuid;v_title text:=nullif(btrim(p_title),'');
begin
  if not app.v89_platform_can('onboarding','rw')
     or not app.v89_can_access_prospect(p_prospect) then
    raise exception 'scoped onboarding write access is required' using errcode='42501';
  end if;
  if length(coalesce(v_title,'')) not between 2 and 240 or p_due_at<=now() then
    raise exception 'invalid prospect task' using errcode='22023';
  end if;
  insert into public.sme_prospect_tasks(
    prospect_id,title,due_at,assigned_consultant_id,created_by
  ) values(
    p_prospect,v_title,p_due_at,app.v89_sales_consultant_id(),auth.uid()
  ) returning id into v_id;
  return jsonb_build_object('task_id',v_id,'prospect_id',p_prospect,
    'status','open');
end
$$;

create or replace function public.platform_complete_my_prospect_task_v89(
  p_task uuid,p_outcome text
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_task public.sme_prospect_tasks%rowtype;
  v_outcome text:=nullif(btrim(p_outcome),'');
begin
  select * into v_task from public.sme_prospect_tasks where id=p_task for update;
  if not found or not app.v89_platform_can('onboarding','rw')
     or not app.v89_can_access_prospect(v_task.prospect_id) then
    raise exception 'scoped onboarding write access is required' using errcode='42501';
  end if;
  if length(coalesce(v_outcome,''))<2 then
    raise exception 'task outcome is required' using errcode='22023';
  end if;
  if v_task.status='completed' then
    return jsonb_build_object('task_id',p_task,'status','completed',
      'completed_at',v_task.completed_at);
  end if;
  update public.sme_prospect_tasks set status='completed',outcome=v_outcome,
    completed_at=now() where id=p_task returning * into v_task;
  return jsonb_build_object('task_id',p_task,'status','completed',
    'completed_at',v_task.completed_at);
end
$$;

create or replace function public.platform_assign_prospect_v89(
  p_prospect uuid,p_consultant uuid,p_reason text default null
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_role text:=app.v89_platform_role();
begin
  if v_role not in ('super_admin','admin')
     or not app.v89_platform_can('onboarding','rw') then
    raise exception 'platform admin onboarding write access is required'
      using errcode='42501';
  end if;
  if p_consultant is not null and not exists(
    select 1 from public.platform_consultants consultant
    where consultant.id=p_consultant and consultant.active
  ) then raise exception 'active consultant is required' using errcode='22023';end if;
  perform 1 from public.sme_prospects where id=p_prospect for update;
  if not found then raise exception 'prospect was not found' using errcode='22023';end if;
  update public.sme_prospects set assigned_consultant_id=p_consultant,
    updated_by=auth.uid(),updated_at=now(),version=version+1
    where id=p_prospect;
  insert into public.sme_prospect_assignments(
    prospect_id,consultant_id,assigned_by,reason
  ) values(p_prospect,p_consultant,auth.uid(),nullif(btrim(p_reason),''));
  return jsonb_build_object('prospect_id',p_prospect,
    'assigned_consultant_id',p_consultant,'status','assigned');
end
$$;

create or replace function public.platform_list_assignment_consultants_v89()
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not app.v89_platform_can('onboarding','r') then
    raise exception 'platform onboarding read access is required'
      using errcode='42501';
  end if;
  return jsonb_build_object('items',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',consultant.id,'display_name',consultant.display_name
    ) order by lower(consultant.display_name),consultant.id)
    from public.platform_consultants consultant where consultant.active
  ),'[]'::jsonb));
end
$$;

create or replace function public.platform_lookup_access_user_v89(p_query text)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_query text:=lower(nullif(btrim(p_query),''));v_items jsonb;
  v_count integer;
begin
  if not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if length(coalesce(v_query,''))<3 or length(v_query)>160 then
    raise exception 'enter at least 3 characters' using errcode='22023';
  end if;
  with matches as (
    select auth_user.id user_id,auth_user.email,
      nullif(btrim(coalesce(auth_user.raw_user_meta_data->>'full_name',
        auth_user.raw_user_meta_data->>'name','')),'') display_name,
      case when lower(coalesce(auth_user.email,''))=v_query then 0 else 1 end rank
    from auth.users auth_user
    where lower(coalesce(auth_user.email,''))=v_query
       or lower(coalesce(auth_user.email,'')) like '%'||v_query||'%'
       or lower(coalesce(auth_user.raw_user_meta_data->>'full_name',
         auth_user.raw_user_meta_data->>'name','')) like '%'||v_query||'%'
    order by rank,lower(coalesce(auth_user.email,'')),auth_user.id limit 20
  )
  select count(*)::integer,coalesce(jsonb_agg(jsonb_build_object(
    'user_id',match.user_id,'email',match.email,
    'display_name',match.display_name
  ) order by match.rank,lower(coalesce(match.email,'')),match.user_id),'[]'::jsonb)
  into v_count,v_items from matches match;
  return jsonb_build_object(
    'status',case when v_count=0 then 'not_found'
      when v_count=1 then 'matched' else 'ambiguous' end,
    'items',v_items
  );
end
$$;

create or replace function public.platform_list_sector_firms_v89()
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not app.v89_platform_can('sectors','r') then
    raise exception 'platform sectors read access is required'
      using errcode='42501';
  end if;
  return jsonb_build_object('items',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',business.id,'name',business.name,'industry',business.industry,
      'enabled_modules',to_jsonb(business.enabled_modules),
      'source_prospect_id',business.source_prospect_id
    ) order by lower(business.name),business.id)
    from public.businesses business
  ),'[]'::jsonb));
end
$$;

create or replace function public.platform_list_commission_consultants_v89()
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not app.v89_platform_can('commissions','r') then
    raise exception 'platform commissions read access is required'
      using errcode='42501';
  end if;
  return jsonb_build_object('consultants',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',consultant.id,'user_id',consultant.user_id,
      'display_name',consultant.display_name,'tier',consultant.tier,
      'employment_started_on',consultant.employment_started_on,
      'active',consultant.active,'departed_at',consultant.departed_at
    ) order by consultant.active desc,lower(consultant.display_name),consultant.id)
    from public.platform_consultants consultant
  ),'[]'::jsonb));
end
$$;

create or replace function public.platform_upsert_commission_consultant_v89(
  p_consultant uuid,p_user uuid,p_display_name text,p_tier text,
  p_employment_started_on date,p_active boolean
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_row public.platform_consultants%rowtype;
  v_name text:=nullif(btrim(p_display_name),'');
begin
  if not app.v89_platform_can('commissions','rw') then
    raise exception 'platform commissions write access is required'
      using errcode='42501';
  end if;
  if p_user is null or length(coalesce(v_name,'')) not between 2 and 120
     or p_tier not in ('senior','junior')
     or p_employment_started_on is null then
    raise exception 'valid consultant details are required' using errcode='22023';
  end if;
  if p_consultant is null then
    insert into public.platform_consultants(
      user_id,display_name,tier,employment_started_on,active,departed_at,created_by
    ) values(
      p_user,v_name,p_tier,p_employment_started_on,coalesce(p_active,true),
      case when p_active is false then now() end,v_actor
    ) returning * into v_row;
  else
    if p_active is false then
      perform app.forfeit_consultant_core_v78(
        p_consultant,now(),
        'directory deactivation via v89 commissions RPC',v_actor
      );
    end if;
    update public.platform_consultants set
      user_id=p_user,display_name=v_name,tier=p_tier,
      employment_started_on=p_employment_started_on,
      active=coalesce(p_active,active),
      departed_at=case
        when p_active is true then null
        when p_active is false then coalesce(departed_at,now())
        else departed_at end,
      updated_at=now()
    where id=p_consultant returning * into v_row;
    if not found then
      raise exception 'platform consultant was not found' using errcode='22023';
    end if;
  end if;
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    null,v_actor,'PLATFORM_CONSULTANT_UPSERT_V89','platform_consultants',
    v_row.id,to_jsonb(v_row)-'user_id'
  );
  return jsonb_build_object('consultant',to_jsonb(v_row));
end
$$;

create or replace function app.v89_platform_billing_rows(
  p_business uuid,p_limit integer
)
returns jsonb language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select coalesce(jsonb_agg(to_jsonb(rows) order by rows.updated_at desc),'[]'::jsonb)
  from (
    select subscription.business_id,business.name business_name,
      subscription.status,subscription.payment_status,subscription.currency,
      subscription.billing_cadence cadence,subscription.cadence_months,
      subscription.billing_provider provider,subscription.provider_customer_id,
      subscription.provider_subscription_id,
      app.billable_seats(subscription.business_id) billable_seats,
      subscription.period_subtotal_cents,subscription.period_tax_cents,
      subscription.period_total_cents,subscription.next_payment_at,
      subscription.last_paid_at,subscription.last_paid_invoice_id,
      subscription.cancel_at_period_end,subscription.updated_at,
      (select count(*) from public.billing_provider_events event
        where event.business_id=subscription.business_id
          and event.processing_status='failed') failed_event_count
    from public.subscriptions subscription
    join public.businesses business on business.id=subscription.business_id
    where p_business is null or subscription.business_id=p_business
    order by subscription.updated_at desc limit p_limit
  ) rows
$$;

create or replace function app.v89_platform_billing_reconciliation(
  p_run uuid,p_limit integer
)
returns jsonb language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select jsonb_build_object(
    'runs',coalesce((
      select jsonb_agg(to_jsonb(runs) order by runs.started_at desc)
      from (
        select id,run_mode,status,cursor_start,cursor_end,started_at,finished_at,summary
        from public.billing_reconciliation_runs
        where p_run is null or id=p_run
        order by started_at desc limit p_limit
      ) runs
    ),'[]'::jsonb),
    'items',coalesce((
      select jsonb_agg(to_jsonb(items) order by items.created_at desc)
      from (
        select run_id,business_id,object_type,provider_object_id,result,
          expected_digest,actual_digest,detail,created_at
        from public.billing_reconciliation_items
        where p_run is not null and run_id=p_run
        order by created_at desc limit 500
      ) items
    ),'[]'::jsonb)
  )
$$;

create or replace function public.platform_get_billing_v89(
  p_business uuid default null,p_limit integer default 100
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not app.v89_platform_can('billing','r') then
    raise exception 'platform billing read access is required' using errcode='42501';
  end if;
  if p_limit not between 1 and 250 then
    raise exception 'limit must be between 1 and 250' using errcode='22023';
  end if;
  return app.v89_platform_billing_rows(p_business,p_limit);
end
$$;

create or replace function public.platform_get_billing_reconciliation_v89(
  p_run uuid default null,p_limit integer default 50
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not app.v89_platform_can('billing','r') then
    raise exception 'platform billing read access is required' using errcode='42501';
  end if;
  if p_limit not between 1 and 200 then
    raise exception 'limit must be between 1 and 200' using errcode='22023';
  end if;
  return app.v89_platform_billing_reconciliation(p_run,p_limit);
end
$$;

create or replace function public.platform_get_automation_billing_v89(
  p_business uuid default null,p_limit integer default 100
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not app.v89_platform_can('automation','r') then
    raise exception 'platform automation read access is required' using errcode='42501';
  end if;
  if p_limit not between 1 and 250 then
    raise exception 'limit must be between 1 and 250' using errcode='22023';
  end if;
  return app.v89_platform_billing_rows(p_business,p_limit);
end
$$;

create or replace function public.platform_get_automation_reconciliation_v89(
  p_run uuid default null,p_limit integer default 50
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not app.v89_platform_can('automation','r') then
    raise exception 'platform automation read access is required' using errcode='42501';
  end if;
  if p_limit not between 1 and 200 then
    raise exception 'limit must be between 1 and 200' using errcode='22023';
  end if;
  return app.v89_platform_billing_reconciliation(p_run,p_limit);
end
$$;

-- v78 predates delegated platform admins and hard-coded super-admin checks.
-- Rebind only the exact commission console RPC inventory to the explicit v89
-- commissions permission; economic bodies and signatures remain unchanged.
do $v89_commission_rebind$
declare
  v_signature text;v_definition text;
  v_needle constant text:='app.is_super_admin()';
  v_replacement constant text:='app.v89_platform_can(''commissions'',''rw'')';
  v_occurrences integer;
begin
  foreach v_signature in array array[
    'public.attribute_consultant_v78(uuid,uuid,uuid,timestamptz,text)',
    'public.create_consultant_commission_policy_v78(text,integer,integer,integer,timestamptz,text)',
    'public.forfeit_consultant_open_commission_v78(uuid,timestamptz,text)',
    'public.approve_consultant_accrual_v78(uuid,text)',
    'public.create_consultant_payout_batch_v78(text,text)',
    'public.add_consultant_payout_line_v78(uuid,uuid,integer)',
    'public.approve_consultant_payout_batch_v78(uuid)',
    'public.record_consultant_payout_v78(uuid,integer,text,timestamptz)'
  ] loop
    select pg_get_functiondef(to_regprocedure(v_signature)) into v_definition;
    v_occurrences:=(length(v_definition)-length(replace(
      v_definition,v_needle,'')))/length(v_needle);
    if v_occurrences<>1 then
      raise exception 'unexpected commission RPC predecessor % (needle occurrences: %)',
        v_signature,v_occurrences;
    end if;
    execute replace(v_definition,v_needle,v_replacement);
  end loop;

  foreach v_signature in array array[
    'public.get_consultant_commission_policies_v78()',
    'public.get_consultant_commission_dashboard_v78(uuid,integer)'
  ] loop
    select pg_get_functiondef(to_regprocedure(v_signature)) into v_definition;
    v_occurrences:=(length(v_definition)-length(replace(
      v_definition,v_needle,'')))/length(v_needle);
    if v_occurrences<>1 then
      raise exception 'unexpected commission reader predecessor % (needle occurrences: %)',
        v_signature,v_occurrences;
    end if;
    execute replace(
      v_definition,v_needle,'app.v89_platform_can(''commissions'',''r'')'
    );
  end loop;
end
$v89_commission_rebind$;

-- Seed every existing active consultant as scoped sales staff. This does not
-- broaden their old permissions: v89 readers/writers still enforce own/assigned.
insert into public.platform_access_grants_v89(
  user_id,role,module_perms,active,created_by,updated_by
)
select consultant.user_id,'sales_staff',
  '{"onboarding":"rw","firms":"r","reports":"r"}'::jsonb,true,
  coalesce((select super_admin.user_id from public.super_admins super_admin
    order by super_admin.created_at,super_admin.user_id limit 1),consultant.user_id),
  coalesce((select super_admin.user_id from public.super_admins super_admin
    order by super_admin.created_at,super_admin.user_id limit 1),consultant.user_id)
from public.platform_consultants consultant
where consultant.active
on conflict(user_id) do nothing;

comment on function public.customer_join_business_from_qr_v89(text,uuid)
  is 'Authenticated QR-only customer enrolment. Raw merchant token is never stored.';
comment on function public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)
  is 'Creates a quoted five-minute classic or catalog pending intent without mutating value.';
comment on function public.merchant_scan_redemption_qr_v89(uuid,text,uuid)
  is 'Merchant-scanned atomic completion through the canonical loyalty redeemer.';

revoke all on function app.v89_sha256(text) from public,anon,authenticated;
revoke all on function app.v89_redemption_token(uuid,uuid,text,uuid,uuid)
  from public,anon,authenticated;
revoke all on function app.v89_platform_role() from public,anon,authenticated;
revoke all on function app.v89_platform_can(text,text) from public,anon,authenticated;
revoke all on function app.v89_business_module_enabled(uuid,text)
  from public,anon,authenticated;
revoke all on function app.v89_sales_consultant_id() from public,anon,authenticated;
revoke all on function app.v89_prospect_in_role_scope(uuid)
  from public,anon,authenticated;
revoke all on function app.v89_business_in_role_scope(uuid)
  from public,anon,authenticated;
revoke all on function app.v89_can_access_prospect(uuid) from public,anon,authenticated;
revoke all on function app.v89_can_access_business(uuid) from public,anon,authenticated;
revoke all on function app.v89_platform_billing_rows(uuid,integer)
  from public,anon,authenticated;
revoke all on function app.v89_platform_billing_reconciliation(uuid,integer)
  from public,anon,authenticated;
revoke all on function app.v89_customer_booking_gate() from public,anon,authenticated;
revoke all on function app.v89_customer_appointment_change_gate()
  from public,anon,authenticated;
revoke all on function app.v89_redemption_intent_guard() from public,anon,authenticated;
revoke all on function app.is_platform_operator_v75()
  from public,anon,authenticated;

revoke all on function public.business_set_customer_capabilities_v89(
  uuid,boolean,boolean,boolean)
  from public,anon,authenticated;
revoke all on function public.business_get_customer_capabilities_v89(uuid)
  from public,anon,authenticated;
revoke all on function public.business_create_customer_join_qr_v89(uuid,timestamptz)
  from public,anon,authenticated;
revoke all on function public.customer_join_business_from_qr_v89(text,uuid)
  from public,anon,authenticated;
revoke all on function public.customer_list_programmes_v89()
  from public,anon,authenticated;
revoke all on function public.get_business_public(text)
  from public,anon,authenticated;
revoke all on function public.customer_get_business_actions_v89(uuid)
  from public,anon,authenticated;
revoke all on function public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)
  from public,anon,authenticated;
revoke all on function public.merchant_scan_redemption_qr_v89(uuid,text,uuid)
  from public,anon,authenticated;
revoke all on function public.customer_get_redemption_intent_v89(uuid)
  from public,anon,authenticated;
revoke all on function public.customer_cancel_redemption_intent_v89(uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.platform_list_my_access_v89()
  from public,anon,authenticated;
revoke all on function public.platform_list_access_grants_v89()
  from public,anon,authenticated;
revoke all on function public.platform_upsert_access_grant_v89(uuid,text,jsonb,boolean)
  from public,anon,authenticated;
revoke all on function public.platform_create_my_prospect_v89(
  text,text,text,text,text) from public,anon,authenticated;
revoke all on function public.platform_list_my_firms_v89(text,integer)
  from public,anon,authenticated;
revoke all on function public.platform_move_my_prospect_stage_v89(uuid,text,bigint,text)
  from public,anon,authenticated;
revoke all on function public.platform_generate_my_report_v89(uuid[])
  from public,anon,authenticated;
revoke all on function public.platform_get_my_prospect_v89(uuid)
  from public,anon,authenticated;
revoke all on function public.platform_add_my_prospect_activity_v89(
  uuid,text,text,text,timestamptz) from public,anon,authenticated;
revoke all on function public.platform_create_my_prospect_task_v89(
  uuid,text,timestamptz) from public,anon,authenticated;
revoke all on function public.platform_complete_my_prospect_task_v89(uuid,text)
  from public,anon,authenticated;
revoke all on function public.platform_assign_prospect_v89(uuid,uuid,text)
  from public,anon,authenticated;
revoke all on function public.platform_list_assignment_consultants_v89()
  from public,anon,authenticated;
revoke all on function public.platform_lookup_access_user_v89(text)
  from public,anon,authenticated;
revoke all on function public.platform_list_sector_firms_v89()
  from public,anon,authenticated;
revoke all on function public.platform_list_commission_consultants_v89()
  from public,anon,authenticated;
revoke all on function public.platform_upsert_commission_consultant_v89(
  uuid,uuid,text,text,date,boolean) from public,anon,authenticated;
revoke all on function public.platform_get_billing_v89(uuid,integer)
  from public,anon,authenticated;
revoke all on function public.platform_get_billing_reconciliation_v89(uuid,integer)
  from public,anon,authenticated;
revoke all on function public.platform_get_automation_billing_v89(uuid,integer)
  from public,anon,authenticated;
revoke all on function public.platform_get_automation_reconciliation_v89(uuid,integer)
  from public,anon,authenticated;
revoke all on function public.internal_public_join_page_v89(text)
  from public,anon,authenticated;
revoke all on function public.internal_public_join_v89(text,text,text,text,boolean)
  from public,anon,authenticated;

grant execute on function public.business_set_customer_capabilities_v89(
  uuid,boolean,boolean,boolean)
  to authenticated;
grant execute on function public.business_get_customer_capabilities_v89(uuid)
  to authenticated;
grant execute on function public.business_create_customer_join_qr_v89(uuid,timestamptz)
  to authenticated;
grant execute on function public.customer_join_business_from_qr_v89(text,uuid)
  to authenticated;
grant execute on function public.customer_list_programmes_v89() to authenticated;
grant execute on function public.get_business_public(text) to anon,authenticated;
grant execute on function public.customer_get_business_actions_v89(uuid) to authenticated;
grant execute on function public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)
  to authenticated;
grant execute on function public.merchant_scan_redemption_qr_v89(uuid,text,uuid)
  to authenticated;
grant execute on function public.customer_get_redemption_intent_v89(uuid)
  to authenticated;
grant execute on function public.customer_cancel_redemption_intent_v89(uuid,uuid)
  to authenticated;
grant execute on function public.platform_list_my_access_v89() to authenticated;
grant execute on function public.platform_list_access_grants_v89() to authenticated;
grant execute on function public.platform_upsert_access_grant_v89(uuid,text,jsonb,boolean)
  to authenticated;
grant execute on function public.platform_create_my_prospect_v89(
  text,text,text,text,text) to authenticated;
grant execute on function public.platform_list_my_firms_v89(text,integer)
  to authenticated;
grant execute on function public.platform_move_my_prospect_stage_v89(uuid,text,bigint,text)
  to authenticated;
grant execute on function public.platform_generate_my_report_v89(uuid[])
  to authenticated;
grant execute on function public.platform_get_my_prospect_v89(uuid)
  to authenticated;
grant execute on function public.platform_add_my_prospect_activity_v89(
  uuid,text,text,text,timestamptz) to authenticated;
grant execute on function public.platform_create_my_prospect_task_v89(
  uuid,text,timestamptz) to authenticated;
grant execute on function public.platform_complete_my_prospect_task_v89(uuid,text)
  to authenticated;
grant execute on function public.platform_assign_prospect_v89(uuid,uuid,text)
  to authenticated;
grant execute on function public.platform_list_assignment_consultants_v89()
  to authenticated;
grant execute on function public.platform_lookup_access_user_v89(text)
  to authenticated;
grant execute on function public.platform_list_sector_firms_v89()
  to authenticated;
grant execute on function public.platform_list_commission_consultants_v89()
  to authenticated;
grant execute on function public.platform_upsert_commission_consultant_v89(
  uuid,uuid,text,text,date,boolean) to authenticated;
grant execute on function public.platform_get_billing_v89(uuid,integer)
  to authenticated;
grant execute on function public.platform_get_billing_reconciliation_v89(uuid,integer)
  to authenticated;
grant execute on function public.platform_get_automation_billing_v89(uuid,integer)
  to authenticated;
grant execute on function public.platform_get_automation_reconciliation_v89(uuid,integer)
  to authenticated;
grant execute on function public.internal_public_join_page_v89(text)
  to service_role;
grant execute on function public.internal_public_join_v89(text,text,text,text,boolean)
  to service_role;

commit;
