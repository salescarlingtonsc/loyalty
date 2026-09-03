-- NESTLY v710 -- checks 4 and 38: promotion_dependency.rate and value_association on
-- public.get_ci_service_intelligence_v1 counted raw SALE rows, not visit-days, so a same-day
-- split bill (several tickets, one afternoon) was double- (or triple-) counted.
--
-- Contract: docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md (v672, frozen). Fixture guide:
-- docs/qa/CI-CORPUS-FIXTURE-GUIDE.md. Proven by
-- db/tests/executed/v710_corpus_service_visit_units.sql.
--
-- ============================================================================================
-- THE DEFECT (found by a refuter with a scratch fixture, not invented). nestly_v699 established
-- one visit-day authority, app.ci_visit_day_v699(timestamptz) returns date -- a visit is one
-- distinct Asia/Singapore calendar day with a qualifying sale for a given customer; a split bill
-- (several sale rows, one afternoon) counts once -- and generalised it into
-- get_ci_category_customers_v1, get_ci_staff_performance_v1, get_ci_discount_dependency_v1 and
-- app.v179_business_insights. nestly_v707 (this same reader, get_ci_service_intelligence_v1) gave
-- promotion_dependency and value_association their own VISIT population (visit_lines,
-- include_visit) instead of the revenue population, but never applied the v699 visit-DAY
-- collapse on top of it -- both still counted raw sale rows:
--
--   1. promotion_dependency.rate (service_promo_agg, nestly_v697/v707): all_sales/discounted_sales
--      were count(distinct sale_id) / count(distinct sale_id) filter (where discounted) -- a
--      client with a discounted sale AND a full-price sale on the SAME day reads as 2 sales (one
--      of them discounted), inflating the rate relative to the true 1-visit-in-N picture. Refuter
--      scenario: 5 single-sale full-price buyers + 1 buyer with a same-day discounted+full pair
--      -> the buggy reader counts 7 sales (1 discounted of 7 = 14.3%); the correct visit-day count
--      is 6 visits (1 discounted of 6 = 16.7%) -- and get_ci_discount_dependency_v1 (v683/v699),
--      which already counts visit-DAYS for the exact same 6 real customers, is the independent
--      cross-check that the correct denominator is 6, not 7.
--
--   2. value_association (window_sales, nestly_v697/v707): one row per SALE, so (a) a same-day
--      split bill inflated median_ticket's sample -- 5 single-sale customers + 1 same-day pair
--      read as 7 tickets from 6 customers, one ticket artificially separate from its sibling
--      instead of summed into that day's true ticket; and (b) value_client_side's n_sales (used
--      for the >=2 threshold behind repeat_visit_rate) could mark a customer "repeat" purely
--      because they split ONE visit into two payments, not because they returned on a second day.
--
-- Both defects are check-4-shaped: the exact class of bug nestly_v699 closed everywhere else
-- "visits" are counted, left open here because nestly_v707 gave this reader its own VISIT
-- population without also applying the visit-DAY collapse on top of it.
--
-- ============================================================================================
-- THE FIX. Unit of count = (client_id, app.ci_visit_day_v699(occurred_at)) everywhere in the
-- promotion and association blocks, matching get_ci_discount_dependency_v1's (v683/v699) own
-- "a day is discounted if any qualifying sale that day carried the discount line" rule:
--
--   (a) service_promo_agg splits into service_promo_rows (row-level, visit_lines +
--       per-row is_discounted, unchanged from v707) feeding TWO aggregations: service_promo_agg
--       itself now only carries visit_buyers/all_revenue_cents/discounted_revenue_cents (revenue
--       stays counted per sale -- discounted_revenue_share is UNCHANGED IN MEANING, per this
--       check's own scope: only the rate's counting unit moves, not the revenue figures) and a
--       new service_promo_days_agg (grouped by service_id, client_id, visit_day first, bool_or
--       over is_discounted for "day_discounted", then aggregated to service_id) supplies
--       all_visit_days/discounted_visit_days -- promotion_dependency.rate and dependency_class
--       now read from service_promo_days_agg instead of service_promo_agg's old all_sales/
--       discounted_sales. Floor-gating is unchanged (spa.visit_buyers, not touched by this fix).
--
--   (b) window_sales is now pre-aggregated to one row per (client_id, visit_day); ticket_cents is
--       the SUM of that day's qualifying sales -- the day's true ticket -- rather than one row per
--       sale. value_pop, value_client_side (n_visits, was n_sales), value_buyer_side/
--       value_nonbuyer_side and value_buyer_repeat/value_nonbuyer_repeat are otherwise unchanged
--       in shape; their input is simply now one row per visit-day instead of one row per sale, so
--       median_ticket sums a split bill into one observation and repeat_visit_rate counts a
--       second PAYMENT on the same day as zero additional visits.
--
--   (c) A new top-level 'visit_definition' key (same convention as every other v699-registry
--       reader) states the rule inline next to the pre-existing 'basis_note', so a reader of the
--       JSON is never left to infer it: revenue-shaped fields (buyers/orders/revenue_cents/
--       repeat_rate/gateway_count/median_days_to_next_purchase/discounted_revenue_share) remain
--       per-sale; promotion_dependency.rate and value_association are per-visit-day.
--
-- Deliberately NOT touched: app.ci_visit_registry_v699 -- nestly_v709 is concurrently re-emitting
-- that registry in this same build wave (adding its own two entries), and re-emitting the same
-- function from two migrations in flight risks exactly the anchor-drift this whole extract-and-
-- diff discipline exists to prevent. REGISTRY ENTRY OWED, not yet recorded: a future migration
-- must add 'get_ci_service_intelligence_v1 (promotion_dependency/value_association)' ->
-- uses_authority=true to app.ci_visit_registry_v699, once it is safe to re-emit that function
-- again without colliding with v709's own edit. This migration's fixture asserts its OWN
-- 'visit_definition' key on the reader's payload directly (not the registry) as the proof that
-- does not depend on that future edit.
--
-- Existing fixtures for this function (v697/v707/v691/v675) stay green: their fixtures give every
-- client exactly one sale each (no same-day pairs), so the visit-day collapse this migration adds
-- is a no-op for every one of them and their truth tables hold exactly as written -- re-run as
-- part of this migration's own fixture file (not edited).
--
-- Base captured and verified below via pg_get_functiondef against the LIVE body -- v707's own
-- re-emit (db/migrations/20260920_nestly_v707_promotion_population.sql, committed c003c36c) is
-- the last migration to touch this function; v691/v693/v695/v697/v698/v700/v702/v703/v707 are
-- listed in this file's own history for the reader who greps for the function name, but only
-- v697 and v707 re-emit its BODY -- confirmed by grep across every later migration file, which
-- finds only CALLS to this function, never a redefinition, since v707 landed. Three anchors,
-- extract-and-diff, roundtrip-verified (see v668/v690/v695/v697/v707 for the pattern).
--
-- Proof: db/tests/executed/v710_corpus_service_visit_units.sql.

