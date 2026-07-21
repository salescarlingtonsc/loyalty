-- FRENLY v37b - VERSIONED RETENTION PROGRAMS AND SAFE TAXONOMY EDITING
--
-- Local review candidate. This migration is intentionally additive to v37's
-- branch-override RPC slice. It is not approved for production application.

begin;

-- retention_programs remains the stable identity and published compatibility
-- projection. All mutable rule values live in the version table below.
alter table public.retention_programs
  add column current_config_version_id uuid;
alter table public.retention_programs
  add constraint retention_programs_current_config_business_fk
  foreign key (current_config_version_id, business_id)
  references public.firm_config_versions(id, business_id) on delete restrict;

create table public.retention_program_versions (
  id uuid primary key default gen_random_uuid(),
  program_id uuid not null,
  config_version_id uuid not null,
  business_id uuid not null,
  name text not null check (char_length(btrim(name)) between 1 and 120),
  active boolean not null default true,
  goal_visits integer not null check (goal_visits > 0),
  period_days integer not null check (period_days > 0),
  starts_on date not null,
  reward_taxonomy_id uuid not null,
  fulfillment_kind text not null
    check (fulfillment_kind in ('discount_pct','free_item','credit')),
  discount_percent numeric,
  credit_cents integer,
  manual_item text,
  sort integer not null default 0 check (sort between 0 and 10000),
  customer_description text check (customer_description is null or char_length(customer_description) <= 1000),
  staff_description text check (staff_description is null or char_length(staff_description) <= 2000),
  created_at timestamptz not null default now(),
  constraint retention_program_versions_program_business_fk
    foreign key (program_id, business_id)
    references public.retention_programs(id, business_id) on delete restrict,
  constraint retention_program_versions_config_business_fk
    foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict,
  constraint retention_program_versions_taxonomy_business_fk
    foreign key (reward_taxonomy_id, business_id)
    references public.firm_reward_taxonomy(id, business_id) on delete restrict,
  constraint retention_program_versions_program_config_uk unique (program_id, config_version_id),
  constraint retention_program_versions_id_program_business_uk unique (id, program_id, business_id),
  constraint retention_program_versions_fulfillment_parameters_check check (
    (fulfillment_kind = 'discount_pct'
      and coalesce(discount_percent > 0 and discount_percent <= 100, false)
      and credit_cents is null and manual_item is null)
    or (fulfillment_kind = 'credit'
      and coalesce(credit_cents > 0, false)
      and discount_percent is null and manual_item is null)
    or (fulfillment_kind = 'free_item'
      and coalesce(char_length(btrim(manual_item)) >= 2, false)
      and discount_percent is null and credit_cents is null)
  )
);
create index retention_program_versions_config_idx
  on public.retention_program_versions(business_id, config_version_id, active, sort, program_id);

-- Before v37 retention was globally live rather than configuration-versioned.
-- Every pre-v37 config therefore receives the same exact live retention rules,
-- so cloning an actual historical version cannot silently lose the programme.
insert into public.retention_program_versions(
  program_id, config_version_id, business_id, name, active, goal_visits,
  period_days, starts_on, reward_taxonomy_id,
  fulfillment_kind, discount_percent, credit_cents, manual_item, sort
)
select rp.id, fv.id,
       rp.business_id, rp.name, rp.active, rp.goal_visits, rp.period_days,
       rp.starts_on, rp.reward_taxonomy_id, tax.fulfillment_kind,
       case when tax.fulfillment_kind='discount_pct' then rp.reward_value end,
       case when tax.fulfillment_kind='credit' then rp.reward_value::integer end,
       case when tax.fulfillment_kind='free_item' then rp.reward_item end,
       0
  from public.retention_programs rp
  join public.firm_config_versions fv on fv.business_id=rp.business_id
  join public.firm_reward_taxonomy tax
    on tax.id=rp.reward_taxonomy_id and tax.business_id=rp.business_id
;

update public.retention_programs rp
   set current_config_version_id=b.active_config_version_id
  from public.businesses b
 where b.id=rp.business_id;

alter table public.reward_grants
  add column retention_program_version_id uuid,
  add column period_start timestamptz,
  add column period_end timestamptz;
alter table public.reward_grants
  add constraint reward_grants_retention_version_business_fk
  foreign key (retention_program_version_id, program_id, business_id)
  references public.retention_program_versions(id, program_id, business_id) on delete restrict;

update public.reward_grants g
   set retention_program_version_id=rv.id,
       period_start=rv.starts_on::timestamptz
         + make_interval(days=>g.period_index*rv.period_days),
       period_end=rv.starts_on::timestamptz
         + make_interval(days=>(g.period_index+1)*rv.period_days)
  from public.retention_program_versions rv
 where rv.program_id=g.program_id
   and rv.business_id=g.business_id
   and rv.config_version_id=g.config_version_id;

do $require_complete_retention_grant_backfill$
begin
  if exists(select 1 from public.reward_grants
    where retention_program_version_id is null or period_start is null or period_end is null) then
    raise exception 'v37b cannot prove a retention version and real period for every historical reward grant';
  end if;
end $require_complete_retention_grant_backfill$;
alter table public.reward_grants
  alter column retention_program_version_id set not null,
  alter column period_start set not null,
  alter column period_end set not null,
  add constraint reward_grants_period_check check(period_end>period_start);
