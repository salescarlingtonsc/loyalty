-- FRENLY v29 - BRANCH OVERRIDES AND TYPED CLIENT CUSTOM FIELDS
--
-- Local review candidate. Do not apply until the phase release gate is accepted.
-- Branch overrides are configuration rows, not a second live loyalty program.
-- Client fields are optional business metadata; no legacy client values are invented.

begin;

-- A branch may override only policy knobs that are safe to resolve at the start of
-- a loyalty transaction. The loyalty model/kind remain firm-wide so a branch cannot
-- change the ledger contract underneath an event path.
create table public.loyalty_branch_overrides (
  config_version_id uuid not null,
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id uuid not null,
  active boolean,
  earn_points_per_dollar numeric,
  stamp_per_cents integer,
  expiry_mode text,
  expiry_days integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (config_version_id, branch_id),
  constraint loyalty_branch_overrides_config_business_fk
    foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict,
  constraint loyalty_branch_overrides_branch_business_fk
    foreign key (branch_id, business_id)
    references public.branches(id, business_id) on delete restrict,
  constraint loyalty_branch_overrides_value_check check (
    active is not null
    or earn_points_per_dollar is not null
    or stamp_per_cents is not null
    or expiry_mode is not null
    or expiry_days is not null
  ),
  constraint loyalty_branch_overrides_earn_check
    check (earn_points_per_dollar is null or earn_points_per_dollar >= 0),
  constraint loyalty_branch_overrides_stamp_per_check
    check (stamp_per_cents is null or stamp_per_cents > 0),
  constraint loyalty_branch_overrides_expiry_mode_check
    check (expiry_mode is null or expiry_mode in ('none','fixed','inactivity')),
  constraint loyalty_branch_overrides_expiry_days_check
    check (expiry_days is null or expiry_days > 0)
);

create index loyalty_branch_overrides_business_branch_idx
  on public.loyalty_branch_overrides (business_id, branch_id, config_version_id);

comment on table public.loyalty_branch_overrides is
  'Draft/published-version branch policy overrides. Missing columns inherit the firm default; no model/kind override is permitted.';
comment on column public.loyalty_branch_overrides.active is
  'Nullable override: NULL inherits the firm active flag, false disables loyalty at this branch.';

-- The resolver is consumed by the sale earn trigger below and by preview code.
-- Redemption functions are not changed by v29, so branch overrides do not affect
-- redemption economics until a later phase wires this resolver into those paths.
-- It accepts a draft for preview, or the active version when p_config_version is NULL. The
-- coalesce expressions are the explicit firm-default -> branch-override contract.
create or replace function app.resolve_loyalty_branch_config(
  p_business_id uuid,
  p_branch_id uuid,
  p_config_version_id uuid default null
)
returns table (
  business_id uuid,
  config_version_id uuid,
  branch_id uuid,
  source text,
  kind text,
  loyalty_model text,
  active boolean,
  earn_points_per_dollar numeric,
  redeem_points integer,
  reward_credit_cents integer,
  stamp_target integer,
  stamp_per_cents integer,
  tier_basis text,
  expiry_mode text,
  expiry_days integer
)
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_config_version_id uuid;
begin
  if p_branch_id is not null
     and not exists (
       select 1 from public.branches b
        where b.id = p_branch_id and b.business_id = p_business_id
     ) then
    raise exception 'branch does not belong to business' using errcode = 'foreign_key_violation';
  end if;

  v_config_version_id := coalesce(
    p_config_version_id,
    app.active_config_version(p_business_id)
  );

  -- A newly onboarded firm may still have only its inactive draft. In that
  -- case there is no earn configuration and recording a sale remains valid.
  if v_config_version_id is null then
    return;
  end if;

  if not exists (
    select 1 from public.firm_config_versions v
     where v.id = v_config_version_id and v.business_id = p_business_id
  ) then
    raise exception 'configuration version does not belong to business'
      using errcode = 'foreign_key_violation';
  end if;

  return query
  select d.business_id,
         d.config_version_id,
         p_branch_id,
         case when o.branch_id is null then 'firm_default' else 'branch_override' end,
         d.kind,
         d.loyalty_model,
         coalesce(o.active, d.active),
         coalesce(o.earn_points_per_dollar, d.earn_points_per_dollar),
         d.redeem_points,
         d.reward_credit_cents,
         d.stamp_target,
         coalesce(o.stamp_per_cents, d.stamp_per_cents),
         d.tier_basis,
         coalesce(o.expiry_mode, d.expiry_mode),
         coalesce(o.expiry_days, d.expiry_days)
    from public.loyalty_program_versions d
    left join public.loyalty_branch_overrides o
      on o.config_version_id = d.config_version_id
     and o.business_id = d.business_id
     and o.branch_id is not distinct from p_branch_id
   where d.business_id = p_business_id
     and d.config_version_id = v_config_version_id;
