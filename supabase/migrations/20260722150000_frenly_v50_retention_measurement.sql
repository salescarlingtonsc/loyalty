-- FRENLY v50 - RETENTION MEASUREMENT (HOLDOUT GROUPS + INCREMENTAL-LIFT ATTRIBUTION)
--
-- Local review candidate. Forward-only; not approved for production application.
-- Builds the measurement layer for Frenly's differentiator: publish a versioned
-- retention rule against a FROZEN audience snapshot, deterministically split that
-- audience into treatment/holdout, issue the offer ONLY to treatment members, then
-- prove repeat-visit lift by comparing reversal-aware return rates and revenue.
--
-- Design invariants honoured (mirrors v27/v34/v35/v37b/v49b):
--   * RLS on every new table; owner-read + <t>_sa_read super-admin read policies.
--   * Append-only history: campaigns are lifecycle-only mutable, members/grants/
--     returns are immutable evidence (before update/delete guards, v34 style).
--   * SECURITY DEFINER RPCs pin search_path and are revoked from public/anon, then
--     granted only to authenticated (v22b born-owner-only reasserted explicitly).
--   * Tenant isolation via business_id scoping and composite (id,business_id) FKs.
--   * Deterministic, reproducible holdout assignment: hashtextextended over
--     (campaign_id, client_id) modulo 100 -- no floating randomness.
--   * Holdout exclusion is STRUCTURAL, not merely UI: a grant/return row FKs the
--     member's (campaign_id, client_id, assignment) with assignment pinned to
--     'treatment' for grants, so the database itself refuses a holdout offer.
--   * NO writes to points_ledger / credit_ledger here. The offer flows through the
--     EXISTING reward_grants / redeem machinery; v50 only orchestrates and measures.
--     retention_campaign_grants.reward_grant_id links the issued offer to a real
--     reward_grants row (tenant-safe composite FK) when one exists.
--   * Returns are judged by the canonical v10/v37b qualifying-visit predicate
--     (counts_as_visit AND reversal_of IS NULL AND not-reversed), so a reversed
--     sale can never count as a return.

begin;

-- reward_grants gained no tenant-safe composite parent key before v50. Add it so
-- the offer-issuance linkage can prove same-business ownership structurally, the
-- same pattern v34 used for its provenance edges. id is the PK, so this is safe.
alter table public.reward_grants
  add constraint reward_grants_id_business_uk unique (id, business_id);

-- ---------------------------------------------------------------------------
-- 1. Deterministic holdout bucket. Pure, immutable, reproducible across re-runs.
--    hashtextextended is a stable pg_catalog hash; (x % 100 + 100) % 100 folds the
--    signed int8 into 0..99 without abs() overflow on int8'-9223372036854775808'.
-- ---------------------------------------------------------------------------
create or replace function app.campaign_holdout_bucket(p_campaign uuid, p_client uuid)
returns smallint
language sql
immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select (((hashtextextended(p_campaign::text || ':' || p_client::text, 0) % 100) + 100) % 100)::smallint
$$;
revoke all privileges on function app.campaign_holdout_bucket(uuid, uuid)
  from public, anon, authenticated;
