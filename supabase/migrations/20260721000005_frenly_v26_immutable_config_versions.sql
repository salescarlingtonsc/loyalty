-- FRENLY v26 - IMMUTABLE TYPED CONFIGURATION VERSIONS
-- Local review candidate. Do not apply until the phase release gate is accepted.

begin;

-- v26 makes loyalty_programs a compatibility projection, not an owner-editable source of truth.
-- SECURITY DEFINER draft/publish RPCs remain able to write it as the migration owner.
drop policy if exists loyalty_programs_write on public.loyalty_programs;
drop policy if exists loyalty_programs_all on public.loyalty_programs;
revoke insert, update, delete, truncate on table public.loyalty_programs
  from public, anon, authenticated;

create table public.firm_config_versions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  version_no integer not null check (version_no > 0),
  status text not null check (status in ('draft','published','superseded','abandoned')),
  based_on_version_id uuid references public.firm_config_versions(id),
  source text not null default 'manual',
  snapshot_hash text not null check (length(snapshot_hash) = 32),
  created_by uuid,
  created_at timestamptz not null default now(),
  published_at timestamptz,
  superseded_at timestamptz,
  constraint firm_config_versions_business_version_uk unique (business_id, version_no),
  constraint firm_config_versions_id_business_uk unique (id, business_id),
  constraint firm_config_versions_base_business_fk
    foreign key (based_on_version_id, business_id)
    references public.firm_config_versions(id, business_id),
  constraint firm_config_versions_state_check check (
    (status = 'draft' and published_at is null and superseded_at is null)
    or (status = 'published' and published_at is not null and superseded_at is null)
    or (status = 'superseded' and published_at is not null and superseded_at is not null)
    or (status = 'abandoned' and published_at is null)
  )
);
create unique index firm_config_one_published_per_business
  on public.firm_config_versions (business_id) where status = 'published';

create table public.loyalty_program_versions (
  config_version_id uuid primary key,
  business_id uuid not null,
  kind text not null check (kind in ('points','stamps')),
  loyalty_model text not null check (loyalty_model in ('classic','points_tiers','stamps')),
  active boolean not null,
  earn_points_per_dollar numeric not null check (earn_points_per_dollar >= 0),
  redeem_points integer not null check (redeem_points > 0),
  reward_credit_cents integer not null check (reward_credit_cents >= 0),
  stamp_target integer,
  stamp_per_cents integer check (stamp_per_cents is null or stamp_per_cents > 0),
  tier_basis text not null check (tier_basis in ('visits','spend','points_earned')),
  expiry_mode text not null check (expiry_mode in ('none','fixed','inactivity')),
  expiry_days integer check (expiry_days is null or expiry_days > 0),
  constraint loyalty_program_versions_header_fk foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict
);

create table public.loyalty_tier_versions (
  id uuid primary key default gen_random_uuid(),
  tier_id uuid not null,
  config_version_id uuid not null,
  business_id uuid not null,
  name text not null check (length(btrim(name)) between 1 and 120),
  threshold integer not null check (threshold >= 0),
  points_multiplier numeric not null check (points_multiplier >= 1),
  perk_note text,
  sort integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint loyalty_tier_versions_header_fk foreign key (config_version_id,business_id)
    references public.firm_config_versions(id,business_id) on delete restrict,
  constraint loyalty_tier_versions_tier_config_uk unique (tier_id,config_version_id)
);

alter table public.businesses add column active_config_version_id uuid;
alter table public.businesses
  add constraint businesses_active_config_version_fk
  foreign key (active_config_version_id, id)
  references public.firm_config_versions(id, business_id) on delete restrict;
alter table public.loyalty_programs add column current_config_version_id uuid;
alter table public.loyalty_programs
  add constraint loyalty_programs_current_config_version_fk
  foreign key (current_config_version_id, business_id)
  references public.firm_config_versions(id, business_id) on delete restrict;