end
$$;

revoke all on function app.resolve_loyalty_branch_config(uuid, uuid, uuid)
  from public, anon, authenticated;

-- New drafts inherit the prior version's branch rows. Published rows are never
-- updated in place, so a publish or rollback-as-new-version keeps history stable.
create or replace function app.clone_loyalty_branch_overrides_on_draft()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.status = 'draft' and new.based_on_version_id is not null then
    insert into public.loyalty_branch_overrides (
      config_version_id, business_id, branch_id, active,
      earn_points_per_dollar, stamp_per_cents, expiry_mode, expiry_days
    )
    select new.id, new.business_id, branch_id, active,
           earn_points_per_dollar, stamp_per_cents, expiry_mode, expiry_days
      from public.loyalty_branch_overrides
     where config_version_id = new.based_on_version_id
       and business_id = new.business_id;
  end if;
  return new;
end
$$;

revoke all on function app.clone_loyalty_branch_overrides_on_draft()
  from public, anon, authenticated;

create trigger trg_clone_loyalty_branch_overrides_on_draft
after insert on public.firm_config_versions
for each row execute function app.clone_loyalty_branch_overrides_on_draft();

create or replace function app.guard_loyalty_branch_override_draft()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_version_id uuid := case when tg_op = 'DELETE' then old.config_version_id else new.config_version_id end;
  v_status text;
  v_old_status text;
begin
  select status into v_status from public.firm_config_versions where id = v_version_id;
  if tg_op = 'UPDATE' then
    select status into v_old_status
      from public.firm_config_versions
     where id = old.config_version_id;
    if old.config_version_id is distinct from new.config_version_id
       or old.business_id is distinct from new.business_id
       or old.branch_id is distinct from new.branch_id then
      raise exception 'branch override identity is immutable; edit the draft row in place'
        using errcode = 'restrict_violation';
    end if;
  end if;
  if v_status is distinct from 'draft'
     or (tg_op = 'UPDATE' and v_old_status is distinct from 'draft') then
    raise exception 'published configuration overrides are immutable; edit a draft'
      using errcode = 'restrict_violation';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  new.updated_at := now();
  return new;
end
$$;

revoke all on function app.guard_loyalty_branch_override_draft()
  from public, anon, authenticated;
create trigger trg_guard_loyalty_branch_override_draft
before insert or update or delete on public.loyalty_branch_overrides
for each row execute function app.guard_loyalty_branch_override_draft();

alter table public.loyalty_branch_overrides enable row level security;
drop policy if exists loyalty_branch_overrides_read on public.loyalty_branch_overrides;
drop policy if exists loyalty_branch_overrides_write on public.loyalty_branch_overrides;
drop policy if exists loyalty_branch_overrides_sa_read on public.loyalty_branch_overrides;
create policy loyalty_branch_overrides_read on public.loyalty_branch_overrides
  for select to authenticated using (app.is_salon_owner(business_id));
create policy loyalty_branch_overrides_write on public.loyalty_branch_overrides
  for all to authenticated
  using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));
create policy loyalty_branch_overrides_sa_read on public.loyalty_branch_overrides
  for select to authenticated using (app.is_super_admin());
revoke all on public.loyalty_branch_overrides from public, anon;
grant select, insert, update, delete on public.loyalty_branch_overrides to authenticated;

