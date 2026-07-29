-- NESTLY v99 - CAMPAIGN EXPOSURE TRUTH AND CONSERVATIVE ATTRIBUTION
--
-- Created with `supabase migration new nestly_v99_campaign_truth_adoption_events`
-- and renamed so this forward-only migration sorts after the pending v97 chain.
--
-- v50 campaign grants are orchestration records, not delivery evidence. This
-- migration deliberately leaves all legacy grants at "exposure unknown". A
-- treatment member becomes measurable only after an owner records immutable,
-- privacy-safe exposure evidence tied to a real reward_grant. Both treatment
-- and holdout measurement windows begin after the final verified exposure in
-- the sealed batch. Results remain descriptive/inconclusive until a separately
-- reviewed statistical decision rule exists; they never claim proven lift.

begin;

alter table public.retention_campaign_grants
  add constraint retention_campaign_grants_v99_scope_uk
  unique (id,business_id,campaign_id,client_id);
alter table public.reward_grants
  add constraint reward_grants_v99_client_scope_uk
  unique (id,business_id,client_id);

-- Campaign offers are real reward entitlements, but they are not ordinary
-- visit-window rewards. Give them explicit immutable campaign provenance and a
-- treatment-arm FK instead of fabricating a natural retention period.
alter table public.reward_grants
  add column campaign_id uuid,
  add column campaign_assignment text;
alter table public.reward_grants
  add constraint reward_grants_v99_campaign_shape check (
    (
      campaign_id is null
      and campaign_assignment is null
    )
    or (
      campaign_id is not null
      and campaign_assignment='treatment'
    )
  ),
  add constraint reward_grants_v99_campaign_business_fk
    foreign key (campaign_id,business_id)
    references public.retention_campaigns(id,business_id) on delete restrict,
  add constraint reward_grants_v99_campaign_member_fk
    foreign key (campaign_id,client_id,campaign_assignment)
    references public.retention_campaign_members(
      campaign_id,client_id,assignment
    ) on delete restrict,
  add constraint reward_grants_v99_campaign_scope_uk
    unique (id,business_id,client_id,campaign_id);
alter table public.reward_grants
  drop constraint reward_grants_program_client_window_uk;
create unique index reward_grants_v99_natural_window_uk
  on public.reward_grants(program_id,client_id,period_start,period_end)
  where campaign_id is null;
create unique index reward_grants_v99_campaign_member_uk
  on public.reward_grants(campaign_id,client_id)
  where campaign_id is not null;

alter table public.retention_campaign_grants
  add column request_hash text
    check (request_hash is null or request_hash ~ '^[0-9a-f]{64}$');

-- Preserve the existing natural-period reward path exactly, while allowing a
-- campaign entitlement to snapshot the campaign's immutable published rule.
create or replace function app.snapshot_reward_grant_taxonomy()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_rule public.retention_program_versions%rowtype;
  v_tax public.firm_reward_taxonomy%rowtype;
  v_campaign public.retention_campaigns%rowtype;
  v_period_start timestamptz;
  v_period_end timestamptz;
begin
  perform 1
  from public.businesses
  where id=new.business_id
  for share;

  if new.campaign_id is not null then
    select campaign.* into v_campaign
    from public.retention_campaigns campaign
    where campaign.id=new.campaign_id
      and campaign.business_id=new.business_id;
    if not found then
      raise exception 'campaign reward grant campaign was not found'
        using errcode='foreign_key_violation';
    end if;
    if v_campaign.status<>'active' then
      raise exception 'campaign reward entitlements require an active campaign'
        using errcode='object_not_in_prerequisite_state';
    end if;
    if not exists(
      select 1
      from public.retention_campaign_members member
      where member.campaign_id=v_campaign.id
        and member.business_id=v_campaign.business_id
        and member.client_id=new.client_id
        and member.assignment='treatment'
    ) then
      raise exception 'campaign reward entitlements are treatment-only'
        using errcode='42501';
    end if;
    select rule.* into v_rule
    from public.retention_program_versions rule
    where rule.id=v_campaign.retention_program_version_id
      and rule.program_id=v_campaign.program_id
      and rule.business_id=v_campaign.business_id
      and rule.config_version_id=v_campaign.config_version_id;
    if not found then
      raise exception 'campaign published retention reward is unavailable'
        using errcode='object_not_in_prerequisite_state';
    end if;
    if not exists(
      select 1
      from public.firm_config_versions config
      join public.businesses business
        on business.id=config.business_id
       and business.active_config_version_id=config.id
      where config.id=v_campaign.config_version_id
        and config.business_id=v_campaign.business_id
        and config.status='published'
    ) then
      raise exception
        'campaign reward version is no longer the active published configuration'
        using errcode='object_not_in_prerequisite_state';
    end if;
    select taxonomy.* into v_tax
    from public.firm_reward_taxonomy taxonomy
    where taxonomy.id=v_rule.reward_taxonomy_id
      and taxonomy.business_id=v_rule.business_id;
    if not found then
      raise exception 'campaign reward taxonomy was not found'
        using errcode='foreign_key_violation';
    end if;
    if new.program_id is distinct from v_campaign.program_id
       or new.config_version_id is distinct from v_campaign.config_version_id
       or (
         new.retention_program_version_id is not null
         and new.retention_program_version_id<>v_rule.id
       )
       or (
         new.campaign_assignment is not null
         and new.campaign_assignment<>'treatment'
       ) then
      raise exception 'campaign reward provenance does not match the campaign'
        using errcode='check_violation';
    end if;
    v_period_start:=v_campaign.activated_at;
    v_period_end:=v_period_start
      + pg_catalog.make_interval(
          days=>v_campaign.attribution_window_days
        );
    if new.period_index<>0
       or (
         new.period_start is not null
         and new.period_start is distinct from v_period_start
       )
       or (
         new.period_end is not null
         and new.period_end is distinct from v_period_end
       ) then
      raise exception 'campaign reward window must match campaign activation'
        using errcode='check_violation';
    end if;
    new.campaign_assignment:='treatment';
    new.retention_program_version_id:=v_rule.id;
    new.period_start:=v_period_start;
    new.period_end:=v_period_end;
    new.reward_taxonomy_id:=v_rule.reward_taxonomy_id;
    new.reward_label:=v_tax.label;
    new.fulfillment_kind:=v_rule.fulfillment_kind;
    new.reward_type:=v_rule.fulfillment_kind;
    new.reward_value:=coalesce(
      v_rule.discount_percent,v_rule.credit_cents,0
    );
    new.reward_item:=v_rule.manual_item;
    new.reward_snapshot:=pg_catalog.jsonb_build_object(
      'legacy',false,
      'entitlement_source','retention_campaign_offer',
      'campaign_id',v_campaign.id,
      'program_id',v_rule.program_id,
      'retention_program_version_id',v_rule.id,
      'config_version_id',v_rule.config_version_id,
      'name',v_rule.name,
      'reward_taxonomy_id',v_rule.reward_taxonomy_id,
      'reward_label',v_tax.label,
      'fulfillment_kind',v_rule.fulfillment_kind,
      'discount_percent',v_rule.discount_percent,
      'credit_cents',v_rule.credit_cents,
      'manual_item',v_rule.manual_item,
      'period_start',v_period_start,
      'period_end',v_period_end
    );
    return new;
  end if;

  select rule.* into v_rule
  from public.retention_program_versions rule
  where rule.program_id=new.program_id
    and rule.business_id=new.business_id
    and rule.config_version_id=new.config_version_id;
  if not found then
    raise exception
      'retention program version not found for stamped configuration';
  end if;
  select taxonomy.* into v_tax
  from public.firm_reward_taxonomy taxonomy
  where taxonomy.id=v_rule.reward_taxonomy_id
    and taxonomy.business_id=v_rule.business_id;
  if not found then
    raise exception 'retention reward taxonomy not found';
  end if;
  if new.retention_program_version_id is not null
     and new.retention_program_version_id<>v_rule.id then
    raise exception
      'reward grant retention version does not match its stamped configuration'
      using errcode='23514';
  end if;
  if new.period_index<0 then
    raise exception 'retention grant period index cannot be negative'
      using errcode='23514';
  end if;
  v_period_start:=v_rule.starts_on::timestamptz
    + pg_catalog.make_interval(days=>new.period_index*v_rule.period_days);
  v_period_end:=v_period_start
    + pg_catalog.make_interval(days=>v_rule.period_days);
  if (
       new.period_start is not null
       and new.period_start is distinct from v_period_start
     )
     or (
       new.period_end is not null
       and new.period_end is distinct from v_period_end
     ) then
    raise exception
      'reward grant period does not match its immutable retention version'
      using errcode='23514';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      new.business_id::text||':'||new.program_id::text
        ||':'||new.client_id::text,
      0
    )
  );
  if exists(
    select 1
    from public.reward_grants grant_row
    where grant_row.business_id=new.business_id
      and grant_row.program_id=new.program_id
      and grant_row.client_id=new.client_id
      and grant_row.campaign_id is null
      and grant_row.id<>new.id
      and grant_row.period_start<v_period_end
      and v_period_start<grant_row.period_end
  ) then
    raise exception
      'retention reward already granted for an overlapping programme window'
      using errcode='23505';
  end if;
  new.retention_program_version_id:=v_rule.id;
  new.period_start:=v_period_start;
  new.period_end:=v_period_end;
  new.reward_taxonomy_id:=v_rule.reward_taxonomy_id;
  new.reward_label:=v_tax.label;
  new.fulfillment_kind:=v_rule.fulfillment_kind;
  new.reward_type:=v_rule.fulfillment_kind;
  new.reward_value:=coalesce(
    v_rule.discount_percent,v_rule.credit_cents,0
  );
  new.reward_item:=v_rule.manual_item;
  new.reward_snapshot:=pg_catalog.jsonb_build_object(
    'legacy',false,
    'program_id',v_rule.program_id,
    'retention_program_version_id',v_rule.id,
    'config_version_id',v_rule.config_version_id,
    'name',v_rule.name,
    'goal_visits',v_rule.goal_visits,
    'period_days',v_rule.period_days,
    'starts_on',v_rule.starts_on,
    'period_start',v_period_start,
    'period_end',v_period_end,
    'reward_taxonomy_id',v_rule.reward_taxonomy_id,
    'reward_label',v_tax.label,
    'fulfillment_kind',v_rule.fulfillment_kind,
    'discount_percent',v_rule.discount_percent,
    'credit_cents',v_rule.credit_cents,
    'manual_item',v_rule.manual_item
  );
  return new;
