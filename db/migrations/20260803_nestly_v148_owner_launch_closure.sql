-- PEEKAA v148 - OWNER LAUNCH CLOSURE (FORWARD-PORTED V143 TIER CONTRACT)
--
-- Forward-only local candidate. Reward claim windows already exist and are
-- enforced by the redemption kernel. This migration gives tiers the same
-- exclusive window, bounded owner/customer RPCs, and editable Gold, Platinum
-- and Diamond starter drafts. No production action is authorized by this file.

begin;

alter table public.loyalty_tier_versions
  add column effective_from timestamptz,
  add column expires_at timestamptz;

alter table public.loyalty_tier_versions
  add constraint loyalty_tier_versions_effective_window_check
  check (expires_at is null or effective_from is null or expires_at>effective_from);

alter table public.loyalty_tiers
  add column effective_from timestamptz,
  add column expires_at timestamptz;

alter table public.loyalty_tiers
  add constraint loyalty_tiers_effective_window_check
  check (expires_at is null or effective_from is null or expires_at>effective_from);

create index loyalty_tiers_effective_business_idx
  on public.loyalty_tiers(business_id,effective_from,expires_at,threshold);

-- C45's draft clone predates tier windows. Replace it after the new columns
-- exist so a scheduled or ended published tier does not silently become
-- unbounded in the next editable draft.
create or replace function public.create_loyalty_config_draft(
  p_business uuid,
  p_based_on uuid default null,
  p_source text default 'manual'
)
returns json language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_base uuid;
  v_id uuid;
  v_no integer;
  v_typed public.loyalty_program_versions%rowtype;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  perform 1 from public.businesses where id=p_business for update;
  v_base:=coalesce(
    p_based_on,
    app.active_config_version(p_business),
    (select current_config_version_id from public.loyalty_programs where business_id=p_business)
  );
  select * into v_typed from public.loyalty_program_versions
  where config_version_id=v_base and business_id=p_business;
  if not found then raise exception 'base configuration not found'; end if;
  select coalesce(max(version_no),0)+1 into v_no
  from public.firm_config_versions where business_id=p_business;
  v_id:=gen_random_uuid();
  insert into public.firm_config_versions(
    id,business_id,version_no,status,based_on_version_id,source,snapshot_hash,created_by
  ) values(
    v_id,p_business,v_no,'draft',v_base,
    coalesce(nullif(btrim(p_source),''),'manual'),
    md5((to_jsonb(v_typed)-'config_version_id')::text),v_actor
  );
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,stamp_target,
    stamp_per_cents,tier_basis,expiry_mode,expiry_days
  )
  select v_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,stamp_target,
    stamp_per_cents,tier_basis,expiry_mode,expiry_days
  from public.loyalty_program_versions where config_version_id=v_base;
  insert into public.loyalty_tier_versions(
    tier_id,config_version_id,business_id,name,threshold,points_multiplier,
    perk_note,sort,active,effective_from,expires_at
  )
  select tier_id,v_id,business_id,name,threshold,points_multiplier,
    perk_note,sort,active,effective_from,expires_at
  from public.loyalty_tier_versions where config_version_id=v_base;
  perform app.refresh_loyalty_config_snapshot(v_id);
  return json_build_object('version_id',v_id,'version_no',v_no,'status','draft');
end
$$;

revoke all on function public.create_loyalty_config_draft(uuid,uuid,text)
  from public,anon;
grant execute on function public.create_loyalty_config_draft(uuid,uuid,text)
  to authenticated;

create table app.loyalty_tier_default_operations_v143(
  operation_id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  actor_id uuid not null,
  idempotency_key uuid not null,
  request_hash text not null check(request_hash~'^[0-9a-f]{32}$'),
  config_version_id uuid not null references public.firm_config_versions(id),
  result_snapshot jsonb not null,
  created_at timestamptz not null default now(),
  unique(business_id,actor_id,idempotency_key)
);

