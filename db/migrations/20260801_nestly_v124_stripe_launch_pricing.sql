-- NESTLY V124 - STRIPE LAUNCH PRICING AND CUSTOMER CAPACITY
--
-- This is an overlay on the reviewed v77 Stripe transport. It deliberately
-- keeps historical seat fields/catalogue intact while making staff access
-- included for the launch offer. Stripe remains payment truth.

begin;

-- -------------------------------------------------------------------------
-- 0. Publish the exact 1 August legal pages without rewriting acceptance.
--    The optional marketing scope is unchanged; existing v92 evidence stays
--    valid, while future choices bind the newly published Privacy Notice.
-- -------------------------------------------------------------------------

lock table app.customer_legal_documents in share row exclusive mode;

do $v124_legal_manifest$
begin
  if not exists (
    select 1 from app.customer_legal_documents d
     where d.document_key='terms' and d.active and (
       (d.document_version='2026-07-26' and d.document_sha256='12aff22e35449a889c75d7cb3705a0f7c58a5de333a8b25a81128e89b76b4618')
       or (d.document_version='2026-08-01' and d.document_sha256='e581bbd1f20e9b8b1958f75f100950c50d20a9810d82fce8467b1ed74859643f')
     )
  ) or not exists (
    select 1 from app.customer_legal_documents d
     where d.document_key='privacy' and d.active and (
       (d.document_version='2026-07-28' and d.document_sha256='994400cadc703134d9c8bd3868fe054f94e37153c47c2d2e688064bdc75138c9')
       or (d.document_version='2026-08-01' and d.document_sha256='08ee39b8c678552699cf2438b7c0803a5ee441b6426ddee3418e88f04a29ba84')
     )
  ) then
    raise exception 'customer legal manifest conflicts with reviewed V124 pages'
      using errcode='23505';
  end if;

  update app.customer_legal_documents
     set document_version='2026-08-01',
         document_sha256='e581bbd1f20e9b8b1958f75f100950c50d20a9810d82fce8467b1ed74859643f',
         published_at=timestamptz '2026-08-01 00:00:00+08:00',
         updated_at=timestamptz '2026-08-01 00:00:00+08:00'
   where document_key='terms' and active
     and document_version='2026-07-26'
     and document_sha256='12aff22e35449a889c75d7cb3705a0f7c58a5de333a8b25a81128e89b76b4618';

  update app.customer_legal_documents
     set document_version='2026-08-01',
         document_sha256='08ee39b8c678552699cf2438b7c0803a5ee441b6426ddee3418e88f04a29ba84',
         published_at=timestamptz '2026-08-01 00:00:00+08:00',
         updated_at=timestamptz '2026-08-01 00:00:00+08:00'
   where document_key='privacy' and active
     and document_version='2026-07-28'
     and document_sha256='994400cadc703134d9c8bd3868fe054f94e37153c47c2d2e688064bdc75138c9';

  if (select count(*) from app.customer_legal_documents d
       where d.active and d.document_version='2026-08-01' and (
         (d.document_key='terms' and d.document_sha256='e581bbd1f20e9b8b1958f75f100950c50d20a9810d82fce8467b1ed74859643f')
         or (d.document_key='privacy' and d.document_sha256='08ee39b8c678552699cf2438b7c0803a5ee441b6426ddee3418e88f04a29ba84')
       ))<>2 then
    raise exception 'reviewed V124 legal manifest was not published exactly'
      using errcode='23514';
  end if;
end
$v124_legal_manifest$;

create or replace function app.v92_prepare_platform_marketing_preference()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.platform_marketing_opted_in then
    new.marketing_scope_version := '2026-07-28-selected-partners-v1';
    new.marketing_privacy_sha256 := '08ee39b8c678552699cf2438b7c0803a5ee441b6426ddee3418e88f04a29ba84';
  else
    new.marketing_scope_version := null;
    new.marketing_privacy_sha256 := null;
  end if;
  return new;
end;
$$;

create or replace function app.v92_capture_platform_marketing_consent()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_source text := coalesce(nullif(current_setting('app.v92_marketing_source',true),''),'signup');
  v_idempotency_key text := nullif(current_setting('app.v92_marketing_idempotency_key',true),'');
  v_privacy app.customer_legal_documents%rowtype;
begin
  if tg_op='UPDATE' and new.platform_marketing_opted_in is not distinct from old.platform_marketing_opted_in
     and v_idempotency_key is null then return new; end if;
  if v_source not in ('signup','customer_profile') then
    raise exception 'invalid platform marketing consent source' using errcode='22023';
  end if;
  select * into v_privacy from app.customer_legal_documents d
   where d.document_key='privacy' and d.active for share;
  if not found or v_privacy.document_version<>'2026-08-01'
     or v_privacy.document_sha256<>'08ee39b8c678552699cf2438b7c0803a5ee441b6426ddee3418e88f04a29ba84' then
    raise exception 'platform marketing consent document is unavailable' using errcode='0A000';
  end if;
  insert into public.customer_platform_marketing_consent_events(
    identity_id,auth_user_id,opted_in,scope_version,privacy_version,
    privacy_sha256,source,idempotency_key,request_hash
  ) values (
    new.identity_id,new.auth_user_id,new.platform_marketing_opted_in,
    '2026-07-28-selected-partners-v1',v_privacy.document_version,
    v_privacy.document_sha256,v_source,v_idempotency_key,
    app.v31_sha256_hex('v92.platform-marketing:'||new.auth_user_id::text||':'
      ||new.platform_marketing_opted_in::text||':'||v_privacy.document_sha256||':'
      ||coalesce(v_idempotency_key,'signup'))
  );
  return new;
