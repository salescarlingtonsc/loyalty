-- NESTLY v114 — TRACEABLE BENEFIT AND DELIVERY ECONOMICS
--
-- Extends the v109 period-economics contract so a financial result is withheld
-- until every sale item, redeemed benefit, and delivered provider event has an
-- unambiguous, effective-dated, source-referenced cost rule. Itemized sale
-- residuals use the v106 half-open period contract and deterministic
-- largest-remainder allocation. The public RPC signature and contract_version
-- remain stable for existing clients.

begin;

create table public.growth_cost_rules_v114 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  branch_id uuid,
  cost_class text not null check (cost_class in ('benefit','delivery')),
  scope_key text not null check (scope_key ~ '^[a-z][a-z0-9_]{1,39}$'),
  cost_method text not null check (cost_method in ('value_bps','fixed_per_event')),
  cost_value bigint not null,
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  source_type text not null check (source_type in (
    'supplier_invoice','supplier_contract','accounting_import',
    'owner_attestation','provider_invoice','provider_contract'
  )),
  source_reference text not null
    check (length(btrim(source_reference)) between 3 and 500),
  evidence jsonb not null default '{}'::jsonb
    check (jsonb_typeof(evidence)='object'),
  effective_from timestamptz not null,
  effective_to timestamptz,
  version_no integer not null check (version_no>0),
  created_by uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  constraint growth_cost_rules_v114_branch_business_fk
    foreign key (branch_id,business_id)
    references public.branches(id,business_id) on delete restrict,
  constraint growth_cost_rules_v114_window_check
    check (effective_to is null or effective_to>effective_from),
  constraint growth_cost_rules_v114_shape_check check (
    (
      cost_class='benefit'
      and scope_key='credit_cents'
      and (
        (cost_method='value_bps' and cost_value between 0 and 10000)
        or
        (cost_method='fixed_per_event' and cost_value between 0 and 100000000)
      )
    )
    or
    (
      cost_class='delivery'
      and cost_method='fixed_per_event'
      and cost_value between 0 and 100000000
    )
  ),
  constraint growth_cost_rules_v114_actor_idem_uk
    unique (business_id,created_by,idempotency_key),
  constraint growth_cost_rules_v114_version_uk
    unique nulls not distinct (
      business_id,branch_id,cost_class,scope_key,version_no
    )
);

create index growth_cost_rules_v114_match_idx
  on public.growth_cost_rules_v114 (
    business_id,cost_class,scope_key,effective_from desc
  );

alter table public.growth_cost_rules_v114 enable row level security;

create policy growth_cost_rules_v114_finance_read
  on public.growth_cost_rules_v114 for select to authenticated
  using (
    app.is_super_admin()
    or (
      app.has_perm(business_id,'view_finance')
      and app.can_see_branch(business_id,branch_id)
    )
  );