-- Existing firms become v1 without changing their live values or active/paused state.
with inserted as (
  insert into public.firm_config_versions (
    business_id, version_no, status, source, snapshot_hash, created_by,
    published_at
  )
  select lp.business_id, 1, lp.configuration_status, 'legacy_v1',
         md5((to_jsonb(lp) - 'id' - 'business_id' - 'current_config_version_id')::text),
         null, case when lp.configuration_status = 'published' then now() end
    from public.loyalty_programs lp
  returning id, business_id
)
insert into public.loyalty_program_versions (
  config_version_id, business_id, kind, loyalty_model, active,
  earn_points_per_dollar, redeem_points, reward_credit_cents, stamp_target,
  stamp_per_cents, tier_basis, expiry_mode, expiry_days
)
select i.id, lp.business_id, lp.kind, lp.loyalty_model, lp.active,
       lp.earn_points_per_dollar, lp.redeem_points, lp.reward_credit_cents,
       lp.stamp_target, lp.stamp_per_cents, lp.tier_basis, lp.expiry_mode, lp.expiry_days
  from inserted i join public.loyalty_programs lp using (business_id);

update public.loyalty_programs lp
   set current_config_version_id = fv.id
  from public.firm_config_versions fv
 where fv.business_id = lp.business_id and fv.version_no = 1;
update public.businesses b
   set active_config_version_id = fv.id
  from public.firm_config_versions fv
 where fv.business_id = b.id and fv.status = 'published';

insert into public.loyalty_tier_versions
  (tier_id,config_version_id,business_id,name,threshold,points_multiplier,perk_note,sort,active)
select t.id,lp.current_config_version_id,t.business_id,t.name,t.threshold,t.points_multiplier,
       t.perk_note,t.sort,true
  from public.loyalty_tiers t
  join public.loyalty_programs lp on lp.business_id=t.business_id;

drop policy if exists loyalty_tiers_write on public.loyalty_tiers;
drop policy if exists loyalty_tiers_all on public.loyalty_tiers;
revoke insert,update,delete,truncate on table public.loyalty_tiers
  from public,anon,authenticated;
alter table public.loyalty_tier_versions enable row level security;
create policy loyalty_tier_versions_read on public.loyalty_tier_versions for select to authenticated
  using (app.is_salon_member(business_id) or app.is_super_admin());
revoke all on public.loyalty_tier_versions from public,anon,authenticated;
grant select on public.loyalty_tier_versions to authenticated;

create or replace function app.loyalty_tier_version_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_status text;
begin
  if tg_op='DELETE' then
    select status into v_status from public.firm_config_versions where id=old.config_version_id;
  else
    select status into v_status from public.firm_config_versions where id=new.config_version_id;
  end if;
  if v_status<>'draft' then
    raise exception 'published tier versions are immutable' using errcode='restrict_violation';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
revoke execute on function app.loyalty_tier_version_guard() from public,anon,authenticated;
create trigger trg_loyalty_tier_versions_immutable before update or delete
  on public.loyalty_tier_versions for each row execute function app.loyalty_tier_version_guard();

alter table public.sales add column config_version_id uuid;
alter table public.points_ledger add column config_version_id uuid;
alter table public.points_batches add column config_version_id uuid;
alter table public.credit_ledger add column config_version_id uuid;
alter table public.loyalty_redemptions add column config_version_id uuid;
alter table public.reward_grants add column config_version_id uuid;

alter table public.sales add constraint sales_config_version_business_fk
  foreign key (config_version_id, business_id) references public.firm_config_versions(id, business_id);
alter table public.points_ledger add constraint points_ledger_config_version_business_fk
  foreign key (config_version_id, business_id) references public.firm_config_versions(id, business_id);
alter table public.points_batches add constraint points_batches_config_version_business_fk
  foreign key (config_version_id, business_id) references public.firm_config_versions(id, business_id);
alter table public.credit_ledger add constraint credit_ledger_config_version_business_fk
  foreign key (config_version_id, business_id) references public.firm_config_versions(id, business_id);
alter table public.loyalty_redemptions add constraint loyalty_redemptions_config_version_business_fk
  foreign key (config_version_id, business_id) references public.firm_config_versions(id, business_id);
alter table public.reward_grants add constraint reward_grants_config_version_business_fk
  foreign key (config_version_id, business_id) references public.firm_config_versions(id, business_id);

