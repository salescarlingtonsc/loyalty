-- ============================================================================
-- nestly_v548 — the attention list: who should this business bring back today?
--
-- WHY. The dashboard opens on member counts and points issued — the same vanity
-- numbers every competitor shows. The numbers only Peekaa can show (because only
-- Peekaa holds the sales ledger, the visit policy and the customer book in one
-- record) are: which customers are overdue against THEIR OWN visit rhythm, and
-- how much monthly revenue is fading with them. v108 already computes per-client
-- cadence (median inter-visit gap) inside the flag-gated growth pipeline, but
-- nothing surfaces it to the owner. This RPC is the surfacing layer: a read-only
-- projection the dashboard renders as "Customers to bring back".
--
-- SEMANTIC CONTRACT — visit validity reproduces v108/v244 exactly:
--   * candidate sales: counts_as_visit = true, reversal_of is null, client set,
--     no reversal referencing the row, positive v106 residual, occurred within
--     the 365-day observation window;
--   * cadence_days = median (percentile_cont 0.5) of the client's inter-visit
--     intervals, clamped to >= 1 day (same-day pairs must not divide by ~zero);
--   * lapse_days = whole days since the last valid visit;
--   * a client needs >= 3 valid visits (>= 2 intervals) for a personal rhythm;
--     fewer visits = insufficient history, never guessed at;
--   * status buckets, each with a 7-day floor so daily-cadence businesses are
--     not nagged about a regular who skipped one morning:
--       due       lapse >= max(7, ceil(cadence))          — their rhythm arrived
--       overdue   lapse >= max(7, ceil(cadence * 1.5))    — v108's multiplier
--       slipping  lapse >= max(7, ceil(cadence * 2.5))    — fading toward lost
--   * monthly_value_cents = avg residual transaction * (30 / cadence) — the
--     client's historical monthly worth, the honest "at risk" unit;
--   * monthly_at_risk_cents sums monthly_value over overdue + slipping only
--     ("due" is expected, not yet at risk);
--   * one_time_count = clients whose ONLY valid visit in the window is >= 30
--     days old — the "came once and never returned" sales-demo number;
--   * synthetic clients (clients.is_synthetic) never appear: they are demo
--     fixtures, not customers to chase.
--
-- AUTHORIZATION. Rows carry client names and phone numbers, so the gate is the
-- same one the customer book itself sits behind: require_module_scope_v145
-- (business, branch, 'clients') — raises 42501/22023 unchanged. An employee who
-- cannot open Customers cannot read this either. EXECUTE: authenticated only
-- (plus service_role), like the sibling read projections (v244).
--
-- BOUND. Rows are capped (default 8, clamp 1..50); the summary always reports
-- the full counts, so truncation is visible, never silent.
--
-- IDEMPOTENT: create or replace + idempotent grants; safe to re-run.
-- ============================================================================

begin;

