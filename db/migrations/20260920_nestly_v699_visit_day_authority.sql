-- NESTLY v699 — one visit-day authority (check 4 refutation), and the envelope gap it exposed
-- (check 16).
--
-- Contract: docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md (v672, frozen). Fixture guide:
-- docs/qa/CI-CORPUS-FIXTURE-GUIDE.md. Proven by db/tests/executed/v699_corpus_visit_days.sql.
--
-- ============================================================================================
-- WHAT WAS WRONG. nestly_v673's funnel/retention readers and nestly_v692's fix to
-- get_customer_lifecycle_v107 both settled that a "visit" is a distinct Asia/Singapore calendar
-- day with a qualifying sale — a split bill (several tickets, same customer, same afternoon) is
-- ONE visit, not several. That standard was never generalised into a single authority, so it was
-- applied in exactly one reader (v692's fix to get_customer_lifecycle_v107) while four other
-- "visits" figures kept counting raw sale/line rows:
--   1. public.get_ci_category_customers_v1 (db/migrations/20260920_nestly_v680_ci_envelope.sql:
--      1379) — 'visits', count(distinct s.id): a raw sale count per client, not per visit-day.
--   2. public.get_ci_staff_performance_v1 (db/migrations/20260902_nestly_v683_staff_rebooking_
--      loyalty_discount.sql:310,342) — 'visits', count(*) over sale_items LINES: three items on
--      one ticket already triple-counts before a second sale even enters the picture.
--   3. public.get_ci_discount_dependency_v1 (same file, :993-995) — full_price_visits /
--      discounted_visits / all_visits count SALE ROWS; the `all_visits < 3` evidence gate and the
--      discounted-share classification both flip on a customer who simply paid twice in one visit.
--   4. app.v179_business_insights (live body = nestly_v695's re-emit) — lifetime_visits and
--      window_clients.visits are both `count(*) filter (where counts_as_visit)`; the "regulars"
--      gate (`lifetime_visits >= 2`) that drives at_risk recovery value is keyed on that same raw
--      count.
--
-- WHAT THIS DOES. One frozen authority, app.ci_visit_day_v699(timestamptz) returns date — the
-- Asia/Singapore calendar day of a sale's occurred_at, nothing else. (v698 is introducing a
-- separate per-branch-timezone helper for the daypart reader only; this authority stays fixed to
-- SG on purpose, matching every other CI reader's `time_basis`/`period.timezone` convention and
-- the v673/v692 precedent it generalises.) All four readers above are re-emitted to count
-- distinct (client, visit-day) instead of raw rows:
--   1. category_customers: 'visits' becomes count(distinct app.ci_visit_day_v699(s.occurred_at))
--      per client (the query is already grouped by client_id).
--   2. staff_performance: 'visits' becomes count(distinct (client_id, visit_day)) per staff+
--      service — the finest per-service breakdown this reader already reports at. A customer
--      visiting for two DIFFERENT services on the same day still counts once per service (each
--      service is its own dimension of the mix-adjustment); a customer buying the SAME service
--      three times in one sitting now counts once. Revenue sums (actual and, downstream, the
--      firm-wide average-ticket figures they feed) are unchanged — only the visits denominator
--      moves, which is exactly why 'adjusted.expected_revenue_cents' and 'adjusted.index' shift
--      for any staff member who had multi-line-same-day tickets; that is the bug being fixed, not
--      a side effect to work around.
--   3. discount_dependency: a customer-day is 'day_discounted' when ANY qualifying sale that day
--      carried a discount (bool_or over the day's sales) — a customer who pays full price at 10am
--      and redeems a discount at 3pm the same day is one discounted visit, not one full-price visit
--      plus one discounted visit. full_price_visits / discounted_visits / all_visits, and therefore
--      the `all_visits < 3` evidence floor and the organic/dependent/mixed classification, all move
--      to this per-day accounting.
--   4. v179_business_insights: lifetime_visits and window_clients.visits both move to
--      count(distinct <day>) filter (where counts_as_visit) via a targeted, position()-verified
--      splice against the LIVE pg_get_functiondef body (v548/v551/v690/v695 all touched this
--      function since v179 first shipped; this migration diffs the body AS IT STANDS, not the
--      original file, so it is agnostic to exactly what those migrations changed elsewhere). The
--      "regulars" gate (`lifetime_visits >= 2`) needs no separate edit — it reads lifetime_visits,
--      so redefining that column at its source cascades automatically. avg_ticket_cents (lifetime
--      revenue / lifetime visits) legitimately reprices per visit-DAY rather than per sale, which
--      is the more correct "one more visit" recovery-value estimate the at_risk block already
--      claims to compute.
--
-- Every "visits"-shaped payload from a re-emitted reader carries a top-level
-- `visit_definition: 'one per customer per calendar day (Asia/Singapore); split bills count
-- once'` note, and app.ci_visit_registry_v699() names every visit-counting CI reader this build
-- wave shipped and whether it defers to this authority — proven, not merely documented, by the
-- fixture calling every named reader.
--
-- ============================================================================================
-- CHECK 16 (coordinator-flagged during this build): get_ci_staff_performance_v1 and
-- get_ci_discount_dependency_v1 never called app.ci_envelope_v680 — verified by grep: v680's
-- envelope wrapper appears nowhere in nestly_v683's file. Both readers therefore shipped without
-- the shared exclusions block (reversed_sales/synthetic_clients/anonymous_sales), the scope/
-- period/trace_id keys every other CI-A/B/C reader carries, and no p_as_of parameter to pin an
-- immutable snapshot. Both gain a trailing `p_as_of timestamptz default clock_timestamp()`
-- parameter (old 4-arg signature dropped first, so exactly one overload of each survives; every
-- existing 4-arg caller — nestly_v688's consultant spine calls both positionally with 4 args —
-- keeps working unchanged against the new default) and are wrapped in app.ci_envelope_v680 the
-- way get_ci_daypart_v1 already does (nestly_v693/v698). Because app.ci_envelope_v680 MERGES its
-- envelope keys into the caller's payload with `||` rather than replacing it, every key nestly_
-- v683's fixture (db/tests/executed/v683_corpus_behavioural_authorities.sql) already reads —
-- 'staff', 'time_basis', 'scope', 'classes', 'full_price_repeat_customers',
-- 'reminder_only_candidates' — survives untouched; the envelope only ADDS 'generated_at', 'as_of',
-- 'period', 'exclusions', 'trace_id'. Confirmed by inspection before writing this migration, and
-- asserted directly in this migration's own fixture (v699_corpus_visit_days.sql calls the v683
-- fixture's own truth-table shapes are not re-asserted here — only that exclusions.reversed_sales
-- etc. now exist on both payloads).
--
-- ============================================================================================
begin;

-- ---------------------------------------------------------------------------------------------
-- 0 · app.ci_visit_day_v699 — the one authority.
-- ---------------------------------------------------------------------------------------------
create or replace function app.ci_visit_day_v699(p_occurred_at timestamptz)
returns date
language sql
immutable
as $$
  select (p_occurred_at at time zone 'Asia/Singapore')::date;
$$;
revoke all on function app.ci_visit_day_v699(timestamptz) from public, anon;
grant execute on function app.ci_visit_day_v699(timestamptz) to service_role;

comment on function app.ci_visit_day_v699(timestamptz) is
  'The one visit-day authority (nestly_v699): a visit is one distinct Asia/Singapore calendar '
  'day with a qualifying sale for a given customer; a split bill (several sales, one afternoon) '
  'counts once. Generalises the rule nestly_v673''s funnel/retention readers and nestly_v692''s '
  'get_customer_lifecycle_v107 fix already applied. See app.ci_visit_registry_v699() for which '
  'CI readers defer to it.';

-- ---------------------------------------------------------------------------------------------
-- 1 · public.get_ci_category_customers_v1 — extract-and-diff (two anchors: the visits expression,
--     and a visit_definition key spliced into both return branches — suppressed and normal).
-- ---------------------------------------------------------------------------------------------
do $cc$
declare
  v_def text;
  v_after text;
  v_expected text;
  v_anchor_visits constant text := '        ''visits'', count(distinct s.id),';
  v_repl_visits constant text :=
    '        ''visits'', count(distinct app.ci_visit_day_v699(s.occurred_at)),';
  v_anchor_branch1 constant text :=
E'      ''node_key'', p_node_key,
      ''scope'', jsonb_build_object(''business_id'', p_business, ''branch_id'', p_branch,
                                  ''from'', p_from, ''to'', p_to),
      ''customers'', ''[]''::jsonb,';
  v_repl_branch1 constant text :=
E'      ''node_key'', p_node_key,
      ''visit_definition'',
        ''one per customer per calendar day (Asia/Singapore); split bills count once'',
      ''scope'', jsonb_build_object(''business_id'', p_business, ''branch_id'', p_branch,
                                  ''from'', p_from, ''to'', p_to),
      ''customers'', ''[]''::jsonb,';
  v_anchor_branch2 constant text :=
E'    ''node_key'', p_node_key,
    ''scope'', jsonb_build_object(''business_id'', p_business, ''branch_id'', p_branch,
                                ''from'', p_from, ''to'', p_to),
    ''customers'', v_rows,';
  v_repl_branch2 constant text :=
E'    ''node_key'', p_node_key,
    ''visit_definition'',
      ''one per customer per calendar day (Asia/Singapore); split bills count once'',
    ''scope'', jsonb_build_object(''business_id'', p_business, ''branch_id'', p_branch,
                                ''from'', p_from, ''to'', p_to),
    ''customers'', v_rows,';
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v699: public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz) not found';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_visits, ''))) / length(v_anchor_visits);
  if v_count <> 1 then
    raise exception 'v699: category_customers visits anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_branch1, ''))) / length(v_anchor_branch1);
  if v_count <> 1 then
    raise exception 'v699: category_customers suppressed-branch anchor occurs % times (expected 1)', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_branch2, ''))) / length(v_anchor_branch2);
  if v_count <> 1 then
    raise exception 'v699: category_customers normal-branch anchor occurs % times (expected 1)', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_visits, v_repl_visits);
  v_expected := replace(v_expected, v_anchor_branch1, v_repl_branch1);
  v_expected := replace(v_expected, v_anchor_branch2, v_repl_branch2);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz)')) into v_after;

  if replace(replace(replace(v_after, v_repl_visits, v_anchor_visits),
             v_repl_branch1, v_anchor_branch1), v_repl_branch2, v_anchor_branch2) <> v_def then
    raise exception
      'v699: get_ci_category_customers_v1 changed by more than the three intended substitutions.';
  end if;
  if position('count(distinct app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v699: category_customers visit-day authority did not land';
  end if;
end
$cc$;
-- ACL restated verbatim from the live proacl (unchanged by this migration — same argument list).
revoke all on function public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz)
  from public, anon;
