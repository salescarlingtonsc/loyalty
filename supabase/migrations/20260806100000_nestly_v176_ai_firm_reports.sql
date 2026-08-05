-- NESTLY v176 - SCHEDULED AI NARRATIVE REPORTS PER FIRM
--
-- Problem: the console's "Monthly consultant brief" is on-demand and purely
-- deterministic (v94 SQL). Nothing is stored, nothing is scheduled, and the
-- owner reads raw KPI tables rather than an explanation. The owner asked for a
-- recurring, written narrative per firm covering new customers, sales growth
-- and customer account opens.
--
-- Shape decision (recorded so it is not re-litigated):
--   * This migration owns STORAGE + CONTRACT ONLY. No LLM call happens in SQL.
--     The `ai-firm-reports` edge function claims queued rows, calls the Claude
--     Messages API once per row, and writes the narrative back.
--   * The evidence pack is assembled in SQL at CLAIM time, not at request time,
--     so a scheduled row and a "Generate now" row carry byte-identical evidence
--     and the row records exactly what was sent to the model.
--   * The evidence pack reuses the EXISTING authorities rather than restating
--     their maths: platform_get_assigned_firm_report_v94,
--     platform_get_catalogue_affinity_v94,
--     platform_get_consultative_recommendations_v94 and the new
--     platform_customer_account_opens_v175. Period-over-period growth and the
--     new-customer count are derived here from `public.sales` using the v10.1
--     per-sale policy snapshot (`counts_as_revenue` / `counts_as_visit`), which
--     is the same revenue definition v94 and v145 already use.
--   * Demo firms (v174 `businesses.is_demo`) are excluded everywhere, exactly
--     as the v94 subscription-lifecycle scan excludes them.
--
-- Internal-invocation pattern: this repo already uses pg_net + Vault for
-- cron -> edge function (v156 `app.v156_run_subscription_automation` posts to
-- /functions/v1/subscription-document-dispatch with an x-v156-dispatch-secret
-- header read from vault). v176 copies that pattern verbatim with its own
-- secret names, and degrades to enqueue-only when vault/net are absent.
--
-- Privacy: the evidence pack carries aggregates and catalogue item names only.
-- It never carries customer names, phone numbers, emails or free text.

begin;

-- ---------------------------------------------------------------------------
-- 1. Storage
-- ---------------------------------------------------------------------------

create table public.ai_firm_reports_v176(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  period_kind text not null
    check (period_kind in ('monthly','quarterly','yearly')),
  period_start date not null,
  period_end date not null,
  status text not null default 'pending'
    check (status in ('pending','generating','succeeded','failed')),
  model text,
  evidence jsonb,
  narrative_md text,
  error text,
  generation integer not null default 1 check (generation > 0),
  requested_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  claimed_at timestamptz,
  completed_at timestamptz,
  constraint ai_firm_reports_v176_period_order
    check (period_end >= period_start),
  constraint ai_firm_reports_v176_terminal_shape check (
    (status = 'succeeded'
      and narrative_md is not null
      and btrim(narrative_md) <> ''
      and completed_at is not null)
    or (status = 'failed'
      and error is not null
      and btrim(error) <> ''
      and completed_at is not null)
    or (status in ('pending','generating')
      and narrative_md is null
      and completed_at is null)
  )
);

create unique index ai_firm_reports_v176_period_uk
  on public.ai_firm_reports_v176(business_id, period_kind, period_start);
create index ai_firm_reports_v176_queue_idx
  on public.ai_firm_reports_v176(created_at, id)
  where status = 'pending';
create index ai_firm_reports_v176_business_idx
  on public.ai_firm_reports_v176(business_id, period_start desc, period_kind);

alter table public.ai_firm_reports_v176 enable row level security;
revoke all privileges on table public.ai_firm_reports_v176
  from public, anon, authenticated;

comment on table public.ai_firm_reports_v176 is
  'Scheduled and on-demand AI narrative reports per firm. Read-only to the API: every write path is a SECURITY DEFINER RPC. `evidence` is the exact pack sent to the model for the stored narrative.';

create or replace function app.v176_touch_updated_at()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end
$$;
revoke all privileges on function app.v176_touch_updated_at()
  from public, anon, authenticated, service_role;

