-- FRENLY v35 - EXPLAINABLE RETENTION RECOMMENDATION DRAFTS
-- Local review candidate. Recommendations are optional drafts, never live rules.

begin;

create table public.retention_recommendation_runs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  idempotency_key text not null check (length(btrim(idempotency_key)) >= 8),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{32}$'),
  status text not null check (status in ('generating','draft_ready')),
  input_metrics jsonb not null check (jsonb_typeof(input_metrics)='object'),
  recommendation jsonb,
  draft_config_version_id uuid,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint retention_recommendation_runs_idempotency_uk
    unique (business_id,idempotency_key),
  constraint retention_recommendation_runs_draft_business_fk
    foreign key (draft_config_version_id,business_id)
    references public.firm_config_versions(id,business_id) on delete restrict,
  constraint retention_recommendation_runs_state_check check (
    (status='generating' and recommendation is null and draft_config_version_id is null and completed_at is null)
    or (status='draft_ready' and recommendation is not null and draft_config_version_id is not null and completed_at is not null)
  )
);
alter table public.retention_recommendation_runs enable row level security;
create policy retention_recommendation_runs_owner_read
  on public.retention_recommendation_runs for select to authenticated
  using (app.is_salon_owner(business_id));
create policy retention_recommendation_runs_sa_read
  on public.retention_recommendation_runs for select to authenticated
  using (app.is_super_admin());
revoke all on public.retention_recommendation_runs from public,anon,authenticated;
grant select on public.retention_recommendation_runs to authenticated;

create or replace function app.retention_recommendation_run_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if tg_op='DELETE' then
    raise exception 'recommendation runs are immutable evidence' using errcode='restrict_violation';
  end if;
  if old.status='draft_ready' or new.business_id is distinct from old.business_id
     or new.idempotency_key is distinct from old.idempotency_key
     or new.request_hash is distinct from old.request_hash
     or new.input_metrics is distinct from old.input_metrics
     or new.created_by is distinct from old.created_by then
    raise exception 'completed recommendation runs are immutable' using errcode='restrict_violation';
  end if;
  return new;
end $$;
revoke execute on function app.retention_recommendation_run_guard() from public,anon,authenticated;
create trigger trg_retention_recommendation_run_guard
  before update or delete on public.retention_recommendation_runs
  for each row execute function app.retention_recommendation_run_guard();

