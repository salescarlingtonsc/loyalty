drop table if exists public.loyalty_programs cascade;

create table public.loyalty_programs (
  id                     uuid primary key default gen_random_uuid(),
  business_id            uuid not null unique references public.businesses(id) on delete cascade,
  kind                   text not null default 'points' check (kind in ('points','stamps')),
  earn_rate_bps          integer not null default 500,
  stamp_target           integer,
  reward_credit_cents    integer not null default 0,
  active                 boolean not null default true,
  earn_points_per_dollar numeric not null default 1,
  redeem_points          integer not null default 800,
  tier_basis             text not null default 'visits' check (tier_basis in ('visits','spend','points_earned')),
  loyalty_model          text not null default 'points_tiers' check (loyalty_model in ('points_tiers'))
);

alter table public.loyalty_programs enable row level security;
drop policy if exists loyalty_programs_read    on public.loyalty_programs;
drop policy if exists loyalty_programs_write   on public.loyalty_programs;
drop policy if exists loyalty_programs_sa_read on public.loyalty_programs;
drop policy if exists loyalty_programs_all     on public.loyalty_programs;
create policy loyalty_programs_read    on public.loyalty_programs for select using (app.is_salon_member(business_id));
create policy loyalty_programs_write   on public.loyalty_programs for all    using (app.is_salon_owner(business_id)) with check (app.is_salon_owner(business_id));
create policy loyalty_programs_sa_read on public.loyalty_programs for select using (app.is_super_admin());