alter table public.reward_grants
  drop constraint if exists reward_grants_program_id_client_id_period_index_key;
alter table public.reward_grants
  add constraint reward_grants_program_client_window_uk
  unique(program_id,client_id,period_start,period_end);

-- Browser roles may read the published compatibility projection, but may not
-- mutate live rules or taxonomy identities directly.
drop policy if exists retention_all on public.retention_programs;
drop policy if exists retention_programs_all on public.retention_programs;
drop policy if exists retention_programs_write on public.retention_programs;
drop policy if exists retention_programs_read on public.retention_programs;
drop policy if exists retention_programs_sa_read on public.retention_programs;
create policy retention_programs_read on public.retention_programs
  for select to authenticated using (
    app.is_salon_member(business_id)
    and exists(
      select 1 from public.businesses b
       where b.id=retention_programs.business_id
         and b.active_config_version_id=retention_programs.current_config_version_id
    )
  );
create policy retention_programs_sa_read on public.retention_programs
  for select to authenticated using (app.is_super_admin());
revoke insert, update, delete, truncate on table public.retention_programs
  from public, anon, authenticated;

drop policy if exists firm_reward_taxonomy_write on public.firm_reward_taxonomy;
revoke insert, update, delete, truncate on table public.firm_reward_taxonomy
  from public, anon, authenticated;

-- v28 seeded only businesses that existed when that migration ran. Future
-- onboarding receives the same controlled starter vocabulary transactionally.
create or replace function app.seed_firm_reward_taxonomy()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  insert into public.firm_reward_taxonomy(business_id,label,fulfillment_kind,created_by,sort)
  values
    (new.id,'Percentage discount','discount_pct',auth.uid(),10),
    (new.id,'Free item or service','free_item',auth.uid(),20),
    (new.id,'Store credit','credit',auth.uid(),30)
  on conflict do nothing;
  return new;
end $$;
revoke all on function app.seed_firm_reward_taxonomy()
  from public,anon,authenticated;
create trigger trg_seed_firm_reward_taxonomy
  after insert on public.businesses
  for each row execute function app.seed_firm_reward_taxonomy();

alter table public.retention_program_versions enable row level security;
create policy retention_program_versions_owner_read on public.retention_program_versions
  for select to authenticated using (app.is_salon_owner(business_id));
create policy retention_program_versions_sa_read on public.retention_program_versions
  for select to authenticated using (app.is_super_admin());
revoke all on public.retention_program_versions from public, anon, authenticated;
grant select on public.retention_program_versions to authenticated;

create or replace function app.guard_retention_program_version()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_version uuid:=case when tg_op='DELETE' then old.config_version_id else new.config_version_id end;
        v_status text; v_tax public.firm_reward_taxonomy%rowtype;
begin
  select status into v_status from public.firm_config_versions where id=v_version;
  if v_status is distinct from 'draft' then
    raise exception 'published retention configuration is immutable'
      using errcode='restrict_violation';
  end if;
  if tg_op='DELETE' then return old; end if;
  if tg_op='UPDATE' and (
       new.program_id is distinct from old.program_id
       or new.config_version_id is distinct from old.config_version_id
       or new.business_id is distinct from old.business_id
     ) then
    raise exception 'retention version identity is immutable'
      using errcode='restrict_violation';
  end if;
  select * into v_tax from public.firm_reward_taxonomy
   where id=new.reward_taxonomy_id and business_id=new.business_id;
  if not found or (not v_tax.active and new.active) then
    raise exception 'retired reward types cannot be selected by new drafts'
      using errcode='check_violation';
  end if;
  new.fulfillment_kind:=v_tax.fulfillment_kind;
  return new;
end $$;
revoke all on function app.guard_retention_program_version()
  from public,anon,authenticated;
create trigger trg_guard_retention_program_version
  before insert or update or delete on public.retention_program_versions
  for each row execute function app.guard_retention_program_version();

-- Draft creation copies immutable economics. Taxonomy labels remain live,
-- non-economic display metadata and are deliberately absent from this clone.
create or replace function app.clone_retention_program_versions_on_draft()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if new.status='draft' and new.based_on_version_id is not null then
    insert into public.retention_program_versions(
      program_id,config_version_id,business_id,name,active,goal_visits,
      period_days,starts_on,reward_taxonomy_id,fulfillment_kind,
      discount_percent,credit_cents,manual_item,sort,
      customer_description,staff_description
    )
    select rv.program_id,new.id,new.business_id,rv.name,rv.active,rv.goal_visits,
           rv.period_days,rv.starts_on,rv.reward_taxonomy_id,t.fulfillment_kind,
           rv.discount_percent,rv.credit_cents,rv.manual_item,rv.sort,
           rv.customer_description,rv.staff_description
      from public.retention_program_versions rv
      join public.firm_reward_taxonomy t
        on t.id=rv.reward_taxonomy_id and t.business_id=rv.business_id
     where rv.config_version_id=new.based_on_version_id
       and rv.business_id=new.business_id;
  end if;
  return new;
end $$;
revoke all on function app.clone_retention_program_versions_on_draft()
  from public,anon,authenticated;
