-- FRENLY v23 — CONFIGURABLE POINTS-&-TIERS LOYALTY MODEL (option A). OWNER-EDITABLE SKELETON.
-- Applied migration name: frenly_v23_loyalty_points_tiers
--
-- ⚠️ REVIEW — NOT YET APPLIED. Verify with a rolled-back chain test, then apply. This is a
-- financial subsystem (points -> store credit), so it lands only after verification.
--
-- WHAT THIS IS. A first-class, per-business loyalty MODEL the owner selects and customises:
-- every sale earns points; points are redeemed against an owner-defined REWARD CATALOG for
-- INSTANT STORE CREDIT (reusing the existing append-only credit_ledger); and customers move
-- through owner-defined TIERS whose threshold basis the owner picks (visits / spend / points).
-- It reproduces the *capability* of common points-and-tiers programs using Frenly's own neutral,
-- owner-renamed terms and artwork — NOT any third party's brand names, tier labels, copy or assets.
--
-- MODEL SELECTOR (owner ruling): loyalty_programs.model is the strategy switch. 'points_tiers'
-- ships now; a second model (owner will specify) slots in as a new enum value + branch later,
-- which is why every model-specific rule reads from this row rather than being hardcoded.
--
-- DECISIONS BAKED IN (owner, 2026-07-20):
--   * tier_basis is OWNER-SELECTABLE with a recommended default of 'visits'.
--   * redemption delivers INSTANT STORE CREDIT (points -> credit_ledger), not vouchers.

begin;

-- 1. PROGRAM CONFIG — one row per business; the strategy selector + earn/expiry rules.
create table if not exists public.loyalty_programs (
  business_id        uuid primary key references public.businesses(id) on delete cascade,
  model              text not null default 'points_tiers'
                       check (model in ('points_tiers')),           -- option B added later
  points_per_dollar  numeric not null default 1 check (points_per_dollar >= 0),
  points_expiry_days integer check (points_expiry_days is null or points_expiry_days > 0),
  tier_basis         text not null default 'visits'                 -- RECOMMENDED default
                       check (tier_basis in ('visits','spend','points_earned')),
  updated_at         timestamptz not null default now()
);
comment on column public.loyalty_programs.tier_basis is
  'How tiers are earned. visits = number of paid visits (recommended; matches a cups-style '
  'program). spend = lifetime dollars. points_earned = lifetime points ever earned. Owner-selectable.';

-- 2. REWARD CATALOG — owner-editable rows (the grid of redeemable rewards). Redeeming a reward
--    spends cost_points and grants credit_cents of store credit.
create table if not exists public.loyalty_rewards (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  name         text not null,                                       -- owner edits, e.g. "$3 off"
  cost_points  integer not null check (cost_points > 0),
  credit_cents integer not null check (credit_cents >= 0),          -- what it's worth as credit
  active       boolean not null default true,
  sort         integer not null default 0,
  created_at   timestamptz not null default now()
);
create index if not exists loyalty_rewards_biz_idx on public.loyalty_rewards (business_id, active, sort);

-- 3. TIERS — owner-editable; threshold is interpreted per loyalty_programs.tier_basis. Seeded with
--    NOTHING here (no tenant-data writes in a migration): the app seeds neutral placeholders
--    (Bronze/Silver/Gold) on first open, which the owner then renames and re-thresholds.
create table if not exists public.loyalty_tiers (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references public.businesses(id) on delete cascade,
  name              text not null,                                  -- owner renames
  threshold         integer not null check (threshold >= 0),        -- visits | dollars | points
  points_multiplier numeric not null default 1 check (points_multiplier >= 1),
  perk_note         text,                                           -- free-form owner perk text
  sort              integer not null default 0
);
create index if not exists loyalty_tiers_biz_idx on public.loyalty_tiers (business_id, threshold);

-- 4. REDEMPTIONS LEDGER — append-only "exchange records" for the member view. The economic truth
--    still lives in points_ledger (spend) + credit_ledger (grant); this is the human-readable trail.
create table if not exists public.loyalty_redemptions (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  client_id    uuid not null references public.clients(id) on delete cascade,
  reward_id    uuid references public.loyalty_rewards(id),
  reward_name  text not null,                                       -- snapshot (reward may change)
  points_spent integer not null check (points_spent > 0),
  credit_cents integer not null check (credit_cents >= 0),
  redeemed_at  timestamptz not null default now(),
  actor        uuid
);
create index if not exists loyalty_redemptions_client_idx on public.loyalty_redemptions (business_id, client_id, redeemed_at desc);

-- 5. RLS — tenant-isolated like every other table. Members read; owners write config; super-admin
--    reads all (sa_read pattern). No anon/authenticated PUBLIC exposure.
--    NOTE: the `ensure_rls` event trigger (public.rls_auto_enable) already enables RLS on any new
--    public table, so the explicit ENABLE below is belt-and-braces (idempotent). Policies are
--    guarded with DROP … IF EXISTS so a re-run (or an interrupted prior apply, which apply_migration
--    can leave partially) can never collide on a duplicate policy name.
alter table public.loyalty_programs    enable row level security;
alter table public.loyalty_rewards     enable row level security;
alter table public.loyalty_tiers       enable row level security;
alter table public.loyalty_redemptions enable row level security;