-- v20 deliberately permits a narrowly scoped migration backfill on sales.
-- The two ledgers are otherwise absolutely append-only, so disable only their
-- named UPDATE/DELETE guards while assigning this new, derived provenance
-- column. The enclosing migration transaction guarantees the guards are
-- restored or the whole migration is rolled back.
select set_config('app.sales_backfill','v26_config_version',true);
update public.sales s set config_version_id = b.active_config_version_id
  from public.businesses b where b.id = s.business_id and s.config_version_id is null;
select set_config('app.sales_backfill','',true);

alter table public.points_ledger disable trigger trg_points_ledger_append_only;
update public.points_ledger x set config_version_id = b.active_config_version_id
  from public.businesses b where b.id = x.business_id and x.config_version_id is null;
alter table public.points_ledger enable trigger trg_points_ledger_append_only;

update public.points_batches x set config_version_id = b.active_config_version_id
  from public.businesses b where b.id = x.business_id and x.config_version_id is null;

alter table public.credit_ledger disable trigger trg_credit_ledger_append_only;
update public.credit_ledger x set config_version_id = b.active_config_version_id
  from public.businesses b where b.id = x.business_id and x.config_version_id is null;
alter table public.credit_ledger enable trigger trg_credit_ledger_append_only;

update public.loyalty_redemptions x set config_version_id = b.active_config_version_id
  from public.businesses b where b.id = x.business_id and x.config_version_id is null;
update public.reward_grants x set config_version_id = b.active_config_version_id
  from public.businesses b where b.id = x.business_id and x.config_version_id is null;

alter table public.firm_config_versions enable row level security;
alter table public.loyalty_program_versions enable row level security;
create policy firm_config_versions_read on public.firm_config_versions for select to authenticated
  using (app.is_salon_member(business_id));
create policy firm_config_versions_sa_read on public.firm_config_versions for select to authenticated
  using (app.is_super_admin());
create policy loyalty_program_versions_read on public.loyalty_program_versions for select to authenticated
  using (app.is_salon_member(business_id));
create policy loyalty_program_versions_sa_read on public.loyalty_program_versions for select to authenticated
  using (app.is_super_admin());
revoke all on public.firm_config_versions from public, anon, authenticated;
revoke all on public.loyalty_program_versions from public, anon, authenticated;
grant select on public.firm_config_versions, public.loyalty_program_versions to authenticated;

create or replace function app.active_config_version(p_business uuid)
returns uuid language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$ select active_config_version_id from public.businesses where id = p_business $$;
revoke execute on function app.active_config_version(uuid) from public, anon, authenticated;

create or replace function app.stamp_config_version()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_business uuid;
  v_version uuid;
  v_reversal_of uuid;
  v_sale_id uuid;
begin
  v_business := new.business_id;
  perform 1 from public.businesses where id = v_business for share;
  -- This trigger serves several tables. Convert NEW to jsonb before reading
  -- table-specific columns so records from the other tables never fail field
  -- resolution inside PL/pgSQL.
  if tg_table_name = 'sales' then
    v_reversal_of := nullif(to_jsonb(new) ->> 'reversal_of', '')::uuid;
  end if;
  if v_reversal_of is not null then
    select config_version_id into v_version from public.sales
     where id = v_reversal_of and business_id = v_business;
    if not found then raise exception 'reversal source sale not found'; end if;
    if new.config_version_id is null then new.config_version_id := v_version; end if;
    if new.config_version_id is distinct from v_version then
      raise exception 'reversal must retain the original sale config version'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;
  -- Ledger children linked to a sale inherit that sale's immutable version. This
  -- keeps compensating entries on the original contract after a later publish.
  if tg_table_name in ('points_ledger','points_batches','credit_ledger') then
    v_sale_id := nullif(to_jsonb(new) ->> 'sale_id', '')::uuid;
  end if;
  if v_sale_id is not null then
    select config_version_id into v_version from public.sales
     where id = v_sale_id and business_id = v_business;
    if not found then raise exception 'linked sale not found for config version'; end if;
    if new.config_version_id is null then new.config_version_id := v_version; end if;
    if new.config_version_id is distinct from v_version then
      raise exception 'ledger child must retain its linked sale config version'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;
  v_version := app.active_config_version(v_business);
  if new.config_version_id is null then new.config_version_id := v_version; end if;
  if new.config_version_id is distinct from v_version then
    raise exception 'event config version is not the locked active business version'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
