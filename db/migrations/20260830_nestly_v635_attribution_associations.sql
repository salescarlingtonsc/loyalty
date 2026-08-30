-- NESTLY v635 — Phase A, M8 (A7/D9): the inferred-association ledger.
-- Owner ruling D9: DIRECT provenance and inferred association are different concepts and
-- must never convert into each other. Direct facts live on source tables (v630's
-- redemption_sale_links_v630, welcome/bring-back grant columns). EVERY future inferred
-- attribution claim — "this redemption probably drove that sale", "this campaign send
-- preceded that return" — lives here, as an append-only row that names its method, window,
-- strength and evidence. There is no code path from this table into any hard link, by
-- construction: different tables, different writers.
--
-- Phase A lands the CONTRACT only: no production job writes here yet (the first writers
-- are Phase D+ attribution jobs). A fixture-only round-trip in the rollback suite proves
-- the shape so later jobs have no excuse to invent parallel schemas.
--
-- Method registry (versioned in docs/design/ci/ATTRIBUTION_METHODS.md, seeded here):
--   same_visit_window_2h      strong  — redemption and paying sale, same client+branch, <=2h apart
--   post_send_return_30d      strong  — first counts_as_visit sale within a send's declared window
--   post_view_purchase_7d     weak    — purchase within 7 days of a promotion view
-- Rows are superseded by appending a newer computed_by for the same (subject, object,
-- method); readers take the latest per method and MUST surface strength + method + window.
begin;

create table public.attribution_associations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  subject_kind text not null check (subject_kind in
    ('redemption','campaign_send','promotion_view','referral_share','rebooking')),
  subject_id uuid not null,
  object_kind text not null check (object_kind in ('sale','appointment','client_return')),
  object_id uuid not null,
  strength text not null check (strength in ('inferred_strong','inferred_weak')),
  method text not null check (method ~ '^[a-z][a-z0-9_]*$'),
  window_start timestamptz not null,
  window_end timestamptz not null check (window_end >= window_start),
  evidence jsonb not null check (jsonb_typeof(evidence) = 'object'),
  computed_by text not null,
  computed_at timestamptz not null default now()
);
create index attribution_associations_subject_idx
  on public.attribution_associations (business_id, subject_kind, subject_id, method, computed_at desc);
create index attribution_associations_object_idx
  on public.attribution_associations (business_id, object_kind, object_id);
alter table public.attribution_associations enable row level security;
create policy attribution_associations_member_read on public.attribution_associations
  for select to authenticated
  using (app.is_salon_member(business_id) or app.is_super_admin());
revoke all on public.attribution_associations from public, anon, authenticated;
grant select on public.attribution_associations to authenticated;

create or replace function app.attribution_associations_guard_v635()
returns trigger language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'attribution_associations is append-only; supersede by appending a newer computed_by'
    using errcode = '42501';
end;
$$;
create trigger trg_attribution_associations_append_only
  before update or delete on public.attribution_associations
  for each row execute function app.attribution_associations_guard_v635();

commit;
