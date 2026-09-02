-- NESTLY v722 -- shared-envelope freshness (check 97) + consultant-brief evidence (check 93) +
-- one platform auth arm for an assigned consultant (check 91/94 range).
--
-- Refuter findings (docs/qa/CI-100-CHECKLIST.md checks 93/97/98):
--
-- (97) The shared envelope (app.ci_envelope_v680, v680/v693) carried NO freshness disclosure of
-- its own. get_ci_opportunities_v1 (v680/v688) built its own bespoke freshness block that also
-- drives a stale-evidence RANKING REFUSAL, and get_ci_customer_records_v1 (v692) built a much
-- thinner one -- but every other CI reader wrapped by the envelope disclosed nothing about how
-- fresh the data behind it is. Fixed by widening app.ci_envelope_v680 itself (the same
-- one-authority-by-calling posture as v672's subgroup_evidence_v1 and the same additive-widen
-- discipline v693 used on this exact function for the exclusions block): a reader whose payload
-- does not already carry a top-level 'freshness' key now gets one built from
--   data_as_of        max(sales.occurred_at) for the business, branch-scoped when p_branch is
--                      given, as of p_as_of (created_at <= p_as_of keeps this point-in-time
--                      reproducible -- the same discipline get_ci_category_mix_v1's own backdate
--                      handling relies on, proven by db/tests/executed/v680_corpus_envelope.sql
--                      E7c)
--   observed_since     the reader's own top-level 'observed_since' watermark when it set one
--                      (most readers already do, via app.metric_observed_since_v1), else null
--   generated_at       same instant as the envelope's own top-level 'generated_at'
--   age_hours          generated_at minus data_as_of, in hours
--   stale              age_hours > 48, or true when there is no sale on record at all
--   note               what the field means, so a caller does not need to read this migration
-- A reader that ALREADY sets 'freshness' (opportunities, customer_records) is passed through
-- byte-for-byte -- widening this function must not silently rewrite behaviour those two readers'
-- own fixtures already pin (v680_corpus E8 asserts get_ci_opportunities_v1's own
-- freshness.stale/refusal_reason under a far-future as_of; recomputing "stale" here from real
-- max(sales.occurred_at) instead of that reader's observed_since_min logic would flip it). This
-- also matches the letter of the finding: never refuse, only disclose -- the envelope-level
-- freshness block does not gate anything, it is pure disclosure.
--
-- (93) public.platform_get_assigned_firm_report_v94's (v94, re-emitted whole by v714, no
-- further redefinition since) consultant-brief 'kpis', 'cohorts' and 'customer_intelligence'
-- sections rendered bare numbers -- including bare zeros on an empty business -- with no
-- indication of whether an identified-customer sample backed them, while sibling CI surfaces
-- (v672 onward) carry an evidence block wherever a subgroup claim is made. Fixed by computing
-- app.subgroup_evidence_v1 once, on the identified-customer count (the same population
-- 'customer_intelligence.total_customers' already counts), and adding it to all three sections.
-- When that count is below the floor (default 5): the derived, rate-like kpis field
-- (average_order_cents, an average is exactly the kind of value a 1-customer sample cannot
-- support) and the identity-bearing customer_intelligence field (top_customer_revenue_cents,
-- which on a small business can point straight at one named customer -- the same small-cell
-- concern check 96 exists for) both go null, and a section-level 'status':'unavailable' marker
-- appears next to 'evidence'. Every COUNT (net_revenue_cents, visits, active_customers,
-- returning_customers, the cohort counts, total_customers, customers_with_purchase,
-- customers_over_90_days_inactive) is left exactly as before -- zero is a legitimate count on an
-- empty business and must keep rendering as zero, not disappear. This is the identical idiom
-- v717 Part B already used for get_ci_category_mix_v1's per-category distribution/skew_note:
-- evidence added, rate-like/distribution-shaped fields nulled below the floor, counts untouched.
--
-- Also (91/94 range): public.platform_customer_account_opens_v175 (v175) refused a legitimately
-- assigned platform consultant trying to pull this report into their brief -- its v_authorized
-- expression covered is_super_admin(), has_perm(business,'view_finance') and the internal
-- (app.v89_can_access_business + app.v89_platform_can('reports','r')) combination, but not the
-- assigned-consultant arm platform_get_assigned_firm_report_v94 itself already gates on
-- (app.platform_firm_report_access_v94, wrapped for exactly this purpose by v176 as
-- app.v176_can_read_firm_report). Fixed by adding that arm to v_authorized. No other arm changes:
-- an unauthorized caller still gets 42501, unchanged.
--
-- Re-emits ONLY: app.ci_envelope_v680, public.platform_get_assigned_firm_report_v94,
-- public.platform_customer_account_opens_v175. Does NOT touch app.v179_business_insights (the
-- spine; v718's), public.get_ci_opportunities_v1 or the one-CI-gate/v83 surface (v721's), the AI
-- evidence pack (v720's), or get_ci_category_mix_v1 (v717's) -- all out of scope for this
-- migration and, where still in flight, owned by sibling sessions.
--
-- Every patch below is an anchored extract-and-diff replace-equality edit of the LIVE body
-- (pg_get_functiondef captured at apply time), verified to occur exactly once and to round-trip
-- back to the exact live original once the intended edit is reversed -- same discipline as
-- v668/v690/v698/v706/v717, never a hand-retyped guess at the base text.
--
-- Proven by db/tests/executed/v722_corpus_freshness_brief.sql.