end;
$$;

create or replace function public.customer_get_platform_marketing_preference()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_actor uuid:=auth.uid();
begin
  if v_actor is null then raise exception 'authenticated customer session required' using errcode='28000'; end if;
  return coalesce((select jsonb_build_object(
    'opted_in',p.platform_marketing_opted_in
      and p.marketing_scope_version='2026-07-28-selected-partners-v1'
      and p.marketing_privacy_sha256 in (
        '994400cadc703134d9c8bd3868fe054f94e37153c47c2d2e688064bdc75138c9',
        '08ee39b8c678552699cf2438b7c0803a5ee441b6426ddee3418e88f04a29ba84'
      ) and exists (select 1 from public.customer_platform_marketing_consent_events e
        where e.identity_id=p.identity_id and e.auth_user_id=v_actor and e.opted_in
          and e.scope_version=p.marketing_scope_version
          and e.privacy_sha256=p.marketing_privacy_sha256),
    'scope_version','2026-07-28-selected-partners-v1','updated_at',p.updated_at)
    from public.customer_registration_preferences p where p.auth_user_id=v_actor),
    jsonb_build_object('opted_in',false,'scope_version','2026-07-28-selected-partners-v1','updated_at',null));
end;
$$;

revoke all on function app.v92_prepare_platform_marketing_preference() from public,anon,authenticated;
revoke all on function app.v92_capture_platform_marketing_consent() from public,anon,authenticated;
revoke all on function public.customer_get_platform_marketing_preference() from public,anon,authenticated;
grant execute on function public.customer_get_platform_marketing_preference() to authenticated;

-- -------------------------------------------------------------------------
-- 1. Monthly cadence and the isolated V124 commercial catalogue.
-- -------------------------------------------------------------------------

alter table public.subscriptions
  drop constraint if exists subscriptions_cadence_pair_check;
alter table public.subscriptions
  drop constraint if exists subscriptions_billing_cadence_check;
alter table public.subscriptions
  drop constraint if exists subscriptions_cadence_months_check;
alter table public.subscriptions
  add constraint subscriptions_billing_cadence_check check (
    billing_cadence is null or billing_cadence in (
      'monthly','quarterly','half_yearly','annual'
    )
  ),
  add constraint subscriptions_cadence_months_check check (
    cadence_months is null or cadence_months in (1,3,6,12)
  ),
  add constraint subscriptions_cadence_pair_check check (
    (billing_cadence is null and cadence_months is null)
    or (billing_cadence = 'monthly' and cadence_months = 1)
    or (billing_cadence = 'quarterly' and cadence_months = 3)
    or (billing_cadence = 'half_yearly' and cadence_months = 6)
    or (billing_cadence = 'annual' and cadence_months = 12)
  );

alter table public.billing_provider_subscriptions
  drop constraint if exists billing_provider_subscriptions_cadence_check;
alter table public.billing_provider_subscriptions
  drop constraint if exists billing_provider_subscriptions_cadence_months_check;
alter table public.billing_provider_subscriptions
  drop constraint if exists billing_provider_subscriptions_cadence_pair;
alter table public.billing_provider_subscriptions
  add constraint billing_provider_subscriptions_cadence_check check (
    cadence is null or cadence in ('monthly','quarterly','half_yearly','annual')
  ),
  add constraint billing_provider_subscriptions_cadence_months_check check (
    cadence_months is null or cadence_months in (1,3,6,12)
  ),
  add constraint billing_provider_subscriptions_cadence_pair check (
    (cadence is null and cadence_months is null)
    or (cadence = 'monthly' and cadence_months = 1)
    or (cadence = 'quarterly' and cadence_months = 3)
    or (cadence = 'half_yearly' and cadence_months = 6)
    or (cadence = 'annual' and cadence_months = 12)
  );

create or replace function app.stripe_cadence_v77(p_interval text,p_count integer)
returns text
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select case
    when p_interval = 'month' and p_count = 1 then 'monthly'
    when p_interval = 'month' and p_count = 3 then 'quarterly'
    when p_interval = 'month' and p_count = 6 then 'half_yearly'
    when (p_interval = 'year' and p_count = 1)
      or (p_interval = 'month' and p_count = 12) then 'annual'
    else null
  end
$$;
revoke all on function app.stripe_cadence_v77(text,integer)
  from public,anon,authenticated;

