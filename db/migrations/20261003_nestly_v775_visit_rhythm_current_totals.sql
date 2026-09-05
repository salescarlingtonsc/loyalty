-- NESTLY v775 — the visit-rhythm reader states its own window total.
--
-- WHAT WAS WRONG. nestly_v772's public.get_ci_visit_rhythm_v1 computes `cur_tot` (the requested
-- window's own visits and revenue) and uses it — for `change`, and for every hour block's
-- `share` denominator — but never EMITS it. The payload therefore carries a `previous` block
-- with the prior window's totals and a `change` block comparing the two, while the number both
-- of those are relative to is absent. A caller wanting "how many visits this window" has to sum
-- `days[]` itself, which is a client-side re-derivation of a figure the server already holds:
-- it can drift from the server's own denominator (the `share` blocks and `change` are computed
-- from `cur_tot`, not from the days array), and a suppressed or zero-filled day makes the
-- summation look like an arithmetic choice rather than a reading of the server's answer. The
-- Owner-brief UI cannot honestly present a total it had to compute for itself when the reader's
-- own percentages were computed against a different one.
--
-- WHAT THIS DOES. Exactly one change: a new top-level key
--
--     'current', jsonb_build_object('visits', ct.visits, 'revenue_cents', ct.revenue_cents)
--
-- emitted immediately before 'previous', from the SAME `cur_tot` CTE that already feeds `change`
-- and every `share` denominator. The two blocks now read as a pair — `current` and `previous`,
-- with `change` between them — and `sum(days[].visits)` is expected to equal `current.visits`
-- for the same call, because both are the same rows counted once.
--
-- WHY A NEW MIGRATION RATHER THAN AN EDIT TO v772. nestly_v772 is APPLIED to production and
-- recorded in the migration history; editing an applied file would leave the repository claiming
-- something the database never ran. This is a fresh CREATE OR REPLACE of the same function at
-- the same signature.
--
-- WHAT IS DELIBERATELY UNCHANGED. Everything else, byte for byte: the signature
-- (p_business uuid, p_from date, p_to date, p_branch uuid default null,
-- p_as_of timestamptz default clock_timestamp()), the app.ci_access_gate_v667 call and the
-- 22023 window validation ahead of any read, the qualifying-sale predicate (v699 visit day,
-- created_at <= p_as_of, no reversal surviving as of p_as_of, non-synthetic), the sale-row visit
-- grain that keeps this reader in step with public.get_ci_daypart_v1, the k=4 weekday floor and
-- k=5 age-cell suppression, every note string, and the app.ci_envelope_v680 wrapper. No table is
-- created or altered and nothing is written. The revoke/grant pair below is restated verbatim
-- from v772 — the argument list is identical, so CREATE OR REPLACE preserves the ACL, and the
-- restatement is the preflight contract, not a change.
--
-- Proven by db/tests/executed/v772_corpus_owner_brief_readers.sql, whose own predetermined truth
-- table already fixes the window at 14 visits and 124000 cents; v775 adds the assertion that
-- `current` reports exactly those two numbers and that they equal the sum of `days[]`.
begin;

