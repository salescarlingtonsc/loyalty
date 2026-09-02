-- NESTLY v694 — demographic service preference: SHARE and LIFT, never raw counts alone.
--
-- Closes check 33 of the rescoped Customer Intelligence program. A previous cut of this
-- surface would have reported "women aged 25-30 spent $30,000 on Facials" — true, and useless,
-- because it says nothing about whether that is MORE than any other group spends on Facials.
-- The fix is the same discipline the rest of Phase CI-A already applies: every demographic cell
-- (age_band x gender) gets, for every level-2 category node, its OWN revenue share within that
-- node compared against the all-customer baseline share for the same node. A lift > 1 means the
-- cell over-indexes on that category relative to the whole customer base; a lift < 1 means it
-- under-indexes. This is a within-window revenue-share association, never a claim about intent
-- or motive — the payload says so explicitly ('limitation'), and 'CAUSAL' never appears here.
--
-- New RPC: public.get_ci_demographic_preference_v1(p_business, p_from, p_to, p_branch default
-- null, p_as_of default clock_timestamp()). Gated by app.ci_access_gate_v667. Wrapped in the
-- frozen v680 envelope (app.ci_envelope_v680 + app.ci_exclusion_counts_v680), the v672
-- statistical authority (subgroup_evidence_v1 / rate_block_v1), and demographics classified via
-- the gate-free app.customer_demographics_core_v674 (design decision 8 of v674: routing through
-- the public, merchant-only-gated wrapper would double-gate and wrongly refuse an assigned
-- consultant who already cleared THIS reader's own app.ci_access_gate_v667).
--
-- ---------------------------------------------------------------------------------------------
-- DESIGN DECISIONS
-- ---------------------------------------------------------------------------------------------
--
-- 1. POPULATION. "Identified, non-synthetic customers with qualifying category-classified sale
--    lines in the window" = clients with at least one sale_items line, on a REVENUE-qualifying
--    sale (counts_as_revenue), whose category resolves to a level-2 node via
--    app.ci_effective_node_v650 + taxonomy_nodes rollup (the same coalesce(parent_key,node_key)
--    pattern v650's own get_ci_category_mix_v1 already uses). A line that does not classify
--    (no service_canonical_map / product_canonical_map row) is excluded from BOTH a client's
--    node revenue and their total classified revenue — it cannot express a preference for a
--    category it was never mapped into, and letting it inflate the denominator would silently
--    dilute every real share below its true value.
--
-- 2. CELL_SHARE / BASELINE_SHARE. cell_share = rate_block(this cell's revenue in the node, this
--    cell's total classified revenue) — i.e. "of everything this cell spent on classified
--    categories, how much went to this one". baseline_share is the identical ratio computed over
--    ALL resolved customers (age_band and gender both known) regardless of cell, so every cell's
--    lift is judged against the same yardstick. Both are app.rate_block_v1 — numerator and
--    denominator always travel with the pct, and pct is null (never 0.0) when the denominator is
--    zero, per the frozen v672 contract.
--
-- 3. EVIDENCE IS CELL-LEVEL, not per-node. A cell's `evidence` block uses the cell's own
--    customer count (age_band x gender population size) against the shared k=5 floor — the same
--    granularity v674's demographics grid already floors on. When a cell is below the floor,
--    EVERY preference row for that cell gets a nulled cell_share.pct and a nulled lift (the
--    fixture's isolated 2-customer cell proves this), but `buyers` (the raw
--    customers_in_cell_buying_node count) is always kept, because a bare count carries no
--    false-precision risk the way a computed rate does. This deliberately does NOT null
--    baseline_share for an under-floor cell: baseline_share is the SAME global figure emitted to
--    every cell for that node (it is not scoped to any one cell's evidence), and its own
--    rate_block_v1 already nulls its pct independently if the baseline population itself has a
--    zero denominator. Nulling a shared global number because one particular cell lacked
--    evidence would make baseline_share inconsistent across cells for no statistical reason.
--
-- 4. LIFT is numerator (cell_share.pct) over denominator (baseline_share.pct), rounded to 2dp,
--    computed only when: the cell clears its evidence floor, cell_share.pct is not null, AND
--    baseline_share.pct is not null and not zero (division by a zero baseline percentage is
--    exactly the "baseline 0" case the task calls out). All three gates are necessary — clearing
--    the evidence floor does not guarantee a non-null baseline_share.pct if the baseline
--    population for that node happens to be entirely unclassified against it, though in practice
--    every node considered here has at least the cell's own resolved-population revenue behind
--    it.
--
-- 5. NODES CONSIDERED = every level-2 node with at least one classified line ANYWHERE in the
--    scoped window (business/branch), not merely the nodes a given cell happened to buy — so a
--    cell that spent nothing on a node the rest of the business bought heavily still gets an
--    explicit preferences row (buyers=0, cell_share 0%, a real — usually sub-1 — lift), which is
--    itself a meaningful "under-indexes to the point of absence" signal, not an omission.
--
-- 6. COVERAGE mirrors v674's get_ci_demographics_v1 exactly: 'demographics' = resolved customers
--    / all identified customers with qualifying classified revenue; 'revenue' = the same ratio
--    in cents. This is a distinct population from v674's (v674's active population is anyone
--    with a qualifying revenue OR visit sale; this reader's active population is narrower —
--    anyone with a qualifying, CLASSIFIED revenue line) — the two coverage numbers are expected
--    to differ and each describes its own reader's own denominator, not a shared one.
--
-- 7. p_as_of / envelope. Every population query gates on s.created_at <= p_as_of (and the
--    correlated reversal-lookup subquery gates on r.created_at <= p_as_of too), per v680's
--    immutable-snapshot contract; the whole payload is wrapped by app.ci_envelope_v680 exactly
--    the way every v680-re-emitted reader wraps its own (generated_at/as_of/period/exclusions/
--    trace_id merged in, never replacing this reader's own keys).
--
-- Proven by db/tests/executed/v694_corpus_preference.sql — a predetermined truth table, exact
-- assertions, mutation-checked (the fixture's own header states the exact lift arithmetic and a
-- deliberately wrong lift value that must turn the suite red).
begin;

create or replace function public.get_ci_demographic_preference_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  with lines as (
    -- Every classified, revenue-qualifying sale line for an identified, non-synthetic customer
    -- in the scoped window. l2_key rolls a level-3 leaf up to its level-2 parent, or keeps a
    -- level-2 node as-is (coalesce(parent_key, node_key) — the v650 category-mix pattern).
    select si.line_cents, s.client_id,
           coalesce(n.parent_key, n.node_key) as l2_key
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
      join public.clients c on c.id = s.client_id
      cross join lateral app.ci_effective_node_v650(si) en
      left join public.taxonomy_nodes n
        on n.version_no = 1 and n.node_key = en.node_key
     where si.business_id = p_business
       and s.business_id = p_business
       and si.item_type in ('service', 'retail')
       and s.client_id is not null
       and not coalesce(c.is_synthetic, false)
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and s.created_at <= p_as_of
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and coalesce(s.counts_as_revenue, false)
       and si.line_cents > 0
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and coalesce(n.parent_key, n.node_key) is not null
  ),
  client_node as (
    select client_id, l2_key, sum(line_cents)::bigint as revenue_cents
      from lines
     group by client_id, l2_key
  ),
  client_total as (
    select client_id, sum(revenue_cents)::bigint as total_revenue_cents
      from client_node
     group by client_id
  ),
  demog as (
    -- Gate-free core (design decision 8 of v674): app.ci_access_gate_v667, already called
    -- above, is the correct authority for this surface. Routing per-client classification
    -- through the public, merchant-only-gated app.customer_demographics_v1 would double-gate
    -- and wrongly refuse an entitled platform consultant.
    select ct.client_id, ct.total_revenue_cents,
           d.dem->>'age_band' as age_band, d.dem->>'gender' as gender
      from client_total ct
      cross join lateral (
        select app.customer_demographics_core_v674(p_business, ct.client_id) as dem
      ) d
  ),
  nodes as (
    select distinct l2_key from client_node
  ),
  cell_pop as (
    select age_band, gender,
           count(distinct client_id) as customers,
           sum(total_revenue_cents)::bigint as cell_total_revenue_cents
      from demog
     where age_band is not null and gender is not null
     group by age_band, gender
  ),
  cells_built as (
    select cp.age_band, cp.gender, cp.customers, cp.cell_total_revenue_cents,
           app.subgroup_evidence_v1(cp.customers::int) as evidence
      from cell_pop cp
  ),
  cell_node_rev as (
    select d.age_band, d.gender, cn.l2_key,
           sum(cn.revenue_cents)::bigint as node_revenue_cents,
           count(distinct cn.client_id) filter (where cn.revenue_cents > 0) as buyers
      from demog d
      join client_node cn on cn.client_id = d.client_id
     where d.age_band is not null and d.gender is not null
     group by d.age_band, d.gender, cn.l2_key
  ),
  baseline_pop as (
    select sum(total_revenue_cents)::bigint as baseline_total_revenue_cents
      from demog
     where age_band is not null and gender is not null
  ),
  baseline_node_rev as (
    select cn.l2_key, sum(cn.revenue_cents)::bigint as node_revenue_cents
      from client_node cn
      join demog d on d.client_id = cn.client_id
     where d.age_band is not null and d.gender is not null
     group by cn.l2_key
  ),
  baseline_share_by_node as (
    select nd.l2_key,
           app.rate_block_v1(coalesce(bnr.node_revenue_cents, 0), bp.baseline_total_revenue_cents)
             as share
      from nodes nd
      left join baseline_node_rev bnr on bnr.l2_key = nd.l2_key
      cross join baseline_pop bp
  ),
  totals as (
    select count(*) as active_customers,
           coalesce(sum(total_revenue_cents), 0)::bigint as active_revenue_cents,
           count(*) filter (where age_band is not null and gender is not null) as resolved_customers,
           coalesce(sum(total_revenue_cents) filter (where age_band is not null and gender is not null), 0)::bigint
             as resolved_revenue_cents
      from demog
  ),
  pref_calc as (
    select cb.age_band, cb.gender, cb.evidence, cb.cell_total_revenue_cents,
           nd.l2_key, tn.label,
           coalesce(cnr.node_revenue_cents, 0) as node_revenue_cents,
           coalesce(cnr.buyers, 0) as buyers,
           bsn.share as baseline_share
      from cells_built cb
      cross join nodes nd
      left join cell_node_rev cnr
        on cnr.age_band = cb.age_band and cnr.gender = cb.gender and cnr.l2_key = nd.l2_key
      left join public.taxonomy_nodes tn on tn.version_no = 1 and tn.node_key = nd.l2_key
      left join baseline_share_by_node bsn on bsn.l2_key = nd.l2_key
  ),
  pref_share as (
    select pc.*,
           case when pc.evidence->>'status' = 'ok'
                then app.rate_block_v1(pc.node_revenue_cents, pc.cell_total_revenue_cents)
                else jsonb_set(
                       app.rate_block_v1(pc.node_revenue_cents, pc.cell_total_revenue_cents),
                       '{pct}', 'null'::jsonb)
                end as cell_share
      from pref_calc pc
  ),
  pref_final as (
    select ps.*,
           case when (ps.cell_share->>'pct') is not null
                 and (ps.baseline_share->>'pct') is not null
                 and (ps.baseline_share->>'pct')::numeric <> 0
                then round((ps.cell_share->>'pct')::numeric
                           / (ps.baseline_share->>'pct')::numeric, 2)
                else null end as lift
      from pref_share ps
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                 'from', p_from, 'to', p_to),
    'cells', coalesce((
      select jsonb_agg(jsonb_build_object(
               'age_band', cb.age_band,
               'gender', cb.gender,
               'evidence', cb.evidence,
               'preferences', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'node_key', pf.l2_key,
                          'label', pf.label,
                          'cell_share', pf.cell_share,
                          'baseline_share', pf.baseline_share,
                          'lift', pf.lift,
                          'buyers', pf.buyers)
                        order by pf.lift desc nulls last, pf.l2_key)
                   from pref_final pf
                  where pf.age_band = cb.age_band and pf.gender = cb.gender
                 ), '[]'::jsonb))
             order by cb.age_band, cb.gender)
        from cells_built cb), '[]'::jsonb),
    'baseline', coalesce((
      select jsonb_agg(jsonb_build_object(
               'node_key', nd.l2_key, 'label', tn.label, 'share', bsn.share)
             order by nd.l2_key)
        from nodes nd
        left join public.taxonomy_nodes tn on tn.version_no = 1 and tn.node_key = nd.l2_key
        left join baseline_share_by_node bsn on bsn.l2_key = nd.l2_key
      ), '[]'::jsonb),
    'coverage', jsonb_build_object(
      'demographics', app.rate_block_v1(t.resolved_customers, t.active_customers),
      'revenue', app.rate_block_v1(t.resolved_revenue_cents, t.active_revenue_cents)),
    'time_basis', 'sale_occurred_at',
    'limitation', 'preference is a revenue-share association within the window, not a stated intent',
    'observed_since', app.metric_observed_since_v1('ci_demographic_preference', p_business))
    into v_result
    from totals t;

  return app.ci_envelope_v680('ci_demographic_preference_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_demographic_preference_v1(uuid,date,date,uuid,timestamptz)
  from public, anon;
grant execute on function public.get_ci_demographic_preference_v1(uuid,date,date,uuid,timestamptz)
  to authenticated, service_role;

commit;
