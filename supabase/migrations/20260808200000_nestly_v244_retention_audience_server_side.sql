-- ============================================================================
-- v244 — retention bring-back audience is computed server-side.
--
-- WHY. The browser built the lapsed-regulars audience by downloading EVERY
-- client row and EVERY visit-marked sales row for the business (fetchAllRows
-- paged, sequential, unbounded — app/app.js pbLoadAudience) and then reducing
-- them in JS. That is a cliff, not a slope: a single business with a large
-- customer history pulls its entire visit history into a phone browser to
-- answer "who has 3+ visits and none in 45 days" — a question that is one
-- aggregate over two indexed columns. The 2026-08-08 capacity audit rated this
-- the only launch-gating finding (breaks for ONE large tenant at ANY fleet
-- size). This migration moves the reduction into the database; the browser now
-- receives only the matching candidates.
--
-- SEMANTIC CONTRACT — reproduces app/app.js exactly:
--   * candidate universe: sales rows with counts_as_visit = true;
--   * a reversal row (reversal_of is not null) is never itself a visit, and an
--     original is discounted when a reversal REFERENCING IT exists WITHIN that
--     counts_as_visit = true set (validVisitSales builds its reversal id set
--     from the already-filtered rows — mirrored deliberately, including the
--     implication that a reversal row stored with counts_as_visit = false
--     would NOT discount its original; changing that is a product decision,
--     not a porting decision);
--   * per client: net = count of valid visits, last = max(occurred_at);
--   * last_visit_days = greatest(0, SG calendar date of now() minus SG
--     calendar date of last visit) — completeSgCalendarDaysSince: whole
--     Asia/Singapore calendar days, never negative;
--   * candidate iff net >= p_min_visits and last_visit_days >= p_lapsed_days
--     (a client with zero valid visits has no last visit and never matches);
--   * ordered most-overdue first (client JS sorted by lastVisitDays desc; the
--     id tiebreaker here only makes ties deterministic).
--
-- AUTHORIZATION — parity, not invention: the browser called
-- require_module_scope_v145(business, null, 'retention') and then read the
-- clients/sales tables under RLS. This function performs the identical scope
-- check server-side and raises its 42501/22023 unchanged. No new grant shape:
-- EXECUTE to authenticated only, like the sibling retention RPCs.
--
-- BOUND — the one deliberate behaviour change: the response is capped at
-- 20000 candidates, with `total` and `truncated` reported honestly. The old
-- client code had no bound because it already had every row locally. A
-- truncated audience must NOT be silently frozen into a campaign (the split
-- would not be the audience the owner configured), so the UI refuses to
-- proceed when truncated = true and asks the owner to narrow the filter.
--
-- IDEMPOTENT: create or replace + idempotent grants; safe to re-run.
--
-- TWO FINDINGS from the v244 differential verification, recorded so they are
-- decisions rather than surprises:
--   * Clamp vs || idiom. This function clamps (0 -> 1, >365 -> 365); the JS
--     callers apply `crit.lapsed_days||45` before calling, and the wizard
--     pre-clamps to [1,365]/[1,99]. A stored audience_criteria of 0 or >365
--     written by some future path would resolve differently (JS 0 -> 45,
--     SQL 0 -> 1). Unreachable today; bound audience_criteria if a second
--     writer ever appears.
--   * SECURITY DEFINER reads bypass RLS, where the old browser code read
--     clients/sales under RLS. Equivalent for every production role today
--     (verified: all gate-passing users are owners with full-table RLS reads),
--     and require_module_scope_v145 remains the authorization boundary. A
--     future role granted view_sales + retention scope but NOT the clients
--     module would see the audience here where the old code showed it empty —
--     if such a role is ever created, revisit whether retention scope should
--     imply clients read.
-- ============================================================================

begin;

