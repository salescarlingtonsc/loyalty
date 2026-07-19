-- FRENLY v20 financial engine
--
-- Repository-only post-transfer migration. Do not apply while the Supabase transfer is
-- running. Applies after v10.1, v11a/v11b, v12/v12a and v17. Commission remains
-- v12 percentage-only: sales.commission_rate_bps + sales.commission_resolved_at.
--
-- Contract:
--   * full sale reversal only; partial refunds and un-refunds are rejected
--   * supported original sale kinds: service, retail, quick_sale
--   * unsupported original sale kinds: gift_card, package, membership
--   * launch refunds: cash and exactly-proven store credit only
--   * store-credit tender is one atomic RPC: negative credit_ledger + positive payment
--   * raw refunds plus credit/gift-card tender payments cannot be posted through record_payment()
--   * points clawback is launch-disabled until earn/redemption provenance and policy exist
--
-- The migration intentionally preserves original rows. Every correction is an append-only
-- linked fact, except for legacy mutable state that must remain compatible with retained
-- points-batch expiry/FIFO consumption and referral qualification workflows.

begin;

-- v13 was review-only and is permanently outside the v20 apply chain. Refuse to apply over
-- any flat-commission artifact instead of silently changing the v12 percentage-only contract.
do $$
begin
  if exists (
       select 1
         from information_schema.columns
        where table_schema = 'public'
          and table_name in ('sales', 'services')
          and column_name = 'commission_flat_cents'
     )
     or exists (
       select 1
         from pg_catalog.pg_proc p
         join pg_catalog.pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'app'
          and p.proname = 'commission_flat_cents'
     ) then
    raise exception 'v20 requires the v12 percentage-only commission contract; v13 flat commission is tombstoned'
      using errcode = 'feature_not_supported';
  end if;
end $$;

-- v10.1/v17 intentionally did not filter inactive staff. That is unsafe for launch: a
-- disabled login retained every permission and branch assignment. Replace both predicates
-- before any v20 policy or RPC uses them.
create or replace function app.has_perm(p_business uuid, p_perm text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.staff s
     where s.business_id = p_business
       and s.user_id = auth.uid()
       and s.active
       and p_perm = any (app.role_perms(s.role))
  )
$$;

