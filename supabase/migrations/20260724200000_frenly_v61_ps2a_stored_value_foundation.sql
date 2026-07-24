-- FRENLY v61 - PROGRAM STUDIO PS-2A INCREMENT A: STORED-VALUE FOUNDATION
--
-- Local review candidate. Production apply needs the owner's RELEASE APPROVED phrase
-- (CLAUDE.md standing gate). PS-2 is authorized for the PS-2A FOUNDATION ONLY
-- (docs/design/ps0/PS-GATES.md; docs/design/ps2/PS2A_STORED_VALUE_CONTRACT.md): the
-- accounts / plans / plan-versions / immutable lots / append-only movement authority /
-- op-ledger idempotency envelope / derived-balance functions / the dedicated sv_authority
-- table shipped at 'unbuilt' for every tenant. There is NO spend / redeem / reserve /
-- reverse / refund / expire path and NO cutover here - those are Increments B/C/D and a
-- future authorized cutover phase. No UI ships in Increment A.
--
-- This migration IMPLEMENTS docs/design/ps0/STORED_VALUE_CONTRACT.md (PS-0, FROZEN, the
-- arithmetic authority). PS-0 wins any conflict. Increment A builds only the MINT half of
-- PS-0 §2 (immutable paid + bonus lots, one mint movement each) plus the safety/authority
-- layer PS-0 left unbuilt. The 26 arithmetic vectors + property test remain the acceptance
-- oracle for the spend/refund arithmetic that lands later.
--
-- HARD SAFETY GATES (contract §2/§3):
--   * sv_authority ships every tenant at 'unbuilt'. NO function in this migration can set
--     'live' or 'ready_for_cutover' - the safest gate is an ABSENT transition function. The
--     sv_authority guard ALSO rejects any transition into those two states unconditionally.
--   * get_sv_account.spendable = (authority_state = 'live'), i.e. ALWAYS false in PS-2A; the
--     raw authority_state is carried verbatim so no client can infer spendability.
--   * No sv_* table carries a mutable balance column: every balance is DERIVED as the signed
--     sum of sv_lot_movements. sv_lot_movements is the authority; sv_lots is immutable.
--   * All value is integer cents. Every value-moving RPC is SECURITY DEFINER, pins
--     search_path, is revoked from public/anon/authenticated, and idempotency-keyed through
--     sv_operations (advisory lock + request_hash + cached result replay; conflict = 22023).
--
-- MOVEMENT-KIND VOCABULARY (reconciled to the FROZEN PS-0 authority): sv_lot_movements.kind
-- uses PS-0 §2's exact 8-kind set — 'issue','spend','expiry','reversal','refund','clawback',
-- 'correction','bad_debt' — so the frozen PS-0 arithmetic oracle (ps0-sv-arithmetic property
-- test, which emits 'issue' for mints and 'correction' for owner adjustments) applies to the
-- later spend/refund increments byte-for-byte with no schema change. Increment A writes ONLY
-- 'issue' (top-up + grant mints). The remaining kinds are permitted by CHECK for the later
-- increments; their per-kind sign rules are enforced where those write paths are built
-- (Increment C). Foundation enforces the two kinds it cares about: issue > 0, bad_debt = 0.

begin;

-- =====================================================================
-- 0. Shared immutability guard for the append-only / immutable sv tables. sv_lots and
--    sv_plan_versions are IMMUTABLE (identity + economics never change); sv_lot_movements
--    is APPEND-ONLY (the ledger authority). All three reject every UPDATE and DELETE with
--    restrict_violation. sv_operations reuses the existing app.v41_operation_immutable_guard.
-- =====================================================================
create or replace function app.sv_immutable_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception '% is append-only and immutable', tg_table_name using errcode = 'restrict_violation';
end $$;
revoke all on function app.sv_immutable_guard() from public, anon, authenticated;

-- Monotonic FEFO-secondary key. A single global sequence is monotonic per business as a
-- subsequence, so it preserves lot creation order for the PS-0 FEFO tiebreak
-- (expiry_key asc -> earned_seq asc -> lot id asc) without cross-key contention.
create sequence if not exists app.sv_earned_seq as bigint;
revoke all on sequence app.sv_earned_seq from public, anon, authenticated;

