-- NESTLY v690 — Phase CI-B continued: dispersion alongside the median (check 45), and one
-- sample-floor authority reaching every subgroup surface, not just the ones built after it
-- existed (check 61).
--
-- Contract: docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md (v672, frozen). Fixture guide:
-- docs/qa/CI-CORPUS-FIXTURE-GUIDE.md.
--
-- ============================================================================================
-- PART 1 — DISPERSION (check 45)
-- ============================================================================================
-- app.customer_cadence_batch_v1 (v651) and app.customer_cadence_v1 (v651, D3-patched by v669)
-- report a median inter-purchase interval and nothing about its spread. Two customers with the
-- same median can have wildly different reliability — one visits every 7-10 days like clockwork,
-- another swings 2-40 days and only "medians" to the same number. This adds the spread, without
-- touching a single existing key or value.
--
-- app.customer_cadence_batch_v1 gains three new output columns (extract-and-diff: the RETURNS
-- TABLE list and the SELECT list are patched from the LIVE pg_get_functiondef text, verified to
-- occur exactly once, and the resulting definition is diffed back down to the original to prove
-- nothing else moved). Adding output columns changes the function's return type, which Postgres
-- will not let CREATE OR REPLACE do — so this drops and recreates it; the replace-equality proof
-- covers the recreated body, and every existing consumer (app.get_customer_lifecycle_v107, its
-- only caller per v651) selects columns by name and is unaffected by the three new ones on the
-- end.
--
-- app.customer_cadence_v1 gains one new key, 'dispersion', immediately after the existing
-- 'median_interval_days' key (D3's own patched text is the anchor). Per the same honesty rule
-- D3 established for the median itself: dispersion is null whenever fewer than 2 intervals are
-- on record (percentile_cont on 0 or 1 points is not a spread, it is a single number wearing a
-- spread's clothes).
--
-- ============================================================================================
-- PART 2 — ONE FLOOR (check 61)
-- ============================================================================================
-- (a) app.v179_business_insights re-emitted (extract-and-diff, LANGUAGE SQL body preserved
--     verbatim by Postgres so the anchors below are the literal migration source of v179): the
--     at_risk cohort, the top_customers concentration shares, and the prior-new return rate each
--     gain an 'evidence' block from app.subgroup_evidence_v1 (floor 5, the same convention v667
--     and v672 already use for identity suppression and value-surface floors). When the cohort
--     is under floor, the rate-like field nulls out (recovery value in dollars, the two share
--     percentages, the return-rate percentage) while every count stays exactly as it was. Every
--     existing key is untouched; three new keys are added (at_risk.evidence,
--     top_customers.evidence, retention.prior_new_evidence). app.v176_evidence_pack embeds
--     v179's output opaquely and needs no change; the edge function and v677 validators read
--     existing keys only, so they are unaffected — an 'evidence' key is additive.
--
-- (b) v108's minimum_arm_size (public.refresh_growth_recommendation_v108) keeps its own
--     owner-configurable policy value — this migration does not touch
--     growth_policies_v108.minimum_arm_size or its semantics. What changes is which CODE decides
--     "is this arm big enough": the two inline `< v_policy.minimum_arm_size` comparisons are
--     replaced with two calls to app.subgroup_evidence_v1(arm_size, v_policy.minimum_arm_size),
--     checking ->>'status' = 'insufficient'. Same floor value, same two arms (treatment and
--     holdout), same net effect (experiment_arms_too_small suppression) — just routed through
--     the shared authority instead of a local `<` so the AUTHORITY is shared even while the
--     FLOOR VALUE legitimately varies per business.
--
-- (c) app.ci_floor_registry_v690() — a short jsonb registry naming every subgroup surface in the
--     system and which floor authority backs it: the v672 readers and v179 on
--     app.subgroup_evidence_v1's fixed default (5), v108 on the same function with its own
--     policy-driven floor, and v652's app.evidence_block_v1 on its own, deliberately SEPARATE
--     p_min_arm parameter (a confidence-interval verdict floor, not a sample-count floor — kept
--     distinct on purpose, registered here so both floors in the system are visible in one
--     place rather than one being invisible).

begin;

-- ---------------------------------------------------------------------------
-- 1a. app.customer_cadence_batch_v1 — add interval_p25, interval_p75, interval_iqr_days.
--     Return-type change: drop + recreate, proven byte-faithful by reversing the two patches
--     against the captured BEFORE text.
-- ---------------------------------------------------------------------------
do $patch_batch$
declare
  v_def          text;
  v_anchor_ret   constant text := 'paid_visits integer)';
  v_new_ret      constant text :=
    'paid_visits integer, interval_p25 numeric, interval_p75 numeric, interval_iqr_days numeric)';
  v_anchor_sel   constant text := '         max(occurred_at) as last_visit_at,
         count(*)::integer as paid_visits
    from sequenced';
  v_new_sel      constant text := '         max(occurred_at) as last_visit_at,
         count(*)::integer as paid_visits,
         percentile_cont(0.25) within group (
           order by extract(epoch from (occurred_at - previous_purchase_at)) / 86400.0
         ) filter (where previous_purchase_at is not null)
           as interval_p25,
         percentile_cont(0.75) within group (
           order by extract(epoch from (occurred_at - previous_purchase_at)) / 86400.0
         ) filter (where previous_purchase_at is not null)
           as interval_p75,
         (percentile_cont(0.75) within group (
           order by extract(epoch from (occurred_at - previous_purchase_at)) / 86400.0
         ) filter (where previous_purchase_at is not null)
          - percentile_cont(0.25) within group (
           order by extract(epoch from (occurred_at - previous_purchase_at)) / 86400.0
         ) filter (where previous_purchase_at is not null))
           as interval_iqr_days
    from sequenced';
  v_count_r integer;
  v_count_s integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'app.customer_cadence_batch_v1(uuid,date,date,timestamptz,uuid,boolean)')) into v_def;
  if v_def is null then raise exception 'v690: app.customer_cadence_batch_v1 not found'; end if;

  v_count_r := (length(v_def) - length(replace(v_def, v_anchor_ret, ''))) / length(v_anchor_ret);
  if v_count_r <> 1 then
    raise exception 'v690: RETURNS TABLE anchor occurs % times (expected 1) — live body drifted', v_count_r;
  end if;
  v_count_s := (length(v_def) - length(replace(v_def, v_anchor_sel, ''))) / length(v_anchor_sel);
  if v_count_s <> 1 then
    raise exception 'v690: select-list anchor occurs % times (expected 1) — live body drifted', v_count_s;
  end if;

  v_expected := replace(v_def, v_anchor_ret, v_new_ret);
  v_expected := replace(v_expected, v_anchor_sel, v_new_sel);

  -- Adding OUT columns is a return-type change: CREATE OR REPLACE refuses it, so drop first.
  drop function app.customer_cadence_batch_v1(uuid,date,date,timestamptz,uuid,boolean);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'app.customer_cadence_batch_v1(uuid,date,date,timestamptz,uuid,boolean)')) into v_after;

  -- Replace-equality proof: reversing both patches against the AFTER text must reproduce the
  -- BEFORE text exactly. Any other drift raises.
  v_roundtrip := replace(replace(v_after, v_new_sel, v_anchor_sel), v_new_ret, v_anchor_ret);
  if v_roundtrip <> v_def then
    raise exception
      'v690: customer_cadence_batch_v1 changed by more than the dispersion columns. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_batch$;
