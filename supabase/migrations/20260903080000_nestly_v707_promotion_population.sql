-- NESTLY v707 -- Customer Intelligence, check 38 fix: promotion_dependency and value_association
-- must draw from the VISIT population, not the revenue population.
--
-- ------------------------------------------------------------------------------------------
-- THE DEFECT (found by a refuter with a scratch fixture, not invented): a tenant can set a
-- per-kind sale-policy override (db/migrations/20260717_frenly_v10_sale_policy.sql,
-- public.sale_policies / app.sale_policy_set()) so that a service's sales carry
-- counts_as_revenue=false, counts_as_visit=true -- a real, recorded, non-reversed visit that the
-- business has simply chosen not to book as revenue (e.g. a comped or bundled service kind).
-- public.get_ci_discount_dependency_v1 (v683) reads app.analytics_sale_class_v1(s).include_visit
-- (== counts_as_visit, not a reversal, no reversal exists against it) and classifies these visits
-- without trouble. public.get_ci_service_intelligence_v1's per-service promotion_dependency and
-- value_association (v697, check 38) instead drew their entire buyer population from `lines` --
-- the pre-existing revenue population, filtered on include_revenue -- so for a service sold ONLY
-- under such a policy, `lines` has zero rows for it, per_service never produces a row for it, and
-- the service is ABSENT from the output entirely: no buyers, no promotion_dependency, no
-- value_association, even though six real customers visited and one of them got a discount. The
-- two readers disagreed on identical sales because they drew from two different populations.
--
-- THE FIX. `visit_lines` is a new CTE, identical in shape to `lines` but filtered on
-- sc.include_visit instead of sc.include_revenue -- exactly v683's own predicate (include_visit,
-- not reversed, non-synthetic client), reused rather than reinvented. `all_service_ids` is the
-- union of both populations' service ids. service_promo_agg (promotion_dependency's source),
-- window_sales and service_buyer_ids (value_association's source) now all draw from visit_lines /
-- all_service_ids; per_service, buyer_revenue, svc_dist, repeat_counts, gateway_counts and
-- median_days -- the pre-existing REVENUE figures (buyers/orders/revenue_cents/distribution/
-- repeat_rate/median_days_to_next_purchase) -- are untouched and keep reading `lines`
-- (include_revenue), per this check's own owner ruling: "promotion_dependency and
-- value_association must draw from the VISIT population ... while the service's revenue figures
-- keep the revenue population." services_agg now LEFT JOINs per_service (rather than driving off
-- it), so a visit-only service reports its revenue fields as null while promotion_dependency and
-- value_association are populated -- and, symmetrically, a service sold only under a policy with
-- counts_as_visit=false would report real revenue figures with promotion_dependency/
-- value_association floor-gated at n=0 (evidence.status='insufficient'). Each service row gains
-- 'population_basis' stating which GUC-free policy flag backs which half of the row, so a reader
-- of the JSON is never left guessing why a null sits next to a populated sibling. Floor-gating for
-- promotion_dependency moves from ps.buyers (revenue buyer count) to spa.visit_buyers (visit buyer
-- count, from service_promo_agg) -- the two can now differ. The truncation ORDER BY gains
-- `nulls last` on revenue_cents so a visit-only (null-revenue) service never outranks a real
-- revenue earner in the top-v_limit slice.
--
-- Base captured and verified below via pg_get_functiondef against the LIVE body -- v697's own
-- re-emit (db/migrations/20260902_nestly_v697_service_promotion_dependency.sql) is the last
-- migration to touch this function; v698 onward only ever call it (grepped), never re-emit it.
-- Four anchors, extract-and-diff, roundtrip-verified (see v668/v690/v695/v697 for the pattern).
-- Byte-additive plus one population swap and one ORDER BY tweak -- no other reader of this
-- function's JSON is touched; an added key never breaks a path read, and a value going from a
-- number to null under a floor/absence is already the documented behaviour of every other
-- floor-gated field this reader emits.
--
-- Proof: db/tests/executed/v707_corpus_promotion_population.sql.

begin;