-- ---------------------------------------------------------------------------------------------
-- public.get_ci_visit_rhythm_v1 — v772's body with one added top-level key.
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_visit_rhythm_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_len      integer;
  v_prev_to  date;
  v_prev_from date;
  v_result   jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;
  v_len       := (p_to - p_from) + 1;
  v_prev_to   := p_from - 1;
  v_prev_from := p_from - v_len;

  with base as (
    -- Both windows in one pass; `in_window` separates the requested window from the one
    -- immediately before it.
    select s.id, s.client_id, s.amount_cents,
           app.ci_visit_day_v699(s.occurred_at)          as visit_day,
           (s.occurred_at at time zone 'Asia/Singapore') as local_ts,
           coalesce(s.counts_as_visit, false)            as is_visit,
           coalesce(s.counts_as_revenue, false)          as is_revenue,
           (app.ci_visit_day_v699(s.occurred_at) between p_from and p_to) as in_window
      from public.sales s
      left join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and s.created_at <= p_as_of
       and s.reversal_of is null
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and not coalesce(c.is_synthetic, false)
       and (coalesce(s.counts_as_visit, false) or coalesce(s.counts_as_revenue, false))
       and app.ci_visit_day_v699(s.occurred_at) between v_prev_from and p_to
  ),
  cur as (select * from base where in_window),
  prev as (select * from base where not in_window),
  cal as (
    select d::date as the_day, extract(isodow from d)::int as dow
      from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
  ),
  day_agg as (
    select c.visit_day,
           count(*) filter (where c.is_visit)::bigint                              as visits,
           coalesce(sum(c.amount_cents) filter (where c.is_revenue), 0)::bigint    as revenue_cents,
           count(distinct c.client_id) filter (where c.is_visit
                                                 and c.client_id is not null)::bigint
                                                                                   as identified_customers
      from cur c
     group by c.visit_day
  ),
  days as (
    select cal.the_day, cal.dow,
           case cal.dow when 1 then 'Monday' when 2 then 'Tuesday' when 3 then 'Wednesday'
                        when 4 then 'Thursday' when 5 then 'Friday' when 6 then 'Saturday'
                        else 'Sunday' end as label,
           coalesce(da.visits, 0)               as visits,
           coalesce(da.revenue_cents, 0)        as revenue_cents,
           coalesce(da.identified_customers, 0) as identified_customers
      from cal
      left join day_agg da on da.visit_day = cal.the_day
  ),
  cur_tot as (
    select coalesce(sum(d.visits), 0)::bigint        as visits,
           coalesce(sum(d.revenue_cents), 0)::bigint as revenue_cents
      from days d
  ),
  prev_tot as (
    select count(*) filter (where p.is_visit)::bigint                           as visits,
           coalesce(sum(p.amount_cents) filter (where p.is_revenue), 0)::bigint as revenue_cents
      from prev p
  ),
  weekday_occ as (
    select cal.dow, count(*)::bigint as occurrences from cal group by cal.dow
  ),
  weekdays as (
    select g.dow,
           case g.dow when 1 then 'Monday' when 2 then 'Tuesday' when 3 then 'Wednesday'
                      when 4 then 'Thursday' when 5 then 'Friday' when 6 then 'Saturday'
                      else 'Sunday' end as label,
           coalesce(sum(d.visits), 0)::bigint        as visits,
           coalesce(sum(d.revenue_cents), 0)::bigint as revenue_cents,
           coalesce(max(wo.occurrences), 0)::bigint  as occurrences
      from generate_series(1, 7) as g(dow)
      left join days d on d.dow = g.dow
      left join weekday_occ wo on wo.dow = g.dow
     group by g.dow
  ),
  weekday_rows as (
    select w.*,
           -- Visits per occurrence is a COUNT PER DAY, not a percentage: emitted as a plain
           -- 1dp number, null when the weekday never occurs inside the window.
           case when w.occurrences > 0
                then round(w.visits::numeric / w.occurrences, 1) else null end as per_occurrence,
           app.subgroup_evidence_v1(w.occurrences::int, 4) as evidence
      from weekdays w
  ),
  weekday_ranked as (
    select wr.* from weekday_rows wr
     where wr.evidence->>'status' = 'ok' and wr.per_occurrence is not null
  ),
  blocks as (
    select g.b as block_start,
           (case when g.b = 0 then '12am' when g.b < 12 then g.b || 'am'
                 when g.b = 12 then '12pm' else (g.b - 12) || 'pm' end)
           || '–' ||
           (case when (g.b + 2) % 24 = 0  then '12am'
                 when (g.b + 2) % 24 < 12 then ((g.b + 2) % 24) || 'am'
                 when (g.b + 2) % 24 = 12 then '12pm'
                 else (((g.b + 2) % 24) - 12) || 'pm' end) as label
      from generate_series(0, 22, 2) as g(b)
  ),
  block_agg as (
    select (extract(hour from c.local_ts)::int / 2) * 2 as block_start,
           count(*) filter (where c.is_visit)::bigint                              as visits,
           coalesce(sum(c.amount_cents) filter (where c.is_revenue), 0)::bigint    as revenue_cents,
           count(distinct c.visit_day) filter (where c.is_visit)::bigint           as days_with_visits
      from cur c
     group by 1
  ),
  block_rows as (
    select b.block_start, b.label,
           coalesce(ba.visits, 0)            as visits,
           coalesce(ba.revenue_cents, 0)     as revenue_cents,
           coalesce(ba.days_with_visits, 0)  as days_with_visits
      from blocks b
      left join block_agg ba on ba.block_start = b.block_start
  ),
  block_scored as (
    select br.*, app.rate_block_v1(br.visits, ct.visits) as share
      from block_rows br, cur_tot ct
  ),
  open_blocks as (
    select bs.* from block_scored bs where bs.days_with_visits >= 3
  ),
  -- age-by-block: identified visits only, classified through the gate-free v674 core
  ident as (
    select c.id, c.client_id, (extract(hour from c.local_ts)::int / 2) * 2 as block_start
      from cur c
     where c.is_visit and c.client_id is not null
  ),
  ident_clients as (
    select distinct client_id from ident
  ),
  classified as (
    select ic.client_id, d.dem->>'age_band' as age_band
      from ident_clients ic
      cross join lateral (
        select app.customer_demographics_core_v674(p_business, ic.client_id) as dem
      ) d
  ),
  age_cells as (
    select i.block_start, cl.age_band, count(*)::bigint as visits
      from ident i
      join classified cl on cl.client_id = i.client_id
     where cl.age_band is not null
     group by i.block_start, cl.age_band
  ),
  age_cov as (
    select count(*)::bigint as identified_visits,
           count(*) filter (where cl.age_band is not null)::bigint as age_known_visits
      from ident i
      left join classified cl on cl.client_id = i.client_id
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'visit_definition',
      'one qualifying sale row (the same grain public.get_ci_daypart_v1 counts), bucketed on '
      'the Asia/Singapore calendar day and hour of sale_occurred_at',
    'days', coalesce((
      select jsonb_agg(jsonb_build_object(
               'date', d.the_day, 'dow', d.dow, 'label', d.label,
               'visits', d.visits, 'revenue_cents', d.revenue_cents,
               'identified_customers', d.identified_customers)
             order by d.the_day)
        from days d), '[]'::jsonb),
    'current', jsonb_build_object(
      'visits', ct.visits, 'revenue_cents', ct.revenue_cents),
    'previous', jsonb_build_object(
      'from', v_prev_from, 'to', v_prev_to,
      'visits', pt.visits, 'revenue_cents', pt.revenue_cents),
    'change', jsonb_build_object(
      'visits_pct',
        case when pt.visits > 0
             then round(100.0 * (ct.visits - pt.visits)::numeric / pt.visits, 1)
             else null end,
      'revenue_pct',
        case when pt.revenue_cents > 0
             then round(100.0 * (ct.revenue_cents - pt.revenue_cents)::numeric / pt.revenue_cents, 1)
             else null end),
    'weekdays', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dow', wr.dow, 'label', wr.label, 'visits', wr.visits,
               'occurrences', wr.occurrences, 'per_occurrence', wr.per_occurrence,
               'revenue_cents', wr.revenue_cents, 'evidence', wr.evidence)
             order by wr.dow)
        from weekday_rows wr), '[]'::jsonb),
    'slowest_weekdays', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dow', q.dow, 'label', q.label, 'visits', q.visits,
               'occurrences', q.occurrences, 'per_occurrence', q.per_occurrence)
             order by q.per_occurrence, q.dow)
        from (select * from weekday_ranked
               order by per_occurrence asc, dow asc limit 2) q), '[]'::jsonb),
    'busiest_weekdays', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dow', q.dow, 'label', q.label, 'visits', q.visits,
               'occurrences', q.occurrences, 'per_occurrence', q.per_occurrence)
             order by q.per_occurrence desc, q.dow)
        from (select * from weekday_ranked
               order by per_occurrence desc, dow asc limit 2) q), '[]'::jsonb),
    'hour_blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'block_start', bs.block_start, 'label', bs.label, 'visits', bs.visits,
               'revenue_cents', bs.revenue_cents, 'days_with_visits', bs.days_with_visits,
               'share', bs.share)
             order by bs.block_start)
        from block_scored bs), '[]'::jsonb),
    'open_blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'block_start', ob.block_start, 'label', ob.label, 'visits', ob.visits,
               'days_with_visits', ob.days_with_visits)
             order by ob.block_start)
        from open_blocks ob), '[]'::jsonb),
    'open_block_rule', 'a two-hour block counts as open when it saw visits on at least 3 days',
    'slowest_blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'block_start', q.block_start, 'label', q.label, 'visits', q.visits,
               'days_with_visits', q.days_with_visits)
             order by q.visits, q.block_start)
        from (select * from open_blocks
               order by visits asc, block_start asc limit 2) q), '[]'::jsonb),
    'busiest_blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'block_start', q.block_start, 'label', q.label, 'visits', q.visits,
               'days_with_visits', q.days_with_visits)
             order by q.visits desc, q.block_start)
        from (select * from open_blocks
               order by visits desc, block_start asc limit 2) q), '[]'::jsonb),
    'age_by_block', coalesce((
      select jsonb_agg(jsonb_build_object(
               'block_start', ac.block_start,
               'label', b.label,
               'age_band', ac.age_band,
               'visits', case when ac.visits >= 5 then ac.visits else null end,
               'suppressed', ac.visits < 5)
             order by ac.block_start, ac.age_band)
        from age_cells ac
        join blocks b on b.block_start = ac.block_start), '[]'::jsonb),
    'age_by_block_note',
      'A cell below the shared 5-visit floor keeps its place and reports visits as null with '
      'suppressed true; it is never dropped and never printed as zero.',
    'coverage', jsonb_build_object(
      'age_known', app.rate_block_v1(av.age_known_visits, av.identified_visits)),
    'time_basis', 'sale_occurred_at',
    'basis_note',
      'Bucketed on sale_occurred_at -- the till timestamp a sale was RECORDED at -- converted '
      'to Asia/Singapore. This is TILL time, not arrival time or service-start time: neither is '
      'captured anywhere in this schema today, so a customer who waited before being served, or '
      'a booking whose service began well before checkout, is bucketed by when the sale closed, '
      'not by when they walked in.',
    'evidence_class', 'DIRECT_FACT',
    'observed_since', app.metric_observed_since_v1('ci_visit_rhythm', p_business))
    into v_result
    from cur_tot ct, prev_tot pt, age_cov av;

  return app.ci_envelope_v680('ci_visit_rhythm_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_visit_rhythm_v1(uuid,date,date,uuid,timestamptz)
  from public, anon;
grant execute on function public.get_ci_visit_rhythm_v1(uuid,date,date,uuid,timestamptz)
  to authenticated, service_role;

commit;