end
$$;
revoke all privileges on function app.snapshot_reward_grant_taxonomy()
  from public,anon,authenticated,service_role;

create or replace function app.reward_grant_snapshot_guard()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  if tg_op='INSERT' then
    if new.reward_snapshot is null then
      raise exception 'retention grant snapshot is required'
        using errcode='23514';
    end if;
    return new;
  end if;
  if new.id is distinct from old.id
     or new.business_id is distinct from old.business_id
     or new.program_id is distinct from old.program_id
     or new.client_id is distinct from old.client_id
     or new.period_index is distinct from old.period_index
     or new.period_start is distinct from old.period_start
     or new.period_end is distinct from old.period_end
     or new.reward_type is distinct from old.reward_type
     or new.reward_value is distinct from old.reward_value
     or new.reward_item is distinct from old.reward_item
     or new.granted_at is distinct from old.granted_at
     or new.config_version_id is distinct from old.config_version_id
     or new.retention_program_version_id
        is distinct from old.retention_program_version_id
     or new.reward_taxonomy_id is distinct from old.reward_taxonomy_id
     or new.reward_label is distinct from old.reward_label
     or new.fulfillment_kind is distinct from old.fulfillment_kind
     or new.reward_snapshot is distinct from old.reward_snapshot
     or new.campaign_id is distinct from old.campaign_id
     or new.campaign_assignment is distinct from old.campaign_assignment then
    raise exception
      'reward grant identity, economics, window and provenance are immutable'
      using errcode='restrict_violation';
  end if;
  return new;
end
$$;
revoke all privileges on function app.reward_grant_snapshot_guard()
  from public,anon,authenticated,service_role;

create table public.retention_campaign_exposures_v99 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  campaign_id uuid not null,
  client_id uuid not null,
  campaign_grant_id uuid not null,
  reward_grant_id uuid not null,
  assignment text not null default 'treatment'
    check (assignment='treatment'),
  channel text not null
    check (channel in ('in_app','email','sms','whatsapp','other')),
  evidence_kind text not null
    check (evidence_kind='manual_confirmation'),
  evidence_reference_hash text
    check (
      evidence_reference_hash is null
      or evidence_reference_hash ~ '^[0-9a-f]{64}$'
    ),
  evidence_context jsonb not null default '{}'::jsonb
    check (jsonb_typeof(evidence_context)='object'),
  exposed_at timestamptz not null,
  recorded_by uuid not null references auth.users(id) on delete restrict,
  idempotency_key text not null
    check (char_length(btrim(idempotency_key)) between 8 and 200),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  recorded_at timestamptz not null default now(),
  constraint retention_campaign_exposures_v99_campaign_fk
    foreign key (campaign_id,business_id)
    references public.retention_campaigns(id,business_id) on delete restrict,
  constraint retention_campaign_exposures_v99_member_fk
    foreign key (campaign_id,client_id,assignment)
    references public.retention_campaign_members(campaign_id,client_id,assignment)
    on delete restrict,
  constraint retention_campaign_exposures_v99_grant_fk
    foreign key (campaign_grant_id,business_id,campaign_id,client_id)
    references public.retention_campaign_grants(
      id,business_id,campaign_id,client_id
    ) on delete restrict,
  constraint retention_campaign_exposures_v99_reward_fk
    foreign key (reward_grant_id,business_id,client_id,campaign_id)
    references public.reward_grants(id,business_id,client_id,campaign_id)
    on delete restrict,
  constraint retention_campaign_exposures_v99_grant_uk
    unique (campaign_grant_id),
  constraint retention_campaign_exposures_v99_idempotency_uk
    unique (business_id,idempotency_key),
  constraint retention_campaign_exposures_v99_id_business_campaign_uk
    unique (id,business_id,campaign_id)
);
create index retention_campaign_exposures_v99_campaign_time_idx
  on public.retention_campaign_exposures_v99(
    business_id,campaign_id,exposed_at,client_id
  );

create table public.retention_campaign_measurement_windows_v99 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  campaign_id uuid not null,
  exposure_cutoff_at timestamptz not null,
  measurement_started_at timestamptz not null,
  measurement_ends_at timestamptz not null,
  treatment_members integer not null check (treatment_members>0),
  holdout_members integer not null check (holdout_members>0),
  verified_treatment_exposures integer not null
    check (verified_treatment_exposures>0),
  minimum_sample_per_arm integer not null
    check (minimum_sample_per_arm between 10 and 10000),
  sealed_by uuid not null references auth.users(id) on delete restrict,
  idempotency_key text not null
    check (char_length(btrim(idempotency_key)) between 8 and 200),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  sealed_at timestamptz not null default now(),
  constraint retention_campaign_measurement_windows_v99_campaign_fk
    foreign key (campaign_id,business_id)
    references public.retention_campaigns(id,business_id) on delete restrict,
  constraint retention_campaign_measurement_windows_v99_campaign_uk
    unique (campaign_id),
  constraint retention_campaign_measurement_windows_v99_idempotency_uk
    unique (business_id,idempotency_key),
  constraint retention_campaign_measurement_windows_v99_id_scope_uk
    unique (id,business_id,campaign_id),
  constraint retention_campaign_measurement_windows_v99_time_check
    check (
      measurement_started_at>=exposure_cutoff_at
      and measurement_ends_at>measurement_started_at
    ),
  constraint retention_campaign_measurement_windows_v99_coverage_check
    check (verified_treatment_exposures=treatment_members)
);

create table public.retention_campaign_attributions_v99 (
  id uuid primary key default gen_random_uuid(),
  measurement_window_id uuid not null,
  business_id uuid not null,
  campaign_id uuid not null,
  client_id uuid not null,
  assignment text not null check (assignment in ('treatment','holdout')),
  sale_id uuid not null,
  returned_at timestamptz not null,
  recorded_by uuid not null references auth.users(id) on delete restrict,
  recorded_at timestamptz not null default now(),
  constraint retention_campaign_attributions_v99_window_fk
    foreign key (measurement_window_id,business_id,campaign_id)
    references public.retention_campaign_measurement_windows_v99(
      id,business_id,campaign_id
    ) on delete restrict,
  constraint retention_campaign_attributions_v99_member_fk
    foreign key (campaign_id,client_id,assignment)
    references public.retention_campaign_members(
      campaign_id,client_id,assignment
    ) on delete restrict,
  constraint retention_campaign_attributions_v99_sale_fk
    foreign key (sale_id,business_id)
    references public.sales(id,business_id) on delete restrict,
  constraint retention_campaign_attributions_v99_member_uk
    unique (campaign_id,client_id),
  constraint retention_campaign_attributions_v99_sale_uk
    unique (campaign_id,sale_id),
  constraint retention_campaign_attributions_v99_id_business_uk
    unique (id,business_id)
);
create index retention_campaign_attributions_v99_campaign_arm_idx
  on public.retention_campaign_attributions_v99(
    business_id,campaign_id,assignment,returned_at
  );

