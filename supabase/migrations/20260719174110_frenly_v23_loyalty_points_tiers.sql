create table if not exists public.loyalty_programs (
  business_id        uuid primary key references public.businesses(id) on delete cascade,
  model              text not null default 'points_tiers' check (model in ('points_tiers')),
  points_per_dollar  numeric not null default 1 check (points_per_dollar >= 0),
  points_expiry_days integer check (points_expiry_days is null or points_expiry_days > 0),
  tier_basis         text not null default 'visits' check (tier_basis in ('visits','spend','points_earned')),
  updated_at         timestamptz not null default now()
);

create table if not exists public.loyalty_rewards (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  name         text not null,
  cost_points  integer not null check (cost_points > 0),
  credit_cents integer not null check (credit_cents >= 0),
  active       boolean not null default true,
  sort         integer not null default 0,
  created_at   timestamptz not null default now()
);
create index if not exists loyalty_rewards_biz_idx on public.loyalty_rewards (business_id, active, sort);

create table if not exists public.loyalty_tiers (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references public.businesses(id) on delete cascade,
  name              text not null,
  threshold         integer not null check (threshold >= 0),
  points_multiplier numeric not null default 1 check (points_multiplier >= 1),
  perk_note         text,
  sort              integer not null default 0
);
create index if not exists loyalty_tiers_biz_idx on public.loyalty_tiers (business_id, threshold);

create table if not exists public.loyalty_redemptions (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  client_id    uuid not null references public.clients(id) on delete cascade,
  reward_id    uuid references public.loyalty_rewards(id),
  reward_name  text not null,
  points_spent integer not null check (points_spent > 0),
  credit_cents integer not null check (credit_cents >= 0),
  redeemed_at  timestamptz not null default now(),
  actor        uuid
);
create index if not exists loyalty_redemptions_client_idx on public.loyalty_redemptions (business_id, client_id, redeemed_at desc);

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
  else
    select coalesce(sum(pl.points),0) into v_metric from public.points_ledger pl
      where pl.business_id = p_business and pl.client_id = p_client and pl.entry_type = 'earn';
  end if;
  select * into v_row from public.loyalty_tiers
    where business_id = p_business and threshold <= v_metric
    order by threshold desc, sort desc limit 1;
  return v_row;
end $$;

create or replace function public.redeem_reward(p_business uuid, p_client uuid, p_reward uuid, p_idempotency_key text default null)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp' as $$
declare v_reward public.loyalty_rewards%rowtype; v_balance integer; v_actor uuid := auth.uid(); v_credit_id uuid;
begin
  if not app.has_perm(p_business, 'redeem_points') then
    raise exception 'not authorized to redeem loyalty rewards' using errcode = '42501';
  end if;
  select * into v_reward from public.loyalty_rewards where id = p_reward and business_id = p_business and active;
  if not found then raise exception 'reward not found or inactive'; end if;
  select coalesce(sum(points),0) into v_balance from public.points_ledger
    where business_id = p_business and client_id = p_client;
  if v_balance < v_reward.cost_points then
    raise exception 'insufficient points: have %, reward costs %', v_balance, v_reward.cost_points using errcode = 'check_violation';
  end if;
  insert into public.points_ledger (business_id, client_id, entry_type, points, reason)
    values (p_business, p_client, 'redeem', -v_reward.cost_points, 'reward: ' || v_reward.name);
  v_credit_id := gen_random_uuid();
  insert into public.credit_ledger (id, business_id, client_id, entry_type, amount_cents, reference, actor, idempotency_key)
    values (v_credit_id, p_business, p_client, 'manual_adjust', v_reward.credit_cents, 'loyalty reward: ' || v_reward.name, v_actor, p_idempotency_key)
    on conflict (business_id, idempotency_key) where idempotency_key is not null do nothing;
  insert into public.loyalty_redemptions (business_id, client_id, reward_id, reward_name, points_spent, credit_cents, actor)
    values (p_business, p_client, v_reward.id, v_reward.name, v_reward.cost_points, v_reward.credit_cents, v_actor);
  return json_build_object('ok', true, 'reward', v_reward.name, 'points_spent', v_reward.cost_points, 'credit_cents', v_reward.credit_cents);
end $$;

revoke all on function app.loyalty_tier_for(uuid, uuid) from public;
revoke all on function public.redeem_reward(uuid, uuid, uuid, text) from public;
grant execute on function app.loyalty_tier_for(uuid, uuid) to authenticated;
grant execute on function public.redeem_reward(uuid, uuid, uuid, text) to authenticated;