-- Definitions are business metadata, not identity proof. A field key is stable
-- within a business; retiring it is prospective and keeps old values addressable.
create table public.client_field_definitions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  field_key text not null,
  label text not null,
  value_type text not null check (value_type in ('text','number','date','boolean','select')),
  classification text not null default 'operational'
    check (classification in ('operational','personal','sensitive')),
  active boolean not null default true,
  customer_visible boolean not null default false,
  customer_editable boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint client_field_definitions_id_business_uk unique (id, business_id),
  constraint client_field_definitions_key_check check (
    field_key = lower(field_key)
    and field_key ~ '^[a-z][a-z0-9_]{1,63}$'
  ),
  constraint client_field_definitions_label_check check (length(btrim(label)) between 1 and 120),
  constraint client_field_definitions_customer_edit_check
    check (not customer_editable or customer_visible),
  constraint client_field_definitions_sensitive_visibility_check
    check (classification <> 'sensitive' or (not customer_visible and not customer_editable))
);

create unique index client_field_definitions_business_key_uk
  on public.client_field_definitions (business_id, field_key);

create table public.client_field_options (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  field_definition_id uuid not null,
  option_key text not null,
  option_label text not null,
  active boolean not null default true,
  sort_order integer not null default 0 check (sort_order >= 0),
  created_at timestamptz not null default now(),
  constraint client_field_options_id_business_uk unique (id, business_id),
  constraint client_field_options_definition_business_fk
    foreign key (field_definition_id, business_id)
    references public.client_field_definitions(id, business_id) on delete cascade,
  constraint client_field_options_key_check check (
    option_key = lower(option_key)
    and option_key ~ '^[a-z][a-z0-9_\-]{0,63}$'
  ),
  constraint client_field_options_label_check check (length(btrim(option_label)) between 1 and 120),
  unique (business_id, field_definition_id, option_key)
);

create table public.client_field_values (
  business_id uuid not null references public.businesses(id) on delete cascade,
  client_id uuid not null,
  field_definition_id uuid not null,
  text_value text,
  number_value numeric,
  date_value date,
  boolean_value boolean,
  select_value text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (business_id, client_id, field_definition_id),
  constraint client_field_values_client_business_fk
    foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete cascade,
  constraint client_field_values_definition_business_fk
    foreign key (field_definition_id, business_id)
    references public.client_field_definitions(id, business_id) on delete restrict,
  constraint client_field_values_one_typed_value_check check (
    (text_value is not null)::integer
    + (number_value is not null)::integer
    + (date_value is not null)::integer
    + (boolean_value is not null)::integer
    + (select_value is not null)::integer = 1
  ),
  constraint client_field_values_text_length_check
    check (text_value is null or length(text_value) <= 4000),
  constraint client_field_values_number_range_check
    check (number_value is null or number_value between -1000000000000 and 1000000000000),
  constraint client_field_values_select_length_check
    check (select_value is null or length(select_value) between 1 and 64)
);

create index client_field_values_business_client_idx
  on public.client_field_values (business_id, client_id);

