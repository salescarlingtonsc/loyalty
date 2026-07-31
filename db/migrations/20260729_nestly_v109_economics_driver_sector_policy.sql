-- NESTLY v109 — TRACEABLE ECONOMICS, RECONCILING DRIVERS & SECTOR POLICY
--
-- Adds three deliberately bounded decision-support contracts:
--   1. effective-dated, source-referenced cost rules and coverage-gated economics;
--   2. deterministic revenue-driver decomposition whose rounded parts reconcile;
--   3. versioned sector policies with evidence, fallback, suppression and audited
--      owner overrides.
--
-- No profit or ROI is returned unless every eligible sale has a traceable cost
-- rule. Sector defaults are starting policies, never universal churn claims.

begin;

insert into app.platform_feature_flags(feature_key,enabled)
values('economics_driver_policy_v109',false)
on conflict(feature_key) do nothing;

create table public.economic_cost_rules_v109(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  branch_id uuid,
  scope_kind text not null check(scope_kind in ('sale_kind','product')),
  scope_key text not null check(length(btrim(scope_key)) between 1 and 120),
  cost_method text not null check(cost_method in ('revenue_bps','fixed_per_unit')),
  cost_value bigint not null check(cost_value>=0),
  currency text not null check(currency ~ '^[A-Z]{3}$'),
  source_type text not null check(source_type in (
    'supplier_invoice','supplier_contract','accounting_import','owner_attestation'
  )),
  source_reference text not null check(length(btrim(source_reference)) between 3 and 500),
  evidence jsonb not null default '{}'::jsonb check(jsonb_typeof(evidence)='object'),
  effective_from timestamptz not null,
  effective_to timestamptz,
  version_no integer not null check(version_no>0),
  created_by uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  request_hash text not null check(request_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  constraint economic_cost_rules_v109_branch_business_fk
    foreign key(branch_id,business_id)
    references public.branches(id,business_id) on delete restrict,
  constraint economic_cost_rules_v109_window_check
    check(effective_to is null or effective_to>effective_from),
  constraint economic_cost_rules_v109_method_check check(
    (cost_method='revenue_bps' and cost_value between 0 and 10000)
    or (cost_method='fixed_per_unit' and cost_value between 0 and 100000000)
  ),
  constraint economic_cost_rules_v109_scope_check check(
    (scope_kind='sale_kind' and scope_key in (
      'service','retail','membership','quick_sale','gift_card','package'
    ))
    or (scope_kind='product' and scope_key ~
      '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
  ),
  constraint economic_cost_rules_v109_actor_idem_uk
    unique(business_id,created_by,idempotency_key),
  constraint economic_cost_rules_v109_version_uk
    unique nulls not distinct(
      business_id,branch_id,scope_kind,scope_key,version_no
    )
);

create index economic_cost_rules_v109_match_idx
  on public.economic_cost_rules_v109(
    business_id,scope_kind,scope_key,effective_from desc
  );

create table public.sector_policy_versions_v109(
  id uuid primary key default gen_random_uuid(),
  sector_key text not null check(sector_key ~ '^[a-z][a-z0-9_]{1,39}$'),
  policy_key text not null check(policy_key='lapse_detection'),
  version_no integer not null check(version_no>0),
  effective_from timestamptz not null,
  effective_to timestamptz,
  status text not null check(status in ('published','retired')),
  evidence_basis jsonb not null check(jsonb_typeof(evidence_basis)='array'),
  parameters jsonb not null check(jsonb_typeof(parameters)='object'),
  fallback_policy jsonb not null check(jsonb_typeof(fallback_policy)='object'),
  suppression_rules jsonb not null check(jsonb_typeof(suppression_rules)='array'),
  limitations jsonb not null check(jsonb_typeof(limitations)='array'),
  created_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint sector_policy_versions_v109_window_check
    check(effective_to is null or effective_to>effective_from),
  constraint sector_policy_versions_v109_version_uk
    unique(sector_key,policy_key,version_no)
);

create index sector_policy_versions_v109_effective_idx
  on public.sector_policy_versions_v109(
    sector_key,policy_key,effective_from desc
  ) where status='published';

create table public.business_sector_policy_overrides_v109(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  policy_key text not null check(policy_key='lapse_detection'),
  base_policy_id uuid not null
    references public.sector_policy_versions_v109(id) on delete restrict,
  version_no integer not null check(version_no>0),
  override_parameters jsonb not null check(jsonb_typeof(override_parameters)='object'),
  reason text not null check(length(btrim(reason)) between 3 and 1000),
  effective_from timestamptz not null,
  effective_to timestamptz,
  created_by uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  request_hash text not null check(request_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  constraint business_sector_policy_overrides_v109_window_check
    check(effective_to is null or effective_to>effective_from),
  constraint business_sector_policy_overrides_v109_version_uk
    unique(business_id,policy_key,version_no),
  constraint business_sector_policy_overrides_v109_actor_idem_uk
    unique(business_id,created_by,idempotency_key)
);

create index business_sector_policy_overrides_v109_effective_idx
  on public.business_sector_policy_overrides_v109(
    business_id,policy_key,effective_from desc
  );

insert into public.sector_policy_versions_v109(
  sector_key,policy_key,version_no,effective_from,status,
  evidence_basis,parameters,fallback_policy,suppression_rules,limitations
) values
(
  'fnb','lapse_detection',1,'2026-07-29 00:00:00+00','published',
  jsonb_build_array(
    'Nestly pilot starting policy; validate against each firm''s observed visit cadence',
    'No external benchmark or universal churn probability is asserted'
  ),
  '{"minimum_prior_visits":4,"cadence_multiplier":1.75,"minimum_lapse_days":14,"minimum_audience":20}'::jsonb,
  '{"when":"individual_cadence_unavailable","action":"use_sector_minimum_only_after_minimum_history"}'::jsonb,
  '["insufficient_history","low_identity_coverage","audience_below_minimum"]'::jsonb,
  '["meal and beverage occasions vary by concept and location","owner must review before activation"]'::jsonb
),(
  'facial','lapse_detection',1,'2026-07-29 00:00:00+00','published',
  jsonb_build_array(
    'Nestly pilot starting policy; treatment intervals must be checked against each firm''s services',
    'No universal salon or spa churn threshold is asserted'
  ),
  '{"minimum_prior_visits":3,"cadence_multiplier":1.50,"minimum_lapse_days":30,"minimum_audience":20}'::jsonb,
  '{"when":"individual_cadence_unavailable","action":"suppress_until_service_history_is_sufficient"}'::jsonb,
  '["insufficient_history","unknown_service_cadence","low_identity_coverage","audience_below_minimum"]'::jsonb,
  '["service plans and treatment cycles differ","owner must review before activation"]'::jsonb
),(
  'salon','lapse_detection',1,'2026-07-29 00:00:00+00','published',
  jsonb_build_array(
    'Nestly pilot starting policy; haircut and treatment cadence must be learned per firm',
    'No universal salon churn threshold is asserted'
  ),
  '{"minimum_prior_visits":3,"cadence_multiplier":1.60,"minimum_lapse_days":28,"minimum_audience":20}'::jsonb,
  '{"when":"individual_cadence_unavailable","action":"suppress_until_service_history_is_sufficient"}'::jsonb,
  '["insufficient_history","unknown_service_cadence","low_identity_coverage","audience_below_minimum"]'::jsonb,
  '["appointment type materially changes cadence","owner must review before activation"]'::jsonb
),(
  'fitness','lapse_detection',1,'2026-07-29 00:00:00+00','published',
  jsonb_build_array(
    'Nestly pilot starting policy; attendance cadence is learned from the firm''s own visits',
    'No universal fitness churn probability is asserted'
  ),
  '{"minimum_prior_visits":5,"cadence_multiplier":2.00,"minimum_lapse_days":14,"minimum_audience":20}'::jsonb,
  '{"when":"individual_cadence_unavailable","action":"suppress_until_attendance_history_is_sufficient"}'::jsonb,
  '["insufficient_history","membership_state_unknown","low_identity_coverage","audience_below_minimum"]'::jsonb,
  '["class packs and memberships need separate interpretation","owner must review before activation"]'::jsonb
),(
  'retail','lapse_detection',1,'2026-07-29 00:00:00+00','published',
  jsonb_build_array(
    'Nestly pilot starting policy; repeat-purchase cadence is learned from firm history',
    'No universal retail churn threshold is asserted'
  ),
  '{"minimum_prior_visits":3,"cadence_multiplier":2.00,"minimum_lapse_days":30,"minimum_audience":20}'::jsonb,
  '{"when":"individual_cadence_unavailable","action":"suppress_until_repeat_purchase_history_is_sufficient"}'::jsonb,
  '["insufficient_history","product_cycle_unknown","low_identity_coverage","audience_below_minimum"]'::jsonb,
  '["replenishment cycles differ by assortment","owner must review before activation"]'::jsonb
),(
  'massage','lapse_detection',1,'2026-07-29 00:00:00+00','published',
  jsonb_build_array(
    'Nestly pilot starting policy; treatment cadence is learned from the firm''s own completed visits',
    'No universal massage or wellness churn threshold is inferred'
  ),
  '{"minimum_prior_visits":3,"cadence_multiplier":1.50,"minimum_lapse_days":30,"minimum_audience":20}'::jsonb,
  '{"when":"individual_cadence_unavailable","action":"suppress_until_service_history_is_sufficient"}'::jsonb,
  '["insufficient_history","unknown_service_cadence","low_identity_coverage","audience_below_minimum"]'::jsonb,
  '["treatment plans and service cadence differ","owner must review before activation"]'::jsonb
),(
  'other','lapse_detection',1,'2026-07-29 00:00:00+00','published',
  jsonb_build_array(
    'Fallback registry entry; firm-specific cadence evidence is required',
    'No cross-sector churn number is supplied'
  ),
  '{"minimum_prior_visits":4,"cadence_multiplier":2.00,"minimum_lapse_days":30,"minimum_audience":20}'::jsonb,
  '{"when":"individual_cadence_unavailable","action":"do_not_classify"}'::jsonb,
  '["insufficient_history","sector_not_specialized","low_identity_coverage","audience_below_minimum"]'::jsonb,
  '["use only until a reviewed sector policy exists","owner must review before activation"]'::jsonb
);

alter table public.economic_cost_rules_v109 enable row level security;
alter table public.sector_policy_versions_v109 enable row level security;
alter table public.business_sector_policy_overrides_v109 enable row level security;

create policy economic_cost_rules_v109_select
  on public.economic_cost_rules_v109 for select to authenticated
  using(
    app.is_super_admin()
    or (
      app.has_perm(business_id,'view_finance')
      and app.can_see_branch(business_id,branch_id)
    )
  );
create policy sector_policy_versions_v109_select
  on public.sector_policy_versions_v109 for select to authenticated
  using(auth.uid() is not null);
create policy business_sector_policy_overrides_v109_select
  on public.business_sector_policy_overrides_v109 for select to authenticated
  using(
    app.is_super_admin()
    or (
      app.has_perm(business_id,'view_finance')
      and app.can_see_branch(business_id,null)
    )
  );

create or replace function app.v109_require_feature()
returns void language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not app.platform_feature_enabled('economics_driver_policy_v109') then
    raise exception 'v109 economics and sector policy is not enabled'
      using errcode='0A000';
  end if;
end $$;

create or replace function app.v109_require_finance(p_business uuid)
returns void language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if auth.uid() is null or (
    not app.is_super_admin()
    and not app.has_perm(p_business,'view_finance')
  ) then
    raise exception 'finance access required' using errcode='42501';
  end if;
end $$;

create or replace function app.v109_require_finance_scope(
  p_business uuid,
  p_branch uuid
)
returns void language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  perform app.v109_require_finance(p_business);
  if not app.can_see_branch(p_business,p_branch) then
    raise exception 'finance branch is outside actor scope' using errcode='42501';
  end if;
end $$;

create or replace function public.set_effective_cost_rule_v109(
  p_business uuid,
  p_branch uuid,
  p_scope_kind text,
  p_scope_key text,
  p_cost_method text,
  p_cost_value bigint,
  p_source_type text,
  p_source_reference text,
  p_evidence jsonb,
  p_effective_from timestamptz,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_existing public.economic_cost_rules_v109%rowtype;
  v_prior public.economic_cost_rules_v109%rowtype;
  v_rule public.economic_cost_rules_v109%rowtype;
  v_version integer;
  v_currency text;
  v_request_hash text;
begin
  perform app.v109_require_feature();
  perform app.v109_require_finance_scope(p_business,p_branch);
  if p_effective_from is null then
    raise exception 'effective_from is required' using errcode='22023';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches b
    where b.id=p_branch and b.business_id=p_business
  ) then
    raise exception 'branch does not belong to business' using errcode='22023';
  end if;
  if p_scope_kind not in ('sale_kind','product')
     or nullif(btrim(p_scope_key),'') is null then
    raise exception 'valid cost scope is required' using errcode='22023';
  end if;
  if p_cost_method not in ('revenue_bps','fixed_per_unit')
     or p_cost_value is null or p_cost_value<0
     or (p_cost_method='revenue_bps' and p_cost_value>10000) then
    raise exception 'valid cost method/value is required' using errcode='22023';
  end if;
  if p_source_type not in (
    'supplier_invoice','supplier_contract','accounting_import','owner_attestation'
  ) or length(btrim(coalesce(p_source_reference,'')))<3 then
    raise exception 'traceable cost source is required' using errcode='22023';
  end if;
  if coalesce(jsonb_typeof(p_evidence),'null')<>'object' then
    raise exception 'cost evidence must be a JSON object' using errcode='22023';
  end if;
  select upper(currency) into strict v_currency
  from public.businesses where id=p_business;
  v_request_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'business_id',p_business,'branch_id',p_branch,
    'scope_kind',p_scope_kind,'scope_key',btrim(p_scope_key),
    'cost_method',p_cost_method,'cost_value',p_cost_value,
    'source_type',p_source_type,'source_reference',btrim(p_source_reference),
    'evidence',p_evidence,'effective_from',p_effective_from,
    'currency',v_currency
  )::text,'UTF8'),'sha256'),'hex');

  select * into v_existing from public.economic_cost_rules_v109
  where business_id=p_business and created_by=v_actor
    and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_hash<>v_request_hash then
      raise exception 'idempotency key reused with a different cost rule request'
        using errcode='23505';
    end if;
    return jsonb_build_object(
      'rule_id',v_existing.id,'version_no',v_existing.version_no,'replayed',true
    );
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    concat_ws(':','v109-cost',p_business,coalesce(p_branch::text,'all'),
      p_scope_kind,btrim(p_scope_key)),0
  ));
  select * into v_prior
  from public.economic_cost_rules_v109 r
  where r.business_id=p_business
    and r.branch_id is not distinct from p_branch
    and r.scope_kind=p_scope_kind and r.scope_key=btrim(p_scope_key)
    and r.effective_from<=p_effective_from
    and (r.effective_to is null or r.effective_to>p_effective_from)
  order by r.effective_from desc,r.version_no desc limit 1 for update;
  if found then
    if v_prior.effective_from=p_effective_from then
      raise exception 'a cost rule already starts at this effective time'
        using errcode='23505';
    end if;
    update public.economic_cost_rules_v109
    set effective_to=p_effective_from where id=v_prior.id;
  end if;
  if exists(
    select 1 from public.economic_cost_rules_v109 r
    where r.business_id=p_business
      and r.branch_id is not distinct from p_branch
      and r.scope_kind=p_scope_kind and r.scope_key=btrim(p_scope_key)
      and r.effective_from>p_effective_from
  ) then
    raise exception 'cost rules must be appended in effective-time order'
      using errcode='22023';
  end if;
  select coalesce(max(version_no),0)+1 into v_version
  from public.economic_cost_rules_v109 r
  where r.business_id=p_business
    and r.branch_id is not distinct from p_branch
    and r.scope_kind=p_scope_kind and r.scope_key=btrim(p_scope_key);
  insert into public.economic_cost_rules_v109(
    business_id,branch_id,scope_kind,scope_key,cost_method,cost_value,
    currency,source_type,source_reference,evidence,effective_from,version_no,
    created_by,idempotency_key,request_hash
  ) values(
    p_business,p_branch,p_scope_kind,btrim(p_scope_key),p_cost_method,p_cost_value,
    v_currency,p_source_type,btrim(p_source_reference),p_evidence,p_effective_from,v_version,
    v_actor,p_idempotency_key,v_request_hash
  ) returning * into v_rule;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(
    p_business,v_actor,'SET_EFFECTIVE_COST_RULE_V109',
    'economic_cost_rules_v109',v_rule.id,
    jsonb_build_object(
      'scope_kind',v_rule.scope_kind,'scope_key',v_rule.scope_key,
      'version_no',v_rule.version_no,'effective_from',v_rule.effective_from,
      'source_type',v_rule.source_type,'source_reference',v_rule.source_reference
    )
  );
  return jsonb_build_object(
    'rule_id',v_rule.id,'version_no',v_rule.version_no,
    'effective_from',v_rule.effective_from,'replayed',false
  );