grant execute on function app.campaign_holdout_bucket(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. retention_campaigns: a published run of a versioned retention rule against a
--    frozen audience. Lifecycle-only mutable (draft -> active -> completed/cancelled).
-- ---------------------------------------------------------------------------
create table public.retention_campaigns (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  retention_program_version_id uuid not null,
  program_id uuid not null,
  config_version_id uuid not null,
  name text not null check (char_length(btrim(name)) between 1 and 120),
  audience_criteria jsonb not null check (jsonb_typeof(audience_criteria) = 'object'),
  audience_size integer check (audience_size is null or audience_size >= 0),
  holdout_percent integer not null default 10 check (holdout_percent between 0 and 90),
  budget_cap_cents bigint not null default 0 check (budget_cap_cents >= 0),
  expected_cost_cents bigint check (expected_cost_cents is null or expected_cost_cents >= 0),
  expected_upside_cents bigint check (expected_upside_cents is null or expected_upside_cents >= 0),
  attribution_window_days integer not null check (attribution_window_days between 1 and 365),
  explanation text check (explanation is null or char_length(explanation) <= 4000),
  status text not null default 'draft'
    check (status in ('draft', 'active', 'completed', 'cancelled')),
  created_by uuid not null,
  created_at timestamptz not null default now(),
  activated_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  constraint retention_campaigns_id_business_uk unique (id, business_id),
  constraint retention_campaigns_program_version_business_fk
    foreign key (retention_program_version_id, program_id, business_id)
    references public.retention_program_versions(id, program_id, business_id) on delete restrict,
  constraint retention_campaigns_config_business_fk
    foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict,
  constraint retention_campaigns_lifecycle_check check (
    (status = 'draft'
      and activated_at is null and audience_size is null
      and completed_at is null and cancelled_at is null)
    or (status = 'active'
      and activated_at is not null and audience_size is not null
      and completed_at is null and cancelled_at is null)
    or (status = 'completed'
      and activated_at is not null and audience_size is not null
      and completed_at is not null and cancelled_at is null)
    or (status = 'cancelled'
      and completed_at is null and cancelled_at is not null)
  )
);
create index retention_campaigns_business_status_idx
  on public.retention_campaigns(business_id, status, created_at desc);

alter table public.retention_campaigns enable row level security;
revoke all privileges on table public.retention_campaigns from public, anon, authenticated;
grant select on public.retention_campaigns to authenticated;
create policy retention_campaigns_owner_read on public.retention_campaigns
  for select to authenticated using (app.is_salon_owner(business_id));
create policy retention_campaigns_sa_read on public.retention_campaigns
  for select to authenticated using (app.is_super_admin());

-- ---------------------------------------------------------------------------
-- 3. retention_campaign_members: the frozen audience + immutable deterministic arm.
-- ---------------------------------------------------------------------------
create table public.retention_campaign_members (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null,
  business_id uuid not null,
  client_id uuid not null,
  assignment text not null check (assignment in ('treatment', 'holdout')),
  assignment_bucket smallint not null check (assignment_bucket between 0 and 99),
  created_at timestamptz not null default now(),
  constraint retention_campaign_members_campaign_business_fk
    foreign key (campaign_id, business_id)
    references public.retention_campaigns(id, business_id) on delete cascade,
  constraint retention_campaign_members_client_business_fk
    foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint retention_campaign_members_member_uk unique (campaign_id, client_id),
  -- Superset key used as the structural holdout-exclusion FK target below.
  constraint retention_campaign_members_arm_uk unique (campaign_id, client_id, assignment),
  constraint retention_campaign_members_id_business_uk unique (id, business_id)
);
create index retention_campaign_members_campaign_arm_idx
  on public.retention_campaign_members(campaign_id, assignment, client_id);

alter table public.retention_campaign_members enable row level security;
revoke all privileges on table public.retention_campaign_members from public, anon, authenticated;
grant select on public.retention_campaign_members to authenticated;
create policy retention_campaign_members_owner_read on public.retention_campaign_members
  for select to authenticated using (app.is_salon_owner(business_id));
create policy retention_campaign_members_sa_read on public.retention_campaign_members
  for select to authenticated using (app.is_super_admin());

-- ---------------------------------------------------------------------------
-- 4. retention_campaign_grants: idempotent offer issuance for TREATMENT members.
--    assignment is pinned 'treatment' and FKs the member arm, so a holdout offer is
--    structurally impossible even if an RPC were buggy. reward_grant_id optionally
--    links the issued offer to a real reward_grants row (v50 never creates one).
-- ---------------------------------------------------------------------------
create table public.retention_campaign_grants (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null,
  business_id uuid not null,
  client_id uuid not null,
  assignment text not null default 'treatment' check (assignment = 'treatment'),
  reward_grant_id uuid,
  offer_cost_cents bigint not null default 0 check (offer_cost_cents >= 0),
  idempotency_key text not null check (length(btrim(idempotency_key)) >= 8),
  issued_by uuid not null,
  issued_at timestamptz not null default now(),
  constraint retention_campaign_grants_campaign_business_fk
    foreign key (campaign_id, business_id)
    references public.retention_campaigns(id, business_id) on delete cascade,
  constraint retention_campaign_grants_treatment_member_fk
    foreign key (campaign_id, client_id, assignment)
    references public.retention_campaign_members(campaign_id, client_id, assignment) on delete restrict,
  constraint retention_campaign_grants_reward_grant_business_fk
    foreign key (reward_grant_id, business_id)
    references public.reward_grants(id, business_id) on delete restrict,
  constraint retention_campaign_grants_member_uk unique (campaign_id, client_id),
  constraint retention_campaign_grants_idempotency_uk unique (business_id, idempotency_key)
);
create index retention_campaign_grants_campaign_idx
  on public.retention_campaign_grants(campaign_id, client_id);

alter table public.retention_campaign_grants enable row level security;
revoke all privileges on table public.retention_campaign_grants from public, anon, authenticated;
grant select on public.retention_campaign_grants to authenticated;
create policy retention_campaign_grants_owner_read on public.retention_campaign_grants
  for select to authenticated using (app.is_salon_owner(business_id));
create policy retention_campaign_grants_sa_read on public.retention_campaign_grants
  for select to authenticated using (app.is_super_admin());

-- ---------------------------------------------------------------------------
-- 5. retention_campaign_returns: durable, append-only per-member first-qualifying
--    return evidence for BOTH arms (holdout returns drive the counterfactual).
--    Captured reversal-aware; the live readout re-judges reversals independently.
-- ---------------------------------------------------------------------------
create table public.retention_campaign_returns (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null,
  business_id uuid not null,
  client_id uuid not null,
  assignment text not null check (assignment in ('treatment', 'holdout')),
  sale_id uuid not null,
  returned_at timestamptz not null,
  recorded_by uuid not null,
  recorded_at timestamptz not null default now(),
  constraint retention_campaign_returns_campaign_business_fk
    foreign key (campaign_id, business_id)
    references public.retention_campaigns(id, business_id) on delete cascade,
  constraint retention_campaign_returns_member_fk
    foreign key (campaign_id, client_id, assignment)
    references public.retention_campaign_members(campaign_id, client_id, assignment) on delete restrict,
  constraint retention_campaign_returns_sale_business_fk
    foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete restrict,
  constraint retention_campaign_returns_member_uk unique (campaign_id, client_id),
  constraint retention_campaign_returns_sale_uk unique (sale_id)
);
create index retention_campaign_returns_campaign_arm_idx
  on public.retention_campaign_returns(campaign_id, assignment);

alter table public.retention_campaign_returns enable row level security;
revoke all privileges on table public.retention_campaign_returns from public, anon, authenticated;
grant select on public.retention_campaign_returns to authenticated;
create policy retention_campaign_returns_owner_read on public.retention_campaign_returns
  for select to authenticated using (app.is_salon_owner(business_id));
create policy retention_campaign_returns_sa_read on public.retention_campaign_returns
  for select to authenticated using (app.is_super_admin());

-- ---------------------------------------------------------------------------
-- 6. Immutability guards (v34 evidence-guard style).
-- ---------------------------------------------------------------------------
create or replace function app.retention_campaign_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'retention campaigns are append-only' using errcode = 'restrict_violation';
  end if;
  if new.id is distinct from old.id
     or new.business_id is distinct from old.business_id
     or new.retention_program_version_id is distinct from old.retention_program_version_id
     or new.program_id is distinct from old.program_id
     or new.config_version_id is distinct from old.config_version_id
     or new.name is distinct from old.name
     or new.audience_criteria is distinct from old.audience_criteria
     or new.holdout_percent is distinct from old.holdout_percent
     or new.budget_cap_cents is distinct from old.budget_cap_cents
     or new.attribution_window_days is distinct from old.attribution_window_days
     or new.created_by is distinct from old.created_by
     or new.created_at is distinct from old.created_at then
    raise exception 'retention campaign identity and terms are immutable'
      using errcode = 'restrict_violation';
  end if;
  if (old.activated_at is not null and new.activated_at is distinct from old.activated_at)
     or (old.audience_size is not null and new.audience_size is distinct from old.audience_size) then
    raise exception 'a frozen campaign audience and activation are immutable'
      using errcode = 'restrict_violation';
  end if;
  if not (
       (old.status = 'draft' and new.status in ('draft', 'active', 'cancelled'))
    or (old.status = 'active' and new.status in ('active', 'completed', 'cancelled'))
    or (old.status = new.status)
  ) then
    raise exception 'illegal retention campaign status transition % -> %', old.status, new.status
      using errcode = 'restrict_violation';
  end if;
  return new;
end $$;
revoke all privileges on function app.retention_campaign_guard() from public, anon, authenticated;
create trigger trg_retention_campaign_guard
  before update or delete on public.retention_campaigns
  for each row execute function app.retention_campaign_guard();

create or replace function app.retention_campaign_child_immutable_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'v50 campaign membership, offer, and return evidence is append-only'
    using errcode = 'restrict_violation';
end $$;
revoke all privileges on function app.retention_campaign_child_immutable_guard()
  from public, anon, authenticated;
create trigger trg_retention_campaign_members_immutable
  before update or delete on public.retention_campaign_members
  for each row execute function app.retention_campaign_child_immutable_guard();
create trigger trg_retention_campaign_grants_immutable
  before update or delete on public.retention_campaign_grants
  for each row execute function app.retention_campaign_child_immutable_guard();
create trigger trg_retention_campaign_returns_immutable
  before update or delete on public.retention_campaign_returns
  for each row execute function app.retention_campaign_child_immutable_guard();

-- ---------------------------------------------------------------------------
-- 7. Owner-only lifecycle RPCs.
-- ---------------------------------------------------------------------------
create or replace function public.create_retention_campaign(
  p_business uuid,
  p_program_version_id uuid,
  p_name text,
  p_audience_criteria jsonb,
  p_holdout_percent integer default 10,
  p_budget_cap_cents bigint default 0,
  p_attribution_window_days integer default 30,
  p_expected_cost_cents bigint default null,
  p_expected_upside_cents bigint default null,
  p_explanation text default null
)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_rule public.retention_program_versions%rowtype;
  v_campaign_id uuid := gen_random_uuid();
  v_name text := btrim(coalesce(p_name, ''));
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  perform 1 from public.businesses where id = p_business for share;
  if char_length(v_name) not between 1 and 120 then
    raise exception 'campaign name must be 1..120 characters' using errcode = '22023';
  end if;
  if p_audience_criteria is null or jsonb_typeof(p_audience_criteria) <> 'object' then
    raise exception 'audience criteria must be a JSON object' using errcode = '22023';
  end if;
  if coalesce(p_holdout_percent, -1) not between 0 and 90 then
    raise exception 'holdout percent must be between 0 and 90' using errcode = '22023';
  end if;
  if coalesce(p_budget_cap_cents, 0) < 0 then
    raise exception 'budget cap cannot be negative' using errcode = '22023';
  end if;
  if coalesce(p_attribution_window_days, 0) not between 1 and 365 then
    raise exception 'attribution window must be between 1 and 365 days' using errcode = '22023';
  end if;
  if p_explanation is not null and char_length(p_explanation) > 4000 then
    raise exception 'explanation is limited to 4000 characters' using errcode = '22023';
  end if;
  select * into v_rule from public.retention_program_versions
   where id = p_program_version_id and business_id = p_business;
  if not found then
    raise exception 'retention program version does not belong to this business' using errcode = '22023';
  end if;

  insert into public.retention_campaigns(
    id, business_id, retention_program_version_id, program_id, config_version_id,
    name, audience_criteria, holdout_percent, budget_cap_cents,
    expected_cost_cents, expected_upside_cents, attribution_window_days,
    explanation, status, created_by
  ) values (
    v_campaign_id, p_business, v_rule.id, v_rule.program_id, v_rule.config_version_id,
    v_name, p_audience_criteria, coalesce(p_holdout_percent, 10), coalesce(p_budget_cap_cents, 0),
    p_expected_cost_cents, p_expected_upside_cents, coalesce(p_attribution_window_days, 30),
    nullif(btrim(coalesce(p_explanation, '')), ''), 'draft', v_actor
  );
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'CREATE_RETENTION_CAMPAIGN', 'retention_campaigns', v_campaign_id,
    jsonb_build_object('retention_program_version_id', v_rule.id, 'holdout_percent', coalesce(p_holdout_percent, 10)));
  return json_build_object(
    'campaign_id', v_campaign_id, 'status', 'draft',
    'retention_program_version_id', v_rule.id, 'holdout_percent', coalesce(p_holdout_percent, 10),
    'attribution_window_days', coalesce(p_attribution_window_days, 30)
  );