create or replace function public.generate_retention_recommendation(
  p_business uuid,
  p_idempotency_key text
)
returns json language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid(); v_run public.retention_recommendation_runs%rowtype;
  v_business public.businesses%rowtype; v_base uuid; v_draft json; v_draft_id uuid;
  v_service_count integer; v_product_count integer; v_branch_count integer;
  v_avg_service integer; v_avg_product integer; v_reference_price integer;
  v_model text; v_stamp_cents integer; v_reward_cost integer;
  v_metrics jsonb; v_recommendation jsonb; v_rows integer;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode='42501'; end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode='22023';
  end if;
  p_idempotency_key:=btrim(p_idempotency_key);
  select * into v_business from public.businesses where id=p_business for update;
  if not found then raise exception 'business not found'; end if;

  select count(*)::integer,coalesce(round(avg(price_cents)),0)::integer
    into v_service_count,v_avg_service from public.services
   where business_id=p_business and active;
  select count(*)::integer,coalesce(round(avg(retail_price_cents)),0)::integer
    into v_product_count,v_avg_product from public.products
   where business_id=p_business and active;
  select count(*)::integer into v_branch_count from public.branches
   where business_id=p_business and active;
  v_reference_price:=case when v_avg_service>0 and v_avg_product>0 then round((v_avg_service+v_avg_product)/2.0)
                          else greatest(v_avg_service,v_avg_product,1000) end;
  v_metrics:=jsonb_build_object(
    'industry',coalesce(v_business.industry,'other'),'active_services',v_service_count,
    'active_products',v_product_count,'active_branches',v_branch_count,
    'average_service_cents',v_avg_service,'average_product_cents',v_avg_product,
    'reference_price_cents',v_reference_price
  );
  insert into public.retention_recommendation_runs(
    business_id,idempotency_key,request_hash,status,input_metrics,created_by
  ) values(p_business,p_idempotency_key,md5(v_metrics::text),'generating',v_metrics,v_actor)
  on conflict(business_id,idempotency_key) do nothing;
  get diagnostics v_rows=row_count;
  if v_rows=0 then
    select * into v_run from public.retention_recommendation_runs
     where business_id=p_business and idempotency_key=p_idempotency_key for update;
    if v_run.request_hash<>md5(v_metrics::text) then
      raise exception 'idempotency key conflicts with changed business inputs' using errcode='22023';
    end if;
    if v_run.status='draft_ready' then return v_run.recommendation::json; end if;
    raise exception 'recommendation is already being generated' using errcode='55P03';
  end if;

  -- These are transparent starting heuristics, not platform rules. The owner
  -- sees and edits every number before an explicit publication.
  v_model:=case when v_business.industry in ('fnb','food_beverage','cafe','restaurant') then 'stamps'
                when v_business.industry in ('salon','spa','fitness','retail') then 'points_tiers'
                else 'classic' end;
  v_stamp_cents:=greatest(100,round((v_reference_price/2.0)/100.0)::integer*100);
  v_reward_cost:=greatest(5,case when v_model='stamps' then 8
                                 else ceil((v_reference_price/100.0)*5)::integer end);
  select coalesce(v_business.active_config_version_id,lp.current_config_version_id)
    into v_base from public.loyalty_programs lp where lp.business_id=p_business;
  if v_base is null then raise exception 'loyalty draft is missing for this business'; end if;
  v_draft:=public.create_loyalty_config_draft(p_business,v_base,'catalog_recommendation');
  v_draft_id:=(v_draft->>'version_id')::uuid;
  perform public.save_loyalty_config_draft(v_draft_id,jsonb_build_object(
    'kind','points','active',false,'loyalty_model',v_model,
    'earn_points_per_dollar',1,'redeem_points',greatest(100,v_reward_cost),
    'reward_credit_cents',0,'stamp_per_cents',case when v_model='stamps' then v_stamp_cents else null end,
    'expiry_mode','none','expiry_days',null
  ));
  if v_model in ('stamps','points_tiers') then
    perform public.save_loyalty_config_draft(v_draft_id,jsonb_build_object(
      'reward',jsonb_build_object(
        'business_id',p_business,'name','Recommended return reward',
        'customer_name','A thank-you on your next visits',
        'description','Suggested starting benefit. Replace this with an item or service that fits your margins.',
        'fulfillment_kind','manual_item','cost_points',v_reward_cost,'credit_cents',0,
        'estimated_cost_cents',0,'active',true,'usage_limit',null
      ),'reward_branch_ids','[]'::jsonb,'reward_service_ids','[]'::jsonb,'reward_product_ids','[]'::jsonb
    ));
  end if;
  v_recommendation:=jsonb_build_object(
    'run_id',(select id from public.retention_recommendation_runs where business_id=p_business and idempotency_key=p_idempotency_key),
    'draft_config_version_id',v_draft_id,'status','draft_ready','published',false,
    'model',v_model,'reference_price_cents',v_reference_price,
    'suggested_spend_per_stamp_cents',case when v_model='stamps' then v_stamp_cents else null end,
    'suggested_reward_cost',case when v_model in ('stamps','points_tiers') then v_reward_cost else null end,
    'rationale',case when v_model='stamps' then 'Frequent-purchase catalog: a visible stamp goal is simple at the counter.'
                     when v_model='points_tiers' then 'Repeat-service catalog: flexible rewards preserve margin and support progression.'
                     else 'Limited catalog signal: start with simple points and review after real sales history.' end,
    'input_metrics',v_metrics
  );
  update public.retention_recommendation_runs set status='draft_ready',
    recommendation=v_recommendation,draft_config_version_id=v_draft_id,completed_at=now()
   where business_id=p_business and idempotency_key=p_idempotency_key;
  return v_recommendation::json;
end $$;
revoke all on function public.generate_retention_recommendation(uuid,text) from public,anon;
grant execute on function public.generate_retention_recommendation(uuid,text) to authenticated;

commit;