create or replace function public.get_attention_list_v548(
  p_business uuid,
  p_branch uuid default null,
  p_limit integer default 8
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_now timestamptz := now();
  v_window constant integer := 365;
  v_limit integer := greatest(1, least(50, coalesce(p_limit, 8)));
  v_result jsonb;
begin
  -- Same gate the customer book applies (raises 42501 for outsiders).
  perform public.require_module_scope_v145(p_business, p_branch, 'clients');

  with visits as (
    select s.client_id, s.occurred_at,
      app.v106_sale_residual_minor(s.id, v_now) as amount_cents,
      extract(epoch from (
        s.occurred_at - lag(s.occurred_at) over (
          partition by s.client_id order by s.occurred_at, s.id
        )
      )) / 86400.0 as interval_days
    from public.sales s
    where s.business_id = p_business
      and (p_branch is null or s.branch_id = p_branch)
      and s.client_id is not null
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at >= v_now - make_interval(days => v_window)
      and s.occurred_at < v_now
      and app.v106_sale_residual_minor(s.id, v_now) > 0
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id and r.reversal_of = s.id
      )
  ),
  metrics as (
    select v.client_id,
      count(*)::integer as prior_visits,
      max(v.occurred_at) as last_visit_at,
      percentile_cont(0.5) within group (order by v.interval_days)
        filter (where v.interval_days is not null) as cadence_days_raw,
      floor(extract(epoch from (v_now - max(v.occurred_at))) / 86400)::integer as lapse_days,
      round(avg(v.amount_cents))::bigint as average_transaction_cents
    from visits v
    group by v.client_id
  ),
  judged as (
    -- The clients join sits HERE, not only on the flagged rows, so that the
    -- synthetic exclusion also governs the 'considered' count: a demo fixture
    -- must not inflate any number this function reports.
    select m.client_id, m.prior_visits, m.last_visit_at, m.lapse_days,
      m.average_transaction_cents,
      c.full_name, c.phone,
      greatest(m.cadence_days_raw, 1.0) as cadence_days,
      round(m.average_transaction_cents * 30.0
        / greatest(m.cadence_days_raw, 1.0))::bigint as monthly_value_cents,
      case
        when m.lapse_days >= greatest(7, ceil(greatest(m.cadence_days_raw, 1.0) * 2.5)) then 'slipping'
        when m.lapse_days >= greatest(7, ceil(greatest(m.cadence_days_raw, 1.0) * 1.5)) then 'overdue'
        when m.lapse_days >= greatest(7, ceil(greatest(m.cadence_days_raw, 1.0)))       then 'due'
        else null
      end as status
    from metrics m
    join public.clients c on c.id = m.client_id and c.business_id = p_business
    where m.prior_visits >= 3 and m.cadence_days_raw is not null
      and coalesce(c.is_synthetic, false) = false
  ),
  flagged as (
    select j.* from judged j where j.status is not null
  )
  select jsonb_build_object(
    'summary', jsonb_build_object(
      'considered', (select count(*) from judged),
      'due',      (select count(*) from flagged where status = 'due'),
      'overdue',  (select count(*) from flagged where status = 'overdue'),
      'slipping', (select count(*) from flagged where status = 'slipping'),
      'monthly_at_risk_cents', (
        select coalesce(sum(monthly_value_cents), 0)
        from flagged where status in ('overdue', 'slipping')
      ),
      'one_time_count', (
        select count(*)
        from metrics m
        join public.clients c on c.id = m.client_id and c.business_id = p_business
        where m.prior_visits = 1 and m.lapse_days >= 30
          and coalesce(c.is_synthetic, false) = false
      )
    ),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'client_id', t.client_id,
        'full_name', t.full_name,
        'phone', t.phone,
        'last_visit_at', t.last_visit_at,
        'last_visit_days', t.lapse_days,
        'cadence_days', round(t.cadence_days::numeric, 1),
        'status', t.status,
        'average_transaction_cents', t.average_transaction_cents,
        'monthly_value_cents', t.monthly_value_cents
      ) order by t.ord), '[]'::jsonb)
      from (
        select f.*, row_number() over (
          order by (f.status = 'due')::int asc,
                   f.monthly_value_cents desc,
                   f.lapse_days desc,
                   f.client_id
        ) as ord
        from flagged f
        order by (f.status = 'due')::int asc,
                 f.monthly_value_cents desc,
                 f.lapse_days desc,
                 f.client_id
        limit v_limit
      ) t
    )
  )
  into v_result;

  return v_result;
end;
$$;

comment on function public.get_attention_list_v548(uuid, uuid, integer) is
  'Read-only attention projection for the business dashboard: per-client visit '
  'rhythm (median inter-visit gap over counts_as_visit sales, v108 reversal and '
  'residual semantics), due/overdue/slipping status against that rhythm with a '
  '7-day floor, historical monthly value, and the one-time-visitor count. Gated '
  'by require_module_scope_v145(business, branch, clients) because rows carry '
  'client names and phones. Rows capped (1..50, default 8); summary counts are '
  'always complete so the cap is never silent.';

revoke all on function public.get_attention_list_v548(uuid, uuid, integer) from public, anon;
grant execute on function public.get_attention_list_v548(uuid, uuid, integer) to authenticated;
grant execute on function public.get_attention_list_v548(uuid, uuid, integer) to service_role;

commit;

-- ============================================================================
-- VERIFICATION (performed rolled-back against production before apply):
--   db/tests/v548_attention_list.sql — synthetic clients with crafted visit
--   histories inserted into a QA tenant inside BEGIN/ROLLBACK: due / overdue /
--   slipping bucketing against personal cadence, the 7-day floor, monthly
--   value arithmetic, reversal discounting, synthetic-client exclusion, the
--   one-time count, branch scoping, row cap with honest summary, and the
--   42501 outsider / anon EXECUTE checks.
-- ============================================================================