end $$;
revoke all privileges on function public.create_retention_campaign(uuid, uuid, text, jsonb, integer, bigint, integer, bigint, bigint, text)
  from public, anon;
grant execute on function public.create_retention_campaign(uuid, uuid, text, jsonb, integer, bigint, integer, bigint, bigint, text)
  to authenticated;

create or replace function public.activate_retention_campaign(
  p_business uuid,
  p_campaign uuid,
  p_client_ids uuid[],
  p_idempotency_key text
)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_campaign public.retention_campaigns%rowtype;
  v_requested integer;
  v_inserted integer;
  v_treatment integer;
  v_holdout integer;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('v50:activate:' || p_campaign::text, 0));
  select * into v_campaign from public.retention_campaigns
   where id = p_campaign and business_id = p_business for update;
  if not found then raise exception 'campaign not found in this business'; end if;

  if v_campaign.status = 'active' then
    select count(*) filter (where assignment = 'treatment'),
           count(*) filter (where assignment = 'holdout')
      into v_treatment, v_holdout
      from public.retention_campaign_members
     where campaign_id = p_campaign and business_id = p_business;
    return json_build_object('campaign_id', p_campaign, 'status', 'active',
      'audience_size', v_campaign.audience_size, 'treatment', v_treatment, 'holdout', v_holdout,
      'replayed', true);
  end if;
  if v_campaign.status <> 'draft' then
    raise exception 'only a draft campaign can be activated' using errcode = '42501';
  end if;
  if p_client_ids is null or array_length(p_client_ids, 1) is null then
    raise exception 'a non-empty audience is required to activate a campaign' using errcode = '22023';
  end if;
  select count(*) into v_requested from (select distinct unnest(p_client_ids) cid) u where u.cid is not null;
  if v_requested = 0 then
    raise exception 'a non-empty audience is required to activate a campaign' using errcode = '22023';
  end if;
  if v_requested > 50000 then
    raise exception 'campaign audience is limited to 50000 members' using errcode = '22023';
  end if;

  insert into public.retention_campaign_members(
    campaign_id, business_id, client_id, assignment, assignment_bucket
  )
  select p_campaign, p_business, c.id,
         case when app.campaign_holdout_bucket(p_campaign, c.id) < v_campaign.holdout_percent
              then 'holdout' else 'treatment' end,
         app.campaign_holdout_bucket(p_campaign, c.id)
    from (select distinct unnest(p_client_ids) cid) u
    join public.clients c on c.id = u.cid and c.business_id = p_business;
  get diagnostics v_inserted = row_count;
  if v_inserted <> v_requested then
    raise exception 'some audience clients do not belong to this business' using errcode = '42501';
  end if;

  select count(*) filter (where assignment = 'treatment'),
         count(*) filter (where assignment = 'holdout')
    into v_treatment, v_holdout
    from public.retention_campaign_members
   where campaign_id = p_campaign and business_id = p_business;

  update public.retention_campaigns
     set status = 'active', activated_at = now(), audience_size = v_inserted
   where id = p_campaign and business_id = p_business;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'ACTIVATE_RETENTION_CAMPAIGN', 'retention_campaigns', p_campaign,
    jsonb_build_object('audience_size', v_inserted, 'treatment', v_treatment, 'holdout', v_holdout));
  return json_build_object('campaign_id', p_campaign, 'status', 'active',
    'audience_size', v_inserted, 'treatment', v_treatment, 'holdout', v_holdout, 'replayed', false);