-- ACL restated verbatim from the live proacl (unchanged by this migration — same argument list).
revoke all on function app.customer_cadence_batch_v1(uuid,date,date,timestamptz,uuid,boolean)
  from public, anon, authenticated;
grant execute on function app.customer_cadence_batch_v1(uuid,date,date,timestamptz,uuid,boolean)
  to service_role;

-- ---------------------------------------------------------------------------
-- 1b. app.customer_cadence_v1 — add the 'dispersion' key. Anchor is D3's own patched text
--     (v669), so this stacks correctly on top of the numeric-honesty fix rather than assuming
--     the pre-v669 shape.
-- ---------------------------------------------------------------------------
do $patch_v1$
declare
  v_def text;
  v_anchor constant text := '    ''median_interval_days'', case when coalesce(v_row.interval_observations, 0) = 0 then null
        else round(v_row.median_interval_days::numeric, 1) end,';
  v_added constant text := '
    ''dispersion'', case when coalesce(v_row.interval_observations, 0) < 2 then null
        else jsonb_build_object(
          ''p25'', round(v_row.interval_p25::numeric, 2),
          ''p75'', round(v_row.interval_p75::numeric, 2),
          ''iqr_days'', round(v_row.interval_iqr_days::numeric, 2),
          ''basis'', ''inter-purchase intervals'') end,';
  v_new text;
  v_count integer;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'app.customer_cadence_v1(uuid,uuid,timestamptz)')) into v_def;
  if v_def is null then raise exception 'v690: app.customer_cadence_v1 not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_count <> 1 then
    raise exception 'v690: median_interval_days anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  v_new := v_anchor || v_added;
  execute replace(v_def, v_anchor, v_new);

  select pg_get_functiondef(to_regprocedure(
    'app.customer_cadence_v1(uuid,uuid,timestamptz)')) into v_after;
  v_roundtrip := replace(v_after, v_new, v_anchor);
  if v_roundtrip <> v_def then
    raise exception
      'v690: customer_cadence_v1 changed by more than the dispersion key. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_v1$;