-- =====================================================================
-- 1. sv_plans + sv_plan_versions - the denomination catalog. A plan version is an IMMUTABLE
--    snapshot (price + bonus ladder + expiry terms + terms_snapshot); a top-up pins its
--    exact plan_version_id and reads that snapshot forever (PS-0 §2).
-- =====================================================================
create table public.sv_plans (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint sv_plans_id_business_uk unique (id, business_id)
);
create index sv_plans_business_idx on public.sv_plans (business_id, created_at);
alter table public.sv_plans enable row level security;
create policy sv_plans_owner_read on public.sv_plans for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_plans_sa_read on public.sv_plans for select to authenticated using (app.is_super_admin());
revoke all on public.sv_plans from public, anon, authenticated;
grant select on public.sv_plans to authenticated;

create table public.sv_plan_versions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  plan_id uuid not null,
  version_no int not null,
  price_cents int not null check (price_cents > 0),
  bonus_cents int not null default 0 check (bonus_cents >= 0),
  expiry_days int check (expiry_days is null or expiry_days > 0),
  terms_snapshot jsonb not null,
  published_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint sv_plan_versions_id_business_uk unique (id, business_id),
  constraint sv_plan_versions_plan_version_uk unique (plan_id, version_no),
  constraint sv_plan_versions_plan_fk foreign key (plan_id, business_id)
    references public.sv_plans(id, business_id) on delete restrict
);
create index sv_plan_versions_plan_idx on public.sv_plan_versions (business_id, plan_id, version_no);
create trigger sv_plan_versions_immutable_guard
  before update or delete on public.sv_plan_versions
  for each row execute function app.sv_immutable_guard();
alter table public.sv_plan_versions enable row level security;
create policy sv_plan_versions_owner_read on public.sv_plan_versions for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_plan_versions_sa_read on public.sv_plan_versions for select to authenticated using (app.is_super_admin());
revoke all on public.sv_plan_versions from public, anon, authenticated;
grant select on public.sv_plan_versions to authenticated;

-- =====================================================================
-- 2. sv_operations - the per-domain op-ledger (v41/v58 house pattern, verbatim):
--    unique(business_id, operation_type, idempotency_key) + request_hash + cached result +
--    advisory-lock serialization. Reuses the shared v41 append-only op guard.
-- =====================================================================
create table public.sv_operations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  operation_type text not null check (operation_type in
    ('topup', 'grant', 'spend', 'reserve', 'release', 'expire', 'reverse', 'refund', 'adjust')),
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  actor uuid,
  result jsonb,
  created_at timestamptz not null default now(),
  constraint sv_operations_id_business_uk unique (id, business_id),
  constraint sv_operations_idem_uk unique (business_id, operation_type, idempotency_key)
);
create index sv_operations_business_idx on public.sv_operations (business_id, created_at);
create trigger sv_operations_immutable_guard
  before update or delete on public.sv_operations
  for each row execute function app.v41_operation_immutable_guard();
alter table public.sv_operations enable row level security;
create policy sv_operations_owner_read on public.sv_operations for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_operations_sa_read on public.sv_operations for select to authenticated using (app.is_super_admin());
revoke all on public.sv_operations from public, anon, authenticated;
grant select on public.sv_operations to authenticated;

-- =====================================================================
-- 3. sv_accounts - the (business, customer) container for one asset. Holds NO balance
--    column (hard contract rule); balances are derived from sv_lot_movements. PS-2A ships
--    exactly one asset: stored_value.
-- =====================================================================
create table public.sv_accounts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  client_id uuid not null,
  asset text not null default 'stored_value' check (asset = 'stored_value'),
  created_at timestamptz not null default now(),
  constraint sv_accounts_id_business_uk unique (id, business_id),
  constraint sv_accounts_business_client_asset_uk unique (business_id, client_id, asset),
  constraint sv_accounts_client_fk foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict
);
create index sv_accounts_client_idx on public.sv_accounts (business_id, client_id);
alter table public.sv_accounts enable row level security;
create policy sv_accounts_owner_read on public.sv_accounts for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_accounts_sa_read on public.sv_accounts for select to authenticated using (app.is_super_admin());
revoke all on public.sv_accounts from public, anon, authenticated;
grant select on public.sv_accounts to authenticated;