begin;

do $v710_patch_svc_intel$
declare
  v_def text;

  v_anchor_2 constant text := $v710a2$  -- v697 (check 38a), v707-revised: per-service discount signal, reusing v683's own notion of a
  -- discount line (public.sale_items row, item_type='studio_discount', line_cents < 0) on the
  -- same sale as a 'visit_lines' row for this service -- v707 moved the source from `lines`
  -- (include_revenue) to `visit_lines` (include_visit) so a service sold only under a policy with
  -- counts_as_revenue=false still reports a promotion signal. Floor-gating happens later against
  -- spa.visit_buyers (services_agg), NOT ps.buyers -- the two can now differ.
  service_promo_agg as (
    select l.service_id,
           count(distinct l.client_id) as visit_buyers,
           count(distinct l.sale_id) as all_sales,
           count(distinct l.sale_id) filter (where sd0.is_discounted) as discounted_sales,
           coalesce(sum(l.line_cents), 0) as all_revenue_cents,
           coalesce(sum(l.line_cents) filter (where sd0.is_discounted), 0) as discounted_revenue_cents
      from visit_lines l
      cross join lateral (
        select exists (
          select 1 from public.sale_items d
           where d.sale_id = l.sale_id and d.item_type = 'studio_discount' and d.line_cents < 0
        ) as is_discounted
      ) sd0
     group by l.service_id
  ),
  -- v697 (check 38b), v707-revised: window_sales is every VISIT-eligible (include_visit), non-
  -- reversed, non-synthetic-client sale in the window for ANY item type (not restricted to this
  -- service's own line items) — value_association asks whether buying THIS service associates
  -- with a customer's OVERALL spend and repeat behaviour, not spend on the service alone. v707
  -- moved this from include_revenue to include_visit for the same reason as service_promo_agg: a
  -- service can be visit-eligible without ever being revenue-eligible.
  window_sales as (
    select s.id as sale_id, s.client_id,
           (select coalesce(sum(si2.line_cents), 0) from public.sale_items si2
             where si2.sale_id = s.id) as ticket_cents
      from public.sales s
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and s.created_at <= p_as_of
       and sc.include_visit
       and not sc.is_synthetic_client
       and s.client_id is not null
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  service_buyer_ids as (
    select distinct service_id, client_id from visit_lines
  ),
  value_pop as (
    select ps0.service_id, ws.sale_id, ws.client_id, ws.ticket_cents,
           exists (select 1 from service_buyer_ids sb
                    where sb.service_id = ps0.service_id and sb.client_id = ws.client_id) as is_buyer
      from (select distinct service_id from all_service_ids) ps0
      cross join window_sales ws
  ),
  value_client_side as (
    select service_id, is_buyer, client_id, count(*) as n_sales
      from value_pop group by service_id, is_buyer, client_id
  ),
  value_buyer_side as (
    select service_id, app.distribution_block_v1(array_agg(ticket_cents::numeric)) as dist
      from value_pop where is_buyer group by service_id
  ),
  value_nonbuyer_side as (
    select service_id, app.distribution_block_v1(array_agg(ticket_cents::numeric)) as dist
      from value_pop where not is_buyer group by service_id
  ),
  value_buyer_repeat as (
    select service_id, count(*) as n_customers,
           count(*) filter (where n_sales >= 2) as repeat_customers
      from value_client_side where is_buyer group by service_id
  ),
  value_nonbuyer_repeat as (
    select service_id, count(*) as n_customers,
           count(*) filter (where n_sales >= 2) as repeat_customers
      from value_client_side where not is_buyer group by service_id
  ),
  value_association_calc as (
    select ps.service_id,
      jsonb_build_object(
        'evidence_class', 'ASSOCIATION',
        'buyers', jsonb_build_object(
          'evidence', app.subgroup_evidence_v1(coalesce(br.n_customers,0)::int, v_floor),
          'median_ticket', case when (app.subgroup_evidence_v1(coalesce(br.n_customers,0)::int, v_floor)->>'status') = 'ok'
                             then bv.dist
                             else jsonb_build_object('n', coalesce(br.n_customers,0), 'status', 'insufficient') end,
          'repeat_visit_rate', app.rate_block_floor_gated_v683(
                                  coalesce(br.repeat_customers,0)::bigint, coalesce(br.n_customers,0)::bigint,
                                  app.subgroup_evidence_v1(coalesce(br.n_customers,0)::int, v_floor))
        ),
        'non_buyers', jsonb_build_object(
          'evidence', app.subgroup_evidence_v1(coalesce(nr.n_customers,0)::int, v_floor),
          'median_ticket', case when (app.subgroup_evidence_v1(coalesce(nr.n_customers,0)::int, v_floor)->>'status') = 'ok'
                             then nv.dist
                             else jsonb_build_object('n', coalesce(nr.n_customers,0), 'status', 'insufficient') end,
          'repeat_visit_rate', app.rate_block_floor_gated_v683(
                                  coalesce(nr.repeat_customers,0)::bigint, coalesce(nr.n_customers,0)::bigint,
                                  app.subgroup_evidence_v1(coalesce(nr.n_customers,0)::int, v_floor))
        ),
        'difference_note', case
          when (app.subgroup_evidence_v1(coalesce(br.n_customers,0)::int, v_floor)->>'status') = 'ok'
           and (app.subgroup_evidence_v1(coalesce(nr.n_customers,0)::int, v_floor)->>'status') = 'ok'
          then format(
                 'Customers who bought this service in the window had a median ticket of %s '
                 'cents vs %s cents for customers who did not, and a %s%% vs %s%% repeat-visit '
                 'rate -- an association observed in this window, not a causal effect of the '
                 'service.',
                 round((bv.dist->>'median')::numeric, 0), round((nv.dist->>'median')::numeric, 0),
                 coalesce((app.rate_block_v1(br.repeat_customers, br.n_customers)->>'pct')::text, 'n/a'),
                 coalesce((app.rate_block_v1(nr.repeat_customers, nr.n_customers)->>'pct')::text, 'n/a'))
          else 'insufficient sample on one or both sides to compare'
        end
      ) as value_association
      from all_service_ids ps
      left join value_buyer_side bv on bv.service_id = ps.service_id
      left join value_nonbuyer_side nv on nv.service_id = ps.service_id
      left join value_buyer_repeat br on br.service_id = ps.service_id
      left join value_nonbuyer_repeat nr on nr.service_id = ps.service_id
  ),
$v710a2$;

  v_new_2 constant text := $v710n2$  -- v697 (check 38a), v707-revised: per-service discount signal, reusing v683's own notion of a
  -- discount line (public.sale_items row, item_type='studio_discount', line_cents < 0) on the
  -- same sale as a 'visit_lines' row for this service -- v707 moved the source from `lines`
  -- (include_revenue) to `visit_lines` (include_visit) so a service sold only under a policy with
  -- counts_as_revenue=false still reports a promotion signal. Floor-gating happens later against
  -- spa.visit_buyers (services_agg), NOT ps.buyers -- the two can now differ.
  --
  -- v710 (checks 4/38 fix, refuter-proven): the RATE's unit of count moves from raw sale rows to
  -- (client, visit-day) pairs -- app.ci_visit_day_v699, the one visit-day authority (nestly_v699).
  -- A client with a discounted sale and a full-price sale on the SAME calendar day (a split bill)
  -- was counted as 2 sales (1 discounted of 2 -> a rate inflated relative to the true 1-visit-in-6
  -- picture), now counts as ONE visit-day, discounted iff ANY of that day's qualifying sales for
  -- this service carried the discount line (bool_or) -- the same "any sale that day" rule
  -- get_ci_discount_dependency_v1 (v683/v699) already applies to its own day_discounted.
  -- all_revenue_cents/discounted_revenue_cents (and therefore discounted_revenue_share) are
  -- UNCHANGED IN MEANING: revenue is still summed per sale line, not per visit-day -- only the
  -- RATE's counting unit moves, per this check's own scope.
  service_promo_rows as (
    select l.service_id, l.client_id, l.line_cents,
           app.ci_visit_day_v699(l.occurred_at) as visit_day,
           sd0.is_discounted
      from visit_lines l
      cross join lateral (
        select exists (
          select 1 from public.sale_items d
           where d.sale_id = l.sale_id and d.item_type = 'studio_discount' and d.line_cents < 0
        ) as is_discounted
      ) sd0
  ),
  service_promo_agg as (
    select service_id,
           count(distinct client_id) as visit_buyers,
           coalesce(sum(line_cents), 0) as all_revenue_cents,
           coalesce(sum(line_cents) filter (where is_discounted), 0) as discounted_revenue_cents
      from service_promo_rows
     group by service_id
  ),
  -- v710: one row per (service, client, visit-day) -- a day is discounted iff any of that
  -- day's qualifying sales for this service carried the discount line.
  service_promo_days as (
    select service_id, client_id, visit_day, bool_or(is_discounted) as day_discounted
      from service_promo_rows
     group by service_id, client_id, visit_day
  ),
  service_promo_days_agg as (
    select service_id,
           count(*) as all_visit_days,
           count(*) filter (where day_discounted) as discounted_visit_days
      from service_promo_days
     group by service_id
  ),
  -- v697 (check 38b), v707-revised: window_sales is every VISIT-eligible (include_visit), non-
  -- reversed, non-synthetic-client sale in the window for ANY item type (not restricted to this
  -- service's own line items) — value_association asks whether buying THIS service associates
  -- with a customer's OVERALL spend and repeat behaviour, not spend on the service alone. v707
  -- moved this from include_revenue to include_visit for the same reason as service_promo_agg: a
  -- service can be visit-eligible without ever being revenue-eligible.
  --
  -- v710 (check 4 fix, refuter-proven): window_sales' unit of count moves from raw sale rows to
  -- (client, visit-day) pairs. A same-day split bill was two separate "tickets" toward
  -- median_ticket (so a window with 6 customers could show 7 tickets, one customer's split visit
  -- double-counted) and two separate observations toward repeat_visit_rate (so one split-bill day
  -- could itself look like repeat behaviour). window_sales is now pre-aggregated to one row per
  -- (client, visit-day); ticket_cents is the SUM of that day's qualifying sales -- the day's true
  -- ticket, matching get_ci_discount_dependency_v1's (v683/v699) own visit-day grain.
  window_sales as (
    select s.client_id, app.ci_visit_day_v699(s.occurred_at) as visit_day,
           sum(coalesce((select sum(si2.line_cents) from public.sale_items si2
                          where si2.sale_id = s.id), 0)) as ticket_cents
      from public.sales s
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and s.created_at <= p_as_of
       and sc.include_visit
       and not sc.is_synthetic_client
       and s.client_id is not null
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
     group by s.client_id, app.ci_visit_day_v699(s.occurred_at)
  ),
  service_buyer_ids as (
    select distinct service_id, client_id from visit_lines
  ),
  value_pop as (
    select ps0.service_id, ws.client_id, ws.visit_day, ws.ticket_cents,
           exists (select 1 from service_buyer_ids sb
                    where sb.service_id = ps0.service_id and sb.client_id = ws.client_id) as is_buyer
      from (select distinct service_id from all_service_ids) ps0
      cross join window_sales ws
  ),
  -- v710: n_visits (was n_sales) now counts distinct visit-days per client, because window_sales
  -- is already one row per (client, visit-day) -- count(*) here is unchanged in form, only in the
  -- cardinality of its input.
  value_client_side as (
    select service_id, is_buyer, client_id, count(*) as n_visits
      from value_pop group by service_id, is_buyer, client_id
  ),
  value_buyer_side as (
    select service_id, app.distribution_block_v1(array_agg(ticket_cents::numeric)) as dist
      from value_pop where is_buyer group by service_id
  ),
  value_nonbuyer_side as (
    select service_id, app.distribution_block_v1(array_agg(ticket_cents::numeric)) as dist
      from value_pop where not is_buyer group by service_id
  ),
  value_buyer_repeat as (
    select service_id, count(*) as n_customers,
           count(*) filter (where n_visits >= 2) as repeat_customers
      from value_client_side where is_buyer group by service_id
  ),
  value_nonbuyer_repeat as (
    select service_id, count(*) as n_customers,
           count(*) filter (where n_visits >= 2) as repeat_customers
      from value_client_side where not is_buyer group by service_id
  ),
  value_association_calc as (
    select ps.service_id,
      jsonb_build_object(
        'evidence_class', 'ASSOCIATION',
        'buyers', jsonb_build_object(
          'evidence', app.subgroup_evidence_v1(coalesce(br.n_customers,0)::int, v_floor),
          'median_ticket', case when (app.subgroup_evidence_v1(coalesce(br.n_customers,0)::int, v_floor)->>'status') = 'ok'
                             then bv.dist
                             else jsonb_build_object('n', coalesce(br.n_customers,0), 'status', 'insufficient') end,
          'repeat_visit_rate', app.rate_block_floor_gated_v683(
                                  coalesce(br.repeat_customers,0)::bigint, coalesce(br.n_customers,0)::bigint,
                                  app.subgroup_evidence_v1(coalesce(br.n_customers,0)::int, v_floor))
        ),
        'non_buyers', jsonb_build_object(
          'evidence', app.subgroup_evidence_v1(coalesce(nr.n_customers,0)::int, v_floor),
          'median_ticket', case when (app.subgroup_evidence_v1(coalesce(nr.n_customers,0)::int, v_floor)->>'status') = 'ok'
                             then nv.dist
                             else jsonb_build_object('n', coalesce(nr.n_customers,0), 'status', 'insufficient') end,
          'repeat_visit_rate', app.rate_block_floor_gated_v683(
                                  coalesce(nr.repeat_customers,0)::bigint, coalesce(nr.n_customers,0)::bigint,
                                  app.subgroup_evidence_v1(coalesce(nr.n_customers,0)::int, v_floor))
        ),
        'difference_note', case
          when (app.subgroup_evidence_v1(coalesce(br.n_customers,0)::int, v_floor)->>'status') = 'ok'
           and (app.subgroup_evidence_v1(coalesce(nr.n_customers,0)::int, v_floor)->>'status') = 'ok'
          then format(
                 'Customers who bought this service in the window had a median ticket of %s '
                 'cents vs %s cents for customers who did not, and a %s%% vs %s%% repeat-visit '
                 'rate -- an association observed in this window, not a causal effect of the '
                 'service.',
                 round((bv.dist->>'median')::numeric, 0), round((nv.dist->>'median')::numeric, 0),
                 coalesce((app.rate_block_v1(br.repeat_customers, br.n_customers)->>'pct')::text, 'n/a'),
                 coalesce((app.rate_block_v1(nr.repeat_customers, nr.n_customers)->>'pct')::text, 'n/a'))
          else 'insufficient sample on one or both sides to compare'
        end
      ) as value_association
      from all_service_ids ps
      left join value_buyer_side bv on bv.service_id = ps.service_id
      left join value_nonbuyer_side nv on nv.service_id = ps.service_id
      left join value_buyer_repeat br on br.service_id = ps.service_id
      left join value_nonbuyer_repeat nr on nr.service_id = ps.service_id
  ),
$v710n2$;

  v_anchor_3 constant text := $v710a3$  services_agg as (
    select asi.service_id, svc.name as service_name,
           ps.buyers, ps.orders, ps.revenue_cents,
           coalesce(rc.repeat_buyers, 0) as repeat_buyers,
           coalesce(gc.gateway_count, 0) as gateway_count,
           coalesce(md.n_obs, 0) as median_n_obs,
           md.raw_median,
           app.subgroup_evidence_v1(ps.buyers::int, v_floor) as evidence,
           sd.dist as distribution,
           jsonb_build_object(
             'rate', app.rate_block_floor_gated_v683(
                       coalesce(spa.discounted_sales,0)::bigint, coalesce(spa.all_sales,0)::bigint,
                       app.subgroup_evidence_v1(coalesce(spa.visit_buyers,0)::int, v_floor)),
             'discounted_revenue_share', app.rate_block_floor_gated_v683(
                       coalesce(spa.discounted_revenue_cents,0)::bigint, coalesce(spa.all_revenue_cents,0)::bigint,
                       app.subgroup_evidence_v1(coalesce(spa.visit_buyers,0)::int, v_floor)),
             'dependency_class', case when (app.subgroup_evidence_v1(coalesce(spa.visit_buyers,0)::int, v_floor)->>'status') = 'ok'
               then case
                 when coalesce(spa.all_sales,0) = 0 then null
                 when (100.0 * spa.discounted_sales / spa.all_sales) < 20 then 'organic'
                 when (100.0 * spa.discounted_sales / spa.all_sales) >= 60 then 'dependent'
                 else 'mixed' end
               else null end,
             'evidence', app.subgroup_evidence_v1(coalesce(spa.visit_buyers,0)::int, v_floor),
             'population_basis', jsonb_build_object('revenue_fields', 'counts_as_revenue',
                                                     'promotion_and_association', 'counts_as_visit')
           ) as promotion_dependency,
           vac.value_association as value_association
      from all_service_ids asi
      join public.services svc on svc.id = asi.service_id and svc.business_id = p_business
      left join per_service ps on ps.service_id = asi.service_id
      left join repeat_counts rc on rc.service_id = asi.service_id
      left join gateway_counts gc on gc.service_id = asi.service_id
      left join median_days md on md.service_id = asi.service_id
      left join svc_dist sd on sd.service_id = asi.service_id
      left join service_promo_agg spa on spa.service_id = asi.service_id
      left join value_association_calc vac on vac.service_id = asi.service_id
  )
$v710a3$;

  v_new_3 constant text := $v710n3$  services_agg as (
    select asi.service_id, svc.name as service_name,
           ps.buyers, ps.orders, ps.revenue_cents,
           coalesce(rc.repeat_buyers, 0) as repeat_buyers,
           coalesce(gc.gateway_count, 0) as gateway_count,
           coalesce(md.n_obs, 0) as median_n_obs,
           md.raw_median,
           app.subgroup_evidence_v1(ps.buyers::int, v_floor) as evidence,
           sd.dist as distribution,
           jsonb_build_object(
             'rate', app.rate_block_floor_gated_v683(
                       coalesce(spda.discounted_visit_days,0)::bigint, coalesce(spda.all_visit_days,0)::bigint,
                       app.subgroup_evidence_v1(coalesce(spa.visit_buyers,0)::int, v_floor)),
             'discounted_revenue_share', app.rate_block_floor_gated_v683(
                       coalesce(spa.discounted_revenue_cents,0)::bigint, coalesce(spa.all_revenue_cents,0)::bigint,
                       app.subgroup_evidence_v1(coalesce(spa.visit_buyers,0)::int, v_floor)),
             'dependency_class', case when (app.subgroup_evidence_v1(coalesce(spa.visit_buyers,0)::int, v_floor)->>'status') = 'ok'
               then case
                 when coalesce(spda.all_visit_days,0) = 0 then null
                 when (100.0 * spda.discounted_visit_days / spda.all_visit_days) < 20 then 'organic'
                 when (100.0 * spda.discounted_visit_days / spda.all_visit_days) >= 60 then 'dependent'
                 else 'mixed' end
               else null end,
             'evidence', app.subgroup_evidence_v1(coalesce(spa.visit_buyers,0)::int, v_floor),
             'population_basis', jsonb_build_object('revenue_fields', 'counts_as_revenue',
                                                     'promotion_and_association', 'counts_as_visit')
           ) as promotion_dependency,
           vac.value_association as value_association
      from all_service_ids asi
      join public.services svc on svc.id = asi.service_id and svc.business_id = p_business
      left join per_service ps on ps.service_id = asi.service_id
      left join repeat_counts rc on rc.service_id = asi.service_id
      left join gateway_counts gc on gc.service_id = asi.service_id
      left join median_days md on md.service_id = asi.service_id
      left join svc_dist sd on sd.service_id = asi.service_id
      left join service_promo_agg spa on spa.service_id = asi.service_id
      left join service_promo_days_agg spda on spda.service_id = asi.service_id
      left join value_association_calc vac on vac.service_id = asi.service_id
  )
$v710n3$;

  v_anchor_c constant text := $v710ac$    'basis_note', 'Buyers/orders/revenue are window+branch scoped; gateway status and the next-'
      'purchase gap look at each client''s full lifetime history with this business, not just '
      'this window (see the migration header, judgement call 3).',
$v710ac$;

  v_new_c constant text := $v710nc$    'basis_note', 'Buyers/orders/revenue are window+branch scoped; gateway status and the next-'
      'purchase gap look at each client''s full lifetime history with this business, not just '
      'this window (see the migration header, judgement call 3).',
    'visit_definition',
      'promotion_dependency.rate and value_association (buyers/non_buyers median_ticket and '
      'repeat_visit_rate) count distinct (client, visit-day) pairs -- one Asia/Singapore '
      'calendar day per client (app.ci_visit_day_v699, nestly_v699); a same-day split bill is '
      'one visit, not one per ticket. buyers/orders/revenue_cents/repeat_rate/gateway_count/'
      'median_days_to_next_purchase are unchanged: still counted per sale (nestly_v710, checks '
      '4/38).',
$v710nc$;

  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_service_intelligence_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v710: public.get_ci_service_intelligence_v1 not found';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_2, ''))) / length(v_anchor_2);
  if v_count <> 1 then
    raise exception 'v710: anchor 2 (promotion/value CTE chain) occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_3, ''))) / length(v_anchor_3);
  if v_count <> 1 then
    raise exception 'v710: anchor 3 (services_agg) occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_c, ''))) / length(v_anchor_c);
  if v_count <> 1 then
    raise exception 'v710: anchor c (basis_note splice point) occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_2, v_new_2);
  v_expected := replace(v_expected, v_anchor_3, v_new_3);
  v_expected := replace(v_expected, v_anchor_c, v_new_c);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_service_intelligence_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, v_new_2, v_anchor_2);
  v_roundtrip := replace(v_roundtrip, v_new_3, v_anchor_3);
  v_roundtrip := replace(v_roundtrip, v_new_c, v_anchor_c);
  if v_roundtrip <> v_def then
    raise exception
      'v710: get_ci_service_intelligence_v1 changed by more than the three intended splices. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;

  if position('service_promo_days_agg' in v_after) = 0 then
    raise exception 'v710: service_promo_days_agg (visit-day promotion aggregation) did not land';
  end if;
  if position('n_visits' in v_after) = 0 then
    raise exception 'v710: value_client_side visit-day rename (n_visits) did not land';
  end if;
end
$v710_patch_svc_intel$;

-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_ci_service_intelligence_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_service_intelligence_v1(uuid,date,date,uuid,timestamptz)
  to authenticated, service_role;

commit;
