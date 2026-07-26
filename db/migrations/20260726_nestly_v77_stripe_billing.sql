-- NESTLY v77 - STRIPE-FIRST SAAS BILLING CONTROL PLANE
--
-- Forward-only review candidate. Stripe is the provider truth for collection;
-- this database remains the tenant, entitlement and audited operations truth.
-- No browser secret, card data, automatic access suspension or deployment is
-- introduced by this migration.

begin;

-- ---------------------------------------------------------------------------
-- 1. Canonical commercial cadence and tenant subscription projection.
-- ---------------------------------------------------------------------------

alter table public.subscriptions
  drop constraint if exists subscriptions_status_check;
alter table public.subscriptions
  add constraint subscriptions_status_check check (
    status in (
      'trialing','active','incomplete','incomplete_expired','past_due',
      'unpaid','paused','canceled','cancelled'
    )
  );

alter table public.subscriptions
  add column if not exists billing_provider text not null default 'manual'
    check (billing_provider in ('manual','stripe')),
  add column if not exists billing_cadence text
    check (billing_cadence in ('quarterly','half_yearly','annual')),
  add column if not exists cadence_months smallint
    check (cadence_months in (3,6,12)),
  add column if not exists provider_customer_id text,
  add column if not exists provider_subscription_id text,
  add column if not exists provider_base_item_id text,
  add column if not exists provider_seat_item_id text,
  add column if not exists provider_base_price_id text,
  add column if not exists provider_seat_price_id text,
  add column if not exists provider_seat_quantity integer
    check (provider_seat_quantity is null or provider_seat_quantity >= 0),
  add column if not exists period_subtotal_cents integer
    check (period_subtotal_cents is null or period_subtotal_cents >= 0),
  add column if not exists period_tax_cents integer
    check (period_tax_cents is null or period_tax_cents >= 0),
  add column if not exists period_total_cents integer
    check (period_total_cents is null or period_total_cents >= 0),
  add column if not exists tax_behavior text
    check (tax_behavior in ('inclusive','exclusive','unspecified')),
  add column if not exists cancel_at_period_end boolean not null default false,
  add column if not exists canceled_at timestamptz,
  add column if not exists next_payment_at timestamptz,
  add column if not exists last_paid_at timestamptz,
  add column if not exists last_paid_invoice_id text,
  add column if not exists payment_status text not null default 'not_collected'
    check (payment_status in (
      'not_collected','paid','failed','action_required','past_due'
    )),
  add column if not exists payment_event_created_at timestamptz,
  add column if not exists payment_event_rank smallint not null default 0,
  add column if not exists provider_event_created_at timestamptz,
  add column if not exists provider_event_rank smallint not null default 0;

alter table public.subscriptions
  drop constraint if exists subscriptions_cadence_pair_check;
alter table public.subscriptions
  add constraint subscriptions_cadence_pair_check check (
    (billing_cadence is null and cadence_months is null)
    or (billing_cadence = 'quarterly' and cadence_months = 3)
    or (billing_cadence = 'half_yearly' and cadence_months = 6)
    or (billing_cadence = 'annual' and cadence_months = 12)
  );
alter table public.subscriptions
  drop constraint if exists subscriptions_period_amounts_check;
alter table public.subscriptions
  add constraint subscriptions_period_amounts_check check (
    period_total_cents is null
    or (
      period_subtotal_cents is not null
      and period_tax_cents is not null
      and period_total_cents = period_subtotal_cents + period_tax_cents
    )
  );

create unique index if not exists subscriptions_provider_customer_uk
  on public.subscriptions(provider_customer_id)
  where provider_customer_id is not null;
create unique index if not exists subscriptions_provider_subscription_uk
  on public.subscriptions(provider_subscription_id)
  where provider_subscription_id is not null;

create table public.billing_price_catalog (
  id uuid primary key default gen_random_uuid(),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  cadence text not null check (cadence in ('quarterly','half_yearly','annual')),
  cadence_months smallint not null check (cadence_months in (3,6,12)),
  provider text not null default 'stripe' check (provider = 'stripe'),
  provider_base_price_id text not null,
  provider_seat_price_id text not null,
  base_amount_cents integer not null check (base_amount_cents >= 0),
  per_seat_amount_cents integer not null check (per_seat_amount_cents >= 0),
  included_seats integer not null default 1 check (included_seats >= 0),
  tax_behavior text not null check (tax_behavior in ('inclusive','exclusive','unspecified')),
  active boolean not null default true,
  effective_from timestamptz not null default now(),
  effective_to timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint billing_price_catalog_cadence_pair check (
    (cadence = 'quarterly' and cadence_months = 3)
    or (cadence = 'half_yearly' and cadence_months = 6)
    or (cadence = 'annual' and cadence_months = 12)
  ),
  constraint billing_price_catalog_window check (
    effective_to is null or effective_to > effective_from
  ),
  unique(currency,cadence,effective_from),
  unique(provider_base_price_id),
  unique(provider_seat_price_id)
);
create unique index billing_price_catalog_one_active_uk
  on public.billing_price_catalog(currency,cadence)
  where active and effective_to is null;

-- ---------------------------------------------------------------------------
-- 2. Provider projections and immutable operational evidence.
-- ---------------------------------------------------------------------------

create table public.billing_provider_customers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null unique references public.businesses(id) on delete cascade,
  provider text not null default 'stripe' check (provider = 'stripe'),
  provider_customer_id text not null unique,
  currency text check (currency is null or currency ~ '^[A-Z]{3}$'),
  livemode boolean not null,
  provider_created_at timestamptz,
  provider_event_created_at timestamptz not null,
  provider_event_rank smallint not null,
  last_event_id text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.billing_provider_subscriptions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  provider_customer_id text not null,
  provider_subscription_id text not null unique,
  status text not null check (
    status in (
      'trialing','active','incomplete','incomplete_expired','past_due',
      'unpaid','paused','canceled'
    )
  ),
  cadence text check (cadence in ('quarterly','half_yearly','annual')),
  cadence_months smallint check (cadence_months in (3,6,12)),
  currency text check (currency is null or currency ~ '^[A-Z]{3}$'),
  current_period_start timestamptz,
  current_period_end timestamptz,
  billing_cycle_anchor timestamptz,
  trial_end timestamptz,
  cancel_at_period_end boolean not null default false,
  canceled_at timestamptz,
  ended_at timestamptz,
  livemode boolean not null,
  provider_event_created_at timestamptz not null,
  provider_event_rank smallint not null,
  last_event_id text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint billing_provider_subscriptions_cadence_pair check (
    (cadence is null and cadence_months is null)
    or (cadence = 'quarterly' and cadence_months = 3)
    or (cadence = 'half_yearly' and cadence_months = 6)
    or (cadence = 'annual' and cadence_months = 12)
  )
);
create index billing_provider_subscriptions_business_idx
  on public.billing_provider_subscriptions(business_id,updated_at desc);

create table public.billing_provider_subscription_items (
  id uuid primary key default gen_random_uuid(),
  provider_subscription_id text not null
    references public.billing_provider_subscriptions(provider_subscription_id) on delete cascade,
  provider_item_id text not null unique,
  item_role text not null check (item_role in ('base','seat','other')),
  provider_price_id text not null,
  quantity integer not null check (quantity >= 0),
  unit_amount_cents integer check (unit_amount_cents is null or unit_amount_cents >= 0),
  currency text check (currency is null or currency ~ '^[A-Z]{3}$'),
  interval_name text check (interval_name is null or interval_name in ('month','year')),
  interval_count smallint check (interval_count is null or interval_count > 0),
  current_period_start timestamptz,
  current_period_end timestamptz,
  provider_event_created_at timestamptz not null,
  provider_event_rank smallint not null,
  last_event_id text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index billing_provider_subscription_items_subscription_idx
  on public.billing_provider_subscription_items(provider_subscription_id,item_role);

create table public.billing_provider_invoices (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  provider_customer_id text not null,
  provider_subscription_id text,
  provider_invoice_id text not null unique,
  provider_payment_intent_id text,
  number text,
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  collection_method text,
  status text not null check (
    status in ('draft','open','paid','void','uncollectible')
  ),
  paid_normalized boolean not null default false,
  subtotal_ex_tax_cents integer not null check (subtotal_ex_tax_cents >= 0),
  tax_cents integer not null check (tax_cents >= 0),
  total_cents integer not null check (total_cents >= 0),
  amount_due_cents integer not null check (amount_due_cents >= 0),
  amount_paid_cents integer not null check (amount_paid_cents >= 0),
  amount_remaining_cents integer not null check (amount_remaining_cents >= 0),
  net_cash_ex_tax_cents integer not null default 0 check (net_cash_ex_tax_cents >= 0),
  period_start timestamptz,
  period_end timestamptz,
  due_at timestamptz,
  next_payment_attempt_at timestamptz,
  paid_at timestamptz,
  finalized_at timestamptz,
  voided_at timestamptz,
  marked_uncollectible_at timestamptz,
  livemode boolean not null,
  provider_event_created_at timestamptz not null,
  provider_event_rank smallint not null,
  last_event_id text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint billing_provider_invoices_total_check check (
    total_cents = subtotal_ex_tax_cents + tax_cents
  ),
  constraint billing_provider_invoices_paid_truth_check check (
    (paid_normalized and status = 'paid' and paid_at is not null)
    or not paid_normalized
  )
);
create index billing_provider_invoices_business_idx
  on public.billing_provider_invoices(business_id,coalesce(paid_at,created_at) desc);
create index billing_provider_invoices_subscription_idx
  on public.billing_provider_invoices(provider_subscription_id,period_end desc);

create table public.billing_payment_attempts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  provider_invoice_id text not null
    references public.billing_provider_invoices(provider_invoice_id) on delete cascade,
  source_event_id text not null unique,
  provider_payment_intent_id text,
  provider_charge_id text,
  attempt_state text not null check (
    attempt_state in ('paid','failed','action_required')
  ),
  amount_cents integer not null check (amount_cents >= 0),
  tax_cents integer not null default 0 check (tax_cents >= 0),
  failure_code text,
  failure_message text,
  next_attempt_at timestamptz,
  occurred_at timestamptz not null,
  collection_method text,
  created_at timestamptz not null default now()
);
create index billing_payment_attempts_invoice_idx
  on public.billing_payment_attempts(provider_invoice_id,occurred_at desc);

