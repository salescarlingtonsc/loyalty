-- NESTLY v628 — Phase A capture-correctness, M1: the shared analytics ground rules.
-- Owner-approved Phase A design (2026-08-30). Three things, all additive:
--   1. app.analytics_business_included_v1 / app.analytics_sale_class_v1 — ONE exclusion
--      authority (demo tenants, named QA tenants, synthetic customers, reversals,
--      $0 entitlement rows, policy flags) so no analytical reader ever re-derives these
--      rules privately again. Advisory in Phase A: existing readers are not force-migrated;
--      every reader added from Phase A onward must use them.
--   2. analytics_observation_watermarks — every forward-only metric records when its
--      evidence began, so early numbers can never silently read as lifetime truths.
--      Later Phase A migrations seed their own keys.
--   3. The customer.referral_shared taxonomy row (A9): the customer app has emitted this
--      event since v300, but it was never registered, so the client allowlist silently
--      dropped it — zero rows ever. The DB half lands here; the JS allowlist entry ships
--      in the same release (app-core.js + the app.js duplicate).
begin;

-- ---------------------------------------------------------------------------
-- 1a. Named analytics-excluded tenants (demo flags are on businesses already;
--     QA tenants are named here rather than hardcoded in function bodies).
-- ---------------------------------------------------------------------------
create table public.analytics_excluded_businesses (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  reason text not null check (reason in ('demo','platform_qa','internal_test')),
  created_at timestamptz not null default now()
);
alter table public.analytics_excluded_businesses enable row level security;
create policy analytics_excluded_sa_read on public.analytics_excluded_businesses
  for select to authenticated using (app.is_super_admin());
-- No write policy at all: service-role / SQL only, same posture as super_admins.
revoke all on public.analytics_excluded_businesses from public, anon, authenticated;
grant select on public.analytics_excluded_businesses to authenticated;

create or replace function app.analytics_business_included_v1(p_business uuid)
returns boolean
language sql stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce((
    select not coalesce(b.is_demo, false)
      from public.businesses b where b.id = p_business
  ), false)
  and not exists (
    select 1 from public.analytics_excluded_businesses x where x.business_id = p_business
  );
$$;

-- ---------------------------------------------------------------------------
-- 1b. Per-sale classification. Wraps the row the caller already has (no extra
--     lookup) plus the client synthetic flag. "Entitlement" = a $0 row whose
--     note/kind marks a redemption or package session — refined further when
--     v634's line kinds land; until then amount=0 is the honest proxy.
-- ---------------------------------------------------------------------------
create or replace function app.analytics_sale_class_v1(p_sale public.sales)
returns table (
  include_revenue boolean,
  include_visit boolean,
  is_reversal boolean,
  is_entitlement boolean,
  is_synthetic_client boolean
)
language sql stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select
    coalesce(p_sale.counts_as_revenue, false)
      and p_sale.reversal_of is null
      and not exists (select 1 from public.sales r
                       where r.reversal_of = p_sale.id and r.business_id = p_sale.business_id),
    coalesce(p_sale.counts_as_visit, false)
      and p_sale.reversal_of is null
      and not exists (select 1 from public.sales r
                       where r.reversal_of = p_sale.id and r.business_id = p_sale.business_id),
    p_sale.reversal_of is not null,
    p_sale.amount_cents = 0,
    coalesce((select c.is_synthetic from public.clients c where c.id = p_sale.client_id), false);
$$;

revoke all on function app.analytics_business_included_v1(uuid) from public, anon;
revoke all on function app.analytics_sale_class_v1(public.sales) from public, anon;
grant execute on function app.analytics_business_included_v1(uuid) to authenticated, service_role;
grant execute on function app.analytics_sale_class_v1(public.sales) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Observation watermarks. Append-only; per-metric, optionally per-business.
-- ---------------------------------------------------------------------------
create table public.analytics_observation_watermarks (
  id uuid primary key default gen_random_uuid(),
  metric_key text not null,
  business_id uuid references public.businesses(id) on delete cascade,
  observed_since timestamptz not null,
  reason text not null,
  created_at timestamptz not null default now(),
  unique (metric_key, business_id)
);
alter table public.analytics_observation_watermarks enable row level security;
create policy watermarks_member_read on public.analytics_observation_watermarks
  for select to authenticated
  using (business_id is null or app.is_salon_member(business_id) or app.is_super_admin());
revoke all on public.analytics_observation_watermarks from public, anon, authenticated;
grant select on public.analytics_observation_watermarks to authenticated;

create or replace function app.watermark_guard_v628()
returns trigger language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'analytics_observation_watermarks is append-only' using errcode = '42501';
end;
$$;
create trigger trg_watermarks_append_only
  before update or delete on public.analytics_observation_watermarks
  for each row execute function app.watermark_guard_v628();

-- A metric's effective start for one business: the later of the platform
-- watermark and the business's own existence.
create or replace function app.metric_observed_since_v1(p_metric text, p_business uuid)
returns timestamptz
language sql stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select greatest(
    coalesce(
      (select w.observed_since from public.analytics_observation_watermarks w
        where w.metric_key = p_metric and w.business_id = p_business),
      (select w.observed_since from public.analytics_observation_watermarks w
        where w.metric_key = p_metric and w.business_id is null)
    ),
    (select b.created_at from public.businesses b where b.id = p_business)
  );
$$;
revoke all on function app.metric_observed_since_v1(text, uuid) from public, anon;
grant execute on function app.metric_observed_since_v1(text, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. A9: register customer.referral_shared (client authority, same shape and
--    retention as customer.promotion_shared from v264).
-- ---------------------------------------------------------------------------
insert into public.product_adoption_event_taxonomy_v100
  (event_name, source_authority, actor_scope, required_module, required_mode,
   business_scope_required, economic_event, description)
values
  ('customer.referral_shared', 'client', 'customer', null, null,
   true, false,
   'Verified customer chose a channel to share their referral link. Records the business and the '
   'channel only — never the recipient, the message, or whether the share completed.')
on conflict (event_name) do nothing;

-- Seed the watermark for the newly-live event (rows can only begin now).
insert into public.analytics_observation_watermarks (metric_key, observed_since, reason)
values ('referral_share_events', now(),
        'customer.referral_shared was emitted but unregistered before v628; no earlier rows exist');

commit;
