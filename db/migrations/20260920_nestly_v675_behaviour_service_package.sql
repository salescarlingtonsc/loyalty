-- NESTLY v675 — behaviour: daypart (with honest denominators), service intelligence,
-- package intelligence.
--
-- Phase CI-A of the Customer Intelligence program. Closes checklist items 35 (daypart naming
-- and exposure), 36 (busiest vs most-valuable must be distinguishable), and 60 (service and
-- package intelligence). Three readers, all embedding the frozen v672 statistical authority
-- (docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md) and gating through the v667 access boundary
-- (app.ci_access_gate_v667). Proven by db/tests/executed/v675_corpus_behaviour.sql.
--
-- ---------------------------------------------------------------------------------------------
-- WHAT "QUALIFYING" MEANS HERE, and why it is app.analytics_sale_class_v1, not a hand-rolled
-- WHERE clause.
-- ---------------------------------------------------------------------------------------------
-- nestly_v628 ("Phase A capture-correctness") already wrote the exclusion authority this
-- contract asks every Phase-A-onward reader to use: app.analytics_sale_class_v1(sales row)
-- returns include_revenue / include_visit / is_reversal / is_entitlement / is_synthetic_client
-- for one sale, and its docstring says plainly: "no extra lookup... refined further when v634's
-- line kinds land". v628's own comment says this is "advisory" for EXISTING readers but
-- MANDATORY ("must use them") for readers added from Phase A onward — this migration is that
-- phase, so all three readers call it instead of re-deriving `reversal_of is null and not
-- exists(...) and counts_as_revenue` inline the way the (pre-Phase-A) v667 readers do. Same
-- population, one fewer place it can drift. app.analytics_business_included_v1 (the sibling
-- demo/QA-tenant exclusion) is deliberately NOT applied here: it exists for platform-wide scans
-- across many tenants, and these three readers are single-tenant drill-downs an already-entitled
-- caller asked for by business_id — excluding a demo-flagged tenant from its OWN owner's read
-- would be a surprise refusal wearing an access-control costume, not what that authority is for.
--
-- ---------------------------------------------------------------------------------------------
-- THE PACKAGE SCHEMA, as actually found (not guessed). Grep chain: v5/v6 notes -> v34 (session
-- consumption/reversal tables) -> v102 (sell_package_v102 / use_package_session_v102, the entitlement
-- shape) -> v593 (expiry: expiry_days on package_plans, expiry_days_snapshot/expires_at on
-- client_packages, DERIVED never swept — a row reads 'expired' at query time, the stored `status`
-- column never becomes 'expired') -> v601 (edit/retire/switch; save_package_plan_v102 clones on
-- edit, so a plan version is immutable once sold) -> v627 (branch scoping for the SALE, via
-- package_branches; the entitlement row itself carries no branch) -> v655 (expiry_days on
-- save_package_plan_v102's signature). Tables actually used below:
--   public.package_plans        the sellable design: sessions, price_cents, expiry_days,
--                                active, version_no (immutable once sold; save_package_plan_v102
--                                clones rather than mutates a version that has sales against it).
--   public.client_packages      one row per PURCHASE ("entitlement"): remaining, status
--                                ('active'|'used_up' — 'expired' is NEVER stored, only derived
--                                by comparing expires_at to now()), purchased_at, expires_at,
--                                sessions_snapshot, plan_id. NO branch_id and NO sale_id column —
--                                the purchase's `sales` row (kind='package') is written by the
--                                same RPC in the same transaction but nothing FK-links the two,
--                                which is exactly why this migration's package reader refuses a
--                                branch filter (see part 3 below) instead of guessing a join.
--   public.package_session_consumptions   one row per SESSION USE, written by
--                                use_package_session_v102 alongside a zero-dollar `sales` row
--                                (kind='service', amount_cents=0 — so it earns nothing but DOES
--                                count as a visit, since kind='service' policy default is
--                                counts_as_visit=true; kind='package' itself is
--                                counts_as_revenue=true/counts_as_visit=FALSE per the v10 fix
--                                CLAUDE.md documents, so a package purchase alone never inflates
--                                the visit count and each session use counts exactly once).
--   public.package_session_reversals      not used by these readers (a reversed session nets
--                                back into `remaining`, which sessions_used already reads live).
--
-- ---------------------------------------------------------------------------------------------
-- JUDGEMENT CALLS, made explicit rather than silent.
-- ---------------------------------------------------------------------------------------------
-- 1. ONE FLOOR, THE DEFAULT (5), EVERYWHERE — REVERSED FROM THE FIRST DRAFT. The first draft of
--    this migration argued that a weekday bucket or a package plan's utilisation never names an
--    individual, so a 5-person floor would routinely null out ordinary small-business weeks, and
--    used an explicit floor of 2 for daypart and package intelligence instead of the identity-
--    tuned default of 5. That was wrong, and was reversed on review, for two reasons. First, the
--    floor is not only about re-identification: app.subgroup_evidence_v1 exists (per v672's own
--    header) to stop ANY rate or dollar figure being reported "as confidently from a 1-customer
--    cohort as a 500-customer one" — a weekday with 2 visits crowning itself "most valuable" off
--    one lucky sale is exactly that failure, identity or no identity. Second, and worse: floor=2
--    was chosen because it was precisely the number this migration's OWN fixture needed for its
--    2-visit Saturday and 2-sold package plan to clear the bar — a floor a fixture can tune until
--    its own seed data passes is not a floor at all, and the incentive runs backwards (cheaper
--    seeding should never be the reason a statistical discipline gets relaxed). All three readers
--    now call app.subgroup_evidence_v1 with no floor argument, i.e. the shared default of 5, with
--    no per-reader override anywhere in this file. What changes below the floor is deliberately
--    narrow: RAW COUNTS are never suppressed (visits, revenue_cents, weekday_occurrences,
--    sold_count, sessions_included/used, expired_or_lapsed_with_unused, repurchase_count and
--    outside_spend_cents all stay visible at any n, because a count is a fact, not a claim) —
--    only RATE-LIKE and VERDICT fields go null or become ineligible: revenue_per_visit_cents and
--    visits_per_occurrence.pct (daypart), utilisation.pct and median_days_between_sessions
--    (package), repeat_rate.pct and median_days_to_next_purchase (service — unchanged from the
--    first draft, which already used the default floor there). most_valuable_weekday is chosen
--    only among evidence-ok weekdays for the same reason; busiest_weekday stays a raw max over
--    ALL weekdays regardless of evidence, because "busiest" is a count statement ("most visits"),
--    not a rate claim, and suppressing it would hide a true, cheap, sample-size-independent fact
--    behind a floor built for a different failure mode. The fixture now seeds MORE data instead
--    of a smaller floor — Monday, Saturday and one package plan each clear n=5 — and keeps a
--    genuinely below-floor weekday (Wednesday) and package plan in specifically to prove the
--    suppression, and the ineligibility of a below-floor cell for a "most valuable" verdict,
--    actually fire.
-- 2. median_days_between_sessions' OWN floor ("<3 gaps" in the acceptance brief) is read here as
--    "<3 pooled session-use EVENTS", i.e. n-1 gaps from n>=3 events, not literally 3 gap values.
--    The brief's own worked example (one holder using 3 of 5 sessions, two 7-day gaps) produces
--    exactly 2 gap values and asks for a real median of 7 — reading the floor as "3 gaps" would
--    null out the brief's own example. "3 observations" is the more defensible reading of the
--    English regardless: three timestamps IS three observations, even though they only yield two
--    differences. median_days_to_next_purchase (service reader) keeps the literal "<3 next-
--    purchase observations" floor the brief states for it, since that one is unambiguous (each
--    observation there already IS a single day-gap, not a session timestamp).
-- 3. get_ci_service_intelligence_v1's "gateway" and "median days to next purchase" both look at a
--    client's LIFETIME sales, firm-wide, never window- or branch-bounded — deliberately: a
--    customer's true first visit, or what they bought next, does not stop being true because it
--    happened at another branch or before p_from. Only "buyers/orders/revenue in this service,
--    this window" is window+branch-scoped.
-- 4. get_ci_package_intelligence_v1's cohort is holders whose PURCHASE fell inside [p_from,p_to]
--    (mirrors "sold_count" and the brief's own utilisation formula, sold*included as the
--    denominator) — sessions_used, expiry state and repurchase history are read from each such
--    holder's CURRENT row state (remaining/status/expires_at), not filtered to session-use events
--    that happened inside the window, because "how much of what they bought this window have they
--    used, as of today" is the more useful number and matches how sessions_included is computed
--    (a lifetime entitlement size, not a windowed count).
--
-- Named for v675: gate=app.ci_access_gate_v667, contract=app.{subgroup_evidence,rate_block,
-- distribution_block,comparisons_note}_v1 (v672), exclusions=app.analytics_sale_class_v1 (v628).

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. Daypart: weekday (with an honest exposure denominator) and hour-of-day.
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_daypart_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  with scope as (
    select s.id, s.amount_cents,
           sc.include_revenue, sc.include_visit,
           (s.occurred_at at time zone 'Asia/Singapore') as local_ts
      from public.sales s
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and not sc.is_synthetic_client
       and (sc.include_revenue or sc.include_visit)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  weekday_occ as (
    -- the exposure denominator: how many times each ISO weekday actually falls inside
    -- [p_from,p_to]. A 14-day window has each weekday exactly twice; a 10-day one does not,
    -- and treating "visits" alone as comparable across weekdays without this would be the
    -- dishonest-denominator failure this checklist item exists to close.
    select extract(isodow from d)::int as dow, count(*) as occurrences
      from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
     group by 1
  ),
  by_weekday as (
    select extract(isodow from local_ts)::int as dow,
           count(*) filter (where include_visit) as visits,
           coalesce(sum(amount_cents) filter (where include_revenue), 0) as revenue_cents
      from scope
     group by 1
  ),
  weekdays as (
    select g.dow,
           case g.dow when 1 then 'Monday' when 2 then 'Tuesday' when 3 then 'Wednesday'
                      when 4 then 'Thursday' when 5 then 'Friday' when 6 then 'Saturday'
                      else 'Sunday' end as label,
           coalesce(bw.visits, 0) as visits,
           coalesce(bw.revenue_cents, 0) as revenue_cents,
           coalesce(wo.occurrences, 0) as weekday_occurrences
      from generate_series(1, 7) as g(dow)
      left join weekday_occ wo on wo.dow = g.dow
      left join by_weekday bw on bw.dow = g.dow
  ),
  weekday_rows as (
    -- evidence uses app.subgroup_evidence_v1's own default floor (5), no override -- see
    -- judgement call #1. revenue_per_visit_cents and visits_per_occurrence (below) are rate-like
    -- and go null when that evidence is insufficient; visits/revenue_cents/weekday_occurrences
    -- are raw counts and are never suppressed, at any n.
    select w.*,
           app.subgroup_evidence_v1(w.visits::int) as evidence
      from weekdays w
  ),
  weekday_rated as (
    select wr.*,
           case when wr.evidence ->> 'status' = 'ok' and wr.visits > 0
                then round(wr.revenue_cents::numeric / wr.visits) else null end
             as revenue_per_visit_cents,
           case when wr.evidence ->> 'status' = 'ok'
                then app.rate_block_v1(wr.visits, wr.weekday_occurrences)
                else jsonb_build_object('numerator', wr.visits,
                                         'denominator', wr.weekday_occurrences, 'pct', null) end
             as visits_per_occurrence
      from weekday_rows wr
  ),
  by_hour as (
    select extract(hour from local_ts)::int as hr,
           count(*) filter (where include_visit) as visits,
           coalesce(sum(amount_cents) filter (where include_revenue), 0) as revenue_cents
      from scope
     group by 1
  ),
  hours as (
    select g.hr, coalesce(bh.visits, 0) as visits, coalesce(bh.revenue_cents, 0) as revenue_cents
      from generate_series(0, 23) as g(hr)
      left join by_hour bh on bh.hr = g.hr
  ),
  busiest as (
    -- raw count, no evidence gate: "busiest" is a fact about volume, not a claim about a rate.
    select dow, label, visits from weekday_rated order by visits desc, dow asc limit 1
  ),
  most_valuable as (
    -- check 36: distinguishable from busiest on purpose, and gated on evidence (default floor 5)
    -- so a below-floor weekday cannot crown itself "most valuable" off a lucky sale or two, no
    -- matter how large its raw revenue_per_visit_cents would otherwise look.
    select dow, label, revenue_per_visit_cents from weekday_rated
     where evidence ->> 'status' = 'ok' and revenue_per_visit_cents is not null
     order by revenue_per_visit_cents desc, dow asc limit 1
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                 'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'basis_note',
      'Bucketed on sale_occurred_at -- the till timestamp a sale was RECORDED at -- converted to '
      'Asia/Singapore. This is TILL time, not arrival time or service-start time: neither is '
      'captured anywhere in this schema today, so a customer who waited before being served, or '
      'a booking whose service began well before checkout, is bucketed by when the sale closed, '
      'not by when they walked in.',
    'weekdays', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'dow', wr.dow, 'label', wr.label,
               'visits', wr.visits, 'revenue_cents', wr.revenue_cents,
               'revenue_per_visit_cents', wr.revenue_per_visit_cents,
               'weekday_occurrences', wr.weekday_occurrences,
               'visits_per_occurrence', wr.visits_per_occurrence,
               'evidence', wr.evidence
             ) order by wr.dow), '[]'::jsonb)
        from weekday_rated wr
    ),
    'hours', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'hour', h.hr, 'visits', h.visits, 'revenue_cents', h.revenue_cents,
               'revenue_per_visit_cents',
                 case when h.visits > 0
                      then round(h.revenue_cents::numeric / h.visits) else null end
             ) order by h.hr), '[]'::jsonb)
        from hours h
    ),
    'busiest_weekday',
      (select jsonb_build_object('dow', b.dow, 'label', b.label, 'visits', b.visits) from busiest b),
    'most_valuable_weekday',
      (select jsonb_build_object('dow', m.dow, 'label', m.label,
                                  'revenue_per_visit_cents', m.revenue_per_visit_cents)
         from most_valuable m),
    'observed_since', app.metric_observed_since_v1('ci_daypart', p_business)
  ) into v_result;

  return v_result;