do $v707_patch_svc_intel$
declare
  v_def text;

  -- Anchor 1: splice visit_lines + all_service_ids in right after `lines`, before
  -- first_ever_sale (both untouched by v697; still verbatim from v691).
  v_anchor_1 constant text := $v707a1$  ),
  first_ever_sale as (
$v707a1$;

  v_new_1 constant text := $v707n1$  ),
  -- v707 (check 38 fix, refuter-proven): a tenant policy can set counts_as_revenue=false and
  -- counts_as_visit=true for a sale kind (db/migrations/20260717_frenly_v10_sale_policy.sql).
  -- v697's promotion_dependency and value_association drew their buyer population from `lines`
  -- (include_revenue), so a service sold only under such a policy showed zero buyers and no
  -- promotion/value data at all -- while public.get_ci_discount_dependency_v1 (v683), which reads
  -- include_visit, classified the exact same real visits without trouble. Fixed by giving
  -- promotion_dependency and value_association their OWN population, drawn from include_visit
  -- (== v683's own predicate: counts_as_visit, not reversed, non-synthetic client), independent of
  -- `lines`. `all_service_ids` is the union of both populations' service ids, so a service can now
  -- appear in the array with its revenue fields (buyers/orders/revenue_cents/distribution/
  -- repeat_rate/median_days_to_next_purchase -- still `lines`, include_revenue, unchanged) null
  -- when it never earns revenue, while promotion_dependency and value_association (now visit-
  -- population, floor-gated on that population's OWN buyer count, not the revenue buyer count)
  -- are populated -- or the reverse, null promotion/value fields with real revenue figures, for a
  -- service sold only under a policy with counts_as_visit=false.
  visit_lines as (
    select si.sale_id, si.ref_id as service_id, si.line_cents, s.client_id, s.occurred_at
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
      cross join lateral app.analytics_sale_class_v1(s) sc
     where si.business_id = p_business
       and si.item_type = 'service'
       and si.ref_id is not null
       and (p_branch is null or s.branch_id = p_branch)
       and s.created_at <= p_as_of
       and sc.include_visit
       and not sc.is_synthetic_client
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  all_service_ids as (
    select service_id from lines
    union
    select service_id from visit_lines
  ),
  first_ever_sale as (
$v707n1$;

  -- Anchor 2: service_promo_agg / window_sales / service_buyer_ids / value_pop /
  -- value_association_calc -- v697's whole promotion+value block, moved off `lines`/`per_service`
  -- onto `visit_lines`/`all_service_ids`.
  v_anchor_2 constant text := $v707a2$  -- v697 (check 38a): per-service discount signal, reusing v683's own notion of a discount line
  -- (public.sale_items row, item_type='studio_discount', line_cents < 0) on the same sale as a
  -- 'lines' row for this service. Floor-gating happens later against ps.buyers (services_agg).
  service_promo_agg as (
    select l.service_id,
           count(distinct l.sale_id) as all_sales,
           count(distinct l.sale_id) filter (where sd0.is_discounted) as discounted_sales,
           coalesce(sum(l.line_cents), 0) as all_revenue_cents,
           coalesce(sum(l.line_cents) filter (where sd0.is_discounted), 0) as discounted_revenue_cents
      from lines l
      cross join lateral (
        select exists (
          select 1 from public.sale_items d
           where d.sale_id = l.sale_id and d.item_type = 'studio_discount' and d.line_cents < 0
        ) as is_discounted
      ) sd0
     group by l.service_id
  ),
  -- v697 (check 38b): window_sales is every revenue-eligible, non-reversed, non-synthetic-
  -- client sale in the window for ANY item type (not restricted to this service's own line
  -- items) — value_association asks whether buying THIS service associates with a customer's
  -- OVERALL spend and repeat behaviour, not spend on the service alone.
  window_sales as (
    select s.id as sale_id, s.client_id,
           (select coalesce(sum(si2.line_cents), 0) from public.sale_items si2
             where si2.sale_id = s.id) as ticket_cents
      from public.sales s
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and s.created_at <= p_as_of
       and sc.include_revenue
       and not sc.is_synthetic_client
       and s.client_id is not null
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  service_buyer_ids as (
    select distinct service_id, client_id from lines
  ),
  value_pop as (
    select ps0.service_id, ws.sale_id, ws.client_id, ws.ticket_cents,
           exists (select 1 from service_buyer_ids sb
                    where sb.service_id = ps0.service_id and sb.client_id = ws.client_id) as is_buyer
      from (select distinct service_id from per_service) ps0
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
      from per_service ps
      left join value_buyer_side bv on bv.service_id = ps.service_id
      left join value_nonbuyer_side nv on nv.service_id = ps.service_id
      left join value_buyer_repeat br on br.service_id = ps.service_id
      left join value_nonbuyer_repeat nr on nr.service_id = ps.service_id
  ),
$v707a2$;

  v_new_2 constant text := $v707n2$  -- v697 (check 38a), v707-revised: per-service discount signal, reusing v683's own notion of a
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
$v707n2$;

  -- Anchor 3: services_agg -- drive off all_service_ids (LEFT JOIN per_service) instead of
  -- INNER-joining per_service; float promotion_dependency's floor gate onto spa.visit_buyers;
  -- add population_basis.
  v_anchor_3 constant text := $v707a3$  services_agg as (
    select ps.service_id, svc.name as service_name,
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
                       app.subgroup_evidence_v1(ps.buyers::int, v_floor)),
             'discounted_revenue_share', app.rate_block_floor_gated_v683(
                       coalesce(spa.discounted_revenue_cents,0)::bigint, coalesce(spa.all_revenue_cents,0)::bigint,
                       app.subgroup_evidence_v1(ps.buyers::int, v_floor)),
             'dependency_class', case when (app.subgroup_evidence_v1(ps.buyers::int, v_floor)->>'status') = 'ok'
               then case
                 when coalesce(spa.all_sales,0) = 0 then null
                 when (100.0 * spa.discounted_sales / spa.all_sales) < 20 then 'organic'
                 when (100.0 * spa.discounted_sales / spa.all_sales) >= 60 then 'dependent'
                 else 'mixed' end
               else null end,
             'evidence', app.subgroup_evidence_v1(ps.buyers::int, v_floor)
           ) as promotion_dependency,
           vac.value_association as value_association
      from per_service ps
      join public.services svc on svc.id = ps.service_id and svc.business_id = p_business
      left join repeat_counts rc on rc.service_id = ps.service_id
      left join gateway_counts gc on gc.service_id = ps.service_id
      left join median_days md on md.service_id = ps.service_id
      left join svc_dist sd on sd.service_id = ps.service_id
      left join service_promo_agg spa on spa.service_id = ps.service_id
      left join value_association_calc vac on vac.service_id = ps.service_id
  )
$v707a3$;

  v_new_3 constant text := $v707n3$  services_agg as (
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
$v707n3$;

  -- Anchor 4: nulls last on the truncation ORDER BY, so a visit-only (null revenue_cents)
  -- service never outranks a real revenue earner in a DESC sort (Postgres defaults to NULLS
  -- FIRST on DESC).
  v_anchor_4 constant text := $v707a4$               'promotion_dependency', x.promotion_dependency,
               'value_association', x.value_association
             ) order by x.revenue_cents desc, x.service_id), '[]'::jsonb)
        from (select * from services_agg order by revenue_cents desc, service_id limit v_limit) x
$v707a4$;

  v_new_4 constant text := $v707n4$               'promotion_dependency', x.promotion_dependency,
               'value_association', x.value_association
             ) order by x.revenue_cents desc nulls last, x.service_id), '[]'::jsonb)
        from (select * from services_agg order by revenue_cents desc nulls last, service_id limit v_limit) x