create trigger ai_firm_reports_v176_touch
  before update on public.ai_firm_reports_v176
  for each row execute function app.v176_touch_updated_at();

-- ---------------------------------------------------------------------------
-- 2. Authorization helpers
--
-- Reading follows the existing consultant-brief rule
-- (app.platform_firm_report_access_v94: platform reports permission, or the
-- consultant this firm is assigned to). Requesting a NEW generation is
-- narrower - it spends money - so it is super admin or assigned consultant
-- only. Both helpers are SECURITY DEFINER wrappers because the underlying v94
-- helpers are revoked from `authenticated` and an RLS policy expression runs
-- as the querying role.
-- ---------------------------------------------------------------------------

create or replace function app.v176_is_assigned_consultant(p_business uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  select auth.uid() is not null
    and exists(
      select 1
      from app.assigned_consultant_v94(p_business) consultant
      where consultant.user_id = auth.uid()
    )
$$;
revoke all privileges on function app.v176_is_assigned_consultant(uuid)
  from public, anon, authenticated, service_role;
grant execute on function app.v176_is_assigned_consultant(uuid)
  to authenticated;

create or replace function app.v176_can_read_firm_report(p_business uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  select auth.uid() is not null
    and (
      app.is_super_admin()
      or app.platform_firm_report_access_v94(p_business)
    )
$$;
revoke all privileges on function app.v176_can_read_firm_report(uuid)
  from public, anon, authenticated, service_role;
grant execute on function app.v176_can_read_firm_report(uuid)
  to authenticated;

create policy ai_firm_reports_v176_read
  on public.ai_firm_reports_v176 for select to authenticated
  using (app.v176_can_read_firm_report(business_id));

-- No insert/update/delete policy exists at all: the table is API-unwritable by
-- every role, exactly like public.super_admins. Writes are SECURITY DEFINER
-- RPCs (request / claim / complete) or direct SQL.

-- ---------------------------------------------------------------------------
-- 3. Period arithmetic
-- ---------------------------------------------------------------------------

create or replace function app.v176_period_end(
  p_period_kind text,
  p_period_start date
)
returns date
language sql
immutable
set search_path = pg_catalog, public, app, pg_temp
as $$
  select case p_period_kind
    when 'monthly' then (p_period_start + interval '1 month' - interval '1 day')::date
    when 'quarterly' then (p_period_start + interval '3 months' - interval '1 day')::date
    when 'yearly' then (p_period_start + interval '1 year' - interval '1 day')::date
  end
$$;
revoke all privileges on function app.v176_period_end(text, date)
  from public, anon, authenticated, service_role;

create or replace function app.v176_period_prior_start(
  p_period_kind text,
  p_period_start date
)
returns date
language sql
immutable
set search_path = pg_catalog, public, app, pg_temp
as $$
  select case p_period_kind
    when 'monthly' then (p_period_start - interval '1 month')::date
    when 'quarterly' then (p_period_start - interval '3 months')::date
    when 'yearly' then (p_period_start - interval '1 year')::date
  end
$$;
revoke all privileges on function app.v176_period_prior_start(text, date)
  from public, anon, authenticated, service_role;

-- A period must be calendar-aligned and fully closed. Reporting on a period
-- that has not ended would produce a narrative the numbers later contradict.
create or replace function app.v176_assert_period(
  p_period_kind text,
  p_period_start date
)
returns date
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_today date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_end date;
begin
  if p_period_kind is null
     or p_period_kind not in ('monthly','quarterly','yearly') then
    raise exception 'period_kind must be monthly, quarterly or yearly'
      using errcode = '22023';
  end if;
  if p_period_start is null then
    raise exception 'period_start is required' using errcode = '22023';
  end if;
  if p_period_kind = 'monthly'
     and p_period_start <> date_trunc('month', p_period_start)::date then
    raise exception 'monthly period_start must be the first day of a month'
      using errcode = '22023';
  end if;
  if p_period_kind = 'quarterly'
     and p_period_start <> date_trunc('quarter', p_period_start)::date then
    raise exception 'quarterly period_start must be 1 Jan, 1 Apr, 1 Jul or 1 Oct'
      using errcode = '22023';
  end if;
  if p_period_kind = 'yearly'
     and p_period_start <> date_trunc('year', p_period_start)::date then
    raise exception 'yearly period_start must be 1 January'
      using errcode = '22023';
  end if;
  v_end := app.v176_period_end(p_period_kind, p_period_start);
  if v_end >= v_today then
    raise exception 'the requested period has not closed yet'
      using errcode = '22023';
  end if;
  if p_period_start < v_today - interval '5 years' then
    raise exception 'period_start is outside the supported reporting range'
      using errcode = '22023';
  end if;
  return v_end;
end
$$;
revoke all privileges on function app.v176_assert_period(text, date)
  from public, anon, authenticated, service_role;

-- Model routing lives in SQL so the claim record states which model produced
-- (or will produce) the narrative. The edge function must honour the stored
-- value rather than choosing its own.
create or replace function app.v176_model_for_period(p_period_kind text)
returns text
language sql
immutable
set search_path = pg_catalog, public, app, pg_temp
as $$
  select case p_period_kind
    when 'monthly' then 'claude-sonnet-5'
    else 'claude-opus-4-8'
  end
$$;
revoke all privileges on function app.v176_model_for_period(text)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Evidence assembly
--
-- 4a. Deterministic sales aggregate for one window. Revenue and visits are
--     judged by each sale's own v10.1 policy snapshot, so a sale that was not
--     revenue when it happened is not revenue in the report either.
-- ---------------------------------------------------------------------------

create or replace function app.v176_sales_window(
  p_business uuid,
  p_from date,
  p_to date
)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  with bounds as (
    select
      p_from::timestamp at time zone 'Asia/Singapore' as from_ts,
      (p_to + 1)::timestamp at time zone 'Asia/Singapore' as to_ts
  ), valid_sales as (
    select sale.id, sale.client_id, sale.amount_cents,
      coalesce(sale.counts_as_revenue, true) as counts_as_revenue,
      coalesce(sale.counts_as_visit, true) as counts_as_visit
    from public.sales sale, bounds
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
    select sale.client_id,
      min((sale.occurred_at at time zone 'Asia/Singapore')::date) as first_date
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and client.is_synthetic = false
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.client_id is not null
      and coalesce(sale.counts_as_visit, true)
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
    group by sale.client_id
  )
  select pg_catalog.jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', 'SGD',
    'net_revenue_cents', coalesce(
      (select sum(amount_cents) from valid_sales where counts_as_revenue), 0
    ),
    'revenue_transactions', (
      select count(*) from valid_sales where counts_as_revenue
    ),
    'visits', (select count(*) from valid_sales where counts_as_visit),
    'customers_served', (
      select count(distinct client_id)
      from valid_sales where client_id is not null
    ),
    'average_order_cents', coalesce(
      (select round(avg(amount_cents))::bigint
       from valid_sales where counts_as_revenue), 0
    ),
    'new_customers', (
      select count(*) from first_purchase
      where first_purchase.first_date between p_from and p_to
    )
  )
$$;
revoke all privileges on function app.v176_sales_window(uuid, date, date)
  from public, anon, authenticated, service_role;

-- 4b. Deterministic account-open totals for one window, read straight from the
--     v175 canonical day rows. Used for the prior-period comparison and as the
--     fallback when the gated v175 report RPC is unavailable.
create or replace function app.v176_account_opens_window(
  p_business uuid,
  p_from date,
  p_to date
)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  with window_rows as (
    select day_row.subject_key, day_row.open_date
    from public.customer_account_open_days_v175 day_row
    where day_row.business_id = p_business
      and day_row.open_date between p_from and p_to
  ), subject_first as (
    select day_row.subject_key, min(day_row.open_date) as first_open_date
    from public.customer_account_open_days_v175 day_row
    where day_row.business_id = p_business
    group by day_row.subject_key
  )
  select pg_catalog.jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'opens', (select count(*) from window_rows),
    'distinct_customers', (
      select count(distinct subject_key) from window_rows
    ),
    'first_time_customers', (
      select count(*) from subject_first
      where subject_first.first_open_date between p_from and p_to
    )
  )