create table public.billing_provider_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null default 'stripe' check (provider = 'stripe'),
  event_id text not null,
  event_type text not null,
  object_id text not null,
  event_created_at timestamptz not null,
  livemode boolean not null,
  api_version text,
  payload jsonb not null,
  payload_sha256 text not null check (payload_sha256 ~ '^[0-9a-f]{64}$'),
  processing_status text not null default 'pending'
    check (processing_status in ('pending','processing','processed','ignored','failed')),
  processing_attempts integer not null default 0 check (processing_attempts >= 0),
  business_id uuid references public.businesses(id) on delete set null,
  processed_at timestamptz,
  last_error text,
  received_at timestamptz not null default now(),
  unique(provider,event_id)
);
create index billing_provider_events_pending_idx
  on public.billing_provider_events(processing_status,received_at)
  where processing_status in ('pending','failed');
create index billing_provider_events_object_idx
  on public.billing_provider_events(event_type,object_id,event_created_at desc);

create table public.billing_commands (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  command_type text not null check (
    command_type in (
      'create_checkout','create_portal','change_cadence',
      'cancel_at_period_end','resume'
    )
  ),
  requested_cadence text check (
    requested_cadence in ('quarterly','half_yearly','annual')
  ),
  idempotency_key uuid not null,
  request_fingerprint text not null check (request_fingerprint ~ '^[0-9a-f]{64}$'),
  requested_by uuid not null references auth.users(id) on delete restrict,
  status text not null default 'pending'
    check (status in ('pending','processing','uncertain','completed','failed','canceled')),
  provider_object_id text,
  redirect_url text,
  error_code text,
  error_message text,
  requested_at timestamptz not null default now(),
  completed_at timestamptz,
  unique(business_id,command_type,idempotency_key)
);
create index billing_commands_pending_idx
  on public.billing_commands(status,requested_at)
  where status in ('pending','processing','uncertain');

create table public.billing_adjustments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  provider_invoice_id text,
  adjustment_type text not null check (
    adjustment_type in (
      'credit','debit','refund','chargeback','external_payment','writeoff','reversal'
    )
  ),
  subtotal_ex_tax_cents integer not null,
  tax_cents integer not null,
  total_cents integer not null,
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  source_event_id text,
  provider_object_id text,
  reversal_of uuid references public.billing_adjustments(id) on delete restrict,
  reason text not null check (length(btrim(reason)) between 3 and 1000),
  evidence_sha256 text not null check (evidence_sha256 ~ '^[0-9a-f]{64}$'),
  recorded_by uuid references auth.users(id) on delete restrict,
  occurred_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint billing_adjustments_amount_check check (
    total_cents <> 0
    and total_cents = subtotal_ex_tax_cents + tax_cents
    and case
      when adjustment_type in ('debit','external_payment')
        then total_cents > 0 and reversal_of is null
      when adjustment_type in ('credit','refund','chargeback','writeoff')
        then total_cents < 0 and reversal_of is null
      when adjustment_type = 'reversal'
        then reversal_of is not null
      else false
    end
  ),
  unique(source_event_id),
  unique(provider_object_id,adjustment_type)
);
create index billing_adjustments_business_idx
  on public.billing_adjustments(business_id,occurred_at desc);
create unique index billing_adjustments_one_reversal_uk
  on public.billing_adjustments(reversal_of)
  where reversal_of is not null;

create table public.billing_evidence (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references public.businesses(id) on delete set null,
  evidence_type text not null check (
    evidence_type in ('provider_event','adjustment','reconciliation','external_payment')
  ),
  entity_type text not null,
  entity_id text not null,
  content_sha256 text not null check (content_sha256 ~ '^[0-9a-f]{64}$'),
  external_reference text,
  recorded_by uuid references auth.users(id) on delete restrict,
  recorded_at timestamptz not null default now(),
  unique(evidence_type,entity_type,entity_id,content_sha256)
);