revoke execute on function app.stamp_config_version() from public, anon, authenticated;

create trigger trg_sales_config_version before insert on public.sales
  for each row execute function app.stamp_config_version();
create trigger trg_points_ledger_config_version before insert on public.points_ledger
  for each row execute function app.stamp_config_version();
create trigger trg_points_batches_config_version before insert on public.points_batches
  for each row execute function app.stamp_config_version();
create trigger trg_credit_ledger_config_version before insert on public.credit_ledger
  for each row execute function app.stamp_config_version();
create trigger trg_loyalty_redemptions_config_version before insert on public.loyalty_redemptions
  for each row execute function app.stamp_config_version();
create trigger trg_reward_grants_config_version before insert on public.reward_grants
  for each row execute function app.stamp_config_version();

create or replace function app.loyalty_version_immutable_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_status text;
begin
  if tg_op = 'DELETE' then
    raise exception 'configuration versions are append-only' using errcode='restrict_violation';
  end if;
  select status into v_status from public.firm_config_versions
   where id = old.config_version_id;
  if v_status <> 'draft' then
    raise exception 'published configuration rows are immutable' using errcode='restrict_violation';
  end if;
  return new;
end $$;
revoke execute on function app.loyalty_version_immutable_guard() from public,anon,authenticated;
create trigger trg_loyalty_program_version_immutable
  before update or delete on public.loyalty_program_versions
  for each row execute function app.loyalty_version_immutable_guard();

create or replace function app.seed_loyalty_config_version()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_id uuid := gen_random_uuid(); v_status text := new.configuration_status;
begin
  if new.current_config_version_id is not null then return new; end if;
  insert into public.firm_config_versions(
    id,business_id,version_no,status,source,snapshot_hash,created_by,published_at
  ) values (
    v_id,new.business_id,1,v_status,coalesce(new.recommendation_source,'initial'),
    md5((to_jsonb(new)-'id'-'business_id'-'current_config_version_id')::text),
    auth.uid(),case when v_status='published' then now() end
  );
  insert into public.loyalty_program_versions (
    config_version_id,business_id,kind,loyalty_model,active,earn_points_per_dollar,
    redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,expiry_mode,expiry_days
  ) values (
    v_id,new.business_id,new.kind,new.loyalty_model,new.active,
    new.earn_points_per_dollar,new.redeem_points,new.reward_credit_cents,new.stamp_target,
    new.stamp_per_cents,new.tier_basis,new.expiry_mode,new.expiry_days
  );
  update public.loyalty_programs set current_config_version_id=v_id where id=new.id;
  if v_status='published' then
    update public.businesses set active_config_version_id=v_id where id=new.business_id;
  end if;
  return new;
end $$;
revoke execute on function app.seed_loyalty_config_version() from public,anon,authenticated;
create trigger trg_seed_loyalty_config_version
  after insert on public.loyalty_programs
  for each row execute function app.seed_loyalty_config_version();

