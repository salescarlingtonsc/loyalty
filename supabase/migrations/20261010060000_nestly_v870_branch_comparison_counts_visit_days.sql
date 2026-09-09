-- nestly_v870 — "Your branches side by side" counts visit-days, the same grain as Home.
--
-- WHAT WAS LIVE, AND WHY IT IS WRONG. public.get_ci_branch_comparison_v1 (Insights → "Your
-- branches side by side", and the owner brief's outlets card) counted every qualifying sale
-- ROW as a visit — its own visit_definition said so: "one qualifying sale row". The Home
-- Visits tile, the tile's drill-down (v719), v179's weekday pattern and the v865 busiest-days
-- chart all count one visit per customer per Singapore day (app.ci_visit_day_v699). Measured on
-- prod 2026-09-09, the same 30-day window: Cubbly SPA 23 on Home against 50 here; ÉLAN 17
-- against 29; Hougang ABC 4 against 7; QA Kaya Toast 7 against 23; QA Kopi Lab 4 against 20.
-- One customer's 16 same-day bills on Mon 2026-08-24 were 16 "visits" on this page and one on
-- Home. The two surfaces printed the same words, "Valid visits", 92% apart.
--
-- THE FIX. One visit definition. A qualifying sale with a customer counts once per customer per
-- SGT day; a walk-in (no client_id) cannot be deduplicated by identity and still counts per
-- sale, exactly as get_dashboard_summary_v155 does. Business-wide the day is per customer;
-- per branch it is per (branch, customer) — the page's existing limitation ("a customer who
-- visits two branches is counted at each") is unchanged and still stated. Revenue, customers,
-- new_customers, demographics and top items are untouched. visit_definition now says what the
-- number is.

begin;

create or replace function public.get_ci_branch_comparison_v1(p_business uuid, p_from date, p_to date, p_as_of timestamp with time zone default clock_timestamp())
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_id      uuid;
  v_visible uuid[] := array[]::uuid[];
  v_hidden  bigint;
  v_result  jsonb;
begin
  perform app.ci_access_gate_v667(p_business, null);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  for v_id in
    select br.id from public.branches br where br.business_id = p_business order by br.id
  loop
    begin
      perform app.ci_access_gate_v667(p_business, v_id);
      v_visible := v_visible || v_id;
    exception when insufficient_privilege then
      null;
    end;
  end loop;

  select count(*) into v_hidden
    from public.branches br
   where br.business_id = p_business and br.active and not (br.id = any(v_visible));

  with br as (
    -- ACTIVE branches the caller may see. A retired branch keeps its history and its directory
    -- row; it is not a thing to compare this window's trading on.
    select b.id, b.code, b.name, b.is_default
      from public.branches b
     where b.business_id = p_business and b.active and b.id = any(v_visible)
  ),
  scoped as (
    -- Decision 7: v772's qualifying-sale predicate, business-wide, once.
    -- nestly_v870: the two row_numbers pick ONE sale row per customer visit-day — business-wide
    -- and per branch — so a visit is counted once however many bills it produced. Visit rows
    -- sort first inside each partition, so a revenue-only row can never mask the visit.
    select s.id, s.client_id, s.branch_id, s.amount_cents,
           app.ci_visit_day_v699(s.occurred_at)   as visit_day,
           coalesce(s.counts_as_visit, false)     as is_visit,
           coalesce(s.counts_as_revenue, false)   as is_revenue,
           row_number() over (
             partition by s.client_id, app.ci_visit_day_v699(s.occurred_at)
             order by (case when coalesce(s.counts_as_visit, false) then 0 else 1 end), s.occurred_at, s.id
           ) as rn_biz,
           row_number() over (
             partition by s.branch_id, s.client_id, app.ci_visit_day_v699(s.occurred_at)
             order by (case when coalesce(s.counts_as_visit, false) then 0 else 1 end), s.occurred_at, s.id
           ) as rn_branch
      from public.sales s
      left join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and s.created_at <= p_as_of
       and s.reversal_of is null
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and not coalesce(c.is_synthetic, false)
       and (coalesce(s.counts_as_visit, false) or coalesce(s.counts_as_revenue, false))
       and app.ci_visit_day_v699(s.occurred_at) between p_from and p_to
  ),
  biz_tot as (
    select count(*) filter (where sc.is_visit and (sc.client_id is null or sc.rn_biz = 1))::bigint as visits,
           coalesce(sum(sc.amount_cents) filter (where sc.is_revenue), 0)::bigint                     as revenue_cents,
           count(distinct sc.client_id) filter (where sc.is_visit
                                                  and sc.client_id is not null)::bigint
                                                                                     as customers,
           count(*) filter (where sc.is_visit and sc.branch_id is null
                              and (sc.client_id is null or sc.rn_biz = 1))::bigint    as unattributed_visits
      from scoped sc
  ),
  cur as (
    select sc.* from scoped sc join br on br.id = sc.branch_id
  ),
  first_visit as (
    -- Decision 9: the customer's first-ever qualifying VISIT at this business, any branch.
    select distinct on (s.client_id)
           s.client_id, s.branch_id,
           app.ci_visit_day_v699(s.occurred_at) as visit_day
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and s.client_id is not null
       and s.created_at <= p_as_of
       and s.reversal_of is null
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and not coalesce(c.is_synthetic, false)
       and coalesce(s.counts_as_visit, false)
     order by s.client_id, app.ci_visit_day_v699(s.occurred_at), s.occurred_at, s.id
  ),
  new_cust as (
    select fv.branch_id, count(*)::bigint as new_customers
      from first_visit fv
     where fv.visit_day between p_from and p_to
       and fv.branch_id is not null
     group by fv.branch_id
  ),
  branch_agg as (
    select br.id as branch_id,
           count(c.id) filter (where c.is_visit and (c.client_id is null or c.rn_branch = 1))::bigint as visits,
           coalesce(sum(c.amount_cents) filter (where c.is_revenue), 0)::bigint                        as revenue_cents,
           count(distinct c.client_id) filter (where c.is_visit
                                                 and c.client_id is not null)::bigint
                                                                                     as customers
      from br left join cur c on c.branch_id = br.id
     group by br.id
  ),
  branch_clients as (
    select distinct c.branch_id, c.client_id
      from cur c
     where c.is_visit and c.client_id is not null
  ),
  classified as (
    -- Decision 11: the gate-free v674 core, one call per (branch, customer).
    select bc.branch_id, bc.client_id,
           d.dem->>'gender'   as gender,
           d.dem->>'age_band' as age_band
      from branch_clients bc
      cross join lateral (
        select app.customer_demographics_core_v674(p_business, bc.client_id) as dem
      ) d
  ),
  dem_tot as (
    select cl.branch_id,
           count(*)::bigint                                       as customers,
           count(*) filter (where cl.gender is not null)::bigint   as gender_known,
           count(*) filter (where cl.age_band is not null)::bigint as age_known
      from classified cl group by cl.branch_id
  ),
  gender_rows as (
    select cl.branch_id, cl.gender, count(*)::bigint as customers
      from classified cl where cl.gender is not null group by cl.branch_id, cl.gender
  ),
  age_rows as (
    select cl.branch_id, cl.age_band, count(*)::bigint as customers
      from classified cl where cl.age_band is not null group by cl.branch_id, cl.age_band
  ),
  top_band as (
    select distinct on (ar.branch_id) ar.branch_id, ar.age_band, ar.customers
      from age_rows ar
     where app.subgroup_evidence_v1(ar.customers::int)->>'status' = 'ok'
     order by ar.branch_id, ar.customers desc,
              case ar.age_band
                when 'under_20' then 1 when '20_24' then 2 when '25_30' then 3
                when '31_40'    then 4 when '41_50' then 5 else 6 end,
              ar.age_band
  ),
  cal as (
    select d::date as the_day, extract(isodow from d)::int as dow
      from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
  ),
  weekday_occ as (
    select cal.dow, count(*)::bigint as occurrences from cal group by cal.dow
  ),
  branch_weekday as (
    select br.id as branch_id, g.dow,
           case g.dow when 1 then 'Monday' when 2 then 'Tuesday' when 3 then 'Wednesday'
                      when 4 then 'Thursday' when 5 then 'Friday' when 6 then 'Saturday'
                      else 'Sunday' end                                as label,
           count(c.id) filter (where c.is_visit and (c.client_id is null or c.rn_branch = 1))::bigint as visits
      from br
      cross join generate_series(1, 7) as g(dow)
      left join cur c
        on c.branch_id = br.id
       and extract(isodow from c.visit_day)::int = g.dow
     group by br.id, g.dow
  ),
  branch_weekday_rows as (
    -- Decision 13: k=4 OCCURRENCES, and per_occurrence is a count per day, not a percentage.
    select bw.branch_id, bw.dow, bw.label, bw.visits, wo.occurrences,
           case when wo.occurrences > 0
                then round(bw.visits::numeric / wo.occurrences, 1) else null end as per_occurrence,
           app.subgroup_evidence_v1(wo.occurrences::int, 4) as evidence
      from branch_weekday bw
      join weekday_occ wo on wo.dow = bw.dow
  ),
  weekday_ranked as (
    select wr.* from branch_weekday_rows wr
     where wr.evidence->>'status' = 'ok' and wr.per_occurrence is not null
  ),
  -- v779: a branch that saw no visits at all in the window has seven weekdays tied at zero, so
  -- it has no busiest and no slowest one. The plain `distinct on` named Monday for BOTH -- dow
  -- being the tie-break at either end of an all-zero ordering -- which reports a pattern the
  -- data does not contain, and reports it identically for every empty branch. A branch is
  -- ranked only once at least one of its weekdays has a visit; the join drops the rest and the
  -- existing `case when ... is null then null` emits null for them. A branch that DID trade
  -- keeps every previous answer, zero-visit weekdays included: Saturday at 0.0 is still the
  -- honest slowest day of a week that had customers on other days.
  weekday_has_visits as (
    select wr.branch_id from weekday_ranked wr
     group by wr.branch_id having max(wr.visits) > 0
  ),
  busiest_wd as (
    select distinct on (q.branch_id) q.branch_id, q.label, q.per_occurrence
      from weekday_ranked q
      join weekday_has_visits h on h.branch_id = q.branch_id
     order by q.branch_id, q.per_occurrence desc, q.dow
  ),
  slowest_wd as (
    select distinct on (q.branch_id) q.branch_id, q.label, q.per_occurrence
      from weekday_ranked q
      join weekday_has_visits h on h.branch_id = q.branch_id
     order by q.branch_id, q.per_occurrence asc, q.dow
  ),
  lines as (
    -- Decision 14: get_ci_demographic_totals_v1.by_item's grouping and its identified-only base.
    select c.branch_id, si.item_type,
           coalesce(si.ref_id, si.product_id) as item_id,
           si.description, si.line_cents, c.client_id
      from public.sale_items si
      join cur c on c.id = si.sale_id
     where si.business_id = p_business
       and c.is_revenue
       and c.client_id is not null
  ),
  item_tot as (
    select l.branch_id, l.item_id, l.description, l.item_type,
           coalesce(sum(l.line_cents), 0)::bigint as revenue_cents,
           count(distinct l.client_id)::bigint    as buyers
      from lines l
     group by l.branch_id, l.item_id, l.description, l.item_type
  ),
  top_item as (
    select distinct on (it.branch_id)
           it.branch_id, it.item_id, it.description, it.item_type, it.revenue_cents, it.buyers
      from item_tot it
     order by it.branch_id, it.revenue_cents desc, it.description, it.item_id
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', null,
                                'from', p_from, 'to', p_to),
    'visit_definition',
      'one customer visit-day (app.ci_visit_day_v699: one visit per customer per Singapore day, '
      'however many bills), walk-ins counted per qualifying sale; attributed to the branch the '
      'sale was recorded at. Same grain as the Home Visits tile and its drill-down (nestly_v870).',
    'business', jsonb_build_object(
      'visits', bt.visits, 'revenue_cents', bt.revenue_cents, 'customers', bt.customers),
    'branches_compared', (select count(*) from br),
    'branches_hidden', v_hidden,
    'unattributed_visits', bt.unattributed_visits,
    'unattributed_note',
      'A qualifying sale that carries no branch id belongs to the business and to no outlet; it '
      'is counted in business.visits and in no branch row, so the branch shares need not sum to '
      '100.',
    'branches', coalesce((
      select jsonb_agg(jsonb_build_object(
               'branch', jsonb_build_object(
                 'id', br.id, 'code', br.code, 'name', br.name, 'is_default', br.is_default),
               'visits', ba.visits,
               'revenue_cents', ba.revenue_cents,
               'customers', ba.customers,
               'new_customers', coalesce(nc.new_customers, 0),
               'share_of_visits', app.rate_block_v1(ba.visits, bt.visits),
               'share_of_revenue', app.rate_block_v1(ba.revenue_cents, bt.revenue_cents),
               'gender', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'gender', gr.gender,
                          'customers', gr.customers,
                          'share',
                            case when app.subgroup_evidence_v1(dt.gender_known::int)->>'status' = 'ok'
                                 then app.rate_block_v1(gr.customers, dt.gender_known)
                                 else jsonb_set(app.rate_block_v1(gr.customers, dt.gender_known),
                                                '{pct}', 'null'::jsonb) end)
                        order by gr.customers desc, gr.gender)
                   from gender_rows gr where gr.branch_id = br.id), '[]'::jsonb),
               'unknown_gender', coalesce(dt.customers, 0) - coalesce(dt.gender_known, 0),
               'age_bands', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'age_band', ar.age_band,
                          'customers', ar.customers,
                          'share',
                            case when app.subgroup_evidence_v1(dt.age_known::int)->>'status' = 'ok'
                                 then app.rate_block_v1(ar.customers, dt.age_known)
                                 else jsonb_set(app.rate_block_v1(ar.customers, dt.age_known),
                                                '{pct}', 'null'::jsonb) end)
                        order by case ar.age_band
                                   when 'under_20' then 1 when '20_24' then 2 when '25_30' then 3
                                   when '31_40'    then 4 when '41_50' then 5 else 6 end,
                                 ar.age_band)
                   from age_rows ar where ar.branch_id = br.id), '[]'::jsonb),
               'unknown_age', coalesce(dt.customers, 0) - coalesce(dt.age_known, 0),
               'coverage', jsonb_build_object(
                 'gender_known', app.rate_block_v1(coalesce(dt.gender_known, 0),
                                                   coalesce(dt.customers, 0)),
                 'age_known',    app.rate_block_v1(coalesce(dt.age_known, 0),
                                                   coalesce(dt.customers, 0))),
               'evidence', jsonb_build_object(
                 'gender',    app.subgroup_evidence_v1(coalesce(dt.gender_known, 0)::int),
                 'age_band',  app.subgroup_evidence_v1(coalesce(dt.age_known, 0)::int)),
               'top_age_band',
                 case when tb.age_band is null then null
                      else jsonb_build_object('age_band', tb.age_band, 'customers', tb.customers)
                 end,
               'busiest_weekday',
                 case when bwd.label is null then null
                      else jsonb_build_object('label', bwd.label,
                                              'per_occurrence', bwd.per_occurrence) end,
               'slowest_weekday',
                 case when swd.label is null then null
                      else jsonb_build_object('label', swd.label,
                                              'per_occurrence', swd.per_occurrence) end,
               'top_item',
                 case when ti.branch_id is null then null
                      else jsonb_build_object('item_name', ti.description,
                                              'item_type', ti.item_type,
                                              'revenue_cents', ti.revenue_cents,
                                              'buyers', ti.buyers) end)
             order by br.code, br.id)
        from br
        join branch_agg ba on ba.branch_id = br.id
        left join new_cust  nc  on nc.branch_id  = br.id
        left join dem_tot   dt  on dt.branch_id  = br.id
        left join top_band  tb  on tb.branch_id  = br.id
        left join busiest_wd bwd on bwd.branch_id = br.id
        left join slowest_wd swd on swd.branch_id = br.id
        left join top_item  ti  on ti.branch_id  = br.id), '[]'::jsonb),
    'weekday_floor',
      'A weekday is ranked only once it occurs at least 4 times inside the window; '
      'per_occurrence is visits per occurrence of that weekday, to 1 decimal place.',
    'time_basis', 'sale_occurred_at',
    'evidence_class', 'DIRECT_FACT',
    'limitation',
      'Branches are compared on where the sale was recorded. A customer who visits two branches '
      'is counted at each.',
    'observed_since', app.metric_observed_since_v1('ci_branch_comparison', p_business))
    into v_result
    from biz_tot bt;

  return app.ci_envelope_v680('ci_branch_comparison_v1', p_business, null, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, null, p_from, p_to, p_as_of), v_result);
end;
$function$;

-- ACL restated verbatim from prod (nestly_v870).
revoke all on function public.get_ci_branch_comparison_v1(uuid,date,date,timestamptz) from public, anon;
grant execute on function public.get_ci_branch_comparison_v1(uuid,date,date,timestamptz) to authenticated, service_role;

do $verify$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.get_ci_branch_comparison_v1(uuid,date,date,timestamptz)'::regprocedure);
  if position('rn_branch = 1' in v_def) = 0 or position('rn_biz = 1' in v_def) = 0
     or position('one customer visit-day' in v_def) = 0 then
    raise exception 'nestly_v870: branch comparison still counts sale rows as visits' using errcode = 'XX001';
  end if;
end
$verify$;

commit;
