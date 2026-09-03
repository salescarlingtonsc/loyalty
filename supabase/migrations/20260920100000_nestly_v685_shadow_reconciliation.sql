-- NESTLY v685 — CI shadow reconciliation (check 99, the MACHINERY half only; the calendar/
-- scheduling half of check 99 is explicitly out of scope for this migration and is not built here).
--
-- Write-only infrastructure that (1) captures the current output of three Customer Intelligence
-- readers for a business+window into an append-only table nothing customer- or business-facing
-- ever reads, and (2) lets a super admin recompute ONE headline number — known revenue —
-- INDEPENDENTLY, straight off `sales`, and diff it against what was captured. Tolerance is 0: any
-- nonzero delta on a reconciled metric is FAIL. This is the same posture as v667's own comment on
-- itself: "the founding defect of this surface was a renderer reading keys a superseded definition
-- emitted" — the oracle here exists so a silent drift between the CI readers and the ledger they
-- describe is caught mechanically, not by a human re-deriving the number by hand.
--
-- app.ci_shadow_capture_v685(p_business, p_from, p_to)
--   SECURITY DEFINER, service_role-only (no grant to anon or authenticated at all — this is
--   scheduled/operational infrastructure, not something a signed-in user, super admin included,
--   calls directly). Calls get_ci_opportunities_v1, get_revenue_truth_v106 and
--   get_ci_funnel_conversion_v1 for the given scope and writes ONE row to
--   app.ci_shadow_runs_v685 holding all three payloads plus a window-definition object
--   (see below). Returns the new run's id.
--
-- public.get_ci_shadow_reconciliation_v685(p_business, p_run_id)
--   Gated exactly like every other super-admin-only RPC in this codebase (grep
--   "not app.is_super_admin() then raise exception ... using errcode='42501'" — v66/v79/v86/v147
--   all use this identical refusal): only a super admin may call it, everyone else gets 42501.
--   Loads the named run, recomputes known revenue and completed-transaction count INDEPENDENTLY
--   by aggregating `public.sales` directly (NOT by calling get_revenue_truth_v106 — that would
--   make the "oracle" just call the thing it is meant to check), and reports PASS/FAIL per metric
--   against the captured payload with zero tolerance.
--
-- INDEPENDENT-RECOMPUTE SCOPE (documented, not silently narrowed): the real
-- get_revenue_truth_v106 (v573's definition, the last committed one at the time this was written)
-- nets each sale against BOTH a native reversal (`sales.reversal_of`) and external
-- commerce-event refund allocations (`commerce_refund_allocations_v106` /
-- `commerce_event_reconciliations_v106`) via app.v106_sale_residual_minor. This oracle restates
-- only the ledger-native half of that rule — a sale counts when it is not itself a reversal, is
-- not later reversed by another sale, counts_as_revenue, was created at-or-before the capture's
-- as-of time, and occurred inside [p_from, p_to) in the sale's own reporting timezone — and does
-- NOT replicate the external-reconciliation refund-allocation netting. A business with active
-- external refund allocations in the reconciled window will show a real, expected, nonzero delta
-- here; that is a known limitation of this phase's oracle, not a bug in it, and is why this
-- migration is scoped to the mechanism (capture -> independent recompute -> PASS/FAIL -> stop
-- conditions), not to reproducing every edge case of v106 on day one.
--
-- Proven by db/tests/executed/v685_corpus_shadow.sql: seeds a business with no external
-- reconciliation rows in scope (so the two rules agree exactly), captures a run, reconciles it
-- (all PASS), mutates a captured number directly on the stored row and reconciles again (the
-- mutated metric is named FAIL, others stay PASS), and calls the reconciliation RPC as a
-- non-super-admin (refused, 42501).
begin;

create table app.ci_shadow_runs_v685 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  window_from date not null,
  window_to date not null,
  captured_at timestamptz not null default clock_timestamp(),
  payload jsonb not null,
  trace_id uuid not null default gen_random_uuid()
);
create index ci_shadow_runs_v685_business_idx on app.ci_shadow_runs_v685(business_id, captured_at desc);
-- Write-only infrastructure: no RLS policy is defined at all, and nothing is granted to any
-- role except what the two functions below need. A table with RLS enabled and zero policies
-- still denies every row to anon/authenticated, which is the point — this is not a defense in
-- depth measure, it is the ONLY access rule for this table.
alter table app.ci_shadow_runs_v685 enable row level security;
revoke all on app.ci_shadow_runs_v685 from public, anon, authenticated;
grant select, insert, update on app.ci_shadow_runs_v685 to service_role;