create or replace function public.create_loyalty_config_draft(
  p_business uuid,
  p_based_on uuid default null,
  p_source text default 'manual'
)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_actor uuid := auth.uid(); v_base uuid; v_id uuid; v_no integer; v_typed public.loyalty_program_versions%rowtype;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode='42501'; end if;
  perform 1 from public.businesses where id = p_business for update;
  v_base := coalesce(p_based_on, app.active_config_version(p_business),
    (select current_config_version_id from public.loyalty_programs where business_id=p_business));
  select * into v_typed from public.loyalty_program_versions
   where config_version_id=v_base and business_id=p_business;
  if not found then raise exception 'base configuration not found'; end if;
  select coalesce(max(version_no),0)+1 into v_no from public.firm_config_versions where business_id=p_business;
  v_id := gen_random_uuid();
  insert into public.firm_config_versions
    (id,business_id,version_no,status,based_on_version_id,source,snapshot_hash,created_by)
  values (v_id,p_business,v_no,'draft',v_base,coalesce(nullif(btrim(p_source),''),'manual'),
    md5((to_jsonb(v_typed)-'config_version_id')::text),v_actor);
  insert into public.loyalty_program_versions (
    config_version_id,business_id,kind,loyalty_model,active,earn_points_per_dollar,
    redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,expiry_mode,expiry_days
  )
  select v_id,business_id,kind,loyalty_model,active,earn_points_per_dollar,
    redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,expiry_mode,expiry_days
    from public.loyalty_program_versions where config_version_id=v_base;
  insert into public.loyalty_tier_versions
    (tier_id,config_version_id,business_id,name,threshold,points_multiplier,perk_note,sort,active)
  select tier_id,v_id,business_id,name,threshold,points_multiplier,perk_note,sort,active
    from public.loyalty_tier_versions where config_version_id=v_base;
  return json_build_object('version_id',v_id,'version_no',v_no,'status','draft');
end $$;

create or replace function public.save_loyalty_config_draft(p_version uuid, p_config jsonb)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_header public.firm_config_versions%rowtype; v_typed public.loyalty_program_versions%rowtype; v_hash text;
begin
  select * into v_header from public.firm_config_versions where id=p_version for update;
  if not found or not app.is_salon_owner(v_header.business_id) then raise exception 'owner only' using errcode='42501'; end if;
  if v_header.status <> 'draft' then raise exception 'only a draft may be edited'; end if;
  select * into v_typed from public.loyalty_program_versions where config_version_id=p_version;
  update public.loyalty_program_versions set
    kind=coalesce(p_config->>'kind',v_typed.kind),
    loyalty_model=coalesce(p_config->>'loyalty_model',v_typed.loyalty_model),
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
  select md5((to_jsonb(x)-'config_version_id')::text) into v_hash
    from public.loyalty_program_versions x where config_version_id=p_version;
  update public.firm_config_versions set snapshot_hash=v_hash where id=p_version;
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
  if v_typed.active and v_typed.loyalty_model='stamps' and coalesce(v_typed.stamp_per_cents,0)<=0 then
    raise exception 'active stamps configuration requires spend per stamp' using errcode='check_violation';
  end if;
  select active_config_version_id into v_prior from public.businesses where id=v_header.business_id;
  update public.firm_config_versions set status='superseded',superseded_at=now()
   where id=v_prior and status='published';
  update public.firm_config_versions set status='published',published_at=now() where id=p_version;
  update public.businesses set active_config_version_id=p_version where id=v_header.business_id;
  update public.loyalty_programs set
    kind=v_typed.kind,loyalty_model=v_typed.loyalty_model,active=v_typed.active,
    earn_points_per_dollar=v_typed.earn_points_per_dollar,
    redeem_points=v_typed.redeem_points,reward_credit_cents=v_typed.reward_credit_cents,
    stamp_target=v_typed.stamp_target,stamp_per_cents=v_typed.stamp_per_cents,
    tier_basis=v_typed.tier_basis,expiry_mode=v_typed.expiry_mode,expiry_days=v_typed.expiry_days,
    configuration_status='published',current_config_version_id=p_version
   where business_id=v_header.business_id;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_header.business_id,auth.uid(),'PUBLISH_CONFIG','firm_config_versions',p_version,
    jsonb_build_object('prior_version_id',v_prior,'new_version_id',p_version,'snapshot_hash',v_header.snapshot_hash));
  return json_build_object('version_id',p_version,'version_no',v_header.version_no,'status','published');
end $$;

revoke all on function public.create_loyalty_config_draft(uuid,uuid,text) from public,anon;
revoke all on function public.save_loyalty_config_draft(uuid,jsonb) from public,anon;
revoke all on function public.publish_loyalty_config(uuid) from public,anon;
grant execute on function public.create_loyalty_config_draft(uuid,uuid,text) to authenticated;
grant execute on function public.save_loyalty_config_draft(uuid,jsonb) to authenticated;
grant execute on function public.publish_loyalty_config(uuid) to authenticated;

commit;