create trigger trg_clone_retention_program_versions_on_draft
  after insert on public.firm_config_versions
  for each row execute function app.clone_retention_program_versions_on_draft();

-- Extend the deterministic configuration evidence with retention rules.
create or replace function app.refresh_loyalty_config_snapshot(p_version uuid)
returns void language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_snapshot jsonb;
begin
  select jsonb_build_object(
    'program',(select to_jsonb(lp)-'config_version_id' from public.loyalty_program_versions lp where lp.config_version_id=p_version),
    'tiers',coalesce((select jsonb_agg(to_jsonb(tv)-'id'-'config_version_id'-'business_id'-'created_at' order by tv.threshold,tv.sort,tv.tier_id) from public.loyalty_tier_versions tv where tv.config_version_id=p_version),'[]'::jsonb),
    'rewards',coalesce((select jsonb_agg(jsonb_build_object(
      'reward',to_jsonb(rv)-'id'-'config_version_id'-'business_id'-'created_at',
      'branches',coalesce((select jsonb_agg(e.branch_id order by e.branch_id) from public.loyalty_reward_branches e where e.reward_version_id=rv.id),'[]'::jsonb),
      'services',coalesce((select jsonb_agg(e.service_id order by e.service_id) from public.loyalty_reward_services e where e.reward_version_id=rv.id),'[]'::jsonb),
      'products',coalesce((select jsonb_agg(e.product_id order by e.product_id) from public.loyalty_reward_products e where e.reward_version_id=rv.id),'[]'::jsonb)
    ) order by rv.reward_id) from public.loyalty_reward_versions rv where rv.config_version_id=p_version),'[]'::jsonb),
    'branch_overrides',coalesce((select jsonb_agg(to_jsonb(o)-'config_version_id'-'business_id'-'created_at'-'updated_at' order by o.branch_id) from public.loyalty_branch_overrides o where o.config_version_id=p_version),'[]'::jsonb),
    'retention_programs',coalesce((select jsonb_agg(to_jsonb(r)-'id'-'config_version_id'-'business_id'-'created_at' order by r.sort,r.program_id) from public.retention_program_versions r where r.config_version_id=p_version),'[]'::jsonb)
  ) into v_snapshot;
  update public.firm_config_versions set snapshot_hash=md5(v_snapshot::text) where id=p_version;
end $$;
revoke all on function app.refresh_loyalty_config_snapshot(uuid)
  from public,anon,authenticated;

create or replace function app.refresh_v37_retention_snapshot_trigger()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  perform app.refresh_loyalty_config_snapshot(case when tg_op='DELETE' then old.config_version_id else new.config_version_id end);
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
revoke all on function app.refresh_v37_retention_snapshot_trigger()
  from public,anon,authenticated;
create trigger trg_retention_program_versions_snapshot
  after insert or update or delete on public.retention_program_versions
  for each row execute function app.refresh_v37_retention_snapshot_trigger();

do $refresh_v37_snapshots$
declare v_id uuid;
begin
  for v_id in select id from public.firm_config_versions loop
    perform app.refresh_loyalty_config_snapshot(v_id);
  end loop;
end $refresh_v37_snapshots$;