-- ACL restated verbatim from the live proacl (unchanged by this migration).
revoke all on function app.customer_cadence_v1(uuid,uuid,timestamptz) from public, anon, authenticated;
grant execute on function app.customer_cadence_v1(uuid,uuid,timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- 2a. app.v179_business_insights — splice 'evidence' into at_risk, top_customers and the
--     retention block's prior-new rate. Extract-and-diff against the live pg_get_functiondef;
--     LANGUAGE SQL preserves the body verbatim, so these anchors are the literal v179 source.
-- ---------------------------------------------------------------------------
do $patch_v179$
declare
  v_def text;

  v_anchor_retention constant text := '      ''prior_new_return_rate_pct'', (
        select case when (select count(*) from prior_new_clients) = 0 then null
          else round(100.0 * (select returned from prior_new_returned)
                     / (select count(*) from prior_new_clients), 1) end
      )
    ),';
  v_new_retention constant text := '      ''prior_new_return_rate_pct'',
        case when (app.subgroup_evidence_v1((select count(*) from prior_new_clients)::int)->>''status'') = ''insufficient''
          then null
          else (
            select case when (select count(*) from prior_new_clients) = 0 then null
              else round(100.0 * (select returned from prior_new_returned)
                         / (select count(*) from prior_new_clients), 1) end
          ) end,
      ''prior_new_evidence'', app.subgroup_evidence_v1((select count(*) from prior_new_clients)::int)
    ),';

  -- NOTE: these two anchors are the LIVE post-v551/v548 shape (v551 renamed the share fields
  -- to top1_share_of_total_revenue_pct / top5_share_of_total_revenue_pct / _of_identified_
  -- variants and v548 added the 'scope' key), not the original v179 source text — extracted
  -- from the migrated cluster's actual pg_get_functiondef, per the fixture guide's warning that
  -- extract-and-diff must anchor on the LIVE body, never an assumed prior version.
  v_anchor_at_risk constant text := '    ''at_risk'', pg_catalog.jsonb_build_object(
      ''scope'', ''identified_customers_only'',
      ''definition'', ''customers with 2+ lifetime visits whose last visit is 45-180 days before period end'',
      ''customers'', (select count(*) from at_risk),
      ''their_lifetime_revenue_cents'', (select coalesce(sum(lifetime_revenue_cents), 0) from at_risk),
      ''recovery_value_one_visit_each_cents'', (select coalesce(sum(avg_ticket_cents), 0) from at_risk)
    ),