do $rls$
declare t text;
begin
  foreach t in array array['loyalty_programs','loyalty_rewards','loyalty_tiers','loyalty_redemptions']
  loop
    execute format($p$drop policy if exists %1$I_read   on public.%1$I$p$, t);
    execute format($p$drop policy if exists %1$I_write  on public.%1$I$p$, t);
    execute format($p$drop policy if exists %1$I_sa_read on public.%1$I$p$, t);
    execute format($p$create policy %1$I_read   on public.%1$I for select using (app.is_salon_member(business_id))$p$, t);
    execute format($p$create policy %1$I_write  on public.%1$I for all    using (app.is_salon_owner(business_id)) with check (app.is_salon_owner(business_id))$p$, t);
    execute format($p$create policy %1$I_sa_read on public.%1$I for select using (app.is_super_admin())$p$, t);
  end loop;
end $rls$;

-- 6. TIER RESOLVER — the customer's current tier given the program's chosen basis. SECURITY DEFINER
--    with a safe search_path (v21 standard); authenticated-executable (v22b makes it born
--    owner-only, so the grant below is explicit).
create or replace function app.loyalty_tier_for(p_business uuid, p_client uuid)
returns public.loyalty_tiers language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp' as $$
declare v_basis text; v_metric numeric; v_row public.loyalty_tiers%rowtype;
begin
  select tier_basis into v_basis from public.loyalty_programs where business_id = p_business;
  if v_basis is null then v_basis := 'visits'; end if;

  if v_basis = 'visits' then
    select count(*) into v_metric from public.sales s
      where s.business_id = p_business and s.client_id = p_client and s.counts_as_visit;
  elsif v_basis = 'spend' then
    select coalesce(sum(s.amount_cents),0)/100.0 into v_metric from public.sales s
      where s.business_id = p_business and s.client_id = p_client and s.counts_as_revenue;
  else -- points_earned
    select coalesce(sum(pl.points),0) into v_metric from public.points_ledger pl
      where pl.business_id = p_business and pl.client_id = p_client and pl.entry_type = 'earn';
  end if;

  select * into v_row from public.loyalty_tiers
    where business_id = p_business and threshold <= v_metric
    order by threshold desc, sort desc limit 1;
  return v_row;  -- NULL row => below the lowest tier
end $$;

-- 7. REDEEM A REWARD -> INSTANT STORE CREDIT. Atomic: spend points, grant credit, log the exchange.
--    Owner/staff-driven (member-facing portal redemption is a later gateway RPC).
create or replace function public.redeem_reward(p_business uuid, p_client uuid, p_reward uuid, p_idempotency_key text default null)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp' as $$
declare v_reward public.loyalty_rewards%rowtype; v_balance integer; v_actor uuid := auth.uid(); v_credit_id uuid;
begin
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'not authorized to redeem loyalty rewards' using errcode = '42501';
  end if;
  select * into v_reward from public.loyalty_rewards where id = p_reward and business_id = p_business and active;
  if not found then raise exception 'reward not found or inactive'; end if;

  select coalesce(sum(points),0) into v_balance from public.points_ledger
    where business_id = p_business and client_id = p_client;
  if v_balance < v_reward.cost_points then
    raise exception 'insufficient points: have %, reward costs %', v_balance, v_reward.cost_points
      using errcode = 'check_violation';
  end if;

  -- spend points (append-only)
  insert into public.points_ledger (business_id, client_id, entry_type, points, reference, actor)
    values (p_business, p_client, 'redeem', -v_reward.cost_points, 'reward: ' || v_reward.name, v_actor);

  -- grant store credit (append-only) — reuse the existing credit system
  v_credit_id := gen_random_uuid();
  insert into public.credit_ledger (id, business_id, client_id, entry_type, amount_cents, reference, actor,
                                    idempotency_key)
    values (v_credit_id, p_business, p_client, 'manual_adjust', v_reward.credit_cents,
            'loyalty reward: ' || v_reward.name, v_actor, p_idempotency_key)
    on conflict (business_id, idempotency_key) where idempotency_key is not null do nothing;

  insert into public.loyalty_redemptions (business_id, client_id, reward_id, reward_name, points_spent, credit_cents, actor)
    values (p_business, p_client, v_reward.id, v_reward.name, v_reward.cost_points, v_reward.credit_cents, v_actor);

  return json_build_object('ok', true, 'reward', v_reward.name,
    'points_spent', v_reward.cost_points, 'credit_cents', v_reward.credit_cents);
end $$;

-- 8. GRANTS — owner-only by default (v22b), so grant authenticated EXECUTE explicitly on the two
--    RPCs (matching v21's authenticated-RPC contract). The tables are reached only via RLS.
revoke all on function app.loyalty_tier_for(uuid, uuid) from public;
revoke all on function public.redeem_reward(uuid, uuid, uuid, text) from public;
grant execute on function app.loyalty_tier_for(uuid, uuid) to authenticated;
grant execute on function public.redeem_reward(uuid, uuid, uuid, text) to authenticated;

commit;
