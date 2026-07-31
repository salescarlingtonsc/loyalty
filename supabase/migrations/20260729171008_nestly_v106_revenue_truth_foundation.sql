-- Nestly v106 — revenue truth and external commerce-event foundation.
--
-- This migration deliberately does not rewrite public.sales, public.payments,
-- public.sale_items, or any stored-value ledger.  The existing sales ledger remains
-- authoritative for Nestly-known revenue.  External events are append-only observations
-- until an authorised user explicitly reconciles them to an existing sale.
--
-- Reporting contract:
--   * periods are half-open business-local dates: [p_from, p_to)
--   * total = identified + anonymous, after native and reconciled refund allocation
--   * a zero denominator produces NULL, never a reassuring but false 0%
--   * business-wide reports preserve every outlet's effective timezone
--   * currency is a versioned ISO-4217-style code; mixed currencies are refused
--   * old rows use an explicit legacy-assumption contract, not an invisible fallback
--
-- External event contract:
--   * unique (business, source_system, source_event_id, event_type)
--   * identical replay is a no-op
--   * a conflicting replay is quarantined and never alters a ledger
--   * partial-refund allocation is append-only and can only reference one original sale

begin;

create table public.reporting_contract_versions_v106 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id uuid,
  version_no integer not null check (version_no > 0),
  effective_from timestamptz not null,
  timezone text not null,
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  legacy_assumption boolean not null default false,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid(),
  constraint reporting_contract_v106_branch_fk
    foreign key (branch_id, business_id)
    references public.branches(id, business_id) on delete no action,
  constraint reporting_contract_v106_id_business_uk unique (id, business_id),
  constraint reporting_contract_v106_version_uk
    unique nulls not distinct (business_id, branch_id, version_no)
);

create unique index reporting_contract_v106_business_effective_uidx
  on public.reporting_contract_versions_v106(business_id, effective_from)
  where branch_id is null;
create unique index reporting_contract_v106_branch_effective_uidx
  on public.reporting_contract_versions_v106(business_id, branch_id, effective_from)
  where branch_id is not null;
create index reporting_contract_v106_lookup_idx
  on public.reporting_contract_versions_v106
  (business_id, branch_id, effective_from desc, version_no desc);

comment on table public.reporting_contract_versions_v106 is
  'Append-only effective-dated business/outlet timezone and currency contract used by v106+ reporting.';
comment on column public.reporting_contract_versions_v106.legacy_assumption is
  'True only for the migration-time contract applied to pre-v106 facts whose historical setting was not versioned.';

create table public.commerce_events_v106 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id uuid,
  event_type text not null check (
    event_type in (
      'transaction_completed',
      'transaction_voided',
      'refund_completed',
      'chargeback_opened',
      'chargeback_reversed'
    )
  ),
  schema_version integer not null default 1 check (schema_version = 1),
  source_system text not null check (
    source_system ~ '^[a-z0-9][a-z0-9._-]{1,62}$'
  ),
  source_event_id text not null check (length(btrim(source_event_id)) between 1 and 200),
  idempotency_key text not null check (length(btrim(idempotency_key)) between 1 and 200),
  occurred_at timestamptz not null,
  received_at timestamptz not null default clock_timestamp(),
  recorded_at timestamptz not null default clock_timestamp(),
  business_date date not null,
  reporting_contract_id uuid not null,
  timezone text not null,
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  amount_minor bigint not null,
  actor_type text not null default 'integration'
    check (actor_type in ('integration', 'owner', 'admin', 'staff', 'system')),
  actor_id uuid,
  causation_id text,
  correlation_id text,
  supersedes_event_id uuid,
  payload jsonb not null default '{}'::jsonb check (jsonb_typeof(payload) = 'object'),
  payload_hash text not null check (payload_hash ~ '^[0-9a-f]{64}$'),
  created_by uuid default auth.uid(),
  constraint commerce_events_v106_branch_fk
    foreign key (branch_id, business_id)
    references public.branches(id, business_id) on delete no action,
  constraint commerce_events_v106_contract_fk
    foreign key (reporting_contract_id, business_id)
    references public.reporting_contract_versions_v106(id, business_id) on delete no action,
  constraint commerce_events_v106_supersedes_fk
    foreign key (supersedes_event_id, business_id)
    references public.commerce_events_v106(id, business_id) on delete no action,
  constraint commerce_events_v106_id_business_uk unique (id, business_id),
  constraint commerce_events_v106_source_uk
    unique (business_id, source_system, source_event_id, event_type),
  constraint commerce_events_v106_idempotency_uk
    unique (business_id, source_system, idempotency_key),
  constraint commerce_events_v106_amount_sign_check check (
    (event_type = 'transaction_completed' and amount_minor > 0)
    or (event_type in ('transaction_voided', 'refund_completed', 'chargeback_opened')
        and amount_minor < 0)
    or (event_type = 'chargeback_reversed' and amount_minor > 0)
  ),
  constraint commerce_events_v106_clock_check
    check (recorded_at >= received_at)
);

create index commerce_events_v106_period_idx
  on public.commerce_events_v106(business_id, branch_id, business_date, occurred_at);