alter table public.retention_campaign_exposures_v99 enable row level security;
alter table public.retention_campaign_measurement_windows_v99
  enable row level security;
alter table public.retention_campaign_attributions_v99
  enable row level security;

revoke all privileges on table public.retention_campaign_exposures_v99
  from public,anon,authenticated,service_role;
revoke all privileges on table
  public.retention_campaign_measurement_windows_v99
  from public,anon,authenticated,service_role;
revoke all privileges on table public.retention_campaign_attributions_v99
  from public,anon,authenticated,service_role;

grant select on table public.retention_campaign_exposures_v99
  to authenticated;
grant select on table public.retention_campaign_measurement_windows_v99
  to authenticated;
grant select on table public.retention_campaign_attributions_v99
  to authenticated;

create policy retention_campaign_exposures_v99_authorized_read
  on public.retention_campaign_exposures_v99
  for select to authenticated
  using (
    auth.uid() is not null
    and (
      app.is_super_admin()
      or (
        app.has_perm(business_id,'view_finance')
        and app.can_module_read(business_id,'retention')
      )
    )
  );
create policy retention_campaign_measurement_windows_v99_authorized_read
  on public.retention_campaign_measurement_windows_v99
  for select to authenticated
  using (
    auth.uid() is not null
    and (
      app.is_super_admin()
      or (
        app.has_perm(business_id,'view_finance')
        and app.can_module_read(business_id,'retention')
      )
    )
  );
create policy retention_campaign_attributions_v99_authorized_read
  on public.retention_campaign_attributions_v99
  for select to authenticated
  using (
    auth.uid() is not null
    and (
      app.is_super_admin()
      or (
        app.has_perm(business_id,'view_finance')
        and app.can_module_read(business_id,'retention')
      )
    )
  );

create or replace function app.v99_immutable_evidence_guard()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  raise exception 'v99 campaign evidence is append-only'
    using errcode='restrict_violation';
end
$$;
revoke all privileges on function app.v99_immutable_evidence_guard()
  from public,anon,authenticated,service_role;

create trigger retention_campaign_exposures_v99_immutable
  before update or delete on public.retention_campaign_exposures_v99
  for each row execute function app.v99_immutable_evidence_guard();
create trigger retention_campaign_measurement_windows_v99_immutable
  before update or delete
  on public.retention_campaign_measurement_windows_v99
  for each row execute function app.v99_immutable_evidence_guard();
create trigger retention_campaign_attributions_v99_immutable
  before update or delete on public.retention_campaign_attributions_v99
  for each row execute function app.v99_immutable_evidence_guard();

-- Preserve append-only v50 evidence while allowing one audited forward repair:
-- an old offer row with no v99 request hash may be linked exactly once to the
-- newly issued campaign entitlement. All other child mutations still refuse.
create or replace function app.retention_campaign_child_immutable_guard()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  if tg_table_name='retention_campaign_grants'
     and tg_op='UPDATE'
     and old.request_hash is null
     and new.request_hash is not null
     and new.request_hash~'^[0-9a-f]{64}$'
     and new.reward_grant_id is not null
     and (
       pg_catalog.to_jsonb(new)-'reward_grant_id'-'request_hash'
     )=(
       pg_catalog.to_jsonb(old)-'reward_grant_id'-'request_hash'
     ) then
    return new;
  end if;
  raise exception
    'campaign membership, offer, and return evidence is append-only'
    using errcode='restrict_violation';
end
$$;
revoke all privileges on function app.retention_campaign_child_immutable_guard()
  from public,anon,authenticated,service_role;

-- Forward replacement of v50's orchestration-only offer writer. The browser
-- no longer supplies a reward-grant identity: this function snapshots the
-- campaign's active published rule into a real treatment-only entitlement and
-- links it to the immutable campaign offer in one transaction.
create or replace function public.issue_campaign_offer(
  p_business uuid,
  p_campaign uuid,
  p_client uuid,
  p_idempotency_key text,
  p_offer_cost_cents bigint default null,
  p_reward_grant_id uuid default null
)
returns json
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid:=auth.uid();
  v_campaign public.retention_campaigns%rowtype;
  v_rule public.retention_program_versions%rowtype;
  v_existing public.retention_campaign_grants%rowtype;
  v_existing_entitlement public.reward_grants%rowtype;
  v_existing_exposure public.retention_campaign_exposures_v99%rowtype;
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_offer_cost bigint;
  v_issued_cost bigint;
  v_hash text;
  v_campaign_grant uuid:=gen_random_uuid();
  v_entitlement uuid;
  v_repaired boolean:=false;
  v_has_existing boolean:=false;