create table public.billing_plan_catalog_v124 (
  id uuid primary key default gen_random_uuid(),
  currency text not null default 'SGD' check (currency = 'SGD'),
  cadence text not null check (cadence in ('monthly','annual')),
  cadence_months smallint not null check (cadence_months in (1,12)),
  provider text not null default 'stripe' check (provider = 'stripe'),
  provider_base_price_id text not null unique
    check (provider_base_price_id ~ '^price_[A-Za-z0-9_]+$'),
  provider_capacity_price_id text not null unique
    check (provider_capacity_price_id ~ '^price_[A-Za-z0-9_]+$'),
  base_amount_cents integer not null,
  included_customer_capacity integer not null default 1000
    check (included_customer_capacity = 1000),
  capacity_block_size integer not null default 1000
    check (capacity_block_size = 1000),
  capacity_block_amount_cents integer not null,
  compare_at_monthly_cents integer not null default 16800
    check (compare_at_monthly_cents = 16800),
  tax_behavior text not null default 'unspecified'
    check (tax_behavior in ('inclusive','exclusive','unspecified')),
  active boolean not null default true,
  effective_from timestamptz not null default now(),
  effective_to timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint billing_plan_catalog_v124_cadence_pair check (
    (cadence = 'monthly' and cadence_months = 1
      and base_amount_cents = 14900
      and capacity_block_amount_cents = 1000)
    or
    (cadence = 'annual' and cadence_months = 12
      and base_amount_cents = 118800
      and capacity_block_amount_cents = 12000)
  ),
  constraint billing_plan_catalog_v124_distinct_prices check (
    provider_base_price_id <> provider_capacity_price_id
  ),
  constraint billing_plan_catalog_v124_window check (
    effective_to is null or effective_to > effective_from
  ),
  unique(currency,cadence,effective_from)
);
create unique index billing_plan_catalog_v124_one_active_uk
  on public.billing_plan_catalog_v124(currency,cadence)
  where active and effective_to is null;

alter table public.billing_plan_catalog_v124 enable row level security;
revoke all privileges on table public.billing_plan_catalog_v124
  from public,anon,authenticated;

-- -------------------------------------------------------------------------
-- 2. Provider-confirmed capacity terms and immutable guarantee evidence.
-- -------------------------------------------------------------------------

create table public.billing_subscription_terms_v124 (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  provider_subscription_id text not null,
  pricing_model text not null default 'v124_customer_capacity'
    check (pricing_model = 'v124_customer_capacity'),
  cadence text not null check (cadence in ('monthly','annual')),
  customer_capacity integer not null check (
    customer_capacity >= 1000 and customer_capacity % 1000 = 0
  ),
  capacity_blocks integer not null check (capacity_blocks >= 1),
  provider_base_price_id text not null,
  provider_capacity_item_id text,
  provider_capacity_price_id text,
  provider_event_created_at timestamptz not null,
  last_event_id text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint billing_subscription_terms_v124_capacity check (
    customer_capacity = capacity_blocks * 1000
  )
);

create table public.billing_money_back_windows_v124 (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  first_paid_invoice_id text not null,
  first_paid_at timestamptz not null,
  money_back_request_until timestamptz not null,
  source_event_id text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint billing_money_back_windows_v124_exact check (
    money_back_request_until = first_paid_at + interval '30 days'
  )
);

alter table public.billing_subscription_terms_v124 enable row level security;
alter table public.billing_money_back_windows_v124 enable row level security;
revoke all privileges on table public.billing_subscription_terms_v124
  from public,anon,authenticated;
revoke all privileges on table public.billing_money_back_windows_v124
  from public,anon,authenticated;

create or replace function app.guard_money_back_window_v124()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'money-back request evidence is immutable'
      using errcode='restrict_violation';
  end if;
  if new.first_paid_at >= old.first_paid_at
     or new.money_back_request_until <> new.first_paid_at + interval '30 days'
     or new.business_id <> old.business_id then
    raise exception 'money-back request evidence may only move to an earlier paid invoice'
      using errcode='restrict_violation';
  end if;
  return new;
end
$$;
revoke all on function app.guard_money_back_window_v124()
  from public,anon,authenticated;

create trigger billing_money_back_windows_v124_guard
  before update or delete on public.billing_money_back_windows_v124
  for each row execute function app.guard_money_back_window_v124();

create or replace function app.capture_money_back_window_v124()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.paid_normalized and new.paid_at is not null and exists(
    select 1 from public.billing_subscription_terms_v124 terms
     where terms.business_id=new.business_id
       and terms.provider_subscription_id=new.provider_subscription_id
  ) then
    insert into public.billing_money_back_windows_v124(
      business_id,first_paid_invoice_id,first_paid_at,
      money_back_request_until,source_event_id
    ) values (
      new.business_id,new.provider_invoice_id,new.paid_at,
      new.paid_at + interval '30 days',new.last_event_id
    )
    on conflict(business_id) do update
      set first_paid_invoice_id=excluded.first_paid_invoice_id,
          first_paid_at=excluded.first_paid_at,
          money_back_request_until=excluded.money_back_request_until,
          source_event_id=excluded.source_event_id,
          updated_at=now()
      where excluded.first_paid_at
            < billing_money_back_windows_v124.first_paid_at;
  end if;
  return new;
end
$$;
revoke all on function app.capture_money_back_window_v124()
  from public,anon,authenticated;

create trigger billing_provider_invoices_money_back_v124
  after insert or update of paid_normalized,paid_at
  on public.billing_provider_invoices
  for each row execute function app.capture_money_back_window_v124();