grant execute on function public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 2 · public.get_ci_staff_performance_v1 — full re-emit: visit-day counting, a trailing p_as_of,
--     and the app.ci_envelope_v680 wrap this reader never had (check 16). Confirmed unchanged
--     since nestly_v683 shipped it (grep across every later migration file finds no other
--     redefinition), so the body below is transcribed verbatim from that migration with exactly
--     the changes this header describes.
-- ---------------------------------------------------------------------------------------------
drop function if exists public.get_ci_staff_performance_v1(uuid,date,date,uuid);
create or replace function public.get_ci_staff_performance_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_staff jsonb;
  v_examined integer;
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);

  with lines as (
    select si.staff_id, si.ref_id as service_id, si.line_cents,
           s.client_id, app.ci_visit_day_v699(s.occurred_at) as visit_day
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
      join public.clients c on c.id = s.client_id
     where si.business_id = p_business
       and si.item_type = 'service'
       and si.ref_id is not null
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and coalesce(s.counts_as_revenue, false)
       and not coalesce(c.is_synthetic, false)
       and s.created_at <= p_as_of
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  firm_service_avg as (
    select service_id, avg(line_cents) as avg_ticket
      from lines
     group by service_id
  ),
  staff_service as (
    select l.staff_id, l.service_id,
           count(distinct (l.client_id, l.visit_day)) as visits,
           sum(l.line_cents) as revenue
      from lines l
     where l.staff_id is not null
     group by l.staff_id, l.service_id
  ),
  staff_totals as (
    select staff_id,
           sum(visits) as total_visits,
           sum(revenue) as actual_revenue_cents,
           sum(visits * fsa.avg_ticket) as expected_revenue_cents
      from staff_service ss
      join firm_service_avg fsa on fsa.service_id = ss.service_id
     group by staff_id
  )
  select count(*) into v_examined from staff_totals;

  with lines as (
    select si.staff_id, si.ref_id as service_id, si.line_cents,
           s.client_id, app.ci_visit_day_v699(s.occurred_at) as visit_day
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
      join public.clients c on c.id = s.client_id
     where si.business_id = p_business
       and si.item_type = 'service'
       and si.ref_id is not null
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and coalesce(s.counts_as_revenue, false)
       and not coalesce(c.is_synthetic, false)
       and s.created_at <= p_as_of
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  staff_service as (
    select l.staff_id, l.service_id,
           count(distinct (l.client_id, l.visit_day)) as visits,
           sum(l.line_cents) as revenue
      from lines l
     where l.staff_id is not null
     group by l.staff_id, l.service_id
  ),
  firm_service_avg as (
    select service_id, avg(line_cents) as avg_ticket
      from lines
     group by service_id
  ),
  staff_totals as (
    select ss.staff_id,
           sum(ss.visits)::integer as total_visits,
           sum(ss.revenue)::bigint as actual_revenue_cents,
           round(sum(ss.visits * fsa.avg_ticket))::bigint as expected_revenue_cents
      from staff_service ss
      join firm_service_avg fsa on fsa.service_id = ss.service_id
     group by ss.staff_id
  ),
  scored as (
    select t.*, app.subgroup_evidence_v1(t.total_visits) as evidence
      from staff_totals t
  )
  -- CI-STAT-AUTHORITY-CONTRACT: raw COUNTS may display at any n, but a rate-like VERDICT
  -- (revenue_per_visit_cents, the adjusted index, and the expected-revenue figure it is derived
  -- from) is null the moment evidence is below the floor.
  select coalesce(jsonb_agg(jsonb_build_object(
           'staff_id', t.staff_id,
           'full_name', st.full_name,
           'unadjusted', jsonb_build_object(
             'revenue_cents', t.actual_revenue_cents,
             'visits', t.total_visits,
             'revenue_per_visit_cents',
               case when (t.evidence->>'status') = 'ok' and t.total_visits > 0
                 then round(t.actual_revenue_cents::numeric / t.total_visits, 2)
                 else null end),
           'adjusted', jsonb_build_object(
             'expected_revenue_cents',
               case when (t.evidence->>'status') = 'ok'
                 then t.expected_revenue_cents else null end,
             'index',
               case when (t.evidence->>'status') = 'ok' and t.expected_revenue_cents > 0
                 then round(t.actual_revenue_cents::numeric / t.expected_revenue_cents, 2)
                 else null end),
           'evidence', t.evidence)
         order by t.actual_revenue_cents desc), '[]'::jsonb)
    into v_staff
    from scored t
    left join public.staff st on st.id = t.staff_id and st.business_id = p_business;

  v_result := jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'visit_definition', 'one per customer per calendar day (Asia/Singapore); split bills count once',
    'staff', v_staff,
    'comparisons', app.comparisons_note_v1(v_examined, v_examined),
    'note', 'adjusted.index = actual revenue / expected revenue, where expected revenue is this '
            'staff member''s own visit counts per service priced at the firm-wide average ticket '
            'for that service. 1.00 means the staff member performs exactly at the firm average '
            'given their own service mix; it does not mean they earn the same raw revenue as '
            'anyone else. ''visits'' counts distinct (client, calendar day) pairs per staff and '
            'service, not raw sale-item lines — three same-day lines for one customer count once.');

  return app.ci_envelope_v680('ci_staff_performance_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_staff_performance_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_staff_performance_v1(uuid,date,date,uuid,timestamptz)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 3 · public.get_ci_discount_dependency_v1 — full re-emit: per-visit-day discount classing, a
--     trailing p_as_of, and the app.ci_envelope_v680 wrap (check 16). Confirmed unchanged since
--     nestly_v683 shipped it.
-- ---------------------------------------------------------------------------------------------
drop function if exists public.get_ci_discount_dependency_v1(uuid,date,date,uuid);
create or replace function public.get_ci_discount_dependency_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_classes jsonb;
  v_full_price_repeat integer;
  v_reminder jsonb;
  v_reminder_count integer;
  v_candidates jsonb;
  v_floor constant integer := 5;
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);

  -- One WITH chain, not several: a CTE only lives for the single SQL statement that declares it.
  with pop as (
    select s.id as sale_id, s.client_id, s.occurred_at,
           exists (select 1 from public.sale_items d
                     where d.sale_id = s.id and d.item_type = 'studio_discount' and d.line_cents < 0
                  ) as is_discounted
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and s.client_id is not null
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and coalesce(s.counts_as_visit, false)
       and not coalesce(c.is_synthetic, false)
       and s.created_at <= p_as_of
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  -- v699: a visit is a (client, calendar day), and a day is discounted if ANY sale that day
  -- carried one — a customer paying full price at 10am and redeeming a discount at 3pm the same
  -- day is one discounted visit, not one full-price visit plus one discounted visit.
  visit_days as (
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day,
           bool_or(is_discounted) as day_discounted
      from pop
     group by client_id, app.ci_visit_day_v699(occurred_at)
  ),
  per_client as (
    select client_id,
           count(*) filter (where not day_discounted) as full_price_visits,
           count(*) filter (where day_discounted) as discounted_visits,
           count(*) as all_visits
      from visit_days
     group by client_id
  ),
  classified as (
    select *,
           case
             when all_visits < 3 then 'insufficient'
             when (100.0 * discounted_visits / all_visits) < 20 then 'organic'
             when (100.0 * discounted_visits / all_visits) >= 60 then 'discount_dependent'
             else 'mixed'
           end as class
      from per_client
  ),
  organic_scored as (
    select oc.client_id, c.full_name,
           (app.customer_cadence_v1(p_business, oc.client_id, now())->>'deviation_state') as state
      from (select client_id from classified where class = 'organic') oc
      join public.clients c on c.id = oc.client_id
  ),
  reminder_agg as (
    select
      count(*) filter (where state = 'overdue') as n_overdue,
      coalesce(jsonb_agg(jsonb_build_object(
          'client_id', client_id, 'full_name', full_name,
          'action', jsonb_build_object('who', 'front desk', 'what', 'send a reminder, no incentive',
                                        'why', 'organic returner; discount unnecessary'))
               ) filter (where state = 'overdue'), '[]'::jsonb) as candidates
      from organic_scored
  )
  select
      count(*) filter (where full_price_visits >= 2),
      jsonb_build_object(
        'organic', jsonb_build_object(
          'n', count(*) filter (where class = 'organic'),
          'evidence', app.subgroup_evidence_v1((count(*) filter (where class = 'organic'))::integer),
          'share', app.rate_block_floor_gated_v683(count(*) filter (where class = 'organic'), count(*),
                     app.subgroup_evidence_v1((count(*) filter (where class = 'organic'))::integer))),
        'discount_dependent', jsonb_build_object(
          'n', count(*) filter (where class = 'discount_dependent'),
          'evidence', app.subgroup_evidence_v1((count(*) filter (where class = 'discount_dependent'))::integer),
          'share', app.rate_block_floor_gated_v683(count(*) filter (where class = 'discount_dependent'), count(*),
                     app.subgroup_evidence_v1((count(*) filter (where class = 'discount_dependent'))::integer))),
        'mixed', jsonb_build_object(
          'n', count(*) filter (where class = 'mixed'),
          'evidence', app.subgroup_evidence_v1((count(*) filter (where class = 'mixed'))::integer),
          'share', app.rate_block_floor_gated_v683(count(*) filter (where class = 'mixed'), count(*),
                     app.subgroup_evidence_v1((count(*) filter (where class = 'mixed'))::integer))),
        'insufficient', jsonb_build_object(
          'n', count(*) filter (where class = 'insufficient'),
          'evidence', app.subgroup_evidence_v1((count(*) filter (where class = 'insufficient'))::integer),
          'share', app.rate_block_floor_gated_v683(count(*) filter (where class = 'insufficient'), count(*),
                     app.subgroup_evidence_v1((count(*) filter (where class = 'insufficient'))::integer)))),
      (select n_overdue from reminder_agg),
      (select candidates from reminder_agg)
    into v_full_price_repeat, v_classes, v_reminder_count, v_candidates
    from classified;

  -- reminder_only_candidates: organic returners who are overdue right now per their own cadence.
  -- Small-cell floor applies (identity-bearing list), same k=5 convention as v667.
  if v_reminder_count > 0 and v_reminder_count < v_floor then
    v_reminder := jsonb_build_object(
      'candidates', '[]'::jsonb,
      'suppressed', jsonb_build_object('reason', 'below_small_cell_floor', 'floor', v_floor,
                                        'cohort_size', v_reminder_count));
  else
    v_reminder := jsonb_build_object('candidates', v_candidates, 'suppressed', null);
  end if;

  v_result := jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'visit_definition', 'one per customer per calendar day (Asia/Singapore); split bills count '
                        'once; a day is discounted if any qualifying sale that day carried a '
                        'discount',
    'classes', v_classes,
    'full_price_repeat_customers', v_full_price_repeat,
    'reminder_only_candidates', v_reminder);

  return app.ci_envelope_v680('ci_discount_dependency_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_discount_dependency_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_discount_dependency_v1(uuid,date,date,uuid,timestamptz)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 4 · app.v179_business_insights — extract-and-diff against the LIVE body (three anchors,
--     confirmed present exactly once each against the post-v548/v551/v556/v690/v695 body before
--     touching it): lifetime_visits, window_clients.visits, and a visit_definition splice next to
--     contract_version. The at_risk "regulars" gate (`lifetime_visits >= 2`) needs no separate
--     edit — it reads the lifetime_visits column this migration redefines at its source.
-- ---------------------------------------------------------------------------------------------
do $v179$
declare
  v_def text;
  v_after text;
  v_expected text;
  v_anchor_lifetime constant text :=
    'count(*) filter (where counts_as_visit) as lifetime_visits,';
  v_repl_lifetime constant text :=
    'count(distinct app.ci_visit_day_v699(occurred_at)) filter (where counts_as_visit) '
    'as lifetime_visits,';
  v_anchor_window constant text :=
    'count(*) filter (where ws.counts_as_visit) as visits,';
  v_repl_window constant text :=
    'count(distinct app.ci_visit_day_v699(ws.occurred_at)) filter (where ws.counts_as_visit) '
    'as visits,';
  v_anchor_contract constant text := '''contract_version'', ''v179'',';
  v_repl_contract constant text :=
E'''contract_version'', ''v179'',
    ''visit_definition'',
      ''one per customer per calendar day (Asia/Singapore); split bills count once; lifetime_visits and top_customers.visits count distinct visit-days, not raw sales'',';
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure(
    'app.v179_business_insights(uuid,date,date,date,date)')) into v_def;
  if v_def is null then raise exception 'v699: app.v179_business_insights not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_lifetime, ''))) / length(v_anchor_lifetime);
  if v_count <> 1 then
    raise exception 'v699: lifetime_visits anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_window, ''))) / length(v_anchor_window);
  if v_count <> 1 then
    raise exception 'v699: window_clients visits anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_contract, ''))) / length(v_anchor_contract);
  if v_count <> 1 then
    raise exception 'v699: contract_version anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_lifetime, v_repl_lifetime);
  v_expected := replace(v_expected, v_anchor_window, v_repl_window);
  v_expected := replace(v_expected, v_anchor_contract, v_repl_contract);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'app.v179_business_insights(uuid,date,date,date,date)')) into v_after;

  if replace(replace(replace(v_after, v_repl_lifetime, v_anchor_lifetime),
             v_repl_window, v_anchor_window), v_repl_contract, v_anchor_contract) <> v_def then
    raise exception
      'v699: v179_business_insights changed by more than the three intended substitutions.';
  end if;
  if position('ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v699: v179 visit-day authority did not land';
  end if;
end
$v179$;
-- ACL restated verbatim from the live proacl (unchanged by this migration).
revoke all privileges on function
  app.v179_business_insights(uuid, date, date, date, date)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 5 · app.ci_visit_registry_v699 — names every visit-counting CI reader this build wave shipped
--     and whether it defers to the authority. Proven against reality (not merely documented) by
--     the fixture: each 'true' entry's reader is called and asserted to dedupe by day; each
--     'false' entry's reader body is checked, via pg_get_functiondef, to NOT reference
--     app.ci_visit_day_v699 — i.e. the registry does not claim an authority a body doesn't use.
-- ---------------------------------------------------------------------------------------------
create or replace function app.ci_visit_registry_v699()
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'authority', 'app.ci_visit_day_v699(timestamptz) returns date',
    'visit_definition',
      'one per customer per calendar day (Asia/Singapore); split bills count once',
    'readers', jsonb_build_object(
      'get_ci_category_customers_v1', jsonb_build_object(
        'uses_authority', true,
        'note', 'visits = distinct visit-day per client (nestly_v699)'),
      'get_ci_staff_performance_v1', jsonb_build_object(
        'uses_authority', true,
        'note', 'visits = distinct (client, visit-day) pairs per staff and service (nestly_v699)'),
      'get_ci_discount_dependency_v1', jsonb_build_object(
        'uses_authority', true,
        'note', 'visits = distinct visit-day per client; a day is discounted iff any sale that '
                'day carried a discount (nestly_v699)'),
      'app.v179_business_insights', jsonb_build_object(
        'uses_authority', true,
        'note', 'lifetime_visits / window_clients.visits = distinct visit-day; the regulars gate '
                '(lifetime_visits >= 2) inherits this at its source (nestly_v699)'),
      'get_customer_lifecycle_v107', jsonb_build_object(
        'uses_authority', true,
        'note', 'repeat_purchasers_in_period counts distinct visit-days, inline '
                '(nestly_v692, predates this authority function but applies the same rule)'),
      'get_ci_daypart_v1', jsonb_build_object(
        'uses_authority', false,
        'note', 'bucketed sales, see nestly_v698 (per-branch-timezone daypart buckets, a '
                'different dimension from customer visit-day dedupe)'),
      'get_ci_funnel_conversion_v1', jsonb_build_object(
        'uses_authority', false,
        'note', 'min(visit_date) per stage, inherently deduped (nestly_v673)'),
      'get_ci_retention_windows_v1', jsonb_build_object(
        'uses_authority', false,
        'note', 'min(visit_date) per stage, inherently deduped (nestly_v673)')
    )
  );
$$;
revoke all on function app.ci_visit_registry_v699() from public, anon;
grant execute on function app.ci_visit_registry_v699() to service_role;

commit;
