-- Nestly v107 — precise customer lifecycle semantics.
--
-- Lifecycle labels are not synonyms:
--   first-ever purchase    earliest eligible purchase in the business
--   new customer           first-ever purchase falls in [p_from,p_to)
--   existing returning     purchased before p_from and again in [p_from,p_to)
--   repeat in period       at least two purchases in [p_from,p_to), regardless of age
--   reactivated            first in-period purchase follows a lapse greater than the
--                          effective customer/business threshold
--
-- Branch reports use business-wide customer history for identity and lapse evidence, but
-- only selected-branch purchases for period activity.  This prevents a branch from calling
-- an established customer "new" merely because it cannot see another outlet.

begin;

create table public.customer_lifecycle_policies_v107 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  version_no integer not null check (version_no > 0),
  effective_from timestamptz not null,
  fallback_lapse_days integer not null check (fallback_lapse_days between 1 and 3650),
  customer_interval_min_observations integer not null default 3
    check (customer_interval_min_observations between 2 and 100),
  reactivation_multiplier numeric(8,3) not null default 2.000
    check (reactivation_multiplier between 1.000 and 20.000),
  note text,
  legacy_assumption boolean not null default false,
  created_at timestamptz not null default clock_timestamp(),
  created_by uuid default auth.uid(),
  constraint customer_lifecycle_policy_v107_business_version_uk
    unique (business_id, version_no),
  constraint customer_lifecycle_policy_v107_business_effective_uk
    unique (business_id, effective_from),
  constraint customer_lifecycle_policy_v107_id_business_uk unique (id, business_id)
);

create index customer_lifecycle_policy_v107_lookup_idx
  on public.customer_lifecycle_policies_v107
  (business_id, effective_from desc, version_no desc);

comment on table public.customer_lifecycle_policies_v107 is
  'Append-only, effective-dated lapse policy for v107 customer lifecycle classification.';
comment on column public.customer_lifecycle_policies_v107.customer_interval_min_observations is
  'Minimum number of measured purchase-to-purchase intervals required before customer cadence replaces the business fallback.';

insert into public.customer_lifecycle_policies_v107(
  business_id, version_no, effective_from, fallback_lapse_days,
  customer_interval_min_observations, reactivation_multiplier,
  note, legacy_assumption, created_by
)
select b.id, 1, '-infinity'::timestamptz, 90, 3, 2.000,
       'v107 migration default: 90-day fallback until business cadence is configured',
       true, null
  from public.businesses b;

create or replace function app.v107_append_only_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception '% is append-only: % is not permitted', tg_table_name, tg_op
    using errcode = 'restrict_violation';
end $$;

create or replace function app.v107_seed_business_policy()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  insert into public.customer_lifecycle_policies_v107(
    business_id, version_no, effective_from, fallback_lapse_days,
    customer_interval_min_observations, reactivation_multiplier,
    note, legacy_assumption, created_by
  ) values (
    new.id, 1, '-infinity'::timestamptz, 90, 3, 2.000,
    'v107 default for business created after migration', false, null
  );
  return new;
end $$;

create trigger trg_customer_lifecycle_policy_v107_append_only
  before update or delete on public.customer_lifecycle_policies_v107
  for each row execute function app.v107_append_only_guard();
create trigger trg_customer_lifecycle_policy_v107_business_insert
  after insert on public.businesses
  for each row execute function app.v107_seed_business_policy();

alter table public.customer_lifecycle_policies_v107 enable row level security;
revoke all on table public.customer_lifecycle_policies_v107
  from public, anon, authenticated;
grant select on table public.customer_lifecycle_policies_v107 to authenticated;

create policy customer_lifecycle_policy_v107_finance_read
  on public.customer_lifecycle_policies_v107 for select to authenticated
  using (
    app.is_super_admin()
    or (
      app.has_perm(business_id, 'view_finance')
      and app.can_see_branch(business_id, null)
    )
  );