begin
  if v_actor is null
     or not app.is_salon_owner(p_business)
     or not app.can_module_write(p_business,'retention') then
    raise exception 'active owner retention write authorization is required'
      using errcode='42501';
  end if;
  if char_length(v_key) not between 8 and 200 then
    raise exception 'idempotency key must contain 8..200 characters'
      using errcode='22023';
  end if;
  if p_reward_grant_id is not null then
    raise exception
      'campaign reward entitlement is server-issued; reward grant input must be null'
      using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'v99:issue:'||p_business::text||':'||v_key,0
    )
  );
  select campaign.* into v_campaign
  from public.retention_campaigns campaign
  where campaign.id=p_campaign
    and campaign.business_id=p_business
  for update;
  if not found then
    raise exception 'campaign not found in this business'
      using errcode='22023';
  end if;
  if v_campaign.status<>'active' then
    raise exception 'offers require an active campaign'
      using errcode='object_not_in_prerequisite_state';
  end if;
  if not exists(
    select 1
    from public.retention_campaign_members member
    where member.campaign_id=p_campaign
      and member.business_id=p_business
      and member.client_id=p_client
      and member.assignment='treatment'
  ) then
    raise exception 'only a treatment member can receive the campaign reward'
      using errcode='42501';
  end if;
  select rule.* into v_rule
  from public.retention_program_versions rule
  join public.firm_config_versions config
    on config.id=rule.config_version_id
   and config.business_id=rule.business_id
   and config.status='published'
  join public.businesses business
    on business.id=rule.business_id
   and business.active_config_version_id=config.id
  where rule.id=v_campaign.retention_program_version_id
    and rule.program_id=v_campaign.program_id
    and rule.business_id=p_business
    and rule.config_version_id=v_campaign.config_version_id
    and rule.active;
  if not found then
    raise exception
      'campaign reward is no longer an active published entitlement'
      using errcode='object_not_in_prerequisite_state';
  end if;
  if v_rule.fulfillment_kind='credit' then
    v_offer_cost:=v_rule.credit_cents::bigint;
    if p_offer_cost_cents is not null
       and p_offer_cost_cents<>v_offer_cost then
      raise exception
        'credit campaign cost must equal the published credit entitlement'
        using errcode='22023';
    end if;
  else
    v_offer_cost:=coalesce(p_offer_cost_cents,0);
  end if;
  if v_offer_cost<0 then
    raise exception 'offer cost cannot be negative' using errcode='22023';
  end if;

  v_hash:=pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.concat_ws(
          '|','v99.campaign-entitlement',p_business::text,
          p_campaign::text,p_client::text,v_rule.id::text,
          v_rule.config_version_id::text,v_rule.fulfillment_kind,
          coalesce(v_rule.discount_percent::text,''),
          coalesce(v_rule.credit_cents::text,''),
          coalesce(v_rule.manual_item,''),v_offer_cost::text
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  select campaign_grant.* into v_existing
  from public.retention_campaign_grants campaign_grant
  where campaign_grant.business_id=p_business
    and campaign_grant.idempotency_key=v_key;
  if found and (
    v_existing.campaign_id<>p_campaign
    or v_existing.client_id<>p_client
  ) then
    raise exception
      'idempotency key conflicts with another campaign entitlement'
      using errcode='23505';
  end if;
  if not found then
    select campaign_grant.* into v_existing
    from public.retention_campaign_grants campaign_grant
    where campaign_grant.campaign_id=p_campaign
      and campaign_grant.client_id=p_client;
  end if;
  v_has_existing:=found;
  if v_has_existing and v_existing.request_hash is not null
     and v_existing.request_hash<>v_hash then
    raise exception
      'campaign member already has different entitlement terms'
      using errcode='23505';
  end if;
  if v_has_existing and v_existing.offer_cost_cents<>v_offer_cost then
    raise exception
      'legacy campaign offer cost differs from the published entitlement'
      using errcode='23505';
  end if;
  if v_has_existing and v_existing.reward_grant_id is not null then
    select reward.* into v_existing_entitlement
    from public.reward_grants reward
    where reward.id=v_existing.reward_grant_id
      and reward.business_id=p_business
      and reward.client_id=p_client
      and reward.campaign_id=p_campaign
      and reward.campaign_assignment='treatment'
      and reward.retention_program_version_id=v_rule.id
      and reward.config_version_id=v_rule.config_version_id;
    if found then
      select exposure.* into v_existing_exposure
      from public.retention_campaign_exposures_v99 exposure
      where exposure.campaign_grant_id=v_existing.id;
      return pg_catalog.jsonb_build_object(
        'campaign_id',p_campaign,
        'client_id',p_client,
        'campaign_grant_id',v_existing.id,
        'grant_id',v_existing.id,
        'reward_grant_id',v_existing_entitlement.id,
        'entitlement_status',v_existing_entitlement.status,
        'fulfillment_kind',v_existing_entitlement.fulfillment_kind,
        'reward_label',v_existing_entitlement.reward_label,
        'offer_cost_cents',v_existing.offer_cost_cents,
        'exposure_status',case
          when v_existing_exposure.id is null
            then 'awaiting_manual_attestation'
          else 'verified'
        end,
        'exposure_id',v_existing_exposure.id,
        'exposed_at',v_existing_exposure.exposed_at,
        'exposure_channel',v_existing_exposure.channel,
        'delivery_provider_status','not_configured',
        'customer_history_visible',true,
        'economic_value_posted',false,
        'redemption_mode','merchant_fulfilment_pending',
        'replayed',true,
        'legacy_link_repaired',false
      );
    end if;
  end if;

  if not v_has_existing and v_campaign.budget_cap_cents>0 then
    select coalesce(sum(campaign_grant.offer_cost_cents),0)
    into v_issued_cost
    from public.retention_campaign_grants campaign_grant
    where campaign_grant.campaign_id=p_campaign
      and campaign_grant.business_id=p_business;
    if v_issued_cost+v_offer_cost>v_campaign.budget_cap_cents then
      raise exception 'campaign budget cap exceeded'
        using errcode='check_violation';
    end if;
  end if;

  insert into public.reward_grants(
    business_id,program_id,client_id,period_index,reward_type,
    reward_value,reward_item,status,granted_at,config_version_id,
    retention_program_version_id,campaign_id,campaign_assignment
  ) values(
    p_business,v_rule.program_id,p_client,0,v_rule.fulfillment_kind,
    coalesce(v_rule.discount_percent,v_rule.credit_cents,0),
    v_rule.manual_item,'granted',clock_timestamp(),v_rule.config_version_id,
    v_rule.id,p_campaign,'treatment'
  )
  returning id into v_entitlement;

  if v_has_existing then
    update public.retention_campaign_grants
    set reward_grant_id=v_entitlement,
        request_hash=v_hash
    where id=v_existing.id
    returning * into v_existing;
    v_campaign_grant:=v_existing.id;
    v_repaired:=true;
  else
    insert into public.retention_campaign_grants(
      id,campaign_id,business_id,client_id,assignment,reward_grant_id,
      offer_cost_cents,idempotency_key,issued_by,request_hash
    ) values(
      v_campaign_grant,p_campaign,p_business,p_client,'treatment',
      v_entitlement,v_offer_cost,v_key,v_actor,v_hash
    );
  end if;
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    p_business,v_actor,'ISSUE_CAMPAIGN_ENTITLEMENT_V99',
    'retention_campaign_grants',v_campaign_grant,
    pg_catalog.jsonb_build_object(
      'campaign_id',p_campaign,
      'client_id',p_client,
      'reward_grant_id',v_entitlement,
      'retention_program_version_id',v_rule.id,
      'fulfillment_kind',v_rule.fulfillment_kind,
      'offer_cost_cents',v_offer_cost,
      'legacy_link_repaired',v_repaired,
      'delivery_provider_status','not_configured'
    )
  );
  return pg_catalog.jsonb_build_object(
    'campaign_id',p_campaign,
    'client_id',p_client,
    'campaign_grant_id',v_campaign_grant,
    'grant_id',v_campaign_grant,
    'reward_grant_id',v_entitlement,
    'entitlement_status','granted',
    'fulfillment_kind',v_rule.fulfillment_kind,
    'reward_label',(
      select reward.reward_label
      from public.reward_grants reward
      where reward.id=v_entitlement
    ),
    'offer_cost_cents',v_offer_cost,
    'exposure_status','awaiting_manual_attestation',
    'delivery_provider_status','not_configured',
    'customer_history_visible',true,
    'economic_value_posted',false,
    'redemption_mode','merchant_fulfilment_pending',
    'replayed',v_repaired,
    'legacy_link_repaired',v_repaired
  );
end
$$;
revoke all privileges on function public.issue_campaign_offer(
  uuid,uuid,uuid,text,bigint,uuid
) from public,anon,authenticated,service_role;
grant execute on function public.issue_campaign_offer(
  uuid,uuid,uuid,text,bigint,uuid
) to authenticated;

create or replace function public.record_campaign_exposure_v99(
  p_business uuid,
  p_campaign uuid,
  p_campaign_grant uuid,
  p_channel text,
  p_idempotency_key text,
  p_exposed_at timestamptz default now(),
  p_evidence_reference_hash text default null,
  p_evidence_context jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid:=auth.uid();
  v_grant public.retention_campaign_grants%rowtype;
  v_existing public.retention_campaign_exposures_v99%rowtype;
  v_context jsonb:=coalesce(p_evidence_context,'{}'::jsonb);
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_hash text;
  v_id uuid:=gen_random_uuid();
begin
  if v_actor is null
     or not app.is_salon_owner(p_business)
     or not app.can_module_write(p_business,'retention') then
    raise exception 'active owner retention write authorization is required'
      using errcode='42501';
  end if;
  if p_channel not in ('in_app','email','sms','whatsapp','other') then
    raise exception 'unsupported exposure channel' using errcode='22023';
  end if;
  if char_length(v_key) not between 8 and 200 then
    raise exception 'idempotency key must contain 8..200 characters'
      using errcode='22023';
  end if;
  if p_exposed_at is null
     or p_exposed_at>clock_timestamp()+interval '5 minutes'
     or p_exposed_at<clock_timestamp()-interval '90 days' then
    raise exception 'exposure time is outside the accepted evidence window'
      using errcode='22023';
  end if;
  if p_evidence_reference_hash is not null
     and p_evidence_reference_hash!~'^[0-9a-f]{64}$' then
    raise exception 'evidence reference must be a lowercase SHA-256 hash'
      using errcode='22023';
  end if;
  if jsonb_typeof(v_context)<>'object'
     or octet_length(v_context::text)>2048
     or exists(
       select 1
       from pg_catalog.jsonb_object_keys(v_context) as context_key(key)
       where context_key.key not in (
         'entry_point','locale','device_class','surface_version','outcome'
       )
     )
     or exists(
       select 1
       from pg_catalog.jsonb_each(v_context) as context_item(key,value)
       where pg_catalog.jsonb_typeof(context_item.value)
               not in ('string','number','boolean','null')
          or (
            pg_catalog.jsonb_typeof(context_item.value)='string'
            and char_length(context_item.value#>>'{}')>80
          )
     ) then
    raise exception 'evidence context is not privacy-safe'
      using errcode='22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'v99:exposure:'||p_business::text||':'||v_key,0
    )
  );
  select grant_row.* into v_grant
  from public.retention_campaign_grants grant_row
  where grant_row.id=p_campaign_grant
    and grant_row.business_id=p_business
    and grant_row.campaign_id=p_campaign
  for share;
  if not found then
    raise exception 'campaign grant was not found in this campaign'
      using errcode='22023';
  end if;
  if v_grant.reward_grant_id is null then
    raise exception 'campaign grant has no linked reward entitlement'
      using errcode='check_violation';
  end if;
  if not exists(
    select 1
    from public.reward_grants reward
    where reward.id=v_grant.reward_grant_id
      and reward.business_id=p_business
      and reward.client_id=v_grant.client_id
      and reward.campaign_id=p_campaign
      and reward.campaign_assignment='treatment'
      and reward.status in ('granted','redeemed')
      and reward.granted_at<=p_exposed_at
  ) then
    raise exception
      'linked reward entitlement is not valid for this campaign member'
      using errcode='check_violation';
  end if;
  if p_exposed_at<v_grant.issued_at then
    raise exception 'exposure cannot precede the campaign grant'
      using errcode='22023';
  end if;
  if exists(
    select 1
    from public.retention_campaign_measurement_windows_v99 measurement
    where measurement.campaign_id=p_campaign
  ) then
    raise exception 'campaign exposure batch is already sealed'
      using errcode='object_not_in_prerequisite_state';
  end if;

  v_hash:=pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.concat_ws(
          '|','v99.campaign-exposure',p_business::text,p_campaign::text,
          p_campaign_grant::text,p_channel,p_exposed_at::text,
          coalesce(p_evidence_reference_hash,''),v_context::text
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
  select exposure.* into v_existing
  from public.retention_campaign_exposures_v99 exposure
  where exposure.business_id=p_business
    and exposure.idempotency_key=v_key;
  if found then
    if v_existing.request_hash<>v_hash then
      raise exception 'idempotency key conflicts with another exposure envelope'
        using errcode='23505';
    end if;
    return pg_catalog.jsonb_build_object(
      'exposure_id',v_existing.id,
      'campaign_id',v_existing.campaign_id,
      'client_id',v_existing.client_id,
      'exposure_status','verified',
      'delivery_provider_status','not_configured',
      'replayed',true
    );
  end if;
  select exposure.* into v_existing
  from public.retention_campaign_exposures_v99 exposure
  where exposure.campaign_grant_id=p_campaign_grant;
  if found then
    if v_existing.request_hash<>v_hash then
      raise exception 'campaign grant already has different exposure evidence'
        using errcode='23505';
    end if;
    return pg_catalog.jsonb_build_object(
      'exposure_id',v_existing.id,
      'campaign_id',v_existing.campaign_id,
      'client_id',v_existing.client_id,
      'exposure_status','verified',
      'delivery_provider_status','not_configured',
      'replayed',true
    );
  end if;

  insert into public.retention_campaign_exposures_v99(
    id,business_id,campaign_id,client_id,campaign_grant_id,reward_grant_id,
    assignment,channel,evidence_kind,evidence_reference_hash,
    evidence_context,exposed_at,recorded_by,idempotency_key,request_hash
  ) values(
    v_id,p_business,p_campaign,v_grant.client_id,p_campaign_grant,
    v_grant.reward_grant_id,'treatment',p_channel,'manual_confirmation',
    p_evidence_reference_hash,v_context,p_exposed_at,v_actor,v_key,v_hash
  );
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    p_business,v_actor,'CAMPAIGN_EXPOSURE_VERIFIED_V99',
    'retention_campaign_exposures_v99',v_id,
    pg_catalog.jsonb_build_object(
      'campaign_id',p_campaign,'campaign_grant_id',p_campaign_grant,
      'channel',p_channel,'evidence_kind','manual_confirmation',
      'delivery_provider_status','not_configured'
    )
  );
  return pg_catalog.jsonb_build_object(
    'exposure_id',v_id,'campaign_id',p_campaign,
    'client_id',v_grant.client_id,'exposure_status','verified',
    'delivery_provider_status','not_configured','replayed',false
  );
