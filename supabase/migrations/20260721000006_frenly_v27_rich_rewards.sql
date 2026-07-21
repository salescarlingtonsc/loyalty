-- FRENLY v27 - RICH, VERSIONED REWARD CATALOGS
--
-- Catalog rows remain stable reward identities. Their merchant-editable terms live in
-- loyalty_reward_versions, keyed to the immutable v26 configuration version. The legacy
-- loyalty_rewards columns are a published compatibility projection for the existing SPA.
--
-- Credit and manual-item fulfilment are the two existing append-only routes. Labels may be flexible; money behaviour may not be invented by
-- a label. Branch, service, and product eligibility is deliberately relational and tenant
-- constrained by composite foreign keys.

begin;

-- Stable catalog identities receive the fields needed by the old client while versioned rows
-- below become the configuration source of truth.
alter table public.loyalty_rewards
  add column internal_name text,
  add column customer_name text,
  add column description text,
  add column fulfillment_kind text,
  add column taxonomy_label text,
  add column instructions text,
  add column terms text,
  add column image_ref text,
  add column estimated_cost_cents integer,
  add column claim_available_from timestamptz,
  add column claim_available_until timestamptz,
  add column entitlement_expiry_days integer,
  add column usage_limit integer,
  add column current_config_version_id uuid;

update public.loyalty_rewards r
   set internal_name = r.name,
       customer_name = r.name,
       fulfillment_kind = case when r.credit_cents > 0 then 'credit' else 'manual_item' end,
       estimated_cost_cents = r.credit_cents;

-- A catalog row can predate a loyalty-program row. Required compatibility fields must be
-- initialized for every row; only the optional version pointer depends on a program existing.
update public.loyalty_rewards r
   set current_config_version_id = lp.current_config_version_id
  from public.loyalty_programs lp
 where lp.business_id = r.business_id;

alter table public.loyalty_rewards
  alter column internal_name set not null,
  alter column customer_name set not null,
  alter column fulfillment_kind set not null,
  alter column estimated_cost_cents set not null;