begin;

-- -------------------------------------------------------------------------------------------
-- app.ci_envelope_v680 -- add the freshness block (check 97)
-- -------------------------------------------------------------------------------------------
do $patch_envelope$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'app.ci_envelope_v680(text,uuid,uuid,date,date,timestamptz,jsonb,jsonb)')) into v_def;
  if v_def is null then
    raise exception 'v722: app.ci_envelope_v680(text,uuid,uuid,date,date,timestamptz,jsonb,jsonb) not found';
  end if;

  -- edit 1 of 2: new local variables
  v_count := (length(v_def) - length(replace(v_def, $zzv722tag1zzz$declare
  v_scope text;
  v_excl jsonb;
  v_trace text;
begin$zzv722tag1zzz$, ''))) / greatest(length($zzv722tag2zzz$declare
  v_scope text;
  v_excl jsonb;
  v_trace text;
begin$zzv722tag2zzz$), 1);
  if v_count <> 1 then
    raise exception 'v722: envelope.decl anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $zzv722tag3zzz$declare
  v_scope text;
  v_excl jsonb;
  v_trace text;
begin$zzv722tag3zzz$, $zzv722tag4zzz$declare
  v_scope text;
  v_excl jsonb;
  v_trace text;
  v_generated_at timestamptz := clock_timestamp();
  v_data_as_of timestamptz;
  v_age_hours numeric;
  v_stale boolean;
  v_freshness jsonb;
begin$zzv722tag4zzz$);

  -- edit 2 of 2: compute freshness (skipped when the reader already set its own) and return it
  v_count := (length(v_expected) - length(replace(v_expected, $zzv722tag5zzz$  return p_payload || jsonb_build_object(
    'generated_at', clock_timestamp(),
    'as_of', p_as_of,
    'period', jsonb_build_object(
      'from', p_from, 'to', p_to, 'interval', '[from,to]', 'timezone', 'Asia/Singapore'),
    'exclusions', v_excl,
    'trace_id', v_trace);
end;$zzv722tag5zzz$, ''))) / greatest(length($zzv722tag6zzz$  return p_payload || jsonb_build_object(
    'generated_at', clock_timestamp(),
    'as_of', p_as_of,
    'period', jsonb_build_object(
      'from', p_from, 'to', p_to, 'interval', '[from,to]', 'timezone', 'Asia/Singapore'),
    'exclusions', v_excl,
    'trace_id', v_trace);
end;$zzv722tag6zzz$), 1);
  if v_count <> 1 then
    raise exception 'v722: envelope.return anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_expected, $zzv722tag7zzz$  return p_payload || jsonb_build_object(
    'generated_at', clock_timestamp(),
    'as_of', p_as_of,
    'period', jsonb_build_object(
      'from', p_from, 'to', p_to, 'interval', '[from,to]', 'timezone', 'Asia/Singapore'),
    'exclusions', v_excl,
    'trace_id', v_trace);