$v707n4$;

  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_service_intelligence_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v707: public.get_ci_service_intelligence_v1 not found';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_1, ''))) / length(v_anchor_1);
  if v_count <> 1 then
    raise exception 'v707: anchor 1 (visit_lines splice point) occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_2, ''))) / length(v_anchor_2);
  if v_count <> 1 then
    raise exception 'v707: anchor 2 (promotion/value CTE chain) occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_3, ''))) / length(v_anchor_3);
  if v_count <> 1 then
    raise exception 'v707: anchor 3 (services_agg) occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_4, ''))) / length(v_anchor_4);
  if v_count <> 1 then
    raise exception 'v707: anchor 4 (order-by tail) occurs % times (expected 1) — live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_1, v_new_1);
  v_expected := replace(v_expected, v_anchor_2, v_new_2);
  v_expected := replace(v_expected, v_anchor_3, v_new_3);
  v_expected := replace(v_expected, v_anchor_4, v_new_4);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_service_intelligence_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, v_new_1, v_anchor_1);
  v_roundtrip := replace(v_roundtrip, v_new_2, v_anchor_2);
  v_roundtrip := replace(v_roundtrip, v_new_3, v_anchor_3);
  v_roundtrip := replace(v_roundtrip, v_new_4, v_anchor_4);
  if v_roundtrip <> v_def then
    raise exception
      'v707: get_ci_service_intelligence_v1 changed by more than the four intended splices. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$v707_patch_svc_intel$;

-- ACL restated verbatim from the live proacl (unchanged by this migration — same argument list).
revoke all on function public.get_ci_service_intelligence_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_service_intelligence_v1(uuid,date,date,uuid,timestamptz)
  to authenticated, service_role;

commit;