create table public.commerce_event_conflicts_v106 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  existing_event_id uuid not null,
  source_system text not null,
  source_event_id text not null,
  event_type text not null,
  received_idempotency_key text not null,
  existing_payload_hash text not null,
  received_payload_hash text not null,
  received_envelope jsonb not null check (jsonb_typeof(received_envelope) = 'object'),
  status text not null default 'quarantined' check (status = 'quarantined'),
  created_at timestamptz not null default clock_timestamp(),
  created_by uuid default auth.uid(),
  constraint commerce_event_conflicts_v106_event_fk
    foreign key (existing_event_id, business_id)
    references public.commerce_events_v106(id, business_id) on delete no action
);

create index commerce_event_conflicts_v106_business_idx
  on public.commerce_event_conflicts_v106(business_id, created_at desc);

create table public.commerce_event_reconciliations_v106 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  event_id uuid not null,
  sale_id uuid not null,
  idempotency_key text not null check (length(btrim(idempotency_key)) between 1 and 200),
  status text not null default 'reconciled' check (status = 'reconciled'),
  reconciliation_hash text not null check (reconciliation_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default clock_timestamp(),
  created_by uuid not null default auth.uid(),
  constraint commerce_recon_v106_event_fk
    foreign key (event_id, business_id)
    references public.commerce_events_v106(id, business_id) on delete no action,
  constraint commerce_recon_v106_sale_fk
    foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete no action,
  constraint commerce_recon_v106_event_uk unique (event_id),
  constraint commerce_recon_v106_idempotency_uk unique (business_id, idempotency_key),
  constraint commerce_recon_v106_id_business_uk unique (id, business_id)
);

create table public.commerce_refund_allocations_v106 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  reconciliation_id uuid not null,
  event_id uuid not null,
  sale_id uuid not null,
  sale_item_id uuid,
  payment_id uuid,
  amount_minor bigint not null check (amount_minor > 0),
  created_at timestamptz not null default clock_timestamp(),
  created_by uuid not null default auth.uid(),
  constraint commerce_refund_alloc_v106_recon_fk
    foreign key (reconciliation_id, business_id)
    references public.commerce_event_reconciliations_v106(id, business_id) on delete no action,
  constraint commerce_refund_alloc_v106_event_fk
    foreign key (event_id, business_id)
    references public.commerce_events_v106(id, business_id) on delete no action,
  constraint commerce_refund_alloc_v106_sale_fk
    foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete no action,
  constraint commerce_refund_alloc_v106_item_fk
    foreign key (sale_item_id)
    references public.sale_items(id) on delete no action,
  constraint commerce_refund_alloc_v106_payment_fk
    foreign key (payment_id, business_id)
    references public.payments(id, business_id) on delete no action,
  constraint commerce_refund_alloc_v106_target_uk
    unique nulls not distinct (reconciliation_id, sale_item_id, payment_id)
);

create index commerce_refund_alloc_v106_sale_idx
  on public.commerce_refund_allocations_v106(business_id, sale_id, created_at);

-- Backfill one explicit legacy contract for the business scope and every existing outlet.
insert into public.reporting_contract_versions_v106(
  business_id, branch_id, version_no, effective_from, timezone, currency,
  legacy_assumption, created_by
)
select b.id, null, 1, '-infinity'::timestamptz,
       coalesce((
         select br.timezone
           from public.branches br
          where br.business_id = b.id
          order by br.is_default desc, br.created_at, br.id
          limit 1
       ), 'Asia/Singapore'),
       upper(b.currency), true, null
  from public.businesses b;

insert into public.reporting_contract_versions_v106(
  business_id, branch_id, version_no, effective_from, timezone, currency,
  legacy_assumption, created_by
)
select br.business_id, br.id, 1, '-infinity'::timestamptz,
       br.timezone, upper(b.currency), true, null
  from public.branches br
  join public.businesses b on b.id = br.business_id;

create or replace function app.v106_assert_timezone(p_timezone text)
returns text
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = p_timezone) then
    raise exception 'unsupported IANA timezone: %', p_timezone
      using errcode = '22023';
  end if;
  return p_timezone;
end $$;

create or replace function app.v106_reporting_contract(
  p_business uuid,
  p_branch uuid,
  p_occurred_at timestamptz
)
returns table (
  contract_id uuid,
  timezone text,
  currency text,
  version_no integer,
  legacy_assumption boolean
)
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select c.id, c.timezone, c.currency, c.version_no, c.legacy_assumption
    from public.reporting_contract_versions_v106 c
   where c.business_id = p_business
     and c.branch_id is not distinct from p_branch
     and c.effective_from <= p_occurred_at
   order by c.effective_from desc, c.version_no desc
   limit 1
$$;

-- Forward-compatible identity-attribution hook.  v106 preserves the immutable
-- ledger client_id until v111 replaces this function with the approved current
-- attribution resolver.  Synchronized reports call the hook, never rewrite a
-- historical sale.
create or replace function app.v111_effective_client_id(
  p_business uuid,
  p_client uuid
)
returns uuid
language sql
stable
security definer
returns null on null input
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select p_client
$$;

revoke all on function app.v111_effective_client_id(uuid, uuid)
  from public, anon, authenticated;

create or replace function app.v106_append_reporting_contract()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_business uuid;
  v_branch uuid;
  v_timezone text;
  v_currency text;
  v_next integer;
  v_branch_row record;