create or replace function app.can_see_branch(p_business uuid, p_branch uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when auth.uid() is null then false
    when app.is_super_admin() then true
    else exists (
      select 1
        from public.staff s
       where s.business_id = p_business
         and s.user_id = auth.uid()
         and s.active
         and (
           app.role_class(s.role) in ('owner', 'admin')
           or (
             p_branch is not null
             and exists (
               select 1
                 from public.staff_branches sb
                where sb.business_id = p_business
                  and sb.staff_id = s.id
                  and sb.branch_id = p_branch
             )
           )
         )
    )
  end
$$;

revoke execute on function app.has_perm(uuid, text) from public, anon;
grant execute on function app.has_perm(uuid, text) to authenticated;
revoke execute on function app.can_see_branch(uuid, uuid) from public, anon;
grant execute on function app.can_see_branch(uuid, uuid) to authenticated;

-- =====================================================================================
-- 1. Reversal columns and structural guards on sales
-- =====================================================================================

alter table public.sales
  add column if not exists reversal_of uuid,
  add column if not exists reversal_reason text,
  add column if not exists reversal_actor uuid,
  add column if not exists reversal_idempotency_key text;

comment on column public.sales.reversal_of is
  'v20: points to the ORIGINAL sale this append-only negative row reverses. Full reversal only.';
comment on column public.sales.reversal_reason is
  'v20: mandatory human reason captured by public.reverse_sale()/refund_sale().';
comment on column public.sales.reversal_actor is
  'v20: auth.uid() that posted the reversal.';
comment on column public.sales.reversal_idempotency_key is
  'v20: business-scoped idempotency key for the reversal RPC.';

alter table public.sales
  drop constraint if exists sales_reversal_of_fk,
  drop constraint if exists sales_reversal_not_self_check,
  drop constraint if exists sales_reversal_metadata_check,
  drop constraint if exists sales_amount_cents_check;

alter table public.sales
  add constraint sales_reversal_of_fk foreign key (reversal_of, business_id)
    references public.sales(id, business_id) on delete no action,
  add constraint sales_reversal_not_self_check
    check (reversal_of is null or reversal_of <> id),
  add constraint sales_reversal_metadata_check check (
    (
      reversal_of is null
      and reversal_reason is null
      and reversal_actor is null
      and reversal_idempotency_key is null
    )
    or (
      reversal_of is not null
      and amount_cents < 0
      and appointment_id is null
      and reversal_actor is not null
      and reversal_idempotency_key is not null
      and length(btrim(coalesce(reversal_reason, ''))) >= 10
    )
  ),
  add constraint sales_amount_cents_check check (
    (reversal_of is null and amount_cents >= 0)
    or
    (reversal_of is not null and amount_cents < 0)
  );

create unique index if not exists sales_full_reversal_once_uidx
  on public.sales(reversal_of) where reversal_of is not null;
create unique index if not exists sales_reversal_idempotency_uidx
  on public.sales(business_id, reversal_idempotency_key)
  where reversal_idempotency_key is not null;
create index if not exists sales_reversal_parent_idx
  on public.sales(reversal_of) where reversal_of is not null;

-- Direct INSERTs of reversal rows through PostgREST would bypass the downstream financial
-- corrections. Block them structurally and open a one-row token only inside reverse_sale().
create or replace function app.sales_reversal_insert_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sale_token text;
  v_original_token text;
begin
  if new.reversal_of is null then
    return new;
  end if;

  v_sale_token := nullif(current_setting('app.sale_reversal_insert_id', true), '');
  v_original_token := nullif(current_setting('app.sale_reversal_original_id', true), '');

  if v_sale_token is distinct from new.id::text
     or v_original_token is distinct from new.reversal_of::text then
    raise exception 'sale reversal rows must be created through public.reverse_sale()'
      using errcode = '42501';
  end if;

  return new;
end $$;

revoke execute on function app.sales_reversal_insert_guard() from public, anon, authenticated;

drop trigger if exists trg_sale_reversal_insert_guard on public.sales;
create trigger trg_sale_reversal_insert_guard
  before insert on public.sales
  for each row execute function app.sales_reversal_insert_guard();

create or replace function app.enforce_sale_reversal_bounds()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.sales%rowtype;
  v_reversed integer;
begin
  if new.reversal_of is null then
    return new;
  end if;

  select * into o
    from public.sales
   where id = new.reversal_of
     and business_id = new.business_id;

  if not found then
    raise exception 'original sale not found for reversal %', new.id;
  end if;
  if o.reversal_of is not null then
    raise exception 'cannot reverse a reversal sale %', o.id;
  end if;
  if -new.amount_cents <> o.amount_cents then
    raise exception 'v20 supports full reversal only: expected %, got %',
      o.amount_cents, -new.amount_cents;
  end if;

  select coalesce(-sum(r.amount_cents), 0)::integer
    into v_reversed
    from public.sales r
   where r.business_id = o.business_id
     and r.reversal_of = o.id;

  if v_reversed > o.amount_cents then
    raise exception 'reversal total % exceeds original sale amount % for sale %',
      v_reversed, o.amount_cents, o.id;
  end if;

  return new;
end $$;

revoke execute on function app.enforce_sale_reversal_bounds() from public, anon, authenticated;

drop trigger if exists trg_sales_reversal_bounds on public.sales;
create constraint trigger trg_sales_reversal_bounds
  after insert or update on public.sales
  deferrable initially immediate
  for each row execute function app.enforce_sale_reversal_bounds();

-- =====================================================================================
-- 2. Audit/link tables
-- =====================================================================================

-- The user key is reserved here before any financial child row is written. request_payload
-- is canonical jsonb and is the authority; request_hash is an indexed/debuggable fingerprint,
-- not an authorization credential. A replay succeeds only when both payload and actor match.
create table if not exists public.financial_operations (
  id uuid primary key,
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id uuid,
  sale_id uuid,
  operation_type text not null
    check (operation_type in ('sale_reversal', 'credit_tender', 'quick_sale')),
  actor uuid not null,
  idempotency_key text not null check (length(btrim(idempotency_key)) >= 8),
  request_payload jsonb not null check (jsonb_typeof(request_payload) = 'object'),
  request_hash text not null check (
    length(request_hash) = 32 and request_hash = md5(request_payload::text)
  ),
  status text not null default 'reserved' check (status in ('reserved', 'completed')),
  result jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint financial_operations_sale_fk foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete no action,
  constraint financial_operations_branch_fk foreign key (branch_id, business_id)
    references public.branches(id, business_id) on delete no action,
  constraint financial_operations_id_business_uk unique (id, business_id),
  constraint financial_operations_idempotency unique
    (business_id, operation_type, idempotency_key),
  constraint financial_operations_completion_check check (
    (status = 'reserved' and result is null and completed_at is null)
    or
    (status = 'completed' and result is not null and completed_at is not null)
  ),
  constraint financial_operations_sale_lifecycle_check check (
    (operation_type = 'quick_sale'
      and ((status = 'reserved' and sale_id is null)
           or (status = 'completed' and sale_id is not null)))
    or
    (operation_type <> 'quick_sale' and sale_id is not null)
  )
);

create index if not exists financial_operations_sale_time
  on public.financial_operations(business_id, sale_id, created_at);

alter table public.financial_operations enable row level security;
drop policy if exists financial_operations_select on public.financial_operations;
create policy financial_operations_select
  on public.financial_operations
  for select to authenticated
  using (
    app.has_perm(business_id, 'view_finance')
    and app.can_see_branch(business_id, branch_id)
  );
revoke all privileges on table public.financial_operations from public, anon, authenticated;
grant select on public.financial_operations to authenticated;

create or replace function app.financial_operation_write_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token text;
begin
  if tg_op = 'INSERT' then
    v_token := nullif(current_setting('app.financial_operation_insert_id', true), '');
    if v_token is distinct from new.id::text then
      raise exception 'financial operations may only be reserved by a financial RPC'
        using errcode = '42501';
    end if;
    if (new.operation_type = 'quick_sale' and new.sale_id is not null)
       or (new.operation_type <> 'quick_sale' and new.sale_id is null) then
      raise exception 'financial operation reservation has an invalid sale lifecycle'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    raise exception 'financial_operations is append-only: DELETE is not permitted'
      using errcode = 'restrict_violation';
  end if;

  v_token := nullif(current_setting('app.financial_operation_complete_id', true), '');
  if v_token is distinct from old.id::text
     or old.status <> 'reserved'
     or new.status <> 'completed'
     or (new.id, new.business_id, new.branch_id, new.operation_type,
         new.actor, new.idempotency_key, new.request_payload, new.request_hash, new.created_at)
        is distinct from
        (old.id, old.business_id, old.branch_id, old.operation_type,
         old.actor, old.idempotency_key, old.request_payload, old.request_hash, old.created_at)
     or (
       old.operation_type = 'quick_sale'
       and (old.sale_id is not null or new.sale_id is null)
     )
     or (
       old.operation_type <> 'quick_sale'
       and new.sale_id is distinct from old.sale_id
     )
     or new.result is null
     or new.completed_at is null then
    raise exception 'financial operation % may only transition reserved -> completed', old.id
      using errcode = 'restrict_violation';
  end if;

  return new;
end $$;

revoke execute on function app.financial_operation_write_guard()
  from public, anon, authenticated;

drop trigger if exists trg_financial_operation_write_guard on public.financial_operations;
create trigger trg_financial_operation_write_guard
  before insert or update or delete on public.financial_operations
  for each row execute function app.financial_operation_write_guard();

create table if not exists public.sale_reversal_audits (
  id uuid primary key default gen_random_uuid(),
  operation_id uuid not null,
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id uuid,
  original_sale_id uuid not null,
  reversal_sale_id uuid not null,
  actor uuid,
  reason text not null check (length(btrim(reason)) >= 10),
  idempotency_key text not null,
  reversed_cents integer not null check (reversed_cents > 0),
  refunded_payment_cents integer not null default 0 check (refunded_payment_cents >= 0),
  credit_restored_cents integer not null default 0 check (credit_restored_cents >= 0),
  points_clawed_back integer not null default 0 check (points_clawed_back >= 0),
  points_batch_remaining_decremented integer not null default 0
    check (points_batch_remaining_decremented >= 0),
  referral_reversed boolean not null default false,
  restock_policy text not null default 'none' check (restock_policy in ('none')),
  effects jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint sale_reversal_audits_operation_fk foreign key (operation_id, business_id)
    references public.financial_operations(id, business_id) on delete no action,
  constraint sale_reversal_audits_original_fk foreign key (original_sale_id, business_id)
    references public.sales(id, business_id) on delete no action,
  constraint sale_reversal_audits_reversal_fk foreign key (reversal_sale_id, business_id)
    references public.sales(id, business_id) on delete no action,
  constraint sale_reversal_audits_branch_fk foreign key (branch_id, business_id)
    references public.branches(id, business_id) on delete no action,
  constraint sale_reversal_audits_original_once unique (original_sale_id),
  constraint sale_reversal_audits_reversal_once unique (reversal_sale_id),
  constraint sale_reversal_audits_operation_once unique (operation_id),
  constraint sale_reversal_audits_idempotency unique (business_id, idempotency_key)
);

create index if not exists sale_reversal_audits_business_time
  on public.sale_reversal_audits(business_id, created_at);

alter table public.sale_reversal_audits enable row level security;
drop policy if exists sale_reversal_audits_select on public.sale_reversal_audits;
create policy sale_reversal_audits_select
  on public.sale_reversal_audits
  for select to authenticated
  using (
    app.has_perm(business_id, 'view_finance')
    and app.can_see_branch(business_id, branch_id)
  );
revoke all privileges on table public.sale_reversal_audits from public, anon, authenticated;
grant select on public.sale_reversal_audits to authenticated;

drop trigger if exists trg_sale_reversal_audits_append_only on public.sale_reversal_audits;
create trigger trg_sale_reversal_audits_append_only
  before update or delete on public.sale_reversal_audits
  for each row execute function app.forbid_mutation();

create table if not exists public.sale_reversal_payment_links (
  id uuid primary key default gen_random_uuid(),
  operation_id uuid not null,
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id uuid,
  original_sale_id uuid not null,
  reversal_sale_id uuid not null,
  refund_payment_id uuid not null,
  method text not null,
  amount_cents integer not null check (amount_cents > 0),
  source_payment_ids uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  constraint sale_reversal_payment_links_operation_fk foreign key (operation_id, business_id)
    references public.financial_operations(id, business_id) on delete no action,
  constraint sale_reversal_payment_links_original_fk foreign key (original_sale_id, business_id)
    references public.sales(id, business_id) on delete no action,
  constraint sale_reversal_payment_links_reversal_fk foreign key (reversal_sale_id, business_id)
    references public.sales(id, business_id) on delete no action,
  constraint sale_reversal_payment_links_payment_fk foreign key (refund_payment_id, business_id)
    references public.payments(id, business_id) on delete no action,
  constraint sale_reversal_payment_links_branch_fk foreign key (branch_id, business_id)
    references public.branches(id, business_id) on delete no action,
  constraint sale_reversal_payment_links_payment_once unique (refund_payment_id)
);

create index if not exists sale_reversal_payment_links_reversal
  on public.sale_reversal_payment_links(reversal_sale_id);
create index if not exists sale_reversal_payment_links_operation
  on public.sale_reversal_payment_links(operation_id);

alter table public.sale_reversal_payment_links enable row level security;
drop policy if exists sale_reversal_payment_links_select on public.sale_reversal_payment_links;
create policy sale_reversal_payment_links_select
  on public.sale_reversal_payment_links
  for select to authenticated
  using (
    app.has_perm(business_id, 'view_finance')
    and app.can_see_branch(business_id, branch_id)
  );
revoke all privileges on table public.sale_reversal_payment_links from public, anon, authenticated;
grant select on public.sale_reversal_payment_links to authenticated;

drop trigger if exists trg_sale_reversal_payment_links_append_only
  on public.sale_reversal_payment_links;
create trigger trg_sale_reversal_payment_links_append_only
  before update or delete on public.sale_reversal_payment_links
  for each row execute function app.forbid_mutation();

-- =====================================================================================
-- 3. Store-credit tender ledger links
-- =====================================================================================

alter table public.credit_ledger
  add column if not exists sale_id uuid,
  add column if not exists payment_id uuid,
  add column if not exists actor uuid,
  add column if not exists idempotency_key text;

alter table public.credit_ledger
  drop constraint if exists credit_ledger_client_id_fkey,
  drop constraint if exists credit_ledger_id_business_uk,
  drop constraint if exists credit_ledger_client_same_tenant,
  drop constraint if exists credit_ledger_sale_same_tenant,
  drop constraint if exists credit_ledger_payment_same_tenant;

alter table public.credit_ledger
  add constraint credit_ledger_id_business_uk unique (id, business_id),
  add constraint credit_ledger_client_same_tenant foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete no action,
  add constraint credit_ledger_sale_same_tenant foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete no action,
  add constraint credit_ledger_payment_same_tenant foreign key (payment_id, business_id)
    references public.payments(id, business_id) on delete no action;

create unique index if not exists credit_ledger_idempotency_uidx
  on public.credit_ledger(business_id, idempotency_key)
  where idempotency_key is not null;
create index if not exists credit_ledger_sale_idx
  on public.credit_ledger(sale_id) where sale_id is not null;
create index if not exists credit_ledger_payment_idx
  on public.credit_ledger(payment_id) where payment_id is not null;

alter table public.points_ledger
  add column if not exists actor uuid;

alter table public.points_ledger
  drop constraint if exists points_ledger_client_id_fkey,
  drop constraint if exists points_ledger_sale_id_fkey,
  drop constraint if exists points_ledger_client_same_tenant,
  drop constraint if exists points_ledger_sale_same_tenant;

alter table public.points_ledger
  add constraint points_ledger_client_same_tenant foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete no action,
  add constraint points_ledger_sale_same_tenant foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete no action;

create table if not exists public.credit_tenders (
  id uuid primary key default gen_random_uuid(),
  operation_id uuid not null,
  business_id uuid not null references public.businesses(id) on delete cascade,
  sale_id uuid not null,
  payment_id uuid not null,
  credit_ledger_id uuid not null,
  client_id uuid not null,
  branch_id uuid,
  actor uuid,
  amount_cents integer not null check (amount_cents > 0),
  idempotency_key text not null,
  reason text,
  balance_before_cents integer not null,
  balance_after_cents integer not null,
  created_at timestamptz not null default now(),
  constraint credit_tenders_operation_fk foreign key (operation_id, business_id)
    references public.financial_operations(id, business_id) on delete no action,
  constraint credit_tenders_sale_fk foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete no action,
  constraint credit_tenders_payment_fk foreign key (payment_id, business_id)
    references public.payments(id, business_id) on delete no action,
  constraint credit_tenders_credit_fk foreign key (credit_ledger_id, business_id)
    references public.credit_ledger(id, business_id) on delete no action,
  constraint credit_tenders_client_fk foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete no action,
  constraint credit_tenders_branch_fk foreign key (branch_id, business_id)
    references public.branches(id, business_id) on delete no action,
  constraint credit_tenders_idempotency unique (business_id, idempotency_key),
  constraint credit_tenders_operation_once unique (operation_id),
  constraint credit_tenders_payment_once unique (payment_id),
  constraint credit_tenders_credit_once unique (credit_ledger_id)
);

create index if not exists credit_tenders_sale_idx on public.credit_tenders(sale_id);
create index if not exists credit_tenders_client_time on public.credit_tenders(client_id, created_at);

alter table public.credit_tenders enable row level security;
drop policy if exists credit_tenders_select on public.credit_tenders;
create policy credit_tenders_select
  on public.credit_tenders
  for select to authenticated
  using (
    app.has_perm(business_id, 'view_finance')
    and app.can_see_branch(business_id, branch_id)
  );
revoke all privileges on table public.credit_tenders from public, anon, authenticated;
grant select on public.credit_tenders to authenticated;

drop trigger if exists trg_credit_tenders_append_only on public.credit_tenders;
create trigger trg_credit_tenders_append_only
  before update or delete on public.credit_tenders
  for each row execute function app.forbid_mutation();

-- Every payment write is internal. The row UUID token binds one statement and the scope binds
-- its semantics; authenticated cannot INSERT the table even if it sets a matching custom GUC.
create or replace function app.payment_write_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment_token text;
  v_scope text;
begin
  v_payment_token := nullif(current_setting('app.payment_insert_id', true), '');
  v_scope := nullif(current_setting('app.payment_write_scope', true), '');
  if v_payment_token is distinct from new.id::text then
    raise exception 'payments may only be posted through an approved payment RPC'
      using errcode = '42501';
  end if;

  if new.method = 'gift_card' then
    raise exception 'gift-card tender is disabled until payments link to immutable gift-card consumption evidence'
      using errcode = 'feature_not_supported';
  end if;

  if v_scope = 'record_payment' then
    if new.kind not in ('payment', 'deposit', 'no_show_fee')
       or new.method in ('credit', 'gift_card') then
      raise exception 'record_payment may only post non-credit positive payment/deposit/no-show rows'
        using errcode = '42501';
    end if;
  elsif v_scope = 'credit_tender' then
    if new.method <> 'credit' or new.kind <> 'payment' or new.amount_cents <= 0 then
      raise exception 'credit_tender payment shape is invalid'
        using errcode = '42501';
    end if;
  elsif v_scope = 'sale_reversal' then
    if new.kind <> 'refund'
       or new.method not in ('cash', 'credit')
       or new.amount_cents >= 0
       or new.sale_id is null then
      raise exception 'sale_reversal may only post negative cash/store-credit refunds linked to a sale'
        using errcode = '42501';
    end if;
  else
    raise exception 'unknown internal payment write scope'
      using errcode = '42501';
  end if;

  if new.sale_id is not null then
    if exists (
      select 1
        from public.sales s
       where s.id = new.sale_id
         and s.business_id = new.business_id
         and s.reversal_of is not null
    ) then
      raise exception 'payments cannot attach to a reversal sale';
    end if;

    if new.kind <> 'refund' and exists (
      select 1
        from public.sales r
       where r.business_id = new.business_id
         and r.reversal_of = new.sale_id
    ) then
      raise exception 'positive payment is forbidden on a fully reversed sale'
        using errcode = 'check_violation';
    end if;
  end if;

  if new.kind <> 'refund' and new.sale_id is null and new.appointment_id is not null
     and exists (
       select 1
         from public.sales s
         join public.sales r
           on r.business_id = s.business_id
          and r.reversal_of = s.id
        where s.business_id = new.business_id
          and s.appointment_id = new.appointment_id
     ) then
    raise exception 'positive appointment payment is forbidden after its completed sale was reversed'
      using errcode = 'check_violation';
  end if;

  return new;
end $$;

revoke execute on function app.payment_write_guard() from public, anon, authenticated;

drop trigger if exists trg_payment_credit_tender_guard on public.payments;
drop trigger if exists trg_payment_write_guard on public.payments;
create trigger trg_payment_write_guard
  before insert on public.payments
  for each row execute function app.payment_write_guard();

drop policy if exists payments_insert on public.payments;
revoke all privileges on table public.payments from public, anon, authenticated;
grant select on public.payments to authenticated;

-- Both loyalty ledgers are internal append-only journals. Cross-tenant client/sale FKs above
-- protect every route; the token/scope guard narrows writes to the sale trigger or named RPCs.
create or replace function app.loyalty_ledger_write_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token text;
  v_scope text;
begin
  if tg_table_name = 'points_ledger' then
    v_token := nullif(current_setting('app.points_ledger_insert_id', true), '');
    v_scope := nullif(current_setting('app.points_ledger_write_scope', true), '');
    if v_token is distinct from new.id::text
       or v_scope not in (
         'sale_trigger', 'redeem_points', 'adjust_points', 'points_expiry'
       ) then
      raise exception 'points_ledger may only be appended by approved loyalty routes'
        using errcode = '42501';
    end if;
    if (v_scope = 'sale_trigger'
        and (new.entry_type <> 'earn' or new.points <= 0 or new.sale_id is null))
       or (v_scope = 'redeem_points'
           and (new.entry_type <> 'redeem' or new.points >= 0 or new.sale_id is not null))
       or (v_scope = 'adjust_points'
           and (new.entry_type <> 'adjust' or new.points = 0 or new.sale_id is not null
                or new.actor is distinct from auth.uid()))
       or (v_scope = 'points_expiry'
           and (new.entry_type <> 'expire' or new.points >= 0 or new.sale_id is not null
                or new.actor is not null)) then
      raise exception 'points ledger entry does not match its internal route'
        using errcode = 'check_violation';
    end if;
  elsif tg_table_name = 'credit_ledger' then
    v_token := nullif(current_setting('app.credit_ledger_insert_id', true), '');
    v_scope := nullif(current_setting('app.credit_ledger_write_scope', true), '');
    if v_token is distinct from new.id::text
       or v_scope not in (
         'sale_trigger', 'redeem_points', 'redeem_gift_card', 'enroll_membership',
         'membership_renewal', 'credit_tender', 'sale_reversal'
       ) then
      raise exception 'credit_ledger may only be appended by approved loyalty/financial routes'
        using errcode = '42501';
    end if;
    if (v_scope = 'sale_trigger'
        and (new.entry_type not in ('loyalty_earn', 'referral_reward')
             or new.amount_cents <= 0 or new.sale_id is null))
       or (v_scope = 'redeem_points'
           and (new.entry_type <> 'loyalty_earn' or new.amount_cents <= 0
                or new.sale_id is not null or new.payment_id is not null
                or new.actor is distinct from auth.uid()))
       or (v_scope = 'redeem_gift_card'
           and (new.entry_type <> 'gift_card_load' or new.amount_cents <= 0
                or new.sale_id is not null or new.payment_id is not null
                or new.actor is distinct from auth.uid()))
       or (v_scope = 'enroll_membership'
           and (new.entry_type <> 'membership_credit' or new.amount_cents <= 0
                or new.sale_id is null or new.payment_id is not null
                or new.actor is distinct from auth.uid()))
       or (v_scope = 'membership_renewal'
           and (new.entry_type <> 'membership_credit' or new.amount_cents <= 0
                or new.sale_id is null or new.payment_id is not null
                or new.actor is not null))
       or (v_scope = 'credit_tender'
           and (new.entry_type <> 'spend' or new.amount_cents >= 0
                or new.sale_id is null or new.payment_id is null
                or new.actor is distinct from auth.uid()))
       or (v_scope = 'sale_reversal'
           and (new.entry_type <> 'manual_adjust' or new.amount_cents = 0
                or new.sale_id is null or new.actor is distinct from auth.uid())) then
      raise exception 'credit tender ledger entry shape is invalid'
        using errcode = 'check_violation';
    end if;
  else
    raise exception 'loyalty ledger guard attached to unexpected table %', tg_table_name;
  end if;
  return new;
end $$;

revoke execute on function app.loyalty_ledger_write_guard()
  from public, anon, authenticated;

drop trigger if exists trg_points_ledger_write_guard on public.points_ledger;
create trigger trg_points_ledger_write_guard
  before insert on public.points_ledger
  for each row execute function app.loyalty_ledger_write_guard();
drop trigger if exists trg_credit_ledger_write_guard on public.credit_ledger;
create trigger trg_credit_ledger_write_guard
  before insert on public.credit_ledger
  for each row execute function app.loyalty_ledger_write_guard();

drop trigger if exists trg_points_ledger_append_only on public.points_ledger;
create trigger trg_points_ledger_append_only
  before update or delete on public.points_ledger
  for each row execute function app.forbid_mutation();
drop trigger if exists trg_credit_ledger_append_only on public.credit_ledger;
create trigger trg_credit_ledger_append_only
  before update or delete on public.credit_ledger
  for each row execute function app.forbid_mutation();

drop policy if exists points_insert on public.points_ledger;
drop policy if exists credit_ledger_insert on public.credit_ledger;
drop policy if exists points_select on public.points_ledger;
create policy points_select on public.points_ledger for select to authenticated
  using (app.has_perm(business_id, 'view_sales'));
drop policy if exists credit_ledger_select on public.credit_ledger;
create policy credit_ledger_select on public.credit_ledger for select to authenticated
  using (app.has_perm(business_id, 'view_sales'));

revoke all privileges on table public.points_ledger from public, anon, authenticated;
grant select on public.points_ledger to authenticated;
revoke all privileges on table public.credit_ledger from public, anon, authenticated;
grant select on public.credit_ledger to authenticated;

-- Retained v3/v5 writers were applied remotely and are represented in this repository by
-- migration notes. Pin their shipped identities before replacing their bodies; a signature
-- drift must stop v20 instead of leaving a legitimate ledger route broken or over-broad.
do $$
declare
  v_required text;
begin
  foreach v_required in array array[
    'public.adjust_points(uuid,uuid,integer,text)',
    'app.run_points_expiry()',
    'public.run_expiry_now(uuid)',
    'public.redeem_gift_card(uuid,text,uuid,integer)',
    'public.enroll_membership(uuid,uuid,uuid)',
    'app.run_membership_renewals()',
    'public.record_quick_sale(uuid,integer,text,uuid,uuid,uuid,text,text,boolean)'
  ] loop
    if to_regprocedure(v_required) is null then
      raise exception 'v20 retained ledger writer prerequisite is missing: %', v_required
        using errcode = 'undefined_function';
    end if;
  end loop;

  if pg_get_function_result(
       to_regprocedure('public.record_quick_sale(uuid,integer,text,uuid,uuid,uuid,text,text,boolean)')
     ) <> 'json' then
    raise exception 'v20 cannot preserve record_quick_sale return contract: expected json'
      using errcode = '42804';
  end if;
  if pg_get_function_result(to_regprocedure('public.run_expiry_now(uuid)')) <> 'void' then
    raise exception 'v20 cannot preserve run_expiry_now return contract: expected void'
      using errcode = '42804';
  end if;
  if pg_get_function_result(to_regprocedure('app.run_points_expiry()')) <> 'void' then
    raise exception 'v20 cannot preserve app.run_points_expiry return contract: expected void'
      using errcode = '42804';
  end if;
  if pg_get_function_result(
       to_regprocedure('public.redeem_gift_card(uuid,text,uuid,integer)')
     ) <> 'json'
     or not exists (
       select 1
         from pg_catalog.pg_proc p
        where p.oid = to_regprocedure('public.redeem_gift_card(uuid,text,uuid,integer)')
          and p.prosecdef
          and p.pronargdefaults = 1
          and pg_get_expr(p.proargdefaults, 0) = 'NULL::integer'
     ) then
    raise exception 'v20 cannot preserve redeem_gift_card contract: expected json with p_amount DEFAULT NULL'
      using errcode = '42804';
  end if;
  if pg_get_function_result(to_regprocedure('app.run_membership_renewals()')) <> 'void'
     or not (select p.prosecdef
               from pg_catalog.pg_proc p
              where p.oid = to_regprocedure('app.run_membership_renewals()')) then
    raise exception 'v20 cannot preserve app.run_membership_renewals return contract: expected void'
      using errcode = '42804';
  end if;
end $$;

create or replace function public.adjust_points(
  p_business uuid,
  p_client uuid,
  p_points integer,
  p_reason text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_balance integer;
  v_batch_balance integer;
  v_remaining integer;
  v_take integer;
  v_points_id uuid := gen_random_uuid();
  v_expiry timestamptz;
  v_batch record;
  lp public.loyalty_programs%rowtype;
begin
  if coalesce(p_points, 0) = 0 then
    raise exception 'points adjustment must be non-zero';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 3 then
    raise exception 'points adjustment reason must be at least 3 characters';
  end if;

  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and s.role = 'owner'
   order by s.created_at
   limit 1
   for update;
  if not found then
    raise exception 'only an active owner may adjust points'
      using errcode = '42501';
  end if;

  perform 1 from public.clients c
   where c.id = p_client and c.business_id = p_business
   for update;
  if not found then
    raise exception 'client does not belong to this business';
  end if;

  select coalesce(sum(pl.points), 0)::integer into v_balance
    from public.points_ledger pl
   where pl.business_id = p_business and pl.client_id = p_client;
  if p_points < 0 and v_balance + p_points < 0 then
    raise exception 'points adjustment would overdraw balance % by %', v_balance, -p_points;
  end if;

  if p_points < 0 then
    select coalesce(sum(pb.remaining), 0)::integer into v_batch_balance
      from public.points_batches pb
     where pb.business_id = p_business
       and pb.client_id = p_client
       and pb.remaining > 0;
    if v_batch_balance < -p_points then
      raise exception 'points batches % cannot prove negative adjustment %',
        v_batch_balance, -p_points
        using errcode = 'check_violation';
    end if;

    v_remaining := -p_points;
    for v_batch in
      select pb.id, pb.remaining
        from public.points_batches pb
       where pb.business_id = p_business
         and pb.client_id = p_client
         and pb.remaining > 0
       order by pb.expires_at nulls last, pb.earned_at, pb.id
       for update
    loop
      exit when v_remaining = 0;
      v_take := least(v_batch.remaining, v_remaining);
      update public.points_batches
         set remaining = remaining - v_take
       where id = v_batch.id;
      v_remaining := v_remaining - v_take;
    end loop;
  else
    select * into lp
      from public.loyalty_programs
     where business_id = p_business
       and active
       and kind = 'points'
     limit 1;
    v_expiry := case
      when found and lp.expiry_mode = 'fixed' and coalesce(lp.expiry_days, 0) > 0
        then now() + make_interval(days => lp.expiry_days)
      else null
    end;
    insert into public.points_batches (
      business_id, client_id, earned, remaining, earned_at, expires_at
    ) values (
      p_business, p_client, p_points, p_points, now(), v_expiry
    );
  end if;

  perform set_config('app.points_ledger_insert_id', v_points_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
  insert into public.points_ledger (
    id, business_id, client_id, entry_type, points, reference, actor
  ) values (
    v_points_id, p_business, p_client, 'adjust', p_points, btrim(p_reason), v_actor
  );
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);

  return v_balance + p_points;
end $$;

revoke execute on function public.adjust_points(uuid, uuid, integer, text)
  from public, anon;
grant execute on function public.adjust_points(uuid, uuid, integer, text)
  to authenticated;

create or replace function app.run_points_expiry_for_business(p_business uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_client record;
  v_batch record;
  v_points_id uuid;
  v_expired integer := 0;
begin
  for v_client in
    select distinct pb.business_id, pb.client_id
      from public.points_batches pb
      join public.loyalty_programs lp on lp.business_id = pb.business_id
     where pb.business_id = p_business
       and pb.remaining > 0
       and lp.active
       and lp.kind = 'points'
       and coalesce(lp.expiry_days, 0) > 0
       and (
         (lp.expiry_mode = 'fixed' and pb.expires_at <= now())
         or (
           lp.expiry_mode = 'inactivity'
           and not exists (
             select 1
               from public.points_ledger pl
              where pl.business_id = pb.business_id
                and pl.client_id = pb.client_id
                and pl.points > 0
                and pl.created_at > now() - make_interval(days => lp.expiry_days)
           )
         )
       )
  loop
    perform 1 from public.clients c
     where c.id = v_client.client_id
       and c.business_id = v_client.business_id
     for update;

    for v_batch in
      select pb.id, pb.remaining
        from public.points_batches pb
        join public.loyalty_programs lp on lp.business_id = pb.business_id
       where pb.business_id = v_client.business_id
         and pb.client_id = v_client.client_id
         and pb.remaining > 0
         and lp.active
         and lp.kind = 'points'
         and coalesce(lp.expiry_days, 0) > 0
         and (
           (lp.expiry_mode = 'fixed' and pb.expires_at <= now())
           or lp.expiry_mode = 'inactivity'
         )
       order by pb.expires_at nulls last, pb.earned_at, pb.id
       for update of pb skip locked
    loop
      v_points_id := gen_random_uuid();
      perform set_config('app.points_ledger_insert_id', v_points_id::text, true);
      perform set_config('app.points_ledger_write_scope', 'points_expiry', true);
      insert into public.points_ledger (
        id, business_id, client_id, entry_type, points, reference, actor
      ) values (
        v_points_id, v_client.business_id, v_client.client_id,
        'expire', -v_batch.remaining, 'points expiry batch ' || v_batch.id, null
      );
      perform set_config('app.points_ledger_insert_id', '', true);
      perform set_config('app.points_ledger_write_scope', '', true);

      update public.points_batches set remaining = 0 where id = v_batch.id;
      v_expired := v_expired + v_batch.remaining;
    end loop;
  end loop;
  return v_expired;
end $$;

revoke execute on function app.run_points_expiry_for_business(uuid)
  from public, anon, authenticated;

create or replace function app.run_points_expiry()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business uuid;
begin
  for v_business in
    select distinct lp.business_id
      from public.loyalty_programs lp
     where lp.active
       and lp.kind = 'points'
       and coalesce(lp.expiry_days, 0) > 0
  loop
    perform app.run_points_expiry_for_business(v_business);
  end loop;
end $$;

revoke execute on function app.run_points_expiry() from public, anon, authenticated;

create or replace function public.run_expiry_now(p_business uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
begin
  if not exists (
    select 1 from public.staff s
     where s.business_id = p_business
       and s.user_id = v_actor
       and s.active
       and s.role = 'owner'
  ) then
    raise exception 'only an active owner may run points expiry for this business'
      using errcode = '42501';
  end if;

  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and s.role = 'owner'
   order by s.created_at
   limit 1
   for update;
  if not found then
    raise exception 'active owner authorization is required to run points expiry'
      using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.staff s
     where s.id = v_staff
       and s.business_id = p_business
       and s.user_id = v_actor
       and s.active
       and s.role = 'owner'
  ) then
    raise exception 'points-expiry authorization changed while the actor was locked'
      using errcode = '42501';
  end if;

  perform app.run_points_expiry_for_business(p_business);
end $$;

revoke execute on function public.run_expiry_now(uuid) from public, anon;
grant execute on function public.run_expiry_now(uuid) to authenticated;

create or replace function public.redeem_gift_card(
  p_business uuid,
  p_code text,
  p_client uuid,
  p_amount integer default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  gc public.gift_cards%rowtype;
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_load integer;
  v_credit_id uuid := gen_random_uuid();
begin
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to redeem gift cards in this business'
      using errcode = '42501';
  end if;
  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and 'create_sales' = any (app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end, s.created_at
   limit 1
   for update;
  if not found then
    raise exception 'active staff authorization is required to redeem a gift card'
      using errcode = '42501';
  end if;
  perform 1 from public.clients c
   where c.id = p_client and c.business_id = p_business
   for update;
  if not found then
    raise exception 'client does not belong to this business';
  end if;
  select * into gc
    from public.gift_cards g
   where g.business_id = p_business
     and upper(g.code) = upper(btrim(p_code))
   for update;
  if not found or gc.status <> 'active' or gc.balance_cents <= 0 then
    raise exception 'gift card is not active or has no remaining balance';
  end if;
  v_load := coalesce(p_amount, gc.balance_cents);
  if v_load <= 0 or v_load > gc.balance_cents then
    raise exception 'gift-card redemption % exceeds available balance %',
      v_load, gc.balance_cents;
  end if;

  update public.gift_cards
     set balance_cents = balance_cents - v_load,
         status = case when balance_cents - v_load = 0 then 'redeemed' else 'active' end
   where id = gc.id;

  perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
  perform set_config('app.credit_ledger_write_scope', 'redeem_gift_card', true);
  insert into public.credit_ledger (
    id, business_id, client_id, entry_type, amount_cents, reference, actor
  ) values (
    v_credit_id, p_business, p_client, 'gift_card_load', v_load,
    'gift card redeemed: ' || gc.code, v_actor
  );
  perform set_config('app.credit_ledger_insert_id', '', true);
  perform set_config('app.credit_ledger_write_scope', '', true);

  return json_build_object(
    'loaded_cents', v_load,
    'remaining_cents', gc.balance_cents - v_load
  );
end $$;

revoke execute on function public.redeem_gift_card(uuid, text, uuid, integer)
  from public, anon;
grant execute on function public.redeem_gift_card(uuid, text, uuid, integer)
  to authenticated;

create or replace function public.enroll_membership(
  p_business uuid,
  p_client uuid,
  p_plan uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  mp public.membership_plans%rowtype;
  ms public.memberships%rowtype;
  v_sale public.sales%rowtype;
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_credit_id uuid;
  v_period_end timestamptz;
begin
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to enroll memberships in this business'
      using errcode = '42501';
  end if;
  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and 'create_sales' = any (app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end, s.created_at
   limit 1
   for update;
  if not found then
    raise exception 'active staff authorization is required to enroll a membership'
      using errcode = '42501';
  end if;
  perform 1 from public.clients c
   where c.id = p_client and c.business_id = p_business
   for update;
  if not found then
    raise exception 'client does not belong to this business';
  end if;
  select * into mp from public.membership_plans p
   where p.id = p_plan and p.business_id = p_business and p.active
   for update;
  if not found then
    raise exception 'active membership plan does not belong to this business';
  end if;
  if exists (
    select 1 from public.memberships m
     where m.business_id = p_business
       and m.client_id = p_client
       and m.status in ('active', 'paused', 'cancel_at_period_end')
  ) then
    raise exception 'client already has a live membership';
  end if;

  v_period_end := now() + case mp.cadence
    when 'monthly' then interval '1 month'
    when 'annual' then interval '1 year'
    else null
  end;
  if v_period_end is null then
    raise exception 'unsupported membership cadence %', mp.cadence;
  end if;

  insert into public.memberships (
    business_id, client_id, plan_id, status, current_period_start, current_period_end
  ) values (
    p_business, p_client, mp.id, 'active', now(), v_period_end
  ) returning * into ms;

  insert into public.sales (
    business_id, client_id, kind, amount_cents, note, staff_id
  ) values (
    p_business, p_client, 'membership', mp.price_cents,
    'membership enrollment: ' || mp.name, null
  ) returning * into v_sale;

  if mp.credit_cents > 0 then
    v_credit_id := gen_random_uuid();
    perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
    perform set_config('app.credit_ledger_write_scope', 'enroll_membership', true);
    insert into public.credit_ledger (
      id, business_id, client_id, entry_type, amount_cents, reference,
      sale_id, actor, idempotency_key
    ) values (
      v_credit_id, p_business, p_client, 'membership_credit', mp.credit_cents,
      'membership period credit: ' || mp.name, v_sale.id, v_actor,
      'v20:membership:' || ms.id || ':' || ms.current_period_start
    );
    perform set_config('app.credit_ledger_insert_id', '', true);
    perform set_config('app.credit_ledger_write_scope', '', true);
  end if;

  return row_to_json(ms);
end $$;

revoke execute on function public.enroll_membership(uuid, uuid, uuid)
  from public, anon;
grant execute on function public.enroll_membership(uuid, uuid, uuid)
  to authenticated;

create or replace function app.run_membership_renewals()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  due record;
  v_sale public.sales%rowtype;
  v_credit_id uuid;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_catchup integer;
begin
  for due in
    select m.id, m.business_id, m.client_id, m.status,
           m.current_period_start, m.current_period_end,
           p.id as plan_id, p.name as plan_name, p.price_cents,
           p.credit_cents, p.cadence, p.active as plan_active
      from public.memberships m
      join public.membership_plans p
        on p.id = m.plan_id and p.business_id = m.business_id
     where m.status in ('active', 'cancel_at_period_end')
       and m.current_period_end <= now()
     order by m.current_period_end, m.id
     for update of m skip locked
  loop
    if due.status = 'cancel_at_period_end' or not due.plan_active then
      update public.memberships set status = 'cancelled' where id = due.id;
      continue;
    end if;

    v_period_start := due.current_period_end;
    v_catchup := 0;
    while v_period_start <= now() and v_catchup < 12 loop
      v_period_end := v_period_start + case due.cadence
        when 'monthly' then interval '1 month'
        when 'annual' then interval '1 year'
        else null
      end;
      if v_period_end is null then
        raise exception 'unsupported membership cadence %', due.cadence;
      end if;

      insert into public.sales (
        business_id, client_id, kind, amount_cents, occurred_at, note, staff_id
      ) values (
        due.business_id, due.client_id, 'membership', due.price_cents,
        now(), 'membership renewal: ' || due.plan_name, null
      ) returning * into v_sale;

      if due.credit_cents > 0 then
        v_credit_id := gen_random_uuid();
        perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
        perform set_config('app.credit_ledger_write_scope', 'membership_renewal', true);
        insert into public.credit_ledger (
          id, business_id, client_id, entry_type, amount_cents, reference,
          sale_id, actor, idempotency_key
        ) values (
          v_credit_id, due.business_id, due.client_id, 'membership_credit',
          due.credit_cents, 'membership renewal credit: ' || due.plan_name,
          v_sale.id, null,
          'v20:membership:' || due.id || ':' || v_period_start
        );
        perform set_config('app.credit_ledger_insert_id', '', true);
        perform set_config('app.credit_ledger_write_scope', '', true);
      end if;

      v_period_start := v_period_end;
      v_catchup := v_catchup + 1;
    end loop;

    update public.memberships
       set current_period_start = v_period_start - case due.cadence
             when 'monthly' then interval '1 month'
             when 'annual' then interval '1 year'
           end,
           current_period_end = v_period_start
     where id = due.id;
  end loop;
end $$;

revoke execute on function app.run_membership_renewals()
  from public, anon, authenticated;

create or replace function public.record_payment(
  p_business uuid,
  p_method text,
  p_amount_cents integer,
  p_sale uuid default null,
  p_appointment uuid default null,
  p_client uuid default null,
  p_staff uuid default null,
  p_kind text default 'payment',
  p_branch uuid default null,
  p_reference text default null,
  p_note text default null,
  p_idempotency_key text default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sale public.sales%rowtype;
  v_appointment public.appointments%rowtype;
  v_row public.payments%rowtype;
  v_branch uuid;
  v_client uuid;
  v_actor uuid := auth.uid();
  v_actor_staff uuid;
  v_payment_id uuid := gen_random_uuid();
  v_amount_bigint bigint;
  v_amount integer;
  v_key text;
  v_reference text;
  v_note text;
begin
  v_key := nullif(btrim(p_idempotency_key), '');
  v_reference := nullif(btrim(p_reference), '');
  v_note := nullif(btrim(p_note), '');
  if v_key is null or length(v_key) < 8 then
    raise exception 'payment idempotency key is required and must be at least 8 characters';
  end if;
  if p_kind = 'refund' then
    raise exception 'standalone refunds are disabled; use public.reverse_sale()'
      using errcode = 'feature_not_supported';
  end if;
  if p_kind not in ('payment', 'deposit', 'no_show_fee') then
    raise exception 'unsupported positive payment kind %', p_kind;
  end if;
  if p_method in ('credit', 'gift_card') then
    raise exception '% tender must use its proof-carrying internal workflow', p_method
      using errcode = 'feature_not_supported';
  end if;
  if p_method not in ('cash', 'card', 'paynow', 'bank_transfer', 'other') then
    raise exception 'unsupported payment method %', p_method;
  end if;
  if p_sale is null and p_appointment is null then
    raise exception 'a payment must reference a sale or an appointment';
  end if;
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to take a payment in this business (create_sales)'
      using errcode = '42501';
  end if;

  -- Resolve attacker-controlled identifiers without locks, authorize their branch, then lock
  -- and re-read below. Unauthorized callers never reach a row or advisory lock.
  if p_sale is not null then
    select * into v_sale
      from public.sales
     where id = p_sale
       and business_id = p_business;
    if not found then
      raise exception 'sale does not belong to this business';
    end if;
  end if;
  if p_appointment is not null then
    select * into v_appointment
      from public.appointments
     where id = p_appointment
       and business_id = p_business;
    if not found then
      raise exception 'appointment does not belong to this business';
    end if;
  end if;

  if v_sale.id is not null and v_appointment.id is not null then
    if v_sale.appointment_id is distinct from v_appointment.id
       or v_sale.branch_id is distinct from v_appointment.branch_id
       or v_sale.client_id is distinct from v_appointment.client_id then
      raise exception 'payment sale and appointment do not describe one checkout';
    end if;
  end if;
  v_branch := coalesce(v_sale.branch_id, v_appointment.branch_id);
  v_client := coalesce(v_sale.client_id, v_appointment.client_id);
  if p_branch is not null and p_branch is distinct from v_branch then
    raise exception 'payment branch override conflicts with the sale/appointment branch';
  end if;
  if p_client is not null and p_client is distinct from v_client then
    raise exception 'payment client override conflicts with the sale/appointment client';
  end if;
  if not app.can_see_branch(p_business, v_branch) then
    raise exception 'you are not permitted to take payment for this branch scope'
      using errcode = '42501';
  end if;

  select s.id into v_actor_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and 'create_sales' = any (app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end, s.created_at
   limit 1
   for update;
  if not found then
    raise exception 'active staff authorization is required to take payment'
      using errcode = '42501';
  end if;

  if p_sale is not null then
    select * into v_sale
      from public.sales
     where id = p_sale
       and business_id = p_business
     for update;
    if not found then
      raise exception 'sale no longer belongs to this business';
    end if;
  end if;
  if p_appointment is not null then
    select * into v_appointment
      from public.appointments
     where id = p_appointment
       and business_id = p_business
     for update;
    if not found then
      raise exception 'appointment no longer belongs to this business';
    end if;
  end if;

  if v_sale.id is not null and v_appointment.id is not null then
    if v_sale.appointment_id is distinct from v_appointment.id then
      raise exception 'payment sale and appointment do not describe the same checkout';
    end if;
    if v_sale.branch_id is distinct from v_appointment.branch_id then
      raise exception 'payment sale and appointment have contradictory branches';
    end if;
    if v_sale.client_id is distinct from v_appointment.client_id then
      raise exception 'payment sale and appointment have contradictory clients';
    end if;
  end if;

  v_branch := coalesce(v_sale.branch_id, v_appointment.branch_id);
  v_client := coalesce(v_sale.client_id, v_appointment.client_id);
  if p_branch is not null and p_branch is distinct from v_branch then
    raise exception 'payment branch override conflicts with the locked sale/appointment branch';
  end if;
  if p_client is not null and p_client is distinct from v_client then
    raise exception 'payment client override conflicts with the locked sale/appointment client';
  end if;
  if not app.has_perm(p_business, 'create_sales')
     or not app.can_see_branch(p_business, v_branch) then
    raise exception 'payment authorization changed while the operation was being locked'
      using errcode = '42501';
  end if;
  if v_sale.reversal_of is not null then
    raise exception 'payments cannot attach to a reversal sale';
  end if;
  if v_sale.id is not null and exists (
    select 1 from public.sales r
     where r.business_id = p_business
       and r.reversal_of = v_sale.id
  ) then
    raise exception 'positive payment is forbidden on a fully reversed sale';
  end if;
  if v_sale.id is null and v_appointment.id is not null and exists (
    select 1
      from public.sales s
      join public.sales r
        on r.business_id = s.business_id
       and r.reversal_of = s.id
     where s.business_id = p_business
       and s.appointment_id = v_appointment.id
  ) then
    raise exception 'positive appointment payment is forbidden after its sale was reversed';
  end if;
  if p_staff is not null and not exists (
    select 1 from public.staff s
     where s.id = p_staff
       and s.business_id = p_business
  ) then
    raise exception 'staff does not belong to this business';
  end if;
  if v_client is not null and not exists (
    select 1 from public.clients c
     where c.id = v_client
       and c.business_id = p_business
  ) then
    raise exception 'client does not belong to this business';
  end if;

  v_amount_bigint := abs(p_amount_cents::bigint);
  if coalesce(v_amount_bigint, 0) <= 0 or v_amount_bigint > 2147483647 then
    raise exception 'payment amount must be a positive 32-bit cent value';
  end if;
  v_amount := v_amount_bigint::integer;

  perform pg_advisory_xact_lock(
    hashtextextended(p_business::text || ':payment:' || v_key, 0)
  );

  perform set_config('app.payment_insert_id', v_payment_id::text, true);
  perform set_config('app.payment_write_scope', 'record_payment', true);
  insert into public.payments (
    id, business_id, branch_id, sale_id, appointment_id, client_id, staff_id,
    method, kind, amount_cents, reference, note, idempotency_key, created_by
  )
  values (
    v_payment_id, p_business, v_branch, p_sale, p_appointment, v_client, p_staff,
    p_method, p_kind, v_amount, v_reference, v_note,
    v_key, v_actor
  )
  on conflict (business_id, idempotency_key) where idempotency_key is not null
    do nothing
  returning * into v_row;
  perform set_config('app.payment_insert_id', '', true);
  perform set_config('app.payment_write_scope', '', true);

  if v_row.id is null then
    select * into v_row
      from public.payments
     where business_id = p_business
       and idempotency_key = v_key;
    if not found
       or (v_row.business_id, v_row.branch_id, v_row.sale_id, v_row.appointment_id,
           v_row.client_id, v_row.staff_id, v_row.method, v_row.kind,
           v_row.amount_cents, v_row.reference, v_row.note, v_row.created_by)
          is distinct from
          (p_business, v_branch, p_sale, p_appointment,
           v_client, p_staff, p_method, p_kind, v_amount,
           v_reference, v_note, v_actor) then
      raise exception 'payment idempotency key conflicts with a different immutable request'
        using errcode = '23505';
    end if;
  end if;

  return row_to_json(v_row);
end $$;

revoke execute on function public.record_payment(uuid, text, integer, uuid, uuid, uuid, uuid,
  text, uuid, text, text, text) from public, anon;
grant execute on function public.record_payment(uuid, text, integer, uuid, uuid, uuid, uuid,
  text, uuid, text, text, text) to authenticated;

-- The operation row, not the optional payment, owns quick-sale idempotency. This preserves
-- the shipped SPA signature while making paid and unpaid checkout equally replay-safe.
create or replace function public.record_quick_sale(
  p_business uuid,
  p_amount_cents integer,
  p_method text,
  p_client uuid default null,
  p_staff uuid default null,
  p_branch uuid default null,
  p_note text default null,
  p_idempotency_key text default null,
  p_paid boolean default true)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_actor_staff uuid;
  v_branch uuid;
  v_method text := lower(nullif(btrim(p_method), ''));
  v_note text := nullif(btrim(p_note), '');
  v_key text := nullif(btrim(p_idempotency_key), '');
  v_paid boolean := coalesce(p_paid, true);
  v_operation_id uuid := gen_random_uuid();
  v_operation public.financial_operations%rowtype;
  v_payload jsonb;
  v_sale public.sales%rowtype;
  v_payment jsonb;
  v_result jsonb;
begin
  if v_key is null or length(v_key) < 8 then
    raise exception 'quick-sale idempotency key is required and must be at least 8 characters';
  end if;
  if coalesce(p_amount_cents, 0) <= 0 then
    raise exception 'a quick sale must have a positive amount';
  end if;
  if v_method not in ('cash', 'card', 'paynow', 'bank_transfer', 'other') then
    raise exception 'unsupported quick-sale payment method %', p_method;
  end if;
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to record a sale in this business (create_sales)'
      using errcode = '42501';
  end if;

  v_branch := coalesce(p_branch, app.default_branch(p_business));
  if v_branch is null or not exists (
    select 1 from public.branches b
     where b.id = v_branch and b.business_id = p_business and b.active
  ) then
    raise exception 'quick-sale branch is missing, inactive, or belongs to another business';
  end if;
  if not app.can_see_branch(p_business, v_branch) then
    raise exception 'you are not permitted to record a quick sale for this branch scope'
      using errcode = '42501';
  end if;
  if p_client is not null and not exists (
    select 1 from public.clients c where c.id = p_client and c.business_id = p_business
  ) then
    raise exception 'quick-sale client does not belong to this business';
  end if;
  if p_staff is not null and not exists (
    select 1 from public.staff s
     where s.id = p_staff and s.business_id = p_business and s.active
  ) then
    raise exception 'quick-sale staff is inactive or does not belong to this business';
  end if;

  select s.id into v_actor_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and 'create_sales' = any (app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end, s.created_at
   limit 1
   for update;
  if not found then
    raise exception 'active staff authorization is required to record a quick sale'
      using errcode = '42501';
  end if;
  perform 1 from public.branches b
   where b.id = v_branch and b.business_id = p_business and b.active
   for update;
  if not found then
    raise exception 'quick-sale branch changed while authorization was being locked';
  end if;
  if p_client is not null then
    perform 1 from public.clients c
     where c.id = p_client and c.business_id = p_business for update;
    if not found then
      raise exception 'quick-sale client changed while authorization was being locked';
    end if;
  end if;
  if p_staff is not null then
    perform 1 from public.staff s
     where s.id = p_staff and s.business_id = p_business and s.active for update;
    if not found then
      raise exception 'quick-sale staff changed while authorization was being locked';
    end if;
  end if;
  if not app.has_perm(p_business, 'create_sales')
     or not app.can_see_branch(p_business, v_branch) then
    raise exception 'quick-sale authorization changed while the operation was being locked'
      using errcode = '42501';
  end if;

  v_payload := jsonb_build_object(
    'business_id', p_business,
    'branch_id', v_branch,
    'client_id', p_client,
    'staff_id', p_staff,
    'actor', v_actor,
    'amount_cents', p_amount_cents,
    'method', v_method,
    'note', v_note,
    'paid', v_paid
  );

  select * into v_operation
    from public.financial_operations fo
   where fo.business_id = p_business
     and fo.operation_type = 'quick_sale'
     and fo.idempotency_key = v_key;
  if found then
    if (v_operation.branch_id, v_operation.actor, v_operation.request_payload,
        v_operation.request_hash)
       is distinct from
       (v_branch, v_actor, v_payload, md5(v_payload::text)) then
      raise exception 'quick-sale idempotency key conflicts with a different immutable request'
        using errcode = '23505';
    end if;
    if v_operation.status <> 'completed' or v_operation.sale_id is null
       or v_operation.result is null then
      raise exception 'quick-sale operation is reserved but incomplete'
        using errcode = '55000';
    end if;
    if not exists (
      select 1 from public.sales s
       where s.id = v_operation.sale_id
         and s.business_id = p_business
         and s.branch_id = v_branch
         and s.client_id is not distinct from p_client
         and s.staff_id is not distinct from p_staff
         and s.kind = 'quick_sale'
         and s.amount_cents = p_amount_cents
         and s.note is not distinct from v_note
    ) or (v_paid and not exists (
      select 1 from public.payments p
       where p.id = (v_operation.result->>'payment_id')::uuid
         and p.business_id = p_business
         and p.sale_id = v_operation.sale_id
         and p.method = v_method
         and p.kind = 'payment'
         and p.amount_cents = p_amount_cents
         and p.created_by = v_actor
    )) or (not v_paid and v_operation.result ? 'payment_id') then
      raise exception 'completed quick sale is missing exact sale/payment proof'
        using errcode = 'XX001';
    end if;
    return (v_operation.result || jsonb_build_object('replayed', true))::json;
  end if;

  perform set_config('app.financial_operation_insert_id', v_operation_id::text, true);
  insert into public.financial_operations(
    id, business_id, branch_id, sale_id, operation_type, actor,
    idempotency_key, request_payload, request_hash
  ) values (
    v_operation_id, p_business, v_branch, null, 'quick_sale', v_actor,
    v_key, v_payload, md5(v_payload::text)
  )
  on conflict (business_id, operation_type, idempotency_key) do nothing
  returning * into v_operation;
  perform set_config('app.financial_operation_insert_id', '', true);

  if v_operation.id is null then
    select * into v_operation from public.financial_operations fo
     where fo.business_id = p_business
       and fo.operation_type = 'quick_sale'
       and fo.idempotency_key = v_key;
    if not found
       or (v_operation.branch_id, v_operation.actor, v_operation.request_payload,
           v_operation.request_hash)
          is distinct from
          (v_branch, v_actor, v_payload, md5(v_payload::text)) then
      raise exception 'quick-sale idempotency reservation conflicts with a different immutable request'
        using errcode = '23505';
    end if;
    if v_operation.status = 'completed' and v_operation.result is not null then
      -- Re-enter the completed replay path so a concurrent winner receives the same exact
      -- sale/payment proof checks as a later replay, rather than trusting the parent alone.
      return public.record_quick_sale(
        p_business, p_amount_cents, v_method, p_client, p_staff, v_branch,
        v_note, v_key, v_paid
      );
    end if;
    raise exception 'quick-sale operation is already reserved but incomplete'
      using errcode = '55000';
  end if;

  insert into public.sales(
    business_id, client_id, kind, amount_cents, branch_id, staff_id, note
  ) values (
    p_business, p_client, 'quick_sale', p_amount_cents, v_branch, p_staff, v_note
  ) returning * into v_sale;

  if v_paid then
    v_payment := public.record_payment(
      p_business => p_business,
      p_method => v_method,
      p_amount_cents => p_amount_cents,
      p_sale => v_sale.id,
      p_client => p_client,
      p_staff => p_staff,
      p_kind => 'payment',
      p_branch => v_branch,
      p_reference => 'quick sale checkout',
      p_note => v_note,
      p_idempotency_key => 'v20:' || v_operation.id || ':payment'
    )::jsonb;
  end if;

  v_result := jsonb_build_object(
    'sale', to_jsonb(v_sale),
    'replayed', false,
    'operation_id', v_operation.id
  );
  if v_paid then
    v_result := v_result || jsonb_build_object(
      'payment', v_payment,
      'payment_id', v_payment->>'id'
    );
  else
    v_result := v_result || jsonb_build_object('payment', null);
  end if;

  perform set_config('app.financial_operation_complete_id', v_operation.id::text, true);
  update public.financial_operations
     set sale_id = v_sale.id,
         status = 'completed',
         result = v_result,
         completed_at = now()
   where id = v_operation.id and status = 'reserved';
  perform set_config('app.financial_operation_complete_id', '', true);
  if not found then
    raise exception 'failed to complete reserved quick-sale operation'
      using errcode = '55000';
  end if;

  return v_result::json;
end $$;

revoke execute on function public.record_quick_sale(uuid, integer, text, uuid, uuid, uuid,
  text, text, boolean) from public, anon;
grant execute on function public.record_quick_sale(uuid, integer, text, uuid, uuid, uuid,
  text, text, boolean) to authenticated;

-- =====================================================================================
-- 4. Snapshot, loyalty, stock and commission functions now understand reversal rows
-- =====================================================================================

create or replace function app.on_sale_policy_snapshot()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  p record;
  o public.sales%rowtype;
begin
  if new.reversal_of is not null then
    select * into o
      from public.sales
     where id = new.reversal_of
       and business_id = new.business_id;
    if not found then
      raise exception 'original sale not found for reversal %', new.reversal_of;
    end if;
    if o.reversal_of is not null then
      raise exception 'cannot reverse a reversal sale %', o.id;
    end if;
    if new.kind is distinct from o.kind then
      raise exception 'reversal kind % must match original kind %', new.kind, o.kind;
    end if;

    new.counts_as_revenue := o.counts_as_revenue;
    new.counts_as_visit := o.counts_as_visit;
    new.earns_points := o.earns_points;
    new.policy_resolved_at := o.policy_resolved_at;
    new.appointment_id := null;
    return new;
  end if;

  select * into p from app.sale_policy(new.business_id, new.kind);
  if not found then
    new.counts_as_revenue := false;
    new.counts_as_visit := false;
    new.earns_points := false;
  else
    new.counts_as_revenue := p.counts_as_revenue;
    new.counts_as_visit := p.counts_as_visit;
    new.earns_points := p.earns_points;
  end if;
  new.policy_resolved_at := now();
  return new;
end $$;

revoke execute on function app.on_sale_policy_snapshot() from public, anon, authenticated;

create or replace function app.on_sale_commission_snapshot()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.sales%rowtype;
begin
  if new.reversal_of is not null then
    select * into o
      from public.sales
     where id = new.reversal_of
       and business_id = new.business_id;
    if not found then
      raise exception 'original sale not found for commission reversal %', new.reversal_of;
    end if;
    new.commission_rate_bps := o.commission_rate_bps;
    new.commission_resolved_at := o.commission_resolved_at;
    return new;
  end if;

  new.commission_rate_bps := app.commission_rate_bps(
    new.business_id, new.kind, new.staff_id, new.appointment_id, new.occurred_at);
  new.commission_resolved_at := now();
  return new;
end $$;

revoke execute on function app.on_sale_commission_snapshot() from public, anon, authenticated;

alter table public.referrals
  add column if not exists qualified_sale_id uuid;

alter table public.referrals
  drop constraint if exists referrals_qualified_sale_same_tenant;

alter table public.referrals
  add constraint referrals_qualified_sale_same_tenant foreign key (qualified_sale_id, business_id)
    references public.sales(id, business_id) on delete no action;

create index if not exists referrals_qualified_sale_idx
  on public.referrals(qualified_sale_id) where qualified_sale_id is not null;

-- v3 rewarded referrals predate qualified_sale_id. Snapshot the finite pre-v20 candidate
-- set once. A single counted visit can be linked automatically; multiple candidates remain
-- explicit manual-review evidence. Future sales are never swept into this legacy ambiguity.
create table if not exists public.legacy_referral_provenance (
  referral_id uuid primary key references public.referrals(id) on delete no action,
  business_id uuid not null references public.businesses(id) on delete no action,
  snapshot_at timestamptz not null,
  candidate_sale_ids uuid[] not null,
  resolution text not null check (resolution in ('resolved_single', 'ambiguous', 'unmatched')),
  check (
    (resolution = 'resolved_single' and cardinality(candidate_sale_ids) = 1)
    or (resolution = 'ambiguous' and cardinality(candidate_sale_ids) > 1)
    or (resolution = 'unmatched' and cardinality(candidate_sale_ids) = 0)
  )
);

create table if not exists public.legacy_referral_sale_candidates (
  referral_id uuid not null references public.legacy_referral_provenance(referral_id)
    on delete no action,
  business_id uuid not null references public.businesses(id) on delete no action,
  sale_id uuid not null,
  primary key (referral_id, sale_id),
  constraint legacy_referral_candidate_sale_fk foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete no action
);
create index if not exists legacy_referral_sale_candidates_sale_idx
  on public.legacy_referral_sale_candidates(business_id, sale_id);

with legacy as (
  select rf.id as referral_id,
         rf.business_id,
         coalesce(rf.qualified_at, statement_timestamp()) as qualified_cutoff,
         statement_timestamp() as snapshot_at
    from public.referrals rf
   where rf.status = 'rewarded'
     and rf.qualified_sale_id is null
), candidate_sets as (
  select l.referral_id,
         l.business_id,
         l.snapshot_at,
         coalesce(
           array_agg(s.id order by s.occurred_at, s.id)
             filter (where s.id is not null),
           '{}'::uuid[]
         ) as candidate_sale_ids
    from legacy l
    left join public.referrals rf on rf.id = l.referral_id
    left join public.sales s
      on s.business_id = l.business_id
     and s.client_id = rf.referred_client_id
     and s.reversal_of is null
     and s.amount_cents > 0
     and s.counts_as_visit
     and s.occurred_at <= l.qualified_cutoff
   group by l.referral_id, l.business_id, l.snapshot_at
)
insert into public.legacy_referral_provenance (
  referral_id, business_id, snapshot_at, candidate_sale_ids, resolution
)
select c.referral_id,
       c.business_id,
       c.snapshot_at,
       c.candidate_sale_ids,
       case cardinality(c.candidate_sale_ids)
         when 0 then 'unmatched'
         when 1 then 'resolved_single'
         else 'ambiguous'
       end
  from candidate_sets c
on conflict (referral_id) do nothing;

update public.referrals rf
   set qualified_sale_id = p.candidate_sale_ids[1]
  from public.legacy_referral_provenance p
 where p.referral_id = rf.id
   and p.resolution = 'resolved_single'
   and rf.qualified_sale_id is null;

insert into public.legacy_referral_sale_candidates (referral_id, business_id, sale_id)
select p.referral_id, p.business_id, candidate.sale_id
  from public.legacy_referral_provenance p
 cross join lateral unnest(p.candidate_sale_ids) candidate(sale_id)
 where p.resolution = 'ambiguous'
on conflict do nothing;

alter table public.legacy_referral_provenance enable row level security;
alter table public.legacy_referral_sale_candidates enable row level security;
drop policy if exists legacy_referral_provenance_select on public.legacy_referral_provenance;
create policy legacy_referral_provenance_select
  on public.legacy_referral_provenance for select to authenticated
  using (app.has_perm(business_id, 'view_finance'));
drop policy if exists legacy_referral_sale_candidates_select
  on public.legacy_referral_sale_candidates;
create policy legacy_referral_sale_candidates_select
  on public.legacy_referral_sale_candidates for select to authenticated
  using (app.has_perm(business_id, 'view_finance'));
revoke all privileges on table public.legacy_referral_provenance
  from public, anon, authenticated;
revoke all privileges on table public.legacy_referral_sale_candidates
  from public, anon, authenticated;
grant select on public.legacy_referral_provenance to authenticated;
grant select on public.legacy_referral_sale_candidates to authenticated;

drop trigger if exists trg_legacy_referral_provenance_append_only
  on public.legacy_referral_provenance;
create trigger trg_legacy_referral_provenance_append_only
  before update or delete on public.legacy_referral_provenance
  for each row execute function app.forbid_mutation();
drop trigger if exists trg_legacy_referral_candidates_append_only
  on public.legacy_referral_sale_candidates;
create trigger trg_legacy_referral_candidates_append_only
  before update or delete on public.legacy_referral_sale_candidates
  for each row execute function app.forbid_mutation();

-- Ambiguous pre-v20 provenance is resolved by an immutable decision event. A selected sale
-- becomes the exact clawback link; a no-link decision records accepted historical ambiguity.
create unique index if not exists referrals_id_business_uk
  on public.referrals(id, business_id);

create table if not exists public.legacy_referral_resolution_events (
  id uuid primary key default gen_random_uuid(),
  referral_id uuid not null,
  business_id uuid not null references public.businesses(id) on delete no action,
  actor uuid not null,
  decision text not null check (decision in ('selected_sale', 'no_link')),
  selected_sale_id uuid,
  reason text not null check (length(btrim(reason)) >= 10),
  created_at timestamptz not null default now(),
  constraint legacy_referral_resolution_referral_fk
    foreign key (referral_id, business_id)
    references public.referrals(id, business_id) on delete no action,
  constraint legacy_referral_resolution_sale_fk
    foreign key (selected_sale_id, business_id)
    references public.sales(id, business_id) on delete no action,
  constraint legacy_referral_resolution_once unique (referral_id),
  constraint legacy_referral_resolution_shape check (
    (decision = 'selected_sale' and selected_sale_id is not null)
    or (decision = 'no_link' and selected_sale_id is null)
  )
);
create index if not exists legacy_referral_resolution_business_time_idx
  on public.legacy_referral_resolution_events(business_id, created_at);
create index if not exists legacy_referral_resolution_sale_idx
  on public.legacy_referral_resolution_events(business_id, selected_sale_id)
  where selected_sale_id is not null;

alter table public.legacy_referral_resolution_events enable row level security;
drop policy if exists legacy_referral_resolution_events_select
  on public.legacy_referral_resolution_events;
create policy legacy_referral_resolution_events_select
  on public.legacy_referral_resolution_events for select to authenticated
  using (app.has_perm(business_id, 'view_finance'));
revoke all privileges on table public.legacy_referral_resolution_events
  from public, anon, authenticated;
grant select on public.legacy_referral_resolution_events to authenticated;
drop trigger if exists trg_legacy_referral_resolution_events_append_only
  on public.legacy_referral_resolution_events;
create trigger trg_legacy_referral_resolution_events_append_only
  before update or delete on public.legacy_referral_resolution_events
  for each row execute function app.forbid_mutation();

create or replace function public.resolve_legacy_referral(
  p_business uuid,
  p_referral uuid,
  p_selected_sale uuid default null,
  p_reason text default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_reason text := nullif(btrim(p_reason), '');
  v_decision text := case when p_selected_sale is null then 'no_link' else 'selected_sale' end;
  v_event public.legacy_referral_resolution_events%rowtype;
  v_sale public.sales%rowtype;
begin
  if v_reason is null or length(v_reason) < 10 then
    raise exception 'legacy referral resolution reason must be at least 10 characters';
  end if;
  if not app.has_perm(p_business, 'refund_sales') then
    raise exception 'you do not have permission to resolve legacy referrals in this business'
      using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.legacy_referral_provenance p
     where p.referral_id = p_referral and p.business_id = p_business
  ) then
    raise exception 'legacy referral provenance was not captured for this business';
  end if;
  if p_selected_sale is not null then
    select * into v_sale from public.sales s
     where s.id = p_selected_sale and s.business_id = p_business;
    if not found or not exists (
      select 1 from public.legacy_referral_sale_candidates c
       where c.referral_id = p_referral
         and c.business_id = p_business
         and c.sale_id = p_selected_sale
    ) then
      raise exception 'selected sale is not a captured candidate for this legacy referral';
    end if;
    if not app.can_see_branch(p_business, v_sale.branch_id) then
      raise exception 'you are not permitted to resolve a referral for this branch scope'
        using errcode = '42501';
    end if;
  end if;

  select s.id into v_staff from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and 'refund_sales' = any (app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end, s.created_at
   limit 1
   for update;
  if not found then
    raise exception 'active refund-authorized staff is required to resolve legacy referrals'
      using errcode = '42501';
  end if;
  perform 1 from public.legacy_referral_provenance p
   where p.referral_id = p_referral and p.business_id = p_business for update;
  if not found then
    raise exception 'legacy referral provenance changed while authorization was being locked';
  end if;
  perform 1 from public.referrals rf
   where rf.id = p_referral
     and rf.business_id = p_business
     and rf.status = 'rewarded'
     and (rf.qualified_sale_id is null
          or rf.qualified_sale_id is not distinct from p_selected_sale)
   for update;
  if not found then
    raise exception 'legacy referral is no longer an unresolved rewarded referral'
      using errcode = '55000';
  end if;
  if p_selected_sale is not null then
    select * into v_sale from public.sales s
     where s.id = p_selected_sale and s.business_id = p_business for update;
    if not found or not exists (
      select 1 from public.legacy_referral_sale_candidates c
       where c.referral_id = p_referral
         and c.business_id = p_business
         and c.sale_id = p_selected_sale
    ) then
      raise exception 'selected legacy referral candidate changed while being locked';
    end if;
  end if;
  if not app.has_perm(p_business, 'refund_sales')
     or (p_selected_sale is not null
         and not app.can_see_branch(p_business, v_sale.branch_id)) then
    raise exception 'legacy referral authorization changed while the operation was being locked'
      using errcode = '42501';
  end if;

  insert into public.legacy_referral_resolution_events(
    referral_id, business_id, actor, decision, selected_sale_id, reason
  ) values (p_referral, p_business, v_actor, v_decision, p_selected_sale, v_reason)
  on conflict (referral_id) do nothing
  returning * into v_event;
  if v_event.id is null then
    select * into v_event from public.legacy_referral_resolution_events e
     where e.referral_id = p_referral;
    if not found
       or (v_event.business_id, v_event.actor, v_event.decision,
           v_event.selected_sale_id, v_event.reason)
          is distinct from
          (p_business, v_actor, v_decision, p_selected_sale, v_reason) then
      raise exception 'legacy referral already has a different immutable resolution'
        using errcode = '23505';
    end if;
    return (to_jsonb(v_event) || jsonb_build_object('replayed', true))::json;
  end if;

  if p_selected_sale is not null then
    update public.referrals
       set qualified_sale_id = p_selected_sale
     where id = p_referral and business_id = p_business and qualified_sale_id is null;
    if not found then
      raise exception 'legacy referral cannot accept the selected sale link'
        using errcode = '55000';
    end if;
  end if;
  return (to_jsonb(v_event) || jsonb_build_object('replayed', false))::json;
end $$;

revoke execute on function public.resolve_legacy_referral(uuid, uuid, uuid, text)
  from public, anon;
grant execute on function public.resolve_legacy_referral(uuid, uuid, uuid, text)
  to authenticated;

create or replace function app.on_sale_recorded()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  lp record;
  rp record;
  refrow record;
  refprog record;
  v_pts integer;
  v_idx integer;
  v_count integer;
  v_earn_id uuid;
  v_credit_id uuid;
  w_start timestamptz;
  w_end timestamptz;
begin
  if new.reversal_of is not null then
    return new;
  end if;

  if new.client_id is null then
    return new;
  end if;

  if not (new.earns_points or new.counts_as_visit) then
    return new;
  end if;

  if new.earns_points then
    select * into lp
      from public.loyalty_programs
     where business_id = new.business_id
       and active
     limit 1;
    if found and lp.kind = 'points' then
      v_pts := floor((new.amount_cents / 100.0) * lp.earn_points_per_dollar);
      if v_pts > 0 then
        v_earn_id := gen_random_uuid();
        perform set_config('app.points_ledger_insert_id', v_earn_id::text, true);
        perform set_config('app.points_ledger_write_scope', 'sale_trigger', true);
        insert into public.points_ledger
          (id, business_id, client_id, entry_type, points, sale_id, reference, actor)
        values
          (v_earn_id, new.business_id, new.client_id, 'earn', v_pts, new.id,
           'auto-earn on sale', auth.uid())
        on conflict do nothing
        returning id into v_earn_id;
        perform set_config('app.points_ledger_insert_id', '', true);
        perform set_config('app.points_ledger_write_scope', '', true);
        if v_earn_id is not null then
          insert into public.points_batches (business_id, client_id, earned, remaining, sale_id, earned_at, expires_at)
          values (
            new.business_id,
            new.client_id,
            v_pts,
            v_pts,
            new.id,
            now(),
            case when lp.expiry_mode = 'fixed'
                 then now() + make_interval(days => lp.expiry_days)
            end
          );
        end if;
      end if;
    end if;
  end if;

  if new.counts_as_visit then
    for rp in
      select * from public.retention_programs
       where business_id = new.business_id
         and active
    loop
      v_idx := floor(extract(epoch from (new.occurred_at - rp.starts_on::timestamptz))
                     / (rp.period_days * 86400));
      if v_idx >= 0 then
        w_start := rp.starts_on::timestamptz + make_interval(days => v_idx * rp.period_days);
        w_end := w_start + make_interval(days => rp.period_days);
        select count(*) into v_count
          from public.sales s
         where s.business_id = new.business_id
           and s.client_id = new.client_id
           and s.counts_as_visit
           and s.reversal_of is null
           and not exists (
             select 1 from public.sales r
              where r.business_id = s.business_id
                and r.reversal_of = s.id
           )
           and s.occurred_at >= w_start
           and s.occurred_at < w_end;

        if v_count >= rp.goal_visits then
          begin
            insert into public.reward_grants (
              business_id, program_id, client_id, period_index,
              reward_type, reward_value, reward_item
            )
            values (
              new.business_id, rp.id, new.client_id, v_idx,
              rp.reward_type, rp.reward_value, rp.reward_item
            );
            if rp.reward_type = 'credit' and rp.reward_value > 0 then
              v_credit_id := gen_random_uuid();
              perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
              perform set_config('app.credit_ledger_write_scope', 'sale_trigger', true);
              insert into public.credit_ledger
                (id, business_id, client_id, entry_type, amount_cents, reference, sale_id, actor)
              values (
                v_credit_id,
                new.business_id,
                new.client_id,
                'loyalty_earn',
                rp.reward_value::integer,
                'retention reward: ' || rp.name,
                new.id,
                auth.uid()
              );
              perform set_config('app.credit_ledger_insert_id', '', true);
              perform set_config('app.credit_ledger_write_scope', '', true);
            end if;
          exception when unique_violation then
            null;
          end;
        end if;
      end if;
    end loop;

    select r.* into refrow
      from public.referrals r
     where r.business_id = new.business_id
       and r.referred_client_id = new.client_id
       and r.status = 'pending'
     limit 1;
    if found then
      select * into refprog
        from public.referral_programs
       where business_id = new.business_id
         and enabled
       limit 1;
      if found and new.amount_cents >= coalesce(refprog.min_spend_cents, 0) then
        update public.referrals
           set status = 'rewarded',
               qualified_at = now(),
               qualified_sale_id = new.id,
               reward_cents = refprog.reward_cents
         where id = refrow.id
           and status = 'pending';
        if found then
          v_credit_id := gen_random_uuid();
          perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
          perform set_config('app.credit_ledger_write_scope', 'sale_trigger', true);
          insert into public.credit_ledger
            (id, business_id, client_id, entry_type, amount_cents, reference, sale_id, actor)
          values (
            v_credit_id,
            new.business_id,
            refrow.referrer_client_id,
            'referral_reward',
            refprog.reward_cents,
            'referral qualified: first visit completed',
            new.id,
            auth.uid()
          );
          perform set_config('app.credit_ledger_insert_id', '', true);
          perform set_config('app.credit_ledger_write_scope', '', true);
        end if;
      end if;
    end if;
  end if;

  return new;
end $$;

revoke execute on function app.on_sale_recorded() from public, anon, authenticated;

-- Existing UI calls this RPC. Recreate it so revoked ledger INSERT grants do not break the
-- workflow and so inactive staff cannot continue redeeming customer value.
create or replace function public.redeem_points(p_business uuid, p_client uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  lp public.loyalty_programs%rowtype;
  bal integer;
  v_batch_balance integer;
  v_remaining integer;
  v_take integer;
  v_batch record;
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_points_id uuid := gen_random_uuid();
  v_credit_id uuid := gen_random_uuid();
begin
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to redeem points in this business (create_sales)'
      using errcode = '42501';
  end if;

  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and 'create_sales' = any (app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end, s.created_at
   limit 1
   for update;
  if not found or not app.has_perm(p_business, 'create_sales') then
    raise exception 'active staff authorization changed while redeeming points'
      using errcode = '42501';
  end if;

  perform 1
    from public.clients c
   where c.id = p_client
     and c.business_id = p_business
   for update;
  if not found then
    raise exception 'client does not belong to this business';
  end if;

  select * into lp
    from public.loyalty_programs
   where business_id = p_business
     and active
     and kind = 'points'
     and redeem_points > 0
     and reward_credit_cents > 0
   limit 1;
  if not found then
    raise exception 'no active redeemable points program with positive points and credit values';
  end if;

  select coalesce(sum(pl.points), 0)::integer into bal
    from public.points_ledger pl
   where pl.business_id = p_business
     and pl.client_id = p_client;
  if bal < lp.redeem_points then
    raise exception 'insufficient points: % < %', bal, lp.redeem_points;
  end if;

  select coalesce(sum(pb.remaining), 0)::integer into v_batch_balance
    from public.points_batches pb
   where pb.business_id = p_business
     and pb.client_id = p_client
     and pb.remaining > 0;
  if v_batch_balance < lp.redeem_points then
    raise exception 'points batches % cannot prove redemption %',
      v_batch_balance, lp.redeem_points
      using errcode = 'check_violation';
  end if;

  v_remaining := lp.redeem_points;
  for v_batch in
    select pb.id, pb.remaining
      from public.points_batches pb
     where pb.business_id = p_business
       and pb.client_id = p_client
       and pb.remaining > 0
     order by pb.expires_at nulls last, pb.earned_at, pb.id
     for update
  loop
    exit when v_remaining = 0;
    v_take := least(v_batch.remaining, v_remaining);
    update public.points_batches
       set remaining = remaining - v_take
     where id = v_batch.id;
    v_remaining := v_remaining - v_take;
  end loop;

  perform set_config('app.points_ledger_insert_id', v_points_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'redeem_points', true);
  insert into public.points_ledger
    (id, business_id, client_id, entry_type, points, reference, actor)
  values
    (v_points_id, p_business, p_client, 'redeem', -lp.redeem_points,
     'redeemed to credit', v_actor);
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);

  perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
  perform set_config('app.credit_ledger_write_scope', 'redeem_points', true);
  insert into public.credit_ledger
    (id, business_id, client_id, entry_type, amount_cents, reference, actor)
  values
    (v_credit_id, p_business, p_client, 'loyalty_earn', lp.reward_credit_cents,
     'points redemption', v_actor);
  perform set_config('app.credit_ledger_insert_id', '', true);
  perform set_config('app.credit_ledger_write_scope', '', true);

  return json_build_object(
    'points_spent', lp.redeem_points,
    'credit_cents', lp.reward_credit_cents
  );
end $$;

revoke execute on function public.redeem_points(uuid, uuid) from public, anon;
grant execute on function public.redeem_points(uuid, uuid) to authenticated;

-- This function exists live but is not represented in the repo. Recreate the safe body so a
-- reversal row carrying provenance can never deduct stock a second time.
create or replace function app.on_sale_stock_deduct()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  bt record;
  v_need integer;
  v_take integer;
begin
  if new.reversal_of is not null or new.product_id is null then
    return new;
  end if;

  v_need := coalesce(new.qty, 1);
  if v_need <= 0 then
    return new;
  end if;

  for bt in
    select id, qty
      from public.stock_batches
     where product_id = new.product_id
       and qty > 0
     order by expires_on nulls last, received_on, id
  loop
    exit when v_need <= 0;
    v_take := least(bt.qty, v_need);
    update public.stock_batches
       set qty = qty - v_take
     where id = bt.id;
    v_need := v_need - v_take;
  end loop;

  return new;
end $$;

revoke execute on function app.on_sale_stock_deduct() from public, anon, authenticated;

drop trigger if exists trg_sale_stock_deduct on public.sales;
create trigger trg_sale_stock_deduct
  after insert on public.sales
  for each row execute function app.on_sale_stock_deduct();

-- Freeze the new reversal metadata in the existing sales immutability guard.
create or replace function app.sales_immutable_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reclassify text;
  v_backfill text;
begin
  if tg_op = 'DELETE' then
    raise exception 'sales is append-only: DELETE is not permitted (sale %). Use append-only reversal rows.',
      old.id
      using errcode = 'restrict_violation';
  end if;

  v_reclassify := nullif(current_setting('app.reclassify_sale', true), '');
  v_backfill := nullif(current_setting('app.sales_backfill', true), '');

  if v_reclassify is not null and v_reclassify = old.id::text then
    if (new.id, new.business_id, new.client_id, new.kind, new.amount_cents, new.occurred_at,
        new.created_at, new.note, new.appointment_id, new.product_id, new.qty,
        new.counts_as_visit, new.earns_points, new.policy_resolved_at,
        new.commission_rate_bps, new.commission_resolved_at,
        new.idem_key,
        new.branch_id, new.staff_id, new.reversal_of, new.reversal_reason,
        new.reversal_actor, new.reversal_idempotency_key)
       is distinct from
       (old.id, old.business_id, old.client_id, old.kind, old.amount_cents, old.occurred_at,
        old.created_at, old.note, old.appointment_id, old.product_id, old.qty,
        old.counts_as_visit, old.earns_points, old.policy_resolved_at,
        old.commission_rate_bps, old.commission_resolved_at,
        old.idem_key,
        old.branch_id, old.staff_id, old.reversal_of, old.reversal_reason,
        old.reversal_actor, old.reversal_idempotency_key)
    then
      raise exception 'reclassification of sale % may change counts_as_revenue and nothing else',
        old.id
        using errcode = 'restrict_violation';
    end if;
    return new;
  end if;

  if v_backfill is not null then
    if (new.id, new.business_id, new.client_id, new.kind, new.amount_cents, new.occurred_at,
        new.created_at, new.note, new.appointment_id, new.product_id, new.qty,
        new.counts_as_revenue, new.counts_as_visit, new.earns_points, new.policy_resolved_at,
        new.commission_rate_bps, new.commission_resolved_at,
        new.idem_key,
        new.branch_id, new.staff_id, new.reversal_of, new.reversal_reason,
        new.reversal_actor, new.reversal_idempotency_key)
       is distinct from
       (old.id, old.business_id, old.client_id, old.kind, old.amount_cents, old.occurred_at,
        old.created_at, old.note, old.appointment_id, old.product_id, old.qty,
        old.counts_as_revenue, old.counts_as_visit, old.earns_points, old.policy_resolved_at,
        old.commission_rate_bps, old.commission_resolved_at,
        old.idem_key,
        old.branch_id, old.staff_id, old.reversal_of, old.reversal_reason,
        old.reversal_actor, old.reversal_idempotency_key)
    then
      raise exception 'backfill window "%" may not change economic facts, attribution, snapshots, or reversal metadata of sale %',
        v_backfill, old.id
        using errcode = 'restrict_violation';
    end if;
    return new;
  end if;

  raise exception 'sales is append-only: UPDATE is not permitted (sale %)', old.id
    using errcode = 'restrict_violation';
end $$;

revoke execute on function app.sales_immutable_guard() from public, anon, authenticated;

-- =====================================================================================
-- 5. Fixed derived views and reporting function
-- =====================================================================================

create or replace view public.sale_balance
with (security_invoker = on) as
with reversal_totals as (
  select r.business_id,
         r.reversal_of as sale_id,
         coalesce(sum(r.amount_cents), 0)::integer as reversal_cents
    from public.sales r
   where r.reversal_of is not null
   group by r.business_id, r.reversal_of
),
payment_totals as (
  select s.business_id,
         s.id as sale_id,
         coalesce(sum(p.amount_cents), 0)::integer as paid_cents
    from public.sales s
    left join public.payments p
      on p.business_id = s.business_id
     and (
       p.sale_id = s.id
       or (
         p.sale_id is null
         and s.appointment_id is not null
         and p.appointment_id = s.appointment_id
       )
     )
   where s.reversal_of is null
   group by s.business_id, s.id
)
select s.id as sale_id,
       s.business_id,
       s.branch_id,
       s.client_id,
       s.appointment_id,
       s.kind,
       s.counts_as_revenue,
       (s.amount_cents + coalesce(rt.reversal_cents, 0))::integer as amount_cents,
       s.occurred_at,
       coalesce(pt.paid_cents, 0)::integer as paid_cents,
       ((s.amount_cents + coalesce(rt.reversal_cents, 0)) - coalesce(pt.paid_cents, 0))::integer as balance_cents,
       case
         when (s.amount_cents + coalesce(rt.reversal_cents, 0)) = 0
              and coalesce(pt.paid_cents, 0) = 0 then 'paid'
         when coalesce(pt.paid_cents, 0) <= 0 then 'unpaid'
         when coalesce(pt.paid_cents, 0) < (s.amount_cents + coalesce(rt.reversal_cents, 0)) then 'partial'
         when coalesce(pt.paid_cents, 0) = (s.amount_cents + coalesce(rt.reversal_cents, 0)) then 'paid'
         else 'overpaid'
       end as payment_status,
       s.amount_cents as gross_amount_cents,
       coalesce(-rt.reversal_cents, 0)::integer as reversed_cents
  from public.sales s
  left join reversal_totals rt
    on rt.business_id = s.business_id
   and rt.sale_id = s.id
  left join payment_totals pt
    on pt.business_id = s.business_id
   and pt.sale_id = s.id
 where s.reversal_of is null
   and app.has_perm(s.business_id, 'view_finance');

revoke all on public.sale_balance from anon;
grant select on public.sale_balance to authenticated;

create or replace view public.sale_commission
with (security_invoker = on) as
select s.id as sale_id,
       s.business_id,
       s.branch_id,
       s.staff_id,
       s.kind,
       s.occurred_at,
       s.amount_cents,
       s.commission_rate_bps as rate_bps,
       case
         when s.reversal_of is not null and s.amount_cents < 0 then
           -floor(((-s.amount_cents)::numeric * s.commission_rate_bps::numeric) / 10000)::integer
         else
           floor((s.amount_cents::numeric * s.commission_rate_bps::numeric) / 10000)::integer
       end as commission_cents
  from public.sales s
 where app.has_perm(s.business_id, 'view_finance')
   and app.can_see_branch(s.business_id, s.branch_id);

revoke all on public.sale_commission from anon;
grant select on public.sale_commission to authenticated;

create or replace function public.get_revenue_summary(
  p_business uuid,
  p_from date,
  p_to date,
  p_branch uuid default null::uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_accrual bigint;
  v_cash bigint;
  v_expenses bigint;
  v_unpaid bigint;
  v_collected bigint;
  v_from_ts timestamptz;
  v_to_ts timestamptz;
begin
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'p_from and p_to are required and p_from must be on or before p_to';
  end if;

  if not app.has_perm(p_business, 'view_finance') then
    raise exception 'you do not have permission to view finance for this business (view_finance)'
      using errcode = '42501';
  end if;

  if p_branch is not null and not exists (
    select 1
      from public.branches b
     where b.id = p_branch
       and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to this business';
  end if;

  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'you are not permitted to view this branch scope for this business (branch_visibility)'
      using errcode = '42501';
  end if;

  v_from_ts := p_from::timestamp at time zone 'Asia/Singapore';
  v_to_ts := (p_to + 1)::timestamp at time zone 'Asia/Singapore';

  select coalesce(sum(s.amount_cents), 0)
    into v_accrual
    from public.sales s
   where s.business_id = p_business
     and s.counts_as_revenue
     and s.occurred_at >= v_from_ts
     and s.occurred_at < v_to_ts
     and (p_branch is null or s.branch_id = p_branch);

  select coalesce(sum(p.amount_cents), 0)
    into v_cash
    from public.payments p
    join public.sales s
      on s.business_id = p.business_id
     and s.reversal_of is null
     and (
       s.id = p.sale_id
       or (
         p.sale_id is null
         and p.appointment_id is not null
         and s.appointment_id = p.appointment_id
       )
     )
   where p.business_id = p_business
     and s.counts_as_revenue
     and p.occurred_at >= v_from_ts
     and p.occurred_at < v_to_ts
     and (p_branch is null or p.branch_id = p_branch);

  select coalesce(sum(p.amount_cents), 0)
    into v_collected
    from public.payments p
   where p.business_id = p_business
     and p.method not in ('credit', 'gift_card')
     and p.occurred_at >= v_from_ts
     and p.occurred_at < v_to_ts
     and (p_branch is null or p.branch_id = p_branch);

  select coalesce(sum(b.balance_cents), 0)
    into v_unpaid
    from public.sale_balance b
   where b.business_id = p_business
     and b.counts_as_revenue
     and b.balance_cents > 0
     and b.occurred_at >= v_from_ts
     and b.occurred_at < v_to_ts
     and (p_branch is null or b.branch_id = p_branch);

  select coalesce(sum(round(e.amount_cents::numeric * e.fx_rate_to_base::numeric)), 0)::bigint
    into v_expenses
    from public.expenses e
   where e.business_id = p_business
     and e.voided_at is null
     and e.occurred_on between p_from and p_to
     and (p_branch is null or e.branch_id = p_branch);

  return json_build_object(
    'from', p_from,
    'to', p_to,
    'branch_id', p_branch,
    'revenue_accrual_cents', v_accrual,
    'revenue_cash_cents', v_cash,
    'cash_collected_cents', v_collected,
    'unpaid_balance_cents', v_unpaid,
    'expenses_cents', v_expenses,
    'net_accrual_cents', v_accrual - v_expenses,
    'net_cash_cents', v_cash - v_expenses
  );
end $$;

revoke execute on function public.get_revenue_summary(uuid, date, date, uuid) from public, anon;
grant execute on function public.get_revenue_summary(uuid, date, date, uuid) to authenticated;

-- =====================================================================================
-- 6. Reclassification now moves any full-reversal row with the original.
-- =====================================================================================

create or replace function public.reclassify_sale_policy(
  p_sale uuid,
  p_counts_as_revenue boolean,
  p_reason text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.sales%rowtype;
  n public.sales%rowtype;
  r public.sales%rowtype;
  v_reversal_ids uuid[] := '{}';
  v_actor uuid := auth.uid();
  v_actor_staff uuid;
begin
  if p_counts_as_revenue is null then
    raise exception 'p_counts_as_revenue is required';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'a reason of at least 10 characters is required to reclassify a historical sale';
  end if;

  select * into o
    from public.sales
   where id = p_sale;
  if not found then
    raise exception 'sale not found';
  end if;
  if o.reversal_of is not null then
    raise exception 'reclassify the original sale %, not reversal %', o.reversal_of, o.id;
  end if;
  if not app.has_perm(o.business_id, 'reclassify_sales') then
    raise exception 'only an active owner may reclassify a historical sale'
      using errcode = '42501';
  end if;
  if not app.can_see_branch(o.business_id, o.branch_id) then
    raise exception 'you are not permitted to reclassify this branch scope'
      using errcode = '42501';
  end if;

  select st.id into v_actor_staff
    from public.staff st
   where st.business_id = o.business_id
     and st.user_id = v_actor
     and st.active
     and 'reclassify_sales' = any (app.role_perms(st.role))
   order by st.created_at
   limit 1
   for update;
  if not found then
    raise exception 'active owner authorization is required to reclassify a sale'
      using errcode = '42501';
  end if;

  select * into o
    from public.sales
   where id = p_sale
   for update;
  if not app.has_perm(o.business_id, 'reclassify_sales')
     or not app.can_see_branch(o.business_id, o.branch_id) then
    raise exception 'reclassification authorization changed while the sale was being locked'
      using errcode = '42501';
  end if;
  if o.counts_as_revenue = p_counts_as_revenue then
    raise exception 'sale % already has counts_as_revenue = %; nothing to restate',
      p_sale, p_counts_as_revenue;
  end if;

  perform set_config('app.reclassify_sale', o.id::text, true);
  update public.sales
     set counts_as_revenue = p_counts_as_revenue
   where id = o.id
  returning * into n;
  perform set_config('app.reclassify_sale', '', true);

  for r in
    select * from public.sales
     where business_id = o.business_id
       and reversal_of = o.id
     for update
  loop
    perform set_config('app.reclassify_sale', r.id::text, true);
    update public.sales
       set counts_as_revenue = p_counts_as_revenue
     where id = r.id;
    perform set_config('app.reclassify_sale', '', true);
    v_reversal_ids := array_append(v_reversal_ids, r.id);
  end loop;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (
    o.business_id,
    auth.uid(),
    'RECLASSIFY',
    'sales',
    o.id,
    jsonb_build_object(
      'reason', p_reason,
      'occurred_at', o.occurred_at,
      'kind', o.kind,
      'amount_cents', o.amount_cents,
      'before', jsonb_build_object('counts_as_revenue', o.counts_as_revenue),
      'after', jsonb_build_object('counts_as_revenue', n.counts_as_revenue),
      'reversal_sale_ids', v_reversal_ids,
      'frozen', jsonb_build_object(
        'counts_as_visit', o.counts_as_visit,
        'earns_points', o.earns_points,
        'commission_rate_bps', o.commission_rate_bps
      )
    )
  );

  return row_to_json(n);
end $$;

revoke execute on function public.reclassify_sale_policy(uuid, boolean, text) from public, anon;
grant execute on function public.reclassify_sale_policy(uuid, boolean, text) to authenticated;

-- =====================================================================================
-- 7. RPC: full sale reversal/refund
-- =====================================================================================

create or replace function public.reverse_sale(
  p_business uuid,
  p_sale uuid,
  p_reason text,
  p_idempotency_key text,
  p_reference text default null,
  p_restock_policy text default 'none')
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.sales%rowtype;
  v_reversal public.sales%rowtype;
  v_existing public.sale_reversal_audits%rowtype;
  v_operation public.financial_operations%rowtype;
  v_operation_id uuid := gen_random_uuid();
  v_request_payload jsonb;
  v_request_hash text;
  v_result jsonb;
  v_reversal_id uuid := gen_random_uuid();
  v_actor uuid := auth.uid();
  v_actor_staff uuid;
  v_paid_cents integer;
  v_validated_refund_cents integer;
  v_credit_payment_cents integer := 0;
  v_refund_payment_cents integer := 0;
  v_credit_restored_cents integer := 0;
  v_points_earned_observed integer := 0;
  v_referral_reversed boolean := false;
  v_payment_ids uuid[] := '{}';
  v_effects jsonb;
  pay record;
  v_payment public.payments%rowtype;
  v_payment_id uuid;
  v_payment_key text;
  v_credit public.credit_ledger%rowtype;
  v_credit_id uuid;
  v_credit_key text;
  v_referral public.referrals%rowtype;
begin
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'p_idempotency_key is required and must be at least 8 characters';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'a reversal reason of at least 10 characters is required';
  end if;
  if coalesce(p_restock_policy, 'none') <> 'none' then
    raise exception 'automatic restock policy "%" is unsupported in v20; use none and post manual stock adjustment evidence',
      p_restock_policy;
  end if;

  -- Coarse authorization precedes every attacker-selected advisory or row lock.
  if not app.has_perm(p_business, 'refund_sales') then
    raise exception 'you do not have permission to reverse/refund sales in this business (refund_sales)'
      using errcode = '42501';
  end if;

  select * into o
    from public.sales
   where id = p_sale
     and business_id = p_business;
  if not found then
    raise exception 'sale not found in this business';
  end if;
  if not app.can_see_branch(p_business, o.branch_id) then
    raise exception 'you are not permitted to reverse/refund this branch scope'
      using errcode = '42501';
  end if;

  select st.id into v_actor_staff
    from public.staff st
   where st.business_id = p_business
     and st.user_id = v_actor
     and st.active
     and 'refund_sales' = any (app.role_perms(st.role))
   order by case st.role when 'owner' then 0 when 'manager' then 1 else 2 end, st.created_at
   limit 1
   for update;
  if not found then
    raise exception 'active staff authorization is required to reverse a sale'
      using errcode = '42501';
  end if;

  select * into o
    from public.sales
   where id = p_sale
     and business_id = p_business
   for update;
  if not found then
    raise exception 'sale not found in this business';
  end if;
  if o.appointment_id is not null then
    perform 1
      from public.appointments a
     where a.id = o.appointment_id
       and a.business_id = o.business_id
     for update;
  end if;

  if not app.has_perm(o.business_id, 'refund_sales')
     or not app.can_see_branch(o.business_id, o.branch_id) then
    raise exception 'sale reversal authorization changed while the operation was being locked'
      using errcode = '42501';
  end if;

  v_request_payload := jsonb_build_object(
    'business_id', p_business,
    'sale_id', o.id,
    'branch_id', o.branch_id,
    'actor', v_actor,
    'reason', btrim(p_reason),
    'reference', nullif(btrim(p_reference), ''),
    'restock_policy', 'none'
  );
  v_request_hash := md5(v_request_payload::text);

  select * into v_operation
    from public.financial_operations fo
   where fo.business_id = p_business
     and fo.operation_type = 'sale_reversal'
     and fo.idempotency_key = btrim(p_idempotency_key);
  if found then
    if (v_operation.sale_id, v_operation.branch_id, v_operation.actor,
        v_operation.request_payload, v_operation.request_hash)
       is distinct from
       (o.id, o.branch_id, v_actor, v_request_payload, v_request_hash) then
      raise exception 'sale reversal idempotency key conflicts with a different immutable request'
        using errcode = '23505';
    end if;
    if v_operation.status <> 'completed' or v_operation.result is null then
      raise exception 'sale reversal operation is reserved but incomplete'
        using errcode = '55000';
    end if;
    select * into v_existing
      from public.sale_reversal_audits a
     where a.operation_id = v_operation.id
       and a.business_id = p_business
       and a.original_sale_id = o.id
       and a.actor = v_actor
       and a.idempotency_key = btrim(p_idempotency_key);
    if not found
       or v_existing.reversal_sale_id is distinct from
          (v_operation.result->>'reversal_sale_id')::uuid then
      raise exception 'completed reversal operation is missing exact audit evidence'
        using errcode = 'XX001';
    end if;
    return (v_operation.result || jsonb_build_object('replayed', true))::json;
  end if;

  if o.reversal_of is not null then
    raise exception 'cannot reverse a reversal sale %', o.id;
  end if;
  if o.amount_cents <= 0 then
    raise exception 'sale % has no positive economic amount to reverse', o.id;
  end if;
  if o.kind not in ('service', 'retail', 'quick_sale') then
    raise exception 'v20 supports only service, retail and quick_sale reversals; kind % has no proven launch correction path',
      o.kind;
  end if;
  if exists (
    select 1 from public.sales r
     where r.business_id = o.business_id
       and r.reversal_of = o.id
  ) then
    raise exception 'sale % is already fully reversed; replay with the original idempotency key to retrieve it',
      o.id;
  end if;

  select coalesce(sum(p.amount_cents), 0)::integer
    into v_paid_cents
    from public.payments p
   where p.business_id = o.business_id
     and (
       p.sale_id = o.id
       or (
         p.sale_id is null
         and o.appointment_id is not null
         and p.appointment_id = o.appointment_id
       )
     );

  if v_paid_cents > o.amount_cents then
    raise exception 'sale % is overpaid by % cents; overpayment returns are not part of v20 sale reversal',
      o.id, v_paid_cents - o.amount_cents;
  end if;
  if v_paid_cents < 0 then
    raise exception 'sale % has negative net payments %; standalone payment correction is outside v20 sale reversal',
      o.id, v_paid_cents;
  end if;

  if exists (
    select 1
      from public.payments p
     where p.business_id = o.business_id
       and (
         p.sale_id = o.id
         or (p.sale_id is null and o.appointment_id is not null
             and p.appointment_id = o.appointment_id)
       )
     group by p.method
    having sum(p.amount_cents) < 0
  ) then
    raise exception 'sale % has a negative per-method payment net; undefined payment corrections cannot be reversed', o.id;
  end if;

  if exists (
    select 1
      from public.payments p
     where p.business_id = o.business_id
       and (
         p.sale_id = o.id
         or (p.sale_id is null and o.appointment_id is not null
             and p.appointment_id = o.appointment_id)
       )
     group by p.method
    having sum(p.amount_cents) > 0
       and p.method not in ('cash', 'credit')
  ) then
    raise exception 'launch refunds support only cash and proven store credit; provider-settled methods are disabled'
      using errcode = 'feature_not_supported';
  end if;

  -- Every positive credit payment must be the exact child of one credit_tenders proof row,
  -- including the original negative ledger spend. Aggregates alone are insufficient proof.
  if exists (
    select 1
      from public.payments p
     where p.business_id = o.business_id
       and p.method = 'credit'
       and (
         p.sale_id = o.id
         or (p.sale_id is null and o.appointment_id is not null
             and p.appointment_id = o.appointment_id)
       )
       and not (
         p.kind = 'payment'
         and p.amount_cents > 0
         and p.sale_id = o.id
         and p.appointment_id is null
         and p.client_id is not distinct from o.client_id
         and p.branch_id is not distinct from o.branch_id
         and exists (
           select 1
             from public.credit_tenders ct
             join public.credit_ledger cl
               on cl.id = ct.credit_ledger_id
              and cl.business_id = ct.business_id
            where ct.business_id = o.business_id
              and ct.sale_id = o.id
              and ct.payment_id = p.id
              and ct.client_id is not distinct from o.client_id
              and ct.branch_id is not distinct from o.branch_id
              and ct.amount_cents = p.amount_cents
              and cl.client_id = ct.client_id
              and cl.entry_type = 'spend'
              and cl.amount_cents = -ct.amount_cents
              and cl.sale_id = ct.sale_id
              and cl.payment_id = ct.payment_id
              and cl.actor is not distinct from ct.actor
         )
       )
  ) then
    raise exception 'store-credit refund requires exact credit_tenders and negative credit_ledger proof'
      using errcode = 'check_violation';
  end if;

  select coalesce(sum(p.amount_cents), 0)::integer
    into v_credit_payment_cents
    from public.payments p
   where p.business_id = o.business_id
     and p.method = 'credit'
     and (
       p.sale_id = o.id
       or (p.sale_id is null and o.appointment_id is not null
           and p.appointment_id = o.appointment_id)
     );

  select coalesce(sum(m.net_cents), 0)::integer
    into v_validated_refund_cents
    from (
      select p.method, sum(p.amount_cents)::integer as net_cents
        from public.payments p
       where p.business_id = o.business_id
         and (
           p.sale_id = o.id
           or (p.sale_id is null and o.appointment_id is not null
               and p.appointment_id = o.appointment_id)
         )
       group by p.method
      having sum(p.amount_cents) > 0
         and p.method in ('cash', 'credit')
    ) m;
  if v_validated_refund_cents is distinct from v_paid_cents then
    raise exception 'validated refundable methods % do not equal sale payment net %',
      v_validated_refund_cents, v_paid_cents
      using errcode = 'check_violation';
  end if;

  if exists (
    select 1
      from public.legacy_referral_sale_candidates c
     where c.business_id = o.business_id
       and c.sale_id = o.id
       and not exists (
         select 1 from public.legacy_referral_resolution_events e
          where e.referral_id = c.referral_id
            and e.business_id = c.business_id
       )
  ) then
    raise exception 'sale % is an ambiguous pre-v20 referral qualification candidate; resolve its captured provenance before reversal',
      o.id
      using errcode = 'feature_not_supported';
  end if;

  select coalesce(sum(pl.points), 0)::integer
    into v_points_earned_observed
    from public.points_ledger pl
   where pl.business_id = o.business_id
     and pl.sale_id = o.id
     and pl.entry_type = 'earn';

  -- Parent reservation is the idempotency decision. No sale, payment, loyalty or referral
  -- side effect occurs before this row is accepted.
  perform set_config('app.financial_operation_insert_id', v_operation_id::text, true);
  insert into public.financial_operations (
    id, business_id, branch_id, sale_id, operation_type, actor,
    idempotency_key, request_payload, request_hash
  )
  values (
    v_operation_id, o.business_id, o.branch_id, o.id, 'sale_reversal', v_actor,
    btrim(p_idempotency_key), v_request_payload, v_request_hash
  )
  on conflict (business_id, operation_type, idempotency_key) do nothing
  returning * into v_operation;
  perform set_config('app.financial_operation_insert_id', '', true);

  if v_operation.id is null then
    select * into v_operation
      from public.financial_operations fo
     where fo.business_id = o.business_id
       and fo.operation_type = 'sale_reversal'
       and fo.idempotency_key = btrim(p_idempotency_key);
    if not found
       or (v_operation.sale_id, v_operation.branch_id, v_operation.actor,
           v_operation.request_payload, v_operation.request_hash)
          is distinct from
          (o.id, o.branch_id, v_actor, v_request_payload, v_request_hash) then
      raise exception 'sale reversal idempotency reservation conflicts with a different immutable request'
        using errcode = '23505';
    end if;
    if v_operation.status = 'completed' and v_operation.result is not null then
      return (v_operation.result || jsonb_build_object('replayed', true))::json;
    end if;
    raise exception 'sale reversal operation is already reserved but incomplete'
      using errcode = '55000';
  end if;

  perform set_config('app.sale_reversal_insert_id', v_reversal_id::text, true);
  perform set_config('app.sale_reversal_original_id', o.id::text, true);

  insert into public.sales (
    id, business_id, client_id, kind, amount_cents, occurred_at, note,
    appointment_id, product_id, qty, branch_id, staff_id,
    reversal_of, reversal_reason, reversal_actor, reversal_idempotency_key
  )
  values (
    v_reversal_id, o.business_id, o.client_id, o.kind, -o.amount_cents, now(),
    coalesce(p_reference, 'sale reversal') || ': ' || left(btrim(p_reason), 200),
    null, null, null, o.branch_id, o.staff_id,
    o.id, btrim(p_reason), v_actor, btrim(p_idempotency_key)
  )
  returning * into v_reversal;

  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);

  -- Launch-safe points policy: observe, but do not claw back. Earned points may already have
  -- been redeemed into credit and the current schema has no immutable redemption-to-earn
  -- provenance or tenant policy that can prove the correct compensating chain.

  select * into v_referral
    from public.referrals rf
   where rf.business_id = o.business_id
     and rf.qualified_sale_id = o.id
     and rf.status = 'rewarded'
   for update;

  if found and coalesce(v_referral.reward_cents, 0) > 0 then
    v_credit_id := gen_random_uuid();
    v_credit_key := 'v20:' || v_operation.id || ':referral:' || v_referral.id;
    perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
    perform set_config('app.credit_ledger_write_scope', 'sale_reversal', true);
    insert into public.credit_ledger (
      id, business_id, client_id, entry_type, amount_cents, reference,
      sale_id, actor, idempotency_key
    )
    values (
      v_credit_id,
      o.business_id,
      v_referral.referrer_client_id,
      'manual_adjust',
      -v_referral.reward_cents,
      'sale reversal: referral reward clawback for sale ' || o.id,
      v_reversal.id,
      v_actor,
      v_credit_key
    )
    on conflict (business_id, idempotency_key) where idempotency_key is not null
      do nothing
    returning * into v_credit;
    perform set_config('app.credit_ledger_insert_id', '', true);
    perform set_config('app.credit_ledger_write_scope', '', true);

    if v_credit.id is null then
      select * into v_credit
        from public.credit_ledger cl
       where cl.business_id = o.business_id
         and cl.idempotency_key = v_credit_key;
      if not found
         or (v_credit.client_id, v_credit.entry_type, v_credit.amount_cents,
             v_credit.sale_id, v_credit.payment_id, v_credit.actor)
            is distinct from
            (v_referral.referrer_client_id, 'manual_adjust'::text,
             -v_referral.reward_cents, v_reversal.id, null::uuid, v_actor) then
        raise exception 'referral reversal ledger key conflicts with a different immutable child'
          using errcode = '23505';
      end if;
    end if;

    update public.referrals
       set status = 'pending',
           qualified_at = null,
           qualified_sale_id = null,
           reward_cents = 0
     where id = v_referral.id;
    v_referral_reversed := true;
  end if;

  for pay in
    select p.method,
           sum(p.amount_cents)::integer as net_cents,
           array_agg(p.id order by p.created_at, p.id) as source_payment_ids
      from public.payments p
     where p.business_id = o.business_id
       and (
         p.sale_id = o.id
         or (
           p.sale_id is null
           and o.appointment_id is not null
           and p.appointment_id = o.appointment_id
         )
       )
       and p.method in ('cash', 'credit')
     group by p.method
    having sum(p.amount_cents) > 0
  loop
    v_payment_id := gen_random_uuid();
    v_payment_key := 'v20:' || v_operation.id || ':refund:' || pay.method;
    v_payment := null;
    perform set_config('app.payment_insert_id', v_payment_id::text, true);
    perform set_config('app.payment_write_scope', 'sale_reversal', true);

    insert into public.payments (
      id, business_id, branch_id, sale_id, appointment_id, client_id, staff_id,
      method, kind, amount_cents, reference, note, idempotency_key, created_by
    )
    values (
      v_payment_id,
      o.business_id,
      o.branch_id,
      o.id,
      null,
      o.client_id,
      coalesce(v_actor_staff, o.staff_id),
      pay.method,
      'refund',
      -pay.net_cents,
      coalesce(p_reference, 'sale reversal ' || o.id),
      'auto refund for full sale reversal ' || v_reversal.id,
      v_payment_key,
      v_actor
    )
    on conflict (business_id, idempotency_key) where idempotency_key is not null
      do nothing
    returning * into v_payment;

    perform set_config('app.payment_insert_id', '', true);
    perform set_config('app.payment_write_scope', '', true);

    if v_payment.id is null then
      select * into v_payment
        from public.payments
       where business_id = o.business_id
         and idempotency_key = v_payment_key;
      if not found
         or (v_payment.branch_id, v_payment.sale_id, v_payment.appointment_id,
             v_payment.client_id, v_payment.staff_id, v_payment.method, v_payment.kind,
             v_payment.amount_cents, v_payment.created_by)
            is distinct from
            (o.branch_id, o.id, null::uuid, o.client_id,
             coalesce(v_actor_staff, o.staff_id), pay.method, 'refund'::text,
             -pay.net_cents, v_actor) then
        raise exception 'refund payment key conflicts with a different immutable child %',
          v_payment_key
          using errcode = '23505';
      end if;
    end if;

    v_payment_ids := array_append(v_payment_ids, v_payment.id);
    v_refund_payment_cents := v_refund_payment_cents + pay.net_cents;

    if pay.method = 'credit' then
      v_credit_id := gen_random_uuid();
      v_credit_key := 'v20:' || v_operation.id || ':credit-restore';
      v_credit := null;
      perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
      perform set_config('app.credit_ledger_write_scope', 'sale_reversal', true);
      insert into public.credit_ledger (
        id, business_id, client_id, entry_type, amount_cents, reference,
        sale_id, payment_id, actor, idempotency_key
      )
      values (
        v_credit_id,
        o.business_id,
        o.client_id,
        'manual_adjust',
        pay.net_cents,
        'sale reversal: restore store credit tender for sale ' || o.id,
        v_reversal.id,
        v_payment.id,
        v_actor,
        v_credit_key
      )
      on conflict (business_id, idempotency_key) where idempotency_key is not null
        do nothing
      returning * into v_credit;
      perform set_config('app.credit_ledger_insert_id', '', true);
      perform set_config('app.credit_ledger_write_scope', '', true);

      if v_credit.id is null then
        select * into v_credit
          from public.credit_ledger cl
         where cl.business_id = o.business_id
           and cl.idempotency_key = v_credit_key;
        if not found
           or (v_credit.client_id, v_credit.entry_type, v_credit.amount_cents,
               v_credit.sale_id, v_credit.payment_id, v_credit.actor)
              is distinct from
              (o.client_id, 'manual_adjust'::text, pay.net_cents,
               v_reversal.id, v_payment.id, v_actor) then
          raise exception 'credit restoration key conflicts with a different immutable child'
            using errcode = '23505';
        end if;
      end if;
      v_credit_restored_cents := v_credit_restored_cents + pay.net_cents;
    end if;

    insert into public.sale_reversal_payment_links (
      operation_id, business_id, branch_id, original_sale_id, reversal_sale_id, refund_payment_id,
      method, amount_cents, source_payment_ids
    )
    values (
      v_operation.id,
      o.business_id,
      o.branch_id,
      o.id,
      v_reversal.id,
      v_payment.id,
      pay.method,
      pay.net_cents,
      pay.source_payment_ids
    );
  end loop;

  if v_refund_payment_cents is distinct from v_validated_refund_cents then
    raise exception 'generated refunds % do not equal validated refundable total %',
      v_refund_payment_cents, v_validated_refund_cents
      using errcode = 'check_violation';
  end if;
  if v_credit_restored_cents is distinct from v_credit_payment_cents then
    raise exception 'restored credit % does not equal proven credit tender total %',
      v_credit_restored_cents, v_credit_payment_cents
      using errcode = 'check_violation';
  end if;
  if (select coalesce(sum(p.amount_cents), 0)::integer
        from public.payments p
       where p.id = any(v_payment_ids)) is distinct from -v_validated_refund_cents then
    raise exception 'persisted refund payments do not exactly equal the validated total'
      using errcode = 'check_violation';
  end if;
  if (select coalesce(sum(l.amount_cents), 0)::integer
        from public.sale_reversal_payment_links l
       where l.operation_id = v_operation.id) is distinct from v_validated_refund_cents then
    raise exception 'refund evidence links do not exactly equal the validated total'
      using errcode = 'check_violation';
  end if;

  v_effects := jsonb_build_object(
    'supported_scope', 'full reversal only for service/retail/quick_sale',
    'unsupported_sale_kinds', jsonb_build_array('gift_card', 'package', 'membership'),
    'refund_methods', jsonb_build_array('cash', 'credit'),
    'provider_refunds', 'disabled_until_provider_settlement_integration',
    'inventory_restock_policy', 'none_manual_stock_adjustment_required',
    'payment_refund_ids', v_payment_ids,
    'points_policy', 'clawback_disabled_until_provenance_and_tenant_policy_exist',
    'points_earned_observed', v_points_earned_observed,
    'points_clawed_back', 0,
    'points_batch_remaining_decremented', 0,
    'referral_reversed', v_referral_reversed,
    'credit_restored_cents', v_credit_restored_cents,
    'commission_policy', 'reversal row inherits original commission snapshot; sale_commission nets negative',
    'cash_drawer_policy', 'cash refund payment auto-posts negative sale_cash via trg_payment_drawer'
  );

  insert into public.sale_reversal_audits (
    operation_id, business_id, branch_id, original_sale_id, reversal_sale_id,
    actor, reason, idempotency_key,
    reversed_cents, refunded_payment_cents, credit_restored_cents,
    points_clawed_back, points_batch_remaining_decremented,
    referral_reversed, restock_policy, effects
  )
  values (
    v_operation.id,
    o.business_id,
    o.branch_id,
    o.id,
    v_reversal.id,
    v_actor,
    btrim(p_reason),
    btrim(p_idempotency_key),
    o.amount_cents,
    v_refund_payment_cents,
    v_credit_restored_cents,
    0,
    0,
    v_referral_reversed,
    'none',
    v_effects
  );

  v_result := jsonb_build_object(
    'replayed', false,
    'operation_id', v_operation.id,
    'original_sale_id', o.id,
    'reversal_sale_id', v_reversal.id,
    'reversed_cents', o.amount_cents,
    'refunded_payment_cents', v_refund_payment_cents,
    'credit_restored_cents', v_credit_restored_cents,
    'payment_refund_ids', v_payment_ids,
    'effects', v_effects
  );

  perform set_config('app.financial_operation_complete_id', v_operation.id::text, true);
  update public.financial_operations
     set status = 'completed',
         result = v_result,
         completed_at = now()
   where id = v_operation.id
     and status = 'reserved';
  perform set_config('app.financial_operation_complete_id', '', true);
  if not found then
    raise exception 'failed to complete reserved sale reversal operation'
      using errcode = '55000';
  end if;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (
    o.business_id,
    v_actor,
    'SALE_REVERSAL',
    'sales',
    o.id,
    jsonb_build_object(
      'reason', btrim(p_reason),
      'operation_id', v_operation.id,
      'original_sale_id', o.id,
      'reversal_sale_id', v_reversal.id,
      'reversed_cents', o.amount_cents,
      'refunded_payment_cents', v_refund_payment_cents,
      'credit_restored_cents', v_credit_restored_cents,
      'payment_refund_ids', v_payment_ids,
      'effects', v_effects
    )
  );

  return v_result::json;
end $$;

revoke execute on function public.reverse_sale(uuid, uuid, text, text, text, text) from public, anon;
grant execute on function public.reverse_sale(uuid, uuid, text, text, text, text) to authenticated;

create or replace function public.refund_sale(
  p_business uuid,
  p_sale uuid,
  p_reason text,
  p_idempotency_key text,
  p_reference text default null,
  p_restock_policy text default 'none')
returns json
language sql
security definer
set search_path = public
as $$
  select public.reverse_sale(
    p_business, p_sale, p_reason, p_idempotency_key, p_reference, p_restock_policy
  )
$$;

revoke execute on function public.refund_sale(uuid, uuid, text, text, text, text) from public, anon;
grant execute on function public.refund_sale(uuid, uuid, text, text, text, text) to authenticated;

-- =====================================================================================
-- 8. RPC: atomic store-credit tender
-- =====================================================================================

create or replace function public.record_credit_tender(
  p_business uuid,
  p_sale uuid,
  p_amount_cents integer,
  p_reason text,
  p_idempotency_key text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.sales%rowtype;
  v_existing public.credit_tenders%rowtype;
  v_operation public.financial_operations%rowtype;
  v_operation_id uuid := gen_random_uuid();
  v_request_payload jsonb;
  v_request_hash text;
  v_result jsonb;
  v_credit_balance integer;
  v_sale_net integer;
  v_paid integer;
  v_balance_due integer;
  v_payment public.payments%rowtype;
  v_payment_id uuid := gen_random_uuid();
  v_payment_key text;
  v_ledger public.credit_ledger%rowtype;
  v_ledger_id uuid := gen_random_uuid();
  v_ledger_key text;
  v_actor uuid := auth.uid();
  v_actor_staff uuid;
begin
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'p_idempotency_key is required and must be at least 8 characters';
  end if;
  if coalesce(p_amount_cents, 0) <= 0 then
    raise exception 'store-credit tender amount must be positive';
  end if;

  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to take payment in this business (create_sales)'
      using errcode = '42501';
  end if;

  select * into s
    from public.sales
   where id = p_sale
     and business_id = p_business;
  if not found then
    raise exception 'sale not found in this business';
  end if;
  if not app.can_see_branch(p_business, s.branch_id) then
    raise exception 'you are not permitted to take payment for this branch scope'
      using errcode = '42501';
  end if;

  select st.id into v_actor_staff
    from public.staff st
   where st.business_id = p_business
     and st.user_id = v_actor
     and st.active
     and 'create_sales' = any (app.role_perms(st.role))
   order by case st.role when 'owner' then 0 when 'manager' then 1 else 2 end, st.created_at
   limit 1
   for update;
  if not found then
    raise exception 'active staff authorization is required to take store-credit tender'
      using errcode = '42501';
  end if;

  select * into s
    from public.sales
   where id = p_sale
     and business_id = p_business
   for update;
  if not found then
    raise exception 'sale not found in this business';
  end if;
  if s.appointment_id is not null then
    perform 1
      from public.appointments a
     where a.id = s.appointment_id
       and a.business_id = s.business_id
     for update;
  end if;

  if not app.has_perm(p_business, 'create_sales')
     or not app.can_see_branch(p_business, s.branch_id) then
    raise exception 'store-credit authorization changed while the operation was being locked'
      using errcode = '42501';
  end if;

  v_request_payload := jsonb_build_object(
    'business_id', p_business,
    'sale_id', s.id,
    'branch_id', s.branch_id,
    'client_id', s.client_id,
    'actor', v_actor,
    'amount_cents', p_amount_cents,
    'reason', nullif(btrim(p_reason), '')
  );
  v_request_hash := md5(v_request_payload::text);

  select * into v_operation
    from public.financial_operations fo
   where fo.business_id = p_business
     and fo.operation_type = 'credit_tender'
     and fo.idempotency_key = btrim(p_idempotency_key);
  if found then
    if (v_operation.sale_id, v_operation.branch_id, v_operation.actor,
        v_operation.request_payload, v_operation.request_hash)
       is distinct from
       (s.id, s.branch_id, v_actor, v_request_payload, v_request_hash) then
      raise exception 'credit tender idempotency key conflicts with a different immutable request'
        using errcode = '23505';
    end if;
    if v_operation.status <> 'completed' or v_operation.result is null then
      raise exception 'credit tender operation is reserved but incomplete'
        using errcode = '55000';
    end if;
    select * into v_existing
      from public.credit_tenders ct
     where ct.operation_id = v_operation.id
       and ct.business_id = p_business
       and ct.sale_id = s.id
       and ct.client_id is not distinct from s.client_id
       and ct.branch_id is not distinct from s.branch_id
       and ct.actor = v_actor
       and ct.amount_cents = p_amount_cents
       and ct.idempotency_key = btrim(p_idempotency_key);
    if not found or not exists (
      select 1
        from public.payments p
        join public.credit_ledger cl
          on cl.id = v_existing.credit_ledger_id
         and cl.business_id = v_existing.business_id
       where p.id = v_existing.payment_id
         and p.business_id = v_existing.business_id
         and p.sale_id = v_existing.sale_id
         and p.client_id = v_existing.client_id
         and p.branch_id is not distinct from v_existing.branch_id
         and p.method = 'credit'
         and p.kind = 'payment'
         and p.amount_cents = v_existing.amount_cents
         and p.created_by = v_existing.actor
         and cl.client_id = v_existing.client_id
         and cl.entry_type = 'spend'
         and cl.amount_cents = -v_existing.amount_cents
         and cl.sale_id = v_existing.sale_id
         and cl.payment_id = v_existing.payment_id
         and cl.actor = v_existing.actor
    ) then
      raise exception 'completed credit tender is missing exact payment/ledger proof'
        using errcode = 'XX001';
    end if;
    return (v_operation.result || jsonb_build_object('replayed', true))::json;
  end if;

  if s.reversal_of is not null then
    raise exception 'cannot take store-credit tender on a reversal sale';
  end if;
  if s.client_id is null then
    raise exception 'store-credit tender requires a sale with a client';
  end if;
  if exists (
    select 1 from public.sales r
     where r.business_id = s.business_id
       and r.reversal_of = s.id
  ) then
    raise exception 'cannot take store-credit tender on a reversed sale';
  end if;

  perform 1
    from public.clients c
   where c.id = s.client_id
     and c.business_id = p_business
   for update;
  if not found then
    raise exception 'sale client does not belong to this business';
  end if;

  select coalesce(sum(cl.amount_cents), 0)::integer
    into v_credit_balance
    from public.credit_ledger cl
   where cl.business_id = p_business
     and cl.client_id = s.client_id;

  select (s.amount_cents + coalesce(sum(r.amount_cents), 0))::integer
    into v_sale_net
    from public.sales r
   where r.business_id = s.business_id
     and r.reversal_of = s.id;
  v_sale_net := coalesce(v_sale_net, s.amount_cents);

  select coalesce(sum(p.amount_cents), 0)::integer
    into v_paid
    from public.payments p
   where p.business_id = p_business
     and (
       p.sale_id = s.id
       or (
         p.sale_id is null
         and s.appointment_id is not null
         and p.appointment_id = s.appointment_id
       )
     );

  v_balance_due := v_sale_net - v_paid;

  if v_balance_due <= 0 then
    raise exception 'sale % has no positive balance due for store-credit tender', s.id;
  end if;
  if p_amount_cents > v_balance_due then
    raise exception 'store-credit tender % exceeds sale balance due %', p_amount_cents, v_balance_due;
  end if;
  if p_amount_cents > v_credit_balance then
    raise exception 'insufficient store credit: % available, % requested',
      v_credit_balance, p_amount_cents
      using errcode = '23514';
  end if;

  perform set_config('app.financial_operation_insert_id', v_operation_id::text, true);
  insert into public.financial_operations (
    id, business_id, branch_id, sale_id, operation_type, actor,
    idempotency_key, request_payload, request_hash
  )
  values (
    v_operation_id, p_business, s.branch_id, s.id, 'credit_tender', v_actor,
    btrim(p_idempotency_key), v_request_payload, v_request_hash
  )
  on conflict (business_id, operation_type, idempotency_key) do nothing
  returning * into v_operation;
  perform set_config('app.financial_operation_insert_id', '', true);

  if v_operation.id is null then
    select * into v_operation
      from public.financial_operations fo
     where fo.business_id = p_business
       and fo.operation_type = 'credit_tender'
       and fo.idempotency_key = btrim(p_idempotency_key);
    if not found
       or (v_operation.sale_id, v_operation.branch_id, v_operation.actor,
           v_operation.request_payload, v_operation.request_hash)
          is distinct from
          (s.id, s.branch_id, v_actor, v_request_payload, v_request_hash) then
      raise exception 'credit tender idempotency reservation conflicts with a different immutable request'
        using errcode = '23505';
    end if;
    if v_operation.status = 'completed' and v_operation.result is not null then
      return (v_operation.result || jsonb_build_object('replayed', true))::json;
    end if;
    raise exception 'credit tender operation is already reserved but incomplete'
      using errcode = '55000';
  end if;

  v_payment_key := 'v20:' || v_operation.id || ':payment';
  perform set_config('app.payment_insert_id', v_payment_id::text, true);
  perform set_config('app.payment_write_scope', 'credit_tender', true);

  insert into public.payments (
    id, business_id, branch_id, sale_id, appointment_id, client_id, staff_id,
    method, kind, amount_cents, reference, note, idempotency_key, created_by
  )
  values (
    v_payment_id,
    p_business,
    s.branch_id,
    s.id,
    null,
    s.client_id,
    coalesce(v_actor_staff, s.staff_id),
    'credit',
    'payment',
    p_amount_cents,
    coalesce(p_reason, 'store credit tender'),
    'auto payment from store credit tender',
    v_payment_key,
    v_actor
  )
  on conflict (business_id, idempotency_key) where idempotency_key is not null
    do nothing
  returning * into v_payment;

  perform set_config('app.payment_insert_id', '', true);
  perform set_config('app.payment_write_scope', '', true);

  if v_payment.id is null then
    select * into v_payment
      from public.payments
     where business_id = p_business
       and idempotency_key = v_payment_key;
    if not found
       or (v_payment.branch_id, v_payment.sale_id, v_payment.appointment_id,
           v_payment.client_id, v_payment.staff_id, v_payment.method, v_payment.kind,
           v_payment.amount_cents, v_payment.created_by)
          is distinct from
          (s.branch_id, s.id, null::uuid, s.client_id,
           coalesce(v_actor_staff, s.staff_id), 'credit'::text, 'payment'::text,
           p_amount_cents, v_actor) then
      raise exception 'credit tender payment key conflicts with a different immutable child'
        using errcode = '23505';
    end if;
  end if;

  v_ledger_key := 'v20:' || v_operation.id || ':ledger';
  perform set_config('app.credit_ledger_insert_id', v_ledger_id::text, true);
  perform set_config('app.credit_ledger_write_scope', 'credit_tender', true);
  insert into public.credit_ledger (
    id, business_id, client_id, entry_type, amount_cents, reference,
    sale_id, payment_id, actor, idempotency_key
  )
  values (
    v_ledger_id,
    p_business,
    s.client_id,
    'spend',
    -p_amount_cents,
    coalesce(p_reason, 'store credit tender') || ' sale ' || s.id,
    s.id,
    v_payment.id,
    v_actor,
    v_ledger_key
  )
  on conflict (business_id, idempotency_key) where idempotency_key is not null
    do nothing
  returning * into v_ledger;
  perform set_config('app.credit_ledger_insert_id', '', true);
  perform set_config('app.credit_ledger_write_scope', '', true);

  if v_ledger.id is null then
    select * into v_ledger
      from public.credit_ledger
     where business_id = p_business
       and idempotency_key = v_ledger_key;
    if not found
       or (v_ledger.client_id, v_ledger.entry_type, v_ledger.amount_cents,
           v_ledger.sale_id, v_ledger.payment_id, v_ledger.actor)
          is distinct from
          (s.client_id, 'spend'::text, -p_amount_cents,
           s.id, v_payment.id, v_actor) then
      raise exception 'credit tender ledger key conflicts with a different immutable child'
        using errcode = '23505';
    end if;
  end if;

  insert into public.credit_tenders (
    operation_id, business_id, sale_id, payment_id, credit_ledger_id, client_id, branch_id,
    actor, amount_cents, idempotency_key, reason,
    balance_before_cents, balance_after_cents
  )
  values (
    v_operation.id,
    p_business,
    s.id,
    v_payment.id,
    v_ledger.id,
    s.client_id,
    s.branch_id,
    v_actor,
    p_amount_cents,
    btrim(p_idempotency_key),
    p_reason,
    v_credit_balance,
    v_credit_balance - p_amount_cents
  )
  returning * into v_existing;

  if v_existing.operation_id is distinct from v_operation.id
     or v_existing.payment_id is distinct from v_payment.id
     or v_existing.credit_ledger_id is distinct from v_ledger.id
     or v_existing.balance_after_cents is distinct from
        (v_existing.balance_before_cents - v_existing.amount_cents)
     or (select coalesce(sum(cl.amount_cents), 0)::integer
           from public.credit_ledger cl
          where cl.business_id = p_business
            and cl.client_id = s.client_id) is distinct from
        (v_credit_balance - p_amount_cents) then
    raise exception 'credit_tenders proof or resulting balance is not exact'
      using errcode = 'check_violation';
  end if;

  v_result := jsonb_build_object(
    'replayed', false,
    'operation_id', v_operation.id,
    'sale_id', s.id,
    'payment_id', v_payment.id,
    'credit_ledger_id', v_ledger.id,
    'amount_cents', p_amount_cents,
    'balance_after_cents', v_credit_balance - p_amount_cents
  );

  perform set_config('app.financial_operation_complete_id', v_operation.id::text, true);
  update public.financial_operations
     set status = 'completed',
         result = v_result,
         completed_at = now()
   where id = v_operation.id
     and status = 'reserved';
  perform set_config('app.financial_operation_complete_id', '', true);
  if not found then
    raise exception 'failed to complete reserved credit tender operation'
      using errcode = '55000';
  end if;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (
    p_business,
    v_actor,
    'STORE_CREDIT_TENDER',
    'sales',
    s.id,
    jsonb_build_object(
      'operation_id', v_operation.id,
      'sale_id', s.id,
      'payment_id', v_payment.id,
      'credit_ledger_id', v_ledger.id,
      'amount_cents', p_amount_cents,
      'balance_before_cents', v_credit_balance,
      'balance_after_cents', v_credit_balance - p_amount_cents
    )
  );

  return v_result::json;
end $$;

revoke execute on function public.record_credit_tender(uuid, uuid, integer, text, text)
  from public, anon;
grant execute on function public.record_credit_tender(uuid, uuid, integer, text, text)
  to authenticated;

commit;