end $$;

create or replace function public.get_period_economics_v109(
  p_business uuid,
  p_from date,
  p_to date,
  p_branch uuid default null,
  p_investment_cents bigint default null,
  p_investment_reference text default null,
  p_as_of timestamptz default statement_timestamp()
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_sales integer:=0;
  v_covered_sales integer:=0;
  v_revenue bigint:=0;
  v_covered_revenue bigint:=0;
  v_traceable_cogs bigint:=0;
  v_transaction_coverage_bps integer;
  v_revenue_coverage_bps integer;
  v_coverage_passes boolean:=false;
  v_gross_profit bigint;
  v_net_return bigint;
  v_roi_bps bigint;
  v_unavailable jsonb:='[]'::jsonb;
  v_currency text;
  v_currency_count integer;
begin
  perform app.v109_require_feature();
  perform app.v109_require_finance_scope(p_business,p_branch);
  if p_from is null or p_to is null or p_from>=p_to or p_as_of is null then
    raise exception 'valid half-open local-date period and as-of are required'
      using errcode='22023';
  end if;
  if p_investment_cents is not null and p_investment_cents<0 then
    raise exception 'investment cannot be negative' using errcode='22023';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches b
    where b.id=p_branch and b.business_id=p_business
  ) then
    raise exception 'branch does not belong to business' using errcode='22023';
  end if;

  select count(distinct contract.currency),min(contract.currency)
  into v_currency_count,v_currency
  from public.sales sale
  cross join lateral app.v106_reporting_contract(
    sale.business_id,sale.branch_id,sale.occurred_at
  ) contract
  where sale.business_id=p_business
    and (p_branch is null or sale.branch_id=p_branch)
    and sale.counts_as_revenue and sale.reversal_of is null
    and sale.created_at<=p_as_of
    and (sale.occurred_at at time zone contract.timezone)::date>=p_from
    and (sale.occurred_at at time zone contract.timezone)::date<p_to;
  if v_currency_count>1 then
    raise exception 'cross-currency reporting periods are not supported'
      using errcode='22023';
  end if;
  if v_currency_count=0 then
    select upper(currency) into strict v_currency
    from public.businesses where id=p_business;
  end if;

  with eligible as(
    select s.*,contract.currency,
      app.v106_sale_residual_minor(s.id,p_as_of) as residual_cents
    from public.sales s
    cross join lateral app.v106_reporting_contract(
      s.business_id,s.branch_id,s.occurred_at
    ) contract
    where s.business_id=p_business
      and (p_branch is null or s.branch_id=p_branch)
      and s.counts_as_revenue and s.reversal_of is null
      and s.created_at<=p_as_of
      and (s.occurred_at at time zone contract.timezone)::date>=p_from
      and (s.occurred_at at time zone contract.timezone)::date<p_to
      and app.v106_sale_residual_minor(s.id,p_as_of)>0
  ), matched as(
    select sale.id,sale.residual_cents as amount_cents,sale.qty,rule.id as rule_id,
      case
        when rule.cost_method='revenue_bps'
          then round(sale.residual_cents*rule.cost_value::numeric/10000)::bigint
        when rule.cost_method='fixed_per_unit'
          then round(
            rule.cost_value*coalesce(sale.qty,1)
            * sale.residual_cents::numeric/greatest(sale.amount_cents,1)
          )::bigint
        else null
      end as cogs_cents
    from eligible sale
    left join lateral(
      select candidate.*
      from public.economic_cost_rules_v109 candidate
      where candidate.business_id=p_business
        and candidate.currency=sale.currency
        and (candidate.branch_id is null or candidate.branch_id=sale.branch_id)
        and (
          (candidate.scope_kind='product'
            and sale.product_id is not null
            and candidate.scope_key=sale.product_id::text)
          or (candidate.scope_kind='sale_kind' and candidate.scope_key=sale.kind)
        )
        and candidate.effective_from<=sale.occurred_at
        and (candidate.effective_to is null or candidate.effective_to>sale.occurred_at)
      order by
        case when candidate.scope_kind='product' then 0 else 1 end,
        case when candidate.branch_id=sale.branch_id then 0 else 1 end,
        candidate.effective_from desc,candidate.version_no desc
      limit 1
    ) rule on true
  )
  select count(*),count(*) filter(where rule_id is not null),
    coalesce(sum(amount_cents),0),
    coalesce(sum(amount_cents) filter(where rule_id is not null),0),
    coalesce(sum(cogs_cents) filter(where rule_id is not null),0)
  into v_sales,v_covered_sales,v_revenue,v_covered_revenue,v_traceable_cogs
  from matched;

  v_transaction_coverage_bps:=case when v_sales=0 then null
    else round(v_covered_sales*10000.0/v_sales)::integer end;
  v_revenue_coverage_bps:=case when v_revenue=0 then null
    else round(v_covered_revenue*10000.0/v_revenue)::integer end;
  v_coverage_passes:=v_sales>0 and v_covered_sales=v_sales
    and v_covered_revenue=v_revenue;
  if v_sales=0 then
    v_unavailable:=v_unavailable||jsonb_build_array('no_eligible_sales');
  elsif not v_coverage_passes then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('incomplete_traceable_cost_coverage');
  end if;
  if p_investment_cents is null
     or length(btrim(coalesce(p_investment_reference,'')))<3 then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('traceable_investment_not_provided');
  elsif p_investment_cents=0 then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('positive_traceable_investment_required');
  end if;
  if v_coverage_passes then
    v_gross_profit:=v_revenue-v_traceable_cogs;
    if p_investment_cents>0
       and length(btrim(coalesce(p_investment_reference,'')))>=3 then
      v_net_return:=v_gross_profit-p_investment_cents;
      v_roi_bps:=round(v_net_return*10000.0/p_investment_cents);
    end if;
  end if;

  return jsonb_build_object(
    'contract_version','period_economics_v109',
    'business_id',p_business,
    'as_of',p_as_of,
    'period',jsonb_build_object('from',p_from,'to',p_to,'basis','business_local_date'),
    'status',case
      when v_sales=0 then 'no_data'
      when v_coverage_passes then 'ready'
      else 'insufficient_cost_coverage'
    end,
    'coverage',jsonb_build_object(
      'eligible_sales',v_sales,'covered_sales',v_covered_sales,
      'transaction_coverage_bps',v_transaction_coverage_bps,
      'eligible_revenue_cents',v_revenue,
      'covered_revenue_cents',v_covered_revenue,
      'revenue_coverage_bps',v_revenue_coverage_bps,
      'traceable_cost_coverage_passes',v_coverage_passes
    ),
    'profit',case when v_coverage_passes then jsonb_build_object(
      'currency',v_currency,'revenue_cents',v_revenue,
      'traceable_cogs_cents',v_traceable_cogs,
      'gross_profit_cents',v_gross_profit
    ) else 'null'::jsonb end,
    'roi',case when v_roi_bps is not null then jsonb_build_object(
      'investment_cents',p_investment_cents,
      'investment_reference',btrim(p_investment_reference),
      'net_return_cents',v_net_return,'return_on_investment_bps',v_roi_bps
    ) else 'null'::jsonb end,
    'unavailable_reasons',v_unavailable,
    'limitations',jsonb_build_array(
      'gross profit is returned only at complete traceable cost coverage',
      'ROI is period gross profit less the supplied traceable investment, divided by that investment',
      'this period result is descriptive and is not a causal increment claim'
    )
  );