end;
$function$;
revoke all on function public.get_ci_daypart_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_daypart_v1(uuid,date,date,uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 2. Service intelligence.
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_service_intelligence_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_result jsonb;
  v_floor constant integer := 5;   -- identity-adjacent: same k=5 as get_ci_category_customers_v1.
  v_limit constant integer := 20;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  with lines as (
    -- window+branch scoped: what was bought, here, in this period.
    select si.sale_id, si.ref_id as service_id, si.line_cents, s.client_id, s.occurred_at
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
      cross join lateral app.analytics_sale_class_v1(s) sc
     where si.business_id = p_business
       and si.item_type = 'service'
       and si.ref_id is not null
       and (p_branch is null or s.branch_id = p_branch)
       and sc.include_revenue
       and not sc.is_synthetic_client
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  first_ever_sale as (
    -- lifetime, firm-wide, NOT window- or branch-bounded (judgement call #3): each client's
    -- earliest-ever qualifying sale with this business, deterministic tie-break on (time, id).
    select distinct on (s.client_id) s.client_id, s.id as sale_id
      from public.sales s
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and sc.include_revenue
       and not sc.is_synthetic_client
       and s.client_id is not null
     order by s.client_id, s.occurred_at asc, s.id asc
  ),
  gateway_clients as (
    -- a buyer counts as "gateway" for a service iff that service was a line item on their
    -- GLOBAL first-ever sale, whether or not that first sale itself fell inside this window.
    select distinct l.service_id, l.client_id
      from lines l
      join first_ever_sale fes on fes.client_id = l.client_id
      join public.sale_items gi
        on gi.sale_id = fes.sale_id and gi.business_id = p_business
       and gi.item_type = 'service' and gi.ref_id = l.service_id
  ),
  per_service as (
    select service_id,
           count(distinct client_id) as buyers,
           count(distinct sale_id) as orders,
           coalesce(sum(line_cents), 0) as revenue_cents
      from lines
     group by service_id
  ),
  buyer_orders as (
    select service_id, client_id, count(distinct sale_id) as n
      from lines
     group by service_id, client_id
  ),
  repeat_counts as (
    select service_id, count(*) as repeat_buyers
      from buyer_orders
     where n >= 2
     group by service_id
  ),
  gateway_counts as (
    select service_id, count(distinct client_id) as gateway_count
      from gateway_clients
     group by service_id
  ),
  last_purchase as (
    select service_id, client_id, max(occurred_at) as last_at
      from lines
     group by service_id, client_id
  ),
  next_purchase as (
    -- one observation per (service, buyer): days from their last in-window purchase of this
    -- service to their next qualifying sale of ANY kind, lifetime -- never window-bounded.
    select lp.service_id, lp.client_id,
           extract(epoch from (np.next_at - lp.last_at)) / 86400.0 as days_to_next
      from last_purchase lp
      cross join lateral (
        select min(s2.occurred_at) as next_at
          from public.sales s2
          cross join lateral app.analytics_sale_class_v1(s2) sc2
         where s2.business_id = p_business
           and s2.client_id = lp.client_id
           and sc2.include_revenue
           and not sc2.is_synthetic_client
           and s2.occurred_at > lp.last_at
      ) np
     where np.next_at is not null
  ),
  median_days as (
    -- the literal "<3 observations" floor the brief states for this field: each row here IS
    -- already a single day-gap, unlike the package reader's session-timestamp pooling.
    select service_id, count(*) as n_obs,
           percentile_cont(0.5) within group (order by days_to_next) as raw_median
      from next_purchase
     group by service_id
  ),
  services_agg as (
    select ps.service_id, svc.name as service_name,
           ps.buyers, ps.orders, ps.revenue_cents,
           coalesce(rc.repeat_buyers, 0) as repeat_buyers,
           coalesce(gc.gateway_count, 0) as gateway_count,
           coalesce(md.n_obs, 0) as median_n_obs,
           md.raw_median,
           app.subgroup_evidence_v1(ps.buyers::int, v_floor) as evidence
      from per_service ps
      join public.services svc on svc.id = ps.service_id and svc.business_id = p_business
      left join repeat_counts rc on rc.service_id = ps.service_id
      left join gateway_counts gc on gc.service_id = ps.service_id
      left join median_days md on md.service_id = ps.service_id
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                 'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'basis_note', 'Buyers/orders/revenue are window+branch scoped; gateway status and the next-'
      'purchase gap look at each client''s full lifetime history with this business, not just '
      'this window (see the migration header, judgement call 3).',
    'services', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'service_id', x.service_id, 'service_name', x.service_name,
               'buyers', x.buyers, 'orders', x.orders, 'revenue_cents', x.revenue_cents,
               'repeat_buyers', x.repeat_buyers,
               'repeat_rate',
                 case when x.evidence ->> 'status' = 'ok'
                      then app.rate_block_v1(x.repeat_buyers, x.buyers)
                      else jsonb_build_object('numerator', x.repeat_buyers,
                                               'denominator', x.buyers, 'pct', null) end,
               'gateway_count', x.gateway_count,
               'median_days_to_next_purchase',
                 case when x.evidence ->> 'status' = 'ok' and x.median_n_obs >= 3
                      then round(x.raw_median::numeric, 1) else null end,
               'evidence', x.evidence
             ) order by x.revenue_cents desc, x.service_id), '[]'::jsonb)
        from (select * from services_agg order by revenue_cents desc, service_id limit v_limit) x
    ),
    'truncated', (select count(*) from services_agg) > v_limit,
    'observed_since', app.metric_observed_since_v1('ci_service_intelligence', p_business)
  ) into v_result;

  return v_result;