begin
  if tg_table_name = 'businesses' then
    v_business := new.id;
    v_branch := null;
    v_timezone := coalesce((
      select br.timezone from public.branches br
       where br.business_id = new.id
       order by br.is_default desc, br.created_at, br.id limit 1
    ), 'Asia/Singapore');
    v_currency := upper(new.currency);
  else
    v_business := new.business_id;
    v_branch := new.id;
    v_timezone := new.timezone;
    select upper(b.currency) into v_currency
      from public.businesses b where b.id = new.business_id;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_business::text || ':' || coalesce(v_branch::text, 'business'), 106)
  );
  perform app.v106_assert_timezone(v_timezone);
  if v_currency !~ '^[A-Z]{3}$' then
    raise exception 'currency must be a three-letter uppercase code'
      using errcode = '22023';
  end if;
  select coalesce(max(c.version_no), 0) + 1 into v_next
    from public.reporting_contract_versions_v106 c
   where c.business_id = v_business
     and c.branch_id is not distinct from v_branch;

  insert into public.reporting_contract_versions_v106(
    business_id, branch_id, version_no, effective_from, timezone, currency,
    legacy_assumption, created_by
  ) values (
    v_business, v_branch, v_next,
    case when v_next=1 then transaction_timestamp() else clock_timestamp() end,
    v_timezone, v_currency,
    false, auth.uid()
  );

  -- A business currency change changes every outlet contract as well.  Capturing only the
  -- business-scope row would leave branch reports on an old currency indefinitely.
  if tg_table_name = 'businesses' then
    for v_branch_row in
      select br.id, br.timezone
        from public.branches br
       where br.business_id = v_business
       order by br.id
    loop
      perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
          v_business::text || ':' || v_branch_row.id::text, 106
        )
      );
      perform app.v106_assert_timezone(v_branch_row.timezone);
      select coalesce(max(c.version_no), 0) + 1 into v_next
        from public.reporting_contract_versions_v106 c
       where c.business_id = v_business
         and c.branch_id = v_branch_row.id;
      insert into public.reporting_contract_versions_v106(
        business_id, branch_id, version_no, effective_from, timezone, currency,
        legacy_assumption, created_by
      ) values (
        v_business, v_branch_row.id, v_next,
        case when v_next=1 then transaction_timestamp() else clock_timestamp() end,
        v_branch_row.timezone, v_currency, false, auth.uid()
      );
    end loop;
  end if;
  return new;
end $$;

create trigger trg_v106_business_reporting_contract_insert
  after insert on public.businesses
  for each row execute function app.v106_append_reporting_contract();
create trigger trg_v106_business_reporting_contract_update
  after update of currency on public.businesses
  for each row
  when (old.currency is distinct from new.currency)
  execute function app.v106_append_reporting_contract();

create trigger trg_v106_branch_reporting_contract_insert
  after insert on public.branches
  for each row execute function app.v106_append_reporting_contract();
create trigger trg_v106_branch_reporting_contract_update
  after update of timezone on public.branches
  for each row
  when (old.timezone is distinct from new.timezone)
  execute function app.v106_append_reporting_contract();

create or replace function app.v106_append_only_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception '% is append-only: % is not permitted', tg_table_name, tg_op
    using errcode = 'restrict_violation';
end $$;

create trigger trg_v106_contract_append_only
  before update or delete on public.reporting_contract_versions_v106
  for each row execute function app.v106_append_only_guard();
create trigger trg_v106_event_append_only
  before update or delete on public.commerce_events_v106
  for each row execute function app.v106_append_only_guard();
create trigger trg_v106_conflict_append_only
  before update or delete on public.commerce_event_conflicts_v106
  for each row execute function app.v106_append_only_guard();
create trigger trg_v106_reconciliation_append_only
  before update or delete on public.commerce_event_reconciliations_v106
  for each row execute function app.v106_append_only_guard();
create trigger trg_v106_refund_alloc_append_only
  before update or delete on public.commerce_refund_allocations_v106
  for each row execute function app.v106_append_only_guard();

alter table public.reporting_contract_versions_v106 enable row level security;
alter table public.commerce_events_v106 enable row level security;
alter table public.commerce_event_conflicts_v106 enable row level security;
alter table public.commerce_event_reconciliations_v106 enable row level security;
alter table public.commerce_refund_allocations_v106 enable row level security;

create or replace function app.v106_sale_residual_minor(
  p_sale uuid,
  p_period_to date,
  p_as_of timestamptz
)
returns bigint
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select greatest(
    0::bigint,
    s.amount_cents::bigint
      - coalesce((
          select abs(sum(r.amount_cents))::bigint
          from public.sales r
          cross join lateral app.v106_reporting_contract(
            r.business_id, r.branch_id, r.occurred_at
          ) reversal_contract
          where r.business_id = s.business_id
            and r.reversal_of = s.id
            and r.created_at <= p_as_of
            and (r.occurred_at at time zone reversal_contract.timezone)::date
                  < p_period_to
        ), 0)
      - coalesce((
          select sum(a.amount_minor)::bigint
          from public.commerce_refund_allocations_v106 a
          join public.commerce_event_reconciliations_v106 reconciliation
            on reconciliation.id = a.reconciliation_id
           and reconciliation.business_id = a.business_id
          join public.commerce_events_v106 event_row
            on event_row.id = reconciliation.event_id
           and event_row.business_id = reconciliation.business_id
          where a.business_id = s.business_id
            and a.sale_id = s.id
            and event_row.event_type = 'refund_completed'
            and reconciliation.created_at <= p_as_of
            and event_row.business_date < p_period_to
        ), 0)
  )
  from public.sales s
  where s.id = p_sale
    and s.reversal_of is null
    and s.created_at <= p_as_of