-- The editor creates a definition and its select options as one atomic owner
-- operation. A failed option must roll back the definition created earlier in
-- this function call; the function never exposes a partial field.
create or replace function public.create_client_field_definition(
  p_business uuid,
  p_field_key text,
  p_label text,
  p_value_type text,
  p_classification text,
  p_options jsonb default '[]'::jsonb
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_definition_id uuid;
  v_option jsonb;
  v_option_count integer := 0;
  v_option_key text;
  v_option_label text;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if p_options is null or jsonb_typeof(p_options) <> 'array' then
    raise exception 'field options must be a JSON array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_options) > 100 then
    raise exception 'a field may have at most 100 options' using errcode = '22023';
  end if;
  if p_value_type <> 'select' and jsonb_array_length(p_options) > 0 then
    raise exception 'only select fields may define options' using errcode = 'check_violation';
  end if;
  if p_value_type = 'select' and jsonb_array_length(p_options) < 2 then
    raise exception 'select fields require at least 2 options' using errcode = 'check_violation';
  end if;

  insert into public.client_field_definitions(
    business_id, field_key, label, value_type, classification
  ) values (
    p_business, p_field_key, p_label, p_value_type, p_classification
  ) returning id into v_definition_id;

  for v_option in select value from jsonb_array_elements(p_options) loop
    if jsonb_typeof(v_option) <> 'object' then
      raise exception 'each field option must be a JSON object' using errcode = '22023';
    end if;
    v_option_key := lower(btrim(v_option->>'option_key'));
    v_option_label := btrim(v_option->>'option_label');
    if v_option_key is null or v_option_key !~ '^[a-z][a-z0-9_\-]{0,63}$' then
      raise exception 'field option key is invalid' using errcode = 'check_violation';
    end if;
    if v_option_label is null or length(v_option_label) not between 1 and 120 then
      raise exception 'field option label must be 1 to 120 characters' using errcode = 'check_violation';
    end if;
    insert into public.client_field_options(
      business_id, field_definition_id, option_key, option_label
    ) values (
      p_business, v_definition_id, v_option_key, v_option_label
    );
    v_option_count := v_option_count + 1;
  end loop;

  return json_build_object(
    'id', v_definition_id,
    'business_id', p_business,
    'field_key', lower(btrim(p_field_key)),
    'value_type', p_value_type,
    'classification', p_classification,
    'options_created', v_option_count
  );
end
$$;

revoke all on function public.create_client_field_definition(uuid, text, text, text, text, jsonb)
  from public, anon;
grant execute on function public.create_client_field_definition(uuid, text, text, text, text, jsonb)
  to authenticated;

-- These triggers make the typed storage agree with the definition row and keep
-- select values normalized. Existing values remain readable after retirement;
-- new writes against an inactive field or option are rejected.
create or replace function app.validate_client_field_option()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_type text;
begin
  select value_type into v_type
    from public.client_field_definitions
   where id = new.field_definition_id and business_id = new.business_id;
  if v_type is null then
    raise exception 'client field definition does not belong to business'
      using errcode = 'foreign_key_violation';
  end if;
  if v_type <> 'select' then
    raise exception 'options are allowed only for select fields'
      using errcode = 'check_violation';
  end if;
  new.option_key := lower(btrim(new.option_key));
  new.option_label := btrim(new.option_label);
  if tg_op = 'UPDATE'
     and (new.business_id is distinct from old.business_id
          or new.field_definition_id is distinct from old.field_definition_id
          or new.option_key is distinct from old.option_key)
     and exists (
       select 1 from public.client_field_values v
        where v.business_id = old.business_id
          and v.field_definition_id = old.field_definition_id
          and v.select_value = old.option_key
     ) then
    raise exception 'select option identity is immutable after values exist'
      using errcode = 'restrict_violation';
  end if;
  return new;
end
$$;

revoke all on function app.validate_client_field_option()
  from public, anon, authenticated;
create trigger trg_validate_client_field_option
before insert or update on public.client_field_options
for each row execute function app.validate_client_field_option();

create or replace function app.guard_client_field_definition()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  new.field_key := lower(btrim(new.field_key));
  new.label := btrim(new.label);
  if tg_op = 'UPDATE' and new.business_id is distinct from old.business_id then
    raise exception 'client field tenant is immutable'
      using errcode = 'restrict_violation';
  end if;
  if tg_op = 'UPDATE' and new.field_key is distinct from old.field_key then
    raise exception 'client field key is immutable; create a new field'
      using errcode = 'restrict_violation';
  end if;
  if tg_op = 'UPDATE'
     and new.value_type is distinct from old.value_type
     and (exists (
       select 1 from public.client_field_values v
        where v.business_id = old.business_id
          and v.field_definition_id = old.id
     ) or exists (
       select 1 from public.client_field_options o
        where o.business_id = old.business_id
          and o.field_definition_id = old.id
     )) then
    raise exception 'client field value type is immutable after values or options exist'
      using errcode = 'restrict_violation';
  end if;
  if tg_op = 'UPDATE'
     and new.classification is distinct from old.classification
     and exists (
       select 1 from public.client_field_values v
        where v.business_id = old.business_id
          and v.field_definition_id = old.id
     ) then
    raise exception 'client field classification is immutable after values exist'
      using errcode = 'restrict_violation';
  end if;
  new.updated_at := now();
  return new;
end
$$;

revoke all on function app.guard_client_field_definition()
  from public, anon, authenticated;
create trigger trg_guard_client_field_definition
before insert or update on public.client_field_definitions
for each row execute function app.guard_client_field_definition();

create or replace function app.validate_client_field_value()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_definition public.client_field_definitions%rowtype;
begin
  select * into v_definition
    from public.client_field_definitions
   where id = new.field_definition_id and business_id = new.business_id;
  if not found then
    raise exception 'client field definition does not belong to business'
      using errcode = 'foreign_key_violation';
  end if;
  if not v_definition.active then
    raise exception 'retired client fields cannot receive new values'
      using errcode = 'check_violation';
  end if;
  if ((new.text_value is not null)::integer
      + (new.number_value is not null)::integer
      + (new.date_value is not null)::integer
      + (new.boolean_value is not null)::integer
      + (new.select_value is not null)::integer) <> 1 then
    raise exception 'exactly one typed client field value is required'
      using errcode = 'check_violation';
  end if;

  case v_definition.value_type
    when 'text' then
      if new.text_value is null then raise exception 'text value is required' using errcode = 'check_violation'; end if;
    when 'number' then
      if new.number_value is null then raise exception 'number value is required' using errcode = 'check_violation'; end if;
    when 'date' then
      if new.date_value is null then raise exception 'date value is required' using errcode = 'check_violation'; end if;
    when 'boolean' then
      if new.boolean_value is null then raise exception 'boolean value is required' using errcode = 'check_violation'; end if;
    when 'select' then
      new.select_value := lower(btrim(new.select_value));
      if new.select_value is null
         or not exists (
           select 1 from public.client_field_options o
            where o.option_key = new.select_value
              and o.business_id = new.business_id
              and o.field_definition_id = new.field_definition_id
              and o.active
         ) then
        raise exception 'select value is not an active option for this field'
          using errcode = 'check_violation';
      end if;
    else
      raise exception 'unsupported client field type' using errcode = 'check_violation';
  end case;
  return new;
end
$$;

revoke all on function app.validate_client_field_value()
  from public, anon, authenticated;
create trigger trg_validate_client_field_value
before insert or update on public.client_field_values
for each row execute function app.validate_client_field_value();

alter table public.client_field_definitions enable row level security;
alter table public.client_field_options enable row level security;
alter table public.client_field_values enable row level security;

drop policy if exists client_field_definitions_owner_read on public.client_field_definitions;
drop policy if exists client_field_definitions_owner_write on public.client_field_definitions;
drop policy if exists client_field_options_owner_read on public.client_field_options;
drop policy if exists client_field_options_owner_write on public.client_field_options;
drop policy if exists client_field_values_owner_read on public.client_field_values;
drop policy if exists client_field_values_owner_write on public.client_field_values;

create policy client_field_definitions_owner_read on public.client_field_definitions
  for select to authenticated using (app.is_salon_owner(business_id));
create policy client_field_definitions_owner_write on public.client_field_definitions
  for all to authenticated
  using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));