create or replace function public.set_growth_cost_rule_v114 (
  p_business uuid,
  p_branch uuid,
  p_cost_class text,
  p_scope_key text,
  p_cost_method text,
  p_cost_value bigint,
  p_source_type text,
  p_source_reference text,
  p_evidence jsonb,
  p_effective_from timestamptz,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_prior public.growth_cost_rules_v114%rowtype;
  v_rule public.growth_cost_rules_v114%rowtype;
  v_version integer;
  v_currency text;
  v_identity text;
  v_request_hash text;
  v_receipt jsonb;
begin
  perform app.v109_require_feature();
  perform app.v109_require_finance_scope(p_business,p_branch);
  if p_effective_from is null or p_idempotency_key is null then
    raise exception 'effective_from and idempotency_key are required'
      using errcode='22023';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches branch_row
    where branch_row.id=p_branch and branch_row.business_id=p_business
  ) then
    raise exception 'branch does not belong to business' using errcode='22023';
  end if;
  if p_cost_class not in ('benefit','delivery')
     or nullif(btrim(p_scope_key),'') is null then
    raise exception 'valid growth cost scope is required' using errcode='22023';
  end if;
  if (
    p_cost_class='benefit'
    and (
      btrim(p_scope_key)<>'credit_cents'
      or p_cost_method not in ('value_bps','fixed_per_event')
    )
  ) or (
    p_cost_class='delivery'
    and p_cost_method<>'fixed_per_event'
  ) or p_cost_value is null or p_cost_value<0
     or (p_cost_method='value_bps' and p_cost_value>10000) then
    raise exception 'valid growth cost method/value is required'
      using errcode='22023';
  end if;
  if p_source_type not in (
    'supplier_invoice','supplier_contract','accounting_import',
    'owner_attestation','provider_invoice','provider_contract'
  ) or length(btrim(coalesce(p_source_reference,'')))<3 then
    raise exception 'traceable growth cost source is required'
      using errcode='22023';
  end if;
  if coalesce(jsonb_typeof(p_evidence),'null')<>'object' then
    raise exception 'growth cost evidence must be a JSON object'
      using errcode='22023';
  end if;
  select upper(currency) into strict v_currency
  from public.businesses where id=p_business;
  v_request_hash:=app.v110_request_hash(jsonb_build_object(
    'business_id',p_business,'branch_id',p_branch,
    'cost_class',p_cost_class,'scope_key',btrim(p_scope_key),
    'cost_method',p_cost_method,'cost_value',p_cost_value,
    'source_type',p_source_type,
    'source_reference',btrim(p_source_reference),
    'evidence',p_evidence,'effective_from',p_effective_from,
    'currency',v_currency
  ));

  v_identity:=app.v112_hash(jsonb_build_object(
    'operation','set_growth_cost_rule_v114',
    'business_id',p_business,'actor',v_actor,
    'idempotency_key',p_idempotency_key
  ));
  perform app.v112_lock_pair(
    'v114-growth-cost-request:'||v_identity,
    concat_ws(
      ':','v114-growth-cost-scope',p_business,
      coalesce(p_branch::text,'all'),p_cost_class,btrim(p_scope_key)
    )
  );
  v_receipt:=app.v112_get_receipt(v_identity,v_request_hash);
  if v_receipt is not null then
    return v_receipt;
  end if;

  select * into v_prior
  from public.growth_cost_rules_v114 rule_row
  where rule_row.business_id=p_business
    and rule_row.branch_id is not distinct from p_branch
    and rule_row.cost_class=p_cost_class
    and rule_row.scope_key=btrim(p_scope_key)
    and rule_row.effective_from<=p_effective_from
    and (
      rule_row.effective_to is null
      or rule_row.effective_to>p_effective_from
    )
  order by rule_row.effective_from desc,rule_row.version_no desc
  limit 1 for update;
  if found then
    if v_prior.effective_from=p_effective_from then
      raise exception 'a growth cost rule already starts at this effective time'
        using errcode='23505';
    end if;
    update public.growth_cost_rules_v114
    set effective_to=p_effective_from where id=v_prior.id;
  end if;
  if exists (
    select 1 from public.growth_cost_rules_v114 rule_row
    where rule_row.business_id=p_business
      and rule_row.branch_id is not distinct from p_branch
      and rule_row.cost_class=p_cost_class
      and rule_row.scope_key=btrim(p_scope_key)
      and rule_row.effective_from>p_effective_from
  ) then
    raise exception 'growth cost rules must be appended in effective-time order'
      using errcode='22023';
  end if;
  select coalesce(max(version_no),0)+1 into v_version
  from public.growth_cost_rules_v114 rule_row
  where rule_row.business_id=p_business
    and rule_row.branch_id is not distinct from p_branch
    and rule_row.cost_class=p_cost_class
    and rule_row.scope_key=btrim(p_scope_key);

  insert into public.growth_cost_rules_v114 (
    business_id,branch_id,cost_class,scope_key,cost_method,cost_value,
    currency,source_type,source_reference,evidence,effective_from,version_no,
    created_by,idempotency_key,request_hash
  ) values (
    p_business,p_branch,p_cost_class,btrim(p_scope_key),
    p_cost_method,p_cost_value,v_currency,p_source_type,
    btrim(p_source_reference),p_evidence,p_effective_from,v_version,
    v_actor,p_idempotency_key,v_request_hash
  ) returning * into v_rule;

  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values (
    p_business,v_actor,'SET_GROWTH_COST_RULE_V114',
    'growth_cost_rules_v114',v_rule.id,jsonb_build_object(
      'branch_id',v_rule.branch_id,'cost_class',v_rule.cost_class,
      'scope_key',v_rule.scope_key,'cost_method',v_rule.cost_method,
      'cost_value',v_rule.cost_value,'currency',v_rule.currency,
      'version_no',v_rule.version_no,
      'effective_from',v_rule.effective_from,
      'source_type',v_rule.source_type,
      'source_reference',v_rule.source_reference
    )
  );
  v_receipt:=jsonb_build_object(
    'rule_id',v_rule.id,'version_no',v_rule.version_no,
    'effective_from',v_rule.effective_from,'replayed',false
  );
  return app.v112_put_receipt(
    v_identity,'set_growth_cost_rule_v114',v_request_hash,
    jsonb_build_object(
      'business_id',p_business,'branch_id',p_branch,'actor',v_actor,
      'cost_class',p_cost_class,'scope_key',btrim(p_scope_key)
    ),
    v_receipt
  );