end
$$;
revoke all privileges on function public.record_campaign_exposure_v99(
  uuid,uuid,uuid,text,text,timestamptz,text,jsonb
) from public,anon,authenticated,service_role;

-- The evidence writer is deliberately internal. Browser callers must make an
-- explicit human attestation through the wrapper below; issuing an entitlement
-- never invents exposure and no provider-delivery status is inferred.
create or replace function public.attest_campaign_exposure_v99(
  p_business uuid,
  p_campaign uuid,
  p_campaign_grant uuid,
  p_channel text,
  p_confirmed boolean,
  p_idempotency_key text,
  p_exposed_at timestamptz default null,
  p_evidence_context jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid:=auth.uid();
  v_existing public.retention_campaign_exposures_v99%rowtype;
  v_result jsonb;
  v_exposed_at timestamptz;
begin
  if v_actor is null
     or not app.is_salon_owner(p_business)
     or not app.can_module_write(p_business,'retention') then
    raise exception 'active owner retention write authorization is required'
      using errcode='42501';
  end if;
  if p_confirmed is distinct from true then
    raise exception
      'manual exposure must be explicitly confirmed after the offer is shown or sent'
      using errcode='22023';
  end if;

  -- A transport replay may omit the original server-stamped timestamp. Every
  -- caller-authored evidence field, including the privacy-safe context, must
  -- still match the immutable first attestation exactly.
  select exposure.* into v_existing
  from public.retention_campaign_exposures_v99 exposure
  where exposure.business_id=p_business
    and exposure.idempotency_key=btrim(coalesce(p_idempotency_key,''));
  if found then
    if v_existing.campaign_id<>p_campaign
       or v_existing.campaign_grant_id<>p_campaign_grant
       or v_existing.channel<>p_channel
       or (
         p_exposed_at is not null
         and v_existing.exposed_at is distinct from p_exposed_at
       )
       or v_existing.evidence_context
            is distinct from coalesce(p_evidence_context,'{}'::jsonb) then
      raise exception
        'idempotency key conflicts with another manual exposure attestation'
        using errcode='23505';
    end if;
    return pg_catalog.jsonb_build_object(
      'exposure_id',v_existing.id,
      'campaign_id',v_existing.campaign_id,
      'campaign_grant_id',v_existing.campaign_grant_id,
      'client_id',v_existing.client_id,
      'exposure_status','verified',
      'attestation_kind','merchant_manual_confirmation',
      'attested',true,
      'delivery_provider_status','not_configured',
      'replayed',true
    );
  end if;

  -- The immutable campaign-grant identity is also a replay anchor. This makes
  -- modal/page reload recovery safe even when the browser did not persist the
  -- first attestation key or timestamp.
  select exposure.* into v_existing
  from public.retention_campaign_exposures_v99 exposure
  where exposure.business_id=p_business
    and exposure.campaign_id=p_campaign
    and exposure.campaign_grant_id=p_campaign_grant;
  if found then
    if v_existing.channel<>p_channel
       or (
         p_exposed_at is not null
         and v_existing.exposed_at is distinct from p_exposed_at
       )
       or v_existing.evidence_context
            is distinct from coalesce(p_evidence_context,'{}'::jsonb) then
      raise exception
        'campaign grant already has different manual exposure evidence'
        using errcode='23505';
    end if;
    return pg_catalog.jsonb_build_object(
      'exposure_id',v_existing.id,
      'campaign_id',v_existing.campaign_id,
      'campaign_grant_id',v_existing.campaign_grant_id,
      'client_id',v_existing.client_id,
      'exposure_status','verified',
      'attestation_kind','merchant_manual_confirmation',
      'attested',true,
      'delivery_provider_status','not_configured',
      'replayed',true
    );
  end if;

  v_exposed_at:=coalesce(p_exposed_at,clock_timestamp());
  v_result:=public.record_campaign_exposure_v99(
    p_business,
    p_campaign,
    p_campaign_grant,
    p_channel,
    p_idempotency_key,
    v_exposed_at,
    null,
    p_evidence_context
  );
  return v_result||pg_catalog.jsonb_build_object(
    'campaign_grant_id',p_campaign_grant,
    'attestation_kind','merchant_manual_confirmation',
    'attested',true
  );
end
$$;
revoke all privileges on function public.attest_campaign_exposure_v99(
  uuid,uuid,uuid,text,boolean,text,timestamptz,jsonb
) from public,anon,authenticated,service_role;
grant execute on function public.attest_campaign_exposure_v99(
  uuid,uuid,uuid,text,boolean,text,timestamptz,jsonb
) to authenticated;

create or replace function public.seal_campaign_measurement_v99(
  p_business uuid,
  p_campaign uuid,
  p_idempotency_key text,
  p_minimum_sample_per_arm integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid:=auth.uid();
  v_campaign public.retention_campaigns%rowtype;
  v_existing public.retention_campaign_measurement_windows_v99%rowtype;
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_hash text;
  v_treatment integer;
  v_holdout integer;
  v_exposures integer;
  v_last_exposure timestamptz;
  v_id uuid:=gen_random_uuid();
  v_started timestamptz;
  v_ends timestamptz;
begin
  if v_actor is null
     or not app.is_salon_owner(p_business)
     or not app.can_module_write(p_business,'retention') then
    raise exception 'active owner retention write authorization is required'
      using errcode='42501';
  end if;
  if char_length(v_key) not between 8 and 200 then
    raise exception 'idempotency key must contain 8..200 characters'
      using errcode='22023';
  end if;
  if p_minimum_sample_per_arm not between 10 and 10000 then
    raise exception 'minimum sample per arm must be 10..10000'
      using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('v99:seal:'||p_campaign::text,0)
  );
  select campaign.* into v_campaign
  from public.retention_campaigns campaign
  where campaign.id=p_campaign and campaign.business_id=p_business
  for update;
  if not found then
    raise exception 'campaign not found in this business'
      using errcode='22023';
  end if;
  if v_campaign.status<>'active' then
    raise exception 'only an active campaign can seal measurement'
      using errcode='object_not_in_prerequisite_state';
  end if;

  v_hash:=pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.concat_ws(
          '|','v99.measurement-seal',p_business::text,p_campaign::text,
          p_minimum_sample_per_arm::text
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
  select measurement.* into v_existing
  from public.retention_campaign_measurement_windows_v99 measurement
  where measurement.campaign_id=p_campaign;
  if found then
    if v_existing.request_hash<>v_hash then
      raise exception 'campaign measurement was sealed with different terms'
        using errcode='23505';
    end if;
    return pg_catalog.jsonb_build_object(
      'measurement_window_id',v_existing.id,
      'campaign_id',p_campaign,
      'measurement_started_at',v_existing.measurement_started_at,
      'measurement_ends_at',v_existing.measurement_ends_at,
      'minimum_sample_per_arm',v_existing.minimum_sample_per_arm,
      'replayed',true
    );
  end if;
  if exists(
    select 1
    from public.retention_campaign_measurement_windows_v99 measurement
    where measurement.business_id=p_business
      and measurement.idempotency_key=v_key
  ) then
    raise exception 'idempotency key conflicts with another measurement seal'
      using errcode='23505';
  end if;

  select
    count(*) filter (where member.assignment='treatment'),
    count(*) filter (where member.assignment='holdout')
  into v_treatment,v_holdout
  from public.retention_campaign_members member
  where member.campaign_id=p_campaign
    and member.business_id=p_business;
  select count(*),max(exposure.exposed_at)
  into v_exposures,v_last_exposure
  from public.retention_campaign_exposures_v99 exposure
  where exposure.campaign_id=p_campaign
    and exposure.business_id=p_business;
  if coalesce(v_treatment,0)=0 or coalesce(v_holdout,0)=0 then
    raise exception 'causal comparison requires non-empty treatment and holdout arms'
      using errcode='check_violation';
  end if;
  if v_exposures<>v_treatment then
    raise exception
      'measurement cannot seal until every treatment member has verified exposure (%/% verified)',
      v_exposures,v_treatment
      using errcode='object_not_in_prerequisite_state';
  end if;
  if exists(
    select 1
    from public.retention_campaign_members member
    left join public.retention_campaign_grants grant_row
      on grant_row.campaign_id=member.campaign_id
     and grant_row.client_id=member.client_id
    left join public.retention_campaign_exposures_v99 exposure
      on exposure.campaign_grant_id=grant_row.id
    left join public.reward_grants reward
      on reward.id=grant_row.reward_grant_id
     and reward.business_id=grant_row.business_id
     and reward.client_id=member.client_id
     and reward.campaign_id=member.campaign_id
     and reward.campaign_assignment='treatment'
    where member.campaign_id=p_campaign
      and member.business_id=p_business
      and member.assignment='treatment'
      and (
        grant_row.reward_grant_id is null
        or reward.id is null
        or reward.status not in ('granted','redeemed')
        or exposure.id is null
        or exposure.reward_grant_id<>grant_row.reward_grant_id
      )
  ) then
    raise exception 'treatment entitlement or exposure evidence is incomplete'
      using errcode='object_not_in_prerequisite_state';
  end if;

  v_started:=greatest(v_campaign.activated_at,v_last_exposure);
  v_ends:=v_started
    + pg_catalog.make_interval(days=>v_campaign.attribution_window_days);
  insert into public.retention_campaign_measurement_windows_v99(
    id,business_id,campaign_id,exposure_cutoff_at,
    measurement_started_at,measurement_ends_at,treatment_members,
    holdout_members,verified_treatment_exposures,
    minimum_sample_per_arm,sealed_by,idempotency_key,request_hash
  ) values(
    v_id,p_business,p_campaign,v_last_exposure,v_started,v_ends,
    v_treatment,v_holdout,v_exposures,p_minimum_sample_per_arm,
    v_actor,v_key,v_hash
  );
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    p_business,v_actor,'CAMPAIGN_MEASUREMENT_SEALED_V99',
    'retention_campaign_measurement_windows_v99',v_id,
    pg_catalog.jsonb_build_object(
      'campaign_id',p_campaign,'treatment_members',v_treatment,
      'holdout_members',v_holdout,'verified_exposures',v_exposures,
      'minimum_sample_per_arm',p_minimum_sample_per_arm,
      'measurement_started_at',v_started,'measurement_ends_at',v_ends
    )
  );
  return pg_catalog.jsonb_build_object(
    'measurement_window_id',v_id,'campaign_id',p_campaign,
    'measurement_started_at',v_started,'measurement_ends_at',v_ends,
    'minimum_sample_per_arm',p_minimum_sample_per_arm,'replayed',false
  );
end
$$;
revoke all privileges on function public.seal_campaign_measurement_v99(
  uuid,uuid,text,integer
) from public,anon,authenticated,service_role;
grant execute on function public.seal_campaign_measurement_v99(
  uuid,uuid,text,integer
) to authenticated;

create or replace function public.record_campaign_returns(
  p_business uuid,
  p_campaign uuid
)
returns json
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid:=auth.uid();
  v_campaign public.retention_campaigns%rowtype;
  v_window public.retention_campaign_measurement_windows_v99%rowtype;
  v_recorded integer:=0;
begin
  if v_actor is null
     or not app.is_salon_owner(p_business)
     or not app.can_module_write(p_business,'retention') then
    raise exception 'active owner retention write authorization is required'
      using errcode='42501';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('v99:returns:'||p_campaign::text,0)
  );
  select campaign.* into v_campaign
  from public.retention_campaigns campaign
  where campaign.id=p_campaign and campaign.business_id=p_business
  for share;
  if not found then
    raise exception 'campaign not found in this business'
      using errcode='22023';
  end if;
  if v_campaign.status not in ('active','completed') then
    raise exception 'returns require an active or completed campaign'
      using errcode='object_not_in_prerequisite_state';
  end if;
  select measurement.* into v_window
  from public.retention_campaign_measurement_windows_v99 measurement
  where measurement.campaign_id=p_campaign
    and measurement.business_id=p_business;
  if not found then
    raise exception 'verified exposure measurement is not sealed'
      using errcode='object_not_in_prerequisite_state';
  end if;

  insert into public.retention_campaign_attributions_v99(
    measurement_window_id,business_id,campaign_id,client_id,assignment,
    sale_id,returned_at,recorded_by
  )
  select
    v_window.id,p_business,p_campaign,member.client_id,member.assignment,
    first_return.sale_id,first_return.occurred_at,v_actor
  from public.retention_campaign_members member
  join lateral(
    select sale.id as sale_id,sale.occurred_at
    from public.sales sale
    where sale.business_id=p_business
      and sale.client_id=member.client_id
      and sale.counts_as_visit
      and sale.reversal_of is null
      and sale.occurred_at>=v_window.measurement_started_at
      and sale.occurred_at<v_window.measurement_ends_at
      and not exists(
        select 1
        from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id
      )
    order by sale.occurred_at,sale.id
    limit 1
  ) first_return on true
  where member.campaign_id=p_campaign
    and member.business_id=p_business
  on conflict (campaign_id,client_id) do nothing;
  get diagnostics v_recorded=row_count;

  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    p_business,v_actor,'RECORD_CAMPAIGN_ATTRIBUTIONS_V99',
    'retention_campaign_measurement_windows_v99',v_window.id,
    pg_catalog.jsonb_build_object(
      'campaign_id',p_campaign,'newly_recorded',v_recorded,
      'measurement_started_at',v_window.measurement_started_at
    )
  );
  return pg_catalog.jsonb_build_object(
    'campaign_id',p_campaign,'measurement_window_id',v_window.id,
    'newly_recorded',v_recorded,
    'legacy_v50_return_evidence_used',false
  );