create policy client_field_options_owner_read on public.client_field_options
  for select to authenticated using (app.is_salon_owner(business_id));
create policy client_field_options_owner_write on public.client_field_options
  for all to authenticated
  using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));
create policy client_field_values_owner_read on public.client_field_values
  for select to authenticated using (app.is_salon_owner(business_id));
create policy client_field_values_owner_write on public.client_field_values
  for all to authenticated
  using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));

revoke all on public.client_field_definitions from public, anon;
revoke all on public.client_field_options from public, anon;
revoke all on public.client_field_values from public, anon;
grant select, insert, update, delete on public.client_field_definitions to authenticated;
grant select, insert, update, delete on public.client_field_options to authenticated;
grant select, insert, update, delete on public.client_field_values to authenticated;
revoke insert on public.client_field_definitions from authenticated;
revoke insert on public.client_field_options from authenticated;

-- v27 hashes the program and reward tree. v29 extends that audit contract with
-- ordered branch policy overrides. Client-field definitions are deliberately
-- excluded: they are business metadata, not config-versioned policy.
create or replace function app.refresh_loyalty_config_snapshot(p_version uuid)
returns void language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_snapshot jsonb;
begin
  select jsonb_build_object(
    'program', (select to_jsonb(lp) - 'config_version_id'
                  from public.loyalty_program_versions lp
                 where lp.config_version_id = p_version),
    'tiers', coalesce((
      select jsonb_agg(
        to_jsonb(tv)-'id'-'config_version_id'-'business_id'-'created_at'
        order by tv.threshold,tv.sort,tv.tier_id
      ) from public.loyalty_tier_versions tv where tv.config_version_id=p_version
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
      from public.loyalty_reward_versions rv
     where rv.config_version_id = p_version
    ), '[]'::jsonb),
    'branch_overrides', coalesce((
      select jsonb_agg(
        to_jsonb(o) - 'config_version_id' - 'business_id' - 'created_at' - 'updated_at'
        order by o.branch_id
      )
        from public.loyalty_branch_overrides o
       where o.config_version_id = p_version
    ), '[]'::jsonb)
  ) into v_snapshot;
  update public.firm_config_versions
     set snapshot_hash = md5(v_snapshot::text)
   where id = p_version;