-- =====================================================================
-- 4. sv_lots - IMMUTABLE minted parcels. One class (paid | bonus), one minted amount, its
--    own expiry_key (paid and bonus expire independently), a monotonic earned_seq FEFO
--    secondary, and the source top-up/grant operation. No remaining_cents column: remaining
--    is DERIVED as the signed sum of this lot's movements.
-- =====================================================================
create table public.sv_lots (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  account_id uuid not null,
  operation_id uuid not null,
  class text not null check (class in ('paid', 'bonus')),
  minted_cents int not null check (minted_cents > 0),
  expiry_key timestamptz,
  earned_seq bigint not null,
  plan_version_id uuid,
  created_at timestamptz not null default now(),
  constraint sv_lots_id_business_uk unique (id, business_id),
  constraint sv_lots_account_fk foreign key (account_id, business_id)
    references public.sv_accounts(id, business_id) on delete restrict,
  constraint sv_lots_operation_fk foreign key (operation_id, business_id)
    references public.sv_operations(id, business_id) on delete restrict,
  constraint sv_lots_plan_version_fk foreign key (plan_version_id, business_id)
    references public.sv_plan_versions(id, business_id) on delete restrict
);
create index sv_lots_account_idx on public.sv_lots (business_id, account_id, class, expiry_key, earned_seq);
create index sv_lots_operation_idx on public.sv_lots (business_id, operation_id);
create trigger sv_lots_immutable_guard
  before update or delete on public.sv_lots
  for each row execute function app.sv_immutable_guard();
alter table public.sv_lots enable row level security;
create policy sv_lots_owner_read on public.sv_lots for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_lots_sa_read on public.sv_lots for select to authenticated using (app.is_super_admin());
revoke all on public.sv_lots from public, anon, authenticated;
grant select on public.sv_lots to authenticated;

-- =====================================================================
-- 5. sv_lot_movements - THE AUTHORITY. Append-only signed rows (PS-0 §2 vocabulary). In
--    Increment A only 'issue' is ever written (top-up + grant mints, always > 0); the other
--    kinds are allowed by CHECK for the later spend/expiry/reversal/refund/clawback/
--    correction/bad_debt increments. Balances are Sum(cents); bad_debt carries cents=0 so it
--    never disturbs the remaining-invariant (PS-0 §2 footnote).
-- =====================================================================
create table public.sv_lot_movements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  account_id uuid not null,
  lot_id uuid not null,
  operation_id uuid not null,
  kind text not null check (kind in
    ('issue', 'spend', 'expiry', 'reversal', 'refund', 'clawback', 'correction', 'bad_debt')),
  cents integer not null,
  created_at timestamptz not null default now(),
  constraint sv_lot_movements_id_business_uk unique (id, business_id),
  -- Foundation sign rules for the two kinds it writes/needs; the remaining kinds' sign
  -- matrix is enforced by their Increment-C write paths.
  constraint sv_lot_movements_issue_positive check (kind <> 'issue' or cents > 0),
  constraint sv_lot_movements_bad_debt_zero check (kind <> 'bad_debt' or cents = 0),
  constraint sv_lot_movements_lot_fk foreign key (lot_id, business_id)
    references public.sv_lots(id, business_id) on delete restrict,
  constraint sv_lot_movements_account_fk foreign key (account_id, business_id)
    references public.sv_accounts(id, business_id) on delete restrict,
  constraint sv_lot_movements_operation_fk foreign key (operation_id, business_id)
    references public.sv_operations(id, business_id) on delete restrict
);
create index sv_lot_movements_lot_idx on public.sv_lot_movements (business_id, lot_id);
create index sv_lot_movements_account_idx on public.sv_lot_movements (business_id, account_id);
create trigger sv_lot_movements_immutable_guard
  before update or delete on public.sv_lot_movements
  for each row execute function app.sv_immutable_guard();
alter table public.sv_lot_movements enable row level security;
create policy sv_lot_movements_owner_read on public.sv_lot_movements for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_lot_movements_sa_read on public.sv_lot_movements for select to authenticated using (app.is_super_admin());
revoke all on public.sv_lot_movements from public, anon, authenticated;
grant select on public.sv_lot_movements to authenticated;

-- =====================================================================
-- 6. sv_authority - the DEDICATED ledger-authority table (contract §2). One row per
--    (business, asset). PS-2A ships every tenant at 'unbuilt'. The guard rejects any
--    transition INTO 'live' or 'ready_for_cutover' unconditionally (belt-and-braces
--    alongside "no function sets them") and forbids deletion (history survives).
--    Browser writes are blocked by the revoked ACL + read-only RLS; only definer paths
--    (the seed trigger, the migration backfill) write it, all at 'unbuilt'.
-- =====================================================================
create table public.sv_authority (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  asset text not null default 'stored_value' check (asset = 'stored_value'),
  state text not null default 'unbuilt' check (state in
    ('unbuilt', 'shadow_testing', 'reconciliation_blocked', 'ready_for_cutover', 'live', 'paused', 'retired')),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint sv_authority_business_asset_uk unique (business_id, asset)
);