end
$$;
revoke all privileges on function public.record_campaign_returns(uuid,uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.record_campaign_returns(uuid,uuid)
  to authenticated;

create or replace function public.get_campaign_results(p_campaign uuid)
returns json
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_business uuid;
  v_campaign public.retention_campaigns%rowtype;
  v_window public.retention_campaign_measurement_windows_v99%rowtype;
  v_t_members integer:=0;
  v_h_members integer:=0;
  v_t_returned integer:=0;
  v_h_returned integer:=0;
  v_t_revenue bigint:=0;
  v_h_revenue bigint:=0;
  v_exposures integer:=0;
  v_grants integer:=0;
  v_legacy_unknown integer:=0;
  v_t_rate integer;
  v_h_rate integer;
  v_difference integer;
  v_status text;
  v_threshold_met boolean:=false;
begin
  select campaign.* into v_campaign
  from public.retention_campaigns campaign
  where campaign.id=p_campaign;
  if not found then
    raise exception 'campaign not found' using errcode='22023';
  end if;
  v_business:=v_campaign.business_id;
  if auth.uid() is null
     or not (
       app.is_super_admin()
       or (
         app.has_perm(v_business,'view_finance')
         and app.can_module_read(v_business,'retention')
       )
     ) then
    raise exception 'authorized retention read is required'
      using errcode='42501';
  end if;

  select
    count(*) filter (where member.assignment='treatment'),
    count(*) filter (where member.assignment='holdout')
  into v_t_members,v_h_members
  from public.retention_campaign_members member
  where member.campaign_id=p_campaign
    and member.business_id=v_business;
  select count(*) into v_grants
  from public.retention_campaign_grants grant_row
  where grant_row.campaign_id=p_campaign
    and grant_row.business_id=v_business;
  select count(*) into v_exposures
  from public.retention_campaign_exposures_v99 exposure
  where exposure.campaign_id=p_campaign
    and exposure.business_id=v_business;
  select count(*) into v_legacy_unknown
  from public.retention_campaign_grants grant_row
  left join public.retention_campaign_exposures_v99 exposure
    on exposure.campaign_grant_id=grant_row.id
  where grant_row.campaign_id=p_campaign
    and grant_row.business_id=v_business
    and exposure.id is null;
  select measurement.* into v_window
  from public.retention_campaign_measurement_windows_v99 measurement
  where measurement.campaign_id=p_campaign
    and measurement.business_id=v_business;

  if not found then
    return pg_catalog.jsonb_build_object(
      'campaign_id',p_campaign,'business_id',v_business,
      'campaign_status',v_campaign.status,
      'measurement_status','awaiting_verified_exposure',
      'claimability','no_lift_or_roi_claim',
      'delivery_provider_status','not_configured',
      'treatment',pg_catalog.jsonb_build_object(
        'members',v_t_members,'grant_records',v_grants,
        'verified_exposures',v_exposures,
        'legacy_or_unverified_grants',v_legacy_unknown,
        'returned',null,'return_rate_bps',null,'revenue_cents',null
      ),
      'holdout',pg_catalog.jsonb_build_object(
        'members',v_h_members,'returned',null,
        'return_rate_bps',null,'revenue_cents',null
      ),
      'observed_return_rate_difference_bps',null,
      'net_lift_bps',null,'incremental_returns',null,
      'incremental_revenue_cents',null,
      'legacy_v50_return_evidence_used',false,
      'measurement_note',
        'Legacy grant records have unknown exposure. Seal measurement only after every treatment member has a linked reward and verified exposure.'
    );
  end if;

  with judged as(
    select member.assignment,
      exists(
        select 1
        from public.sales sale
        where sale.business_id=v_business
          and sale.client_id=member.client_id
          and sale.counts_as_visit
          and sale.reversal_of is null
          and sale.occurred_at>=v_window.measurement_started_at
          and sale.occurred_at<v_window.measurement_ends_at
          and not exists(
            select 1
            from public.sales reversal
            where reversal.business_id=sale.business_id
              and reversal.reversal_of=sale.id
          )
      ) as returned,
      coalesce((
        select sum(sale.amount_cents)
        from public.sales sale
        where sale.business_id=v_business
          and sale.client_id=member.client_id
          and sale.counts_as_revenue
          and sale.reversal_of is null
          and sale.occurred_at>=v_window.measurement_started_at
          and sale.occurred_at<v_window.measurement_ends_at
          and not exists(
            select 1
            from public.sales reversal
            where reversal.business_id=sale.business_id
              and reversal.reversal_of=sale.id
          )
      ),0)::bigint as revenue_cents
    from public.retention_campaign_members member
    where member.campaign_id=p_campaign
      and member.business_id=v_business
  )
  select
    count(*) filter (where assignment='treatment' and returned),
    count(*) filter (where assignment='holdout' and returned),
    coalesce(sum(revenue_cents) filter (where assignment='treatment'),0),
    coalesce(sum(revenue_cents) filter (where assignment='holdout'),0)
  into v_t_returned,v_h_returned,v_t_revenue,v_h_revenue
  from judged;
  v_t_rate:=case when v_t_members>0
    then (v_t_returned*10000)/v_t_members else null end;
  v_h_rate:=case when v_h_members>0
    then (v_h_returned*10000)/v_h_members else null end;
  v_difference:=case when v_t_rate is not null and v_h_rate is not null
    then v_t_rate-v_h_rate else null end;
  v_threshold_met:=
    v_t_members>=v_window.minimum_sample_per_arm
    and v_h_members>=v_window.minimum_sample_per_arm;
  v_status:=case
    when clock_timestamp()<v_window.measurement_ends_at then 'collecting'
    when not v_threshold_met then 'inconclusive_minimum_sample'
    else 'inconclusive_statistical_test_not_implemented'
  end;

  return pg_catalog.jsonb_build_object(
    'campaign_id',p_campaign,'business_id',v_business,
    'campaign_status',v_campaign.status,
    'measurement_status',v_status,
    'claimability','descriptive_observation_not_causal_proof',
    'delivery_provider_status','not_configured',
    'measurement_started_at',v_window.measurement_started_at,
    'measurement_ends_at',v_window.measurement_ends_at,
    'minimum_sample_per_arm',v_window.minimum_sample_per_arm,
    'minimum_sample_met',v_threshold_met,
    'treatment',pg_catalog.jsonb_build_object(
      'members',v_t_members,'grant_records',v_grants,
      'verified_exposures',v_exposures,
      'legacy_or_unverified_grants',v_legacy_unknown,
      'returned',v_t_returned,'return_rate_bps',v_t_rate,
      'revenue_cents',v_t_revenue
    ),
    'holdout',pg_catalog.jsonb_build_object(
      'members',v_h_members,'returned',v_h_returned,
      'return_rate_bps',v_h_rate,'revenue_cents',v_h_revenue
    ),
    'observed_return_rate_difference_bps',v_difference,
    'observed_revenue_difference_cents',v_t_revenue-v_h_revenue,
    'net_lift_bps',null,'incremental_returns',null,
    'incremental_revenue_cents',null,
    'legacy_v50_return_evidence_used',false,
    'measurement_note',
      'Observed differences are descriptive. No lift, ROI, or statistical-significance claim is made.'
  );
end
$$;
revoke all privileges on function public.get_campaign_results(uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.get_campaign_results(uuid)
  to authenticated;

-- Customer activity must not describe a campaign offer as earned, fulfilled,
-- or spendable merely because its server-issued entitlement row exists.
create or replace function public.customer_get_loyalty_details(
  p_business_slug text,
  p_cursor jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_context record;
  v_program public.loyalty_programs%rowtype;
  v_cursor jsonb:=coalesce(p_cursor,'{}'::jsonb);
  v_limit integer:=20;
  v_before_at timestamptz;
  v_before_id uuid;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required'
      using errcode='28000';
  end if;
  if pg_catalog.jsonb_typeof(v_cursor)<>'object'
     or exists(
       select 1
       from pg_catalog.jsonb_object_keys(v_cursor) as keys(key)
       where keys.key not in ('limit','before_at','before_id')
     ) then
    raise exception 'invalid loyalty activity cursor' using errcode='22023';
  end if;
  begin
    v_limit:=least(
      greatest(coalesce((v_cursor->>'limit')::integer,20),1),50
    );
    v_before_at:=nullif(v_cursor->>'before_at','')::timestamptz;
    v_before_id:=nullif(v_cursor->>'before_id','')::uuid;
  exception when others then
    raise exception 'invalid loyalty activity cursor' using errcode='22023';
  end;
  if (v_before_at is null)<>(v_before_id is null) then
    raise exception 'loyalty activity cursor is incomplete'
      using errcode='22023';
  end if;

  select * into v_context
  from app.v32_customer_wallet_context(p_business_slug)
  limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode='42501';
  end if;
  if not ('loyalty'=any(v_context.enabled_modules)) then
    raise exception 'loyalty module is unavailable for this business'
      using errcode='42501';
  end if;
  select * into v_program
  from public.loyalty_programs program
  where program.business_id=v_context.business_id
    and program.active
  limit 1;
  if not found then
    raise exception 'loyalty module is unavailable for this business'
      using errcode='42501';
  end if;

  with activity as (
    select
      ledger.id,
      ledger.created_at as event_at,
      ledger.entry_type as event_type,
      ledger.points::integer as points_delta,
      case ledger.entry_type
        when 'earn' then 'Points earned'
        when 'expire' then 'Points expired'
        when 'adjust' then 'Balance adjustment'
        else 'Loyalty activity'
      end as title,
      null::text as detail,
      null::text as status,
      null::timestamptz as entitlement_expires_at,
      false as is_campaign_entitlement,
      null::text as entitlement_status,
      null::text as fulfillment_status,
      null::text as redemption_mode,
      null::boolean as economic_value_posted,
      null::text as fulfillment_kind,
      null::text as reward_label,
      false as reward_value_hidden,
      null::text as display_label,
      null::bigint as display_amount_cents
    from public.points_ledger ledger
    where ledger.business_id=v_context.business_id
      and ledger.client_id=v_context.client_id
      and ledger.entry_type in ('earn','expire','adjust')
    union all
    select
      redemption.id,
      redemption.redeemed_at,
      'reward_claimed',
      -redemption.points_spent,
      redemption.reward_name,
      null::text,
      case when reversal.id is null then 'claimed' else 'reversed' end,
      redemption.entitlement_expires_at,
      false,null::text,null::text,null::text,null::boolean,
      null::text,redemption.reward_name,false,redemption.reward_name,
      null::bigint
    from public.loyalty_redemptions redemption
    left join public.loyalty_redemption_reversals reversal
      on reversal.business_id=redemption.business_id
     and reversal.redemption_id=redemption.id
    where redemption.business_id=v_context.business_id
      and redemption.client_id=v_context.client_id
    union all
    select
      reward.id,
      reward.granted_at,
      case when reward.campaign_id is not null
        then 'campaign_offer_entitlement'
        else 'retention_reward'
      end,
      0,
      case when reward.campaign_id is not null
        then 'Offer awaiting merchant fulfilment'
        else coalesce(
          nullif(btrim(reward.reward_label),''),'Reward earned'
        )
      end,
      case when reward.campaign_id is not null
        then 'No wallet value has been posted. Ask the business to fulfil this offer.'
        else null::text
      end,
      case
        when reward.campaign_id is not null and reward.status='expired'
          then 'expired_unfulfilled'
        when reward.campaign_id is not null
          then 'merchant_fulfilment_pending'
        else reward.status
      end,
      null::timestamptz,
      reward.campaign_id is not null,
      reward.status,
      case
        when reward.campaign_id is not null and reward.status='expired'
          then 'expired_unfulfilled'
        when reward.campaign_id is not null
          then 'merchant_fulfilment_pending'
        else reward.status
      end,
      case when reward.campaign_id is not null
        then 'merchant_fulfilment_pending'
        else null::text
      end,
      case when reward.campaign_id is not null then false else null::boolean end,
      reward.fulfillment_kind,
      reward.reward_label,
      reward.campaign_id is not null,
      case when reward.campaign_id is not null
        then 'Offer awaiting merchant fulfilment'
        else coalesce(nullif(btrim(reward.reward_label),''),'Reward')
      end,
      case
        when reward.campaign_id is null
         and reward.fulfillment_kind='credit'
          then reward.reward_value::bigint
        else null::bigint
      end
    from public.reward_grants reward
    where reward.business_id=v_context.business_id
      and reward.client_id=v_context.client_id
  ), eligible as (
    select *
    from activity
    where v_before_at is null
       or (event_at,id)<(v_before_at,v_before_id)
    order by event_at desc,id desc
    limit v_limit+1
  ), visible as (
    select * from eligible order by event_at desc,id desc limit v_limit
  )
  select pg_catalog.jsonb_build_object(
    'model',v_program.loyalty_model,
    'unit',case when v_program.loyalty_model='stamps'
      then 'stamps' else 'points' end,
    'balance',coalesce((
      select sum(ledger.points)::integer
      from public.points_ledger ledger
      where ledger.business_id=v_context.business_id
        and ledger.client_id=v_context.client_id
    ),0),
    'expiry',pg_catalog.jsonb_build_object(
      'expiring_next_30_days',coalesce((
        select sum(batch.remaining)::integer
        from public.points_batches batch
        where batch.business_id=v_context.business_id
          and batch.client_id=v_context.client_id
          and batch.remaining>0
          and batch.expires_at>now()
          and batch.expires_at<=now()+interval '30 days'
      ),0),
      'next_expiry_at',(
        select min(batch.expires_at)
        from public.points_batches batch
        where batch.business_id=v_context.business_id
          and batch.client_id=v_context.client_id
          and batch.remaining>0
          and batch.expires_at>now()
      )
    ),
    'items',coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'event_at',event_at,
          'event_type',event_type,
          'points_delta',points_delta,
          'title',title,
          'detail',detail,
          'status',status,
          'entitlement_expires_at',entitlement_expires_at,
          'is_campaign_entitlement',is_campaign_entitlement,
          'entitlement_status',entitlement_status,
          'fulfillment_status',fulfillment_status,
          'redemption_mode',redemption_mode,
          'economic_value_posted',economic_value_posted,
          'fulfillment_kind',fulfillment_kind,
          'reward_label',reward_label,
          'reward_value_hidden',reward_value_hidden,
          'display_label',display_label,
          'display_amount_cents',display_amount_cents
        )
        order by event_at desc,id desc
      )
      from visible
    ),'[]'::jsonb),
    'next_cursor',case
      when (select count(*) from eligible)>v_limit then (
        select pg_catalog.jsonb_build_object(
          'before_at',event_at,'before_id',id,'limit',v_limit
        )
        from visible order by event_at,id limit 1
      )
      else null
    end
  ) into v_result;
  return v_result;