$$;

revoke all on function app.v106_sale_residual_minor(uuid, date, timestamptz)
  from public, anon, authenticated;

create or replace function app.v106_sale_residual_minor(
  p_sale uuid,
  p_as_of timestamptz default clock_timestamp()
)
returns bigint
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select app.v106_sale_residual_minor(
    p_sale, 'infinity'::date, p_as_of
  )
$$;

revoke all on function app.v106_sale_residual_minor(uuid, timestamptz)
  from public, anon, authenticated;

create policy reporting_contract_v106_finance_read
  on public.reporting_contract_versions_v106 for select to authenticated
  using (
    app.is_super_admin()
    or (
      app.has_perm(business_id, 'view_finance')
      and app.can_see_branch(business_id, branch_id)
    )
  );
create policy commerce_events_v106_finance_read
  on public.commerce_events_v106 for select to authenticated
  using (
    app.is_super_admin()
    or (
      app.has_perm(business_id, 'view_finance')
      and app.can_see_branch(business_id, branch_id)
    )
  );
create policy commerce_event_conflicts_v106_finance_read
  on public.commerce_event_conflicts_v106 for select to authenticated
  using (
    app.is_super_admin()
    or (
      app.has_perm(business_id, 'view_finance')
      and exists (
        select 1 from public.commerce_events_v106 e
         where e.id = commerce_event_conflicts_v106.existing_event_id
           and e.business_id = commerce_event_conflicts_v106.business_id
           and app.can_see_branch(e.business_id, e.branch_id)
      )
    )
  );
create policy commerce_reconciliations_v106_finance_read
  on public.commerce_event_reconciliations_v106 for select to authenticated
  using (
    app.is_super_admin()
    or (
      app.has_perm(business_id, 'view_finance')
      and exists (
        select 1 from public.commerce_events_v106 e
         where e.id = commerce_event_reconciliations_v106.event_id
           and e.business_id = commerce_event_reconciliations_v106.business_id
           and app.can_see_branch(e.business_id, e.branch_id)
      )
    )
  );
create policy commerce_refund_alloc_v106_finance_read
  on public.commerce_refund_allocations_v106 for select to authenticated
  using (
    app.is_super_admin()
    or (
      app.has_perm(business_id, 'view_finance')
      and exists (
        select 1 from public.commerce_events_v106 e
         where e.id = commerce_refund_allocations_v106.event_id
           and e.business_id = commerce_refund_allocations_v106.business_id
           and app.can_see_branch(e.business_id, e.branch_id)
      )
    )
  );

revoke all on table
  public.reporting_contract_versions_v106,
  public.commerce_events_v106,
  public.commerce_event_conflicts_v106,
  public.commerce_event_reconciliations_v106,
  public.commerce_refund_allocations_v106
from public, anon, authenticated;
grant select on table
  public.reporting_contract_versions_v106,
  public.commerce_events_v106,
  public.commerce_event_conflicts_v106,
  public.commerce_event_reconciliations_v106,
  public.commerce_refund_allocations_v106
to authenticated;