create or replace function app.sv_authority_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'sv_authority is not deletable (history survives)' using errcode = 'restrict_violation';
  end if;
  -- PS-2A: cutover is a later authorized phase. No live/ready_for_cutover, ever, here.
  if new.state in ('live', 'ready_for_cutover') then
    raise exception 'sv_authority cannot transition to % in PS-2A (cutover is unreachable until a future authorized phase)', new.state
      using errcode = 'restrict_violation';
  end if;
  return new;
end $$;
revoke all on function app.sv_authority_guard() from public, anon, authenticated;
create trigger sv_authority_guard
  before insert or update or delete on public.sv_authority
  for each row execute function app.sv_authority_guard();

alter table public.sv_authority enable row level security;
create policy sv_authority_owner_read on public.sv_authority for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_authority_sa_read on public.sv_authority for select to authenticated using (app.is_super_admin());
revoke all on public.sv_authority from public, anon, authenticated;
grant select on public.sv_authority to authenticated;

-- Seed one 'unbuilt' authority row per existing business, and a trigger for new tenants
-- (mirrors app.trg_seed_benefit_registry). NEVER seeds anything but 'unbuilt'.
create or replace function app.seed_sv_authority(p_business uuid)
returns void language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  insert into public.sv_authority(business_id, asset, state)
  values (p_business, 'stored_value', 'unbuilt')
  on conflict (business_id, asset) do nothing;
end $$;
revoke all on function app.seed_sv_authority(uuid) from public, anon, authenticated;

do $seed_sv_authority_backfill$
declare v_b uuid;
begin
  for v_b in select id from public.businesses loop
    perform app.seed_sv_authority(v_b);
  end loop;
end $seed_sv_authority_backfill$;

create or replace function app.trg_seed_sv_authority()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  perform app.seed_sv_authority(new.id);
  return new;
end $$;
revoke all on function app.trg_seed_sv_authority() from public, anon, authenticated;
create trigger trg_seed_sv_authority
  after insert on public.businesses
  for each row execute function app.trg_seed_sv_authority();

-- =====================================================================
-- 7. Derived-balance helpers (contract §3: balances are derived, never stored). All read
--    the movement authority; PS-2A has no reservations, so available == Sum(movements) -
--    Increment C subtracts active holds. Revoked from browsers (definer bodies read them).
-- =====================================================================
create or replace function app.sv_lot_remaining(p_lot uuid)
returns integer language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce(sum(m.cents), 0)::integer
    from public.sv_lot_movements m
   where m.lot_id = p_lot
$$;
revoke all on function app.sv_lot_remaining(uuid) from public, anon, authenticated;

create or replace function app.sv_available_balance(p_business uuid, p_account uuid)
returns integer language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  -- PS-2A: no reservations exist yet, so available == Sum(movements). Increment C
  -- subtracts active holds here.
  select coalesce(sum(m.cents), 0)::integer
    from public.sv_lot_movements m
   where m.business_id = p_business and m.account_id = p_account
$$;
revoke all on function app.sv_available_balance(uuid, uuid) from public, anon, authenticated;

create or replace function app.sv_class_balance(p_business uuid, p_account uuid, p_class text)
returns integer language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce(sum(m.cents), 0)::integer
    from public.sv_lot_movements m
    join public.sv_lots l on l.id = m.lot_id and l.business_id = m.business_id
   where m.business_id = p_business and m.account_id = p_account and l.class = p_class
$$;
revoke all on function app.sv_class_balance(uuid, uuid, text) from public, anon, authenticated;

-- Resolve (or create) the single stored_value account for a (business, client). Definer
-- helper only; callers have already authorized + validated the client.
create or replace function app.sv_ensure_account(p_business uuid, p_client uuid)
returns uuid language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_id uuid;
begin
  insert into public.sv_accounts(business_id, client_id, asset)
  values (p_business, p_client, 'stored_value')
  on conflict (business_id, client_id, asset) do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from public.sv_accounts
     where business_id = p_business and client_id = p_client and asset = 'stored_value';
  end if;
  return v_id;