create or replace function app.backfill_money_back_window_v124()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_invoice public.billing_provider_invoices%rowtype;
begin
  select invoice.* into v_invoice
    from public.billing_provider_invoices invoice
   where invoice.business_id=new.business_id
     and invoice.provider_subscription_id=new.provider_subscription_id
     and invoice.paid_normalized and invoice.paid_at is not null
   order by invoice.paid_at,invoice.provider_event_created_at,
            invoice.provider_invoice_id
   limit 1;
  if found then
    insert into public.billing_money_back_windows_v124(
      business_id,first_paid_invoice_id,first_paid_at,
      money_back_request_until,source_event_id
    ) values (
      new.business_id,v_invoice.provider_invoice_id,v_invoice.paid_at,
      v_invoice.paid_at + interval '30 days',v_invoice.last_event_id
    )
    on conflict(business_id) do update
      set first_paid_invoice_id=excluded.first_paid_invoice_id,
          first_paid_at=excluded.first_paid_at,
          money_back_request_until=excluded.money_back_request_until,
          source_event_id=excluded.source_event_id,
          updated_at=now()
      where excluded.first_paid_at
            < billing_money_back_windows_v124.first_paid_at;
  end if;
  return null;
end
$$;
revoke all on function app.backfill_money_back_window_v124()
  from public,anon,authenticated;

create trigger billing_subscription_terms_money_backfill_v124
  after insert or update of provider_subscription_id
  on public.billing_subscription_terms_v124
  for each row execute function app.backfill_money_back_window_v124();

alter table public.billing_provider_subscription_items
  drop constraint if exists billing_provider_subscription_items_item_role_check;
alter table public.billing_provider_subscription_items
  add constraint billing_provider_subscription_items_item_role_check
  check (item_role in ('base','seat','capacity','other'));

create or replace function app.classify_billing_item_v124()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_role text;
begin
  select case
    when catalog.provider_base_price_id = new.provider_price_id then 'base'
    when catalog.provider_capacity_price_id = new.provider_price_id then 'capacity'
  end into v_role
    from public.billing_plan_catalog_v124 catalog
   where new.provider_price_id in (
     catalog.provider_base_price_id,catalog.provider_capacity_price_id
   )
   order by catalog.effective_from desc limit 1;
  if v_role is not null then new.item_role := v_role; end if;
  return new;
end
$$;
revoke all on function app.classify_billing_item_v124()
  from public,anon,authenticated;

create trigger billing_provider_items_classify_v124
  before insert or update of provider_price_id,item_role
  on public.billing_provider_subscription_items
  for each row execute function app.classify_billing_item_v124();

create or replace function app.project_billing_terms_v124()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_subscription_id text := coalesce(new.provider_subscription_id,old.provider_subscription_id);
  v_business uuid;
  v_cadence text;
  v_base public.billing_provider_subscription_items%rowtype;
  v_capacity public.billing_provider_subscription_items%rowtype;
  v_catalog public.billing_plan_catalog_v124%rowtype;
  v_blocks integer;
begin
  select subscription.business_id,subscription.cadence
    into v_business,v_cadence
    from public.billing_provider_subscriptions subscription
   where subscription.provider_subscription_id=v_subscription_id;
  if v_business is null or v_cadence not in ('monthly','annual') then return null; end if;

  select * into v_base from public.billing_provider_subscription_items item
   where item.provider_subscription_id=v_subscription_id and item.item_role='base'
   order by item.updated_at desc limit 1;
  if not found then return null; end if;
  select * into v_catalog from public.billing_plan_catalog_v124 catalog
   where catalog.provider_base_price_id=v_base.provider_price_id
     and catalog.cadence=v_cadence
   order by catalog.effective_from desc limit 1;
  if not found then return null; end if;
  select * into v_capacity from public.billing_provider_subscription_items item
   where item.provider_subscription_id=v_subscription_id and item.item_role='capacity'
   order by item.updated_at desc limit 1;
  v_blocks := 1 + case when found then greatest(v_capacity.quantity,0) else 0 end;

  insert into public.billing_subscription_terms_v124(
    business_id,provider_subscription_id,cadence,customer_capacity,capacity_blocks,
    provider_base_price_id,provider_capacity_item_id,
    provider_capacity_price_id,provider_event_created_at,last_event_id
  ) values (
    v_business,v_subscription_id,v_cadence,v_blocks*1000,v_blocks,
    v_base.provider_price_id,v_capacity.provider_item_id,
    v_capacity.provider_price_id,
    greatest(v_base.provider_event_created_at,
      coalesce(v_capacity.provider_event_created_at,v_base.provider_event_created_at)),
    coalesce(v_capacity.last_event_id,v_base.last_event_id)
  )
  on conflict(business_id) do update
    set provider_subscription_id=excluded.provider_subscription_id,
        cadence=excluded.cadence,
        customer_capacity=excluded.customer_capacity,
        capacity_blocks=excluded.capacity_blocks,
        provider_base_price_id=excluded.provider_base_price_id,
        provider_capacity_item_id=excluded.provider_capacity_item_id,
        provider_capacity_price_id=excluded.provider_capacity_price_id,
        provider_event_created_at=excluded.provider_event_created_at,
        last_event_id=excluded.last_event_id,updated_at=now()
    where excluded.provider_event_created_at
          >= billing_subscription_terms_v124.provider_event_created_at;
  return null;