create or replace function public.get_retention_config_draft(p_config_version uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_header public.firm_config_versions%rowtype; v_result jsonb;
begin
  select * into v_header from public.firm_config_versions
   where id=p_config_version for share;
  if not found or not app.is_salon_owner(v_header.business_id) then
    raise exception 'owner only' using errcode='42501';
  end if;
  if v_header.status<>'draft' then
    raise exception 'only a draft retention configuration may be read' using errcode='42501';
  end if;
  perform 1 from public.businesses where id=v_header.business_id for share;
  select jsonb_build_object(
    'config_version_id',v_header.id,'business_id',v_header.business_id,
    'version_no',v_header.version_no,'status',v_header.status,
    'snapshot_hash',v_header.snapshot_hash,
    'programs',coalesce((select jsonb_agg(jsonb_build_object(
      'retention_program_version_id',r.id,'program_id',r.program_id,
      'name',r.name,'active',r.active,'goal_visits',r.goal_visits,
      'period_days',r.period_days,'starts_on',r.starts_on,
      'reward_taxonomy_id',r.reward_taxonomy_id,'reward_label',t.label,
      'fulfillment_kind',r.fulfillment_kind,
      'discount_percent',r.discount_percent,'credit_cents',r.credit_cents,
      'manual_item',r.manual_item,'sort',r.sort,
      'customer_description',r.customer_description,'staff_description',r.staff_description
    ) order by r.sort,r.program_id) from public.retention_program_versions r
      join public.firm_reward_taxonomy t
        on t.id=r.reward_taxonomy_id and t.business_id=r.business_id
      where r.config_version_id=v_header.id and r.business_id=v_header.business_id),'[]'::jsonb),
    'taxonomy',coalesce((select jsonb_agg(jsonb_build_object(
      'id',t.id,'label',t.label,'fulfillment_kind',t.fulfillment_kind,
      'active',t.active,'sort',t.sort
    ) order by t.sort,t.label,t.id) from public.firm_reward_taxonomy t
      where t.business_id=v_header.business_id),'[]'::jsonb)
  ) into v_result;
  return v_result;
end $$;

create or replace function public.save_retention_program_draft(
  p_config_version uuid,
  p_program_id uuid,
  p_program jsonb,
  p_expected_snapshot_hash text default null
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_header public.firm_config_versions%rowtype; v_existing public.retention_program_versions%rowtype;
  v_tax public.firm_reward_taxonomy%rowtype; v_program_id uuid:=p_program_id;
  v_id uuid; v_hash text; v_name text; v_active boolean; v_goal integer; v_period integer;
  v_starts date; v_tax_id uuid; v_discount numeric; v_credit integer; v_item text;
  v_sort integer; v_customer text; v_staff text;
begin
  if p_program_id is null then
    raise exception 'a stable program id is required for retry-safe creation' using errcode='22023';
  end if;
  if p_program is null or jsonb_typeof(p_program)<>'object' then
    raise exception 'retention program must be a JSON object' using errcode='22023';
  end if;
  if exists(select 1 from jsonb_object_keys(p_program) k where k not in(
    'name','active','goal_visits','period_days','starts_on','reward_taxonomy_id',
    'discount_percent','credit_cents','manual_item','sort','customer_description','staff_description'
  )) then raise exception 'retention program contains unsupported fields' using errcode='22023'; end if;
  select * into v_header from public.firm_config_versions where id=p_config_version for update;
  if not found or not app.is_salon_owner(v_header.business_id) then raise exception 'owner only' using errcode='42501'; end if;
  if v_header.status<>'draft' then raise exception 'only a draft retention program may be edited' using errcode='42501'; end if;
  perform 1 from public.businesses where id=v_header.business_id for share;
  if p_expected_snapshot_hash is null then
    raise exception 'expected snapshot hash is required' using errcode='22023';
  end if;
  select * into v_existing from public.retention_program_versions
   where program_id=v_program_id and config_version_id=p_config_version and business_id=v_header.business_id;
  if v_existing.id is null and exists(select 1 from public.retention_programs where id=p_program_id) then
    if exists(select 1 from public.retention_programs where id=p_program_id and business_id<>v_header.business_id) then
      raise exception 'retention program does not belong to this business' using errcode='42501';
    end if;
    raise exception 'retention program is not part of this draft' using errcode='22023';
  end if;
  v_name:=coalesce(nullif(btrim(p_program->>'name'),''),v_existing.name);
  v_active:=case when p_program?'active' then (p_program->>'active')::boolean else coalesce(v_existing.active,true) end;
  v_goal:=case when p_program?'goal_visits' then (p_program->>'goal_visits')::integer else v_existing.goal_visits end;
  v_period:=case when p_program?'period_days' then (p_program->>'period_days')::integer else v_existing.period_days end;
  v_starts:=case when p_program?'starts_on' then (p_program->>'starts_on')::date else coalesce(v_existing.starts_on,current_date) end;
  v_tax_id:=case when p_program?'reward_taxonomy_id' then (p_program->>'reward_taxonomy_id')::uuid else v_existing.reward_taxonomy_id end;
  v_discount:=case when p_program?'discount_percent' then nullif(p_program->>'discount_percent','')::numeric else v_existing.discount_percent end;
  v_credit:=case when p_program?'credit_cents' then nullif(p_program->>'credit_cents','')::integer else v_existing.credit_cents end;
  v_item:=case when p_program?'manual_item' then nullif(btrim(p_program->>'manual_item'),'') else v_existing.manual_item end;
  v_sort:=case when p_program?'sort' then (p_program->>'sort')::integer else coalesce(v_existing.sort,0) end;
  v_customer:=case when p_program?'customer_description' then nullif(btrim(p_program->>'customer_description'),'') else v_existing.customer_description end;
  v_staff:=case when p_program?'staff_description' then nullif(btrim(p_program->>'staff_description'),'') else v_existing.staff_description end;
  if v_name is null or v_goal is null or v_goal<=0 or v_period is null or v_period<=0 or v_tax_id is null then
    raise exception 'name, positive goal/period, and reward taxonomy are required' using errcode='22023';
  end if;
  select * into v_tax from public.firm_reward_taxonomy where id=v_tax_id and business_id=v_header.business_id and active;
  if not found then raise exception 'reward taxonomy is missing, retired, or belongs to another business' using errcode='22023'; end if;
  if (v_tax.fulfillment_kind='discount_pct' and not(coalesce(v_discount,0)>0 and v_discount<=100))
     or (v_tax.fulfillment_kind='credit' and coalesce(v_credit,0)<=0)
     or (v_tax.fulfillment_kind='free_item' and char_length(coalesce(v_item,''))<2) then
    raise exception 'retention reward parameters do not match the immutable fulfillment kind' using errcode='22023';
  end if;
  if v_tax.fulfillment_kind<>'discount_pct' then v_discount:=null; end if;
  if v_tax.fulfillment_kind<>'credit' then v_credit:=null; end if;
  if v_tax.fulfillment_kind<>'free_item' then v_item:=null; end if;
  if v_header.snapshot_hash is distinct from p_expected_snapshot_hash then
    if v_existing.id is not null
       and (v_existing.name,v_existing.active,v_existing.goal_visits,v_existing.period_days,
            v_existing.starts_on,v_existing.reward_taxonomy_id,v_existing.discount_percent,
            v_existing.credit_cents,v_existing.manual_item,v_existing.sort,
            v_existing.customer_description,v_existing.staff_description)
           is not distinct from
           (v_name,v_active,v_goal,v_period,v_starts,v_tax.id,v_discount,v_credit,v_item,
            v_sort,v_customer,v_staff) then
      return jsonb_build_object('program_id',v_program_id,
        'retention_program_version_id',v_existing.id,'config_version_id',p_config_version,
        'status','draft','snapshot_hash',v_header.snapshot_hash,'replayed',true);
    end if;
    raise exception 'draft configuration changed; reload before saving' using errcode='40001';
  end if;
  if v_existing.id is null then
    insert into public.retention_programs(
      id,business_id,name,goal_visits,period_days,reward_taxonomy_id,reward_type,
      reward_value,reward_item,starts_on,active,current_config_version_id
    ) values(v_program_id,v_header.business_id,v_name,v_goal,v_period,v_tax.id,v_tax.fulfillment_kind,
      coalesce(v_discount,v_credit,0),v_item,v_starts,false,null);
  end if;
  insert into public.retention_program_versions(
    program_id,config_version_id,business_id,name,active,goal_visits,period_days,
    starts_on,reward_taxonomy_id,fulfillment_kind,
    discount_percent,credit_cents,manual_item,sort,customer_description,staff_description
  ) values(v_program_id,p_config_version,v_header.business_id,v_name,v_active,v_goal,v_period,
    v_starts,v_tax.id,v_tax.fulfillment_kind,v_discount,v_credit,v_item,v_sort,v_customer,v_staff)
  on conflict(program_id,config_version_id) do update set
    name=excluded.name,active=excluded.active,goal_visits=excluded.goal_visits,
    period_days=excluded.period_days,starts_on=excluded.starts_on,
    reward_taxonomy_id=excluded.reward_taxonomy_id,
    fulfillment_kind=excluded.fulfillment_kind,discount_percent=excluded.discount_percent,
    credit_cents=excluded.credit_cents,manual_item=excluded.manual_item,sort=excluded.sort,
    customer_description=excluded.customer_description,staff_description=excluded.staff_description
  returning id into v_id;
  perform app.refresh_loyalty_config_snapshot(p_config_version);
  select snapshot_hash into v_hash from public.firm_config_versions where id=p_config_version;
  return jsonb_build_object('program_id',v_program_id,'retention_program_version_id',v_id,
    'config_version_id',p_config_version,'status','draft','snapshot_hash',v_hash,'replayed',false);
end $$;

create or replace function public.save_reward_taxonomy(
  p_business uuid,
  p_taxonomy_id uuid,
  p_taxonomy jsonb
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_row public.firm_reward_taxonomy%rowtype; v_id uuid:=coalesce(p_taxonomy_id,gen_random_uuid());
  v_label text; v_kind text; v_active boolean; v_sort integer;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode='42501'; end if;
  perform 1 from public.businesses where id=p_business for update;
  if p_taxonomy is null or jsonb_typeof(p_taxonomy)<>'object' then raise exception 'taxonomy must be a JSON object' using errcode='22023'; end if;
  if exists(select 1 from jsonb_object_keys(p_taxonomy) k where k not in('label','fulfillment_kind','active','sort')) then
    raise exception 'taxonomy contains unsupported fields' using errcode='22023';
  end if;
  if p_taxonomy_id is not null then
    select * into v_row from public.firm_reward_taxonomy where id=p_taxonomy_id and business_id=p_business for update;
    if not found then raise exception 'taxonomy does not belong to this business' using errcode='42501'; end if;
  end if;
  v_label:=coalesce(nullif(btrim(p_taxonomy->>'label'),''),v_row.label);
  v_kind:=coalesce(nullif(p_taxonomy->>'fulfillment_kind',''),v_row.fulfillment_kind);
  v_active:=case when p_taxonomy?'active' then (p_taxonomy->>'active')::boolean else coalesce(v_row.active,true) end;
  v_sort:=case when p_taxonomy?'sort' then (p_taxonomy->>'sort')::integer else coalesce(v_row.sort,0) end;
  if v_label is null or char_length(v_label) not between 2 and 80
     or v_kind not in('discount_pct','free_item','credit') or v_sort not between 0 and 10000 then
    raise exception 'invalid taxonomy values' using errcode='22023';
  end if;
  if p_taxonomy_id is not null and v_kind is distinct from v_row.fulfillment_kind then
    raise exception 'reward fulfillment behavior is immutable; create a new reward type' using errcode='23001';
  end if;
  if p_taxonomy_id is not null and not v_active and exists(
    select 1
      from public.retention_program_versions rv
      join public.businesses b
        on b.id=rv.business_id and b.active_config_version_id=rv.config_version_id
     where rv.business_id=p_business
       and rv.reward_taxonomy_id=p_taxonomy_id
       and rv.active
  ) then
    raise exception 'publish a replacement or disable the live retention program before retiring this taxonomy'
      using errcode='23514';
  end if;
  insert into public.firm_reward_taxonomy(id,business_id,label,fulfillment_kind,active,sort,created_by)
  values(v_id,p_business,v_label,v_kind,v_active,v_sort,auth.uid())
  on conflict(id) do update set label=excluded.label,active=excluded.active,sort=excluded.sort;
  return jsonb_build_object('id',v_id,'label',v_label,'fulfillment_kind',v_kind,'active',v_active,'sort',v_sort);
end $$;

-- Snapshot grants against the exact retention version chosen by the sale's
-- stamped config, never against today's compatibility projection.
create or replace function app.snapshot_reward_grant_taxonomy()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_rule public.retention_program_versions%rowtype;
  v_tax public.firm_reward_taxonomy%rowtype;
  v_period_start timestamptz; v_period_end timestamptz;
begin
  perform 1 from public.businesses where id=new.business_id for share;
  select * into v_rule from public.retention_program_versions
   where program_id=new.program_id and business_id=new.business_id
     and config_version_id=new.config_version_id;
  if not found then raise exception 'retention program version not found for stamped configuration'; end if;
  select * into v_tax from public.firm_reward_taxonomy
   where id=v_rule.reward_taxonomy_id and business_id=v_rule.business_id;
  if not found then raise exception 'retention reward taxonomy not found'; end if;
  if new.retention_program_version_id is not null and new.retention_program_version_id<>v_rule.id then
    raise exception 'reward grant retention version does not match its stamped configuration' using errcode='23514';
  end if;
  if new.period_index<0 then raise exception 'retention grant period index cannot be negative' using errcode='23514'; end if;
  v_period_start:=v_rule.starts_on::timestamptz+make_interval(days=>new.period_index*v_rule.period_days);
  v_period_end:=v_period_start+make_interval(days=>v_rule.period_days);
  if new.period_start is not null and new.period_start is distinct from v_period_start
     or new.period_end is not null and new.period_end is distinct from v_period_end then
    raise exception 'reward grant period does not match its immutable retention version' using errcode='23514';
  end if;
  -- Version publication is configuration history, not financial idempotency.
  -- Serialize the stable programme/customer scope and reject every overlapping
  -- real-world [period_start,period_end) window across all config versions.
  perform pg_advisory_xact_lock(hashtextextended(
    new.business_id::text||':'||new.program_id::text||':'||new.client_id::text,0));
  if exists(
    select 1 from public.reward_grants g
     where g.business_id=new.business_id and g.program_id=new.program_id
       and g.client_id=new.client_id and g.id<>new.id
       and g.period_start<v_period_end and v_period_start<g.period_end
  ) then
    raise exception 'retention reward already granted for an overlapping programme window'
      using errcode='23505';
  end if;
  new.retention_program_version_id:=v_rule.id;
  new.period_start:=v_period_start;
  new.period_end:=v_period_end;
  new.reward_taxonomy_id:=v_rule.reward_taxonomy_id;
  new.reward_label:=v_tax.label;
  new.fulfillment_kind:=v_rule.fulfillment_kind;
  new.reward_type:=v_rule.fulfillment_kind;
  new.reward_value:=coalesce(v_rule.discount_percent,v_rule.credit_cents,0);
  new.reward_item:=v_rule.manual_item;
  new.reward_snapshot:=jsonb_build_object(
    'legacy',false,'program_id',v_rule.program_id,
    'retention_program_version_id',v_rule.id,'config_version_id',v_rule.config_version_id,
    'name',v_rule.name,'goal_visits',v_rule.goal_visits,'period_days',v_rule.period_days,
    'starts_on',v_rule.starts_on,'period_start',v_period_start,'period_end',v_period_end,
    'reward_taxonomy_id',v_rule.reward_taxonomy_id,
    'reward_label',v_tax.label,'fulfillment_kind',v_rule.fulfillment_kind,
    'discount_percent',v_rule.discount_percent,'credit_cents',v_rule.credit_cents,
    'manual_item',v_rule.manual_item
  );
  return new;
end $$;
revoke all on function app.snapshot_reward_grant_taxonomy()
  from public,anon,authenticated;

-- v27 deliberately allowed status transitions, but its original guard did not
-- yet know the full v28/v37 provenance. Only status may change after issuance.
create or replace function app.reward_grant_snapshot_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if tg_op='INSERT' then
    if new.reward_snapshot is null then
      raise exception 'retention grant snapshot is required' using errcode='23514';
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
     or new.retention_program_version_id is distinct from old.retention_program_version_id
     or new.reward_taxonomy_id is distinct from old.reward_taxonomy_id
     or new.reward_label is distinct from old.reward_label
     or new.fulfillment_kind is distinct from old.fulfillment_kind
     or new.reward_snapshot is distinct from old.reward_snapshot then
    raise exception 'reward grant identity, economics, window and provenance are immutable'
      using errcode='23001';
  end if;
  return new;
end $$;
revoke all on function app.reward_grant_snapshot_guard()
  from public,anon,authenticated;

-- Publish remains one transaction. The business UPDATE lock serializes against
-- the sales BEFORE trigger's business SHARE lock, then the compatibility
-- projection is advanced atomically with every other typed configuration row.
create or replace function public.publish_loyalty_config(p_version uuid)
returns json language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_header public.firm_config_versions%rowtype; v_typed public.loyalty_program_versions%rowtype; v_prior uuid;
begin
  select * into v_header from public.firm_config_versions where id=p_version for update;
  if not found or not app.is_salon_owner(v_header.business_id) then raise exception 'owner only' using errcode='42501'; end if;
  if v_header.status<>'draft' then raise exception 'only a draft may be published'; end if;
  perform 1 from public.businesses where id=v_header.business_id for update;
  select * into v_typed from public.loyalty_program_versions where config_version_id=p_version;
  if v_typed.active and v_typed.loyalty_model='stamps' and coalesce(v_typed.stamp_per_cents,0)<=0 then raise exception 'active stamps configuration requires spend per stamp' using errcode='23514'; end if;
  if exists(select 1 from public.retention_program_versions rv left join public.firm_reward_taxonomy t on t.id=rv.reward_taxonomy_id and t.business_id=rv.business_id where rv.config_version_id=p_version and rv.business_id=v_header.business_id and rv.active and coalesce(t.active,false)=false) then
    raise exception 'active retention programs cannot publish a retired taxonomy' using errcode='23514';
  end if;
  perform app.refresh_loyalty_config_snapshot(p_version);
  select * into v_header from public.firm_config_versions where id=p_version;
  select active_config_version_id into v_prior from public.businesses where id=v_header.business_id;
  update public.firm_config_versions set status='superseded',superseded_at=now() where id=v_prior and status='published';
  update public.firm_config_versions set status='published',published_at=now() where id=p_version;
  update public.businesses set active_config_version_id=p_version where id=v_header.business_id;
  update public.loyalty_programs set kind=v_typed.kind,loyalty_model=v_typed.loyalty_model,active=v_typed.active,earn_points_per_dollar=v_typed.earn_points_per_dollar,redeem_points=v_typed.redeem_points,reward_credit_cents=v_typed.reward_credit_cents,stamp_target=v_typed.stamp_target,stamp_per_cents=v_typed.stamp_per_cents,tier_basis=v_typed.tier_basis,expiry_mode=v_typed.expiry_mode,expiry_days=v_typed.expiry_days,configuration_status='published',current_config_version_id=p_version where business_id=v_header.business_id;
  update public.loyalty_rewards r set name=rv.customer_name,internal_name=rv.internal_name,customer_name=rv.customer_name,description=rv.description,fulfillment_kind=rv.fulfillment_kind,taxonomy_label=rv.taxonomy_label,cost_points=rv.cost_points,credit_cents=rv.credit_cents,estimated_cost_cents=rv.estimated_cost_cents,active=rv.active,sort=rv.sort,claim_available_from=rv.claim_available_from,claim_available_until=rv.claim_available_until,entitlement_expiry_days=rv.entitlement_expiry_days,instructions=rv.instructions,terms=rv.terms,image_ref=rv.image_ref,usage_limit=rv.usage_limit,current_config_version_id=p_version from public.loyalty_reward_versions rv where rv.reward_id=r.id and rv.business_id=r.business_id and rv.config_version_id=p_version;
  delete from public.loyalty_tiers where business_id=v_header.business_id;
  insert into public.loyalty_tiers(id,business_id,name,threshold,points_multiplier,perk_note,sort) select tier_id,business_id,name,threshold,points_multiplier,perk_note,sort from public.loyalty_tier_versions where config_version_id=p_version and business_id=v_header.business_id and active;
  update public.retention_programs rp set
    name=rv.name,active=rv.active,goal_visits=rv.goal_visits,period_days=rv.period_days,
    starts_on=rv.starts_on,reward_taxonomy_id=rv.reward_taxonomy_id,
    reward_type=rv.fulfillment_kind,reward_value=coalesce(rv.discount_percent,rv.credit_cents,0),
    reward_item=rv.manual_item,current_config_version_id=p_version
  from public.retention_program_versions rv
  where rv.program_id=rp.id and rv.business_id=rp.business_id
    and rv.config_version_id=p_version and rp.business_id=v_header.business_id;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_header.business_id,auth.uid(),'PUBLISH_CONFIG','firm_config_versions',p_version,
    jsonb_build_object('prior_version_id',v_prior,'new_version_id',p_version,'snapshot_hash',v_header.snapshot_hash));
  return json_build_object('version_id',p_version,'version_no',v_header.version_no,'status','published');
end $$;

-- Sale retention resolves only the immutable rule rows belonging to the sale's
-- already-stamped version. All legacy points/referral behavior is retained.
create or replace function app.on_sale_recorded()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare lp record; rp record; refrow record; refprog record; v_tier public.loyalty_tiers%rowtype;
  v_pts integer; v_idx integer; v_count integer; v_earn_id uuid; v_credit_id uuid;
  w_start timestamptz; w_end timestamptz;
begin
  if new.reversal_of is not null or new.client_id is null or not(new.earns_points or new.counts_as_visit) then return new; end if;
  if new.earns_points then
    select * into lp from app.resolve_loyalty_branch_config(new.business_id,new.branch_id,new.config_version_id);
    if found and lp.active then
      if lp.loyalty_model='stamps' then v_pts:=case when coalesce(lp.stamp_per_cents,0)>0 then floor(new.amount_cents::numeric/lp.stamp_per_cents) else 0 end;
      elsif lp.kind='points' then v_pts:=floor((new.amount_cents/100.0)*lp.earn_points_per_dollar); else v_pts:=0; end if;
      select * into v_tier from app.loyalty_tier_for(new.business_id,new.client_id);
      if v_tier.id is not null and v_tier.points_multiplier>1 then v_pts:=floor(v_pts*v_tier.points_multiplier); end if;
      if v_pts>0 then
        v_earn_id:=gen_random_uuid(); perform set_config('app.points_ledger_insert_id',v_earn_id::text,true); perform set_config('app.points_ledger_write_scope','sale_trigger',true);
        insert into public.points_ledger(id,business_id,client_id,entry_type,points,sale_id,reference,actor) values(v_earn_id,new.business_id,new.client_id,'earn',v_pts,new.id,'auto-earn on sale',auth.uid()) on conflict do nothing returning id into v_earn_id;
        perform set_config('app.points_ledger_insert_id','',true); perform set_config('app.points_ledger_write_scope','',true);
        if v_earn_id is not null then insert into public.points_batches(business_id,client_id,earned,remaining,sale_id,earned_at,expires_at) values(new.business_id,new.client_id,v_pts,v_pts,new.id,now(),case when lp.expiry_mode='fixed' then now()+make_interval(days=>lp.expiry_days) end); end if;
      end if;
    end if;
  end if;
  if new.counts_as_visit then
    for rp in select * from public.retention_program_versions where business_id=new.business_id and config_version_id=new.config_version_id and active loop
      v_idx:=floor(extract(epoch from(new.occurred_at-rp.starts_on::timestamptz))/(rp.period_days*86400));
      if v_idx>=0 then
        w_start:=rp.starts_on::timestamptz+make_interval(days=>v_idx*rp.period_days); w_end:=w_start+make_interval(days=>rp.period_days);
        select count(*) into v_count from public.sales s where s.business_id=new.business_id and s.client_id=new.client_id and s.counts_as_visit and s.reversal_of is null and not exists(select 1 from public.sales r where r.business_id=s.business_id and r.reversal_of=s.id) and s.occurred_at>=w_start and s.occurred_at<w_end;
        if v_count>=rp.goal_visits then
          begin
            insert into public.reward_grants(business_id,program_id,client_id,period_index,reward_type,reward_value,reward_item,config_version_id,retention_program_version_id)
            values(new.business_id,rp.program_id,new.client_id,v_idx,rp.fulfillment_kind,coalesce(rp.discount_percent,rp.credit_cents,0),rp.manual_item,new.config_version_id,rp.id);
            if rp.fulfillment_kind='credit' and rp.credit_cents>0 then
              v_credit_id:=gen_random_uuid(); perform set_config('app.credit_ledger_insert_id',v_credit_id::text,true); perform set_config('app.credit_ledger_write_scope','sale_trigger',true);
              insert into public.credit_ledger(id,business_id,client_id,entry_type,amount_cents,reference,sale_id,actor) values(v_credit_id,new.business_id,new.client_id,'loyalty_earn',rp.credit_cents,'retention reward: '||rp.name,new.id,auth.uid());
              perform set_config('app.credit_ledger_insert_id','',true); perform set_config('app.credit_ledger_write_scope','',true);
            end if;
          exception when unique_violation then null; end;
        end if;
      end if;
    end loop;
    select r.* into refrow from public.referrals r where r.business_id=new.business_id and r.referred_client_id=new.client_id and r.status='pending' limit 1;
    if found then
      select * into refprog from public.referral_programs where business_id=new.business_id and enabled limit 1;
      if found and new.amount_cents>=coalesce(refprog.min_spend_cents,0) then
        update public.referrals set status='rewarded',qualified_at=now(),qualified_sale_id=new.id,reward_cents=refprog.reward_cents where id=refrow.id and status='pending';
        if found then
          v_credit_id:=gen_random_uuid(); perform set_config('app.credit_ledger_insert_id',v_credit_id::text,true); perform set_config('app.credit_ledger_write_scope','sale_trigger',true);
          insert into public.credit_ledger(id,business_id,client_id,entry_type,amount_cents,reference,sale_id,actor) values(v_credit_id,new.business_id,refrow.referrer_client_id,'referral_reward',refprog.reward_cents,'referral qualified: first visit completed',new.id,auth.uid());
          perform set_config('app.credit_ledger_insert_id','',true); perform set_config('app.credit_ledger_write_scope','',true);
        end if;
      end if;
    end if;
  end if;
  return new;
end $$;

revoke all on function public.get_retention_config_draft(uuid) from public,anon;
revoke all on function public.save_retention_program_draft(uuid,uuid,jsonb,text) from public,anon;
revoke all on function public.save_reward_taxonomy(uuid,uuid,jsonb) from public,anon;
grant execute on function public.get_retention_config_draft(uuid) to authenticated;
grant execute on function public.save_retention_program_draft(uuid,uuid,jsonb,text) to authenticated;
grant execute on function public.save_reward_taxonomy(uuid,uuid,jsonb) to authenticated;
revoke all on function public.publish_loyalty_config(uuid) from public,anon;
grant execute on function public.publish_loyalty_config(uuid) to authenticated;
revoke all on function app.on_sale_recorded() from public,anon,authenticated;

commit;