create or replace function public.ingest_external_commerce_event_v106(
  p_business uuid,
  p_branch uuid,
  p_event_type text,
  p_source_system text,
  p_source_event_id text,
  p_idempotency_key text,
  p_occurred_at timestamptz,
  p_currency text,
  p_amount_minor bigint,
  p_payload jsonb default '{}'::jsonb,
  p_actor_type text default 'integration',
  p_actor_id uuid default null,
  p_causation_id text default null,
  p_correlation_id text default null,
  p_supersedes_event_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_contract record;
  v_envelope jsonb;
  v_hash text;
  v_existing public.commerce_events_v106%rowtype;
  v_event public.commerce_events_v106%rowtype;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not (
    app.is_super_admin()
    or (
      lower(btrim(p_event_type)) in ('refund_completed', 'chargeback_opened', 'chargeback_reversed')
      and app.has_perm(p_business, 'refund_sales')
    )
    or (
      lower(btrim(p_event_type)) in ('transaction_completed', 'transaction_voided')
      and app.has_perm(p_business, 'create_sales')
    )
  ) then
    raise exception 'sale-write permission required for this external event'
      using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'branch is outside actor scope' using errcode = '42501';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches b
     where b.id = p_branch and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to business' using errcode = '23503';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'payload must be a JSON object' using errcode = '22023';
  end if;

  select * into strict v_contract
    from app.v106_reporting_contract(p_business, p_branch, p_occurred_at);
  if upper(p_currency) <> v_contract.currency then
    raise exception 'event currency % differs from effective reporting currency %',
      upper(p_currency), v_contract.currency using errcode = '22023';
  end if;

  v_envelope := jsonb_build_object(
    'event_type', lower(btrim(p_event_type)),
    'source_system', lower(btrim(p_source_system)),
    'source_event_id', btrim(p_source_event_id),
    'occurred_at', p_occurred_at,
    'currency', upper(p_currency),
    'amount_minor', p_amount_minor,
    'actor_type', lower(btrim(p_actor_type)),
    'actor_id', p_actor_id,
    'causation_id', p_causation_id,
    'correlation_id', p_correlation_id,
    'supersedes_event_id', p_supersedes_event_id,
    'payload', p_payload
  );
  v_hash := encode(
    extensions.digest(convert_to(v_envelope::text, 'UTF8'), 'sha256'), 'hex'
  );

  select * into v_existing
    from public.commerce_events_v106 e
   where e.business_id = p_business
     and e.source_system = lower(btrim(p_source_system))
     and e.source_event_id = btrim(p_source_event_id)
     and e.event_type = lower(btrim(p_event_type));
  if found then
    if v_existing.payload_hash = v_hash then
      return jsonb_build_object(
        'status', 'replayed',
        'event_id', v_existing.id,
        'payload_hash', v_hash,
        'ledger_changed', false
      );
    end if;
    insert into public.commerce_event_conflicts_v106(
      business_id, existing_event_id, source_system, source_event_id, event_type,
      received_idempotency_key, existing_payload_hash, received_payload_hash,
      received_envelope
    ) values (
      p_business, v_existing.id, lower(btrim(p_source_system)), btrim(p_source_event_id),
      lower(btrim(p_event_type)), btrim(p_idempotency_key),
      v_existing.payload_hash, v_hash, v_envelope
    );
    return jsonb_build_object(
      'status', 'quarantined',
      'event_id', v_existing.id,
      'existing_payload_hash', v_existing.payload_hash,
      'received_payload_hash', v_hash,
      'ledger_changed', false
    );
  end if;

  insert into public.commerce_events_v106(
    business_id, branch_id, event_type, source_system, source_event_id,
    idempotency_key, occurred_at, business_date, reporting_contract_id,
    timezone, currency, amount_minor, actor_type, actor_id, causation_id,
    correlation_id, supersedes_event_id, payload, payload_hash
  ) values (
    p_business, p_branch, lower(btrim(p_event_type)), lower(btrim(p_source_system)),
    btrim(p_source_event_id), btrim(p_idempotency_key), p_occurred_at,
    (p_occurred_at at time zone v_contract.timezone)::date, v_contract.contract_id,
    v_contract.timezone, upper(p_currency), p_amount_minor,
    lower(btrim(p_actor_type)), p_actor_id, nullif(btrim(p_causation_id), ''),
    nullif(btrim(p_correlation_id), ''), p_supersedes_event_id, p_payload, v_hash
  ) returning * into v_event;

  return jsonb_build_object(
    'status', 'accepted',
    'event_id', v_event.id,
    'business_date', v_event.business_date,
    'timezone', v_event.timezone,
    'currency', v_event.currency,
    'payload_hash', v_event.payload_hash,
    'ledger_changed', false
  );
exception
  when unique_violation then
    select * into v_existing
      from public.commerce_events_v106 e
     where e.business_id = p_business
       and e.source_system = lower(btrim(p_source_system))
       and e.idempotency_key = btrim(p_idempotency_key);
    if found and v_existing.payload_hash = v_hash then
      return jsonb_build_object(
        'status', 'replayed',
        'event_id', v_existing.id,
        'payload_hash', v_hash,
        'ledger_changed', false
      );
    end if;
    raise exception 'idempotency key was already used for a different event'
      using errcode = '23505';
end $$;

create or replace function public.reconcile_external_commerce_event_v106(
  p_event uuid,
  p_sale uuid,
  p_idempotency_key text,
  p_allocations jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_event public.commerce_events_v106%rowtype;
  v_sale public.sales%rowtype;
  v_existing public.commerce_event_reconciliations_v106%rowtype;
  v_recon public.commerce_event_reconciliations_v106%rowtype;
  v_line jsonb;
  v_alloc_total bigint := 0;
  v_prior_refunds bigint := 0;
  v_hash text;
  v_item uuid;
  v_payment uuid;
  v_amount bigint;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array' then
    raise exception 'allocations must be a JSON array' using errcode = '22023';
  end if;

  select * into strict v_event from public.commerce_events_v106 where id = p_event;
  if not (
    app.is_super_admin()
    or (
      v_event.event_type in ('refund_completed', 'chargeback_opened', 'chargeback_reversed')
      and app.has_perm(v_event.business_id, 'refund_sales')
    )
    or (
      v_event.event_type in ('transaction_completed', 'transaction_voided')
      and app.has_perm(v_event.business_id, 'create_sales')
    )
  ) then
    raise exception 'sale-write permission required to reconcile this event'
      using errcode = '42501';
  end if;
  if not app.can_see_branch(v_event.business_id, v_event.branch_id) then
    raise exception 'branch is outside actor scope' using errcode = '42501';
  end if;
  select * into strict v_sale
    from public.sales s
   where s.id = p_sale and s.business_id = v_event.business_id
   for update;
  if v_sale.branch_id is distinct from v_event.branch_id then
    raise exception 'event and sale branch differ' using errcode = '22023';
  end if;
  if not app.can_see_branch(v_sale.business_id, v_sale.branch_id) then
    raise exception 'sale branch is outside actor scope' using errcode = '42501';
  end if;
  if v_event.currency <> (
    select c.currency
      from app.v106_reporting_contract(v_sale.business_id, v_sale.branch_id, v_sale.occurred_at) c
  ) then
    raise exception 'event and sale reporting currency differ' using errcode = '22023';
  end if;
  if v_event.event_type = 'transaction_completed'
     and (
       v_sale.reversal_of is not null
       or not v_sale.counts_as_revenue
       or v_sale.amount_cents <= 0
       or v_event.amount_minor <> v_sale.amount_cents
     ) then
    raise exception 'transaction_completed must match one positive completed revenue sale exactly'
      using errcode = '22023';
  end if;
  if v_event.event_type = 'transaction_voided'
     and (
       v_sale.reversal_of is null
       or v_sale.amount_cents >= 0
       or v_event.amount_minor <> v_sale.amount_cents
     ) then
    raise exception 'transaction_voided must match one native reversal sale exactly'
      using errcode = '22023';
  end if;

  v_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'event_id', p_event, 'sale_id', p_sale, 'allocations', p_allocations
  )::text, 'UTF8'), 'sha256'), 'hex');
  select * into v_existing
    from public.commerce_event_reconciliations_v106
   where event_id = p_event;
  if found then
    if v_existing.reconciliation_hash = v_hash then
      return jsonb_build_object(
        'status', 'replayed',
        'reconciliation_id', v_existing.id,
        'ledger_changed', false
      );
    end if;
    raise exception 'event is already reconciled differently'
      using errcode = '23505';
  end if;

  if v_event.event_type = 'refund_completed' then
    if v_sale.reversal_of is not null then
      raise exception 'a refund cannot be allocated to a reversal row'
        using errcode = '22023';
    end if;
    if exists (
      select 1 from public.sales r
       where r.business_id = v_sale.business_id and r.reversal_of = v_sale.id
    ) then
      raise exception 'sale already has a native full reversal'
        using errcode = '22023';
    end if;
    for v_line in select value from jsonb_array_elements(p_allocations)
    loop
      if jsonb_typeof(v_line) <> 'object' then
        raise exception 'each allocation must be a JSON object' using errcode = '22023';
      end if;
      v_item := nullif(v_line->>'sale_item_id', '')::uuid;
      v_payment := nullif(v_line->>'payment_id', '')::uuid;
      v_amount := (v_line->>'amount_minor')::bigint;
      if v_amount <= 0 then
        raise exception 'allocation amount_minor must be positive' using errcode = '22023';
      end if;
      if v_item is not null and not exists (
        select 1 from public.sale_items i
         where i.id = v_item and i.sale_id = v_sale.id
           and i.business_id = v_sale.business_id
      ) then
        raise exception 'sale_item allocation target is outside the sale'
          using errcode = '23503';
      end if;
      if v_payment is not null and not exists (
        select 1 from public.payments p
         where p.id = v_payment and p.sale_id = v_sale.id
           and p.business_id = v_sale.business_id
      ) then
        raise exception 'payment allocation target is outside the sale'
          using errcode = '23503';
      end if;
      v_alloc_total := v_alloc_total + v_amount;
    end loop;
    if v_alloc_total <> abs(v_event.amount_minor) then
      raise exception 'refund allocations % do not equal event amount %',
        v_alloc_total, abs(v_event.amount_minor) using errcode = '22023';
    end if;
    select coalesce(sum(a.amount_minor), 0) into v_prior_refunds
      from public.commerce_refund_allocations_v106 a
      join public.commerce_event_reconciliations_v106 r
        on r.id = a.reconciliation_id and r.business_id = a.business_id
     where a.business_id = v_sale.business_id and a.sale_id = v_sale.id;
    if v_prior_refunds + v_alloc_total > v_sale.amount_cents then
      raise exception 'cumulative external refunds exceed the original sale'
        using errcode = '22023';
    end if;
  elsif p_allocations <> '[]'::jsonb then
    raise exception 'only refund_completed events may carry allocations'
      using errcode = '22023';
  end if;

  insert into public.commerce_event_reconciliations_v106(
    business_id, event_id, sale_id, idempotency_key, reconciliation_hash
  ) values (
    v_event.business_id, v_event.id, v_sale.id, btrim(p_idempotency_key), v_hash
  ) returning * into v_recon;

  if v_event.event_type = 'refund_completed' then
    for v_line in select value from jsonb_array_elements(p_allocations)
    loop
      insert into public.commerce_refund_allocations_v106(
        business_id, reconciliation_id, event_id, sale_id,
        sale_item_id, payment_id, amount_minor
      ) values (
        v_event.business_id, v_recon.id, v_event.id, v_sale.id,
        nullif(v_line->>'sale_item_id', '')::uuid,
        nullif(v_line->>'payment_id', '')::uuid,
        (v_line->>'amount_minor')::bigint
      );
    end loop;
  end if;

  return jsonb_build_object(
    'status', 'reconciled',
    'reconciliation_id', v_recon.id,
    'event_id', v_event.id,
    'sale_id', v_sale.id,
    'allocated_refund_minor', v_alloc_total,
    'ledger_changed', false
  );
