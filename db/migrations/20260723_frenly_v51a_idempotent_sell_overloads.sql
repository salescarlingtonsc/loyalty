-- FRENLY v51a — server-idempotent overloads for sell_package / enroll_membership_v41.
-- Forward-only; rehearsal + db/tests/v51a_idempotent_sell_overloads.sql verify it.
--
-- WHY THESE EXIST
--   Both zero-key entrypoints create a real sales row (kind='package' / 'membership') plus
--   a client_packages / membership row with NO server-side idempotency, so a lost-response
--   client retry double-sells. That is the sole reason packages and memberships were kept
--   out of cart mode (the cart admits only server-idempotent write paths). These 4-arg
--   overloads add the missing key and delegate ALL work to the existing implementations.
--
-- WHICH IDEMPOTENCY MECHANISM — a design-queue correction, verified against the schema
--   The v51 design queue proposed deduping these "via financial_operations". That is NOT
--   usable here: financial_operations.operation_type is CHECK-constrained to
--   ('sale_reversal','credit_tender','quick_sale'); its sale-lifecycle CHECK and its
--   GUC-token write guard (app.financial_operation_write_guard) both hardcode that only
--   'quick_sale' may reserve with sale_id NULL, so the reserve-then-create pattern a NEW
--   sale needs is impossible for any other type without editing that core financial table
--   and its guard — exactly what "do not reimplement the financial engine" forbids. The
--   idempotency mechanism the engine's OWN new-row-creating writes really use is the v41
--   keyed operations ledger (public.gift_card_issue_operations / customer_staff_operations):
--   a per-domain append-only table keyed (business_id, idempotency_key) with a request hash
--   for conflict detection and a cached result — the same keyed-ledger mechanism as
--   financial_operations, minus the quick-sale-only two-phase reservation. issue_gift_card
--   (creates a gift_cards + sales row, deduped via gift_card_issue_operations) is the exact
--   structural precedent for sell_package / enroll (which create client_packages/membership
--   + sales rows). We follow it.

begin;

-- ---------------------------------------------------------------------------
-- 1. Keyed, append-only idempotency ledger for package/membership sells.
-- ---------------------------------------------------------------------------
create table public.sale_intent_operations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  actor uuid not null references auth.users(id) on delete restrict,
  operation_type text not null check (operation_type in ('package_sale', 'membership_enroll')),
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  status text not null check (status in ('completed')),
  client_id uuid not null,
  result jsonb not null check (jsonb_typeof(result) = 'object'),
  created_at timestamptz not null default now(),
  unique (business_id, actor, operation_type, idempotency_key),
  unique (business_id, idempotency_key),
  foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict
);
comment on table public.sale_intent_operations is
  'v51a append-only idempotency and provenance ledger for keyed package/membership sells.';
create index sale_intent_operations_business_idx
  on public.sale_intent_operations(business_id, client_id, created_at);

alter table public.sale_intent_operations enable row level security;
revoke all privileges on table public.sale_intent_operations from public, anon, authenticated;

-- Reuse the v41 generic append-only guard (before update or delete -> raise).
create trigger sale_intent_operations_immutable_guard
  before update or delete on public.sale_intent_operations
  for each row execute function app.v41_operation_immutable_guard();

-- ---------------------------------------------------------------------------
-- 2. sell_package(p_business, p_client, p_plan, p_idempotency_key)
--    New overload; the 3-arg v10 signature is untouched and still works.
-- ---------------------------------------------------------------------------
create or replace function public.sell_package(
  p_business uuid,
  p_client uuid,
  p_plan uuid,
  p_idempotency_key uuid)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_payload jsonb;
  v_hash text;
  v_existing public.sale_intent_operations%rowtype;
  v_result json;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'a package-sale idempotency key is required' using errcode = '22023';
  end if;
  if p_client is null or not exists (
    select 1 from public.clients c where c.id = p_client and c.business_id = p_business
  ) then
    raise exception 'package-sale client does not belong to this business' using errcode = '22023';
  end if;

  v_payload := jsonb_build_object('business_id', p_business, 'client_id', p_client, 'plan_id', p_plan);
  v_hash := app.v41_request_hash(v_payload::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v51a:package:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing
    from public.sale_intent_operations o
   where o.business_id = p_business and o.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.actor is distinct from v_actor
       or v_existing.operation_type <> 'package_sale'
       or v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with another package sale' using errcode = '23505';
    end if;
    return v_existing.result::json;
  end if;

  -- Delegate the actual sale to the existing v10 implementation (its own auth + work).
  v_result := public.sell_package(p_business, p_client, p_plan);

  insert into public.sale_intent_operations(
    business_id, actor, operation_type, idempotency_key, request_hash, status, client_id, result)
  values (
    p_business, v_actor, 'package_sale', p_idempotency_key, v_hash, 'completed', p_client, v_result::jsonb);
  return v_result;
end $$;

revoke all privileges on function public.sell_package(uuid, uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.sell_package(uuid, uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. enroll_membership_v41(p_business, p_client, p_plan, p_idempotency_key)
--    New overload; the 3-arg v41 signature is untouched and still works.
-- ---------------------------------------------------------------------------
create or replace function public.enroll_membership_v41(
  p_business uuid,
  p_client uuid,
  p_plan uuid,
  p_idempotency_key uuid)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_payload jsonb;
  v_hash text;
  v_existing public.sale_intent_operations%rowtype;
  v_result json;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'a membership-enrollment idempotency key is required' using errcode = '22023';
  end if;
  if p_client is null or not exists (
    select 1 from public.clients c where c.id = p_client and c.business_id = p_business
  ) then
    raise exception 'membership-enrollment client does not belong to this business'
      using errcode = '22023';
  end if;

  v_payload := jsonb_build_object('business_id', p_business, 'client_id', p_client, 'plan_id', p_plan);
  v_hash := app.v41_request_hash(v_payload::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v51a:membership:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing
    from public.sale_intent_operations o
   where o.business_id = p_business and o.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.actor is distinct from v_actor
       or v_existing.operation_type <> 'membership_enroll'
       or v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with another membership enrollment'
        using errcode = '23505';
    end if;
    return v_existing.result::json;
  end if;

  -- Delegate to the existing 3-arg v41 implementation (its own auth + work).
  v_result := public.enroll_membership_v41(p_business, p_client, p_plan);

  insert into public.sale_intent_operations(
    business_id, actor, operation_type, idempotency_key, request_hash, status, client_id, result)
  values (
    p_business, v_actor, 'membership_enroll', p_idempotency_key, v_hash, 'completed', p_client, v_result::jsonb);
  return v_result;
end $$;

revoke all privileges on function public.enroll_membership_v41(uuid, uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.enroll_membership_v41(uuid, uuid, uuid, uuid) to authenticated;

commit;