alter table public.loyalty_rewards
  add constraint loyalty_rewards_id_business_uk unique (id, business_id),
  add constraint loyalty_rewards_internal_name_check
    check (length(btrim(internal_name)) between 1 and 120),
  add constraint loyalty_rewards_customer_name_check
    check (length(btrim(customer_name)) between 1 and 120),
  add constraint loyalty_rewards_fulfillment_kind_check
    check (fulfillment_kind in ('credit','manual_item')),
  add constraint loyalty_rewards_fulfillment_amount_check
    check ((fulfillment_kind = 'credit' and credit_cents > 0)
           or (fulfillment_kind = 'manual_item' and credit_cents = 0)),
  add constraint loyalty_rewards_description_check
    check (description is null or length(description) <= 2000),
  add constraint loyalty_rewards_instructions_check
    check (instructions is null or length(instructions) <= 4000),
  add constraint loyalty_rewards_terms_check
    check (terms is null or length(terms) <= 4000),
  add constraint loyalty_rewards_taxonomy_label_check
    check (taxonomy_label is null or length(btrim(taxonomy_label)) between 1 and 80),
  add constraint loyalty_rewards_image_ref_check
    check (
      image_ref is null
      or image_ref ~ '^[a-z0-9][a-z0-9/_-]{0,247}\.(png|jpg|jpeg|webp)$'
      or image_ref ~ '^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~:/?#\[\]@!$&''()*+,;=%-]*)?$'
    ),
  add constraint loyalty_rewards_estimated_cost_check
    check (estimated_cost_cents >= 0),
  add constraint loyalty_rewards_claim_window_check
    check (claim_available_until is null or claim_available_from is null
           or claim_available_until > claim_available_from),
  add constraint loyalty_rewards_entitlement_expiry_check
    check (entitlement_expiry_days is null or entitlement_expiry_days > 0),
  add constraint loyalty_rewards_usage_limit_check
    check (usage_limit is null or usage_limit > 0),
  add constraint loyalty_rewards_current_config_business_fk
    foreign key (current_config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict;

comment on column public.loyalty_rewards.entitlement_expiry_days is
  'Firm-visible claim validity. Its value is snapshotted on redemption; expiry enforcement for held benefits requires a future entitlement state machine.';
comment on column public.loyalty_rewards.image_ref is
  'Validated relative Storage key or HTTPS image URL. Data URLs and executable schemes are rejected.';

create table public.loyalty_reward_versions (
  id uuid primary key default gen_random_uuid(),
  reward_id uuid not null,
  business_id uuid not null references public.businesses(id) on delete cascade,
  config_version_id uuid not null,
  internal_name text not null check (length(btrim(internal_name)) between 1 and 120),
  customer_name text not null check (length(btrim(customer_name)) between 1 and 120),
  description text check (description is null or length(description) <= 2000),
  fulfillment_kind text not null check (fulfillment_kind in ('credit','manual_item')),
  taxonomy_label text check (taxonomy_label is null or length(btrim(taxonomy_label)) between 1 and 80),
  cost_points integer not null check (cost_points > 0),
  credit_cents integer not null check (credit_cents >= 0),
  estimated_cost_cents integer not null check (estimated_cost_cents >= 0),
  active boolean not null default true,
  sort integer not null default 0,
  claim_available_from timestamptz,
  claim_available_until timestamptz,
  entitlement_expiry_days integer check (entitlement_expiry_days is null or entitlement_expiry_days > 0),
  instructions text check (instructions is null or length(instructions) <= 4000),
  terms text check (terms is null or length(terms) <= 4000),
  image_ref text check (
    image_ref is null
    or image_ref ~ '^[a-z0-9][a-z0-9/_-]{0,247}\.(png|jpg|jpeg|webp)$'
    or image_ref ~ '^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~:/?#\[\]@!$&''()*+,;=%-]*)?$'
  ),
  usage_limit integer check (usage_limit is null or usage_limit > 0),
  created_at timestamptz not null default now(),
  constraint loyalty_reward_versions_reward_business_fk
    foreign key (reward_id, business_id)
    references public.loyalty_rewards(id, business_id) on delete restrict,
  constraint loyalty_reward_versions_config_business_fk
    foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict,
  constraint loyalty_reward_versions_reward_config_uk unique (reward_id, config_version_id),
  constraint loyalty_reward_versions_id_business_uk unique (id, business_id),
  constraint loyalty_reward_versions_id_reward_business_uk unique (id, reward_id, business_id),
  constraint loyalty_reward_versions_claim_window_check
    check (claim_available_until is null or claim_available_from is null
           or claim_available_until > claim_available_from),
  constraint loyalty_reward_versions_fulfillment_amount_check
    check ((fulfillment_kind = 'credit' and credit_cents > 0)
           or (fulfillment_kind = 'manual_item' and credit_cents = 0))
);
create index loyalty_reward_versions_config_idx
  on public.loyalty_reward_versions (business_id, config_version_id, active, sort);

insert into public.loyalty_reward_versions (
  reward_id, business_id, config_version_id, internal_name, customer_name,
  description, fulfillment_kind, taxonomy_label, cost_points, credit_cents,
  estimated_cost_cents, active, sort, claim_available_from, claim_available_until,
  entitlement_expiry_days, instructions, terms, image_ref, usage_limit
)
select r.id, r.business_id, r.current_config_version_id, r.internal_name, r.customer_name,
       r.description, r.fulfillment_kind, r.taxonomy_label, r.cost_points,
       r.credit_cents, r.estimated_cost_cents, r.active, r.sort, r.claim_available_from,
       r.claim_available_until, r.entitlement_expiry_days, r.instructions, r.terms,
       r.image_ref, r.usage_limit
  from public.loyalty_rewards r
 where r.current_config_version_id is not null;

create table public.loyalty_reward_branches (
  reward_version_id uuid not null,
  reward_id uuid not null,
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id uuid not null,
  primary key (reward_version_id, branch_id),
  foreign key (reward_version_id, reward_id, business_id)
    references public.loyalty_reward_versions(id, reward_id, business_id) on delete cascade,
  foreign key (branch_id, business_id)
    references public.branches(id, business_id) on delete restrict
);
create index loyalty_reward_branches_business_idx
  on public.loyalty_reward_branches (business_id, branch_id);

create table public.loyalty_reward_services (
  reward_version_id uuid not null,
  reward_id uuid not null,
  business_id uuid not null references public.businesses(id) on delete cascade,
  service_id uuid not null,
  primary key (reward_version_id, service_id),
  foreign key (reward_version_id, reward_id, business_id)
    references public.loyalty_reward_versions(id, reward_id, business_id) on delete cascade,
  foreign key (service_id, business_id)
    references public.services(id, business_id) on delete restrict
);
create index loyalty_reward_services_business_idx
  on public.loyalty_reward_services (business_id, service_id);

-- Products predate v11a's tenant-safe composite key sweep. Eligibility uses a
-- same-business foreign key, so establish the matching parent key before the
-- first product eligibility table is created.
alter table public.products
  add constraint products_id_business_uk unique (id, business_id);

create table public.loyalty_reward_products (
  reward_version_id uuid not null,
  reward_id uuid not null,
  business_id uuid not null references public.businesses(id) on delete cascade,
  product_id uuid not null,
  primary key (reward_version_id, product_id),
  foreign key (reward_version_id, reward_id, business_id)
    references public.loyalty_reward_versions(id, reward_id, business_id) on delete cascade,
  foreign key (product_id, business_id)
    references public.products(id, business_id) on delete restrict
);
create index loyalty_reward_products_business_idx
  on public.loyalty_reward_products (business_id, product_id);

-- All new public tables are read-only to members; mutations run through the owner-only draft RPC.
alter table public.loyalty_reward_versions enable row level security;
alter table public.loyalty_reward_branches enable row level security;
alter table public.loyalty_reward_services enable row level security;
alter table public.loyalty_reward_products enable row level security;

create policy loyalty_reward_versions_read on public.loyalty_reward_versions for select to authenticated
  using (app.is_salon_member(business_id));
create policy loyalty_reward_versions_sa_read on public.loyalty_reward_versions for select to authenticated
  using (app.is_super_admin());
create policy loyalty_reward_branches_read on public.loyalty_reward_branches for select to authenticated
  using (app.is_salon_member(loyalty_reward_branches.business_id) and exists (
    select 1 from public.loyalty_reward_versions rv join public.businesses b on b.active_config_version_id=rv.config_version_id
     where rv.id=loyalty_reward_branches.reward_version_id
       and rv.reward_id=loyalty_reward_branches.reward_id
       and rv.business_id=loyalty_reward_branches.business_id
  ));
create policy loyalty_reward_branches_sa_read on public.loyalty_reward_branches for select to authenticated
  using (app.is_super_admin());
create policy loyalty_reward_services_read on public.loyalty_reward_services for select to authenticated
  using (app.is_salon_member(loyalty_reward_services.business_id) and exists (
    select 1 from public.loyalty_reward_versions rv join public.businesses b on b.active_config_version_id=rv.config_version_id
     where rv.id=loyalty_reward_services.reward_version_id
       and rv.reward_id=loyalty_reward_services.reward_id
       and rv.business_id=loyalty_reward_services.business_id
  ));
create policy loyalty_reward_services_sa_read on public.loyalty_reward_services for select to authenticated
  using (app.is_super_admin());
create policy loyalty_reward_products_read on public.loyalty_reward_products for select to authenticated
  using (app.is_salon_member(loyalty_reward_products.business_id) and exists (
    select 1 from public.loyalty_reward_versions rv join public.businesses b on b.active_config_version_id=rv.config_version_id
     where rv.id=loyalty_reward_products.reward_version_id
       and rv.reward_id=loyalty_reward_products.reward_id
       and rv.business_id=loyalty_reward_products.business_id
  ));
create policy loyalty_reward_products_sa_read on public.loyalty_reward_products for select to authenticated
  using (app.is_super_admin());

revoke all on public.loyalty_rewards from public, anon, authenticated;
grant select on public.loyalty_rewards to authenticated;
revoke all on public.loyalty_reward_versions from public, anon, authenticated;
grant select on public.loyalty_reward_versions to authenticated;
revoke all on public.loyalty_reward_branches from public, anon, authenticated;
grant select on public.loyalty_reward_branches to authenticated;
revoke all on public.loyalty_reward_services from public, anon, authenticated;
grant select on public.loyalty_reward_services to authenticated;
revoke all on public.loyalty_reward_products from public, anon, authenticated;
grant select on public.loyalty_reward_products to authenticated;

-- Reward configuration is cloned with each v26 draft. This copies values, never mutations of a
-- published version, and keeps historical catalogue rows addressable by their original version.
create or replace function app.clone_reward_versions_for_config()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.based_on_version_id is null then return new; end if;
  insert into public.loyalty_reward_versions (
    reward_id, business_id, config_version_id, internal_name, customer_name,
    description, fulfillment_kind, taxonomy_label, cost_points, credit_cents,
    estimated_cost_cents, active, sort, claim_available_from, claim_available_until,
    entitlement_expiry_days, instructions, terms, image_ref, usage_limit
  )
  select reward_id, business_id, new.id, internal_name, customer_name, description,
         fulfillment_kind, taxonomy_label, cost_points, credit_cents, estimated_cost_cents,
         active, sort, claim_available_from, claim_available_until, entitlement_expiry_days,
         instructions, terms, image_ref, usage_limit
    from public.loyalty_reward_versions
   where config_version_id = new.based_on_version_id and business_id = new.business_id;

  insert into public.loyalty_reward_branches (reward_version_id, reward_id, business_id, branch_id)
  select next_rv.id, next_rv.reward_id, old_e.business_id, old_e.branch_id
    from public.loyalty_reward_versions old_rv
    join public.loyalty_reward_branches old_e on old_e.reward_version_id = old_rv.id
    join public.loyalty_reward_versions next_rv
      on next_rv.config_version_id = new.id and next_rv.reward_id = old_rv.reward_id
   where old_rv.config_version_id = new.based_on_version_id;

  insert into public.loyalty_reward_services (reward_version_id, reward_id, business_id, service_id)
  select next_rv.id, next_rv.reward_id, old_e.business_id, old_e.service_id
    from public.loyalty_reward_versions old_rv
    join public.loyalty_reward_services old_e on old_e.reward_version_id = old_rv.id
    join public.loyalty_reward_versions next_rv
      on next_rv.config_version_id = new.id and next_rv.reward_id = old_rv.reward_id
   where old_rv.config_version_id = new.based_on_version_id;

  insert into public.loyalty_reward_products (reward_version_id, reward_id, business_id, product_id)
  select next_rv.id, next_rv.reward_id, old_e.business_id, old_e.product_id
    from public.loyalty_reward_versions old_rv
    join public.loyalty_reward_products old_e on old_e.reward_version_id = old_rv.id
    join public.loyalty_reward_versions next_rv
      on next_rv.config_version_id = new.id and next_rv.reward_id = old_rv.reward_id
   where old_rv.config_version_id = new.based_on_version_id;
  return new;
end $$;
revoke execute on function app.clone_reward_versions_for_config() from public, anon, authenticated;

create trigger trg_clone_reward_versions_for_config
  after insert on public.firm_config_versions
  for each row execute function app.clone_reward_versions_for_config();

create or replace function app.reward_version_immutable_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_config uuid; v_reward_version uuid; v_status text;
begin
  if tg_table_name = 'loyalty_reward_versions' then
    v_config := coalesce(new.config_version_id, old.config_version_id);
  else
    v_reward_version := coalesce(new.reward_version_id, old.reward_version_id);
    select config_version_id into v_config from public.loyalty_reward_versions where id = v_reward_version;
  end if;
  select status into v_status from public.firm_config_versions where id = v_config;
  if v_status is distinct from 'draft' then
    raise exception 'published reward configuration is immutable' using errcode = 'restrict_violation';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
revoke execute on function app.reward_version_immutable_guard() from public, anon, authenticated;

create trigger trg_loyalty_reward_versions_immutable
  before update or delete on public.loyalty_reward_versions
  for each row execute function app.reward_version_immutable_guard();
create trigger trg_loyalty_reward_branches_immutable
  before update or delete on public.loyalty_reward_branches
  for each row execute function app.reward_version_immutable_guard();
create trigger trg_loyalty_reward_services_immutable
  before update or delete on public.loyalty_reward_services
  for each row execute function app.reward_version_immutable_guard();
create trigger trg_loyalty_reward_products_immutable
  before update or delete on public.loyalty_reward_products
  for each row execute function app.reward_version_immutable_guard();

-- The complete program plus reward tree is hashed for publication audit. This replaces v26's
-- program-only hash whenever a v27 row changes.
create or replace function app.refresh_loyalty_config_snapshot(p_version uuid)
returns void language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_snapshot jsonb;
begin
  select jsonb_build_object(
    'program', (select to_jsonb(lp) - 'config_version_id' from public.loyalty_program_versions lp
                where lp.config_version_id = p_version),
    'tiers', coalesce((
      select jsonb_agg(to_jsonb(tv)-'id'-'config_version_id'-'business_id'-'created_at'
                       order by tv.threshold,tv.sort,tv.tier_id)
        from public.loyalty_tier_versions tv where tv.config_version_id=p_version
    ),'[]'::jsonb),
    'rewards', coalesce((
      select jsonb_agg(jsonb_build_object(
        'reward', to_jsonb(rv) - 'id' - 'config_version_id' - 'business_id' - 'created_at',
        'branches', coalesce((select jsonb_agg(e.branch_id order by e.branch_id)
                              from public.loyalty_reward_branches e
                              where e.reward_version_id = rv.id), '[]'::jsonb),
        'services', coalesce((select jsonb_agg(e.service_id order by e.service_id)
                              from public.loyalty_reward_services e
                              where e.reward_version_id = rv.id), '[]'::jsonb),
        'products', coalesce((select jsonb_agg(e.product_id order by e.product_id)
                              from public.loyalty_reward_products e
                              where e.reward_version_id = rv.id), '[]'::jsonb)
      ) order by rv.reward_id)
      from public.loyalty_reward_versions rv where rv.config_version_id = p_version
    ), '[]'::jsonb)
  ) into v_snapshot;
  update public.firm_config_versions set snapshot_hash = md5(v_snapshot::text) where id = p_version;
end $$;
revoke execute on function app.refresh_loyalty_config_snapshot(uuid) from public, anon, authenticated;

create or replace function app.refresh_loyalty_tier_snapshot_trigger()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  perform app.refresh_loyalty_config_snapshot(
    case when tg_op='DELETE' then old.config_version_id else new.config_version_id end
  );
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
revoke execute on function app.refresh_loyalty_tier_snapshot_trigger() from public,anon,authenticated;
create trigger trg_loyalty_tier_versions_snapshot after insert or update or delete
  on public.loyalty_tier_versions for each row execute function app.refresh_loyalty_tier_snapshot_trigger();

do $refresh_existing_configs$
declare v_id uuid;
begin
  for v_id in select id from public.firm_config_versions loop
    perform app.refresh_loyalty_config_snapshot(v_id);
  end loop;
end $refresh_existing_configs$;

create or replace function app.refresh_loyalty_config_snapshot_trigger()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row jsonb;
  v_reward_version uuid;
  v_config uuid;
begin
  v_row := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  if tg_table_name = 'loyalty_reward_versions' then
    v_config := nullif(v_row ->> 'config_version_id', '')::uuid;
  else
    v_reward_version := nullif(v_row ->> 'reward_version_id', '')::uuid;
    select config_version_id into v_config from public.loyalty_reward_versions where id = v_reward_version;
  end if;
  if v_config is not null then perform app.refresh_loyalty_config_snapshot(v_config); end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
revoke execute on function app.refresh_loyalty_config_snapshot_trigger() from public, anon, authenticated;

create trigger trg_loyalty_reward_versions_snapshot
  after insert or update or delete on public.loyalty_reward_versions
  for each row execute function app.refresh_loyalty_config_snapshot_trigger();
create trigger trg_loyalty_reward_branches_snapshot
  after insert or update or delete on public.loyalty_reward_branches
  for each row execute function app.refresh_loyalty_config_snapshot_trigger();
create trigger trg_loyalty_reward_services_snapshot
  after insert or update or delete on public.loyalty_reward_services
  for each row execute function app.refresh_loyalty_config_snapshot_trigger();
create trigger trg_loyalty_reward_products_snapshot
  after insert or update or delete on public.loyalty_reward_products
  for each row execute function app.refresh_loyalty_config_snapshot_trigger();

-- Existing financial records are preserved and receive the best available historical snapshots.
alter table public.loyalty_redemptions
  add column reward_version_id uuid,
  add column reward_snapshot jsonb,
  add column eligibility_snapshot jsonb,
  add column fulfillment_kind text,
  add column entitlement_expires_at timestamptz,
  add column usage_number integer;
alter table public.loyalty_redemptions
  add constraint loyalty_redemptions_reward_version_business_fk
    foreign key (reward_version_id, business_id)
    references public.loyalty_reward_versions(id, business_id) on delete restrict,
  add constraint loyalty_redemptions_snapshot_shape_check
    check (reward_snapshot is null or jsonb_typeof(reward_snapshot) = 'object'),
  add constraint loyalty_redemptions_eligibility_snapshot_shape_check
    check (eligibility_snapshot is null or jsonb_typeof(eligibility_snapshot) = 'object'),
  add constraint loyalty_redemptions_fulfillment_kind_check
    check (fulfillment_kind is null or fulfillment_kind in ('credit','manual_item')),
  add constraint loyalty_redemptions_usage_number_check
    check (usage_number is null or usage_number > 0);
create index loyalty_redemptions_reward_usage_idx
  on public.loyalty_redemptions (business_id, client_id, reward_id, redeemed_at);

update public.loyalty_redemptions x
   set reward_snapshot = jsonb_build_object(
         'legacy', true, 'name', x.reward_name, 'cost_points', x.points_spent,
         'credit_cents', x.credit_cents
       ),
       eligibility_snapshot = jsonb_build_object('legacy', true, 'scope', 'unrecorded'),
       fulfillment_kind = case when x.credit_cents > 0 then 'credit' else 'manual_item' end
 where x.reward_snapshot is null;

alter table public.reward_grants add column reward_snapshot jsonb;
alter table public.reward_grants
  add constraint reward_grants_snapshot_shape_check
  check (reward_snapshot is null or jsonb_typeof(reward_snapshot) = 'object');
update public.reward_grants g
   set reward_snapshot = jsonb_build_object(
     'legacy', true, 'reward_type', g.reward_type, 'reward_value', g.reward_value,
     'reward_item', g.reward_item, 'config_version_id', g.config_version_id
   )
 where g.reward_snapshot is null;

create or replace function app.reward_grant_snapshot_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'INSERT' then
    if new.reward_snapshot is null then
      new.reward_snapshot := jsonb_build_object(
        'legacy', false, 'reward_type', new.reward_type, 'reward_value', new.reward_value,
        'reward_item', new.reward_item, 'config_version_id', new.config_version_id
      );
    end if;
    return new;
  end if;
  if new.reward_snapshot is distinct from old.reward_snapshot
     or new.reward_type is distinct from old.reward_type
     or new.reward_value is distinct from old.reward_value
     or new.reward_item is distinct from old.reward_item
     or new.config_version_id is distinct from old.config_version_id then
    raise exception 'reward grant economics and snapshot are immutable' using errcode = 'restrict_violation';
  end if;
  return new;
end $$;
revoke execute on function app.reward_grant_snapshot_guard() from public, anon, authenticated;
create trigger trg_z_reward_grant_snapshot_guard
  before insert or update on public.reward_grants
  for each row execute function app.reward_grant_snapshot_guard();

create or replace function app.loyalty_redemption_immutable_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'loyalty redemptions are append-only' using errcode = 'restrict_violation';
end $$;
revoke execute on function app.loyalty_redemption_immutable_guard() from public, anon, authenticated;
create trigger trg_loyalty_redemptions_immutable
  before update or delete on public.loyalty_redemptions
  for each row execute function app.loyalty_redemption_immutable_guard();

-- Owner-only catalog editor. It only changes a v26 draft and replaces the complete eligibility
-- set in one transaction. A missing eligibility array means unrestricted, never an unvalidated
-- UUID array stored on the reward itself.
create or replace function public.save_loyalty_reward_draft(
  p_config_version uuid,
  p_reward_id uuid,
  p_reward jsonb,
  p_eligibility jsonb default '{}'::jsonb
)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_header public.firm_config_versions%rowtype;
  v_existing public.loyalty_reward_versions%rowtype;
  v_reward_id uuid := coalesce(p_reward_id, gen_random_uuid());
  v_version_id uuid;
  v_key text;
  v_internal_name text;
  v_customer_name text;
  v_description text;
  v_kind text;
  v_taxonomy text;
  v_cost integer;
  v_credit integer;
  v_estimated integer;
  v_active boolean;
  v_sort integer;
  v_claim_from timestamptz;
  v_claim_until timestamptz;
  v_entitlement_days integer;
  v_instructions text;
  v_terms text;
  v_image text;
  v_limit integer;
begin
  if p_reward is null or jsonb_typeof(p_reward) <> 'object' then
    raise exception 'reward must be a JSON object' using errcode = '22023';
  end if;
  if p_eligibility is null or jsonb_typeof(p_eligibility) <> 'object' then
    raise exception 'eligibility must be a JSON object' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_object_keys(p_reward) k
     where k not in (
       'id','business_id','name','internal_name','customer_name','description','fulfillment_kind','taxonomy_label',
       'cost_points','credit_cents','estimated_cost_cents','active','sort',
       'claim_available_from','claim_available_until','entitlement_expiry_days',
       'instructions','terms','image_ref','usage_limit'
     )
  ) then raise exception 'reward contains unsupported fields' using errcode = '22023'; end if;
  if exists (select 1 from jsonb_object_keys(p_eligibility) k where k not in ('branches','services','products')) then
    raise exception 'eligibility contains unsupported fields' using errcode = '22023';
  end if;
  if jsonb_typeof(coalesce(p_eligibility->'branches','[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_eligibility->'services','[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_eligibility->'products','[]'::jsonb)) <> 'array' then
    raise exception 'each eligibility value must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(coalesce(p_eligibility->'branches','[]'::jsonb)) > 500
     or jsonb_array_length(coalesce(p_eligibility->'services','[]'::jsonb)) > 500
     or jsonb_array_length(coalesce(p_eligibility->'products','[]'::jsonb)) > 500 then
    raise exception 'eligibility arrays may contain at most 500 items' using errcode = '22023';
  end if;

  select * into v_header from public.firm_config_versions where id = p_config_version for update;
  if not found or not app.is_salon_owner(v_header.business_id) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if v_header.status <> 'draft' then raise exception 'only a draft reward configuration may be edited'; end if;
  if p_reward ? 'business_id' and (p_reward->>'business_id')::uuid is distinct from v_header.business_id then
    raise exception 'reward business does not match configuration business' using errcode = '42501';
  end if;
  if p_reward_id is not null and not exists (
    select 1 from public.loyalty_rewards where id = p_reward_id and business_id = v_header.business_id
  ) then raise exception 'reward does not belong to this business' using errcode = '42501'; end if;

  select * into v_existing from public.loyalty_reward_versions
   where reward_id = v_reward_id and config_version_id = p_config_version for update;

  v_internal_name := coalesce(nullif(btrim(p_reward->>'internal_name'),''), nullif(btrim(p_reward->>'name'),''), v_existing.internal_name);
  v_customer_name := coalesce(nullif(btrim(p_reward->>'customer_name'),''), v_existing.customer_name);
  v_description := case when p_reward ? 'description' then nullif(p_reward->>'description','') else v_existing.description end;
  v_kind := coalesce(p_reward->>'fulfillment_kind', v_existing.fulfillment_kind, 'credit');
  v_taxonomy := case when p_reward ? 'taxonomy_label' then nullif(btrim(p_reward->>'taxonomy_label'),'') else v_existing.taxonomy_label end;
  v_cost := coalesce((p_reward->>'cost_points')::integer, v_existing.cost_points);
  v_credit := coalesce((p_reward->>'credit_cents')::integer, v_existing.credit_cents, 0);
  v_estimated := coalesce((p_reward->>'estimated_cost_cents')::integer, v_existing.estimated_cost_cents, v_credit);
  v_active := case when p_reward ? 'active' then (p_reward->>'active')::boolean else coalesce(v_existing.active, true) end;
  v_sort := coalesce((p_reward->>'sort')::integer, v_existing.sort, 0);
  v_claim_from := case when p_reward ? 'claim_available_from' then nullif(p_reward->>'claim_available_from','')::timestamptz else v_existing.claim_available_from end;
  v_claim_until := case when p_reward ? 'claim_available_until' then nullif(p_reward->>'claim_available_until','')::timestamptz else v_existing.claim_available_until end;
  v_entitlement_days := case when p_reward ? 'entitlement_expiry_days' then nullif(p_reward->>'entitlement_expiry_days','')::integer else v_existing.entitlement_expiry_days end;
  v_instructions := case when p_reward ? 'instructions' then nullif(p_reward->>'instructions','') else v_existing.instructions end;
  v_terms := case when p_reward ? 'terms' then nullif(p_reward->>'terms','') else v_existing.terms end;
  v_image := case when p_reward ? 'image_ref' then nullif(p_reward->>'image_ref','') else v_existing.image_ref end;
  v_limit := case when p_reward ? 'usage_limit' then nullif(p_reward->>'usage_limit','')::integer else v_existing.usage_limit end;
  if v_internal_name is null or v_customer_name is null or v_cost is null then
    raise exception 'internal_name, customer_name, and cost_points are required' using errcode = '22023';
  end if;
  if v_kind not in ('credit','manual_item') then raise exception 'unsupported fulfillment kind' using errcode = '22023'; end if;
  if (v_kind='credit' and v_credit <= 0) or (v_kind='manual_item' and v_credit <> 0) then
    raise exception 'credit rewards need positive credit; manual-item rewards must have zero credit' using errcode = '22023';
  end if;

  if not found then
    insert into public.loyalty_rewards (
      id, business_id, name, internal_name, customer_name, description, fulfillment_kind,
      taxonomy_label, cost_points, credit_cents, estimated_cost_cents, active, sort,
      claim_available_from, claim_available_until, entitlement_expiry_days, instructions, terms,
      image_ref, usage_limit, current_config_version_id
    ) values (
      v_reward_id, v_header.business_id, v_customer_name, v_internal_name, v_customer_name,
      v_description, v_kind, v_taxonomy, v_cost, v_credit, v_estimated, false, v_sort,
      v_claim_from, v_claim_until, v_entitlement_days, v_instructions, v_terms, v_image, v_limit,
      p_config_version
    );
  end if;

  insert into public.loyalty_reward_versions (
    reward_id, business_id, config_version_id, internal_name, customer_name, description,
    fulfillment_kind, taxonomy_label, cost_points, credit_cents, estimated_cost_cents, active,
    sort, claim_available_from, claim_available_until, entitlement_expiry_days, instructions,
    terms, image_ref, usage_limit
  ) values (
    v_reward_id, v_header.business_id, p_config_version, v_internal_name, v_customer_name,
    v_description, v_kind, v_taxonomy, v_cost, v_credit, v_estimated, v_active, v_sort,
    v_claim_from, v_claim_until, v_entitlement_days, v_instructions, v_terms, v_image, v_limit
  ) on conflict (reward_id, config_version_id) do update set
    internal_name = excluded.internal_name, customer_name = excluded.customer_name,
    description = excluded.description, fulfillment_kind = excluded.fulfillment_kind,
    taxonomy_label = excluded.taxonomy_label, cost_points = excluded.cost_points,
    credit_cents = excluded.credit_cents, estimated_cost_cents = excluded.estimated_cost_cents,
    active = excluded.active, sort = excluded.sort, claim_available_from = excluded.claim_available_from,
    claim_available_until = excluded.claim_available_until,
    entitlement_expiry_days = excluded.entitlement_expiry_days, instructions = excluded.instructions,
    terms = excluded.terms, image_ref = excluded.image_ref,
    usage_limit = excluded.usage_limit
  returning id into v_version_id;

  delete from public.loyalty_reward_branches where reward_version_id = v_version_id;
  delete from public.loyalty_reward_services where reward_version_id = v_version_id;
  delete from public.loyalty_reward_products where reward_version_id = v_version_id;
  insert into public.loyalty_reward_branches (reward_version_id, reward_id, business_id, branch_id)
  select v_version_id, v_reward_id, v_header.business_id, x.value::uuid
    from jsonb_array_elements_text(coalesce(p_eligibility->'branches','[]'::jsonb)) x;
  insert into public.loyalty_reward_services (reward_version_id, reward_id, business_id, service_id)
  select v_version_id, v_reward_id, v_header.business_id, x.value::uuid
    from jsonb_array_elements_text(coalesce(p_eligibility->'services','[]'::jsonb)) x;
  insert into public.loyalty_reward_products (reward_version_id, reward_id, business_id, product_id)
  select v_version_id, v_reward_id, v_header.business_id, x.value::uuid
    from jsonb_array_elements_text(coalesce(p_eligibility->'products','[]'::jsonb)) x;
  perform app.refresh_loyalty_config_snapshot(p_config_version);
  return json_build_object('reward_id', v_reward_id, 'reward_version_id', v_version_id, 'status', 'draft');
end $$;

-- The existing four-argument endpoint remains for old tills. It can redeem only unrestricted
-- rewards. New UI submits a concrete branch/service/product context to the five-column route.
create or replace function app.redeem_reward_core(
  p_business uuid, p_client uuid, p_reward uuid, p_idempotency_key text,
  p_branch uuid default null, p_service uuid default null, p_product uuid default null
)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  lp public.loyalty_programs%rowtype;
  v_reward public.loyalty_rewards%rowtype;
  v_version public.loyalty_reward_versions%rowtype;
  v_balance integer; v_batch_balance integer; v_remaining integer; v_take integer; v_batch record;
  v_actor uuid := auth.uid(); v_staff uuid; v_points_id uuid := gen_random_uuid();
  v_credit_id uuid := gen_random_uuid(); v_operation_id uuid := gen_random_uuid();
  v_payload jsonb; v_operation public.loyalty_operations%rowtype; v_rows integer;
  v_usage integer; v_eligibility jsonb; v_result json;
begin
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);
  if not app.has_perm(p_business, 'create_sales') then raise exception 'not authorized to redeem loyalty rewards' using errcode = '42501'; end if;
  perform 1 from public.businesses where id = p_business for share;
  select s.id into v_staff from public.staff s
   where s.business_id = p_business and s.user_id = v_actor and s.active
     and 'create_sales' = any (app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end, s.created_at limit 1 for update;
  if not found then raise exception 'active staff authorization changed while redeeming' using errcode = '42501'; end if;
  perform 1 from public.clients c where c.id = p_client and c.business_id = p_business for update;
  if not found then raise exception 'client does not belong to this business'; end if;
  if p_branch is not null and not exists (select 1 from public.branches where id=p_branch and business_id=p_business) then raise exception 'branch does not belong to this business'; end if;
  if p_service is not null and not exists (select 1 from public.services where id=p_service and business_id=p_business) then raise exception 'service does not belong to this business'; end if;
  if p_product is not null and not exists (select 1 from public.products where id=p_product and business_id=p_business) then raise exception 'product does not belong to this business'; end if;

  v_payload := jsonb_build_object('business_id',p_business,'client_id',p_client,'reward_id',p_reward,
                                  'branch_id',p_branch,'service_id',p_service,'product_id',p_product);
  perform set_config('app.loyalty_operation_insert_id', v_operation_id::text, true);
  insert into public.loyalty_operations (id,business_id,client_id,reward_id,operation_type,actor,idempotency_key,request_payload,request_hash)
  values (v_operation_id,p_business,p_client,p_reward,'redeem_reward',v_actor,p_idempotency_key,v_payload,md5(v_payload::text))
  on conflict (business_id,operation_type,idempotency_key) do nothing;
  get diagnostics v_rows = row_count;
  perform set_config('app.loyalty_operation_insert_id','',true);
  if v_rows = 0 then
    select * into v_operation from public.loyalty_operations where business_id=p_business and operation_type='redeem_reward' and idempotency_key=p_idempotency_key for update;
    if v_operation.actor <> v_actor or v_operation.request_hash <> md5(v_payload::text) then raise exception 'idempotency key conflicts with another request' using errcode='22023'; end if;
    if v_operation.status = 'completed' then return v_operation.result::json; end if;
    raise exception 'redemption is already in progress' using errcode='55P03';
  end if;

  select * into lp from public.loyalty_programs where business_id=p_business and active limit 1;
  if not found or lp.loyalty_model not in ('points_tiers','stamps') then raise exception 'this business does not use catalog redemption'; end if;
  select * into v_reward from public.loyalty_rewards where id=p_reward and business_id=p_business;
  if not found then raise exception 'reward not found'; end if;
  select rv.* into v_version from public.loyalty_reward_versions rv
   join public.businesses b on b.active_config_version_id=rv.config_version_id
   where rv.reward_id=p_reward and rv.business_id=p_business;
  if not found or not v_version.active then raise exception 'reward not found or inactive'; end if;
  if v_version.claim_available_from is not null and v_version.claim_available_from > now() then raise exception 'reward is not available yet'; end if;
  if v_version.claim_available_until is not null and v_version.claim_available_until <= now() then raise exception 'reward claim period has ended'; end if;
  if v_version.fulfillment_kind not in ('credit','manual_item') then raise exception 'unsupported reward fulfillment'; end if;

  select jsonb_build_object(
    'branch_ids', coalesce((select jsonb_agg(branch_id order by branch_id) from public.loyalty_reward_branches where reward_version_id=v_version.id),'[]'::jsonb),
    'service_ids', coalesce((select jsonb_agg(service_id order by service_id) from public.loyalty_reward_services where reward_version_id=v_version.id),'[]'::jsonb),
    'product_ids', coalesce((select jsonb_agg(product_id order by product_id) from public.loyalty_reward_products where reward_version_id=v_version.id),'[]'::jsonb),
    'selected', jsonb_build_object('branch_id',p_branch,'service_id',p_service,'product_id',p_product)
  ) into v_eligibility;
  if exists (select 1 from public.loyalty_reward_branches where reward_version_id=v_version.id)
     and not exists (select 1 from public.loyalty_reward_branches where reward_version_id=v_version.id and branch_id=p_branch) then
    raise exception 'reward is not eligible at this branch';
  end if;
  if exists (select 1 from public.loyalty_reward_services where reward_version_id=v_version.id)
     and not exists (select 1 from public.loyalty_reward_services where reward_version_id=v_version.id and service_id=p_service) then
    raise exception 'reward is not eligible for this service';
  end if;
  if exists (select 1 from public.loyalty_reward_products where reward_version_id=v_version.id)
     and not exists (select 1 from public.loyalty_reward_products where reward_version_id=v_version.id and product_id=p_product) then
    raise exception 'reward is not eligible for this product';
  end if;
  select count(*)::integer into v_usage from public.loyalty_redemptions
   where business_id=p_business and client_id=p_client and reward_id=p_reward;
  if v_version.usage_limit is not null and v_usage >= v_version.usage_limit then
    raise exception 'customer has reached this reward usage limit' using errcode='check_violation';
  end if;

  select coalesce(sum(points),0)::integer into v_balance from public.points_ledger where business_id=p_business and client_id=p_client;
  if v_balance < v_version.cost_points then raise exception 'insufficient points: % < %',v_balance,v_version.cost_points using errcode='check_violation'; end if;
  select coalesce(sum(remaining),0)::integer into v_batch_balance from public.points_batches where business_id=p_business and client_id=p_client and remaining>0;
  if v_batch_balance < v_version.cost_points then raise exception 'points batches cannot prove redemption' using errcode='check_violation'; end if;
  v_remaining:=v_version.cost_points;
  for v_batch in select id,remaining from public.points_batches where business_id=p_business and client_id=p_client and remaining>0 order by expires_at nulls last,earned_at,id for update loop
    exit when v_remaining=0; v_take:=least(v_batch.remaining,v_remaining); update public.points_batches set remaining=remaining-v_take where id=v_batch.id; v_remaining:=v_remaining-v_take;
  end loop;
  perform set_config('app.points_ledger_insert_id',v_points_id::text,true); perform set_config('app.points_ledger_write_scope','redeem_points',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor) values(v_points_id,p_business,p_client,'redeem',-v_version.cost_points,'reward: '||v_version.customer_name,v_actor);
  perform set_config('app.points_ledger_insert_id','',true); perform set_config('app.points_ledger_write_scope','',true);
  if v_version.credit_cents>0 then
    perform set_config('app.credit_ledger_insert_id',v_credit_id::text,true); perform set_config('app.credit_ledger_write_scope','redeem_points',true);
    insert into public.credit_ledger(id,business_id,client_id,entry_type,amount_cents,reference,actor) values(v_credit_id,p_business,p_client,'loyalty_earn',v_version.credit_cents,'loyalty reward: '||v_version.customer_name,v_actor);
    perform set_config('app.credit_ledger_insert_id','',true); perform set_config('app.credit_ledger_write_scope','',true);
  end if;
  insert into public.loyalty_redemptions(business_id,client_id,reward_id,reward_name,points_spent,credit_cents,actor,reward_version_id,reward_snapshot,eligibility_snapshot,fulfillment_kind,entitlement_expires_at,usage_number)
  values(p_business,p_client,p_reward,v_version.customer_name,v_version.cost_points,v_version.credit_cents,v_actor,v_version.id,
         to_jsonb(v_version)-'id'-'config_version_id'-'business_id'-'created_at',v_eligibility,v_version.fulfillment_kind,
         case when v_version.entitlement_expiry_days is null then null
              else now() + make_interval(days => v_version.entitlement_expiry_days) end,
         v_usage+1);
  v_result:=json_build_object('ok',true,'reward',v_version.customer_name,'points_spent',v_version.cost_points,'credit_cents',v_version.credit_cents,'reward_version_id',v_version.id);
  perform set_config('app.loyalty_operation_complete_id',v_operation_id::text,true);
  update public.loyalty_operations set status='completed',result=v_result::jsonb,completed_at=now() where id=v_operation_id;
  perform set_config('app.loyalty_operation_complete_id','',true);
  return v_result;
end $$;
revoke execute on function app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid) from public, anon, authenticated;