create or replace function public.set_customer_lifecycle_policy_v107(
  p_business uuid,
  p_fallback_lapse_days integer,
  p_customer_interval_min_observations integer default 3,
  p_reactivation_multiplier numeric default 2.000,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_version integer;
  v_row public.customer_lifecycle_policies_v107%rowtype;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not (app.is_super_admin() or app.is_salon_owner(p_business)) then
    raise exception 'owner or super-admin required' using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, null) then
    raise exception 'business-wide lifecycle policy is outside actor scope'
      using errcode = '42501';
  end if;
  if not exists (select 1 from public.businesses where id = p_business) then
    raise exception 'business not found' using errcode = '23503';
  end if;
  if p_fallback_lapse_days not between 1 and 3650
     or p_customer_interval_min_observations not between 2 and 100
     or p_reactivation_multiplier not between 1.000 and 20.000 then
    raise exception 'lifecycle policy values are outside supported bounds'
      using errcode = '22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_business::text, 107)
  );
  select coalesce(max(version_no), 0) + 1 into v_version
    from public.customer_lifecycle_policies_v107 where business_id = p_business;
  insert into public.customer_lifecycle_policies_v107(
    business_id, version_no, effective_from, fallback_lapse_days,
    customer_interval_min_observations, reactivation_multiplier,
    note, legacy_assumption
  ) values (
    p_business, v_version, clock_timestamp(), p_fallback_lapse_days,
    p_customer_interval_min_observations, p_reactivation_multiplier,
    nullif(btrim(p_note), ''), false
  ) returning * into v_row;
  return jsonb_build_object(
    'status', 'created',
    'policy_id', v_row.id,
    'version_no', v_row.version_no,
    'effective_from', v_row.effective_from,
    'fallback_lapse_days', v_row.fallback_lapse_days,
    'customer_interval_min_observations', v_row.customer_interval_min_observations,
    'reactivation_multiplier', v_row.reactivation_multiplier
  );
end $$;