create table public.billing_reconciliation_runs (
  id uuid primary key default gen_random_uuid(),
  provider text not null default 'stripe' check (provider = 'stripe'),
  run_mode text not null check (run_mode in ('dry_run','apply','scheduled')),
  cursor_start text,
  cursor_end text,
  status text not null default 'running'
    check (status in ('running','partial','clean','mismatch','failed')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  summary jsonb,
  started_by uuid references auth.users(id) on delete set null,
  constraint billing_reconciliation_runs_finish_check check (
    (finished_at is null and status = 'running')
    or (finished_at is not null and status <> 'running' and summary is not null)
  )
);

create table public.billing_reconciliation_items (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.billing_reconciliation_runs(id) on delete cascade,
  business_id uuid references public.businesses(id) on delete set null,
  object_type text not null check (
    object_type in ('customer','subscription','item','invoice','payment','adjustment')
  ),
  provider_object_id text not null,
  result text not null check (result in ('match','missing_local','missing_provider','mismatch','repaired','failed')),
  expected_digest text,
  actual_digest text,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(run_id,object_type,provider_object_id)
);

create table public.billing_automation_runs (
  id uuid primary key default gen_random_uuid(),
  job_name text not null,
  idempotency_key text not null unique,
  status text not null default 'running'
    check (status in ('running','succeeded','failed')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  summary jsonb,
  constraint billing_automation_runs_finish_check check (
    (finished_at is null and status = 'running')
    or (finished_at is not null and status <> 'running' and summary is not null)
  )
);

-- No operational table is a browser write/read API. Finite readers below are
-- the only authenticated surface.
alter table public.billing_price_catalog enable row level security;
revoke all privileges on table public.billing_price_catalog from public, anon, authenticated;
alter table public.billing_provider_customers enable row level security;
revoke all privileges on table public.billing_provider_customers from public, anon, authenticated;
alter table public.billing_provider_subscriptions enable row level security;
revoke all privileges on table public.billing_provider_subscriptions from public, anon, authenticated;
alter table public.billing_provider_subscription_items enable row level security;
revoke all privileges on table public.billing_provider_subscription_items from public, anon, authenticated;
alter table public.billing_provider_invoices enable row level security;
revoke all privileges on table public.billing_provider_invoices from public, anon, authenticated;
alter table public.billing_payment_attempts enable row level security;
revoke all privileges on table public.billing_payment_attempts from public, anon, authenticated;
alter table public.billing_provider_events enable row level security;
revoke all privileges on table public.billing_provider_events from public, anon, authenticated;
alter table public.billing_commands enable row level security;
revoke all privileges on table public.billing_commands from public, anon, authenticated;
alter table public.billing_adjustments enable row level security;
revoke all privileges on table public.billing_adjustments from public, anon, authenticated;
alter table public.billing_evidence enable row level security;
revoke all privileges on table public.billing_evidence from public, anon, authenticated;
alter table public.billing_reconciliation_runs enable row level security;
revoke all privileges on table public.billing_reconciliation_runs from public, anon, authenticated;
alter table public.billing_reconciliation_items enable row level security;
revoke all privileges on table public.billing_reconciliation_items from public, anon, authenticated;
alter table public.billing_automation_runs enable row level security;
revoke all privileges on table public.billing_automation_runs from public, anon, authenticated;

-- Immutable evidence and adjustment bodies are corrected only by a new row.
create or replace function app.billing_append_only_guard_v77()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception '% is append-only', tg_table_name
    using errcode = 'restrict_violation';
end
$$;
revoke all on function app.billing_append_only_guard_v77()
  from public,anon,authenticated;

create trigger billing_adjustments_append_only
  before update or delete on public.billing_adjustments
  for each row execute function app.billing_append_only_guard_v77();
create trigger billing_evidence_append_only
  before update or delete on public.billing_evidence
  for each row execute function app.billing_append_only_guard_v77();

create or replace function app.billing_adjustment_insert_guard_v77()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_original public.billing_adjustments%rowtype;
begin
  if new.adjustment_type <> 'reversal' then
    if new.reversal_of is not null then
      raise exception 'only a reversal may reference an earlier adjustment'
        using errcode='22023';
    end if;
    return new;
  end if;
  select * into v_original
    from public.billing_adjustments where id=new.reversal_of
    for key share;
  if not found
     or v_original.business_id <> new.business_id
     or v_original.currency <> new.currency
     or v_original.provider_invoice_id is distinct from new.provider_invoice_id
     or new.subtotal_ex_tax_cents <> -v_original.subtotal_ex_tax_cents
     or new.tax_cents <> -v_original.tax_cents
     or new.total_cents <> -v_original.total_cents then
    raise exception 'reversal must exactly compensate its referenced adjustment'
      using errcode='22023';
  end if;
  return new;
end
$$;
revoke all on function app.billing_adjustment_insert_guard_v77()
  from public,anon,authenticated;
create trigger billing_adjustments_insert_guard
  before insert on public.billing_adjustments
  for each row execute function app.billing_adjustment_insert_guard_v77();

-- Event envelopes are immutable; only their processing columns may move.
create or replace function app.billing_event_envelope_guard_v77()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'billing_provider_events is append-only'
      using errcode = 'restrict_violation';
  end if;
  if (
    new.provider,new.event_id,new.event_type,new.object_id,new.event_created_at,
    new.livemode,new.api_version,new.payload,new.payload_sha256,new.received_at
  ) is distinct from (
    old.provider,old.event_id,old.event_type,old.object_id,old.event_created_at,
    old.livemode,old.api_version,old.payload,old.payload_sha256,old.received_at
  ) then
    raise exception 'billing event envelope is immutable'
      using errcode = 'restrict_violation';
  end if;
  return new;
end
$$;
revoke all on function app.billing_event_envelope_guard_v77()
  from public,anon,authenticated;
create trigger billing_provider_events_envelope_guard
  before update or delete on public.billing_provider_events
  for each row execute function app.billing_event_envelope_guard_v77();

-- ---------------------------------------------------------------------------
-- 3. Provider-event normalization.
-- ---------------------------------------------------------------------------

create or replace function app.stripe_epoch_v77(p_value jsonb)
returns timestamptz
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select case
    when p_value is null or jsonb_typeof(p_value) <> 'number' then null
    when (p_value #>> '{}')::numeric < 0 then null
    else to_timestamp((p_value #>> '{}')::double precision)
  end
$$;
revoke all on function app.stripe_epoch_v77(jsonb)
  from public,anon,authenticated;

create or replace function app.stripe_event_rank_v77(p_type text)
returns smallint
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select case p_type
    when 'checkout.session.completed' then 10
    when 'customer.subscription.created' then 20
    when 'customer.subscription.updated' then 30
    when 'customer.subscription.deleted' then 90
    when 'invoice.finalized' then 20
    when 'invoice.payment_action_required' then 35
    when 'invoice.payment_failed' then 40
    when 'invoice.marked_uncollectible' then 70
    when 'invoice.voided' then 80
    when 'invoice.paid' then 100
    when 'refund.created' then 110
    when 'charge.dispute.created' then 120
    else 0
  end::smallint
$$;
revoke all on function app.stripe_event_rank_v77(text)
  from public,anon,authenticated;

create or replace function app.stripe_cadence_v77(p_interval text,p_count integer)
returns text
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select case
    when p_interval = 'month' and p_count = 3 then 'quarterly'
    when p_interval = 'month' and p_count = 6 then 'half_yearly'
    when (p_interval = 'year' and p_count = 1)
      or (p_interval = 'month' and p_count = 12) then 'annual'
    else null
  end
$$;
revoke all on function app.stripe_cadence_v77(text,integer)
  from public,anon,authenticated;

create or replace function app.stripe_business_v77(p_payload jsonb)
returns uuid
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_object jsonb := p_payload #> '{data,object}';
  v_candidate text;
  v_customer text;
  v_subscription text;
  v_invoice text;
  v_payment_intent text;
  v_charge text;
  v_business uuid;
begin
  v_candidate := coalesce(
    v_object #>> '{metadata,business_id}',
    v_object #>> '{subscription_details,metadata,business_id}',
    v_object #>> '{parent,subscription_details,metadata,business_id}',
    v_object ->> 'client_reference_id'
  );
  if v_candidate ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     and exists (select 1 from public.businesses where id = v_candidate::uuid) then
    return v_candidate::uuid;
  end if;

  v_customer := case
    when jsonb_typeof(v_object->'customer') = 'string' then v_object->>'customer'
    else v_object#>>'{customer,id}'
  end;
  select business_id into v_business
    from public.billing_provider_customers
   where provider_customer_id = v_customer;
  if found then return v_business; end if;

  v_subscription := coalesce(
    case when jsonb_typeof(v_object->'subscription') = 'string'
         then v_object->>'subscription' else v_object#>>'{subscription,id}' end,
    v_object#>>'{parent,subscription_details,subscription}'
  );
  select business_id into v_business
    from public.billing_provider_subscriptions
   where provider_subscription_id = v_subscription;
  if found then return v_business; end if;

  v_invoice := case
    when jsonb_typeof(v_object->'invoice') = 'string' then v_object->>'invoice'
    else v_object#>>'{invoice,id}'
  end;
  select business_id into v_business
    from public.billing_provider_invoices
   where provider_invoice_id = v_invoice;
  if found then return v_business; end if;

  v_payment_intent := case
    when jsonb_typeof(v_object->'payment_intent') = 'string'
      then v_object->>'payment_intent'
    else v_object#>>'{payment_intent,id}'
  end;
  select business_id into v_business
    from public.billing_provider_invoices
   where provider_payment_intent_id = v_payment_intent
   order by paid_at desc nulls last
   limit 1;
  if found then return v_business; end if;

  v_charge := case
    when jsonb_typeof(v_object->'charge') = 'string' then v_object->>'charge'
    else v_object#>>'{charge,id}'
  end;
  select business_id into v_business
    from public.billing_payment_attempts
   where provider_charge_id = v_charge
   order by occurred_at desc
   limit 1;
  if found then return v_business; end if;

  return null;
end
$$;
revoke all on function app.stripe_business_v77(jsonb)
  from public,anon,authenticated;

create or replace function public.ingest_stripe_billing_event_v77(
  p_event_id text,
  p_event_type text,
  p_object_id text,
  p_event_created_at timestamptz,
  p_livemode boolean,
  p_payload jsonb,
  p_payload_sha256 text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_existing public.billing_provider_events%rowtype;
  v_inserted uuid;
begin
  if p_event_id !~ '^evt_[A-Za-z0-9_]+$'
     or nullif(btrim(p_event_type),'') is null
     or nullif(btrim(p_object_id),'') is null
     or p_event_created_at is null
     or p_livemode is null
     or jsonb_typeof(p_payload) <> 'object'
     or p_payload_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid Stripe event envelope' using errcode = '22023';
  end if;

  insert into public.billing_provider_events(
    event_id,event_type,object_id,event_created_at,livemode,api_version,
    payload,payload_sha256
  ) values (
    p_event_id,p_event_type,p_object_id,p_event_created_at,p_livemode,
    nullif(p_payload->>'api_version',''),p_payload,p_payload_sha256
  )
  on conflict(provider,event_id) do nothing
  returning id into v_inserted;

  if v_inserted is not null then
    return jsonb_build_object('event_id',p_event_id,'status','accepted','duplicate',false);
  end if;

  select * into strict v_existing
    from public.billing_provider_events
   where provider = 'stripe' and event_id = p_event_id;
  if v_existing.event_type <> p_event_type
     or v_existing.object_id <> p_object_id
     or v_existing.event_created_at <> p_event_created_at
     or v_existing.livemode <> p_livemode
     or v_existing.payload <> p_payload
     or v_existing.payload_sha256 <> p_payload_sha256 then
    raise exception 'Stripe event id conflicts with a different envelope'
      using errcode = '22023';
  end if;
  return jsonb_build_object(
    'event_id',p_event_id,'status',v_existing.processing_status,'duplicate',true
  );
end
$$;
revoke all on function public.ingest_stripe_billing_event_v77(
  text,text,text,timestamptz,boolean,jsonb,text
) from public,anon,authenticated;
grant execute on function public.ingest_stripe_billing_event_v77(
  text,text,text,timestamptz,boolean,jsonb,text
) to service_role;

create or replace function public.apply_stripe_billing_event_v77(p_event_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_event public.billing_provider_events%rowtype;
  v_object jsonb;
  v_business uuid;
  v_rank smallint;
  v_customer text;
  v_subscription text;
  v_invoice text;
  v_status text;
  v_interval text;
  v_interval_count integer;
  v_cadence_months integer;
  v_cadence text;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_next_attempt timestamptz;
  v_paid_at timestamptz;
  v_subtotal integer;
  v_tax integer;
  v_total integer;
  v_due integer;
  v_paid integer;
  v_remaining integer;
  v_item jsonb;
  v_item_role text;
  v_price text;
  v_attempt_state text;
  v_adjustment_total integer;
  v_adjustment_tax integer;
  v_adjustment_net integer;
  v_adjustment_invoice public.billing_provider_invoices%rowtype;
begin
  select * into v_event
    from public.billing_provider_events
   where provider = 'stripe' and event_id = p_event_id
   for update;
  if not found then
    raise exception 'Stripe event is not in the durable inbox' using errcode = '22023';
  end if;
  if v_event.processing_status in ('processed','ignored') then
    return jsonb_build_object(
      'event_id',p_event_id,'status',v_event.processing_status,'duplicate',true
    );
  end if;

  update public.billing_provider_events
     set processing_status = 'processing',
         processing_attempts = processing_attempts + 1,
         last_error = null
   where id = v_event.id;

  begin
    v_object := v_event.payload #> '{data,object}';
    v_rank := app.stripe_event_rank_v77(v_event.event_type);
    if v_rank = 0 or jsonb_typeof(v_object) <> 'object' then
      update public.billing_provider_events
         set processing_status='ignored',processed_at=now()
       where id=v_event.id;
      return jsonb_build_object('event_id',p_event_id,'status','ignored');
    end if;

    v_business := app.stripe_business_v77(v_event.payload);
    if v_business is null then
      raise exception 'Stripe event cannot be mapped to a business';
    end if;
    v_customer := case
      when jsonb_typeof(v_object->'customer') = 'string' then v_object->>'customer'
      else v_object#>>'{customer,id}'
    end;
    v_subscription := coalesce(
      case when jsonb_typeof(v_object->'subscription') = 'string'
           then v_object->>'subscription' else v_object#>>'{subscription,id}' end,
      v_object#>>'{parent,subscription_details,subscription}'
    );

    if v_customer is not null then
      if exists(
        select 1 from public.billing_provider_customers customer
         where (
           customer.provider_customer_id=v_customer
           and customer.business_id<>v_business
         ) or (
           customer.business_id=v_business
           and customer.provider_customer_id<>v_customer
         )
      ) then
        raise exception 'Stripe customer is already linked to another business';
      end if;
      insert into public.billing_provider_customers(
        business_id,provider_customer_id,currency,livemode,provider_created_at,
        provider_event_created_at,provider_event_rank,last_event_id
      ) values (
        v_business,v_customer,upper(nullif(v_object->>'currency','')),
        v_event.livemode,app.stripe_epoch_v77(v_object->'created'),
        v_event.event_created_at,v_rank,v_event.event_id
      )
      on conflict(provider_customer_id) do update
        set currency=coalesce(excluded.currency,billing_provider_customers.currency),
            provider_event_created_at=excluded.provider_event_created_at,
            provider_event_rank=excluded.provider_event_rank,
            last_event_id=excluded.last_event_id,updated_at=now()
      where (excluded.provider_event_created_at,excluded.provider_event_rank)
            >= (billing_provider_customers.provider_event_created_at,
                billing_provider_customers.provider_event_rank);
    end if;

    if v_event.event_type like 'customer.subscription.%' then
      v_subscription := v_object->>'id';
      if exists(
        select 1 from public.billing_provider_subscriptions subscription
         where subscription.provider_subscription_id=v_subscription
           and subscription.business_id<>v_business
      ) then
        raise exception 'Stripe subscription is already linked to another business';
      end if;
      v_status := case
        when v_event.event_type = 'customer.subscription.deleted' then 'canceled'
        when v_object->>'status' in (
          'trialing','active','incomplete','incomplete_expired','past_due',
          'unpaid','paused','canceled'
        ) then v_object->>'status'
        else 'incomplete'
      end;
      select item into v_item
        from jsonb_array_elements(coalesce(v_object#>'{items,data}','[]'::jsonb)) item
       order by coalesce((item->>'quantity')::integer,0) desc
       limit 1;
      v_interval := v_item#>>'{price,recurring,interval}';
      v_interval_count := nullif(v_item#>>'{price,recurring,interval_count}','')::integer;
      v_cadence := app.stripe_cadence_v77(v_interval,v_interval_count);
      v_cadence_months := case v_cadence
        when 'quarterly' then 3
        when 'half_yearly' then 6
        when 'annual' then 12
        else null
      end;
      v_period_start := coalesce(
        app.stripe_epoch_v77(v_item->'current_period_start'),
        app.stripe_epoch_v77(v_object->'current_period_start')
      );
      v_period_end := coalesce(
        app.stripe_epoch_v77(v_item->'current_period_end'),
        app.stripe_epoch_v77(v_object->'current_period_end')
      );

      insert into public.billing_provider_subscriptions(
        business_id,provider_customer_id,provider_subscription_id,status,
        cadence,cadence_months,currency,current_period_start,current_period_end,
        billing_cycle_anchor,trial_end,cancel_at_period_end,canceled_at,ended_at,
        livemode,provider_event_created_at,provider_event_rank,last_event_id
      ) values (
        v_business,v_customer,v_subscription,v_status,v_cadence,v_cadence_months,
        upper(nullif(v_object->>'currency','')),v_period_start,v_period_end,
        app.stripe_epoch_v77(v_object->'billing_cycle_anchor'),
        app.stripe_epoch_v77(v_object->'trial_end'),
        coalesce((v_object->>'cancel_at_period_end')::boolean,false),
        app.stripe_epoch_v77(v_object->'canceled_at'),
        app.stripe_epoch_v77(v_object->'ended_at'),
        v_event.livemode,v_event.event_created_at,v_rank,v_event.event_id
      )
      on conflict(provider_subscription_id) do update
        set status=excluded.status,cadence=excluded.cadence,
            cadence_months=excluded.cadence_months,currency=excluded.currency,
            current_period_start=excluded.current_period_start,
            current_period_end=excluded.current_period_end,
            billing_cycle_anchor=excluded.billing_cycle_anchor,
            trial_end=excluded.trial_end,
            cancel_at_period_end=excluded.cancel_at_period_end,
            canceled_at=excluded.canceled_at,ended_at=excluded.ended_at,
            provider_event_created_at=excluded.provider_event_created_at,
            provider_event_rank=excluded.provider_event_rank,
            last_event_id=excluded.last_event_id,updated_at=now()
      where (excluded.provider_event_created_at,excluded.provider_event_rank)
            >= (billing_provider_subscriptions.provider_event_created_at,
                billing_provider_subscriptions.provider_event_rank);

      for v_item in
        select value from jsonb_array_elements(coalesce(v_object#>'{items,data}','[]'::jsonb))
      loop
        v_price := coalesce(v_item#>>'{price,id}',v_item->>'price');
        select case
          when catalog.provider_base_price_id = v_price then 'base'
          when catalog.provider_seat_price_id = v_price then 'seat'
          else 'other'
        end into v_item_role
          from public.billing_price_catalog catalog
         where v_price in (catalog.provider_base_price_id,catalog.provider_seat_price_id)
         order by catalog.effective_from desc
         limit 1;
        v_item_role := coalesce(v_item_role,'other');
        insert into public.billing_provider_subscription_items(
          provider_subscription_id,provider_item_id,item_role,provider_price_id,
          quantity,unit_amount_cents,currency,interval_name,interval_count,
          current_period_start,current_period_end,provider_event_created_at,
          provider_event_rank,last_event_id
        ) values (
          v_subscription,v_item->>'id',v_item_role,v_price,
          coalesce((v_item->>'quantity')::integer,0),
          nullif(v_item#>>'{price,unit_amount}','')::integer,
          upper(nullif(v_item#>>'{price,currency}','')),
          v_item#>>'{price,recurring,interval}',
          nullif(v_item#>>'{price,recurring,interval_count}','')::integer,
          app.stripe_epoch_v77(v_item->'current_period_start'),
          app.stripe_epoch_v77(v_item->'current_period_end'),
          v_event.event_created_at,v_rank,v_event.event_id
        )
        on conflict(provider_item_id) do update
          set item_role=excluded.item_role,provider_price_id=excluded.provider_price_id,
              quantity=excluded.quantity,unit_amount_cents=excluded.unit_amount_cents,
              currency=excluded.currency,interval_name=excluded.interval_name,
              interval_count=excluded.interval_count,
              current_period_start=excluded.current_period_start,
              current_period_end=excluded.current_period_end,
              provider_event_created_at=excluded.provider_event_created_at,
              provider_event_rank=excluded.provider_event_rank,
              last_event_id=excluded.last_event_id,updated_at=now()
        where (excluded.provider_event_created_at,excluded.provider_event_rank)
              >= (billing_provider_subscription_items.provider_event_created_at,
                  billing_provider_subscription_items.provider_event_rank);
      end loop;

      update public.subscriptions tenant_subscription
         set billing_provider='stripe',provider_customer_id=v_customer,
             provider_subscription_id=v_subscription,status=v_status,
             billing_cadence=v_cadence,cadence_months=v_cadence_months,
             current_period_start=coalesce(v_period_start,current_period_start),
             current_period_end=coalesce(v_period_end,current_period_end),
             next_payment_at=v_period_end,
             cancel_at_period_end=coalesce((v_object->>'cancel_at_period_end')::boolean,false),
             canceled_at=app.stripe_epoch_v77(v_object->'canceled_at'),
             provider_base_item_id=(
               select item.provider_item_id
                 from public.billing_provider_subscription_items item
                where item.provider_subscription_id=v_subscription
                  and item.item_role='base'
                order by item.updated_at desc limit 1
             ),
             provider_seat_item_id=(
               select item.provider_item_id
                 from public.billing_provider_subscription_items item
                where item.provider_subscription_id=v_subscription
                  and item.item_role='seat'
                order by item.updated_at desc limit 1
             ),
             provider_base_price_id=(
               select item.provider_price_id
                 from public.billing_provider_subscription_items item
                where item.provider_subscription_id=v_subscription
                  and item.item_role='base'
                order by item.updated_at desc limit 1
             ),
             provider_seat_price_id=(
               select item.provider_price_id
                 from public.billing_provider_subscription_items item
                where item.provider_subscription_id=v_subscription
                  and item.item_role='seat'
                order by item.updated_at desc limit 1
             ),
             provider_seat_quantity=coalesce((
               select item.quantity
                 from public.billing_provider_subscription_items item
                where item.provider_subscription_id=v_subscription
                  and item.item_role='seat'
                order by item.updated_at desc limit 1
             ),0),
             provider_event_created_at=v_event.event_created_at,
             provider_event_rank=v_rank,updated_at=now()
       where tenant_subscription.business_id=v_business
         and (tenant_subscription.provider_event_created_at is null
              or (v_event.event_created_at,v_rank)
                 >= (tenant_subscription.provider_event_created_at,
                     tenant_subscription.provider_event_rank));
    end if;

    if v_event.event_type like 'invoice.%' then
      v_invoice := v_object->>'id';
      if exists(
        select 1 from public.billing_provider_invoices invoice
         where invoice.provider_invoice_id=v_invoice
           and invoice.business_id<>v_business
      ) then
        raise exception 'Stripe invoice is already linked to another business';
      end if;
      if v_subscription is not null and exists(
        select 1 from public.billing_provider_subscriptions subscription
         where subscription.provider_subscription_id=v_subscription
           and subscription.business_id<>v_business
      ) then
        raise exception 'Stripe invoice references another business subscription';
      end if;
      v_status := case
        when v_event.event_type = 'invoice.paid' then 'paid'
        when v_event.event_type = 'invoice.voided' then 'void'
        when v_event.event_type = 'invoice.marked_uncollectible' then 'uncollectible'
        when v_object->>'status' in ('draft','open','void','uncollectible')
          then v_object->>'status'
        else 'open'
      end;
      v_subtotal := greatest(coalesce(
        nullif(v_object->>'total_excluding_tax','')::integer,
        nullif(v_object->>'subtotal_excluding_tax','')::integer,
        nullif(v_object->>'subtotal','')::integer,0
      ),0);
      v_total := greatest(coalesce(nullif(v_object->>'total','')::integer,v_subtotal),0);
      v_tax := greatest(v_total-v_subtotal,0);
      v_due := greatest(coalesce(nullif(v_object->>'amount_due','')::integer,v_total),0);
      v_paid := greatest(coalesce(nullif(v_object->>'amount_paid','')::integer,0),0);
      v_remaining := greatest(coalesce(
        nullif(v_object->>'amount_remaining','')::integer,v_due-v_paid,0
      ),0);
      v_next_attempt := app.stripe_epoch_v77(v_object->'next_payment_attempt');
      v_paid_at := case when v_event.event_type='invoice.paid' then coalesce(
        app.stripe_epoch_v77(v_object#>'{status_transitions,paid_at}'),
        v_event.event_created_at
      ) end;

      insert into public.billing_provider_invoices(
        business_id,provider_customer_id,provider_subscription_id,
        provider_invoice_id,provider_payment_intent_id,number,currency,
        collection_method,status,paid_normalized,subtotal_ex_tax_cents,tax_cents,
        total_cents,amount_due_cents,amount_paid_cents,amount_remaining_cents,
        net_cash_ex_tax_cents,period_start,period_end,due_at,
        next_payment_attempt_at,paid_at,finalized_at,voided_at,
        marked_uncollectible_at,livemode,provider_event_created_at,
        provider_event_rank,last_event_id
      ) values (
        v_business,v_customer,v_subscription,v_invoice,
        case when jsonb_typeof(v_object->'payment_intent')='string'
             then v_object->>'payment_intent'
             else v_object#>>'{payment_intent,id}' end,
        v_object->>'number',upper(coalesce(nullif(v_object->>'currency',''),'SGD')),
        v_object->>'collection_method',v_status,
        v_event.event_type='invoice.paid',v_subtotal,v_tax,v_total,v_due,v_paid,
        v_remaining,
        case when v_event.event_type='invoice.paid'
             then greatest(least(v_paid,v_total)-least(v_tax,least(v_paid,v_total)),0)
             else 0 end,
        app.stripe_epoch_v77(v_object->'period_start'),
        app.stripe_epoch_v77(v_object->'period_end'),
        app.stripe_epoch_v77(v_object->'due_date'),v_next_attempt,v_paid_at,
        app.stripe_epoch_v77(v_object#>'{status_transitions,finalized_at}'),
        app.stripe_epoch_v77(v_object#>'{status_transitions,voided_at}'),
        app.stripe_epoch_v77(v_object#>'{status_transitions,marked_uncollectible_at}'),
        v_event.livemode,v_event.event_created_at,v_rank,v_event.event_id
      )
      on conflict(provider_invoice_id) do update
        set provider_payment_intent_id=coalesce(
              excluded.provider_payment_intent_id,
              billing_provider_invoices.provider_payment_intent_id
            ),
            number=coalesce(excluded.number,billing_provider_invoices.number),
            collection_method=excluded.collection_method,status=excluded.status,
            paid_normalized=excluded.paid_normalized,
            subtotal_ex_tax_cents=excluded.subtotal_ex_tax_cents,
            tax_cents=excluded.tax_cents,total_cents=excluded.total_cents,
            amount_due_cents=excluded.amount_due_cents,
            amount_paid_cents=excluded.amount_paid_cents,
            amount_remaining_cents=excluded.amount_remaining_cents,
            net_cash_ex_tax_cents=excluded.net_cash_ex_tax_cents,
            period_start=excluded.period_start,period_end=excluded.period_end,
            due_at=excluded.due_at,
            next_payment_attempt_at=excluded.next_payment_attempt_at,
            paid_at=excluded.paid_at,finalized_at=excluded.finalized_at,
            voided_at=excluded.voided_at,
            marked_uncollectible_at=excluded.marked_uncollectible_at,
            provider_event_created_at=excluded.provider_event_created_at,
            provider_event_rank=excluded.provider_event_rank,
            last_event_id=excluded.last_event_id,updated_at=now()
      where (excluded.provider_event_created_at,excluded.provider_event_rank)
            >= (billing_provider_invoices.provider_event_created_at,
                billing_provider_invoices.provider_event_rank);

      if v_event.event_type in (
        'invoice.paid','invoice.payment_failed','invoice.payment_action_required'
      ) then
        v_attempt_state := case v_event.event_type
          when 'invoice.paid' then 'paid'
          when 'invoice.payment_failed' then 'failed'
          else 'action_required'
        end;
        insert into public.billing_payment_attempts(
          business_id,provider_invoice_id,source_event_id,
          provider_payment_intent_id,provider_charge_id,attempt_state,
          amount_cents,tax_cents,failure_code,failure_message,next_attempt_at,
          occurred_at,collection_method
        ) values (
          v_business,v_invoice,v_event.event_id,
          case when jsonb_typeof(v_object->'payment_intent')='string'
               then v_object->>'payment_intent'
               else v_object#>>'{payment_intent,id}' end,
          v_object#>>'{charge,id}',v_attempt_state,
          case when v_attempt_state='paid' then v_paid else v_due end,
          v_tax,v_object#>>'{last_finalization_error,code}',
          left(v_object#>>'{last_finalization_error,message}',1000),
          v_next_attempt,v_event.event_created_at,v_object->>'collection_method'
        ) on conflict(source_event_id) do nothing;
      end if;

      update public.subscriptions tenant_subscription
         set payment_status=case
               when v_event.event_type='invoice.payment_failed' then 'failed'
               when v_event.event_type='invoice.payment_action_required'
                 then 'action_required'
               when v_event.event_type='invoice.paid' then 'paid'
               else payment_status
             end,
             period_subtotal_cents=v_subtotal,period_tax_cents=v_tax,
             period_total_cents=v_total,
             next_payment_at=case
               when v_event.event_type in (
                 'invoice.payment_failed','invoice.payment_action_required'
               ) then v_next_attempt
               else next_payment_at
             end,
             last_paid_at=case when v_event.event_type='invoice.paid'
                               then v_paid_at else last_paid_at end,
             last_paid_invoice_id=case when v_event.event_type='invoice.paid'
                                       then v_invoice else last_paid_invoice_id end,
             payment_event_created_at=v_event.event_created_at,
             payment_event_rank=v_rank,updated_at=now()
       where tenant_subscription.business_id=v_business
         and (tenant_subscription.payment_event_created_at is null
              or (v_event.event_created_at,v_rank)
                 >= (tenant_subscription.payment_event_created_at,
                     tenant_subscription.payment_event_rank));
    end if;

    if v_event.event_type in ('refund.created','charge.dispute.created') then
      if v_event.event_type='refund.created' then
        select invoice_row.* into v_adjustment_invoice
          from public.billing_provider_invoices invoice_row
         where invoice_row.provider_payment_intent_id =
               coalesce(
                 case when jsonb_typeof(v_object->'payment_intent')='string'
                      then v_object->>'payment_intent'
                      else v_object#>>'{payment_intent,id}' end,
                 (
                   select attempt.provider_payment_intent_id
                     from public.billing_payment_attempts attempt
                    where attempt.provider_charge_id = v_object->>'charge'
                    order by attempt.occurred_at desc limit 1
                 )
               )
         order by invoice_row.paid_at desc nulls last
         limit 1;
        v_adjustment_total := -greatest(coalesce((v_object->>'amount')::integer,0),0);
      else
        select invoice_row.* into v_adjustment_invoice
          from public.billing_payment_attempts attempt
          join public.billing_provider_invoices invoice_row
            on invoice_row.provider_invoice_id=attempt.provider_invoice_id
         where attempt.provider_charge_id = coalesce(
           case when jsonb_typeof(v_object->'charge')='string'
                then v_object->>'charge' else v_object#>>'{charge,id}' end,
           v_object->>'charge'
         )
         order by attempt.occurred_at desc limit 1;
        v_adjustment_total := -greatest(coalesce((v_object->>'amount')::integer,0),0);
      end if;
      if v_adjustment_invoice.id is null or v_adjustment_total = 0 then
        raise exception 'refund or chargeback cannot be mapped to a paid invoice';
      end if;
      v_adjustment_tax := case when v_adjustment_invoice.total_cents > 0 then
        -floor(
          abs(v_adjustment_total)::numeric
          * v_adjustment_invoice.tax_cents::numeric
          / v_adjustment_invoice.total_cents::numeric
        )::integer
      else 0 end;
      v_adjustment_net := v_adjustment_total-v_adjustment_tax;
      insert into public.billing_adjustments(
        business_id,provider_invoice_id,adjustment_type,
        subtotal_ex_tax_cents,tax_cents,total_cents,currency,source_event_id,
        provider_object_id,reason,evidence_sha256,occurred_at
      ) values (
        v_adjustment_invoice.business_id,
        v_adjustment_invoice.provider_invoice_id,
        case when v_event.event_type='refund.created' then 'refund' else 'chargeback' end,
        v_adjustment_net,v_adjustment_tax,v_adjustment_total,
        v_adjustment_invoice.currency,v_event.event_id,v_object->>'id',
        case when v_event.event_type='refund.created'
             then 'Stripe refund event' else 'Stripe chargeback event' end,
        v_event.payload_sha256,v_event.event_created_at
      ) on conflict(source_event_id) do nothing;
    end if;

    insert into public.billing_evidence(
      business_id,evidence_type,entity_type,entity_id,content_sha256,external_reference
    ) values (
      v_business,'provider_event','stripe_event',v_event.event_id,
      v_event.payload_sha256,v_event.object_id
    ) on conflict do nothing;

    update public.billing_provider_events
       set processing_status='processed',business_id=v_business,
           processed_at=now(),last_error=null
     where id=v_event.id;
    return jsonb_build_object(
      'event_id',p_event_id,'status','processed','business_id',v_business
    );
  exception when others then
    update public.billing_provider_events
       set processing_status='failed',last_error=left(sqlerrm,2000)
     where id=v_event.id;
    return jsonb_build_object(
      'event_id',p_event_id,'status','failed','error',left(sqlerrm,500)
    );
  end;
end
$$;
revoke all on function public.apply_stripe_billing_event_v77(text)
  from public,anon,authenticated;
grant execute on function public.apply_stripe_billing_event_v77(text)
  to service_role;

-- ---------------------------------------------------------------------------
-- 4. Browser-safe command seam and finite readers.
-- ---------------------------------------------------------------------------

create or replace function public.request_billing_command_v77(
  p_business uuid,
  p_command_type text,
  p_cadence text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_fingerprint text;
  v_command public.billing_commands%rowtype;
begin
  if v_actor is null
     or not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'active owner or super-admin access is required'
      using errcode='42501';
  end if;
  if p_command_type not in (
    'create_checkout','create_portal','change_cadence',
    'cancel_at_period_end','resume'
  ) or p_idempotency_key is null then
    raise exception 'invalid billing command' using errcode='22023';
  end if;
  if p_command_type in ('create_checkout','change_cadence')
     and p_cadence not in ('quarterly','half_yearly','annual') then
    raise exception 'a canonical cadence is required' using errcode='22023';
  end if;
  if p_command_type not in ('create_checkout','change_cadence')
     and p_cadence is not null then
    raise exception 'cadence is not valid for this command' using errcode='22023';
  end if;
  v_fingerprint := encode(extensions.digest(convert_to(
    p_business::text||E'\n'||p_command_type||E'\n'||coalesce(p_cadence,''),
    'utf8'
  ),'sha256'),'hex');

  select * into v_command
    from public.billing_commands
   where business_id=p_business and command_type=p_command_type
     and idempotency_key=p_idempotency_key;
  if found then
    if v_command.request_fingerprint <> v_fingerprint then
      raise exception 'billing command idempotency key conflicts with another request'
        using errcode='22023';
    end if;
  else
    insert into public.billing_commands(
      business_id,command_type,requested_cadence,idempotency_key,
      request_fingerprint,requested_by
    ) values (
      p_business,p_command_type,p_cadence,p_idempotency_key,
      v_fingerprint,v_actor
    ) returning * into v_command;
  end if;
  return jsonb_build_object(
    'command_id',v_command.id,'status',v_command.status,
    'command_type',v_command.command_type,'cadence',v_command.requested_cadence,
    'redirect_url',v_command.redirect_url,'requested_at',v_command.requested_at
  );
end
$$;
revoke all on function public.request_billing_command_v77(uuid,text,text,uuid)
  from public,anon,authenticated;
grant execute on function public.request_billing_command_v77(uuid,text,text,uuid)
  to authenticated;

create or replace function app.billing_price_confirmation_v77(
  p_currency text,
  p_cadence text,
  p_provider_base_price_id text,
  p_provider_seat_price_id text,
  p_base_amount_cents integer,
  p_per_seat_amount_cents integer,
  p_included_seats integer,
  p_tax_behavior text,
  p_effective_from timestamptz
)
returns text
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select encode(extensions.digest(convert_to(
    upper(p_currency)||E'\n'||p_cadence||E'\n'
    ||p_provider_base_price_id||E'\n'||p_provider_seat_price_id||E'\n'
    ||p_base_amount_cents::text||E'\n'||p_per_seat_amount_cents::text||E'\n'
    ||p_included_seats::text||E'\n'||p_tax_behavior||E'\n'
    ||to_char(p_effective_from at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US'),
    'utf8'
  ),'sha256'),'hex')
$$;
revoke all on function app.billing_price_confirmation_v77(
  text,text,text,text,integer,integer,integer,text,timestamptz
) from public,anon,authenticated;

create or replace function public.preview_billing_price_catalog_v77(
  p_currency text,
  p_cadence text,
  p_provider_base_price_id text,
  p_provider_seat_price_id text,
  p_base_amount_cents integer,
  p_per_seat_amount_cents integer,
  p_included_seats integer,
  p_tax_behavior text,
  p_effective_from timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_months smallint;
  v_current jsonb;
  v_hash text;
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  v_months := case p_cadence
    when 'quarterly' then 3 when 'half_yearly' then 6 when 'annual' then 12
  end;
  if p_currency !~ '^[A-Z]{3}$' or v_months is null
     or p_provider_base_price_id !~ '^price_[A-Za-z0-9_]+$'
     or p_provider_seat_price_id !~ '^price_[A-Za-z0-9_]+$'
     or p_provider_base_price_id=p_provider_seat_price_id
     or p_base_amount_cents < 0 or p_per_seat_amount_cents < 0
     or p_included_seats < 0
     or p_tax_behavior not in ('inclusive','exclusive','unspecified')
     or p_effective_from is null then
    raise exception 'invalid Stripe price catalog proposal' using errcode='22023';
  end if;
  select to_jsonb(catalog) into v_current
    from public.billing_price_catalog catalog
   where currency=p_currency and cadence=p_cadence
     and active and effective_to is null
   order by effective_from desc limit 1;
  v_hash := app.billing_price_confirmation_v77(
    p_currency,p_cadence,p_provider_base_price_id,p_provider_seat_price_id,
    p_base_amount_cents,p_per_seat_amount_cents,p_included_seats,
    p_tax_behavior,p_effective_from
  );
  return jsonb_build_object(
    'proposal',jsonb_build_object(
      'currency',p_currency,'cadence',p_cadence,'cadence_months',v_months,
      'provider_base_price_id',p_provider_base_price_id,
      'provider_seat_price_id',p_provider_seat_price_id,
      'base_amount_cents',p_base_amount_cents,
      'per_seat_amount_cents',p_per_seat_amount_cents,
      'included_seats',p_included_seats,'tax_behavior',p_tax_behavior,
      'effective_from',p_effective_from
    ),
    'current',v_current,'confirmation_hash',v_hash
  );
end
$$;
revoke all on function public.preview_billing_price_catalog_v77(
  text,text,text,text,integer,integer,integer,text,timestamptz
) from public,anon,authenticated;
grant execute on function public.preview_billing_price_catalog_v77(
  text,text,text,text,integer,integer,integer,text,timestamptz
) to authenticated;

create or replace function public.confirm_billing_price_catalog_v77(
  p_currency text,
  p_cadence text,
  p_provider_base_price_id text,
  p_provider_seat_price_id text,
  p_base_amount_cents integer,
  p_per_seat_amount_cents integer,
  p_included_seats integer,
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
  v_actor uuid := auth.uid();
  v_preview jsonb;
  v_expected text;
  v_months smallint;
  v_prior public.billing_price_catalog%rowtype;
  v_new public.billing_price_catalog%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  v_preview := public.preview_billing_price_catalog_v77(
    p_currency,p_cadence,p_provider_base_price_id,p_provider_seat_price_id,
    p_base_amount_cents,p_per_seat_amount_cents,p_included_seats,
    p_tax_behavior,p_effective_from
  );
  v_expected := v_preview->>'confirmation_hash';
  if p_confirmation_hash is null or p_confirmation_hash <> v_expected then
    raise exception 'price catalog confirmation hash does not match preview'
      using errcode='22023';
  end if;
  if nullif(btrim(p_reason),'') is null or length(p_reason)>1000 then
    raise exception 'a bounded activation reason is required' using errcode='22023';
  end if;
  if p_effective_from < now()-interval '1 day'
     or p_effective_from > now()+interval '5 minutes' then
    raise exception 'effective_from must activate now, not schedule a hidden gap'
      using errcode='22023';
  end if;
  v_months := case p_cadence
    when 'quarterly' then 3 when 'half_yearly' then 6 when 'annual' then 12
  end;
  perform pg_advisory_xact_lock(hashtextextended(
    'v77:billing-price:'||p_currency||':'||p_cadence,0
  ));
  select * into v_prior
    from public.billing_price_catalog
   where currency=p_currency and cadence=p_cadence
     and active and effective_to is null
   for update;
  if found and v_prior.effective_from >= p_effective_from then
    raise exception 'new price version must begin after the active version'
      using errcode='22023';
  end if;
  if found then
    update public.billing_price_catalog
       set active=false,effective_to=p_effective_from
     where id=v_prior.id;
  end if;
  insert into public.billing_price_catalog(
    currency,cadence,cadence_months,provider_base_price_id,
    provider_seat_price_id,base_amount_cents,per_seat_amount_cents,
    included_seats,tax_behavior,effective_from,created_by
  ) values (
    p_currency,p_cadence,v_months,p_provider_base_price_id,
    p_provider_seat_price_id,p_base_amount_cents,p_per_seat_amount_cents,
    p_included_seats,p_tax_behavior,p_effective_from,v_actor
  ) returning * into v_new;
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values (
    null,v_actor,'BILLING_PRICE_CATALOG_ACTIVATED_V77',
    'billing_price_catalog',v_new.id,
    jsonb_build_object(
      'prior_id',v_prior.id,'currency',p_currency,'cadence',p_cadence,
      'cadence_months',v_months,'base_amount_cents',p_base_amount_cents,
      'per_seat_amount_cents',p_per_seat_amount_cents,
      'included_seats',p_included_seats,'tax_behavior',p_tax_behavior,
      'confirmation_hash',p_confirmation_hash,'reason',btrim(p_reason)
    )
  );
  return to_jsonb(v_new);
end
$$;
revoke all on function public.confirm_billing_price_catalog_v77(
  text,text,text,text,integer,integer,integer,text,timestamptz,text,text
) from public,anon,authenticated;
grant execute on function public.confirm_billing_price_catalog_v77(
  text,text,text,text,integer,integer,integer,text,timestamptz,text,text
) to authenticated;

create or replace function public.get_billing_price_catalog_v77(
  p_currency text default null
)
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
             provider_seat_price_id,base_amount_cents,per_seat_amount_cents,
             included_seats,tax_behavior,active,effective_from,effective_to,
             created_at
        from public.billing_price_catalog
       where p_currency is null or currency=p_currency
       order by effective_from desc limit 100
    ) rows
  ),'[]'::jsonb);
end
$$;
revoke all on function public.get_billing_price_catalog_v77(text)
  from public,anon,authenticated;
grant execute on function public.get_billing_price_catalog_v77(text)
  to authenticated;

create or replace function public.claim_billing_command_v77(
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
  v_catalog public.billing_price_catalog%rowtype;
  v_seats integer;
  v_recovery_required boolean:=false;
begin
  if p_command is null or p_actor is null then
    raise exception 'command and actor are required' using errcode='22023';
  end if;
  select * into v_command
    from public.billing_commands
   where id=p_command and requested_by=p_actor
   for update;
  if not found then
    raise exception 'billing command was not found for this actor'
      using errcode='42501';
  end if;
  if v_command.status in ('completed','failed','canceled') then
    return jsonb_build_object(
      'command_id',v_command.id,'status',v_command.status,
      'command_type',v_command.command_type,
      'provider_object_id',v_command.provider_object_id,
      'redirect_url',v_command.redirect_url,
      'error_code',v_command.error_code,
      'error_message',v_command.error_message
    );
  end if;
  v_recovery_required:=v_command.status in ('processing','uncertain');
  update public.billing_commands
     set status='processing'
   where id=v_command.id and status in ('pending','uncertain')
   returning * into v_command;
  if not found then
    select * into strict v_command
      from public.billing_commands where id=p_command;
  end if;

  select * into strict v_subscription
    from public.subscriptions where business_id=v_command.business_id;
  v_seats := app.billable_seats(v_command.business_id);
  if v_command.requested_cadence is not null then
    select * into v_catalog
      from public.billing_price_catalog
     where currency=v_subscription.currency
       and cadence=v_command.requested_cadence
       and active and effective_from <= now()
       and (effective_to is null or effective_to > now())
     order by effective_from desc limit 1;
    if not found then
      raise exception 'active Stripe price catalog entry was not found'
        using errcode='22023';
    end if;
  end if;
  return jsonb_build_object(
    'command_id',v_command.id,'status',v_command.status,
    'command_type',v_command.command_type,
    'business_id',v_command.business_id,
    'requested_cadence',v_command.requested_cadence,
    'provider_idempotency_key','nestly:v77:billing-command:'||v_command.id::text,
    'recovery_required',v_recovery_required,
    'prior_provider_object_id',v_command.provider_object_id,
    'prior_redirect_url',v_command.redirect_url,
    'prior_error_code',v_command.error_code,
    'currency',v_subscription.currency,
    'provider_customer_id',v_subscription.provider_customer_id,
    'provider_subscription_id',v_subscription.provider_subscription_id,
    'provider_base_item_id',coalesce(
      v_subscription.provider_base_item_id,
      (
        select item.provider_item_id
          from public.billing_provider_subscription_items item
         where item.provider_subscription_id=v_subscription.provider_subscription_id
           and item.item_role='base'
         order by item.updated_at desc limit 1
      )
    ),
    'provider_seat_item_id',coalesce(
      v_subscription.provider_seat_item_id,
      (
        select item.provider_item_id
          from public.billing_provider_subscription_items item
         where item.provider_subscription_id=v_subscription.provider_subscription_id
           and item.item_role='seat'
         order by item.updated_at desc limit 1
      )
    ),
    'billable_seats',v_seats,
    'included_seats',coalesce(v_catalog.included_seats,v_subscription.included_seats),
    'extra_seats',greatest(
      v_seats-coalesce(v_catalog.included_seats,v_subscription.included_seats),0
    ),
    'provider_base_price_id',v_catalog.provider_base_price_id,
    'provider_seat_price_id',v_catalog.provider_seat_price_id
  );
end
$$;
revoke all on function public.claim_billing_command_v77(uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.claim_billing_command_v77(uuid,uuid)
  to service_role;

create or replace function public.complete_billing_command_v77(
  p_command uuid,
  p_status text,
  p_provider_object_id text,
  p_redirect_url text,
  p_error_code text,
  p_error_message text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_command public.billing_commands%rowtype;
begin
  if p_status not in ('processing','uncertain','completed','failed','canceled') then
    raise exception 'invalid command status' using errcode='22023';
  end if;
  select * into v_command from public.billing_commands where id=p_command for update;
  if not found then raise exception 'billing command not found' using errcode='22023'; end if;
  if v_command.status in ('completed','failed','canceled') then
    if v_command.status <> p_status
       or v_command.provider_object_id is distinct from p_provider_object_id
       or v_command.redirect_url is distinct from p_redirect_url
       or v_command.error_code is distinct from p_error_code then
      raise exception 'terminal billing command cannot be rewritten'
        using errcode='restrict_violation';
    end if;
    return to_jsonb(v_command);
  end if;
  update public.billing_commands
     set status=p_status,provider_object_id=p_provider_object_id,
         redirect_url=p_redirect_url,error_code=p_error_code,
         error_message=left(p_error_message,2000),
         completed_at=case when p_status in ('completed','failed','canceled')
                           then now() else null end
   where id=p_command returning * into v_command;
  return to_jsonb(v_command);
end
$$;
revoke all on function public.complete_billing_command_v77(
  uuid,text,text,text,text,text
) from public,anon,authenticated;
grant execute on function public.complete_billing_command_v77(
  uuid,text,text,text,text,text
) to service_role;

create or replace function public.append_billing_adjustment_v77(
  p_business uuid,
  p_provider_invoice_id text,
  p_adjustment_type text,
  p_subtotal_ex_tax_cents integer,
  p_tax_cents integer,
  p_currency text,
  p_provider_object_id text,
  p_reversal_of uuid,
  p_reason text,
  p_evidence_sha256 text,
  p_occurred_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_id uuid;
  v_total integer;
begin
  v_total := p_subtotal_ex_tax_cents + p_tax_cents;
  if p_adjustment_type not in (
    'credit','debit','refund','chargeback','external_payment','writeoff','reversal'
  ) or p_currency !~ '^[A-Z]{3}$'
     or p_evidence_sha256 !~ '^[0-9a-f]{64}$'
     or p_occurred_at is null then
    raise exception 'invalid billing adjustment' using errcode='22023';
  end if;
  if p_adjustment_type='reversal' and p_reversal_of is null then
    raise exception 'reversal reference is required' using errcode='22023';
  elsif p_adjustment_type<>'reversal' and p_reversal_of is not null then
    raise exception 'only a reversal may carry a reversal reference'
      using errcode='22023';
  end if;
  insert into public.billing_adjustments(
    business_id,provider_invoice_id,adjustment_type,subtotal_ex_tax_cents,
    tax_cents,total_cents,currency,provider_object_id,reversal_of,reason,
    evidence_sha256,occurred_at
  ) values (
    p_business,p_provider_invoice_id,p_adjustment_type,p_subtotal_ex_tax_cents,
    p_tax_cents,v_total,p_currency,p_provider_object_id,p_reversal_of,p_reason,
    p_evidence_sha256,p_occurred_at
  ) returning id into v_id;
  insert into public.billing_evidence(
    business_id,evidence_type,entity_type,entity_id,content_sha256,external_reference
  ) values (
    p_business,'adjustment','billing_adjustment',v_id::text,
    p_evidence_sha256,p_provider_object_id
  );
  return v_id;
end
$$;
revoke all on function public.append_billing_adjustment_v77(
  uuid,text,text,integer,integer,text,text,uuid,text,text,timestamptz
) from public,anon,authenticated;
grant execute on function public.append_billing_adjustment_v77(
  uuid,text,text,integer,integer,text,text,uuid,text,text,timestamptz
) to service_role;

create or replace function public.start_billing_reconciliation_v77(
  p_run_mode text,
  p_cursor_start text
)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_id uuid;
begin
  if p_run_mode not in ('dry_run','apply','scheduled') then
    raise exception 'invalid reconciliation mode' using errcode='22023';
  end if;
  insert into public.billing_reconciliation_runs(run_mode,cursor_start)
  values(p_run_mode,p_cursor_start) returning id into v_id;
  return v_id;
end
$$;
revoke all on function public.start_billing_reconciliation_v77(text,text)
  from public,anon,authenticated;
grant execute on function public.start_billing_reconciliation_v77(text,text)
  to service_role;

create or replace function public.finish_billing_reconciliation_v77(
  p_run uuid,
  p_status text,
  p_cursor_end text,
  p_summary jsonb
)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if p_status not in ('partial','clean','mismatch','failed')
     or jsonb_typeof(p_summary) <> 'object' then
    raise exception 'invalid reconciliation result' using errcode='22023';
  end if;
  update public.billing_reconciliation_runs
     set status=p_status,cursor_end=p_cursor_end,summary=p_summary,finished_at=now()
   where id=p_run and status='running';
  if not found then
    raise exception 'running reconciliation was not found'
      using errcode='restrict_violation';
  end if;
end
$$;
revoke all on function public.finish_billing_reconciliation_v77(
  uuid,text,text,jsonb
) from public,anon,authenticated;
grant execute on function public.finish_billing_reconciliation_v77(
  uuid,text,text,jsonb
) to service_role;

create or replace function public.get_business_billing_v77(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null
     or not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'active owner or super-admin access is required'
      using errcode='42501';
  end if;
  select jsonb_build_object(
    'business_id',s.business_id,'status',s.status,
    'payment_status',s.payment_status,'currency',s.currency,
    'cadence',s.billing_cadence,'cadence_months',s.cadence_months,
    'billable_seats',app.billable_seats(s.business_id),
    'provider_seat_quantity',s.provider_seat_quantity,
    'period_subtotal_cents',s.period_subtotal_cents,
    'period_tax_cents',s.period_tax_cents,
    'period_total_cents',s.period_total_cents,
    'tax_behavior',s.tax_behavior,
    'provider',jsonb_build_object(
      'name',s.billing_provider,'customer_id',s.provider_customer_id,
      'subscription_id',s.provider_subscription_id
    ),
    'current_period_start',s.current_period_start,
    'current_period_end',s.current_period_end,
    'next_payment_at',s.next_payment_at,
    'last_paid_at',s.last_paid_at,
    'last_paid_invoice_id',s.last_paid_invoice_id,
    'cancel_at_period_end',s.cancel_at_period_end,
    'invoices',coalesce((
      select jsonb_agg(to_jsonb(invoice_rows) order by invoice_rows.sort_at desc)
      from (
        select provider_invoice_id,number,status,paid_normalized,currency,
               subtotal_ex_tax_cents,tax_cents,total_cents,amount_paid_cents,
               amount_remaining_cents,collection_method,period_start,period_end,
               paid_at,next_payment_attempt_at,
               coalesce(paid_at,created_at) sort_at
          from public.billing_provider_invoices
         where business_id=p_business
         order by coalesce(paid_at,created_at) desc limit 20
      ) invoice_rows
    ),'[]'::jsonb),
    'payment_attempts',coalesce((
      select jsonb_agg(to_jsonb(attempt_rows) order by attempt_rows.occurred_at desc)
      from (
        select provider_invoice_id,attempt_state,amount_cents,tax_cents,
               failure_code,next_attempt_at,occurred_at,collection_method
          from public.billing_payment_attempts
         where business_id=p_business order by occurred_at desc limit 20
      ) attempt_rows
    ),'[]'::jsonb),
    'adjustments',coalesce((
      select jsonb_agg(to_jsonb(adjustment_rows) order by adjustment_rows.occurred_at desc)
      from (
        select id,provider_invoice_id,adjustment_type,subtotal_ex_tax_cents,
               tax_cents,total_cents,currency,reason,occurred_at,reversal_of
          from public.billing_adjustments
         where business_id=p_business order by occurred_at desc limit 20
      ) adjustment_rows
    ),'[]'::jsonb),
    'commands',coalesce((
      select jsonb_agg(to_jsonb(command_rows) order by command_rows.requested_at desc)
      from (
        select id command_id,command_type,requested_cadence,status,redirect_url,
               error_code,requested_at,completed_at
          from public.billing_commands
         where business_id=p_business order by requested_at desc limit 10
      ) command_rows
    ),'[]'::jsonb)
  ) into v_result
    from public.subscriptions s where s.business_id=p_business;
  if v_result is null then
    raise exception 'billing subscription was not found' using errcode='22023';
  end if;
  return v_result;
end
$$;
revoke all on function public.get_business_billing_v77(uuid)
  from public,anon,authenticated;
grant execute on function public.get_business_billing_v77(uuid)
  to authenticated;

create or replace function public.get_platform_billing_v77(
  p_business uuid default null,
  p_limit integer default 100
)
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
  if p_limit not between 1 and 250 then
    raise exception 'limit must be between 1 and 250' using errcode='22023';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(rows) order by rows.updated_at desc)
    from (
      select s.business_id,b.name business_name,s.status,s.payment_status,s.currency,
             s.billing_cadence cadence,s.cadence_months,s.billing_provider provider,
             s.provider_customer_id,s.provider_subscription_id,
             app.billable_seats(s.business_id) billable_seats,
             s.period_subtotal_cents,s.period_tax_cents,s.period_total_cents,
             s.next_payment_at,s.last_paid_at,s.last_paid_invoice_id,
             s.cancel_at_period_end,s.updated_at,
             (
               select array_agg(catalog.cadence order by catalog.cadence)
                 from public.billing_price_catalog catalog
                where catalog.currency=s.currency and catalog.active
                  and catalog.effective_from<=now()
                  and (catalog.effective_to is null or catalog.effective_to>now())
             ) catalog_ready_cadences,
             array(
               select required.cadence
                 from unnest(array['annual','half_yearly','quarterly']) required(cadence)
                where not exists(
                  select 1 from public.billing_price_catalog catalog
                   where catalog.currency=s.currency
                     and catalog.cadence=required.cadence
                     and catalog.active and catalog.effective_from<=now()
                     and (catalog.effective_to is null or catalog.effective_to>now())
                )
                order by required.cadence
             ) catalog_missing_cadences,
             (
               select count(*) from public.billing_provider_events e
                where e.business_id=s.business_id and e.processing_status='failed'
             ) failed_event_count
        from public.subscriptions s
        join public.businesses b on b.id=s.business_id
       where p_business is null or s.business_id=p_business
       order by s.updated_at desc limit p_limit
    ) rows
  ),'[]'::jsonb);
end
$$;
revoke all on function public.get_platform_billing_v77(uuid,integer)
  from public,anon,authenticated;
grant execute on function public.get_platform_billing_v77(uuid,integer)
  to authenticated;

create or replace function public.get_billing_reconciliation_v77(
  p_run uuid default null,
  p_limit integer default 50
)
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
  if p_limit not between 1 and 200 then
    raise exception 'limit must be between 1 and 200' using errcode='22023';
  end if;
  return jsonb_build_object(
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
  );
end
$$;
revoke all on function public.get_billing_reconciliation_v77(uuid,integer)
  from public,anon,authenticated;
grant execute on function public.get_billing_reconciliation_v77(uuid,integer)
  to authenticated;

comment on function public.apply_stripe_billing_event_v77(text) is
  'Service-role-only normalizer. invoice.paid is the sole event that sets normalized paid truth; provider timestamps and event ranks reject stale regressions.';
comment on function public.request_billing_command_v77(uuid,text,text,uuid) is
  'Owner/SA command outbox. It never accepts or returns Stripe secrets and never treats a checkout redirect as payment truth.';
comment on function public.claim_billing_command_v77(uuid,uuid) is
  'Service-only command claim for the authenticated Edge executor. Returns a finite provider instruction and a stable Stripe idempotency key.';
comment on function public.preview_billing_price_catalog_v77(
  text,text,text,text,integer,integer,integer,text,timestamptz
) is 'SA preview for a versioned Stripe price activation. Confirmation hashes bind all cents, tax and cadence fields.';

commit;