end;$zzv722tag7zzz$, $zzv722tag8zzz$  if not (p_payload ? 'freshness') then
    select max(s.occurred_at) into v_data_as_of
      from public.sales s
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and s.created_at <= p_as_of;

    v_age_hours := case when v_data_as_of is null then null
      else round(extract(epoch from (v_generated_at - v_data_as_of)) / 3600.0, 1) end;

    v_stale := (v_data_as_of is null) or (v_age_hours > 48);

    v_freshness := jsonb_build_object(
      'data_as_of', v_data_as_of,
      'observed_since', p_payload->'observed_since',
      'generated_at', v_generated_at,
      'age_hours', v_age_hours,
      'stale', v_stale,
      'note', case when v_data_as_of is null
        then 'No sales recorded yet for this scope; treat any finding as provisional.'
        else 'data_as_of is the most recent recorded sale for this scope, not the requested reporting period; stale means that sale is more than 48 hours old.'
        end);
  else
    v_freshness := p_payload->'freshness';
  end if;

  return p_payload || jsonb_build_object(
    'generated_at', v_generated_at,
    'as_of', p_as_of,
    'period', jsonb_build_object(
      'from', p_from, 'to', p_to, 'interval', '[from,to]', 'timezone', 'Asia/Singapore'),
    'exclusions', v_excl,
    'trace_id', v_trace,
    'freshness', v_freshness);
end;$zzv722tag8zzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'app.ci_envelope_v680(text,uuid,uuid,date,date,timestamptz,jsonb,jsonb)')) into v_after;

  v_roundtrip := replace(v_after, $zzv722tag9zzz$declare
  v_scope text;
  v_excl jsonb;
  v_trace text;
  v_generated_at timestamptz := clock_timestamp();
  v_data_as_of timestamptz;
  v_age_hours numeric;
  v_stale boolean;
  v_freshness jsonb;
begin$zzv722tag9zzz$, $zzv722tagAzzz$declare
  v_scope text;
  v_excl jsonb;
  v_trace text;
begin$zzv722tagAzzz$);
  v_roundtrip := replace(v_roundtrip, $zzv722tagBzzz$  if not (p_payload ? 'freshness') then
    select max(s.occurred_at) into v_data_as_of
      from public.sales s
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and s.created_at <= p_as_of;

    v_age_hours := case when v_data_as_of is null then null
      else round(extract(epoch from (v_generated_at - v_data_as_of)) / 3600.0, 1) end;

    v_stale := (v_data_as_of is null) or (v_age_hours > 48);

    v_freshness := jsonb_build_object(
      'data_as_of', v_data_as_of,
      'observed_since', p_payload->'observed_since',
      'generated_at', v_generated_at,
      'age_hours', v_age_hours,
      'stale', v_stale,
      'note', case when v_data_as_of is null
        then 'No sales recorded yet for this scope; treat any finding as provisional.'
        else 'data_as_of is the most recent recorded sale for this scope, not the requested reporting period; stale means that sale is more than 48 hours old.'
        end);
  else
    v_freshness := p_payload->'freshness';
  end if;

  return p_payload || jsonb_build_object(
    'generated_at', v_generated_at,
    'as_of', p_as_of,
    'period', jsonb_build_object(
      'from', p_from, 'to', p_to, 'interval', '[from,to]', 'timezone', 'Asia/Singapore'),
    'exclusions', v_excl,
    'trace_id', v_trace,
    'freshness', v_freshness);
end;$zzv722tagBzzz$, $zzv722tagCzzz$  return p_payload || jsonb_build_object(
    'generated_at', clock_timestamp(),
    'as_of', p_as_of,
    'period', jsonb_build_object(
      'from', p_from, 'to', p_to, 'interval', '[from,to]', 'timezone', 'Asia/Singapore'),
    'exclusions', v_excl,
    'trace_id', v_trace);
end;$zzv722tagCzzz$);
  if v_roundtrip <> v_def then
    raise exception
      'v722: app.ci_envelope_v680 changed by more than the 2 intended edits. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end;