create or replace function public.get_customer_lifecycle_v107(
  p_business uuid,
  p_from date,
  p_to date,
  p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp()
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_policy public.customer_lifecycle_policies_v107%rowtype;
  v_timezone text;
  v_currency text;
  v_business_wide_identity boolean;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_to <= p_from then
    raise exception 'p_to must be after p_from' using errcode = '22023';
  end if;
  if not (app.is_super_admin() or app.has_perm(p_business, 'view_finance')) then
    raise exception 'finance permission required' using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'branch is outside actor scope' using errcode = '42501';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches b
     where b.id = p_branch and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to business' using errcode = '23503';
  end if;
  v_business_wide_identity := app.can_see_branch(p_business, null);
  select * into strict v_policy
    from public.customer_lifecycle_policies_v107 p
   where p.business_id = p_business and p.effective_from <= p_as_of
   order by p.effective_from desc, p.version_no desc limit 1;
  select upper(currency) into strict v_currency
    from public.businesses where id = p_business;
  if p_branch is null then
    v_timezone := 'per_outlet';
  else
    select timezone into strict v_timezone
      from public.branches where id = p_branch and business_id = p_business;
  end if;

  with eligible as materialized (
    select s.id,
           app.v111_effective_client_id(s.business_id, s.client_id) as client_id,
           s.branch_id, s.occurred_at, s.created_at,
           s.amount_cents, c.timezone,
           app.v106_sale_residual_minor(s.id, p_to, p_as_of)
             as residual_minor
      from public.sales s
      cross join lateral app.v106_reporting_contract(
        s.business_id, s.branch_id, s.occurred_at
      ) c
     where s.business_id = p_business
       and s.reversal_of is null
       and s.counts_as_visit
       and s.created_at <= p_as_of
       and (
         v_business_wide_identity
         or (p_branch is not null and s.branch_id = p_branch)
       )
  ), sequenced as (
    select e.*,
           min(e.occurred_at) over (partition by e.client_id) as first_ever_at,
           first_value((e.occurred_at at time zone e.timezone)::date) over (
             partition by e.client_id order by e.occurred_at, e.id
           ) as first_ever_business_date,
           lag(e.occurred_at) over (
             partition by e.client_id order by e.occurred_at, e.id
           ) as previous_purchase_at,
           row_number() over (
             partition by e.client_id order by e.occurred_at, e.id
           ) as purchase_sequence,
           ((e.occurred_at at time zone e.timezone)::date >= p_from
             and (e.occurred_at at time zone e.timezone)::date < p_to
             and (p_branch is null or e.branch_id = p_branch)) as in_selected_period
      from eligible e
     where e.residual_minor > 0
  ), interval_evidence as (
    select client_id,
           count(*) filter (where previous_purchase_at is not null)::integer
             as interval_observations,
           percentile_cont(0.5) within group (
             order by extract(epoch from (occurred_at - previous_purchase_at)) / 86400.0
           ) filter (where previous_purchase_at is not null)
             as median_interval_days
      from sequenced
     where client_id is not null
       and (occurred_at at time zone timezone)::date < p_from
     group by client_id
  ), customer_activity as (
    select s.client_id,
           count(*) filter (where s.in_selected_period)::integer as period_purchases,
           min(s.occurred_at) filter (where s.in_selected_period) as first_period_at,
           min(s.first_ever_at) as first_ever_at,
           bool_or(
             (s.occurred_at at time zone s.timezone)::date < p_from
           ) as purchased_before_period
      from sequenced s
     where s.client_id is not null
     group by s.client_id
    having count(*) filter (where s.in_selected_period) > 0
  ), first_period_evidence as (
    select distinct on (s.client_id)
           s.client_id, s.previous_purchase_at, s.timezone,
           s.first_ever_business_date
      from sequenced s
      join customer_activity a
        on a.client_id = s.client_id and a.first_period_at = s.occurred_at
     where s.in_selected_period
     order by s.client_id, s.occurred_at, s.id
  ), classified as (
    select a.*,
           f.previous_purchase_at,
           f.first_ever_business_date,
           coalesce(i.interval_observations, 0) as interval_observations,
           i.median_interval_days,
           case
             when coalesce(i.interval_observations, 0)
                    >= v_policy.customer_interval_min_observations
               then greatest(
                 1.0,
                 i.median_interval_days * v_policy.reactivation_multiplier
               )
             else v_policy.fallback_lapse_days::numeric
           end as effective_lapse_days,
           case
             when coalesce(i.interval_observations, 0)
                    >= v_policy.customer_interval_min_observations
               then 'customer_median_interval'
             else 'business_fallback'
           end as lapse_evidence_source
      from customer_activity a
      join first_period_evidence f using (client_id)
      left join interval_evidence i using (client_id)
  ), totals as (
    select
      count(*)::bigint as transacting_identified_customers,
      count(*) filter (
        where first_ever_business_date >= p_from
          and first_ever_business_date < p_to
      )::bigint as new_customers,
      count(*) filter (where purchased_before_period)::bigint
        as existing_returning_customers,
      count(*) filter (where period_purchases >= 2)::bigint
        as repeat_purchasers_in_period,
      count(*) filter (
        where purchased_before_period
          and previous_purchase_at is not null
          and extract(epoch from (first_period_at - previous_purchase_at)) / 86400.0
                > effective_lapse_days
      )::bigint as reactivated_customers,
      count(*) filter (
        where lapse_evidence_source = 'customer_median_interval'
      )::bigint as customer_cadence_classifications,
      count(*) filter (
        where lapse_evidence_source = 'business_fallback'
      )::bigint as fallback_classifications
    from classified
  ), transaction_coverage as (
    select
      count(*) filter (
        where (occurred_at at time zone timezone)::date >= p_from
          and (occurred_at at time zone timezone)::date < p_to
          and (p_branch is null or branch_id = p_branch)
          and residual_minor > 0
      )::bigint as eligible_transactions,
      count(*) filter (
        where (occurred_at at time zone timezone)::date >= p_from
          and (occurred_at at time zone timezone)::date < p_to
          and (p_branch is null or branch_id = p_branch)
          and residual_minor > 0 and client_id is not null
      )::bigint as identified_transactions,
      max(occurred_at) filter (
        where (occurred_at at time zone timezone)::date >= p_from
          and (occurred_at at time zone timezone)::date < p_to
          and (p_branch is null or branch_id = p_branch)
          and residual_minor > 0
      ) as latest_purchase_occurred_at
    from eligible
  )
  select jsonb_build_object(
    'contract_version', 'v107.1',
    'generated_at', clock_timestamp(),
    'as_of', p_as_of,
    'scope', jsonb_build_object(
      'business_id', p_business,
      'branch_id', p_branch,
      'period', jsonb_build_object(
        'from', p_from, 'to', p_to, 'interval', '[from,to)'
      ),
      'timezone', v_timezone,
      'timezone_contract', case when p_branch is null
        then 'per_outlet_effective_timezone'
        else 'selected_outlet_effective_timezone'
      end,
      'currency', v_currency,
      'identity_scope', case when v_business_wide_identity
        then 'business'
        else 'selected_branch'
      end,
      'period_activity_scope', case when p_branch is null then 'business' else 'branch' end
    ),
    'status', case when x.eligible_transactions = 0 then 'no_data' else 'ok' end,
    'policy', jsonb_build_object(
      'id', v_policy.id,
      'version_no', v_policy.version_no,
      'effective_from', v_policy.effective_from,
      'fallback_lapse_days', v_policy.fallback_lapse_days,
      'customer_interval_min_observations',
        v_policy.customer_interval_min_observations,
      'reactivation_multiplier', v_policy.reactivation_multiplier,
      'legacy_assumption', v_policy.legacy_assumption
    ),
    'metrics', jsonb_build_object(
      'transacting_identified_customers', t.transacting_identified_customers,
      'new_customers', t.new_customers,
      'existing_returning_customers', t.existing_returning_customers,
      'repeat_purchasers_in_period', t.repeat_purchasers_in_period,
      'reactivated_customers', t.reactivated_customers,
      'existing_customer_share_pct',
        case when t.transacting_identified_customers = 0 then null
          else round(
            100 * t.existing_returning_customers::numeric
              / t.transacting_identified_customers, 2
          ) end,
      'repeat_in_period_rate_pct',
        case when t.transacting_identified_customers = 0 then null
          else round(
            100 * t.repeat_purchasers_in_period::numeric
              / t.transacting_identified_customers, 2
          ) end,
      'customer_cadence_classifications', t.customer_cadence_classifications,
      'fallback_classifications', t.fallback_classifications
    ),
    'coverage', jsonb_build_object(
      'eligible_transactions', x.eligible_transactions,
      'identified_transactions', x.identified_transactions,
      'identified_transaction_pct',
        case when x.eligible_transactions = 0 then null
          else round(
            100 * x.identified_transactions::numeric / x.eligible_transactions, 2
          ) end
    ),
    'freshness', jsonb_build_object(
      'latest_purchase_occurred_at', x.latest_purchase_occurred_at
    ),
    'definitions', jsonb_build_object(
      'first_ever_purchase',
        'earliest eligible counts_as_visit purchase in the business',
      'new_customer',
        'first-ever business purchase has a local business date in [from,to)',
      'existing_returning_customer',
        'at least one eligible purchase before from and at least one in [from,to)',
      'repeat_purchaser_in_period',
        'at least two eligible purchases in [from,to); not a synonym for returning',
      'reactivated_customer',
        'existing customer whose first in-period purchase follows a lapse strictly greater than the effective threshold',
      'effective_threshold',
        'customer median interval multiplied by policy multiplier when evidence is sufficient; otherwise policy fallback days'
    ),
    'formula_metadata', jsonb_build_object(
      'version', 'customer_lifecycle_v107_1',
      'eligible_purchase',
        'original sale with counts_as_visit=true, residual amount above zero, and created_at<=as_of',
      'identity_attribution',
        'immutable sales.client_id is resolved through app.v111_effective_client_id for current synchronized reporting',
      'existing_customer_share',
        'existing_returning_customers / transacting_identified_customers',
      'repeat_in_period_rate',
        'repeat_purchasers_in_period / transacting_identified_customers',
      'zero_denominator', 'ratios are null',
      'lapse_comparison', 'gap_days > effective_lapse_days'
    ),
    'limitations', jsonb_build_array(
      'Anonymous purchases contribute to identity coverage but cannot be lifecycle-classified.',
      'Customer-specific cadence uses only pre-period intervals to avoid future leakage.',
      'The migration default is 90 days until an owner or super-admin publishes a business policy.',
      'Lifecycle is aggregate reporting only and does not expose customer PII.'
    )
  ) into v_result
  from totals t cross join transaction_coverage x;
  return v_result;
end $$;

revoke all on function app.v107_append_only_guard()
  from public, anon, authenticated;
revoke all on function app.v107_seed_business_policy()
  from public, anon, authenticated;
revoke all on function public.set_customer_lifecycle_policy_v107(
  uuid, integer, integer, numeric, text
) from public, anon;
revoke all on function public.get_customer_lifecycle_v107(
  uuid, date, date, uuid, timestamptz
) from public, anon;
grant execute on function public.set_customer_lifecycle_policy_v107(
  uuid, integer, integer, numeric, text
) to authenticated;
grant execute on function public.get_customer_lifecycle_v107(
  uuid, date, date, uuid, timestamptz
) to authenticated;

commit;