create or replace function public.redeem_reward(p_business uuid,p_client uuid,p_reward uuid,p_idempotency_key text default null)
returns json language sql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$ select app.redeem_reward_core(p_business,p_client,p_reward,p_idempotency_key,null,null,null) $$;

create or replace function public.redeem_reward_at_context(
  p_business uuid,p_client uuid,p_reward uuid,p_idempotency_key text,
  p_branch uuid default null,p_service uuid default null,p_product uuid default null
)
returns json language sql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$ select app.redeem_reward_core(p_business,p_client,p_reward,p_idempotency_key,p_branch,p_service,p_product) $$;

-- v26's program editor and publisher are extended so reward changes are hashed and published
-- atomically with the program projection.
create or replace function public.save_loyalty_config_draft(p_version uuid, p_config jsonb)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_header public.firm_config_versions%rowtype; v_typed public.loyalty_program_versions%rowtype;
  v_hash text; v_tier jsonb; v_tier_id uuid;
begin
  select * into v_header from public.firm_config_versions where id=p_version for update;
  if not found or not app.is_salon_owner(v_header.business_id) then raise exception 'owner only' using errcode='42501'; end if;
  if v_header.status <> 'draft' then raise exception 'only a draft may be edited'; end if;
  select * into v_typed from public.loyalty_program_versions where config_version_id=p_version;
  update public.loyalty_program_versions set
    kind=coalesce(p_config->>'kind',v_typed.kind), loyalty_model=coalesce(p_config->>'loyalty_model',v_typed.loyalty_model),
    active=coalesce((p_config->>'active')::boolean,v_typed.active),
    earn_points_per_dollar=coalesce((p_config->>'earn_points_per_dollar')::numeric,v_typed.earn_points_per_dollar),
    redeem_points=coalesce((p_config->>'redeem_points')::integer,v_typed.redeem_points),
    reward_credit_cents=coalesce((p_config->>'reward_credit_cents')::integer,v_typed.reward_credit_cents),
    stamp_target=case when p_config ? 'stamp_target' then (p_config->>'stamp_target')::integer else v_typed.stamp_target end,
    stamp_per_cents=case when p_config ? 'stamp_per_cents' then (p_config->>'stamp_per_cents')::integer else v_typed.stamp_per_cents end,
    tier_basis=coalesce(p_config->>'tier_basis',v_typed.tier_basis),
    expiry_mode=coalesce(p_config->>'expiry_mode',v_typed.expiry_mode),
    expiry_days=case when p_config ? 'expiry_days' then (p_config->>'expiry_days')::integer else v_typed.expiry_days end
   where config_version_id=p_version;
  if p_config ? 'reward' then
    if jsonb_typeof(p_config->'reward') <> 'object' then
      raise exception 'reward must be a JSON object' using errcode = '22023';
    end if;
    perform public.save_loyalty_reward_draft(
      p_version,
      nullif(p_config->'reward'->>'id','')::uuid,
      p_config->'reward',
      jsonb_build_object(
        'branches', coalesce(p_config->'reward_branch_ids','[]'::jsonb),
        'services', coalesce(p_config->'reward_service_ids','[]'::jsonb),
        'products', coalesce(p_config->'reward_product_ids','[]'::jsonb)
      )
    );
  elsif p_config ? 'reward_branch_ids' or p_config ? 'reward_service_ids' or p_config ? 'reward_product_ids' then
    raise exception 'eligibility requires a reward envelope' using errcode = '22023';
  end if;
  if p_config ? 'tier' then
    v_tier:=p_config->'tier';
    if jsonb_typeof(v_tier)<>'object' then raise exception 'tier must be an object' using errcode='22023'; end if;
    if exists(select 1 from jsonb_object_keys(v_tier) k where k not in
      ('id','name','threshold','points_multiplier','perk_note','sort','active')) then
      raise exception 'tier contains unsupported fields' using errcode='22023';
    end if;
    v_tier_id:=coalesce(nullif(v_tier->>'id','')::uuid,gen_random_uuid());
    if nullif(btrim(v_tier->>'name'),'') is null
       or coalesce((v_tier->>'threshold')::integer,-1)<0
       or coalesce((v_tier->>'points_multiplier')::numeric,0)<1 then
      raise exception 'tier requires a name, non-negative threshold and multiplier of at least 1' using errcode='22023';
    end if;
    insert into public.loyalty_tier_versions
      (tier_id,config_version_id,business_id,name,threshold,points_multiplier,perk_note,sort,active)
    values(v_tier_id,p_version,v_header.business_id,btrim(v_tier->>'name'),
      (v_tier->>'threshold')::integer,(v_tier->>'points_multiplier')::numeric,
      nullif(btrim(v_tier->>'perk_note'),''),coalesce((v_tier->>'sort')::integer,0),
      coalesce((v_tier->>'active')::boolean,true))
    on conflict(tier_id,config_version_id) do update set
      name=excluded.name,threshold=excluded.threshold,points_multiplier=excluded.points_multiplier,
      perk_note=excluded.perk_note,sort=excluded.sort,active=excluded.active;
  end if;
  perform app.refresh_loyalty_config_snapshot(p_version);
  select snapshot_hash into v_hash from public.firm_config_versions where id=p_version;
  return json_build_object('version_id',p_version,'status','draft','snapshot_hash',v_hash);