end $$;
revoke all privileges on function public.activate_retention_campaign(uuid, uuid, uuid[], text)
  from public, anon;
grant execute on function public.activate_retention_campaign(uuid, uuid, uuid[], text) to authenticated;

create or replace function public.issue_campaign_offer(
  p_business uuid,
  p_campaign uuid,
  p_client uuid,
  p_idempotency_key text,
  p_offer_cost_cents bigint default null,
  p_reward_grant_id uuid default null
)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_campaign public.retention_campaigns%rowtype;
  v_rule public.retention_program_versions%rowtype;
  v_assignment text;
  v_existing public.retention_campaign_grants%rowtype;
  v_offer_cost bigint;
  v_issued_cost bigint;
  v_grant_id uuid := gen_random_uuid();
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);
  perform pg_advisory_xact_lock(hashtextextended('v50:issue:' || p_business::text || ':' || p_idempotency_key, 0));
  select * into v_campaign from public.retention_campaigns
   where id = p_campaign and business_id = p_business for update;
  if not found then raise exception 'campaign not found in this business'; end if;
  if v_campaign.status <> 'active' then
    raise exception 'offers can only be issued for an active campaign' using errcode = '42501';
  end if;

  -- Idempotency key replay (same request) returns the prior grant; a different
  -- (campaign, client) under the same key is a hard conflict.
  select * into v_existing from public.retention_campaign_grants
   where business_id = p_business and idempotency_key = p_idempotency_key;
  if found then
    if v_existing.campaign_id is distinct from p_campaign or v_existing.client_id is distinct from p_client then
      raise exception 'idempotency key conflicts with another campaign offer' using errcode = '23505';
    end if;
    return json_build_object('campaign_id', p_campaign, 'client_id', p_client,
      'grant_id', v_existing.id, 'offer_cost_cents', v_existing.offer_cost_cents, 'replayed', true);
  end if;
  -- One grant per member per campaign (idempotent even without the request key).
  select * into v_existing from public.retention_campaign_grants
   where campaign_id = p_campaign and client_id = p_client;
  if found then
    return json_build_object('campaign_id', p_campaign, 'client_id', p_client,
      'grant_id', v_existing.id, 'offer_cost_cents', v_existing.offer_cost_cents, 'replayed', true);
  end if;

  select assignment into v_assignment from public.retention_campaign_members
   where campaign_id = p_campaign and client_id = p_client;
  if v_assignment is null then
    raise exception 'client is not part of this campaign audience' using errcode = '22023';
  end if;
  if v_assignment = 'holdout' then
    -- Enforced in the granting path, not merely the UI. The (campaign,client,'treatment')
    -- FK would also reject this row; the explicit check yields a clean authorization error.
    raise exception 'holdout members never receive the campaign offer' using errcode = '42501';
  end if;

  select * into v_rule from public.retention_program_versions
   where id = v_campaign.retention_program_version_id and business_id = p_business;
  if not found then raise exception 'campaign retention rule is missing'; end if;
  v_offer_cost := coalesce(
    p_offer_cost_cents,
    case when v_rule.fulfillment_kind = 'credit' then coalesce(v_rule.credit_cents, 0)::bigint else 0::bigint end
  );
  if v_offer_cost < 0 then raise exception 'offer cost cannot be negative' using errcode = '22023'; end if;

  if v_campaign.budget_cap_cents > 0 then
    select coalesce(sum(offer_cost_cents), 0) into v_issued_cost
      from public.retention_campaign_grants where campaign_id = p_campaign and business_id = p_business;
    if v_issued_cost + v_offer_cost > v_campaign.budget_cap_cents then
      raise exception 'campaign budget cap exceeded' using errcode = 'check_violation';
    end if;
  end if;

  if p_reward_grant_id is not null and not exists (
    select 1 from public.reward_grants g where g.id = p_reward_grant_id and g.business_id = p_business
  ) then
    raise exception 'linked reward grant does not belong to this business' using errcode = '42501';
  end if;

  insert into public.retention_campaign_grants(
    id, campaign_id, business_id, client_id, assignment, reward_grant_id,
    offer_cost_cents, idempotency_key, issued_by
  ) values (
    v_grant_id, p_campaign, p_business, p_client, 'treatment', p_reward_grant_id,
    v_offer_cost, p_idempotency_key, v_actor
  );
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'ISSUE_CAMPAIGN_OFFER', 'retention_campaign_grants', v_grant_id,
    jsonb_build_object('campaign_id', p_campaign, 'client_id', p_client, 'offer_cost_cents', v_offer_cost));
  return json_build_object('campaign_id', p_campaign, 'client_id', p_client,
    'grant_id', v_grant_id, 'offer_cost_cents', v_offer_cost, 'replayed', false);