create or replace function public.retention_lapsed_candidates_v244(
  p_business uuid,
  p_lapsed_days integer,
  p_min_visits integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_cap constant integer := 20000;
  v_lapsed integer := greatest(1, least(365, coalesce(p_lapsed_days, 45)));
  v_min integer := greatest(1, least(99, coalesce(p_min_visits, 3)));
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_total bigint;
  v_rows jsonb;
begin
  -- Same gate the browser applied before its raw table reads (raises 42501).
  perform public.require_module_scope_v145(p_business, null, 'retention');

  with visit_rows as (
    select s.id, s.client_id, s.occurred_at, s.reversal_of
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_visit = true
  ),
  valid_visits as (
    -- validVisitSales: reversals are never visits; a reversed original is out.
    select v.client_id, v.occurred_at
    from visit_rows v
    where v.reversal_of is null
      and not exists (
        select 1 from visit_rows r where r.reversal_of = v.id
      )
  ),
  per_client as (
    select vv.client_id,
           count(*)::integer as net_visits,
           max(vv.occurred_at) as last_visit_at
    from valid_visits vv
    group by vv.client_id
  ),
  candidates as (
    select c.id, c.full_name, c.phone,
           pc.net_visits,
           greatest(0, v_today - (pc.last_visit_at at time zone 'Asia/Singapore')::date)::integer
             as last_visit_days
    from per_client pc
    join public.clients c
      on c.id = pc.client_id and c.business_id = p_business
    where pc.net_visits >= v_min
      and greatest(0, v_today - (pc.last_visit_at at time zone 'Asia/Singapore')::date) >= v_lapsed
  )
  select count(*),
         coalesce(jsonb_agg(x.row order by x.last_visit_days desc, x.id)
                    filter (where x.rank <= v_cap), '[]'::jsonb)
    into v_total, v_rows
    from (
      select cand.id, cand.last_visit_days,
             row_number() over (order by cand.last_visit_days desc, cand.id) as rank,
             jsonb_build_object(
               'id', cand.id,
               'full_name', cand.full_name,
               'phone', cand.phone,
               'net_visits', cand.net_visits,
               'last_visit_days', cand.last_visit_days
             ) as row
      from candidates cand
    ) x;

  return jsonb_build_object(
    'candidates', v_rows,
    'total', coalesce(v_total, 0),
    'truncated', coalesce(v_total, 0) > v_cap
  );
end;
$$;

comment on function public.retention_lapsed_candidates_v244(uuid,integer,integer) is
  'v244: server-side bring-back audience. Replaces the browser downloading every '
  'client and every visit-marked sale (fetchAllRows) to compute lapsed regulars. '
  'Visit validity, SG calendar-day lapse and the >=min-visits filter reproduce '
  'app/app.js validVisitSales + pbComputeCandidates exactly; authorization is the '
  'same require_module_scope_v145(business, null, retention) the client called. '
  'Capped at 20000 candidates with an honest truncated flag — the UI must refuse '
  'to freeze a truncated audience.';

revoke all on function public.retention_lapsed_candidates_v244(uuid,integer,integer) from public, anon;
grant execute on function public.retention_lapsed_candidates_v244(uuid,integer,integer) to authenticated;
grant execute on function public.retention_lapsed_candidates_v244(uuid,integer,integer) to service_role;

commit;

-- ============================================================================
-- VERIFICATION (performed rolled-back against production before apply):
--   1. Differential: the exact JS reference (validVisitSales +
--      pbComputeCandidates, executed in Node on rows fetched the way the old
--      client fetched them) compared to this function's output for every
--      production business and several (lapsed, min) pairs — byte-equal ids,
--      counts and day numbers required.
--   2. Synthetic branch coverage inside BEGIN/ROLLBACK: reversal rows,
--      reversed originals, reversal rows with counts_as_visit=false (must NOT
--      discount — documented quirk parity), zero-visit clients, SG-midnight
--      boundary (an occurred_at late UTC evening = next SG day), min/lapsed
--      clamping, cap/truncated flag, anon and non-staff callers (42501).
-- ============================================================================
