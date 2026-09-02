-- NESTLY v695 — Phase CI-B/D: service and segment cadence, the fallback chain a business
-- actually needed underneath v651's two tiers (check 46), plus the customer-cadence and v179
-- typed-verdict halves that the sibling typed-verdicts migration (v693) deliberately left alone
-- (v693 covers funnel/retention/daypart/demographic_cohort + envelope counts; this migration is
-- app.customer_cadence_v1 and app.v179_business_insights).
--
-- Contract: docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md (v672, frozen). Fixture guide:
-- docs/qa/CI-CORPUS-FIXTURE-GUIDE.md. Live bases captured via a --keep cluster + psql before
-- writing this migration: db/migrations/20260920_nestly_v690_dispersion_and_one_floor.sql is
-- the last migration to touch app.customer_cadence_v1 and app.v179_business_insights, and
-- neither is touched again by v691/v692/v693/v694 (grepped), so the LIVE body captured after
-- v691 IS the anchor these patches are written against.
--
-- ============================================================================================
-- PART 1 — SERVICE AND SEGMENT CADENCE (check 46)
-- ============================================================================================
-- app.customer_cadence_v1's only fallback below the customer's own rhythm was, until now, a
-- single business-wide constant (customer_lifecycle_policies_v107.fallback_lapse_days) — the
-- same number whether a customer's one purchase was a $4 coffee or a $400 facial package. Two
-- new pooled-evidence authorities sit between the customer's own history and that constant:
--
--   app.service_cadence_v695(p_business, p_service_id, p_as_of) — the median inter-purchase
--     interval for ONE service, pooled across every customer who bought it 2+ times. Gated by
--     app.subgroup_evidence_v1 on DISTINCT CONTRIBUTING CUSTOMERS (never raw interval count,
--     so one chatty customer cannot manufacture "evidence" alone).
--   app.segment_cadence_v695(p_business, p_segment_kind, p_segment_key, p_as_of) — the same
--     idea one level coarser: 'category' (a level-2 taxonomy node via app.ci_effective_node_v650
--     + app.ci_effective_node_v650's taxonomy_nodes.parent_key rollup, the same rollup
--     app.get_ci_category_mix_v1 uses) or 'acquisition' (public.clients.first_acquired_via).
--
-- Both exclude reversed sales, non-visit sales and synthetic clients via app.analytics_sale_class_v1
-- (v628) — the same CI-layer exclusion authority app.get_ci_service_intelligence_v1 (v675) and
-- app.get_ci_category_mix_v1 (v650) already use — rather than re-deriving the exclusion rules
-- locally, per the CI-STAT-AUTHORITY-CONTRACT's exclusion convention (#3).
--
-- app.v695_sector_cadence_multiplier(p_business, p_as_of) reads the per-sector
-- cadence_multiplier straight off public.sector_policy_versions_v109 (industry -> sector_key,
-- 'other' fallback) the same way app.growth_v108_effective_parameters already does — WITHOUT
-- routing through public.get_effective_sector_policy_v109's feature-flag/view_finance gate,
-- because this is an internal SECURITY DEFINER cadence computation, not a finance-facing read.
-- v109 remains the only place a per-sector cadence multiplier is defined; this migration adds a
-- second internal reader of that same constant, not a new policy.
--
-- app.customer_cadence_v1 is re-emitted (anchored on the LIVE body, extract-and-diff, verified
-- byte-faithful except for the intended additions) so the fallback chain becomes:
--   customer_median_interval (the customer's own rhythm, k >= customer_interval_min_observations)
--     -> service_median (the customer's single most-purchased service's pooled cadence, when its
--        evidence clears the floor)
--     -> segment_median (the customer's single most-purchased category's pooled cadence, when
--        ITS evidence clears the floor)
--     -> business_fallback (customer_lifecycle_policies_v107.fallback_lapse_days, unchanged)
--     -> none (no paid visit at all, unchanged).
-- The customer_median_interval tier's keys and values are byte-identical to before this
-- migration (same computation, same branch) — only the ELSE arm gained two new attempts before
-- reaching the constant it already fell back to. Two additive keys travel with every 'ready'
-- answer: 'evidence_class' ('DIRECT_FACT' for the customer's own intervals, 'ASSOCIATION' for
-- every pooled or constant tier, with a 'note'), and 'fallback_evidence' (the pooled tier's own
-- n/floor from app.subgroup_evidence_v1 — present only for service_median/segment_median, since
-- business_fallback is a fixed policy constant, not a subgroup sample).
--
-- ============================================================================================
-- PART 2 — v179 TYPED VERDICTS, THE CADENCE-ADJACENT HALF (check 17)
-- ============================================================================================
-- app.v179_business_insights (re-emitted, extract-and-diff on the LIVE body) gains four additive
-- 'evidence_class' keys, vocabulary restricted to DIRECT_FACT | ASSOCIATION (CAUSAL never
-- appears anywhere in this migration): at_risk -> 'ASSOCIATION' (the 45-180 day absence window
-- is a fixed heuristic threshold, not a customer-specific prediction, hence a 'evidence_class_note'
-- travels with it); retention -> 'DIRECT_FACT' (every count and rate is a direct tally of this
-- period's own sales); weekday_pattern -> 'DIRECT_FACT' (a direct sum by day of week);
-- top_customers -> 'DIRECT_FACT' (each row is a direct per-customer revenue tally). Every
-- existing key and value is untouched.

begin;

-- ---------------------------------------------------------------------------
-- 1. app.service_cadence_v695 — pooled median inter-purchase interval for ONE service.
-- ---------------------------------------------------------------------------
create or replace function app.service_cadence_v695(
  p_business uuid, p_service_id uuid, p_as_of timestamptz default now()
) returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  with purchases as materialized (
    select distinct
           app.v111_effective_client_id(s.business_id, s.client_id) as client_id,
           s.id as sale_id, s.occurred_at
      from public.sales s
      join public.sale_items si
        on si.sale_id = s.id and si.business_id = s.business_id
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and s.client_id is not null
       and s.created_at <= p_as_of
       and sc.include_visit
       and not sc.is_synthetic_client
       and si.item_type = 'service'
       and si.ref_id = p_service_id
  ), qualifying_clients as (
    -- "bought that service >= 2 times" -- a single purchase contributes no interval and no
    -- evidence; only customers who repeated it are counted as contributing.
    select client_id from purchases group by client_id having count(*) >= 2
  ), sequenced as (
    select p.client_id, p.occurred_at,
           lag(p.occurred_at) over (
             partition by p.client_id order by p.occurred_at, p.sale_id
           ) as previous_purchase_at
      from purchases p
      join qualifying_clients q on q.client_id = p.client_id
  ), intervals as (
    select client_id,
           extract(epoch from (occurred_at - previous_purchase_at)) / 86400.0 as interval_days
      from sequenced
     where previous_purchase_at is not null
  ), agg as (
    select count(*)::int as observations,
           count(distinct client_id)::int as contributing_customers,
           percentile_cont(0.5) within group (order by interval_days) as median_interval_days
      from intervals
  )
  select jsonb_build_object(
    'service_id', p_service_id,
    'observations', a.observations,
    'evidence', app.subgroup_evidence_v1(a.contributing_customers),
    'median_interval_days',
      case when (app.subgroup_evidence_v1(a.contributing_customers)->>'status') = 'insufficient'
        then null
        else round(a.median_interval_days::numeric, 1) end
  )
  from agg a;
$$;
revoke all on function app.service_cadence_v695(uuid,uuid,timestamptz) from public, anon, authenticated;
grant execute on function app.service_cadence_v695(uuid,uuid,timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- 2. app.segment_cadence_v695 — the same idea one level coarser: 'category' (level-2 taxonomy
--    node, the app.get_ci_category_mix_v1 rollup) or 'acquisition' (first_acquired_via).
-- ---------------------------------------------------------------------------
create or replace function app.segment_cadence_v695(
  p_business uuid, p_segment_kind text, p_segment_key text, p_as_of timestamptz default now()
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_result jsonb;
begin
  if p_segment_kind not in ('category', 'acquisition') then
    raise exception 'unknown segment kind: %', p_segment_kind using errcode = '22023';
  end if;
  if p_segment_key is null or btrim(p_segment_key) = '' then
    raise exception 'segment key is required' using errcode = '22023';
  end if;

  with visits as materialized (
    select distinct
           app.v111_effective_client_id(s.business_id, s.client_id) as client_id,
           s.id as sale_id, s.occurred_at
      from public.sales s
      join public.sale_items si on si.sale_id = s.id and si.business_id = s.business_id
      cross join lateral app.analytics_sale_class_v1(s) sc
      cross join lateral app.ci_effective_node_v650(si) en
      left join public.taxonomy_nodes n on n.version_no = 1 and n.node_key = en.node_key
     where p_segment_kind = 'category'
       and s.business_id = p_business
       and s.client_id is not null
       and s.created_at <= p_as_of
       and sc.include_visit
       and not sc.is_synthetic_client
       and en.node_key is not null
       and coalesce(n.parent_key, n.node_key) = p_segment_key
    union all
    select app.v111_effective_client_id(s.business_id, s.client_id), s.id, s.occurred_at
      from public.sales s
      join public.clients c on c.id = s.client_id
      cross join lateral app.analytics_sale_class_v1(s) sc
     where p_segment_kind = 'acquisition'
       and s.business_id = p_business
       and s.client_id is not null
       and s.created_at <= p_as_of
       and sc.include_visit
       and not sc.is_synthetic_client
       and c.first_acquired_via = p_segment_key
  ), qualifying as (
    select client_id from visits group by client_id having count(*) >= 2
  ), sequenced as (
    select v.client_id, v.occurred_at,
           lag(v.occurred_at) over (
             partition by v.client_id order by v.occurred_at, v.sale_id
           ) as previous_purchase_at
      from visits v
      join qualifying q on q.client_id = v.client_id
  ), intervals as (
    select client_id,
           extract(epoch from (occurred_at - previous_purchase_at)) / 86400.0 as interval_days
      from sequenced
     where previous_purchase_at is not null
  ), agg as (
    select count(*)::int as observations,
           count(distinct client_id)::int as contributing_customers,
           percentile_cont(0.5) within group (order by interval_days) as median_interval_days
      from intervals
  )
  select jsonb_build_object(
    'segment_kind', p_segment_kind,
    'segment_key', p_segment_key,
    'observations', a.observations,
    'evidence', app.subgroup_evidence_v1(a.contributing_customers),
    'median_interval_days',
      case when (app.subgroup_evidence_v1(a.contributing_customers)->>'status') = 'insufficient'
        then null
        else round(a.median_interval_days::numeric, 1) end
  ) into v_result
  from agg a;

  return v_result;
end;
$$;
revoke all on function app.segment_cadence_v695(uuid,text,text,timestamptz) from public, anon, authenticated;
grant execute on function app.segment_cadence_v695(uuid,text,text,timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- 3. app.v695_sector_cadence_multiplier — the per-sector cadence multiplier v109 already
--    defines, read directly (no feature-flag/view_finance gate: this is an internal cadence
--    computation, not the finance-facing public.get_effective_sector_policy_v109 RPC).
-- ---------------------------------------------------------------------------
create or replace function app.v695_sector_cadence_multiplier(
  p_business uuid, p_as_of timestamptz default statement_timestamp()
) returns numeric
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce(
    (select (p.parameters->>'cadence_multiplier')::numeric
       from public.sector_policy_versions_v109 p
       join public.businesses b on lower(b.industry) = p.sector_key
      where b.id = p_business
        and p.policy_key = 'lapse_detection'
        and p.status = 'published'
        and p.effective_from <= p_as_of
        and (p.effective_to is null or p.effective_to > p_as_of)
      order by p.version_no desc limit 1),
    (select (p.parameters->>'cadence_multiplier')::numeric
       from public.sector_policy_versions_v109 p
      where p.sector_key = 'other'
        and p.policy_key = 'lapse_detection'
        and p.status = 'published'
        and p.effective_from <= p_as_of
        and (p.effective_to is null or p.effective_to > p_as_of)
      order by p.version_no desc limit 1),
    2.0
  );
$$;
revoke all on function app.v695_sector_cadence_multiplier(uuid,timestamptz) from public, anon, authenticated;
grant execute on function app.v695_sector_cadence_multiplier(uuid,timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- 4. app.customer_cadence_v1 — the fallback chain. Anchored, verified-occurs-exactly-once
--    patch of the LIVE body (captured via a --keep cluster + psql before writing this
--    migration; matches db/migrations/20260920_nestly_v690_dispersion_and_one_floor.sql's own
--    style), with a round-trip proof that nothing outside the three intended edits moved.
-- ---------------------------------------------------------------------------
do $patch_cadence$
declare
  v_def text;

  v_anchor_declare constant text := 'declare
  v_policy public.customer_lifecycle_policies_v107%rowtype;
  v_row record;
  v_effective_lapse numeric;
  v_source text;
  v_days_since numeric;
  v_expected_from timestamptz;
  v_expected_to timestamptz;
  v_state text;
begin';
  v_new_declare constant text := 'declare
  v_policy public.customer_lifecycle_policies_v107%rowtype;
  v_row record;
  v_effective_lapse numeric;
  v_source text;
  v_days_since numeric;
  v_expected_from timestamptz;
  v_expected_to timestamptz;
  v_state text;
  v_service_id uuid;
  v_segment_key text;
  v_tier_evidence jsonb;
  v_fallback_evidence jsonb;
  v_evidence_class text;
begin';

  v_anchor_tier constant text := '  if v_row.interval_observations >= v_policy.customer_interval_min_observations
     and v_row.median_interval_days is not null then
    v_source := ''customer_median_interval'';
    v_effective_lapse := greatest(1, v_row.median_interval_days * v_policy.reactivation_multiplier);
    -- The customer''s own window: their median, with a symmetric tolerance of half
    -- the multiplier''s headroom. Deliberately a RANGE, never a single date.
    v_expected_from := v_row.last_visit_at
      + make_interval(secs => v_row.median_interval_days * 86400.0 * 0.75);
    v_expected_to := v_row.last_visit_at
      + make_interval(secs => v_row.median_interval_days * 86400.0 * 1.25);
  else
    v_source := ''business_fallback'';
    v_effective_lapse := greatest(1, v_policy.fallback_lapse_days);
    v_expected_from := null;
    v_expected_to := null;
  end if;';
  v_new_tier constant text := '  if v_row.interval_observations >= v_policy.customer_interval_min_observations
     and v_row.median_interval_days is not null then
    v_source := ''customer_median_interval'';
    v_effective_lapse := greatest(1, v_row.median_interval_days * v_policy.reactivation_multiplier);
    -- The customer''s own window: their median, with a symmetric tolerance of half
    -- the multiplier''s headroom. Deliberately a RANGE, never a single date.
    v_expected_from := v_row.last_visit_at
      + make_interval(secs => v_row.median_interval_days * 86400.0 * 0.75);
    v_expected_to := v_row.last_visit_at
      + make_interval(secs => v_row.median_interval_days * 86400.0 * 1.25);
    v_evidence_class := ''DIRECT_FACT'';
  else
    -- v695: the customer''s own rhythm is not trusted (below the observations gate, or no
    -- interval at all). Before falling all the way to the business-wide constant, ask whether
    -- pooled evidence -- this customer''s single most-purchased service, then their single
    -- most-purchased category -- clears the same shared floor other CI readers use.
    select si.ref_id into v_service_id
      from public.sale_items si
      join public.sales s on s.id = si.sale_id and s.business_id = si.business_id
     where s.business_id = p_business
       and s.client_id = app.v111_effective_client_id(p_business, p_client)
       and s.reversal_of is null
       and s.counts_as_visit
       and s.created_at <= p_as_of
       and si.item_type = ''service''
       and si.ref_id is not null
     group by si.ref_id
     order by count(*) desc, si.ref_id
     limit 1;

    v_tier_evidence := case when v_service_id is not null
      then app.service_cadence_v695(p_business, v_service_id, p_as_of) else null end;

    if v_tier_evidence is not null
       and (v_tier_evidence->''evidence''->>''status'') = ''ok''
       and v_tier_evidence->>''median_interval_days'' is not null then
      v_source := ''service_median'';
      v_effective_lapse := greatest(1,
        (v_tier_evidence->>''median_interval_days'')::numeric
          * app.v695_sector_cadence_multiplier(p_business, p_as_of));
      v_expected_from := null;
      v_expected_to := null;
      v_evidence_class := ''ASSOCIATION'';
      v_fallback_evidence := jsonb_build_object(
        ''n'', v_tier_evidence->''evidence''->''n'',
        ''floor'', v_tier_evidence->''evidence''->''floor'');
    else
      select coalesce(n.parent_key, n.node_key) into v_segment_key
        from public.sale_items si
        join public.sales s on s.id = si.sale_id and s.business_id = si.business_id
        cross join lateral app.ci_effective_node_v650(si) en
        left join public.taxonomy_nodes n on n.version_no = 1 and n.node_key = en.node_key
       where s.business_id = p_business
         and s.client_id = app.v111_effective_client_id(p_business, p_client)
         and s.reversal_of is null
         and s.counts_as_visit
         and s.created_at <= p_as_of
         and en.node_key is not null
       group by coalesce(n.parent_key, n.node_key)
       order by count(*) desc, coalesce(n.parent_key, n.node_key)
       limit 1;

      v_tier_evidence := case when v_segment_key is not null
        then app.segment_cadence_v695(p_business, ''category'', v_segment_key, p_as_of) else null end;

      if v_tier_evidence is not null
         and (v_tier_evidence->''evidence''->>''status'') = ''ok''
         and v_tier_evidence->>''median_interval_days'' is not null then
        v_source := ''segment_median'';
        v_effective_lapse := greatest(1,
          (v_tier_evidence->>''median_interval_days'')::numeric
            * app.v695_sector_cadence_multiplier(p_business, p_as_of));
        v_expected_from := null;
        v_expected_to := null;
        v_evidence_class := ''ASSOCIATION'';
        v_fallback_evidence := jsonb_build_object(
          ''n'', v_tier_evidence->''evidence''->''n'',
          ''floor'', v_tier_evidence->''evidence''->''floor'');
      else
        v_source := ''business_fallback'';
        v_effective_lapse := greatest(1, v_policy.fallback_lapse_days);
        v_expected_from := null;
        v_expected_to := null;
        v_evidence_class := ''ASSOCIATION'';
        v_fallback_evidence := null;
      end if;
    end if;
  end if;';

  v_anchor_tail constant text := '    ''policy'', jsonb_build_object(
      ''min_observations'', v_policy.customer_interval_min_observations,
      ''multiplier'', v_policy.reactivation_multiplier,
      ''fallback_lapse_days'', v_policy.fallback_lapse_days));';
  v_new_tail constant text := '    ''policy'', jsonb_build_object(
      ''min_observations'', v_policy.customer_interval_min_observations,
      ''multiplier'', v_policy.reactivation_multiplier,
      ''fallback_lapse_days'', v_policy.fallback_lapse_days))
    || jsonb_build_object(''evidence_class'', v_evidence_class)
    || case when v_fallback_evidence is not null
         then jsonb_build_object(''fallback_evidence'', v_fallback_evidence)
         else ''{}''::jsonb end
    || case when v_evidence_class = ''ASSOCIATION''
         then jsonb_build_object(''note'',
           ''derived from pooled evidence (service, segment, or business-wide), not this '' ||
           ''customer''''s own purchase intervals'')
         else ''{}''::jsonb end;';

  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'app.customer_cadence_v1(uuid,uuid,timestamptz)')) into v_def;
  if v_def is null then raise exception 'v695: app.customer_cadence_v1 not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_declare, ''))) / length(v_anchor_declare);
  if v_count <> 1 then
    raise exception 'v695: declare-block anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_tier, ''))) / length(v_anchor_tier);
  if v_count <> 1 then
    raise exception 'v695: tier-selection anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_tail, ''))) / length(v_anchor_tail);
  if v_count <> 1 then
    raise exception 'v695: policy-tail anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_declare, v_new_declare);
  v_expected := replace(v_expected, v_anchor_tier, v_new_tier);
  v_expected := replace(v_expected, v_anchor_tail, v_new_tail);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'app.customer_cadence_v1(uuid,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, v_new_declare, v_anchor_declare);
  v_roundtrip := replace(v_roundtrip, v_new_tier, v_anchor_tier);
  v_roundtrip := replace(v_roundtrip, v_new_tail, v_anchor_tail);
  if v_roundtrip <> v_def then
    raise exception
      'v695: customer_cadence_v1 changed by more than the three intended edits. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_cadence$;
-- ACL restated verbatim from the live proacl (unchanged by this migration — same argument list).
revoke all on function app.customer_cadence_v1(uuid,uuid,timestamptz) from public, anon, authenticated;
grant execute on function app.customer_cadence_v1(uuid,uuid,timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- 5. app.v179_business_insights — four additive 'evidence_class' splices. Extract-and-diff
--    against the LIVE body (LANGUAGE SQL preserves it verbatim, so these anchors are the
--    literal current source, post-v548/v551/v545/v690).
-- ---------------------------------------------------------------------------
do $patch_v179$
declare
  v_def text;

  v_anchor_retention constant text := '      ''prior_new_evidence'', app.subgroup_evidence_v1((select count(*) from prior_new_clients)::int)
    ),';
  v_new_retention constant text := '      ''prior_new_evidence'', app.subgroup_evidence_v1((select count(*) from prior_new_clients)::int),
      ''evidence_class'', ''DIRECT_FACT''
    ),';

  v_anchor_at_risk constant text := '      ''evidence'', app.subgroup_evidence_v1((select count(*) from at_risk)::int)
    ),';
  v_new_at_risk constant text := '      ''evidence'', app.subgroup_evidence_v1((select count(*) from at_risk)::int),
      ''evidence_class'', ''ASSOCIATION'',
      ''evidence_class_note'', ''a fixed 45-180 day absence window is a heuristic threshold, not a customer-specific prediction of return''
    ),';

  v_anchor_top constant text := '      ''evidence'', app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)
    ),';
  v_new_top constant text := '      ''evidence'', app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int),
      ''evidence_class'', ''DIRECT_FACT''
    ),';

  v_anchor_weekday constant text := '      ''quietest_isodow'', (select isodow from weekday order by revenue_cents asc, isodow limit 1)
    ),';
  v_new_weekday constant text := '      ''quietest_isodow'', (select isodow from weekday order by revenue_cents asc, isodow limit 1),
      ''evidence_class'', ''DIRECT_FACT''
    ),';

  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'app.v179_business_insights(uuid,date,date,date,date)')) into v_def;
  if v_def is null then raise exception 'v695: app.v179_business_insights not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_retention, ''))) / length(v_anchor_retention);
  if v_count <> 1 then
    raise exception 'v695: retention-tail anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_at_risk, ''))) / length(v_anchor_at_risk);
  if v_count <> 1 then
    raise exception 'v695: at_risk-tail anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_top, ''))) / length(v_anchor_top);
  if v_count <> 1 then
    raise exception 'v695: top_customers-tail anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_weekday, ''))) / length(v_anchor_weekday);
  if v_count <> 1 then
    raise exception 'v695: weekday-tail anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_retention, v_new_retention);
  v_expected := replace(v_expected, v_anchor_at_risk, v_new_at_risk);
  v_expected := replace(v_expected, v_anchor_top, v_new_top);
  v_expected := replace(v_expected, v_anchor_weekday, v_new_weekday);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'app.v179_business_insights(uuid,date,date,date,date)')) into v_after;

  v_roundtrip := replace(v_after, v_new_retention, v_anchor_retention);
  v_roundtrip := replace(v_roundtrip, v_new_at_risk, v_anchor_at_risk);
  v_roundtrip := replace(v_roundtrip, v_new_top, v_anchor_top);
  v_roundtrip := replace(v_roundtrip, v_new_weekday, v_anchor_weekday);
  if v_roundtrip <> v_def then
    raise exception
      'v695: v179_business_insights changed by more than the four evidence_class splices. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_v179$;
-- ACL restated verbatim from the live proacl (unchanged by this migration).
revoke all privileges on function
  app.v179_business_insights(uuid, date, date, date, date)
  from public, anon, authenticated, service_role;

commit;