create or replace function app.ci_shadow_capture_v685(p_business uuid, p_from date, p_to date)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_run_id uuid;
  v_opportunities jsonb;
  v_revenue_truth jsonb;
  v_funnel_conversion jsonb;
  v_as_of timestamptz := clock_timestamp();
  -- The window-definition object (check 99's "machinery" half): what was captured, how the
  -- independent recompute works, and the two conditions that stop this from ever silently
  -- passing a partial or runaway reconciliation. The calendar/scheduling half (WHEN this runs)
  -- is deliberately not represented here — nothing in this migration schedules a capture.
  v_window jsonb := jsonb_build_object(
    'start', p_from, 'duration_days', greatest(0, p_to - p_from),
    'method', 'independent_recompute',
    'stop_conditions', jsonb_build_array('any delta > 0', 'runtime > 60s'));
begin
  if p_business is null or p_from is null or p_to is null or p_to <= p_from then
    raise exception 'p_business, p_from and p_to are required and p_to must be after p_from'
      using errcode = '22023';
  end if;
  if not exists (select 1 from public.businesses b where b.id = p_business) then
    raise exception 'unknown business' using errcode = '22023';
  end if;

  select public.get_ci_opportunities_v1(p_business, p_from, p_to, null) into v_opportunities;
  select public.get_revenue_truth_v106(p_business, p_from, p_to, null, v_as_of) into v_revenue_truth;
  select public.get_ci_funnel_conversion_v1(p_business, p_from, p_to, 60, null) into v_funnel_conversion;

  insert into app.ci_shadow_runs_v685 (business_id, window_from, window_to, captured_at, payload)
  values (p_business, p_from, p_to, v_as_of, jsonb_build_object(
    'as_of', v_as_of,
    'window', v_window,
    'get_ci_opportunities_v1', v_opportunities,
    'get_revenue_truth_v106', v_revenue_truth,
    'get_ci_funnel_conversion_v1', v_funnel_conversion))
  returning id into v_run_id;

  return v_run_id;
end;
$$;
revoke all on function app.ci_shadow_capture_v685(uuid,date,date) from public, anon, authenticated;
grant execute on function app.ci_shadow_capture_v685(uuid,date,date) to service_role;

create or replace function public.get_ci_shadow_reconciliation_v685(p_business uuid, p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_run app.ci_shadow_runs_v685%rowtype;
  v_captured_revenue_truth jsonb;
  v_captured_known_revenue bigint;
  v_captured_completed_txns bigint;
  v_independent_known_revenue bigint;
  v_independent_completed_txns bigint;
  v_delta_revenue bigint;
  v_delta_txns bigint;
  v_metrics jsonb;
  v_started_at timestamptz := clock_timestamp();
begin
  -- Same refusal convention as every other super-admin-only RPC in this codebase (v66/v79/v86/
  -- v147): anyone who is not a super admin gets 42501, no partial data, no different message.
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode = '42501';
  end if;
  if p_business is null or p_run_id is null then
    raise exception 'p_business and p_run_id are required' using errcode = '22023';
  end if;

  select * into v_run
    from app.ci_shadow_runs_v685
   where id = p_run_id and business_id = p_business;
  if not found then
    raise exception 'unknown shadow run for this business' using errcode = '22023';
  end if;

  v_captured_revenue_truth := v_run.payload->'get_revenue_truth_v106';
  v_captured_known_revenue := (v_captured_revenue_truth->'totals'->>'known_revenue_minor')::bigint;
  v_captured_completed_txns := (v_captured_revenue_truth->'totals'->>'completed_transactions')::bigint;

  -- THE INDEPENDENT ORACLE. Deliberately NOT a call to get_revenue_truth_v106 — restates the
  -- ledger-native half of its rule directly against `sales` (see the migration header for the
  -- documented, non-silent scope limit: no external commerce-event refund-allocation netting).
  -- A sale counts when: it is not itself a reversal, nothing reverses it, it is flagged
  -- counts_as_revenue by the v10 sale-policy trigger, it was recorded at-or-before this run's
  -- as-of time, and it occurred inside [window_from, window_to) in Asia/Singapore — the same
  -- timezone convention app.js's own truthRequest/customerIntelligencePage use for this business.
  select
    coalesce(sum(s.amount_cents), 0)::bigint,
    coalesce(count(*) filter (where s.amount_cents > 0), 0)::bigint
    into v_independent_known_revenue, v_independent_completed_txns
    from public.sales s
   where s.business_id = p_business
     and s.reversal_of is null
     and coalesce(s.counts_as_revenue, false)
     and s.created_at <= (v_run.payload->>'as_of')::timestamptz
     and not exists (select 1 from public.sales r where r.reversal_of = s.id)
     and (s.occurred_at at time zone 'Asia/Singapore')::date >= v_run.window_from
     and (s.occurred_at at time zone 'Asia/Singapore')::date < v_run.window_to;

  v_delta_revenue := coalesce(v_independent_known_revenue, 0) - coalesce(v_captured_known_revenue, 0);
  v_delta_txns := coalesce(v_independent_completed_txns, 0) - coalesce(v_captured_completed_txns, 0);

  v_metrics := jsonb_build_array(
    jsonb_build_object(
      'metric', 'known_revenue_minor',
      'captured', v_captured_known_revenue,
      'independent', v_independent_known_revenue,
      'delta', v_delta_revenue,
      'status', case when v_delta_revenue = 0 then 'PASS' else 'FAIL' end),
    jsonb_build_object(
      'metric', 'completed_transactions',
      'captured', v_captured_completed_txns,
      'independent', v_independent_completed_txns,
      'delta', v_delta_txns,
      'status', case when v_delta_txns = 0 then 'PASS' else 'FAIL' end));

  return jsonb_build_object(
    'run_id', v_run.id,
    'business_id', v_run.business_id,
    'window', v_run.payload->'window',
    'metrics', v_metrics,
    'overall_status', case when v_delta_revenue = 0 and v_delta_txns = 0 then 'PASS' else 'FAIL' end,
    'runtime_ms', extract(epoch from (clock_timestamp() - v_started_at)) * 1000);
end;
$$;
revoke all on function public.get_ci_shadow_reconciliation_v685(uuid,uuid) from public, anon;
grant execute on function public.get_ci_shadow_reconciliation_v685(uuid,uuid) to authenticated, service_role;

commit;