end $$;
revoke all privileges on function public.issue_campaign_offer(uuid, uuid, uuid, text, bigint, uuid)
  from public, anon;
grant execute on function public.issue_campaign_offer(uuid, uuid, uuid, text, bigint, uuid) to authenticated;

create or replace function public.record_campaign_returns(
  p_business uuid,
  p_campaign uuid
)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_campaign public.retention_campaigns%rowtype;
  v_window_end timestamptz;
  v_recorded integer;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('v50:returns:' || p_campaign::text, 0));
  select * into v_campaign from public.retention_campaigns
   where id = p_campaign and business_id = p_business for update;
  if not found then raise exception 'campaign not found in this business'; end if;
  if v_campaign.status not in ('active', 'completed') then
    raise exception 'returns can only be recorded for an active or completed campaign' using errcode = '42501';
  end if;
  v_window_end := v_campaign.activated_at + make_interval(days => v_campaign.attribution_window_days);

  -- First qualifying return per member, reversal-aware. Existing evidence is kept
  -- (on conflict do nothing) so the earliest recorded attribution is stable.
  insert into public.retention_campaign_returns(
    campaign_id, business_id, client_id, assignment, sale_id, returned_at, recorded_by
  )
  select p_campaign, p_business, m.client_id, m.assignment, first_return.sale_id,
         first_return.occurred_at, v_actor
    from public.retention_campaign_members m
    join lateral (
      select s.id as sale_id, s.occurred_at
        from public.sales s
       where s.business_id = p_business
         and s.client_id = m.client_id
         and s.counts_as_visit
         and s.reversal_of is null
         and s.occurred_at >= v_campaign.activated_at
         and s.occurred_at < v_window_end
         and not exists (
           select 1 from public.sales r
            where r.business_id = s.business_id and r.reversal_of = s.id
         )
       order by s.occurred_at, s.id
       limit 1
    ) first_return on true
   where m.campaign_id = p_campaign and m.business_id = p_business
  on conflict (campaign_id, client_id) do nothing;
  get diagnostics v_recorded = row_count;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'RECORD_CAMPAIGN_RETURNS', 'retention_campaigns', p_campaign,
    jsonb_build_object('newly_recorded', v_recorded));
  return json_build_object('campaign_id', p_campaign, 'newly_recorded', v_recorded);