end;
$function$;
revoke all on function public.get_ci_service_intelligence_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_service_intelligence_v1(uuid,date,date,uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 3. Package intelligence.
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_package_intelligence_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  -- client_packages carries no branch_id and no sale_id: the purchase's `sales` row (which DOES
  -- carry branch_id) is written by sell_package_v102 in the same transaction but nothing FK-
  -- links the two rows (verified against the schema; see the migration header). A branch filter
  -- is refused rather than silently ignored -- exactly the discipline v667 established.
  perform app.ci_no_branch_dimension_v667(p_branch, 'package intelligence');
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  with cohort as (
    -- window cohort: package holders whose PURCHASE fell inside [p_from,p_to] (judgement call 4).
    select cp.id as client_package_id, cp.plan_id, cp.client_id, cp.remaining, cp.status,
           cp.sessions_snapshot, cp.purchased_at, cp.expires_at
      from public.client_packages cp
      join public.clients c on c.id = cp.client_id and c.business_id = p_business
     where cp.business_id = p_business
       and not coalesce(c.is_synthetic, false)
       and (cp.purchased_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  usage_events as (
    select psc.client_package_id, psc.created_at,
           row_number() over (partition by psc.client_package_id order by psc.created_at) as rn
      from public.package_session_consumptions psc
      join cohort ch on ch.client_package_id = psc.client_package_id
     where psc.business_id = p_business
  ),
  gaps as (
    select ch.plan_id,
           extract(epoch from (cur.created_at - prev.created_at)) / 86400.0 as gap_days
      from usage_events cur
      join usage_events prev
        on prev.client_package_id = cur.client_package_id and prev.rn = cur.rn - 1
      join cohort ch on ch.client_package_id = cur.client_package_id
  ),
  gap_stats as (
    select plan_id, percentile_cont(0.5) within group (order by gap_days) as raw_median
      from gaps
     group by plan_id
  ),
  event_counts as (
    -- pooled session-use EVENT count, not gap count -- see judgement call #2.
    select ch.plan_id, count(ue.rn) as n_events
      from cohort ch
      left join usage_events ue on ue.client_package_id = ch.client_package_id
     group by ch.plan_id
  ),
  repurchase as (
    -- one row per (plan, client) that already held an EARLIER package for the same plan which
    -- had reached used_up or expired (by the time of this window purchase) before this purchase.
    select distinct ch.plan_id, ch.client_id
      from cohort ch
     where exists (
       select 1 from public.client_packages older
        where older.business_id = p_business
          and older.plan_id = ch.plan_id
          and older.client_id = ch.client_id
          and older.id <> ch.client_package_id
          and older.purchased_at < ch.purchased_at
          and (older.status = 'used_up'
               or (older.expires_at is not null and older.expires_at < ch.purchased_at))
     )
  ),
  repurchase_counts as (
    select plan_id, count(*) as repurchase_count from repurchase group by plan_id
  ),
  outside_spend as (
    -- non-package qualifying revenue from this window's holders, in this same window.
    select ch.plan_id, coalesce(sum(s.amount_cents), 0) as spend_cents
      from cohort ch
      join public.sales s on s.business_id = p_business and s.client_id = ch.client_id
      cross join lateral app.analytics_sale_class_v1(s) sc
     where sc.include_revenue
       and not sc.is_synthetic_client
       and s.kind <> 'package'
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
     group by ch.plan_id
  ),
  per_plan as (
    select ch.plan_id,
           count(*) as sold_count,
           sum(ch.sessions_snapshot) as sessions_included,
           sum(ch.sessions_snapshot - ch.remaining) as sessions_used,
           count(*) filter (
             where ch.remaining > 0 and ch.expires_at is not null and ch.expires_at < now()
           ) as expired_or_lapsed_with_unused
      from cohort ch
     group by ch.plan_id
  ),
  plans as (
    select pp.id as plan_id, pp.name as plan_name,
           pl.sold_count, pl.sessions_included, pl.sessions_used,
           pl.expired_or_lapsed_with_unused,
           coalesce(rp.repurchase_count, 0) as repurchase_count,
           coalesce(os.spend_cents, 0) as outside_spend_cents,
           coalesce(ec.n_events, 0) as n_events,
           gs.raw_median,
           -- default floor (5), no override -- see judgement call #1.
           app.subgroup_evidence_v1(pl.sold_count::int) as evidence
      from public.package_plans pp
      join per_plan pl on pl.plan_id = pp.id
      left join repurchase_counts rp on rp.plan_id = pp.id
      left join outside_spend os on os.plan_id = pp.id
      left join event_counts ec on ec.plan_id = pp.id
      left join gap_stats gs on gs.plan_id = pp.id
     where pp.business_id = p_business
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', null,
                                 'from', p_from, 'to', p_to),
    'time_basis', 'client_packages.purchased_at',
    'basis_note', 'One row per plan with at least one purchase inside the window. Utilisation, '
      'expiry state and repurchase history are read from each window holder''s CURRENT row, not '
      're-filtered to session-use events inside the window (see the migration header, judgement '
      'call 4).',
    'plans', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'plan_id', p.plan_id, 'plan_name', p.plan_name,
               'sold_count', p.sold_count,
               'sessions_included', p.sessions_included,
               'sessions_used', p.sessions_used,
               'utilisation',
                 case when p.evidence ->> 'status' = 'ok'
                      then app.rate_block_v1(p.sessions_used, p.sessions_included)
                      else jsonb_build_object('numerator', p.sessions_used,
                                               'denominator', p.sessions_included, 'pct', null) end,
               'median_days_between_sessions',
                 case when p.evidence ->> 'status' = 'ok' and p.n_events >= 3
                      then round(p.raw_median::numeric, 1) else null end,
               'expired_or_lapsed_with_unused', p.expired_or_lapsed_with_unused,
               'repurchase_count', p.repurchase_count,
               'outside_spend_cents', p.outside_spend_cents,
               'evidence', p.evidence
             ) order by p.sold_count desc, p.plan_id), '[]'::jsonb)
        from plans p
    ),
    'observed_since', app.metric_observed_since_v1('ci_package_intelligence', p_business)
  ) into v_result;

  return v_result;
end;
$function$;
revoke all on function public.get_ci_package_intelligence_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_package_intelligence_v1(uuid,date,date,uuid)
  to authenticated, service_role;

commit;
