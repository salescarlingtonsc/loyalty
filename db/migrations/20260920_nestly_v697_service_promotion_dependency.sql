-- NESTLY v697 — Customer Intelligence, check 38: per-service promotion dependency and value
-- association.
--
-- public.get_ci_service_intelligence_v1's 'services' array (v675/v680/v691) gains two additive
-- keys per service, byte-additive only (docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md,
-- docs/qa/CI-CORPUS-FIXTURE-GUIDE.md). Base captured and verified below via pg_get_functiondef
-- against the LIVE body as emitted by db/migrations/20260920_nestly_v691_outliers_and_confounders.sql
-- (v691 is the last migration to touch this function — grepped; v692/v693/v694/v695/v696 only
-- ever CALL it, never re-emit it), extract-and-diff, roundtrip-verified (see v668/v690/v695 for
-- the pattern). Neither public.get_ci_opportunities_v1 (v678/v680/v696, a sibling in flight) nor
-- any other reader is touched by this migration — they consume this reader by JSON path access,
-- and an added key never breaks a path read.
--
-- ------------------------------------------------------------------------------------------
-- 38a · promotion_dependency. Reuses v683's own notion of a discount signal on a sale — a
-- public.sale_items row with item_type='studio_discount' and a negative line_cents, whichever
-- of v657's two shapes it takes and whichever engine applied it (public.get_ci_discount_
-- dependency_v1, v683) — found by grep, not invented. Also reuses v683's own two cut points:
-- < 20% discounted = 'organic', >= 60% discounted = 'dependent' (v683 calls it
-- 'discount_dependent'; this check's own three-value vocabulary is 'organic'|'mixed'|'dependent'
-- per the acceptance brief, so the label differs, the cut points do not — see v683's own
-- `classified` CTE, get_ci_discount_dependency_v1). v683 classifies a CUSTOMER by their own
-- visit mix over the whole window; this reader classifies a SERVICE by the discount mix of the
-- sales (orders) that carry it — a different unit of analysis, the identical two thresholds, so
-- no direct row-for-row equality assertion against v683's own output is meaningful (v683 never
-- emits a per-service number); the executed fixture instead recomputes the same two thresholds
-- against the same raw counts inline and asserts exact agreement, so both readers are proven to
-- share one classification boundary rather than two independently-typed ones.
-- 'rate' = app.rate_block_v1(discounted_sales, all_sales); 'discounted_revenue_share' =
-- app.rate_block_v1(discounted_revenue_cents, all_revenue_cents) — both floor-gated (via
-- app.rate_block_floor_gated_v683, v683 — pct null, counts kept) on this service's own distinct
-- buyers (the SAME floor and SAME evidence object the rest of this reader already computes for
-- 'evidence'/'repeat_rate'/'median_days_to_next_purchase'). 'dependency_class' is null below
-- that same floor.
--
-- 38b · value_association. Compares customers who bought this service in the window against
-- customers who did not, on two axes: median per-visit "ticket" (the WHOLE sale's total, any
-- item type — not just revenue from this service, since the question is whether buying this
-- service associates with higher overall spend) via app.distribution_block_v1, and repeat-visit
-- rate (>= 2 window sales, any item type) via app.rate_block_v1. Both sides floor-gated
-- independently (app.subgroup_evidence_v1 on each side's own distinct customer count) — a
-- service with few buyers reports its buyer side as insufficient even when the non-buyer side
-- (essentially the rest of the customer base) clears the floor easily, and vice versa in
-- principle. 'evidence_class' is always 'ASSOCIATION', never 'CAUSAL' — a 'difference_note'
-- states the comparison in observational language and explicitly disclaims causation.
--
-- Proof: db/tests/executed/v697_corpus_service_promotion.sql.

begin;

do $v697_patch_svc_intel$
declare
  v_def text;

  v_anchor_a constant text := $v697aA$  svc_dist as (
    select service_id, app.distribution_block_v1(array_agg(rev)) as dist
      from buyer_revenue
     group by service_id
  ),
$v697aA$;

  v_new_a constant text := $v697nA$  svc_dist as (
    select service_id, app.distribution_block_v1(array_agg(rev)) as dist
      from buyer_revenue
     group by service_id
  ),
  -- v697 (check 38a): per-service discount signal, reusing v683's own notion of a discount line
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
$v697nA$;

  v_anchor_b constant text := $v697aB$  services_agg as (
    select ps.service_id, svc.name as service_name,
           ps.buyers, ps.orders, ps.revenue_cents,
           coalesce(rc.repeat_buyers, 0) as repeat_buyers,
           coalesce(gc.gateway_count, 0) as gateway_count,
           coalesce(md.n_obs, 0) as median_n_obs,
           md.raw_median,
           app.subgroup_evidence_v1(ps.buyers::int, v_floor) as evidence,
           sd.dist as distribution
      from per_service ps
      join public.services svc on svc.id = ps.service_id and svc.business_id = p_business
      left join repeat_counts rc on rc.service_id = ps.service_id
      left join gateway_counts gc on gc.service_id = ps.service_id
      left join median_days md on md.service_id = ps.service_id
      left join svc_dist sd on sd.service_id = ps.service_id
  )
$v697aB$;

  v_new_b constant text := $v697nB$  services_agg as (
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
$v697nB$;

  v_anchor_c constant text := $v697aC$               'evidence', x.evidence,
               'distribution', x.distribution,
               'skew_note', case when coalesce((x.distribution->>'skew_material')::boolean, false)
                 then format('top customer carries %s%% of this category; the mean overstates the typical customer',
                              round((x.distribution->>'top1_share_bps')::numeric / 100, 1))
                 else null end
             ) order by x.revenue_cents desc, x.service_id), '[]'::jsonb)
$v697aC$;

  v_new_c constant text := $v697nC$               'evidence', x.evidence,
               'distribution', x.distribution,
               'skew_note', case when coalesce((x.distribution->>'skew_material')::boolean, false)
                 then format('top customer carries %s%% of this category; the mean overstates the typical customer',
                              round((x.distribution->>'top1_share_bps')::numeric / 100, 1))
                 else null end,
               'promotion_dependency', x.promotion_dependency,
               'value_association', x.value_association
             ) order by x.revenue_cents desc, x.service_id), '[]'::jsonb)
$v697nC$;

  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_service_intelligence_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v697: public.get_ci_service_intelligence_v1 not found';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_a, ''))) / length(v_anchor_a);
  if v_count <> 1 then
    raise exception 'v697: svc_dist anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_b, ''))) / length(v_anchor_b);
  if v_count <> 1 then
    raise exception 'v697: services_agg anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_c, ''))) / length(v_anchor_c);
  if v_count <> 1 then
    raise exception 'v697: per-service jsonb_build_object anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_a, v_new_a);
  v_expected := replace(v_expected, v_anchor_b, v_new_b);
  v_expected := replace(v_expected, v_anchor_c, v_new_c);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_service_intelligence_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, v_new_a, v_anchor_a);
  v_roundtrip := replace(v_roundtrip, v_new_b, v_anchor_b);
  v_roundtrip := replace(v_roundtrip, v_new_c, v_anchor_c);
  if v_roundtrip <> v_def then
    raise exception
      'v697: get_ci_service_intelligence_v1 changed by more than the three intended splices. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$v697_patch_svc_intel$;

-- ACL restated verbatim from the live proacl (unchanged by this migration — same argument list).
revoke all on function public.get_ci_service_intelligence_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_service_intelligence_v1(uuid,date,date,uuid,timestamptz)
  to authenticated, service_role;

commit;