end $$;
revoke all privileges on function public.record_campaign_returns(uuid, uuid) from public, anon;
grant execute on function public.record_campaign_returns(uuid, uuid) to authenticated;

create or replace function public.complete_retention_campaign(
  p_business uuid,
  p_campaign uuid
)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_actor uuid := auth.uid(); v_campaign public.retention_campaigns%rowtype;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  select * into v_campaign from public.retention_campaigns
   where id = p_campaign and business_id = p_business for update;
  if not found then raise exception 'campaign not found in this business'; end if;
  if v_campaign.status <> 'active' then
    raise exception 'only an active campaign can be completed' using errcode = '42501';
  end if;
  update public.retention_campaigns set status = 'completed', completed_at = now()
   where id = p_campaign and business_id = p_business;
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'COMPLETE_RETENTION_CAMPAIGN', 'retention_campaigns', p_campaign, '{}'::jsonb);
  return json_build_object('campaign_id', p_campaign, 'status', 'completed');
end $$;
revoke all privileges on function public.complete_retention_campaign(uuid, uuid) from public, anon;
grant execute on function public.complete_retention_campaign(uuid, uuid) to authenticated;

create or replace function public.cancel_retention_campaign(
  p_business uuid,
  p_campaign uuid,
  p_reason text default null
)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_actor uuid := auth.uid(); v_campaign public.retention_campaigns%rowtype;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  select * into v_campaign from public.retention_campaigns
   where id = p_campaign and business_id = p_business for update;
  if not found then raise exception 'campaign not found in this business'; end if;
  if v_campaign.status not in ('draft', 'active') then
    raise exception 'only a draft or active campaign can be cancelled' using errcode = '42501';
  end if;
  update public.retention_campaigns set status = 'cancelled', cancelled_at = now()
   where id = p_campaign and business_id = p_business;
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'CANCEL_RETENTION_CAMPAIGN', 'retention_campaigns', p_campaign,
    jsonb_build_object('reason', nullif(btrim(coalesce(p_reason, '')), '')));
  return json_build_object('campaign_id', p_campaign, 'status', 'cancelled');