end
$$;
revoke all on function app.project_billing_terms_v124()
  from public,anon,authenticated;

create trigger billing_provider_items_project_terms_v124
  after insert or update or delete on public.billing_provider_subscription_items
  for each row execute function app.project_billing_terms_v124();

create or replace function app.prune_billing_provider_items_v124()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_object jsonb;
  v_subscription_id text;
  v_rank smallint;
begin
  if new.processing_status='processed'
     and old.processing_status is distinct from new.processing_status
     and new.event_type like 'customer.subscription.%' then
    v_object:=new.payload#>'{data,object}';
    v_subscription_id:=v_object->>'id';
    v_rank:=app.stripe_event_rank_v77(new.event_type);
    if v_subscription_id is not null
       and jsonb_typeof(v_object#>'{items,data}')='array'
       and not coalesce((v_object#>>'{items,has_more}')::boolean,false) then
      delete from public.billing_provider_subscription_items item
       where item.provider_subscription_id=v_subscription_id
         and item.provider_item_id not in (
           select value->>'id'
             from jsonb_array_elements(v_object#>'{items,data}')
            where nullif(value->>'id','') is not null
         )
         and (item.provider_event_created_at,item.provider_event_rank)
             <= (new.event_created_at,v_rank);
    end if;
  end if;
  return new;
end
$$;
revoke all on function app.prune_billing_provider_items_v124()
  from public,anon,authenticated;

create trigger billing_provider_events_prune_items_v124
  after update of processing_status on public.billing_provider_events
  for each row execute function app.prune_billing_provider_items_v124();

create or replace function app.enforce_customer_capacity_v124()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_capacity integer;
  v_current_customer_count integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('nestly:v124:capacity:'||new.business_id::text,0));
  select terms.customer_capacity into v_capacity
    from public.billing_subscription_terms_v124 terms
    join public.subscriptions subscription using(business_id)
   where terms.business_id=new.business_id
     and terms.pricing_model='v124_customer_capacity'
     and subscription.status in ('trialing','active','past_due','unpaid','paused');
  if v_capacity is null then return new; end if;
  select count(*)::integer into v_current_customer_count
    from public.clients client where client.business_id=new.business_id;
  if v_current_customer_count >= v_capacity then
    raise exception 'customer capacity reached; increase the subscription capacity before adding another customer'
      using errcode='check_violation';
  end if;
  return new;
end
$$;
revoke all on function app.enforce_customer_capacity_v124()
  from public,anon,authenticated;

create trigger clients_capacity_v124
  before insert on public.clients
  for each row execute function app.enforce_customer_capacity_v124();

-- -------------------------------------------------------------------------
-- 3. Audited catalogue configuration and V124 command bus.
-- -------------------------------------------------------------------------

create or replace function public.preview_billing_plan_catalog_v124(
  p_cadence text,
  p_provider_base_price_id text,
  p_provider_capacity_price_id text,
  p_tax_behavior text,
  p_effective_from timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_base integer;
  v_addon integer;
  v_hash text;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if p_cadence not in ('monthly','annual')
     or p_provider_base_price_id !~ '^price_[A-Za-z0-9_]+$'
     or p_provider_capacity_price_id !~ '^price_[A-Za-z0-9_]+$'
     or p_provider_base_price_id=p_provider_capacity_price_id
     or p_tax_behavior not in ('inclusive','exclusive','unspecified')
     or p_effective_from is null then
    raise exception 'invalid V124 Stripe price proposal' using errcode='22023';
  end if;
  v_base:=case p_cadence when 'monthly' then 14900 else 118800 end;
  v_addon:=case p_cadence when 'monthly' then 1000 else 12000 end;
  v_hash:=encode(extensions.digest(convert_to(
    'SGD'||E'\n'||p_cadence||E'\n'||p_provider_base_price_id||E'\n'
    ||p_provider_capacity_price_id||E'\n'||v_base::text||E'\n'||v_addon::text
    ||E'\n1000\n1000\n16800\n'||p_tax_behavior||E'\n'||p_effective_from::text,
    'utf8'),'sha256'),'hex');
  return jsonb_build_object(
    'currency','SGD','cadence',p_cadence,
    'base_amount_cents',v_base,'capacity_block_amount_cents',v_addon,
    'included_customer_capacity',1000,'capacity_block_size',1000,
    'compare_at_monthly_cents',16800,'tax_behavior',p_tax_behavior,
    'effective_from',p_effective_from,'confirmation_hash',v_hash
  );
end
$$;
revoke all on function public.preview_billing_plan_catalog_v124(
  text,text,text,text,timestamptz
) from public,anon,authenticated;
grant execute on function public.preview_billing_plan_catalog_v124(
  text,text,text,text,timestamptz
) to authenticated;

create or replace function public.confirm_billing_plan_catalog_v124(
  p_cadence text,
  p_provider_base_price_id text,
  p_provider_capacity_price_id text,
  p_tax_behavior text,
  p_effective_from timestamptz,
  p_confirmation_hash text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_preview jsonb;
  v_row public.billing_plan_catalog_v124%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if length(btrim(coalesce(p_reason,''))) < 8 then
    raise exception 'an audit reason is required' using errcode='22023';
  end if;
  v_preview:=public.preview_billing_plan_catalog_v124(
    p_cadence,p_provider_base_price_id,p_provider_capacity_price_id,
    p_tax_behavior,p_effective_from
  );
  if p_confirmation_hash is distinct from v_preview->>'confirmation_hash' then
    raise exception 'V124 Stripe price confirmation is stale' using errcode='22023';
  end if;
  update public.billing_plan_catalog_v124
     set active=false,effective_to=p_effective_from
   where currency='SGD' and cadence=p_cadence
     and active and effective_to is null;
  insert into public.billing_plan_catalog_v124(
    currency,cadence,cadence_months,provider_base_price_id,
    provider_capacity_price_id,base_amount_cents,
    included_customer_capacity,capacity_block_size,
    capacity_block_amount_cents,compare_at_monthly_cents,
    tax_behavior,effective_from,created_by
  ) values (
    'SGD',p_cadence,case p_cadence when 'monthly' then 1 else 12 end,
    p_provider_base_price_id,p_provider_capacity_price_id,
    case p_cadence when 'monthly' then 14900 else 118800 end,
    1000,1000,case p_cadence when 'monthly' then 1000 else 12000 end,
    16800,p_tax_behavior,p_effective_from,v_actor
  ) returning * into v_row;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (null,v_actor,'billing.v124_catalog_confirmed','billing_plan_catalog_v124',
    v_row.id,jsonb_build_object('reason',btrim(p_reason),'proposal',v_preview));
  return to_jsonb(v_row);
end
$$;
revoke all on function public.confirm_billing_plan_catalog_v124(
  text,text,text,text,timestamptz,text,text
) from public,anon,authenticated;
grant execute on function public.confirm_billing_plan_catalog_v124(
  text,text,text,text,timestamptz,text,text
) to authenticated;

create or replace function public.get_billing_plan_catalog_v124()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(rows) order by rows.effective_from desc)
    from (
      select id,currency,cadence,cadence_months,provider_base_price_id,
             provider_capacity_price_id,base_amount_cents,
             included_customer_capacity,capacity_block_size,
             capacity_block_amount_cents,compare_at_monthly_cents,
             tax_behavior,active,effective_from,effective_to,created_at
        from public.billing_plan_catalog_v124
       order by effective_from desc limit 100
    ) rows
  ),'[]'::jsonb);
end
$$;
revoke all on function public.get_billing_plan_catalog_v124()
  from public,anon,authenticated;
grant execute on function public.get_billing_plan_catalog_v124()
  to authenticated;

alter table public.billing_commands
  add column if not exists pricing_model text,
  add column if not exists requested_customer_capacity integer,
  add column if not exists billing_catalog_id_v124 uuid
    references public.billing_plan_catalog_v124(id) on delete restrict;
alter table public.billing_commands
  drop constraint if exists billing_commands_command_type_check;
alter table public.billing_commands
  drop constraint if exists billing_commands_requested_cadence_check;
alter table public.billing_commands
  drop constraint if exists billing_commands_v124_catalog_check;
alter table public.billing_commands
  add constraint billing_commands_command_type_check check (
    command_type in (
      'create_checkout','create_portal','change_cadence','change_capacity',
      'cancel_at_period_end','resume'
    )
  ),
  add constraint billing_commands_requested_cadence_check check (
    requested_cadence is null or requested_cadence in (
      'monthly','quarterly','half_yearly','annual'
    )
  ),
  add constraint billing_commands_pricing_model_check check (
    pricing_model is null or pricing_model='v124_customer_capacity'
  ),
  add constraint billing_commands_customer_capacity_check check (
    requested_customer_capacity is null or (
      requested_customer_capacity >= 1000
      and requested_customer_capacity % 1000 = 0
    )
  ),
  add constraint billing_commands_v124_catalog_check check (
    pricing_model is distinct from 'v124_customer_capacity'
    or command_type not in ('create_checkout','change_cadence','change_capacity')
    or billing_catalog_id_v124 is not null
  );

create or replace function public.request_billing_command_v124(
  p_business uuid,
  p_command_type text,
  p_cadence text,
  p_customer_capacity integer,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_fingerprint text;
  v_command public.billing_commands%rowtype;
  v_current_customer_count integer;
  v_existing_capacity integer;
  v_catalog public.billing_plan_catalog_v124%rowtype;
begin
  if v_actor is null
     or not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'active owner or super-admin access is required'
      using errcode='42501';
  end if;
  if p_command_type not in (
      'create_checkout','create_portal','change_cadence','change_capacity',
      'cancel_at_period_end','resume'
    ) or p_idempotency_key is null then
    raise exception 'invalid billing command' using errcode='22023';
  end if;
  if p_command_type in ('create_checkout','change_cadence','change_capacity') then
    if p_cadence not in ('monthly','annual')
       or p_customer_capacity < 1000
       or p_customer_capacity % 1000 <> 0 then
      raise exception 'canonical cadence and customer capacity are required'
        using errcode='22023';
    end if;
    select count(*)::integer into v_current_customer_count
      from public.clients client where client.business_id=p_business;
    if p_customer_capacity < greatest(1000,
         ceil(v_current_customer_count::numeric/1000)::integer*1000) then
      raise exception 'selected capacity is below the current customer count'
        using errcode='22023';
    end if;
    select * into v_catalog
      from public.billing_plan_catalog_v124 catalog
       where catalog.currency='SGD' and catalog.cadence=p_cadence
         and catalog.active and catalog.effective_from<=now()
         and (catalog.effective_to is null or catalog.effective_to>now())
       order by catalog.effective_from desc limit 1;
    if not found then
      raise exception 'active V124 Stripe price catalog entry was not found'
        using errcode='22023';
    end if;
    if p_command_type in ('change_cadence','change_capacity') then
      select terms.customer_capacity into v_existing_capacity
        from public.billing_subscription_terms_v124 terms
       where terms.business_id=p_business;
      if p_command_type='change_capacity' and (
           v_existing_capacity is null
           or p_customer_capacity<=v_existing_capacity
         ) then
        raise exception 'capacity changes must be an increase'
          using errcode='22023';
      elsif p_command_type='change_cadence'
            and v_existing_capacity is not null
            and p_customer_capacity<v_existing_capacity then
        raise exception 'billing-cycle changes cannot decrease customer capacity'
          using errcode='22023';
      end if;
    end if;
  elsif p_cadence is not null or p_customer_capacity is not null then
    raise exception 'cadence and capacity are not valid for this command'
      using errcode='22023';
  end if;

  v_fingerprint:=encode(extensions.digest(convert_to(
    p_business::text||E'\n'||p_command_type||E'\n'||coalesce(p_cadence,'')
    ||E'\n'||coalesce(p_customer_capacity::text,'')
    ||E'\nv124_customer_capacity','utf8'
  ),'sha256'),'hex');
  select * into v_command from public.billing_commands
   where business_id=p_business and command_type=p_command_type
     and idempotency_key=p_idempotency_key;
  if found then
    if v_command.request_fingerprint<>v_fingerprint then
      raise exception 'billing command idempotency key conflicts with another request'
        using errcode='22023';
    end if;
  else
    insert into public.billing_commands(
      business_id,command_type,requested_cadence,pricing_model,
      requested_customer_capacity,billing_catalog_id_v124,
      idempotency_key,request_fingerprint,requested_by
    ) values (
      p_business,p_command_type,p_cadence,'v124_customer_capacity',
      p_customer_capacity,v_catalog.id,p_idempotency_key,v_fingerprint,v_actor
    ) returning * into v_command;
  end if;
  return jsonb_build_object(
    'command_id',v_command.id,'status',v_command.status,
    'command_type',v_command.command_type,'cadence',v_command.requested_cadence,
    'requested_customer_capacity',v_command.requested_customer_capacity,
    'redirect_url',v_command.redirect_url,'requested_at',v_command.requested_at
  );
end
$$;
revoke all on function public.request_billing_command_v124(
  uuid,text,text,integer,uuid
) from public,anon,authenticated;
grant execute on function public.request_billing_command_v124(
  uuid,text,text,integer,uuid
) to authenticated;

create or replace function public.claim_billing_command_v124(
  p_command uuid,
  p_actor uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_command public.billing_commands%rowtype;
  v_subscription public.subscriptions%rowtype;
  v_terms public.billing_subscription_terms_v124%rowtype;
  v_catalog public.billing_plan_catalog_v124%rowtype;
  v_recovery_required boolean:=false;
  v_current_customer_count integer;
  v_capacity integer;
  v_blocks integer;
begin
  select * into v_command from public.billing_commands
   where id=p_command and requested_by=p_actor for update;
  if not found then
    raise exception 'billing command was not found for this actor'
      using errcode='42501';
  end if;
  if v_command.pricing_model is distinct from 'v124_customer_capacity' then
    return public.claim_billing_command_v77(p_command,p_actor);
  end if;
  if v_command.status in ('completed','failed','canceled') then
    return jsonb_build_object(
      'command_id',v_command.id,'status',v_command.status,
      'command_type',v_command.command_type,
      'provider_object_id',v_command.provider_object_id,
      'redirect_url',v_command.redirect_url,'error_code',v_command.error_code,
      'error_message',v_command.error_message,'pricing_model',v_command.pricing_model
    );
  end if;
  v_recovery_required:=v_command.status in ('processing','uncertain');
  update public.billing_commands set status='processing'
   where id=v_command.id and status in ('pending','uncertain')
   returning * into v_command;
  if not found then
    select * into strict v_command from public.billing_commands where id=p_command;
  end if;
  select * into strict v_subscription from public.subscriptions
   where business_id=v_command.business_id;
  select * into v_terms from public.billing_subscription_terms_v124
   where business_id=v_command.business_id;
  select count(*)::integer into v_current_customer_count
    from public.clients client where client.business_id=v_command.business_id;

  if v_command.requested_cadence is not null then
    select * into v_catalog from public.billing_plan_catalog_v124 catalog
     where catalog.id=v_command.billing_catalog_id_v124
       and catalog.currency='SGD'
       and catalog.cadence=v_command.requested_cadence;
    if not found then
      raise exception 'snapshotted V124 Stripe price catalog entry was not found'
        using errcode='22023';
    end if;
  end if;
  v_capacity:=coalesce(v_command.requested_customer_capacity,v_terms.customer_capacity);
  if v_capacity is not null and (
       v_capacity<greatest(1000,ceil(v_current_customer_count::numeric/1000)::integer*1000)
       or v_capacity%1000<>0
     ) then
    raise exception 'selected capacity is below the current customer count'
      using errcode='22023';
  end if;
  if v_command.command_type in ('change_cadence','change_capacity')
     and v_terms.business_id is not null and (
       v_capacity<v_terms.customer_capacity
       or (v_command.command_type='change_capacity'
           and v_capacity=v_terms.customer_capacity
           and not v_recovery_required)
     ) then
    raise exception 'subscription changes cannot decrease or replay customer capacity'
      using errcode='22023';
  end if;
  v_blocks:=case when v_capacity is null then null else v_capacity/1000 end;

  return jsonb_build_object(
    'command_id',v_command.id,'status',v_command.status,
    'command_type',v_command.command_type,'business_id',v_command.business_id,
    'pricing_model','v124_customer_capacity',
    'requested_cadence',v_command.requested_cadence,
    'requested_customer_capacity',v_capacity,
    'current_customer_count',v_current_customer_count,
    'capacity_blocks',v_blocks,'extra_capacity_blocks',greatest(v_blocks-1,0),
    'provider_idempotency_key','nestly:v124:billing-command:'||v_command.id::text,
    'recovery_required',v_recovery_required,
    'prior_provider_object_id',v_command.provider_object_id,
    'prior_redirect_url',v_command.redirect_url,
    'prior_error_code',v_command.error_code,
    'currency',v_subscription.currency,
    'provider_customer_id',v_subscription.provider_customer_id,
    'provider_subscription_id',v_subscription.provider_subscription_id,
    'provider_base_item_id',v_subscription.provider_base_item_id,
    'provider_capacity_item_id',v_terms.provider_capacity_item_id,
    'provider_base_price_id',v_catalog.provider_base_price_id,
    'provider_capacity_price_id',v_catalog.provider_capacity_price_id,
    'base_amount_cents',v_catalog.base_amount_cents,
    'capacity_block_amount_cents',v_catalog.capacity_block_amount_cents,
    'tax_behavior',v_catalog.tax_behavior
  );
end
$$;
revoke all on function public.claim_billing_command_v124(uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.claim_billing_command_v124(uuid,uuid)
  to service_role;

-- -------------------------------------------------------------------------
-- 4. Finite owner reader. Staff access is included; no staff count is billed.
-- -------------------------------------------------------------------------

create or replace function public.get_business_billing_v124(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_base jsonb;
  v_current_customer_count integer;
begin
  if auth.uid() is null
     or not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'active owner or super-admin access is required'
      using errcode='42501';
  end if;
  v_base:=public.get_business_billing_v77(p_business);
  select count(*)::integer into v_current_customer_count
    from public.clients client where client.business_id=p_business;
  return v_base || jsonb_build_object(
    'pricing_model','v124_customer_capacity',
    'current_customer_count',v_current_customer_count,
    'staff_billing',false,
    'staff_access_note','Staff access is included; use individual logins and roles.',
    'terms',(select to_jsonb(terms) from public.billing_subscription_terms_v124 terms
      where terms.business_id=p_business),
    'money_back_window',(select to_jsonb(window_row)
      from public.billing_money_back_windows_v124 window_row
      where window_row.business_id=p_business),
    'plans',coalesce((
      select jsonb_agg(to_jsonb(plan_rows) order by
        case plan_rows.cadence when 'annual' then 0 else 1 end)
      from (
        select cadence,cadence_months,base_amount_cents,
               included_customer_capacity,capacity_block_size,
               capacity_block_amount_cents,compare_at_monthly_cents,
               tax_behavior
          from public.billing_plan_catalog_v124 catalog
         where currency='SGD' and active and effective_from<=now()
           and (effective_to is null or effective_to>now())
      ) plan_rows
    ),'[]'::jsonb),
    'included_modules',jsonb_build_array(
      'Customer CRM and QR signup','Loyalty points, stamps and rewards',
      'Birthday benefits and referrals','Appointments, team schedule and waitlist',
      'Quick Earn and sales','Packages, memberships and gift cards',
      'Customer wallet, history and redemption','Promotions and AI-assisted promotion copy',
      'Feedback and Google review handoff','Configured notifications',
      'Profitability and operational reports','Branches, roles and permissions',
      'English, Simplified Chinese and Malay business UI'
    ),
    'exclusions',jsonb_build_array(
      'Stripe payment processing fees','Usage-priced external messaging',
      'Custom integrations','Platform-only administration',
      'Disabled or unconfigured modules'
    )
  );
end
$$;
revoke all on function public.get_business_billing_v124(uuid)
  from public,anon,authenticated;
grant execute on function public.get_business_billing_v124(uuid)
  to authenticated;

comment on table public.billing_plan_catalog_v124 is
  'V124 launch pricing; SGD 168 is comparison metadata only and never a charge.';
comment on table public.billing_money_back_windows_v124 is
  'First provider-paid invoice fixes the exact 30-day money-back request window.';
comment on function public.request_billing_command_v124(uuid,text,text,integer,uuid) is
  'Owner/super-admin V124 command request binding cadence and customer capacity.';

commit;