end
$$;
revoke all privileges on function public.customer_get_loyalty_details(text,jsonb)
  from public,anon,authenticated,service_role;
grant execute on function public.customer_get_loyalty_details(text,jsonb)
  to authenticated;

-- Customer 360 uses the same display-safe entitlement contract instead of
-- selecting raw reward values and inferring fulfilment in the browser.
create or replace function public.staff_get_reward_entitlements_v99(
  p_business uuid,
  p_client uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid:=auth.uid();
  v_result jsonb;
begin
  if v_actor is null
     or not app.can_module_read(p_business,'clients') then
    raise exception 'customer read access is required' using errcode='42501';
  end if;
  if not exists(
    select 1
    from public.clients client
    where client.id=p_client
      and client.business_id=p_business
  ) then
    raise exception 'customer was not found in this business'
      using errcode='22023';
  end if;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id',reward.id,
        'granted_at',reward.granted_at,
        'program_name',program.name,
        'campaign_id',reward.campaign_id,
        'is_campaign_entitlement',reward.campaign_id is not null,
        'entitlement_status',reward.status,
        'fulfillment_status',case
          when reward.campaign_id is not null and reward.status='expired'
            then 'expired_unfulfilled'
          when reward.campaign_id is not null
            then 'merchant_fulfilment_pending'
          else reward.status
        end,
        'redemption_mode',case when reward.campaign_id is not null
          then 'merchant_fulfilment_pending' else null end,
        'economic_value_posted',case when reward.campaign_id is not null
          then false else null end,
        'fulfillment_kind',reward.fulfillment_kind,
        'reward_label',reward.reward_label,
        'reward_value_hidden',reward.campaign_id is not null,
        'display_label',case when reward.campaign_id is not null
          then 'Offer awaiting merchant fulfilment'
          else coalesce(nullif(btrim(reward.reward_label),''),'Reward')
        end,
        'display_amount_cents',case
          when reward.campaign_id is null
           and reward.fulfillment_kind='credit'
            then reward.reward_value::bigint
          else null
        end,
        'display_discount_percent',case
          when reward.campaign_id is null
           and reward.fulfillment_kind='discount_pct'
            then reward.reward_value
          else null
        end,
        'display_item',case
          when reward.campaign_id is null
           and reward.fulfillment_kind='free_item'
            then reward.reward_item
          else null
        end
      )
      order by reward.granted_at desc,reward.id desc
    ),
    '[]'::jsonb
  ) into v_result
  from public.reward_grants reward
  left join public.retention_programs program
    on program.id=reward.program_id
   and program.business_id=reward.business_id
  where reward.business_id=p_business
    and reward.client_id=p_client;
  return v_result;
end
$$;
revoke all privileges on function public.staff_get_reward_entitlements_v99(
  uuid,uuid
) from public,anon,authenticated,service_role;
grant execute on function public.staff_get_reward_entitlements_v99(uuid,uuid)
  to authenticated;

comment on table public.retention_campaign_exposures_v99 is
  'Immutable manually verified exposure evidence. No delivery provider is configured by v99.';
comment on table public.retention_campaign_measurement_windows_v99 is
  'Immutable common-arm measurement window sealed only after complete treatment entitlement and exposure evidence.';
comment on table public.retention_campaign_attributions_v99 is
  'Append-only post-exposure campaign return evidence; legacy v50 return rows are not used.';
comment on function public.get_campaign_results(uuid) is
  'Returns conservative descriptive campaign observations. Lift, ROI and significance remain explicitly unclaimed.';

commit;