end $$;
revoke all on function app.sv_ensure_account(uuid, uuid) from public, anon, authenticated;

-- =====================================================================
-- 8. public.sv_topup - the MINT operation (PS-0 §2). Owner-only in PS-2A. Idempotent via
--    sv_operations (advisory lock on business+key, request_hash of the canonical request,
--    cached-result replay; a conflicting hash fails closed with 22023). Mints EXACTLY TWO
--    immutable lots: one 'paid' lot = price_cents and one 'bonus' lot = bonus_cents (the
--    bonus lot is skipped when bonus_cents = 0), each with its own expiry_key computed from
--    the plan (null when expiry_days is null), a monotonic earned_seq, and one 'issue'
--    movement. Refuses while sv_authority is 'paused'/'retired' (an sv_pauses table is
--    Increment D; until then the authority state is the earn gate).
-- =====================================================================
create or replace function public.sv_topup(
  p_business uuid, p_client uuid, p_plan_version uuid, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_hash text;
  v_existing public.sv_operations%rowtype;
  v_pv public.sv_plan_versions%rowtype;
  v_state text;
  v_account uuid;
  v_op uuid := gen_random_uuid();
  v_paid_lot uuid := gen_random_uuid();
  v_bonus_lot uuid;
  v_paid_seq bigint;
  v_bonus_seq bigint;
  v_paid_expiry timestamptz;
  v_bonus_expiry timestamptz;
  v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value top-up idempotency key is required' using errcode = '22023';
  end if;

  -- Canonical request: business + client + plan version. A different plan version or client
  -- under the same key is a hash conflict -> fail closed.
  v_hash := app.ps1b_sha256(jsonb_build_object(
    'op', 'topup', 'business_id', p_business, 'client_id', p_client,
    'plan_version_id', p_plan_version)::text);

  perform pg_advisory_xact_lock(hashtextextended(
    'v61:sv_topup:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.sv_operations o
   where o.business_id = p_business and o.operation_type = 'topup' and o.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different stored-value top-up' using errcode = '22023';
    end if;
    return v_existing.result;
  end if;

  -- Validate the plan version belongs to this business (BEFORE any write, so a bad reference
  -- leaves no op/lot/movement row - the whole function is one statement in the caller txn).
  select * into v_pv from public.sv_plan_versions
   where id = p_plan_version and business_id = p_business;
  if not found then
    raise exception 'stored-value plan version does not belong to this business' using errcode = '22023';
  end if;
  if not exists (select 1 from public.clients c where c.id = p_client and c.business_id = p_business) then
    raise exception 'stored-value top-up client does not belong to this business' using errcode = '22023';
  end if;

  -- Authority earn gate (sv_pauses arrives in Increment D). unbuilt/shadow_testing/
  -- reconciliation_blocked/ready_for_cutover all permit minting into the shadow ledger;
  -- paused/retired refuse. A missing row fails closed to refuse.
  select state into v_state from public.sv_authority
   where business_id = p_business and asset = 'stored_value';
  if v_state is null then
    raise exception 'stored-value authority is not initialised for this business' using errcode = '22023';
  end if;
  if v_state in ('paused', 'retired') then
    raise exception 'stored-value earning is % for this business', v_state using errcode = '22023';
  end if;

  v_account := app.sv_ensure_account(p_business, p_client);

  -- Expiry computed per class independently from the plan snapshot (same term here, stored
  -- as its own key on each lot so a future differential-expiry plan and the expiry sweep
  -- treat paid and bonus independently - PS-0 expiry independence).
  v_paid_expiry := case when v_pv.expiry_days is null then null
                        else now() + (v_pv.expiry_days || ' days')::interval end;
  v_bonus_expiry := case when v_pv.expiry_days is null then null
                         else now() + (v_pv.expiry_days || ' days')::interval end;
  v_paid_seq := nextval('app.sv_earned_seq');

  -- Build the cached result FIRST (lot ids pre-generated) so the op row stores it once and
  -- an identical retry replays it verbatim.
  if v_pv.bonus_cents > 0 then
    v_bonus_lot := gen_random_uuid();
    v_bonus_seq := nextval('app.sv_earned_seq');
  end if;

  v_result := jsonb_build_object(
    'status', 'ok',
    'operation_id', v_op,
    'account_id', v_account,
    'asset', 'stored_value',
    'plan_version_id', p_plan_version,
    'paid_lot', jsonb_build_object(
      'lot_id', v_paid_lot, 'class', 'paid', 'minted_cents', v_pv.price_cents,
      'expiry_key', v_paid_expiry, 'earned_seq', v_paid_seq),
    'bonus_lot', case when v_pv.bonus_cents > 0 then jsonb_build_object(
      'lot_id', v_bonus_lot, 'class', 'bonus', 'minted_cents', v_pv.bonus_cents,
      'expiry_key', v_bonus_expiry, 'earned_seq', v_bonus_seq) else null end,
    'minted', jsonb_build_object(
      'paid_cents', v_pv.price_cents, 'bonus_cents', v_pv.bonus_cents,
      'total_cents', v_pv.price_cents + v_pv.bonus_cents));

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'topup', p_idempotency_key, v_hash, v_actor, v_result);

  insert into public.sv_lots(id, business_id, account_id, operation_id, class, minted_cents, expiry_key, earned_seq, plan_version_id)
  values (v_paid_lot, p_business, v_account, v_op, 'paid', v_pv.price_cents, v_paid_expiry, v_paid_seq, p_plan_version);
  insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
  values (p_business, v_account, v_paid_lot, v_op, 'issue', v_pv.price_cents);

  if v_pv.bonus_cents > 0 then
    insert into public.sv_lots(id, business_id, account_id, operation_id, class, minted_cents, expiry_key, earned_seq, plan_version_id)
    values (v_bonus_lot, p_business, v_account, v_op, 'bonus', v_pv.bonus_cents, v_bonus_expiry, v_bonus_seq, p_plan_version);
    insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
    values (p_business, v_account, v_bonus_lot, v_op, 'issue', v_pv.bonus_cents);
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_TOPUP', 'sv_accounts', v_account, jsonb_build_object(
    'operation_id', v_op, 'plan_version_id', p_plan_version,
    'paid_cents', v_pv.price_cents, 'bonus_cents', v_pv.bonus_cents));

  return v_result;
