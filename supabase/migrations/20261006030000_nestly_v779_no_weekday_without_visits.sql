-- NESTLY v779 — no busiest or slowest day when nothing happened.
--
-- THE DEFECT, SEEN LIVE. public.get_ci_branch_comparison_v1 (nestly_v777) reported
-- `busiest_weekday {Monday, 0}` AND `slowest_weekday {Monday, 0}` for a branch with no visits
-- at all in the window. Both readings are produced entirely by the tie-break: every weekday
-- sits at per_occurrence 0.0, `distinct on (branch_id) ... order by per_occurrence desc, dow`
-- and its `asc` twin therefore both land on dow 1, and the payload states a busiest day, a
-- slowest day, and the fact that they are the same day — three claims about a trading pattern
-- from a branch that did not trade. It is worse than a wrong number: it is the SAME wrong
-- number for every empty branch, so a reader comparing outlets sees "Monday" repeat and reads
-- it as a finding.
--
-- THE SAME SHAPE, LATENT, IN public.get_ci_visit_rhythm_v1 (nestly_v772, re-emitted by
-- nestly_v775): `slowest_weekdays` and `busiest_weekdays` are built from `weekday_ranked`,
-- which filters on the k=4 OCCURRENCE evidence floor and on per_occurrence being non-null —
-- neither of which has anything to say about visits. A 28-day window with no visits clears the
-- occurrence floor on all seven weekdays and yields two arrays naming Monday and Tuesday as
-- the busiest days at 0.0 apiece. Not yet reported by a user, and fixed here rather than
-- waiting for it: it is the same defect class, one function away, and the Bug-Closure Protocol
-- asks for the class and not the tenant.
--
-- THE RULE, ONE SENTENCE. A busiest or slowest weekday (or hour block) is emitted only when the
-- ranked candidate set contains at least one entry with visits > 0; when every candidate is at
-- zero, the comparison emits null and the rhythm reader emits []. Ties among POSITIVE values
-- keep their existing deterministic tie-break unchanged, and a zero-visit candidate may still
-- win `slowest` as long as some other candidate in the same set has a visit — which is the
-- honest answer ("you were shut on Saturday") and the one v772's own truth table already fixes.
--
-- WHAT THIS IS NOT. It is not a suppression floor. Nothing is hidden because it is small: the
-- `weekdays` array still lists all seven with their real counts, `hour_blocks` still lists all
-- twelve, and `open_blocks` still lists every block that cleared the open rule. Only the four
-- SUPERLATIVES are gated, and only in the one case where a superlative has no meaning.
--
-- WHY A NEW MIGRATION RATHER THAN AN EDIT. nestly_v772, nestly_v775 and nestly_v777 are all
-- APPLIED to production and recorded in the migration history; editing an applied file would
-- leave the repository claiming something the database never ran. These are fresh CREATE OR
-- REPLACE statements at the same signatures, over the live bodies (v775's for the rhythm
-- reader, v777's for the comparison), reproduced verbatim apart from the guard.
--
-- WHAT IS DELIBERATELY UNCHANGED. Both signatures; the app.ci_access_gate_v667 calls and the
-- 22023 window validation ahead of any read; the qualifying-sale predicate; the sale-row visit
-- grain; the k=4 weekday-occurrence floor and the k=5 people floors; every rate block, evidence
-- block and note string; the v680 envelope. No table is created or altered and nothing is
-- written. Both revoke/grant pairs are restated verbatim from v772/v777 — the argument lists
-- are identical, so CREATE OR REPLACE preserves the ACLs, and the restatement is the preflight
-- contract, not a change.
--
-- HOW THE GUARD IS EXPRESSED, AND WHY NOT A `visits > 0` FILTER. Filtering the candidate set
-- down to positive weekdays would ALSO change the answer for a branch that traded, by making a
-- genuine zero-visit Saturday ineligible to be its slowest day. The guard is therefore a whole-
-- set existence test — keep every candidate, or none — which touches only the all-zero case:
--
--     where exists (select 1 from weekday_ranked z where z.visits > 0)     -- rhythm
--     having max(wr.visits) > 0                                           -- comparison, per branch
--
-- The comparison's version groups by branch because its candidate set is per branch, and it is
-- an INNER JOIN so an unranked branch falls out and the reader's existing
-- `case when bwd.label is null then null` emits null with no further change.
--
-- THE HOUR BLOCKS ARE GUARDED THOUGH THEY CANNOT CURRENTLY FAIL. `open_blocks` requires
-- days_with_visits >= 3, and days_with_visits counts distinct days on which the block saw a
-- visit, so an open block always has at least 3 visits and can never be at zero. The guard is
-- stated anyway: the rule belongs to the concept of a superlative, not to the arithmetic that
-- happens to make it unreachable today, and relaxing `open_block_rule` — a one-number change
-- someone will eventually make — would otherwise bring the fabrication straight back with no
-- test to catch it.
--
-- PROVEN BY:
--   db/tests/executed/v777_corpus_branch_code_and_comparison.sql — a fourth ACTIVE branch (B04)
--     with no sales at all: busiest_weekday and slowest_weekday both null, while B01 keeps
--     Monday 1.0 / Saturday 0.0 unchanged.
--   db/tests/executed/v772_corpus_owner_brief_readers.sql — a rhythm call over
--     2026-05-04..2026-05-31 (28 days, four of every weekday, zero visits): slowest_weekdays,
--     busiest_weekdays, slowest_blocks and busiest_blocks all [], `weekdays` still seven rows,
--     current.visits 0 — while the existing 2026-03 call keeps every value it had.
--
-- ROLLBACK: re-apply nestly_v775's public.get_ci_visit_rhythm_v1 and nestly_v777's
-- public.get_ci_branch_comparison_v1 verbatim; this migration adds two CTEs to the first and
-- one to the second, and changes four FROM clauses between them. Nothing else moves.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1 · public.get_ci_visit_rhythm_v1 — v775's body, with the rule on weekdays and blocks.
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
  -- v779: a superlative needs something to be superlative ABOUT. When every ranked weekday sits
  -- at zero visits there is no busiest and no slowest one, only seven ties, and naming one is a
  -- fabrication produced by the tie-break rather than by the data. Emptying the candidate set
  -- here makes both arrays [] through their existing coalesce, and subtracts nothing the moment
  -- ANY weekday has a visit -- including the case this reader must keep, a zero-visit weekday
  -- winning `slowest` in a window that saw visits on other days.
  weekday_ranked_live as (
    select wr.* from weekday_ranked wr
     where exists (select 1 from weekday_ranked z where z.visits > 0)
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
  -- v779: the same rule for the two-hour blocks. `open_blocks` itself is a LISTING and keeps
  -- every row it had; only the two SUPERLATIVES read from this. Today the guard can never
  -- subtract a row -- days_with_visits >= 3 already implies visits >= 3, so an open block is
  -- never at zero -- and it is stated anyway, because the rule belongs to the concept and not
  -- to the arithmetic that currently makes it unreachable: relax open_block_rule to >= 0 and
  -- the fabrication returns at once, silently.
  open_blocks_live as (
    select ob.* from open_blocks ob
     where exists (select 1 from open_blocks z where z.visits > 0)
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
        from (select * from weekday_ranked_live
               order by per_occurrence asc, dow asc limit 2) q), '[]'::jsonb),
    'busiest_weekdays', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dow', q.dow, 'label', q.label, 'visits', q.visits,
               'occurrences', q.occurrences, 'per_occurrence', q.per_occurrence)
             order by q.per_occurrence desc, q.dow)
        from (select * from weekday_ranked_live
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
        from (select * from open_blocks_live
               order by visits asc, block_start asc limit 2) q), '[]'::jsonb),
    'busiest_blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'block_start', q.block_start, 'label', q.label, 'visits', q.visits,
               'days_with_visits', q.days_with_visits)
             order by q.visits desc, q.block_start)
        from (select * from open_blocks_live
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

-- ---------------------------------------------------------------------------------------------
-- 2 · public.get_ci_branch_comparison_v1 — v777's body, with the same rule per branch.
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_branch_comparison_v1(
  p_business uuid, p_from date, p_to date,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
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
    select s.id, s.client_id, s.branch_id, s.amount_cents,
           app.ci_visit_day_v699(s.occurred_at)   as visit_day,
           coalesce(s.counts_as_visit, false)     as is_visit,
           coalesce(s.counts_as_revenue, false)   as is_revenue
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
    select count(*) filter (where sc.is_visit)::bigint                              as visits,
           coalesce(sum(sc.amount_cents) filter (where sc.is_revenue), 0)::bigint    as revenue_cents,
           count(distinct sc.client_id) filter (where sc.is_visit
                                                  and sc.client_id is not null)::bigint
                                                                                     as customers,
           count(*) filter (where sc.is_visit and sc.branch_id is null)::bigint      as unattributed_visits
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
           count(c.id) filter (where c.is_visit)::bigint                            as visits,
           coalesce(sum(c.amount_cents) filter (where c.is_revenue), 0)::bigint     as revenue_cents,
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
           count(c.id) filter (where c.is_visit)::bigint               as visits
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
      'one qualifying sale row (the same grain public.get_ci_visit_rhythm_v1 counts), attributed '
      'to the branch the sale was recorded at',
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
$$;

revoke all on function public.get_ci_branch_comparison_v1(uuid,date,date,timestamptz)
  from public, anon;
grant execute on function public.get_ci_branch_comparison_v1(uuid,date,date,timestamptz)
  to authenticated, service_role;

commit;