end $$;

create or replace function public.get_revenue_driver_decomposition_v109(
  p_business uuid,
  p_current_from date,
  p_current_to date,
  p_comparison_from date,
  p_comparison_to date,
  p_branch uuid default null,
  p_as_of timestamptz default statement_timestamp()
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  c_total bigint:=0;c_identified bigint:=0;c_transactions integer:=0;c_clients integer:=0;
  p_total bigint:=0;p_identified bigint:=0;p_transactions integer:=0;p_clients integer:=0;
  c_anonymous bigint:=0;p_anonymous bigint:=0;
  c_coverage integer;p_coverage integer;
  p_frequency numeric;p_aov numeric;c_frequency numeric;c_aov numeric;
  d_customer bigint;d_frequency bigint;d_aov bigint;d_anonymous bigint;
  d_residual bigint;d_total bigint;d_sum bigint;
  v_available boolean:=false;
  v_reason text;
  v_currency text;
  v_currency_count integer;
begin
  perform app.v109_require_feature();
  perform app.v109_require_finance_scope(p_business,p_branch);
  if p_current_from is null or p_current_to is null
     or p_comparison_from is null or p_comparison_to is null
     or p_current_from>=p_current_to
     or p_comparison_from>=p_comparison_to
     or p_as_of is null then
    raise exception 'valid local-date periods and as-of are required'
      using errcode='22023';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches b
    where b.id=p_branch and b.business_id=p_business
  ) then
    raise exception 'branch does not belong to business' using errcode='22023';
  end if;

  select count(distinct contract.currency),min(contract.currency)
  into v_currency_count,v_currency
  from public.sales sale
  cross join lateral app.v106_reporting_contract(
    sale.business_id,sale.branch_id,sale.occurred_at
  ) contract
  where sale.business_id=p_business
    and (p_branch is null or sale.branch_id=p_branch)
    and sale.counts_as_revenue and sale.reversal_of is null
    and sale.created_at<=p_as_of
    and (
      (
        (sale.occurred_at at time zone contract.timezone)::date>=p_current_from
        and (sale.occurred_at at time zone contract.timezone)::date<p_current_to
      ) or (
        (sale.occurred_at at time zone contract.timezone)::date>=p_comparison_from
        and (sale.occurred_at at time zone contract.timezone)::date<p_comparison_to
      )
    );
  if v_currency_count>1 then
    raise exception 'cross-currency driver comparisons are not supported'
      using errcode='22023';
  end if;
  if v_currency_count=0 then
    select upper(currency) into strict v_currency
    from public.businesses where id=p_business;
  end if;

  with base as(
    select s.client_id,
      app.v106_sale_residual_minor(s.id,p_as_of) as amount_cents
    from public.sales s
    cross join lateral app.v106_reporting_contract(
      s.business_id,s.branch_id,s.occurred_at
    ) contract
    where s.business_id=p_business
      and (p_branch is null or s.branch_id=p_branch)
      and s.counts_as_revenue and s.reversal_of is null
      and s.created_at<=p_as_of
      and (s.occurred_at at time zone contract.timezone)::date>=p_current_from
      and (s.occurred_at at time zone contract.timezone)::date<p_current_to
      and app.v106_sale_residual_minor(s.id,p_as_of)>0
  )
  select coalesce(sum(amount_cents),0),
    coalesce(sum(amount_cents) filter(where client_id is not null),0),
    count(*) filter(where client_id is not null),
    count(distinct client_id) filter(where client_id is not null)
  into c_total,c_identified,c_transactions,c_clients from base;
  with base as(
    select s.client_id,
      app.v106_sale_residual_minor(s.id,p_as_of) as amount_cents
    from public.sales s
    cross join lateral app.v106_reporting_contract(
      s.business_id,s.branch_id,s.occurred_at
    ) contract
    where s.business_id=p_business
      and (p_branch is null or s.branch_id=p_branch)
      and s.counts_as_revenue and s.reversal_of is null
      and s.created_at<=p_as_of
      and (s.occurred_at at time zone contract.timezone)::date>=p_comparison_from
      and (s.occurred_at at time zone contract.timezone)::date<p_comparison_to
      and app.v106_sale_residual_minor(s.id,p_as_of)>0
  )
  select coalesce(sum(amount_cents),0),
    coalesce(sum(amount_cents) filter(where client_id is not null),0),
    count(*) filter(where client_id is not null),
    count(distinct client_id) filter(where client_id is not null)
  into p_total,p_identified,p_transactions,p_clients from base;

  c_anonymous:=c_total-c_identified;
  p_anonymous:=p_total-p_identified;
  c_coverage:=case when c_total=0 then null
    else round(c_identified*10000.0/c_total)::integer end;
  p_coverage:=case when p_total=0 then null
    else round(p_identified*10000.0/p_total)::integer end;
  d_total:=c_total-p_total;
  v_available:=c_clients>0 and p_clients>0
    and c_transactions>0 and p_transactions>0;
  if v_available then
    p_frequency:=p_transactions::numeric/p_clients;
    p_aov:=p_identified::numeric/p_transactions;
    c_frequency:=c_transactions::numeric/c_clients;
    c_aov:=c_identified::numeric/c_transactions;
    d_customer:=round((c_clients-p_clients)*p_frequency*p_aov);
    d_frequency:=round(c_clients*(c_frequency-p_frequency)*p_aov);
    d_aov:=round(c_clients*c_frequency*(c_aov-p_aov));
    d_anonymous:=c_anonymous-p_anonymous;
    d_residual:=d_total-d_customer-d_frequency-d_aov-d_anonymous;
    d_sum:=d_customer+d_frequency+d_aov+d_anonymous+d_residual;
  else
    v_reason:=case
      when p_total=0 then 'comparison_period_has_no_revenue'
      when c_total=0 then 'current_period_has_no_revenue'
      when p_clients=0 or p_transactions=0
        then 'comparison_period_has_no_identified_customer_base'
      else 'current_period_has_no_identified_customer_base'
    end;
  end if;

  return jsonb_build_object(
    'contract_version','revenue_driver_decomposition_v109',
    'business_id',p_business,
    'as_of',p_as_of,
    'currency',v_currency,
    'status',case when v_available then 'ready' else 'unavailable' end,
    'unavailable_reason',v_reason,
    'periods',jsonb_build_object(
      'comparison',jsonb_build_object(
        'from',p_comparison_from,'to',p_comparison_to,
        'basis','business_local_date',
        'revenue_cents',p_total,'identified_revenue_cents',p_identified,
        'anonymous_revenue_cents',p_anonymous,
        'identified_customers',p_clients,'identified_transactions',p_transactions
      ),
      'current',jsonb_build_object(
        'from',p_current_from,'to',p_current_to,
        'basis','business_local_date',
        'revenue_cents',c_total,'identified_revenue_cents',c_identified,
        'anonymous_revenue_cents',c_anonymous,
        'identified_customers',c_clients,'identified_transactions',c_transactions
      )
    ),
    'coverage',jsonb_build_object(
      'comparison_identified_revenue_bps',p_coverage,
      'current_identified_revenue_bps',c_coverage,
      'anonymous_revenue_is_separate_driver',true
    ),
    'drivers',case when v_available then jsonb_build_object(
      'identified_customer_count_cents',d_customer,
      'purchase_frequency_cents',d_frequency,
      'average_transaction_value_cents',d_aov,
      'anonymous_revenue_cents',d_anonymous,
      'rounding_residual_cents',d_residual
    ) else 'null'::jsonb end,
    'reconciliation',jsonb_build_object(
      'period_revenue_delta_cents',d_total,
      'sum_driver_contributions_cents',d_sum,
      'rounding_residual_cents',d_residual,
      'reconciles',case when v_available then d_sum=d_total else null end
    ),
    'method',jsonb_build_object(
      'identity','revenue = identified customers × purchase frequency × average transaction value + anonymous revenue',
      'order',jsonb_build_array(
        'identified_customer_count','purchase_frequency',
        'average_transaction_value','anonymous_revenue','rounding_residual'
      ),
      'deterministic',true,
      'causal_claim',false
    )
  );