end $$;
revoke all privileges on function public.cancel_retention_campaign(uuid, uuid, text) from public, anon;
grant execute on function public.cancel_retention_campaign(uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Owner/manager read surfaces (bounded output, v49b authorization style).
--    Return attribution is computed LIVE and reversal-aware here, so the readout is
--    correct even if a recorded return sale is later reversed.
-- ---------------------------------------------------------------------------
create or replace function public.get_campaign_results(p_campaign uuid)
returns json language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_business uuid;
  v_campaign public.retention_campaigns%rowtype;
  v_window_end timestamptz;
  v_t_members integer := 0; v_h_members integer := 0;
  v_t_returned integer := 0; v_h_returned integer := 0;
  v_t_revenue bigint := 0; v_h_revenue bigint := 0;
  v_offers integer := 0; v_grant_cost bigint := 0;
  v_t_rate integer; v_h_rate integer;
  v_incr_returns bigint; v_incr_revenue bigint;
begin
  select business_id into v_business from public.retention_campaigns where id = p_campaign;
  if v_business is null then raise exception 'campaign not found'; end if;
  if auth.uid() is null
     or not app.has_perm(v_business, 'view_finance')
     or not app.can_module_read(v_business, 'retention') then
    raise exception 'active owner or manager retention read authorization is required'
      using errcode = '42501';
  end if;
  select * into v_campaign from public.retention_campaigns where id = p_campaign;
  v_window_end := case when v_campaign.activated_at is null then null
                       else v_campaign.activated_at + make_interval(days => v_campaign.attribution_window_days) end;

  with mem as (
    select m.client_id, m.assignment
      from public.retention_campaign_members m
     where m.campaign_id = p_campaign and m.business_id = v_business
  ),
  judged as (
    select mem.assignment,
      (v_window_end is not null and exists (
        select 1 from public.sales s
         where s.business_id = v_business and s.client_id = mem.client_id
           and s.counts_as_visit and s.reversal_of is null
           and s.occurred_at >= v_campaign.activated_at and s.occurred_at < v_window_end
           and not exists (
             select 1 from public.sales r
              where r.business_id = s.business_id and r.reversal_of = s.id)
      )) as returned,
      -- Reversal-aware: a reversed sale contributes exactly zero (its original is
      -- excluded by the reversal check, the reversal row by reversal_of is null),
      -- so signed reversals cancel regardless of the reversal row's policy flags.
      coalesce((
        select sum(s.amount_cents) from public.sales s
         where s.business_id = v_business and s.client_id = mem.client_id
           and s.counts_as_revenue and s.reversal_of is null
           and v_window_end is not null
           and s.occurred_at >= v_campaign.activated_at and s.occurred_at < v_window_end
           and not exists (
             select 1 from public.sales r
              where r.business_id = s.business_id and r.reversal_of = s.id)
      ), 0)::bigint as revenue_cents
    from mem
  )
  select
    count(*) filter (where assignment = 'treatment'),
    count(*) filter (where assignment = 'holdout'),
    count(*) filter (where assignment = 'treatment' and returned),
    count(*) filter (where assignment = 'holdout' and returned),
    coalesce(sum(revenue_cents) filter (where assignment = 'treatment'), 0),
    coalesce(sum(revenue_cents) filter (where assignment = 'holdout'), 0)
    into v_t_members, v_h_members, v_t_returned, v_h_returned, v_t_revenue, v_h_revenue
    from judged;

  select count(*), coalesce(sum(offer_cost_cents), 0)
    into v_offers, v_grant_cost
    from public.retention_campaign_grants
   where campaign_id = p_campaign and business_id = v_business;

  v_t_rate := case when v_t_members > 0 then (v_t_returned * 10000) / v_t_members else 0 end;
  v_h_rate := case when v_h_members > 0 then (v_h_returned * 10000) / v_h_members else 0 end;
  -- Counterfactual: expected treatment behaviour if it had matched the holdout arm.
  v_incr_returns := case when v_h_members > 0
    then v_t_returned - round(v_t_members::numeric * v_h_returned / v_h_members) else null end;
  v_incr_revenue := case when v_h_members > 0
    then v_t_revenue - round(v_t_members::numeric * v_h_revenue / v_h_members) else null end;

  return json_build_object(
    'campaign_id', p_campaign,
    'business_id', v_business,
    'status', v_campaign.status,
    'holdout_percent', v_campaign.holdout_percent,
    'attribution_window_days', v_campaign.attribution_window_days,
    'activated_at', v_campaign.activated_at,
    'attribution_ends_at', v_window_end,
    'budget_cap_cents', v_campaign.budget_cap_cents,
    'grant_cost_cents', v_grant_cost,
    'treatment', json_build_object(
      'members', v_t_members, 'offers_issued', v_offers,
      'returned', v_t_returned, 'return_rate_bps', v_t_rate, 'revenue_cents', v_t_revenue),
    'holdout', json_build_object(
      'members', v_h_members, 'returned', v_h_returned,
      'return_rate_bps', v_h_rate, 'revenue_cents', v_h_revenue),
    'net_lift_bps', v_t_rate - v_h_rate,
    'incremental_returns', v_incr_returns,
    'incremental_revenue_cents', v_incr_revenue
  );
end $$;
revoke all privileges on function public.get_campaign_results(uuid) from public, anon;
grant execute on function public.get_campaign_results(uuid) to authenticated;

create or replace function public.list_retention_campaigns(p_business uuid)
returns json language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_result json;
begin
  if auth.uid() is null
     or not app.has_perm(p_business, 'view_finance')
     or not app.can_module_read(p_business, 'retention') then
    raise exception 'active owner or manager retention read authorization is required'
      using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(c.obj order by c.created_at desc), '[]'::jsonb)::json
    into v_result
    from (
      select rc.created_at,
        jsonb_build_object(
          'campaign_id', rc.id,
          'name', rc.name,
          'status', rc.status,
          'holdout_percent', rc.holdout_percent,
          'audience_size', rc.audience_size,
          'budget_cap_cents', rc.budget_cap_cents,
          'expected_cost_cents', rc.expected_cost_cents,
          'expected_upside_cents', rc.expected_upside_cents,
          'attribution_window_days', rc.attribution_window_days,
          'retention_program_version_id', rc.retention_program_version_id,
          'offers_issued', (
            select count(*) from public.retention_campaign_grants g
             where g.campaign_id = rc.id and g.business_id = rc.business_id),
          'created_at', rc.created_at,
          'activated_at', rc.activated_at
        ) as obj
      from public.retention_campaigns rc
      where rc.business_id = p_business
      order by rc.created_at desc
      limit 500
    ) c;
  return v_result;
end $$;
revoke all privileges on function public.list_retention_campaigns(uuid) from public, anon;
grant execute on function public.list_retention_campaigns(uuid) to authenticated;

commit;