end
$$;
revoke all on function app.refresh_loyalty_config_snapshot(uuid)
  from public, anon, authenticated;

create or replace function app.refresh_v29_branch_snapshot_trigger()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_config uuid := coalesce(new.config_version_id, old.config_version_id);
begin
  perform app.refresh_loyalty_config_snapshot(v_config);
  if tg_op = 'DELETE' then return old; end if;
  return new;
end
$$;
revoke all on function app.refresh_v29_branch_snapshot_trigger()
  from public, anon, authenticated;
create trigger trg_loyalty_branch_overrides_snapshot
  after insert or update or delete on public.loyalty_branch_overrides
  for each row execute function app.refresh_v29_branch_snapshot_trigger();

-- Replace the current v24 sale trigger body with the same reviewed financial,
-- retention and referral engine, changing only the loyalty-config source.
-- The sale's stamped config_version_id and branch_id now determine earn values.
create or replace function app.on_sale_recorded()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp' as $$
declare
  lp record;
  rp record;
  refrow record;
  refprog record;
  v_tier public.loyalty_tiers%rowtype;
  v_pts integer;
  v_idx integer;
  v_count integer;
  v_earn_id uuid;
  v_credit_id uuid;
  w_start timestamptz;
  w_end timestamptz;
begin
  if new.reversal_of is not null then
    return new;
  end if;

  if new.client_id is null then
    return new;
  end if;

  if not (new.earns_points or new.counts_as_visit) then
    return new;
  end if;

  if new.earns_points then
    select * into lp
      from app.resolve_loyalty_branch_config(
        new.business_id,
        new.branch_id,
        new.config_version_id
      );
    if found and lp.active then
      -- v29: resolve the sale's immutable version and branch before earning.
      -- v24: earn rule per firm-selected model. stamps = floor(amount / stamp_per_cents);
      -- points-based models = amount * earn_points_per_dollar (unchanged).
      if lp.loyalty_model = 'stamps' then
        v_pts := case when coalesce(lp.stamp_per_cents, 0) > 0
                      then floor(new.amount_cents::numeric / lp.stamp_per_cents)
                      else 0 end;
      elsif lp.kind = 'points' then
        v_pts := floor((new.amount_cents / 100.0) * lp.earn_points_per_dollar);
      else
        v_pts := 0;
      end if;
      -- v23g (#2): the firm's tier multiplier (owner-configured, >= 1) applies at earn time.
      select * into v_tier from app.loyalty_tier_for(new.business_id, new.client_id);
      if v_tier.id is not null and v_tier.points_multiplier > 1 then
        v_pts := floor(v_pts * v_tier.points_multiplier);
      end if;
      if v_pts > 0 then
        v_earn_id := gen_random_uuid();
        perform set_config('app.points_ledger_insert_id', v_earn_id::text, true);
        perform set_config('app.points_ledger_write_scope', 'sale_trigger', true);
        insert into public.points_ledger
          (id, business_id, client_id, entry_type, points, sale_id, reference, actor)
        values
          (v_earn_id, new.business_id, new.client_id, 'earn', v_pts, new.id,
           'auto-earn on sale', auth.uid())
        on conflict do nothing
        returning id into v_earn_id;
        perform set_config('app.points_ledger_insert_id', '', true);
        perform set_config('app.points_ledger_write_scope', '', true);
        if v_earn_id is not null then
          insert into public.points_batches (business_id, client_id, earned, remaining, sale_id, earned_at, expires_at)
          values (
            new.business_id,
            new.client_id,
            v_pts,
            v_pts,
            new.id,
            now(),
            case when lp.expiry_mode = 'fixed'
                 then now() + make_interval(days => lp.expiry_days)
            end
          );
        end if;
      end if;
    end if;
  end if;

  if new.counts_as_visit then
    for rp in
      select * from public.retention_programs
       where business_id = new.business_id
         and active
    loop
      v_idx := floor(extract(epoch from (new.occurred_at - rp.starts_on::timestamptz))
                     / (rp.period_days * 86400));
      if v_idx >= 0 then
        w_start := rp.starts_on::timestamptz + make_interval(days => v_idx * rp.period_days);
        w_end := w_start + make_interval(days => rp.period_days);
        select count(*) into v_count
          from public.sales s
         where s.business_id = new.business_id
           and s.client_id = new.client_id
           and s.counts_as_visit
           and s.reversal_of is null
           and not exists (
             select 1 from public.sales r
              where r.business_id = s.business_id
                and r.reversal_of = s.id
           )
           and s.occurred_at >= w_start
           and s.occurred_at < w_end;

        if v_count >= rp.goal_visits then
          begin
            insert into public.reward_grants (
              business_id, program_id, client_id, period_index,
              reward_type, reward_value, reward_item
            )
            values (
              new.business_id, rp.id, new.client_id, v_idx,
              rp.reward_type, rp.reward_value, rp.reward_item
            );
            if rp.reward_type = 'credit' and rp.reward_value > 0 then
              v_credit_id := gen_random_uuid();
              perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
              perform set_config('app.credit_ledger_write_scope', 'sale_trigger', true);
              insert into public.credit_ledger
                (id, business_id, client_id, entry_type, amount_cents, reference, sale_id, actor)
              values (
                v_credit_id,
                new.business_id,
                new.client_id,
                'loyalty_earn',
                rp.reward_value::integer,
                'retention reward: ' || rp.name,
                new.id,
                auth.uid()
              );
              perform set_config('app.credit_ledger_insert_id', '', true);
              perform set_config('app.credit_ledger_write_scope', '', true);
            end if;
          exception when unique_violation then
            null;
          end;
        end if;
      end if;
    end loop;

    select r.* into refrow
      from public.referrals r
     where r.business_id = new.business_id
       and r.referred_client_id = new.client_id
       and r.status = 'pending'
     limit 1;
    if found then
      select * into refprog
        from public.referral_programs
       where business_id = new.business_id
         and enabled
       limit 1;
      if found and new.amount_cents >= coalesce(refprog.min_spend_cents, 0) then
        update public.referrals
           set status = 'rewarded',
               qualified_at = now(),
               qualified_sale_id = new.id,
               reward_cents = refprog.reward_cents
         where id = refrow.id
           and status = 'pending';
        if found then
          v_credit_id := gen_random_uuid();
          perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
          perform set_config('app.credit_ledger_write_scope', 'sale_trigger', true);
          insert into public.credit_ledger
            (id, business_id, client_id, entry_type, amount_cents, reference, sale_id, actor)
          values (
            v_credit_id,
            new.business_id,
            refrow.referrer_client_id,
            'referral_reward',
            refprog.reward_cents,
            'referral qualified: first visit completed',
            new.id,
            auth.uid()
          );
          perform set_config('app.credit_ledger_insert_id', '', true);
          perform set_config('app.credit_ledger_write_scope', '', true);
        end if;
      end if;
    end if;
  end if;

  return new;
end $$;
revoke execute on function app.on_sale_recorded() from public, anon, authenticated;

commit;