end $$;

create or replace function public.get_effective_sector_policy_v109(
  p_business uuid,
  p_policy_key text default 'lapse_detection',
  p_as_of timestamptz default statement_timestamp()
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_sector text;
  v_base public.sector_policy_versions_v109%rowtype;
  v_override public.business_sector_policy_overrides_v109%rowtype;
begin
  perform app.v109_require_feature();
  perform app.v109_require_finance_scope(p_business,null);
  if p_as_of is null then
    raise exception 'as-of is required' using errcode='22023';
  end if;
  select lower(b.industry) into v_sector
  from public.businesses b where b.id=p_business;
  if v_sector is null then raise exception 'business not found';end if;
  select * into v_base
  from public.sector_policy_versions_v109 p
  where p.sector_key=v_sector and p.policy_key=p_policy_key
    and p.status='published' and p.effective_from<=p_as_of
    and (p.effective_to is null or p.effective_to>p_as_of)
  order by p.version_no desc limit 1;
  if not found then
    select * into v_base
    from public.sector_policy_versions_v109 p
    where p.sector_key='other' and p.policy_key=p_policy_key
      and p.status='published' and p.effective_from<=p_as_of
      and (p.effective_to is null or p.effective_to>p_as_of)
    order by p.version_no desc limit 1;
  end if;
  if not found then raise exception 'no effective sector policy';end if;
  select * into v_override
  from public.business_sector_policy_overrides_v109 o
  where o.business_id=p_business and o.policy_key=p_policy_key
    and o.base_policy_id=v_base.id and o.effective_from<=p_as_of
    and (o.effective_to is null or o.effective_to>p_as_of)
  order by o.version_no desc limit 1;
  return jsonb_build_object(
    'contract_version','effective_sector_policy_v109',
    'business_id',p_business,
    'requested_sector',v_sector,
    'resolved_sector',v_base.sector_key,
    'used_fallback_sector',v_base.sector_key<>v_sector,
    'policy_key',v_base.policy_key,
    'base_policy',jsonb_build_object(
      'id',v_base.id,'version_no',v_base.version_no,
      'effective_from',v_base.effective_from,'effective_to',v_base.effective_to,
      'evidence_basis',v_base.evidence_basis,'parameters',v_base.parameters,
      'fallback_policy',v_base.fallback_policy,
      'suppression_rules',v_base.suppression_rules,
      'limitations',v_base.limitations
    ),
    'owner_override',case when v_override.id is null then 'null'::jsonb
      else jsonb_build_object(
        'id',v_override.id,'version_no',v_override.version_no,
        'parameters',v_override.override_parameters,
        'reason',v_override.reason,'effective_from',v_override.effective_from,
        'effective_to',v_override.effective_to,'created_by',v_override.created_by
      ) end,
    'effective_parameters',v_base.parameters
      ||coalesce(v_override.override_parameters,'{}'::jsonb),
    'universal_churn_number',null,
    'requires_local_evidence',true
  );
end $$;

create or replace function app.v109_sector_source_availability(
  p_business uuid,
  p_sector text,
  p_minimum_history integer,
  p_as_of timestamptz
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_service_history integer:=0;
  v_product_history integer:=0;
  v_membership_history integer:=0;
  v_required integer:=greatest(coalesce(p_minimum_history,1),1);
begin
  if p_as_of is null then
    raise exception 'as-of is required' using errcode='22023';
  end if;

  if p_sector in ('facial','salon','massage') then
    select count(*) into v_service_history
    from (
      select appointment.id
      from public.appointments appointment
      where appointment.business_id=p_business
        and appointment.status='completed'
        and appointment.service_id is not null
        and appointment.created_at<=p_as_of
      union
      select item.sale_id
      from public.sale_items item
      join public.sales sale
        on sale.id=item.sale_id and sale.business_id=item.business_id
      where item.business_id=p_business
        and item.item_type='service' and item.ref_id is not null
        and sale.reversal_of is null and sale.created_at<=p_as_of
        and app.v106_sale_residual_minor(sale.id,p_as_of)>0
    ) observed;
  end if;

  if p_sector='retail' then
    select count(distinct item.sale_id) into v_product_history
    from public.sale_items item
    join public.sales sale
      on sale.id=item.sale_id and sale.business_id=item.business_id
    where item.business_id=p_business
      and item.item_type='retail' and item.product_id is not null
      and sale.reversal_of is null and sale.created_at<=p_as_of
      and app.v106_sale_residual_minor(sale.id,p_as_of)>0;
  end if;

  if p_sector='fitness' then
    select count(*) into v_membership_history
    from public.memberships membership
    where membership.business_id=p_business
      and membership.created_at<=p_as_of
      and membership.status in (
        'active','paused','cancel_at_period_end','cancelled'
      );
  end if;

  return jsonb_build_object(
    'as_of',p_as_of,
    'minimum_history_required',v_required,
    'service_cadence',case
      when p_sector in ('facial','salon','massage')
        then v_service_history>=v_required else null end,
    'service_linked_history_count',case
      when p_sector in ('facial','salon','massage')
        then v_service_history else null end,
    'product_cycle',case
      when p_sector='retail' then v_product_history>=v_required else null end,
    'product_linked_history_count',case
      when p_sector='retail' then v_product_history else null end,
    'membership_state',case
      when p_sector='fitness' then v_membership_history>0 else null end,
    'membership_history_count',case
      when p_sector='fitness' then v_membership_history else null end,
    'specialized_sector_policy',p_sector<>'other'
  );
end $$;

create or replace function app.growth_v108_effective_parameters(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_sector text;
  v_base public.sector_policy_versions_v109%rowtype;
  v_override public.business_sector_policy_overrides_v109%rowtype;
  v_suppressions jsonb:='[]'::jsonb;
  v_availability jsonb;
  v_as_of timestamptz:=statement_timestamp();
begin
  select lower(industry) into strict v_sector
  from public.businesses where id=p_business;
  select * into v_base
  from public.sector_policy_versions_v109
  where sector_key=v_sector and policy_key='lapse_detection'
    and status='published' and effective_from<=v_as_of
    and (effective_to is null or effective_to>v_as_of)
  order by version_no desc limit 1;
  if not found then
    select * into strict v_base
    from public.sector_policy_versions_v109
    where sector_key='other' and policy_key='lapse_detection'
      and status='published' and effective_from<=v_as_of
      and (effective_to is null or effective_to>v_as_of)
    order by version_no desc limit 1;
  end if;
  select * into v_override
  from public.business_sector_policy_overrides_v109
    where business_id=p_business and policy_key='lapse_detection'
    and base_policy_id=v_base.id
    and effective_from<=v_as_of
    and (effective_to is null or effective_to>v_as_of)
  order by version_no desc limit 1;
  v_availability:=app.v109_sector_source_availability(
    p_business,v_base.sector_key,
    (v_base.parameters->>'minimum_prior_visits')::integer,v_as_of
  );
  if v_base.sector_key in ('facial','salon','massage')
     and not coalesce((v_availability->>'service_cadence')::boolean,false) then
    v_suppressions:=jsonb_build_array('unknown_service_cadence');
  elsif v_base.sector_key='fitness'
     and not coalesce((v_availability->>'membership_state')::boolean,false) then
    v_suppressions:=jsonb_build_array('membership_state_unknown');
  elsif v_base.sector_key='retail'
     and not coalesce((v_availability->>'product_cycle')::boolean,false) then
    v_suppressions:=jsonb_build_array('product_cycle_unknown');
  elsif v_base.sector_key='other' then
    v_suppressions:=jsonb_build_array('sector_not_specialized');
  end if;
  return jsonb_build_object(
    'source','sector_policy_v109',
    'lineage',jsonb_build_object(
      'requested_sector',v_sector,
      'resolved_sector',v_base.sector_key,
      'base_policy_id',v_base.id,
      'base_version_no',v_base.version_no,
      'override_id',v_override.id,
      'override_version_no',v_override.version_no
    ),
    'parameters',v_base.parameters
      ||coalesce(v_override.override_parameters,'{}'::jsonb),
    'suppression_reasons',v_suppressions,
    'source_availability',v_availability
  );
end $$;

create or replace function public.set_business_sector_policy_override_v109(
  p_business uuid,
  p_policy_key text,
  p_override_parameters jsonb,
  p_reason text,
  p_effective_from timestamptz,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_effective jsonb;
  v_base uuid;
  v_existing public.business_sector_policy_overrides_v109%rowtype;
  v_prior public.business_sector_policy_overrides_v109%rowtype;
  v_row public.business_sector_policy_overrides_v109%rowtype;
  v_version integer;
  v_request_hash text;
begin
  perform app.v109_require_feature();
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode='42501';
  end if;
  if not app.can_see_branch(p_business,null) then
    raise exception 'business-wide sector policy is outside actor scope'
      using errcode='42501';
  end if;
  if p_effective_from is null
     or coalesce(jsonb_typeof(p_override_parameters),'null')<>'object'
     or p_override_parameters='{}'::jsonb then
    raise exception 'non-empty override parameters and effective time are required'
      using errcode='22023';
  end if;
  if exists(
    select 1 from jsonb_object_keys(p_override_parameters) k
    where k not in (
      'minimum_prior_visits','cadence_multiplier',
      'minimum_lapse_days','minimum_audience'
    )
  ) then
    raise exception 'override contains an unsupported parameter' using errcode='22023';
  end if;
  if p_override_parameters ? 'minimum_prior_visits'
     and (
       jsonb_typeof(p_override_parameters->'minimum_prior_visits')<>'number'
       or (p_override_parameters->>'minimum_prior_visits')::numeric<>trunc(
         (p_override_parameters->>'minimum_prior_visits')::numeric
       )
       or (p_override_parameters->>'minimum_prior_visits')::numeric not between 2 and 20
     ) then
    raise exception 'minimum_prior_visits must be 2..20' using errcode='22023';
  end if;
  if p_override_parameters ? 'cadence_multiplier'
     and (
       jsonb_typeof(p_override_parameters->'cadence_multiplier')<>'number'
       or (p_override_parameters->>'cadence_multiplier')::numeric not between 1.10 and 5.00
     ) then
    raise exception 'cadence_multiplier must be 1.10..5.00' using errcode='22023';
  end if;
  if p_override_parameters ? 'minimum_lapse_days'
     and (
       jsonb_typeof(p_override_parameters->'minimum_lapse_days')<>'number'
       or (p_override_parameters->>'minimum_lapse_days')::numeric<>trunc(
         (p_override_parameters->>'minimum_lapse_days')::numeric
       )
       or (p_override_parameters->>'minimum_lapse_days')::numeric not between 3 and 365
     ) then
    raise exception 'minimum_lapse_days must be 3..365' using errcode='22023';
  end if;
  if p_override_parameters ? 'minimum_audience'
     and (
       jsonb_typeof(p_override_parameters->'minimum_audience')<>'number'
       or (p_override_parameters->>'minimum_audience')::numeric<>trunc(
         (p_override_parameters->>'minimum_audience')::numeric
       )
       or (p_override_parameters->>'minimum_audience')::numeric not between 10 and 5000
     ) then
    raise exception 'minimum_audience must be 10..5000' using errcode='22023';
  end if;
  if length(btrim(coalesce(p_reason,'')))<3 then
    raise exception 'override reason is required' using errcode='22023';
  end if;
  v_request_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'business_id',p_business,'policy_key',p_policy_key,
    'override_parameters',p_override_parameters,
    'reason',btrim(p_reason),'effective_from',p_effective_from
  )::text,'UTF8'),'sha256'),'hex');
  select * into v_existing
  from public.business_sector_policy_overrides_v109
  where business_id=p_business and created_by=v_actor
    and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_hash<>v_request_hash then
      raise exception 'idempotency key reused with a different sector override request'
        using errcode='23505';
    end if;
    return jsonb_build_object(
      'override_id',v_existing.id,'version_no',v_existing.version_no,'replayed',true
    );
  end if;
  v_effective:=public.get_effective_sector_policy_v109(
    p_business,p_policy_key,p_effective_from
  );
  v_base:=(v_effective#>>'{base_policy,id}')::uuid;
  perform pg_advisory_xact_lock(hashtextextended(
    'v109-sector-override:'||p_business::text||':'||p_policy_key,0
  ));
  select * into v_prior
  from public.business_sector_policy_overrides_v109 o
  where o.business_id=p_business and o.policy_key=p_policy_key
    and o.effective_from<=p_effective_from
    and (o.effective_to is null or o.effective_to>p_effective_from)
  order by o.effective_from desc,o.version_no desc limit 1 for update;
  if found then
    if v_prior.effective_from=p_effective_from then
      raise exception 'an override already starts at this effective time'
        using errcode='23505';
    end if;
    update public.business_sector_policy_overrides_v109
    set effective_to=p_effective_from where id=v_prior.id;
  end if;
  if exists(
    select 1 from public.business_sector_policy_overrides_v109 o
    where o.business_id=p_business and o.policy_key=p_policy_key
      and o.effective_from>p_effective_from
  ) then
    raise exception 'overrides must be appended in effective-time order'
      using errcode='22023';
  end if;
  select coalesce(max(version_no),0)+1 into v_version
  from public.business_sector_policy_overrides_v109
  where business_id=p_business and policy_key=p_policy_key;
  insert into public.business_sector_policy_overrides_v109(
    business_id,policy_key,base_policy_id,version_no,override_parameters,
    reason,effective_from,created_by,idempotency_key,request_hash
  ) values(
    p_business,p_policy_key,v_base,v_version,p_override_parameters,
    btrim(p_reason),p_effective_from,v_actor,p_idempotency_key,v_request_hash
  ) returning * into v_row;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(
    p_business,v_actor,'SET_SECTOR_POLICY_OVERRIDE_V109',
    'business_sector_policy_overrides_v109',v_row.id,
    jsonb_build_object(
      'policy_key',p_policy_key,'base_policy_id',v_base,
      'version_no',v_version,'parameters',p_override_parameters,
      'reason',btrim(p_reason),'effective_from',p_effective_from
    )
  );
  return jsonb_build_object(
    'override_id',v_row.id,'base_policy_id',v_base,
    'version_no',v_version,'replayed',false
  );
end $$;

revoke all privileges on table
  public.economic_cost_rules_v109,
  public.sector_policy_versions_v109,
  public.business_sector_policy_overrides_v109
from public,anon,authenticated;

revoke all privileges on function app.v109_require_feature(),
  app.v109_require_finance(uuid),
  app.v109_require_finance_scope(uuid,uuid),
  app.v109_sector_source_availability(uuid,text,integer,timestamptz)
from public,anon,authenticated;

revoke all privileges on function public.set_effective_cost_rule_v109(
  uuid,uuid,text,text,text,bigint,text,text,jsonb,timestamptz,uuid
) from public,anon;
revoke all privileges on function public.get_period_economics_v109(
  uuid,date,date,uuid,bigint,text,timestamptz
) from public,anon;
revoke all privileges on function public.get_revenue_driver_decomposition_v109(
  uuid,date,date,date,date,uuid,timestamptz
) from public,anon;
revoke all privileges on function public.get_effective_sector_policy_v109(
  uuid,text,timestamptz
) from public,anon;
revoke all privileges on function public.set_business_sector_policy_override_v109(
  uuid,text,jsonb,text,timestamptz,uuid
) from public,anon;

grant execute on function public.set_effective_cost_rule_v109(
  uuid,uuid,text,text,text,bigint,text,text,jsonb,timestamptz,uuid
) to authenticated;
grant execute on function public.get_period_economics_v109(
  uuid,date,date,uuid,bigint,text,timestamptz
) to authenticated;
grant execute on function public.get_revenue_driver_decomposition_v109(
  uuid,date,date,date,date,uuid,timestamptz
) to authenticated;
grant execute on function public.get_effective_sector_policy_v109(
  uuid,text,timestamptz
) to authenticated;
grant execute on function public.set_business_sector_policy_override_v109(
  uuid,text,jsonb,text,timestamptz,uuid
) to authenticated;

comment on table public.economic_cost_rules_v109 is
  'Effective-dated, source-referenced cost rules. Browser roles mutate only through finance-gated RPC.';
comment on table public.sector_policy_versions_v109 is
  'Versioned sector starting policies with evidence, fallback, suppression and limitations; never a universal churn claim.';
comment on function public.get_period_economics_v109(
  uuid,date,date,uuid,bigint,text,timestamptz
) is
  'Returns profit only at complete traceable cost coverage and ROI only with a traceable investment, using one immutable as-of and business-local half-open dates.';
comment on function public.get_revenue_driver_decomposition_v109(
  uuid,date,date,date,date,uuid,timestamptz
) is
  'Deterministic non-causal revenue bridge with identity coverage, unavailable states, historical-currency refusal and explicit rounding residual.';

commit;