revoke all on table app.loyalty_tier_default_operations_v143
  from public,anon,authenticated;

create or replace function app.v143_immutable_tier_default_operation()
returns trigger
language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  raise exception 'tier default operation evidence is immutable' using errcode='55000';
end
$$;

revoke all on function app.v143_immutable_tier_default_operation()
  from public,anon,authenticated;

create trigger loyalty_tier_default_operations_v143_immutable
before update or delete on app.loyalty_tier_default_operations_v143
for each row execute function app.v143_immutable_tier_default_operation();

create or replace function app.v143_project_tier_window()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  select version.effective_from,version.expires_at
    into new.effective_from,new.expires_at
  from public.businesses business
  join public.loyalty_tier_versions version
    on version.business_id=business.id
   and version.config_version_id=business.active_config_version_id
   and version.tier_id=new.id
  where business.id=new.business_id;
  return new;
end
$$;

revoke all on function app.v143_project_tier_window()
  from public,anon,authenticated;

create trigger loyalty_tiers_v143_window_projection
before insert or update on public.loyalty_tiers
for each row execute function app.v143_project_tier_window();

create or replace function public.save_loyalty_tier_draft_v143(
  p_version uuid,
  p_tier jsonb,
  p_expected_snapshot_hash text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_header public.firm_config_versions%rowtype;
  v_tier_id uuid;
  v_effective_from timestamptz;
  v_expires_at timestamptz;
  v_hash text;
begin
  if p_tier is null or jsonb_typeof(p_tier)<>'object' then
    raise exception 'tier must be an object' using errcode='22023';
  end if;
  if exists(
    select 1 from jsonb_object_keys(p_tier) field
    where field not in (
      'id','name','threshold','points_multiplier','perk_note','sort','active',
      'effective_from','expires_at'
    )
  ) then
    raise exception 'tier contains unsupported fields' using errcode='22023';
  end if;

  select * into v_header
  from public.firm_config_versions
  where id=p_version
  for update;
  if not found or not app.c45_owner_loyalty_write(v_header.business_id) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if v_header.status<>'draft' then
    raise exception 'only a draft may be edited' using errcode='55000';
  end if;
  if p_expected_snapshot_hash is not null
     and v_header.snapshot_hash is distinct from p_expected_snapshot_hash then
    raise exception 'draft configuration changed; reload before saving'
      using errcode='40001';
  end if;

  begin
    v_tier_id:=coalesce(nullif(p_tier->>'id','')::uuid,gen_random_uuid());
    v_effective_from:=nullif(p_tier->>'effective_from','')::timestamptz;
    v_expires_at:=nullif(p_tier->>'expires_at','')::timestamptz;
  exception when others then
    raise exception 'tier identifiers and effective boundaries must be valid'
      using errcode='22023';
  end;
  if nullif(btrim(p_tier->>'name'),'') is null
     or coalesce((p_tier->>'threshold')::integer,-1)<0
     or coalesce((p_tier->>'points_multiplier')::numeric,0)<1 then
    raise exception 'tier requires a name, non-negative threshold and multiplier of at least 1'
      using errcode='22023';
  end if;
  if v_expires_at is not null and v_effective_from is not null
     and v_expires_at<=v_effective_from then
    raise exception 'tier expiration must be after its effective time'
      using errcode='22023';
  end if;

  insert into public.loyalty_tier_versions(
    tier_id,config_version_id,business_id,name,threshold,points_multiplier,
    perk_note,sort,active,effective_from,expires_at
  ) values(
    v_tier_id,p_version,v_header.business_id,btrim(p_tier->>'name'),
    (p_tier->>'threshold')::integer,(p_tier->>'points_multiplier')::numeric,
    nullif(btrim(p_tier->>'perk_note'),''),coalesce((p_tier->>'sort')::integer,0),
    coalesce((p_tier->>'active')::boolean,true),v_effective_from,v_expires_at
  )
  on conflict(tier_id,config_version_id) do update set
    name=excluded.name,
    threshold=excluded.threshold,
    points_multiplier=excluded.points_multiplier,
    perk_note=excluded.perk_note,
    sort=excluded.sort,
    active=excluded.active,
    effective_from=excluded.effective_from,
    expires_at=excluded.expires_at;

  perform app.refresh_loyalty_config_snapshot(p_version);
  select snapshot_hash into v_hash
  from public.firm_config_versions
  where id=p_version;
  return jsonb_build_object(
    'version_id',p_version,'tier_id',v_tier_id,'status','draft',
    'snapshot_hash',v_hash,'effective_from',v_effective_from,'expires_at',v_expires_at
  );
end
$$;

revoke all on function public.save_loyalty_tier_draft_v143(uuid,jsonb,text)
  from public,anon,authenticated;
grant execute on function public.save_loyalty_tier_draft_v143(uuid,jsonb,text)
  to authenticated;

create or replace function public.add_recommended_loyalty_tiers_v143(
  p_business uuid,
  p_version uuid,
  p_basis text,
  p_expected_snapshot_hash text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_request_hash text;
  v_operation app.loyalty_tier_default_operations_v143%rowtype;
  v_header public.firm_config_versions%rowtype;
  v_version uuid:=p_version;
  v_created_draft boolean:=false;
  v_draft jsonb;
  v_snapshot_hash text;
  v_tier_ids jsonb:='[]'::jsonb;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated owner required' using errcode='28000';
  end if;
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode='22023';
  end if;
  p_basis:=lower(btrim(coalesce(p_basis,'')));
  if p_basis not in ('visits','spend','points_earned') then
    raise exception 'tier basis must be visits, spend or points earned' using errcode='22023';
  end if;
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;

  v_request_hash:=md5(jsonb_build_object(
    'business_id',p_business,
    'version_id',p_version,
    'basis',p_basis,
    'expected_snapshot_hash',p_expected_snapshot_hash
  )::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v148-tier-defaults:'||p_business::text||':'||v_actor::text||':'||p_idempotency_key::text,0
  ));
  perform 1 from public.businesses where id=p_business for update;
  if not found then raise exception 'business not found' using errcode='22023'; end if;

  select * into v_operation
  from app.loyalty_tier_default_operations_v143
  where business_id=p_business and actor_id=v_actor and idempotency_key=p_idempotency_key
  for update;
  if found then
    if v_operation.request_hash<>v_request_hash then
      raise exception 'idempotency key conflicts with changed tier defaults'
        using errcode='22023';
    end if;
    return v_operation.result_snapshot;
  end if;

  if v_version is null then
    select version.id into v_version
    from public.firm_config_versions version
    where version.business_id=p_business and version.status='draft'
    order by version.version_no desc,version.id
    limit 1;
    if v_version is null then
      v_draft:=public.create_loyalty_config_draft(
        p_business,
        (select active_config_version_id from public.businesses where id=p_business),
        'recommended_tiers_v148'
      )::jsonb;
      v_version:=(v_draft->>'version_id')::uuid;
      v_created_draft:=true;
    end if;
  end if;

  select * into v_header from public.firm_config_versions
  where id=v_version for update;
  if not found or v_header.business_id<>p_business
     or not app.c45_owner_loyalty_write(v_header.business_id) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if v_header.status<>'draft' then
    raise exception 'only a draft may receive recommended tiers' using errcode='55000';
  end if;
  if p_expected_snapshot_hash is not null
     and v_header.snapshot_hash is distinct from p_expected_snapshot_hash then
    raise exception 'draft configuration changed; reload before adding tiers'
      using errcode='40001';
  end if;

  if exists(
    select 1 from public.loyalty_tier_versions
    where business_id=p_business and config_version_id=v_version
  ) then
    select coalesce(jsonb_agg(tier_id order by threshold,sort,tier_id),'[]'::jsonb)
      into v_tier_ids
    from public.loyalty_tier_versions
    where business_id=p_business and config_version_id=v_version;
    v_result:=jsonb_build_object(
      'version_id',v_version,'tier_ids',v_tier_ids,'status','existing_tiers',
      'snapshot_hash',v_header.snapshot_hash,'created_draft',v_created_draft,
      'published',false,'replayed',false
    );
  else
    with templates(name,threshold,points_multiplier,perk_note,sort) as (
      values
        ('Gold',0::integer,1::numeric,'Standard points earning',0),
        ('Platinum',case when p_basis='visits' then 5 else 500 end::integer,
          1.25::numeric,'25% more points',1),
        ('Diamond',case when p_basis='visits' then 12 else 1500 end::integer,
          1.5::numeric,'50% more points',2)
    ), inserted as (
      insert into public.loyalty_tier_versions(
        tier_id,config_version_id,business_id,name,threshold,points_multiplier,
        perk_note,sort,active,effective_from,expires_at
      )
      select gen_random_uuid(),v_version,p_business,name,threshold,
        points_multiplier,perk_note,sort,true,null,null
      from templates
      returning tier_id,threshold,sort
    )
    select coalesce(jsonb_agg(tier_id order by threshold,sort,tier_id),'[]'::jsonb)
      into v_tier_ids from inserted;
    perform app.refresh_loyalty_config_snapshot(v_version);
    select snapshot_hash into v_snapshot_hash
    from public.firm_config_versions where id=v_version;
    v_result:=jsonb_build_object(
      'version_id',v_version,'tier_ids',v_tier_ids,'status','draft_ready',
      'snapshot_hash',v_snapshot_hash,'created_draft',v_created_draft,
      'published',false,'replayed',false
    );
  end if;

  insert into app.loyalty_tier_default_operations_v143(
    business_id,actor_id,idempotency_key,request_hash,config_version_id,result_snapshot
  ) values(
    p_business,v_actor,p_idempotency_key,v_request_hash,v_version,v_result
  );
  return v_result;
end
$$;

revoke all on function public.add_recommended_loyalty_tiers_v143(uuid,uuid,text,text,uuid)
  from public,anon,authenticated;
grant execute on function public.add_recommended_loyalty_tiers_v143(uuid,uuid,text,text,uuid)
  to authenticated;

create or replace function app.loyalty_tier_for(p_business uuid,p_client uuid)
returns public.loyalty_tiers
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_basis text;
  v_metric numeric;
  v_row public.loyalty_tiers%rowtype;
begin
  select tier_basis into v_basis
  from public.loyalty_programs
  where business_id=p_business;
  v_basis:=coalesce(v_basis,'visits');
  if v_basis='visits' then
    select count(*) into v_metric from public.sales
    where business_id=p_business and client_id=p_client and counts_as_visit;
  elsif v_basis='spend' then
    select coalesce(sum(amount_cents),0)/100.0 into v_metric from public.sales
    where business_id=p_business and client_id=p_client and counts_as_revenue;
  else
    select coalesce(sum(points),0) into v_metric from public.points_ledger
    where business_id=p_business and client_id=p_client and entry_type='earn';
  end if;
  select * into v_row from public.loyalty_tiers
  where business_id=p_business
    and threshold<=v_metric
    and (effective_from is null or effective_from<=statement_timestamp())
    and (expires_at is null or expires_at>statement_timestamp())
  order by threshold desc,sort desc,id
  limit 1;
  return v_row;
end
$$;

revoke all on function app.loyalty_tier_for(uuid,uuid)
  from public,anon,authenticated;

create or replace function public.business_get_loyalty_tiers_v143(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(version)-'id'-'config_version_id'-'business_id'-'created_at'
      order by version.threshold,version.sort,version.tier_id)
    from public.businesses business
    join public.loyalty_tier_versions version
      on version.business_id=business.id
     and version.config_version_id=business.active_config_version_id
    where business.id=p_business
  ),'[]'::jsonb);