$$;
revoke all privileges on function
  app.v176_account_opens_window(uuid, date, date)
  from public, anon, authenticated, service_role;

-- 4c. The gated evidence RPCs.
--
--     platform_get_assigned_firm_report_v94, platform_get_catalogue_affinity_v94,
--     platform_get_consultative_recommendations_v94 and
--     platform_customer_account_opens_v175 all require an authenticated,
--     authorized auth.uid(). A pg_cron / service-role caller has none, so a
--     scheduled report would otherwise carry strictly weaker evidence than a
--     hand-triggered one - the exact inconsistency this engine must not have.
--
--     Rather than duplicating (and drifting from) their SQL, this helper adopts
--     the platform's own super-admin identity for the duration of those four
--     READ-ONLY calls and restores the prior claims immediately, on both the
--     success and the failure path. It is granted to nobody: only SECURITY
--     DEFINER callers inside this migration reach it, and it never widens what
--     a human caller can already see. Reviewer: this is the one place in v176
--     that forges a request claim - it is deliberate and scoped.
create or replace function app.v176_gated_evidence(
  p_business uuid,
  p_from date,
  p_to date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_reader uuid;
  v_prior_sub text;
  v_prior_claims text;
  v_impersonated boolean := false;
  v_result jsonb;
begin
  if auth.uid() is null then
    select super_admin.user_id into v_reader
    from public.super_admins super_admin
    order by super_admin.user_id
    limit 1;
    if v_reader is null then
      return pg_catalog.jsonb_build_object(
        'available', false, 'reason', 'no_platform_reader'
      );
    end if;
    v_prior_sub := coalesce(
      pg_catalog.current_setting('request.jwt.claim.sub', true), ''
    );
    v_prior_claims := coalesce(
      pg_catalog.current_setting('request.jwt.claims', true), ''
    );
    perform pg_catalog.set_config(
      'request.jwt.claim.sub', v_reader::text, true
    );
    perform pg_catalog.set_config(
      'request.jwt.claims',
      pg_catalog.json_build_object(
        'sub', v_reader, 'role', 'authenticated', 'aud', 'authenticated'
      )::text,
      true
    );
    v_impersonated := true;
  end if;

  begin
    v_result := pg_catalog.jsonb_build_object(
      'available', true,
      'consultant_brief',
        public.platform_get_assigned_firm_report_v94(
          p_business, null, p_from, p_to
        ),
      'catalogue_affinity',
        public.platform_get_catalogue_affinity_v94(
          p_business, null, p_from, p_to, 25
        ),
      'recommendations',
        public.platform_get_consultative_recommendations_v94(
          p_business, null, p_from, p_to, 25
        ),
      'account_opens_report',
        public.platform_customer_account_opens_v175(p_business, p_from, p_to)
    );
  exception when others then
    v_result := pg_catalog.jsonb_build_object(
      'available', false, 'reason', 'evidence_rpc_unavailable'
    );
  end;

  if v_impersonated then
    perform pg_catalog.set_config(
      'request.jwt.claim.sub', v_prior_sub, true
    );
    perform pg_catalog.set_config(
      'request.jwt.claims', v_prior_claims, true
    );
  end if;
  return v_result;
end
$$;
revoke all privileges on function app.v176_gated_evidence(uuid, date, date)
  from public, anon, authenticated, service_role;

-- 4d. The pack itself.
create or replace function app.v176_evidence_pack(
  p_business uuid,
  p_period_kind text,
  p_period_start date,
  p_period_end date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_business record;
  v_prior_start date := app.v176_period_prior_start(p_period_kind, p_period_start);
  v_prior_end date := p_period_start - 1;
  v_current jsonb;
  v_prior jsonb;
  v_opens_current jsonb;
  v_opens_prior jsonb;
  v_gated jsonb;
begin
  select business.id, business.name, business.industry, business.is_demo
  into v_business
  from public.businesses business
  where business.id = p_business;
  if not found then
    raise exception 'business_not_found' using errcode = '22023';
  end if;

  v_current := app.v176_sales_window(p_business, p_period_start, p_period_end);
  v_prior := app.v176_sales_window(p_business, v_prior_start, v_prior_end);
  v_opens_current := app.v176_account_opens_window(
    p_business, p_period_start, p_period_end
  );
  v_opens_prior := app.v176_account_opens_window(
    p_business, v_prior_start, v_prior_end
  );
  v_gated := app.v176_gated_evidence(p_business, p_period_start, p_period_end);

  return pg_catalog.jsonb_build_object(
    'contract_version', 'v176',
    'generated_at', now(),
    'timezone', 'Asia/Singapore',
    'currency', 'SGD',
    'scope', pg_catalog.jsonb_build_object(
      'business_id', v_business.id,
      'business_name', v_business.name,
      'industry', v_business.industry,
      'period_kind', p_period_kind,
      'period_start', p_period_start,
      'period_end', p_period_end,
      'prior_period_start', v_prior_start,
      'prior_period_end', v_prior_end
    ),
    'sales', pg_catalog.jsonb_build_object(
      'current', v_current,
      'prior', v_prior,
      'growth', pg_catalog.jsonb_build_object(
        'net_revenue_cents_delta',
          (v_current->>'net_revenue_cents')::bigint
            - (v_prior->>'net_revenue_cents')::bigint,
        'net_revenue_pct',
          case when (v_prior->>'net_revenue_cents')::bigint > 0
            then round(
              ((v_current->>'net_revenue_cents')::numeric
                - (v_prior->>'net_revenue_cents')::numeric)
              * 100 / (v_prior->>'net_revenue_cents')::numeric, 1)
            else null end,
        'revenue_transactions_delta',
          (v_current->>'revenue_transactions')::bigint
            - (v_prior->>'revenue_transactions')::bigint,
        'customers_served_delta',
          (v_current->>'customers_served')::bigint
            - (v_prior->>'customers_served')::bigint,
        'new_customers_delta',
          (v_current->>'new_customers')::bigint
            - (v_prior->>'new_customers')::bigint
      )
    ),
    'account_opens', pg_catalog.jsonb_build_object(
      'current', v_opens_current,
      'prior', v_opens_prior,
      'report', v_gated->'account_opens_report'
    ),
    'consultant_brief', v_gated->'consultant_brief',
    'catalogue_affinity', v_gated->'catalogue_affinity',
    'recommendations', v_gated->'recommendations',
    'evidence_completeness', pg_catalog.jsonb_build_object(
      'gated_rpcs_available',
        coalesce((v_gated->>'available')::boolean, false),
      'gated_rpcs_reason', v_gated->>'reason',
      'synthetic_customers_excluded', true,
      'reversed_sales_excluded', true,
      'revenue_definition',
        'per-sale v10.1 policy snapshot (counts_as_revenue)'
    )
  );
end
$$;
revoke all privileges on function
  app.v176_evidence_pack(uuid, text, date, date)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Request and list RPCs (console-facing)
-- ---------------------------------------------------------------------------

create or replace function public.platform_request_ai_firm_report_v176(
  p_business uuid,
  p_period_kind text,
  p_period_start date
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_end date;
  v_business record;
  v_row public.ai_firm_reports_v176%rowtype;
begin
  if v_actor is null then
    raise exception 'authenticated platform session is required'
      using errcode = '28000';
  end if;
  if not app.is_super_admin()
     and not app.v176_is_assigned_consultant(p_business) then
    raise exception 'ai_firm_report_request_requires_platform_owner'
      using errcode = '42501';
  end if;

  select business.id, business.name, business.is_demo, business.is_synthetic
  into v_business
  from public.businesses business
  where business.id = p_business
  for share;
  if not found then
    raise exception 'business_not_found' using errcode = '22023';
  end if;
  if v_business.is_demo or v_business.is_synthetic then
    raise exception 'ai_firm_reports_exclude_demo_firms'
      using errcode = '22023';
  end if;

  v_end := app.v176_assert_period(p_period_kind, p_period_start);

  insert into public.ai_firm_reports_v176(
    business_id, period_kind, period_start, period_end,
    status, model, requested_by
  ) values(
    p_business, p_period_kind, p_period_start, v_end,
    'pending', app.v176_model_for_period(p_period_kind), v_actor
  )
  on conflict (business_id, period_kind, period_start) do update
    set status = 'pending',
        model = app.v176_model_for_period(excluded.period_kind),
        evidence = null,
        narrative_md = null,
        error = null,
        claimed_at = null,
        completed_at = null,
        requested_by = v_actor,
        generation = ai_firm_reports_v176.generation + 1
  returning * into v_row;

  insert into public.audit_log(
    business_id, actor, action, entity, entity_id, detail
  ) values(
    p_business, v_actor, 'AI_FIRM_REPORT_REQUESTED_V176',
    'ai_firm_reports_v176', v_row.id,
    pg_catalog.jsonb_build_object(
      'period_kind', v_row.period_kind,
      'period_start', v_row.period_start,
      'period_end', v_row.period_end,
      'generation', v_row.generation,
      'model', v_row.model
    )
  );

  return to_jsonb(v_row) - 'evidence';
end
$$;
revoke all privileges on function public.platform_request_ai_firm_report_v176(
  uuid, text, date
) from public, anon, authenticated, service_role;
grant execute on function public.platform_request_ai_firm_report_v176(
  uuid, text, date
) to authenticated;

create or replace function public.platform_list_ai_firm_reports_v176(
  p_business uuid,
  p_limit integer default 12
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_rows jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated platform session is required'
      using errcode = '28000';
  end if;
  if not app.v176_can_read_firm_report(p_business) then
    raise exception 'ai_firm_report_read_outside_role_scope'
      using errcode = '42501';
  end if;
  if p_limit is null or p_limit not between 1 and 50 then
    raise exception 'limit must be 1..50' using errcode = '22023';
  end if;

  select coalesce(pg_catalog.jsonb_agg(row_json order by ordinality), '[]'::jsonb)
  into v_rows
  from (
    select pg_catalog.jsonb_build_object(
      'id', report.id,
      'business_id', report.business_id,
      'period_kind', report.period_kind,
      'period_start', report.period_start,
      'period_end', report.period_end,
      'status', report.status,
      'model', report.model,
      'narrative_md', report.narrative_md,
      'error', report.error,
      'generation', report.generation,
      'requested_by', report.requested_by,
      'created_at', report.created_at,
      'completed_at', report.completed_at
    ) as row_json,
    row_number() over(
      order by report.period_start desc, report.period_kind, report.id
    ) as ordinality
    from public.ai_firm_reports_v176 report
    where report.business_id = p_business
    order by report.period_start desc, report.period_kind, report.id
    limit p_limit
  ) recent;

  return pg_catalog.jsonb_build_object(
    'business_id', p_business,
    'contract_version', 'v176',
    'reports', v_rows
  );
end
$$;
revoke all privileges on function public.platform_list_ai_firm_reports_v176(
  uuid, integer
) from public, anon, authenticated, service_role;
grant execute on function public.platform_list_ai_firm_reports_v176(
  uuid, integer
) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Worker queue (service role only; called by the ai-firm-reports function)
-- ---------------------------------------------------------------------------

create or replace function public.internal_claim_ai_firm_report_v176()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_id uuid;
  v_row public.ai_firm_reports_v176%rowtype;
  v_evidence jsonb;
begin
  select report.id into v_id
  from public.ai_firm_reports_v176 report
  where report.status = 'pending'
  order by report.created_at, report.id
  for update skip locked
  limit 1;

  if v_id is null then
    return pg_catalog.jsonb_build_object('claimed', false);
  end if;

  select report.* into v_row
  from public.ai_firm_reports_v176 report
  where report.id = v_id;

  v_evidence := app.v176_evidence_pack(
    v_row.business_id, v_row.period_kind, v_row.period_start, v_row.period_end
  );

  update public.ai_firm_reports_v176 report
  set status = 'generating',
      claimed_at = now(),
      evidence = v_evidence,
      error = null,
      model = coalesce(
        report.model, app.v176_model_for_period(report.period_kind)
      )
  where report.id = v_id
  returning * into v_row;

  return pg_catalog.jsonb_build_object(
    'claimed', true,
    'report', to_jsonb(v_row)
  );
end
$$;
revoke all privileges on function public.internal_claim_ai_firm_report_v176()
  from public, anon, authenticated, service_role;
grant execute on function public.internal_claim_ai_firm_report_v176()
  to service_role;

create or replace function public.internal_complete_ai_firm_report_v176(
  p_report uuid,
  p_status text,
  p_narrative_md text default null,
  p_error text default null,
  p_model text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_row public.ai_firm_reports_v176%rowtype;
begin
  if p_status not in ('succeeded','failed') then
    raise exception 'completion status must be succeeded or failed'
      using errcode = '22023';
  end if;
  if p_status = 'succeeded'
     and coalesce(btrim(p_narrative_md), '') = '' then
    raise exception 'a succeeded report requires narrative markdown'
      using errcode = '22023';
  end if;

  select report.* into v_row
  from public.ai_firm_reports_v176 report
  where report.id = p_report
  for update;
  if not found then
    raise exception 'ai_firm_report_not_found' using errcode = '22023';
  end if;
  if v_row.status <> 'generating' then
    raise exception 'only a claimed report can be completed'
      using errcode = '22023';
  end if;

  update public.ai_firm_reports_v176 report
  set status = p_status,
      narrative_md = case when p_status = 'succeeded'
        then p_narrative_md else null end,
      error = case when p_status = 'failed'
        then left(coalesce(nullif(btrim(p_error), ''), 'generation_failed'), 2000)
        else null end,
      model = coalesce(nullif(btrim(p_model), ''), report.model),
      completed_at = now()
  where report.id = p_report
  returning * into v_row;

  return to_jsonb(v_row) - 'evidence';
end
$$;
revoke all privileges on function public.internal_complete_ai_firm_report_v176(
  uuid, text, text, text, text
) from public, anon, authenticated, service_role;
grant execute on function public.internal_complete_ai_firm_report_v176(
  uuid, text, text, text, text
) to service_role;

-- ---------------------------------------------------------------------------
-- 7. Scheduling
-- ---------------------------------------------------------------------------

-- Enqueue-only: generation happens in the edge function. ON CONFLICT DO
-- NOTHING makes a repeated run idempotent, so no run-log is needed and a
-- replay never resets a narrative that already succeeded.
create or replace function app.v176_enqueue_ai_firm_reports(
  p_period_kind text,
  p_period_start date
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_end date := app.v176_period_end(p_period_kind, p_period_start);
  v_queued integer := 0;
begin
  if v_end is null then
    raise exception 'period_kind must be monthly, quarterly or yearly'
      using errcode = '22023';
  end if;

  insert into public.ai_firm_reports_v176(
    business_id, period_kind, period_start, period_end, status, model
  )
  select business.id, p_period_kind, p_period_start, v_end,
    'pending', app.v176_model_for_period(p_period_kind)
  from public.businesses business
  join public.business_workspace_controls_v94 control
    on control.business_id = business.id
  where control.approval_status = 'approved'
    and business.is_demo = false
    and business.is_synthetic = false
  on conflict (business_id, period_kind, period_start) do nothing;

  get diagnostics v_queued = row_count;
  return v_queued;
end
$$;
revoke all privileges on function app.v176_enqueue_ai_firm_reports(text, date)
  from public, anon, authenticated, service_role;

-- One daily job rather than three cron entries.
--
-- pg_cron runs in UTC. 03:00 SGT is 19:00 UTC on the PREVIOUS UTC day, so a
-- monthly cron expression of "1st of the month" in UTC would fire on the 2nd
-- in Singapore. The job therefore runs daily at 19:00 UTC and self-gates on
-- the Singapore calendar date: the 1st of a month enqueues the closed month,
-- the 1st of Jan/Apr/Jul/Oct additionally enqueues the closed quarter, and
-- 1 January additionally enqueues the closed year.
create or replace function app.v176_run_scheduled_ai_firm_reports(
  p_today date default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_today date := coalesce(
    p_today, (clock_timestamp() at time zone 'Asia/Singapore')::date
  );
  v_yesterday date := v_today - 1;
  v_monthly integer := 0;
  v_quarterly integer := 0;
  v_yearly integer := 0;
  v_url text;
  v_secret text;
  v_request bigint;
begin
  if extract(day from v_today) = 1 then
    v_monthly := app.v176_enqueue_ai_firm_reports(
      'monthly', date_trunc('month', v_yesterday)::date
    );
    if extract(month from v_today) in (1, 4, 7, 10) then
      v_quarterly := app.v176_enqueue_ai_firm_reports(
        'quarterly', date_trunc('quarter', v_yesterday)::date
      );
    end if;
    if extract(month from v_today) = 1 then
      v_yearly := app.v176_enqueue_ai_firm_reports(
        'yearly', date_trunc('year', v_yesterday)::date
      );
    end if;
  end if;

  if v_monthly + v_quarterly + v_yearly = 0
     and not exists(
       select 1 from public.ai_firm_reports_v176 where status = 'pending'
     ) then
    return pg_catalog.jsonb_build_object(
      'today', v_today, 'queued', 0, 'dispatch', 'nothing_pending'
    );
  end if;

  -- Dispatch mirrors app.v156_run_subscription_automation: pg_net + Vault.
  if to_regnamespace('vault') is null or to_regnamespace('net') is null then
    return pg_catalog.jsonb_build_object(
      'today', v_today, 'monthly', v_monthly, 'quarterly', v_quarterly,
      'yearly', v_yearly, 'dispatch', 'extensions_unavailable'
    );
  end if;
  begin
    execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
      into v_url using 'v176_supabase_url';
    if coalesce(v_url, '') = '' then
      execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
        into v_url using 'v156_supabase_url';
    end if;
    execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
      into v_secret using 'v176_dispatch_secret';
  exception when others then
    return pg_catalog.jsonb_build_object(
      'today', v_today, 'monthly', v_monthly, 'quarterly', v_quarterly,
      'yearly', v_yearly, 'dispatch', 'vault_unavailable'
    );
  end;
  if coalesce(v_url, '') = '' or coalesce(v_secret, '') = '' then
    return pg_catalog.jsonb_build_object(
      'today', v_today, 'monthly', v_monthly, 'quarterly', v_quarterly,
      'yearly', v_yearly, 'dispatch', 'secret_unconfigured'
    );
  end if;

  execute 'select net.http_post(url := $1, body := ''{}''::jsonb, headers := jsonb_build_object(''content-type'',''application/json'',''x-v176-dispatch-secret'',$2), timeout_milliseconds := 20000)'
    into v_request
    using rtrim(v_url, '/') || '/functions/v1/ai-firm-reports', v_secret;

  return pg_catalog.jsonb_build_object(
    'today', v_today, 'monthly', v_monthly, 'quarterly', v_quarterly,
    'yearly', v_yearly, 'dispatch_request_id', v_request
  );
end
$$;
revoke all privileges on function
  app.v176_run_scheduled_ai_firm_reports(date)
  from public, anon, authenticated, service_role;
grant execute on function app.v176_run_scheduled_ai_firm_reports(date)
  to service_role;

do $cron$
begin
  if to_regnamespace('cron') is not null
     and to_regprocedure('cron.schedule(text,text,text)') is not null then
    if exists(
      select 1 from cron.job
      where jobname = 'nestly-v176-ai-firm-reports-daily'
    ) then
      perform cron.unschedule('nestly-v176-ai-firm-reports-daily');
    end if;
    -- 19:00 UTC == 03:00 SGT on the following Singapore calendar day.
    perform cron.schedule(
      'nestly-v176-ai-firm-reports-daily',
      '0 19 * * *',
      $command$select app.v176_run_scheduled_ai_firm_reports()$command$
    );
  else
    raise notice
      'v176: pg_cron is absent; AI firm reports are not scheduled';
  end if;
end
$cron$;

comment on function public.platform_request_ai_firm_report_v176(uuid, text, date)
  is 'Queues (or re-queues) an AI narrative report for one non-demo firm and one closed calendar period. Super admin or the assigned consultant only.';
comment on function public.platform_list_ai_firm_reports_v176(uuid, integer)
  is 'Recent stored AI narrative reports for one firm. Evidence packs are deliberately not returned to the browser.';
comment on function public.internal_claim_ai_firm_report_v176()
  is 'Service-role queue claim: oldest pending report -> generating, with the evidence pack assembled and stored at claim time. FOR UPDATE SKIP LOCKED.';
comment on function public.internal_complete_ai_firm_report_v176(uuid, text, text, text, text)
  is 'Service-role completion: stores the model narrative or the failure reason for a claimed report.';

commit;