end $$;

create or replace function public.get_revenue_truth_v106(
  p_business uuid,
  p_from date,
  p_to date,
  p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp()
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_currency text;
  v_period_currency text;
  v_currency_count integer;
  v_timezone text;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_to <= p_from then
    raise exception 'p_to must be after p_from' using errcode = '22023';
  end if;
  if not (app.is_super_admin() or app.has_perm(p_business, 'view_finance')) then
    raise exception 'finance permission required' using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'branch is outside actor scope' using errcode = '42501';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches b
     where b.id = p_branch and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to business' using errcode = '23503';
  end if;
  select upper(b.currency) into strict v_currency
    from public.businesses b where b.id = p_business;
  if p_branch is null then
    v_timezone := 'per_outlet';
  else
    select b.timezone into strict v_timezone
      from public.branches b
     where b.id = p_branch and b.business_id = p_business;
  end if;
  select count(distinct c.currency), min(c.currency)
    into v_currency_count, v_period_currency
    from public.sales s
    cross join lateral app.v106_reporting_contract(
      s.business_id, s.branch_id, s.occurred_at
    ) c
   where s.business_id = p_business
     and s.reversal_of is null
     and s.counts_as_revenue
     and s.created_at <= p_as_of
     and (p_branch is null or s.branch_id = p_branch)
     and (s.occurred_at at time zone c.timezone)::date >= p_from
     and (s.occurred_at at time zone c.timezone)::date < p_to;
  if v_currency_count > 1 then
    raise exception 'cross-currency reporting periods are not supported'
      using errcode = '22023';
  end if;
  if v_currency_count = 1 then
    v_currency := v_period_currency;
  end if;

  with original_sales as materialized (
    select s.id,
           app.v111_effective_client_id(s.business_id, s.client_id) as client_id,
           s.amount_cents, s.occurred_at, s.created_at,
           s.branch_id, c.timezone, c.currency,
           coalesce((
             select abs(sum(r.amount_cents))
             from public.sales r
              cross join lateral app.v106_reporting_contract(
                r.business_id, r.branch_id, r.occurred_at
              ) rc
              where r.business_id = s.business_id
                and r.reversal_of = s.id
                and r.created_at <= p_as_of
                and (r.occurred_at at time zone rc.timezone)::date < p_to
           ), 0)::bigint as native_refund_minor,
           coalesce((
             select sum(a.amount_minor)
               from public.commerce_refund_allocations_v106 a
               join public.commerce_event_reconciliations_v106 rr
                 on rr.id = a.reconciliation_id and rr.business_id = a.business_id
               join public.commerce_events_v106 e
                 on e.id = a.event_id and e.business_id = a.business_id
              where a.business_id = s.business_id
                and a.sale_id = s.id
                and rr.created_at <= p_as_of
                and e.business_date < p_to
           ), 0)::bigint as external_refund_minor,
           exists (
             select 1 from public.sale_items i
              where i.business_id = s.business_id and i.sale_id = s.id
           ) as is_itemized,
           exists (
             select 1
               from public.commerce_event_reconciliations_v106 rr
               join public.commerce_events_v106 e
                 on e.id = rr.event_id
                and e.business_id = rr.business_id
              where rr.business_id = s.business_id
                and rr.sale_id = s.id
                and rr.created_at <= p_as_of
                and e.received_at <= p_as_of
                and e.event_type = 'transaction_completed'
                and e.branch_id is not distinct from s.branch_id
                and e.currency = c.currency
                and e.amount_minor = s.amount_cents
           ) as is_reconciled
      from public.sales s
      cross join lateral app.v106_reporting_contract(
        s.business_id, s.branch_id, s.occurred_at
      ) c
     where s.business_id = p_business
       and s.reversal_of is null
       and s.counts_as_revenue
       and s.created_at <= p_as_of
       and (p_branch is null or s.branch_id = p_branch)
       and (s.occurred_at at time zone c.timezone)::date >= p_from
       and (s.occurred_at at time zone c.timezone)::date < p_to
  ), eligible as (
    select *,
      app.v106_sale_residual_minor(id, p_to, p_as_of) as net_minor
      from original_sales
  ), totals as (
    select
      coalesce(sum(net_minor), 0)::bigint as known_revenue,
      coalesce(sum(net_minor) filter (where client_id is not null), 0)::bigint
        as identified_revenue,
      coalesce(sum(net_minor) filter (where client_id is null), 0)::bigint
        as anonymous_revenue,
      count(*) filter (where net_minor > 0)::bigint as completed_transactions,
      count(*) filter (where net_minor > 0 and client_id is not null)::bigint
        as identified_transactions,
      count(*) filter (where net_minor > 0 and client_id is null)::bigint
        as anonymous_transactions,
      count(*) filter (where net_minor > 0 and is_itemized)::bigint
        as itemized_transactions,
      count(*) filter (where net_minor > 0 and is_reconciled)::bigint
        as reconciled_transactions,
      max(occurred_at) as latest_sale_occurred_at,
      max(created_at) as latest_sale_recorded_at,
      count(*)::bigint as cohort_rows
    from eligible
  ), event_freshness as (
    select max(e.received_at) as latest_external_event_received_at
      from public.commerce_events_v106 e
     where e.business_id = p_business
       and (p_branch is null or e.branch_id = p_branch)
       and e.received_at <= p_as_of
  ), conflict_count as (
    select count(*)::bigint as conflicts
      from public.commerce_event_conflicts_v106 q
      join public.commerce_events_v106 e
        on e.id = q.existing_event_id and e.business_id = q.business_id
     where q.business_id = p_business and q.created_at <= p_as_of
       and (p_branch is null or e.branch_id = p_branch)
  )
  select jsonb_build_object(
    'contract_version', 'v106.1',
    'generated_at', clock_timestamp(),
    'as_of', p_as_of,
    'scope', jsonb_build_object(
      'business_id', p_business,
      'branch_id', p_branch,
      'period', jsonb_build_object(
        'from', p_from,
        'to', p_to,
        'interval', '[from,to)'
      ),
      'timezone', v_timezone,
      'timezone_contract', case when p_branch is null
        then 'per_outlet_effective_timezone'
        else 'selected_outlet_effective_timezone'
      end,
      'currency', v_currency
    ),
    'status', case when t.completed_transactions = 0 then 'no_data' else 'ok' end,
    'totals', jsonb_build_object(
      'known_revenue_minor', t.known_revenue,
      'identified_revenue_minor', t.identified_revenue,
      'anonymous_revenue_minor', t.anonymous_revenue,
      'completed_transactions', t.completed_transactions,
      'identified_transactions', t.identified_transactions,
      'anonymous_transactions', t.anonymous_transactions,
      'itemized_transactions', t.itemized_transactions
    ),
    'coverage', jsonb_build_object(
      'identity_revenue_pct', case when t.known_revenue = 0 then null
        else round(100 * t.identified_revenue::numeric / t.known_revenue, 2) end,
      'identity_transaction_pct', case when t.completed_transactions = 0 then null
        else round(100 * t.identified_transactions::numeric / t.completed_transactions, 2) end,
      'itemization_transaction_pct', case when t.completed_transactions = 0 then null
        else round(100 * t.itemized_transactions::numeric / t.completed_transactions, 2) end,
      'reconciled_transaction_pct', case when t.completed_transactions = 0 then null
        else round(100 * t.reconciled_transactions::numeric / t.completed_transactions, 2) end
    ),
    'freshness', jsonb_build_object(
      'latest_sale_occurred_at', t.latest_sale_occurred_at,
      'latest_sale_recorded_at', t.latest_sale_recorded_at,
      'latest_external_event_received_at', f.latest_external_event_received_at,
      'reconciliation_conflicts', q.conflicts
    ),
    'formula_metadata', jsonb_build_object(
      'version', 'revenue_truth_v106_1',
      'eligible_sale', 'original sale with counts_as_revenue=true and created_at<=as_of',
      'period_assignment', 'sale occurred_at converted by its effective outlet timezone',
      'known_revenue', 'sum(max(original_amount-native_full_reversal-reconciled_external_refund_allocations,0))',
      'identity_split', 'identified iff the v111 current-attribution resolver returns a client_id; otherwise anonymous',
      'identity_attribution', 'immutable sales.client_id is resolved through app.v111_effective_client_id for current synchronized reporting',
      'invariant', 'known_revenue_minor = identified_revenue_minor + anonymous_revenue_minor',
      'refund_cutoff', 'refund business date is before report p_to and recorded by as_of',
      'zero_denominator', 'coverage ratios are null'
    ),
    'limitations', jsonb_build_array(
      'Known revenue covers the Nestly sales ledger; it is not merchant-total revenue until a POS adapter proves source completeness.',
      'External transaction observations do not affect totals until reconciled to an existing sale.',
      'Legacy pre-v106 facts use an explicit migration-time timezone/currency assumption.',
      'Native reversals are full-sale only; v106 external allocations provide partial-refund attribution without rewriting old ledgers.'
    )
  ) into v_result
  from totals t cross join event_freshness f cross join conflict_count q;

  if (v_result #>> '{totals,known_revenue_minor}')::bigint <>
     (v_result #>> '{totals,identified_revenue_minor}')::bigint +
     (v_result #>> '{totals,anonymous_revenue_minor}')::bigint then
    raise exception 'v106 revenue identity invariant failed'
      using errcode = 'data_exception';
  end if;
  return v_result;
end $$;

revoke all on function app.v106_assert_timezone(text)
  from public, anon, authenticated;
revoke all on function app.v106_reporting_contract(uuid, uuid, timestamptz)
  from public, anon, authenticated;
revoke all on function app.v111_effective_client_id(uuid, uuid)
  from public, anon, authenticated;
revoke all on function app.v106_append_reporting_contract()
  from public, anon, authenticated;
revoke all on function app.v106_append_only_guard()
  from public, anon, authenticated;
revoke all on function public.ingest_external_commerce_event_v106(
  uuid, uuid, text, text, text, text, timestamptz, text, bigint, jsonb,
  text, uuid, text, text, uuid
) from public, anon;
revoke all on function public.reconcile_external_commerce_event_v106(
  uuid, uuid, text, jsonb
) from public, anon;
revoke all on function public.get_revenue_truth_v106(
  uuid, date, date, uuid, timestamptz
) from public, anon;
grant execute on function public.ingest_external_commerce_event_v106(
  uuid, uuid, text, text, text, text, timestamptz, text, bigint, jsonb,
  text, uuid, text, text, uuid
) to authenticated;
grant execute on function public.reconcile_external_commerce_event_v106(
  uuid, uuid, text, jsonb
) to authenticated;
grant execute on function public.get_revenue_truth_v106(
  uuid, date, date, uuid, timestamptz
) to authenticated;

commit;