';
  v_new_at_risk constant text := '    ''at_risk'', pg_catalog.jsonb_build_object(
      ''scope'', ''identified_customers_only'',
      ''definition'', ''customers with 2+ lifetime visits whose last visit is 45-180 days before period end'',
      ''customers'', (select count(*) from at_risk),
      ''their_lifetime_revenue_cents'', (select coalesce(sum(lifetime_revenue_cents), 0) from at_risk),
      ''recovery_value_one_visit_each_cents'',
        case when (app.subgroup_evidence_v1((select count(*) from at_risk)::int)->>''status'') = ''insufficient''
          then null
          else (select coalesce(sum(avg_ticket_cents), 0) from at_risk) end,
      ''evidence'', app.subgroup_evidence_v1((select count(*) from at_risk)::int)
    ),
';

  v_anchor_top constant text := '    ''top_customers'', pg_catalog.jsonb_build_object(
      ''scope'', ''identified_customers_only'',
      ''rows'', coalesce((
        select jsonb_agg(jsonb_build_object(
          ''label'', app.v177_person_label(client.full_name, wc.client_id),
          ''revenue_cents'', wc.revenue_cents,
          ''visits'', wc.visits,
          ''is_new_this_period'', wc.is_new
        ) order by wc.revenue_cents desc, wc.client_id)
        from (select * from window_clients order by revenue_cents desc limit 5) wc
        join public.clients client on client.id = wc.client_id
        where wc.revenue_cents > 0
      ), ''[]''::jsonb),
      ''top1_share_of_total_revenue_pct'', (
        select case when wa.total_cents = 0 then null
          else round(100.0 * (select max(revenue_cents) from window_clients) / wa.total_cents, 1) end
        from window_all_revenue wa
      ),
      ''top5_share_of_total_revenue_pct'', (
        select case when wa.total_cents = 0 then null
          else round(100.0 * (
            select coalesce(sum(revenue_cents), 0)
              from (select revenue_cents from window_clients order by revenue_cents desc limit 5) top5
          ) / wa.total_cents, 1) end
        from window_all_revenue wa
      ),
      /* v551: the expressions below are the PRE-v551 fields verbatim — only the names changed,
         to say what the denominator has always been. */
      ''top1_share_of_identified_revenue_pct'', (
        select case when wr.total_cents = 0 then null
          else round(100.0 * (select max(revenue_cents) from window_clients) / wr.total_cents, 1) end
        from window_revenue wr
      ),
      ''top5_share_of_identified_revenue_pct'', (
        select case when wr.total_cents = 0 then null
          else round(100.0 * (
            select coalesce(sum(revenue_cents), 0)
            from (select revenue_cents from window_clients
                  order by revenue_cents desc limit 5) top5
          ) / wr.total_cents, 1) end
        from window_revenue wr
      )
    ),