end $$;
revoke all on function public.sv_topup(uuid, uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.sv_topup(uuid, uuid, uuid, uuid) to authenticated;

-- =====================================================================
-- 9. public.sv_grant - owner-only operator/promotional grant. Mints ONE 'bonus' lot + its
--    mint movement, requires a reason of >= 3 chars, and is an append-only ledger event
--    with actor + reason (there is no editable balance field anywhere). Same idempotency
--    envelope. Bonus grants do not expire in PS-2A (expiry_key null).
-- =====================================================================
create or replace function public.sv_grant(
  p_business uuid, p_client uuid, p_cents int, p_reason text, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
  v_hash text;
  v_existing public.sv_operations%rowtype;
  v_state text;
  v_account uuid;
  v_op uuid := gen_random_uuid();
  v_lot uuid := gen_random_uuid();
  v_seq bigint;
  v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value grant idempotency key is required' using errcode = '22023';
  end if;
  if p_cents is null or p_cents < 1 then
    raise exception 'a stored-value grant must be a whole number of at least 1 cent' using errcode = '22023';
  end if;
  if char_length(v_reason) < 3 then
    raise exception 'a stored-value grant requires a reason of at least 3 characters' using errcode = '22023';
  end if;

  v_hash := app.ps1b_sha256(jsonb_build_object(
    'op', 'grant', 'business_id', p_business, 'client_id', p_client,
    'cents', p_cents, 'reason', v_reason)::text);

  perform pg_advisory_xact_lock(hashtextextended(
    'v61:sv_grant:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.sv_operations o
   where o.business_id = p_business and o.operation_type = 'grant' and o.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different stored-value grant' using errcode = '22023';
    end if;
    return v_existing.result;
  end if;

  if not exists (select 1 from public.clients c where c.id = p_client and c.business_id = p_business) then
    raise exception 'stored-value grant client does not belong to this business' using errcode = '22023';
  end if;
  select state into v_state from public.sv_authority
   where business_id = p_business and asset = 'stored_value';
  if v_state is null then
    raise exception 'stored-value authority is not initialised for this business' using errcode = '22023';
  end if;
  if v_state in ('paused', 'retired') then
    raise exception 'stored-value earning is % for this business', v_state using errcode = '22023';
  end if;

  v_account := app.sv_ensure_account(p_business, p_client);
  v_seq := nextval('app.sv_earned_seq');
  v_result := jsonb_build_object(
    'status', 'ok',
    'operation_id', v_op,
    'account_id', v_account,
    'asset', 'stored_value',
    'bonus_lot', jsonb_build_object(
      'lot_id', v_lot, 'class', 'bonus', 'minted_cents', p_cents,
      'expiry_key', null, 'earned_seq', v_seq),
    'minted', jsonb_build_object('paid_cents', 0, 'bonus_cents', p_cents, 'total_cents', p_cents),
    'reason', v_reason);

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'grant', p_idempotency_key, v_hash, v_actor, v_result);
  insert into public.sv_lots(id, business_id, account_id, operation_id, class, minted_cents, expiry_key, earned_seq, plan_version_id)
  values (v_lot, p_business, v_account, v_op, 'bonus', p_cents, null, v_seq, null);
  insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
  values (p_business, v_account, v_lot, v_op, 'issue', p_cents);
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_GRANT', 'sv_accounts', v_account, jsonb_build_object(
    'operation_id', v_op, 'cents', p_cents, 'reason', v_reason));

  return v_result;
end $$;
revoke all on function public.sv_grant(uuid, uuid, integer, text, uuid) from public, anon, authenticated;
grant execute on function public.sv_grant(uuid, uuid, integer, text, uuid) to authenticated;

-- =====================================================================
-- 10. public.get_sv_account - read RPC for owner + salon members (and super admin). Renders
--     the server truth verbatim: authority_state, and spendable = (authority_state = 'live')
--     which is ALWAYS false in PS-2A. The label is never "balance available to spend"; the
--     raw authority_state is carried so the future UI cannot infer spendability. Read-only.
-- =====================================================================
create or replace function public.get_sv_account(p_business uuid, p_client uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_account uuid;
  v_state text;
  v_total int; v_paid int; v_bonus int;
  v_lots jsonb; v_moves jsonb;
begin
  if not (app.is_salon_member(p_business) or app.is_super_admin()) then
    raise exception 'not permitted to view stored value for this business' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clients c where c.id = p_client and c.business_id = p_business) then
    raise exception 'stored-value client does not belong to this business' using errcode = '22023';
  end if;

  select id into v_account from public.sv_accounts
   where business_id = p_business and client_id = p_client and asset = 'stored_value';

  select coalesce(state, 'unbuilt') into v_state from public.sv_authority
   where business_id = p_business and asset = 'stored_value';
  v_state := coalesce(v_state, 'unbuilt');   -- fail closed if no authority row

  if v_account is null then
    v_total := 0; v_paid := 0; v_bonus := 0; v_lots := '[]'::jsonb; v_moves := '[]'::jsonb;
  else
    v_total := app.sv_available_balance(p_business, v_account);
    v_paid := app.sv_class_balance(p_business, v_account, 'paid');
    v_bonus := app.sv_class_balance(p_business, v_account, 'bonus');
    select coalesce(jsonb_agg(jsonb_build_object(
        'lot_id', l.id, 'class', l.class, 'minted_cents', l.minted_cents,
        'remaining_cents', app.sv_lot_remaining(l.id), 'expiry_key', l.expiry_key,
        'earned_seq', l.earned_seq, 'plan_version_id', l.plan_version_id) order by l.earned_seq), '[]'::jsonb)
      into v_lots from public.sv_lots l
     where l.business_id = p_business and l.account_id = v_account;
    select coalesce(jsonb_agg(jsonb_build_object(
        'movement_id', t.id, 'lot_id', t.lot_id, 'kind', t.kind,
        'cents', t.cents, 'created_at', t.created_at) order by t.created_at desc, t.id), '[]'::jsonb)
      into v_moves
      from (select mv.id, mv.lot_id, mv.kind, mv.cents, mv.created_at
              from public.sv_lot_movements mv
             where mv.business_id = p_business and mv.account_id = v_account
             order by mv.created_at desc, mv.id limit 50) t;
  end if;

  return jsonb_build_object(
    'business_id', p_business,
    'client_id', p_client,
    'account_id', v_account,
    'asset', 'stored_value',
    'authority_state', v_state,
    'spendable', (v_state = 'live'),
    'balances', jsonb_build_object('total_cents', v_total, 'paid_cents', v_paid, 'bonus_cents', v_bonus),
    'lots', v_lots,
    'recent_movements', v_moves);
end $$;
revoke all on function public.get_sv_account(uuid, uuid) from public, anon, authenticated;
grant execute on function public.get_sv_account(uuid, uuid) to authenticated;

commit;