end $$;

create or replace function public.publish_loyalty_config(p_version uuid)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_header public.firm_config_versions%rowtype; v_typed public.loyalty_program_versions%rowtype; v_prior uuid;
begin
  select * into v_header from public.firm_config_versions where id=p_version for update;
  if not found or not app.is_salon_owner(v_header.business_id) then raise exception 'owner only' using errcode='42501'; end if;
  if v_header.status <> 'draft' then raise exception 'only a draft may be published'; end if;
  perform 1 from public.businesses where id=v_header.business_id for update;
  select * into v_typed from public.loyalty_program_versions where config_version_id=p_version;
  if v_typed.active and v_typed.loyalty_model='stamps' and coalesce(v_typed.stamp_per_cents,0)<=0 then raise exception 'active stamps configuration requires spend per stamp' using errcode='check_violation'; end if;
  perform app.refresh_loyalty_config_snapshot(p_version);
  select * into v_header from public.firm_config_versions where id=p_version;
  select active_config_version_id into v_prior from public.businesses where id=v_header.business_id;
  update public.firm_config_versions set status='superseded',superseded_at=now() where id=v_prior and status='published';
  update public.firm_config_versions set status='published',published_at=now() where id=p_version;
  update public.businesses set active_config_version_id=p_version where id=v_header.business_id;
  update public.loyalty_programs set
    kind=v_typed.kind,loyalty_model=v_typed.loyalty_model,active=v_typed.active,
    earn_points_per_dollar=v_typed.earn_points_per_dollar,redeem_points=v_typed.redeem_points,
    reward_credit_cents=v_typed.reward_credit_cents,stamp_target=v_typed.stamp_target,
    stamp_per_cents=v_typed.stamp_per_cents,tier_basis=v_typed.tier_basis,expiry_mode=v_typed.expiry_mode,
    expiry_days=v_typed.expiry_days,configuration_status='published',current_config_version_id=p_version
   where business_id=v_header.business_id;
  update public.loyalty_rewards r set
    name=rv.customer_name,internal_name=rv.internal_name,customer_name=rv.customer_name,
    description=rv.description,fulfillment_kind=rv.fulfillment_kind,
    taxonomy_label=rv.taxonomy_label,cost_points=rv.cost_points,credit_cents=rv.credit_cents,
    estimated_cost_cents=rv.estimated_cost_cents,active=rv.active,sort=rv.sort,
    claim_available_from=rv.claim_available_from,claim_available_until=rv.claim_available_until,
    entitlement_expiry_days=rv.entitlement_expiry_days,instructions=rv.instructions,terms=rv.terms,
    image_ref=rv.image_ref,usage_limit=rv.usage_limit,
    current_config_version_id=p_version
   from public.loyalty_reward_versions rv
   where rv.reward_id=r.id and rv.business_id=r.business_id and rv.config_version_id=p_version;
  delete from public.loyalty_tiers where business_id=v_header.business_id;
  insert into public.loyalty_tiers(id,business_id,name,threshold,points_multiplier,perk_note,sort)
  select tier_id,business_id,name,threshold,points_multiplier,perk_note,sort
    from public.loyalty_tier_versions
   where config_version_id=p_version and business_id=v_header.business_id and active;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_header.business_id,auth.uid(),'PUBLISH_CONFIG','firm_config_versions',p_version,
    jsonb_build_object('prior_version_id',v_prior,'new_version_id',p_version,'snapshot_hash',v_header.snapshot_hash));
  return json_build_object('version_id',p_version,'version_no',v_header.version_no,'status','published');
end $$;

-- This helper is invoked only by save_loyalty_config_draft inside the same definer transaction.
-- Keeping it ungranted avoids creating a second authenticated mutation API.
revoke all on function public.save_loyalty_reward_draft(uuid,uuid,jsonb,jsonb) from public, anon, authenticated;
revoke all on function public.redeem_reward(uuid,uuid,uuid,text) from public, anon;
grant execute on function public.redeem_reward(uuid,uuid,uuid,text) to authenticated;
revoke all on function public.redeem_reward_at_context(uuid,uuid,uuid,text,uuid,uuid,uuid) from public, anon;
grant execute on function public.redeem_reward_at_context(uuid,uuid,uuid,text,uuid,uuid,uuid) to authenticated;
revoke all on function public.save_loyalty_config_draft(uuid,jsonb) from public, anon;
grant execute on function public.save_loyalty_config_draft(uuid,jsonb) to authenticated;
revoke all on function public.publish_loyalty_config(uuid) from public, anon;
grant execute on function public.publish_loyalty_config(uuid) to authenticated;

commit;