';
  v_new_top constant text := '    ''top_customers'', pg_catalog.jsonb_build_object(
      ''scope'', ''identified_customers_only'',
      ''rows'', coalesce((
        select jsonb_agg(jsonb_build_object(
          ''label'', app.v177_person_label(client.full_name, wc.client_id),
          ''revenue_cents'', wc.revenue_cents,
          ''visits'', wc.visits,
          ''is_new_this_period'', wc.is_new
        ) order by wc.revenue_cents desc, wc.client_id)
        from (select * from window_clients order by revenue_cents desc limit 5) wc
        join public.clients client on client.id = wc.client_id
        where wc.revenue_cents > 0
      ), ''[]''::jsonb),
      ''top1_share_of_total_revenue_pct'',
        case when (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>''status'') = ''insufficient''
          then null
          else (
            select case when wa.total_cents = 0 then null
              else round(100.0 * (select max(revenue_cents) from window_clients) / wa.total_cents, 1) end
            from window_all_revenue wa
          ) end,
      ''top5_share_of_total_revenue_pct'',
        case when (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>''status'') = ''insufficient''
          then null
          else (
            select case when wa.total_cents = 0 then null
              else round(100.0 * (
                select coalesce(sum(revenue_cents), 0)
                  from (select revenue_cents from window_clients order by revenue_cents desc limit 5) top5
              ) / wa.total_cents, 1) end
            from window_all_revenue wa
          ) end,
      /* v551: the expressions below are the PRE-v551 fields verbatim — only the names changed,
         to say what the denominator has always been. */
      ''top1_share_of_identified_revenue_pct'',
        case when (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>''status'') = ''insufficient''
          then null
          else (
            select case when wr.total_cents = 0 then null
              else round(100.0 * (select max(revenue_cents) from window_clients) / wr.total_cents, 1) end
            from window_revenue wr
          ) end,
      ''top5_share_of_identified_revenue_pct'',
        case when (app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)->>''status'') = ''insufficient''
          then null
          else (
            select case when wr.total_cents = 0 then null
              else round(100.0 * (
                select coalesce(sum(revenue_cents), 0)
                from (select revenue_cents from window_clients
                      order by revenue_cents desc limit 5) top5
              ) / wr.total_cents, 1) end
            from window_revenue wr
          ) end,
      ''evidence'', app.subgroup_evidence_v1((select count(*) from window_clients where visits > 0)::int)
    ),
';

  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'app.v179_business_insights(uuid,date,date,date,date)')) into v_def;
  if v_def is null then raise exception 'v690: app.v179_business_insights not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_retention, ''))) / length(v_anchor_retention);
  if v_count <> 1 then
    raise exception 'v690: retention/prior_new anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_at_risk, ''))) / length(v_anchor_at_risk);
  if v_count <> 1 then
    raise exception 'v690: at_risk anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_top, ''))) / length(v_anchor_top);
  if v_count <> 1 then
    raise exception 'v690: top_customers anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_retention, v_new_retention);
  v_expected := replace(v_expected, v_anchor_at_risk, v_new_at_risk);
  v_expected := replace(v_expected, v_anchor_top, v_new_top);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'app.v179_business_insights(uuid,date,date,date,date)')) into v_after;

  v_roundtrip := replace(v_after, v_new_retention, v_anchor_retention);
  v_roundtrip := replace(v_roundtrip, v_new_at_risk, v_anchor_at_risk);
  v_roundtrip := replace(v_roundtrip, v_new_top, v_anchor_top);
  if v_roundtrip <> v_def then
    raise exception
      'v690: v179_business_insights changed by more than the three evidence splices. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_v179$;
-- ACL restated verbatim from the live proacl (unchanged by this migration — v179 has never been
-- callable directly by anything, including service_role; only v176_evidence_pack, itself
-- SECURITY DEFINER, reaches it).
revoke all privileges on function
  app.v179_business_insights(uuid, date, date, date, date)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2b. public.refresh_growth_recommendation_v108 — route the arm-size check through the shared