$patch_envelope$;

revoke all on function app.ci_envelope_v680(text,uuid,uuid,date,date,timestamptz,jsonb,jsonb)
  from public, anon, authenticated;

-- -------------------------------------------------------------------------------------------
-- public.platform_get_assigned_firm_report_v94 -- evidence for kpis/cohorts/customer_intelligence
-- (check 93)
-- -------------------------------------------------------------------------------------------
do $patch_v94$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.platform_get_assigned_firm_report_v94(uuid,uuid,date,date)')) into v_def;
  if v_def is null then
    raise exception 'v722: public.platform_get_assigned_firm_report_v94(uuid,uuid,date,date) not found';
  end if;

  -- edit 1 of 5: new CTEs -- the identified-customer count and the shared evidence block
  v_count := (length(v_def) - length(replace(v_def, $zzv722vtag1zzz$  ), preference_rows as ($zzv722vtag1zzz$, ''))) / greatest(length($zzv722vtag2zzz$  ), preference_rows as ($zzv722vtag2zzz$), 1);
  if v_count <> 1 then
    raise exception 'v722: v94.cte anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $zzv722vtag3zzz$  ), preference_rows as ($zzv722vtag3zzz$, $zzv722vtag4zzz$  ), identified_n as (
    select count(*)::int as n from customer_metrics
  ), evidence_block as (
    select app.subgroup_evidence_v1(identified_n.n) as evidence,
      (app.subgroup_evidence_v1(identified_n.n)->>'status') = 'insufficient' as insufficient
    from identified_n
  ), preference_rows as ($zzv722vtag4zzz$);

  -- edit 2 of 5: kpis.average_order_cents goes null below the floor, plus evidence/status
  v_count := (length(v_expected) - length(replace(v_expected, $zzv722vtag5zzz$      'average_order_cents',coalesce((select round(avg(amount_cents))::bigint
        from valid_sales where counts_as_revenue),0)
    ),$zzv722vtag5zzz$, ''))) / greatest(length($zzv722vtag6zzz$      'average_order_cents',coalesce((select round(avg(amount_cents))::bigint
        from valid_sales where counts_as_revenue),0)
    ),$zzv722vtag6zzz$), 1);
  if v_count <> 1 then
    raise exception 'v722: v94.kpis anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_expected, $zzv722vtag7zzz$      'average_order_cents',coalesce((select round(avg(amount_cents))::bigint
        from valid_sales where counts_as_revenue),0)
    ),$zzv722vtag7zzz$, $zzv722vtag8zzz$      'average_order_cents',
        case when evidence_block.insufficient then null
        else coalesce((select round(avg(amount_cents))::bigint
          from valid_sales where counts_as_revenue),0) end,
      'evidence',evidence_block.evidence,
      'status',case when evidence_block.insufficient then 'unavailable' else 'ok' end
    ),$zzv722vtag8zzz$);

  -- edit 3 of 5: cohorts.evidence/status (counts stay -- nothing nulled)
  v_count := (length(v_expected) - length(replace(v_expected, $zzv722vtag9zzz$        'other',(select count(*) from classified where cohort='other')
      )
    ),$zzv722vtag9zzz$, ''))) / greatest(length($zzv722vtagAzzz$        'other',(select count(*) from classified where cohort='other')
      )
    ),$zzv722vtagAzzz$), 1);
  if v_count <> 1 then
    raise exception 'v722: v94.cohorts anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_expected, $zzv722vtagBzzz$        'other',(select count(*) from classified where cohort='other')
      )
    ),$zzv722vtagBzzz$, $zzv722vtagCzzz$        'other',(select count(*) from classified where cohort='other')
      ),
      'evidence',evidence_block.evidence,
      'status',case when evidence_block.insufficient then 'unavailable' else 'ok' end
    ),$zzv722vtagCzzz$);

  -- edit 4 of 5: customer_intelligence.top_customer_revenue_cents goes null below the floor,
  -- plus evidence/status (an identity-bearing field -- see migration header)
  v_count := (length(v_expected) - length(replace(v_expected, $zzv722vtagDzzz$      'top_customer_revenue_cents',coalesce((select max(revenue_cents)
        from customer_metrics),0)
    ),$zzv722vtagDzzz$, ''))) / greatest(length($zzv722vtagEzzz$      'top_customer_revenue_cents',coalesce((select max(revenue_cents)
        from customer_metrics),0)
    ),$zzv722vtagEzzz$), 1);
  if v_count <> 1 then
    raise exception 'v722: v94.customer_intelligence anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_expected, $zzv722vtagFzzz$      'top_customer_revenue_cents',coalesce((select max(revenue_cents)
        from customer_metrics),0)
    ),$zzv722vtagFzzz$, $zzv722vtagGzzz$      'top_customer_revenue_cents',
        case when evidence_block.insufficient then null
        else coalesce((select max(revenue_cents)
          from customer_metrics),0) end,
      'evidence',evidence_block.evidence,
      'status',case when evidence_block.insufficient then 'unavailable' else 'ok' end
    ),$zzv722vtagGzzz$);

  -- edit 5 of 5: bring evidence_block into scope
  v_count := (length(v_expected) - length(replace(v_expected, $zzv722vtagHzzz$  ) into v_result
  from public.businesses business cross join preferences
  where business.id=p_business;$zzv722vtagHzzz$, ''))) / greatest(length($zzv722vtagIzzz$  ) into v_result
  from public.businesses business cross join preferences
  where business.id=p_business;$zzv722vtagIzzz$), 1);
  if v_count <> 1 then
    raise exception 'v722: v94.from anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_expected, $zzv722vtagJzzz$  ) into v_result
  from public.businesses business cross join preferences
  where business.id=p_business;$zzv722vtagJzzz$, $zzv722vtagKzzz$  ) into v_result
  from public.businesses business cross join preferences cross join evidence_block
  where business.id=p_business;$zzv722vtagKzzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.platform_get_assigned_firm_report_v94(uuid,uuid,date,date)')) into v_after;

  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $zzv722vtagK2zzz$  ) into v_result
  from public.businesses business cross join preferences cross join evidence_block
  where business.id=p_business;$zzv722vtagK2zzz$, $zzv722vtagJ2zzz$  ) into v_result
  from public.businesses business cross join preferences
  where business.id=p_business;$zzv722vtagJ2zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv722vtagG2zzz$      'top_customer_revenue_cents',
        case when evidence_block.insufficient then null
        else coalesce((select max(revenue_cents)
          from customer_metrics),0) end,
      'evidence',evidence_block.evidence,
      'status',case when evidence_block.insufficient then 'unavailable' else 'ok' end
    ),$zzv722vtagG2zzz$, $zzv722vtagF2zzz$      'top_customer_revenue_cents',coalesce((select max(revenue_cents)
        from customer_metrics),0)
    ),$zzv722vtagF2zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv722vtagC2zzz$        'other',(select count(*) from classified where cohort='other')
      ),
      'evidence',evidence_block.evidence,
      'status',case when evidence_block.insufficient then 'unavailable' else 'ok' end
    ),$zzv722vtagC2zzz$, $zzv722vtagB2zzz$        'other',(select count(*) from classified where cohort='other')
      )
    ),$zzv722vtagB2zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv722vtag82zzz$      'average_order_cents',
        case when evidence_block.insufficient then null
        else coalesce((select round(avg(amount_cents))::bigint
          from valid_sales where counts_as_revenue),0) end,
      'evidence',evidence_block.evidence,
      'status',case when evidence_block.insufficient then 'unavailable' else 'ok' end
    ),$zzv722vtag82zzz$, $zzv722vtag72zzz$      'average_order_cents',coalesce((select round(avg(amount_cents))::bigint
        from valid_sales where counts_as_revenue),0)
    ),$zzv722vtag72zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv722vtag42zzz$  ), identified_n as (
    select count(*)::int as n from customer_metrics
  ), evidence_block as (
    select app.subgroup_evidence_v1(identified_n.n) as evidence,
      (app.subgroup_evidence_v1(identified_n.n)->>'status') = 'insufficient' as insufficient
    from identified_n
  ), preference_rows as ($zzv722vtag42zzz$, $zzv722vtag32zzz$  ), preference_rows as ($zzv722vtag32zzz$);

  if v_roundtrip <> v_def then
    raise exception
      'v722: public.platform_get_assigned_firm_report_v94 changed by more than the 5 intended edits. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end;