end $$;

-- v109 originally costed only a parent sale or retail product.  Itemized
-- service and package lines need their own evidence-backed scopes; otherwise a
-- mixed cart can only be costed by guessing from its parent sale kind.
alter table public.economic_cost_rules_v109
  drop constraint if exists economic_cost_rules_v109_scope_kind_check;
alter table public.economic_cost_rules_v109
  drop constraint if exists economic_cost_rules_v109_scope_check;
alter table public.economic_cost_rules_v109
  add constraint economic_cost_rules_v109_scope_kind_check
    check(scope_kind in ('sale_kind','product','service','package'));
alter table public.economic_cost_rules_v109
  add constraint economic_cost_rules_v109_scope_check check(
    (
      scope_kind='sale_kind'
      and scope_key in (
        'service','retail','membership','quick_sale','gift_card','package'
      )
    )
    or (
      scope_kind in ('product','service','package')
      and scope_key ~
        '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    )
  );

create or replace function public.set_effective_cost_rule_v109_v112_inner(
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
returns jsonb
language plpgsql
security definer
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
  if p_scope_kind not in ('sale_kind','product','service','package')
     or nullif(btrim(p_scope_key),'') is null then
    raise exception 'valid cost scope is required' using errcode='22023';
  end if;
  if p_scope_kind in ('product','service','package')
     and btrim(p_scope_key) !~
       '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    raise exception 'line cost scope must be a valid item UUID'
      using errcode='22023';
  end if;
  if p_scope_kind='sale_kind'
     and btrim(p_scope_key) not in (
       'service','retail','membership','quick_sale','gift_card','package'
     ) then
    raise exception 'valid sale kind cost scope is required'
      using errcode='22023';
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
    v_currency,p_source_type,btrim(p_source_reference),p_evidence,
    p_effective_from,v_version,v_actor,p_idempotency_key,v_request_hash
  ) returning * into v_rule;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(
    p_business,v_actor,'SET_EFFECTIVE_COST_RULE_V109',
    'economic_cost_rules_v109',v_rule.id,
    jsonb_build_object(
      'scope_kind',v_rule.scope_kind,'scope_key',v_rule.scope_key,
      'version_no',v_rule.version_no,'effective_from',v_rule.effective_from,
      'source_type',v_rule.source_type,
      'source_reference',v_rule.source_reference
    )
  );
  return jsonb_build_object(
    'rule_id',v_rule.id,'version_no',v_rule.version_no,
    'effective_from',v_rule.effective_from,'replayed',false
  );
end $$;

revoke all privileges on function
  public.set_effective_cost_rule_v109_v112_inner(
    uuid,uuid,text,text,text,bigint,text,text,jsonb,timestamptz,uuid
  )
from public,anon,authenticated,service_role;

create or replace function public.get_period_economics_v109 (
  p_business uuid,
  p_from date,
  p_to date,
  p_branch uuid default null,
  p_investment_cents bigint default null,
  p_investment_reference text default null,
  p_as_of timestamptz default statement_timestamp()
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_sales integer:=0;
  v_covered_sales integer:=0;
  v_sale_lines integer:=0;
  v_covered_sale_lines integer:=0;
  v_ambiguous_sale_lines integer:=0;
  v_revenue bigint:=0;
  v_covered_revenue bigint:=0;
  v_traceable_cogs bigint:=0;
  v_sale_transaction_coverage_bps integer;
  v_sale_revenue_coverage_bps integer;
  v_sale_coverage_passes boolean:=false;
  v_benefits integer:=0;
  v_covered_benefits integer:=0;
  v_benefit_value bigint:=0;
  v_covered_benefit_value bigint:=0;
  v_traceable_benefit_cost bigint:=0;
  v_benefit_coverage_bps integer;
  v_benefit_coverage_passes boolean:=true;
  v_deliveries integer:=0;
  v_covered_deliveries integer:=0;
  v_traceable_delivery_cost bigint:=0;
  v_delivery_coverage_bps integer;
  v_delivery_coverage_passes boolean:=true;
  v_coverage_passes boolean:=false;
  v_gross_profit bigint;
  v_contribution bigint;
  v_growth_investment bigint;
  v_total_investment bigint;
  v_net_return bigint;
  v_roi_bps bigint;
  v_unavailable jsonb:='[]'::jsonb;
  v_currency text;
  v_currency_count integer;
  v_extra_reference text;
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
  if p_investment_cents>0
     and length(btrim(coalesce(p_investment_reference,'')))<3 then
    raise exception 'positive additional investment requires a source reference'
      using errcode='22023';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches branch_row
    where branch_row.id=p_branch and branch_row.business_id=p_business
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

  with eligible as (
    select sale.*,contract.currency,
      app.v106_sale_residual_minor(
        sale.id,p_to,p_as_of
      ) as residual_cents
    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.counts_as_revenue and sale.reversal_of is null
      and sale.created_at<=p_as_of
      and (sale.occurred_at at time zone contract.timezone)::date>=p_from
      and (sale.occurred_at at time zone contract.timezone)::date<p_to
      and app.v106_sale_residual_minor(sale.id,p_to,p_as_of)>0
  ), sale_shape as (
    select sale.*,
      exists(
        select 1 from public.sale_items item
        where item.business_id=p_business and item.sale_id=sale.id
      ) as is_itemized,
      coalesce((
        select sum(item.line_cents)
        from public.sale_items item
        where item.business_id=p_business and item.sale_id=sale.id
          and item.line_cents>0
      ),0)::bigint as positive_line_cents
    from eligible sale
  ), itemized_base as (
    select sale.id as sale_id,item.id as cost_line_key,
      sale.branch_id,sale.occurred_at,sale.currency,sale.kind as sale_kind,
      true as is_itemized,item.qty,item.line_cents as source_line_cents,
      case
        when item.item_type='retail' and item.product_id is not null
          then 'product'
        when item.item_type='service' and item.ref_id is not null
          then 'service'
        when item.item_type='package' and item.ref_id is not null
          then 'package'
        else null
      end as desired_scope_kind,
      case
        when item.item_type='retail' and item.product_id is not null
          then item.product_id::text
        when item.item_type in ('service','package') and item.ref_id is not null
          then item.ref_id::text
        else null
      end as desired_scope_key,
      sale.amount_cents as sale_original_cents,
      sale.residual_cents as sale_residual_cents,
      floor(
        sale.residual_cents::numeric*item.line_cents
        /sale.positive_line_cents
      )::bigint as allocated_base_cents,
      mod(
        sale.residual_cents::numeric*item.line_cents,
        sale.positive_line_cents
      ) as allocation_remainder
    from sale_shape sale
    join public.sale_items item
      on item.business_id=p_business and item.sale_id=sale.id
    where sale.is_itemized and sale.positive_line_cents>0
      and item.line_cents>0
  ), itemized_ranked as (
    select itemized_base.*,
      itemized_base.sale_residual_cents
        -sum(itemized_base.allocated_base_cents) over(
          partition by itemized_base.sale_id
        ) as remainder_to_assign,
      row_number() over(
        partition by itemized_base.sale_id
        order by itemized_base.allocation_remainder desc,
          itemized_base.cost_line_key
      ) as allocation_rank
    from itemized_base
  ), economic_lines as (
    select sale_id,cost_line_key,branch_id,occurred_at,currency,sale_kind,
      is_itemized,qty,source_line_cents,desired_scope_kind,desired_scope_key,
      sale_original_cents,sale_residual_cents,
      allocated_base_cents
        +case when allocation_rank<=remainder_to_assign then 1 else 0 end
        as allocated_cents
    from itemized_ranked
    union all
    -- An itemized parent with no positive economic line is never silently
    -- reclassified as a parent sale.  Keep one uncovered line so the report
    -- fails closed while still reconciling its full residual revenue.
    select sale.id,sale.id,sale.branch_id,sale.occurred_at,sale.currency,
      sale.kind,true,coalesce(sale.qty,1),greatest(sale.amount_cents,1),
      null::text,null::text,sale.amount_cents,sale.residual_cents,
      sale.residual_cents
    from sale_shape sale
    where sale.is_itemized and sale.positive_line_cents=0
    union all
    -- Sale-kind fallback exists only for genuinely non-itemized legacy rows.
    select sale.id,sale.id,sale.branch_id,sale.occurred_at,sale.currency,
      sale.kind,false,coalesce(sale.qty,1),greatest(sale.amount_cents,1),
      case when sale.product_id is not null then 'product' else 'sale_kind' end,
      case
        when sale.product_id is not null then sale.product_id::text
        else sale.kind
      end,
      sale.amount_cents,sale.residual_cents,
      sale.residual_cents
    from sale_shape sale
    where not sale.is_itemized
  ), candidate_pool as (
    select line.*,candidate.id as candidate_rule_id,
      candidate.cost_method,candidate.cost_value,
      candidate.effective_from,candidate.version_no,
      case
        when candidate.scope_kind=line.desired_scope_kind
          and candidate.scope_key=line.desired_scope_key then 0
        when not line.is_itemized and candidate.scope_kind='sale_kind'
          and candidate.scope_key=line.sale_kind then 1
        else 2
      end as scope_priority,
      case when candidate.branch_id=line.branch_id then 0 else 1 end
        as branch_priority
    from economic_lines line
    left join public.economic_cost_rules_v109 candidate
      on candidate.business_id=p_business
      and candidate.currency=line.currency
      and (candidate.branch_id is null or candidate.branch_id=line.branch_id)
      and candidate.effective_from<=line.occurred_at
      and (
        candidate.effective_to is null
        or candidate.effective_to>line.occurred_at
      )
      and (
        (
          candidate.scope_kind=line.desired_scope_kind
          and candidate.scope_key=line.desired_scope_key
        )
        or (
          not line.is_itemized
          and line.desired_scope_kind='product'
          and candidate.scope_kind='sale_kind'
          and candidate.scope_key=line.sale_kind
        )
      )
  ), ranked_candidates as (
    select candidate_pool.*,
      row_number() over(
        partition by sale_id,cost_line_key
        order by scope_priority,branch_priority,
          effective_from desc nulls last,version_no desc nulls last
      ) as selection_rank,
      count(candidate_rule_id) over(
        partition by sale_id,cost_line_key,scope_priority,branch_priority,
          effective_from
      ) as equal_precedence_rules
    from candidate_pool
  ), selected as (
    select *,
      candidate_rule_id is not null and equal_precedence_rules=1
        as is_covered,
      candidate_rule_id is not null and equal_precedence_rules>1
        as is_ambiguous,
      case
        when candidate_rule_id is null or equal_precedence_rules<>1 then null
        when cost_method='revenue_bps' then
          round(allocated_cents*cost_value::numeric/10000)::bigint
        when cost_method='fixed_per_unit' then
          round(
            cost_value*qty*sale_residual_cents::numeric
            /greatest(sale_original_cents,1)
          )::bigint
        else null
      end as cost_cents
    from ranked_candidates
    where selection_rank=1
  ), sale_summary as (
    select sale_id,count(*)::integer as eligible_lines,
      count(*) filter(where is_covered)::integer as covered_lines,
      count(*) filter(where is_ambiguous)::integer as ambiguous_lines,
      sum(allocated_cents)::bigint as revenue_cents,
      coalesce(sum(allocated_cents) filter(where is_covered),0)::bigint
        as covered_revenue_cents,
      coalesce(sum(cost_cents) filter(where is_covered),0)::bigint
        as cost_cents
    from selected
    group by sale_id
  )
  select count(*)::integer,
    count(*) filter(
      where covered_lines=eligible_lines and ambiguous_lines=0
    )::integer,
    coalesce(sum(eligible_lines),0)::integer,
    coalesce(sum(covered_lines),0)::integer,
    coalesce(sum(ambiguous_lines),0)::integer,
    coalesce(sum(revenue_cents),0)::bigint,
    coalesce(sum(covered_revenue_cents),0)::bigint,
    coalesce(sum(cost_cents),0)::bigint
  into v_sales,v_covered_sales,v_sale_lines,v_covered_sale_lines,
    v_ambiguous_sale_lines,v_revenue,v_covered_revenue,v_traceable_cogs
  from sale_summary;

  with eligible as (
    select entitlement.id,entitlement.value_cents,
      entitlement.entitlement_type,entitlement.redeemed_at,
      execution_row.branch_id,contract.currency
    from public.growth_entitlements_v108 entitlement
    join public.growth_executions_v108 execution_row
      on execution_row.id=entitlement.execution_id
      and execution_row.business_id=entitlement.business_id
    cross join lateral app.v106_reporting_contract(
      entitlement.business_id,execution_row.branch_id,entitlement.redeemed_at
    ) contract
    left join lateral (
      select event_row.sale_id,reversal_sale.occurred_at
      from public.growth_entitlement_events_v108 event_row
      join public.sales reversal_sale
        on reversal_sale.id=event_row.sale_id
        and reversal_sale.business_id=event_row.business_id
      where event_row.entitlement_id=entitlement.id
        and event_row.business_id=entitlement.business_id
        and event_row.event_type='reversed'
        and event_row.created_at<=p_as_of
        and reversal_sale.created_at<=p_as_of
        and reversal_sale.reversal_of=entitlement.redeemed_sale_id
      order by event_row.created_at desc,event_row.id desc
      limit 1
    ) reversal_evidence on true
    left join lateral app.v106_reporting_contract(
      entitlement.business_id,execution_row.branch_id,
      reversal_evidence.occurred_at
    ) reversal_contract on reversal_evidence.sale_id is not null
    where entitlement.business_id=p_business
      and (p_branch is null or execution_row.branch_id=p_branch)
      and entitlement.redeemed_at is not null
      and entitlement.redeemed_at<=p_as_of
      and (
        entitlement.reversed_at is null
        or entitlement.reversed_at>p_as_of
        or (
          entitlement.reversed_at<=p_as_of
          and reversal_evidence.sale_id is not null
          and (
            reversal_evidence.occurred_at
              at time zone reversal_contract.timezone
          )::date>=p_to
        )
      )
      and (
        entitlement.redeemed_at at time zone contract.timezone
      )::date>=p_from
      and (
        entitlement.redeemed_at at time zone contract.timezone
      )::date<p_to
  ), matched as (
    select benefit.id,benefit.value_cents,rule_row.id as rule_id,
      case
        when rule_row.cost_method='value_bps' then
          round(
            benefit.value_cents*rule_row.cost_value::numeric/10000
          )::bigint
        when rule_row.cost_method='fixed_per_event' then rule_row.cost_value
        else null
      end as cost_cents
    from eligible benefit
    left join lateral (
      select candidate.*
      from public.growth_cost_rules_v114 candidate
      where candidate.business_id=p_business
        and candidate.cost_class='benefit'
        and candidate.scope_key=benefit.entitlement_type
        and candidate.currency=benefit.currency
        and (
          candidate.branch_id is null
          or candidate.branch_id=benefit.branch_id
        )
        and candidate.effective_from<=benefit.redeemed_at
        and (
          candidate.effective_to is null
          or candidate.effective_to>benefit.redeemed_at
        )
      order by
        case when candidate.branch_id=benefit.branch_id then 0 else 1 end,
        candidate.effective_from desc,candidate.version_no desc
      limit 1
    ) rule_row on true
  )
  select count(*),count(*) filter(where rule_id is not null),
    coalesce(sum(value_cents),0),
    coalesce(sum(value_cents) filter(where rule_id is not null),0),
    coalesce(sum(cost_cents) filter(where rule_id is not null),0)
  into v_benefits,v_covered_benefits,v_benefit_value,
    v_covered_benefit_value,v_traceable_benefit_cost
  from matched;

  with eligible as (
    select dispatch.id,dispatch.branch_id,dispatch.provider,
      dispatch.delivered_at,contract.currency
    from public.growth_delivery_dispatches_v110 dispatch
    cross join lateral app.v106_reporting_contract(
      dispatch.business_id,dispatch.branch_id,dispatch.delivered_at
    ) contract
    where dispatch.business_id=p_business
      and (p_branch is null or dispatch.branch_id=p_branch)
      and dispatch.delivered_at is not null
      and dispatch.delivered_at<=p_as_of
      and (
        dispatch.delivered_at at time zone contract.timezone
      )::date>=p_from
      and (
        dispatch.delivered_at at time zone contract.timezone
      )::date<p_to
  ), matched as (
    select delivery.id,rule_row.id as rule_id,
      rule_row.cost_value as cost_cents
    from eligible delivery
    left join lateral (
      select candidate.*
      from public.growth_cost_rules_v114 candidate
      where candidate.business_id=p_business
        and candidate.cost_class='delivery'
        and candidate.scope_key=delivery.provider
        and candidate.currency=delivery.currency
        and (
          candidate.branch_id is null
          or candidate.branch_id=delivery.branch_id
        )
        and candidate.effective_from<=delivery.delivered_at
        and (
          candidate.effective_to is null
          or candidate.effective_to>delivery.delivered_at
        )
      order by
        case when candidate.branch_id=delivery.branch_id then 0 else 1 end,
        candidate.effective_from desc,candidate.version_no desc
      limit 1
    ) rule_row on true
  )
  select count(*),count(*) filter(where rule_id is not null),
    coalesce(sum(cost_cents) filter(where rule_id is not null),0)
  into v_deliveries,v_covered_deliveries,v_traceable_delivery_cost
  from matched;

  v_sale_transaction_coverage_bps:=case
    when v_sales=0 then null
    else round(v_covered_sales*10000.0/v_sales)::integer
  end;
  v_sale_revenue_coverage_bps:=case
    when v_revenue=0 then null
    else round(v_covered_revenue*10000.0/v_revenue)::integer
  end;
  v_sale_coverage_passes:=v_sales>0
    and v_sale_lines>0
    and v_covered_sales=v_sales
    and v_covered_sale_lines=v_sale_lines
    and v_ambiguous_sale_lines=0
    and v_covered_revenue=v_revenue;
  v_benefit_coverage_bps:=case
    when v_benefits=0 then null
    else round(v_covered_benefits*10000.0/v_benefits)::integer
  end;
  v_benefit_coverage_passes:=v_benefits=0
    or v_covered_benefits=v_benefits;
  v_delivery_coverage_bps:=case
    when v_deliveries=0 then null
    else round(v_covered_deliveries*10000.0/v_deliveries)::integer
  end;
  v_delivery_coverage_passes:=v_deliveries=0
    or v_covered_deliveries=v_deliveries;
  v_coverage_passes:=v_sale_coverage_passes
    and v_benefit_coverage_passes and v_delivery_coverage_passes;

  if v_sales=0 then
    v_unavailable:=v_unavailable||jsonb_build_array('no_eligible_sales');
  elsif not v_sale_coverage_passes then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('incomplete_traceable_sale_cost_coverage');
  end if;
  if v_ambiguous_sale_lines>0 then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('ambiguous_traceable_sale_cost_rules');
  end if;
  if not v_benefit_coverage_passes then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('incomplete_traceable_benefit_cost_coverage');
  end if;
  if not v_delivery_coverage_passes then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('incomplete_traceable_delivery_cost_coverage');
  end if;

  if v_coverage_passes then
    v_gross_profit:=v_revenue-v_traceable_cogs;
    v_contribution:=v_gross_profit-v_traceable_benefit_cost
      -v_traceable_delivery_cost;
    v_growth_investment:=v_traceable_benefit_cost+v_traceable_delivery_cost;
    v_total_investment:=v_growth_investment+coalesce(p_investment_cents,0);
    if v_total_investment>0 then
      v_net_return:=v_contribution-coalesce(p_investment_cents,0);
      v_roi_bps:=round(v_net_return*10000.0/v_total_investment);
    else
      v_unavailable:=v_unavailable
        ||jsonb_build_array('positive_traceable_investment_required');
    end if;
  end if;
  v_extra_reference:=nullif(btrim(coalesce(p_investment_reference,'')),'');

  return jsonb_build_object(
    'contract_version','period_economics_v109',
    'cost_contract_version','growth_costs_v114',
    'business_id',p_business,'as_of',p_as_of,
    'period',jsonb_build_object(
      'from',p_from,'to',p_to,'basis','business_local_date'
    ),
    'status',case
      when v_sales=0 then 'no_data'
      when v_coverage_passes then 'ready'
      else 'insufficient_cost_coverage'
    end,
    'coverage',jsonb_build_object(
      'cost_contract_version','growth_costs_v114',
      'eligible_sales',v_sales,'covered_sales',v_covered_sales,
      'eligible_sale_lines',v_sale_lines,
      'covered_sale_lines',v_covered_sale_lines,
      'ambiguous_sale_lines',v_ambiguous_sale_lines,
      'transaction_coverage_bps',v_sale_transaction_coverage_bps,
      'eligible_revenue_cents',v_revenue,
      'covered_revenue_cents',v_covered_revenue,
      'revenue_coverage_bps',v_sale_revenue_coverage_bps,
      'sale_cost_coverage_passes',v_sale_coverage_passes,
      'eligible_redeemed_benefits',v_benefits,
      'covered_redeemed_benefits',v_covered_benefits,
      'eligible_redeemed_benefit_value_cents',v_benefit_value,
      'covered_redeemed_benefit_value_cents',v_covered_benefit_value,
      'benefit_cost_coverage_bps',v_benefit_coverage_bps,
      'benefit_cost_coverage_passes',v_benefit_coverage_passes,
      'eligible_deliveries',v_deliveries,
      'covered_deliveries',v_covered_deliveries,
      'delivery_cost_coverage_bps',v_delivery_coverage_bps,
      'delivery_cost_coverage_passes',v_delivery_coverage_passes,
      'traceable_cost_coverage_passes',v_coverage_passes
    ),
    'profit',case when v_coverage_passes then jsonb_build_object(
      'currency',v_currency,'revenue_cents',v_revenue,
      'traceable_cogs_cents',v_traceable_cogs,
      'gross_profit_before_growth_costs_cents',v_gross_profit,
      'traceable_benefit_cost_cents',v_traceable_benefit_cost,
      'traceable_delivery_cost_cents',v_traceable_delivery_cost,
      'traceable_growth_cost_cents',
        v_traceable_benefit_cost+v_traceable_delivery_cost,
      'total_traceable_cost_cents',
        v_traceable_cogs+v_traceable_benefit_cost+v_traceable_delivery_cost,
      'contribution_after_growth_costs_cents',v_contribution,
      -- Compatibility alias: this is gross profit before growth costs.
      'gross_profit_cents',v_gross_profit
    ) else 'null'::jsonb end,
    'roi',case when v_roi_bps is not null then jsonb_build_object(
      'investment_cents',v_total_investment,
      'traceable_growth_investment_cents',v_growth_investment,
      'additional_investment_cents',coalesce(p_investment_cents,0),
      'investment_reference',case
        when v_extra_reference is null then 'v114 traceable benefit and delivery cost rules'
        else 'v114 traceable growth costs + '||v_extra_reference
      end,
      'additional_investment_reference',v_extra_reference,
      'net_return_cents',v_net_return,
      'return_on_investment_bps',v_roi_bps
    ) else 'null'::jsonb end,
    'unavailable_reasons',v_unavailable,
    'limitations',jsonb_build_array(
      'profit and contribution are returned only at complete sale-line, redeemed-benefit and delivery cost coverage',
      'itemized sale residuals, including in-period refunds, are allocated proportionally with deterministic largest-remainder rounding',
      'fixed unit costs preserve full unit COGS across checkout discounts and are reduced only by the sale refund survival ratio',
      'benefit reversals use the recorded reversal sale business date rather than the entitlement wall-clock update time',
      'sale-kind cost fallback is used only for genuinely non-itemized legacy sales',
      'ROI uses traceable redeemed-benefit and delivered-provider costs plus any separately sourced additional investment',
      'this period result is descriptive and is not a causal increment claim'
    )
  );
end $$;

revoke all privileges on table public.growth_cost_rules_v114
from public,anon,authenticated;

revoke all privileges on function public.set_growth_cost_rule_v114(
  uuid,uuid,text,text,text,bigint,text,text,jsonb,timestamptz,uuid
) from public,anon;
revoke all privileges on function public.get_period_economics_v109(
  uuid,date,date,uuid,bigint,text,timestamptz
) from public,anon;

grant execute on function public.set_growth_cost_rule_v114(
  uuid,uuid,text,text,text,bigint,text,text,jsonb,timestamptz,uuid
) to authenticated;
grant execute on function public.get_period_economics_v109(
  uuid,date,date,uuid,bigint,text,timestamptz
) to authenticated;

comment on table public.growth_cost_rules_v114 is
  'Effective-dated, source-referenced cost rules for redeemed benefits and delivered providers. Direct browser mutation is denied.';
comment on function public.set_growth_cost_rule_v114(
  uuid,uuid,text,text,text,bigint,text,text,jsonb,timestamptz,uuid
) is
  'Finance-gated append-only benefit/delivery cost rule with concurrency-safe idempotent receipt replay.';
comment on function public.get_period_economics_v109(
  uuid,date,date,uuid,bigint,text,timestamptz
) is
  'Stable v109 response contract extended by v114: profit, contribution and ROI are withheld until sale, redeemed-benefit and delivered-provider costs are fully traceable.';

commit;