--     authority. Policy semantics (the floor VALUE, owner-configurable per business) untouched;
--     only which code decides "insufficient" changes.
-- ---------------------------------------------------------------------------
do $patch_v108$
declare
  v_def text;
  -- NOTE: the live body is the CONDENSED form nestly_v113 re-serialized it into (no spaces
  -- around operators, `:=` not `:= `), not the original v108 source formatting — extracted from
  -- the migrated cluster's actual pg_get_functiondef, per the fixture guide's warning to anchor
  -- on the LIVE body, never an assumed prior version.
  v_anchor constant text := '  if floor(v_eligible*v_policy.holdout_percent/100.0)<v_policy.minimum_arm_size
     or v_eligible-floor(v_eligible*v_policy.holdout_percent/100.0)
        <v_policy.minimum_arm_size then
    v_suppressions:=v_suppressions||
      jsonb_build_array(''experiment_arms_too_small'');
  end if;';
  v_new constant text := '  if (app.subgroup_evidence_v1(floor(v_eligible*v_policy.holdout_percent/100.0)::integer,v_policy.minimum_arm_size)->>''status'')=''insufficient''
     or (app.subgroup_evidence_v1((v_eligible-floor(v_eligible*v_policy.holdout_percent/100.0))::integer,v_policy.minimum_arm_size)->>''status'')=''insufficient'' then
    v_suppressions:=v_suppressions||
      jsonb_build_array(''experiment_arms_too_small'');
  end if;';
  v_count integer;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.refresh_growth_recommendation_v108(uuid,uuid)')) into v_def;
  if v_def is null then raise exception 'v690: public.refresh_growth_recommendation_v108 not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_count <> 1 then
    raise exception 'v690: experiment_arms_too_small anchor occurs % times (expected 1) — live body drifted', v_count;
  end if;

  execute replace(v_def, v_anchor, v_new);

  select pg_get_functiondef(to_regprocedure(
    'public.refresh_growth_recommendation_v108(uuid,uuid)')) into v_after;
  v_roundtrip := replace(v_after, v_new, v_anchor);
  if v_roundtrip <> v_def then
    raise exception
      'v690: refresh_growth_recommendation_v108 changed by more than the arm-size authority swap. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_v108$;
-- ACL restated verbatim from the live proacl (unchanged by this migration).
revoke all on function public.refresh_growth_recommendation_v108(uuid,uuid) from public, anon;
grant execute on function public.refresh_growth_recommendation_v108(uuid,uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2c. app.ci_floor_registry_v690 — a short, checkable registry of every subgroup surface and
--     the floor authority behind it. The fixture proves this registry matches reality by
--     calling each named function directly and comparing shapes, not by trusting this list.
-- ---------------------------------------------------------------------------
create or replace function app.ci_floor_registry_v690()
returns jsonb
language sql
stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select jsonb_build_object(
    'contract_version', 'v690',
    'surfaces', jsonb_build_array(
      jsonb_build_object(
        'surface', 'v672_subgroup_readers',
        'authority', 'app.subgroup_evidence_v1',
        'floor_kind', 'fixed_default',
        'default_floor', 5,
        'note', 'Every Customer Intelligence subgroup reader from phase CI-A onward embeds '
                'app.subgroup_evidence_v1 directly rather than computing its own floor.'
      ),
      jsonb_build_object(
        'surface', 'v179_business_insights',
        'authority', 'app.subgroup_evidence_v1',
        'floor_kind', 'fixed_default',
        'default_floor', 5,
        'note', 'at_risk, top_customers and the retention block''s prior-new cohort each carry '
                'an evidence block from the shared authority; the matching rate-like field nulls '
                'out when insufficient, counts stay.'
      ),
      jsonb_build_object(
        'surface', 'v108_bring_back_arm_size',
        'authority', 'app.subgroup_evidence_v1',
        'floor_kind', 'policy_configurable',
        'policy_column', 'growth_policies_v108.minimum_arm_size',
        'note', 'The treatment and holdout arm sizes are each checked against the shared '
                'authority using this business''s own minimum_arm_size as the floor argument — '
                'the floor value is owner-configurable, the authority deciding sufficiency is not.'
      ),
      jsonb_build_object(
        'surface', 'v652_evidence_block',
        'authority', 'app.evidence_block_v1',
        'floor_kind', 'parameter',
        'policy_column', 'p_min_arm',
        'note', 'A deliberately SEPARATE authority: this is the confidence-interval verdict '
                'floor (default 10), not a sample-count floor. Registered here so both floors '
                'in the system are visible in one place instead of one being invisible.'
      )
    )
  );
$$;
revoke all on function app.ci_floor_registry_v690() from public, anon;
grant execute on function app.ci_floor_registry_v690() to service_role;

commit;
