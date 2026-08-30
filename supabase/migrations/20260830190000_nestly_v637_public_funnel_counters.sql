-- NESTLY v637 — Phase A, M11 (A14/D2): identity-free pre-login funnel counters.
-- Owner ruling D2: aggregate counters only — no anonymous IDs, no device fingerprints,
-- no post-login stitching. One row per (business, surface, step, Singapore day) holding
-- a bare count, incremented by the public edge gateway (which already fronts these
-- surfaces and rate-limits by cf-connecting-ip). Steps are what the server can honestly
-- see without tracking a person:
--   join:    page_view (landing GET) -> completed (successful join POST)
--   booking: page_view (portal GET)  -> started (availability queried) -> completed (request POST)
-- Completed counts are cross-checkable against real rows (clients / booking_requests).
-- No personal data exists in this table at any point. ⚖️ nothing to assess.
begin;

create table public.public_funnel_counters (
  business_id uuid not null references public.businesses(id) on delete cascade,
  surface text not null check (surface in ('join','booking')),
  step text not null check (step in ('page_view','started','completed')),
  day date not null,
  hits bigint not null default 0 check (hits >= 0),
  primary key (business_id, surface, step, day)
);
alter table public.public_funnel_counters enable row level security;
create policy public_funnel_counters_member_read on public.public_funnel_counters
  for select to authenticated
  using (app.is_salon_member(business_id) or app.is_super_admin());
revoke all on public.public_funnel_counters from public, anon, authenticated;
grant select on public.public_funnel_counters to authenticated;

-- Increment RPC for the edge gateway (service role only; anon can never call it).
-- Fire-and-forget semantics: an unknown business is a silent no-op — the public
-- surface must never error because of telemetry.
create or replace function public.internal_public_funnel_hit_v637(
  p_business uuid, p_surface text, p_step text)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if p_business is null
     or p_surface not in ('join','booking')
     or p_step not in ('page_view','started','completed')
     or not exists (select 1 from public.businesses b where b.id = p_business) then
    return;
  end if;
  insert into public.public_funnel_counters (business_id, surface, step, day, hits)
  values (p_business, p_surface, p_step, (now() at time zone 'Asia/Singapore')::date, 1)
  on conflict (business_id, surface, step, day)
    do update set hits = public.public_funnel_counters.hits + 1;
end;
$$;
revoke all on function public.internal_public_funnel_hit_v637(uuid,text,text) from public, anon, authenticated;
grant execute on function public.internal_public_funnel_hit_v637(uuid,text,text) to service_role;

insert into public.analytics_observation_watermarks (metric_key, observed_since, reason)
values ('public_funnel_counters', now(),
        'identity-free join/booking funnel counts begin at v637 edge deploy; no earlier funnel data exists');

commit;