end
$$;

revoke all on function public.business_get_loyalty_tiers_v143(uuid)
  from public,anon,authenticated;
grant execute on function public.business_get_loyalty_tiers_v143(uuid)
  to authenticated;

create or replace function public.customer_get_effective_tier_v143(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_identity uuid;
  v_client uuid;
  v_basis text;
  v_metric numeric:=0;
  v_current public.loyalty_tiers%rowtype;
  v_next public.loyalty_tiers%rowtype;
  v_progress numeric:=0;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode='28000';
  end if;
  v_identity:=app.v31_current_identity();
  select link.client_id into v_client
  from public.customer_links link
  where link.identity_id=v_identity
    and link.auth_user_id=auth.uid()
    and link.business_id=p_business
    and link.state='verified';
  if not found then
    raise exception 'verified customer link required' using errcode='42501';
  end if;
  if not app.business_module_enabled_at_v117(p_business,'loyalty',null)
     or not exists(
       select 1 from public.loyalty_programs
       where business_id=p_business and active
     ) then
    raise exception 'loyalty module is unavailable for this business' using errcode='42501';
  end if;

  select coalesce(tier_basis,'visits') into v_basis
  from public.loyalty_programs
  where business_id=p_business and active
  limit 1;
  if v_basis='spend' then
    select coalesce(sum(amount_cents),0)/100.0 into v_metric from public.sales
    where business_id=p_business and client_id=v_client and counts_as_revenue;
  elsif v_basis='points_earned' then
    select coalesce(sum(points),0) into v_metric from public.points_ledger
    where business_id=p_business and client_id=v_client and entry_type='earn';
  else
    select count(*) into v_metric from public.sales
    where business_id=p_business and client_id=v_client and counts_as_visit;
  end if;

  select * into v_current from public.loyalty_tiers
  where business_id=p_business
    and threshold<=v_metric
    and (effective_from is null or effective_from<=statement_timestamp())
    and (expires_at is null or expires_at>statement_timestamp())
  order by threshold desc,sort desc,id limit 1;
  select * into v_next from public.loyalty_tiers
  where business_id=p_business
    and threshold>coalesce(v_current.threshold,-1)
    and (effective_from is null or effective_from<=statement_timestamp())
    and (expires_at is null or expires_at>statement_timestamp())
  order by threshold,sort,id limit 1;
  if v_next.id is not null then
    v_progress:=greatest(0,least(100,round(
      (v_metric-coalesce(v_current.threshold,0))*100
      /nullif(v_next.threshold-coalesce(v_current.threshold,0),0),2
    )));
  elsif v_current.id is not null then
    v_progress:=100;
  end if;

  return jsonb_build_object('tier',jsonb_build_object(
    'label',v_current.name,
    'current',case when v_current.id is null then null else jsonb_build_object(
      'id',v_current.id,'label',v_current.name,'threshold',v_current.threshold,
      'metric',v_metric,'benefits',coalesce((
        select jsonb_agg(btrim(benefit) order by ordinal)
        from regexp_split_to_table(coalesce(v_current.perk_note,''),E'\\r?\\n')
          with ordinality as item(benefit,ordinal)
        where btrim(benefit)<>''
      ),'[]'::jsonb)
    ) end,
    'next',case when v_next.id is null then null else jsonb_build_object(
      'id',v_next.id,'label',v_next.name,'threshold',v_next.threshold,
      'benefits',coalesce((
        select jsonb_agg(btrim(benefit) order by ordinal)
        from regexp_split_to_table(coalesce(v_next.perk_note,''),E'\\r?\\n')
          with ordinality as item(benefit,ordinal)
        where btrim(benefit)<>''
      ),'[]'::jsonb)
    ) end,
    'progress_percent',v_progress,'basis',v_basis,'metric',v_metric
  ));
end
$$;

revoke all on function public.customer_get_effective_tier_v143(uuid)
  from public,anon,authenticated;
grant execute on function public.customer_get_effective_tier_v143(uuid)
  to authenticated;

commit;