$patch_v94$;

revoke all on function public.platform_get_assigned_firm_report_v94(uuid,uuid,date,date) from public;
grant execute on function public.platform_get_assigned_firm_report_v94(uuid,uuid,date,date)
  to public, anon, authenticated, service_role;

-- -------------------------------------------------------------------------------------------
-- public.platform_customer_account_opens_v175 -- let an assigned consultant through
-- -------------------------------------------------------------------------------------------
do $patch_v175$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.platform_customer_account_opens_v175(uuid,date,date)')) into v_def;
  if v_def is null then
    raise exception 'v722: public.platform_customer_account_opens_v175(uuid,date,date) not found';
  end if;

  v_count := (length(v_def) - length(replace(v_def, $zzv722otag1zzz$  v_authorized:=
    app.v676_internal_drain_active()
    or app.is_super_admin()
    or app.has_perm(p_business,'view_finance')
    or (
      app.v89_can_access_business(p_business)
      and app.v89_platform_can('reports','r')
    );$zzv722otag1zzz$, ''))) / greatest(length($zzv722otag2zzz$  v_authorized:=
    app.v676_internal_drain_active()
    or app.is_super_admin()
    or app.has_perm(p_business,'view_finance')
    or (
      app.v89_can_access_business(p_business)
      and app.v89_platform_can('reports','r')
    );$zzv722otag2zzz$), 1);
  if v_count <> 1 then
    raise exception 'v722: v175.auth anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_expected := replace(v_def, $zzv722otag3zzz$  v_authorized:=
    app.v676_internal_drain_active()
    or app.is_super_admin()
    or app.has_perm(p_business,'view_finance')
    or (
      app.v89_can_access_business(p_business)
      and app.v89_platform_can('reports','r')
    );$zzv722otag3zzz$, $zzv722otag4zzz$  v_authorized:=
    app.v676_internal_drain_active()
    or app.is_super_admin()
    or app.has_perm(p_business,'view_finance')
    or app.v176_can_read_firm_report(p_business)
    or (
      app.v89_can_access_business(p_business)
      and app.v89_platform_can('reports','r')
    );$zzv722otag4zzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.platform_customer_account_opens_v175(uuid,date,date)')) into v_after;

  v_roundtrip := replace(v_after, $zzv722otag5zzz$  v_authorized:=
    app.v676_internal_drain_active()
    or app.is_super_admin()
    or app.has_perm(p_business,'view_finance')
    or app.v176_can_read_firm_report(p_business)
    or (
      app.v89_can_access_business(p_business)
      and app.v89_platform_can('reports','r')
    );$zzv722otag5zzz$, $zzv722otag6zzz$  v_authorized:=
    app.v676_internal_drain_active()
    or app.is_super_admin()
    or app.has_perm(p_business,'view_finance')
    or (
      app.v89_can_access_business(p_business)
      and app.v89_platform_can('reports','r')
    );$zzv722otag6zzz$);
  if v_roundtrip <> v_def then
    raise exception
      'v722: public.platform_customer_account_opens_v175 changed by more than the 1 intended edit. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end;
$patch_v175$;

-- v175's live grant surface, restated verbatim (v676's own restatement comment: "v175's live
-- surface, restated verbatim") -- only authenticated has execute, nobody else.
revoke all privileges on function public.platform_customer_account_opens_v175(uuid,date,date)
  from public, anon, authenticated, service_role;
grant execute on function public.platform_customer_account_opens_v175(uuid,date,date)
  to authenticated;

commit;
