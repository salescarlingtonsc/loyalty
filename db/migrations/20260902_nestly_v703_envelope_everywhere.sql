-- NESTLY v703 — the shared CI envelope (generated_at/as_of/period/exclusions/trace_id) reaches
-- four readers that v680 (envelope) and v683 (floor gate) never touched, and
-- get_ci_retention_windows_v1's per-cohort per-horizon rate stops leaking a rate below the
-- evidence floor. Closes acceptance checks 16 (exclusion counts travel with every payload,
-- applied to the last stragglers) and 61 (a rate travels with the evidence that backs it, no
-- exceptions) of docs/qa/CI-100-CHECKLIST.md.
--
-- Reads docs/qa/CI-CORPUS-FIXTURE-GUIDE.md, docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md (v672,
-- frozen), db/migrations/20260902_nestly_v680_ci_envelope.sql (app.ci_envelope_v680's call shape,
-- and get_ci_daypart_v1's use of it as replayed by v693), and v693's retention-windows body,
-- which computes each cohort's per-horizon rate as a bare `app.rate_block_v1(returned_n, n)` —
-- never gated on that cohort's own `app.subgroup_evidence_v1(n)` — the exact gap this migration
-- closes with `app.rate_block_floor_gated_v683`, already proven correct and shipped by v683
-- (staff/rebooking) for a different reader.
--
-- FUNCTIONS TOUCHED (five, all named in the task brief; no others):
--   public.get_ci_contactability_v1   — envelope + p_as_of added (was: no period at all; a live
--                                        consent snapshot has no natural [from,to], so period is
--                                        the whole history to date: ['-infinity', as_of's SGT date]).
--   public.get_ci_engagement_v1       — envelope + p_as_of added (period = the reader's own
--                                        trailing p_months window, [this_month - months, today],
--                                        and now() swapped for p_as_of throughout so the envelope's
--                                        as_of is not a decoration over a still-live now()).
--   public.get_ci_funnel_v1           — envelope + p_as_of added (period = the caller's own
--                                        [p_from,p_to], unchanged; day <= as_of added to the
--                                        counter scan for snapshot honesty).
--   public.get_ci_marketing_funnel_v1 — envelope + p_as_of added (period = the caller's own
--                                        [p_from,p_to]; now() swapped for p_as_of for the
--                                        maturity threshold).
--   public.get_ci_retention_windows_v1 — NO signature change (already envelope-wrapped by v680);
--                                        one internal call site changed: the per-cohort
--                                        per-horizon rate is now floor-gated on that cohort's own
--                                        n, so a cohort below the evidence floor keeps its counts
--                                        and loses only the derived pct.
--
-- NOT touched, on purpose (siblings own these; re-emitting them here would race a concurrent
-- migration and misattribute the fix): get_ci_daypart_v1 (v698), get_ci_service_intelligence_v1
-- (v697), get_ci_opportunities_v1 (v696), get_ci_discovery_*_v1 (v702), every staff_*/discount/
-- loyalty/rebooking reader (v699/v700), validate.mjs, app/.
--
-- IS EVERY READER NAMED HERE A POPULATION READER? Yes, all five. get_ci_contactability_v1 counts
-- real (non-synthetic, non-erased) customers by consent; get_ci_engagement_v1 counts real
-- customer events; get_ci_funnel_v1 and get_ci_marketing_funnel_v1 both already call
-- app.ci_access_gate_v667 and describe a real transaction/campaign population (funnel counters
-- and campaign sends respectively) even though get_ci_funnel_v1's own numbers come from a
-- separate counters table — the exclusions attached to its envelope still describe the SAME
-- business's sales population over the SAME window, which is the shared contract every CI reader
-- carries per CI-STAT-AUTHORITY-CONTRACT.md convention 3. None of the five returns pure metadata
-- (a capability list, a schema descriptor, etc.), so none is excluded from this migration.
--
-- CALLERS GREPPED (app/, supabase/, db/migrations/) before adding the trailing p_as_of, so the
-- default keeps every one of them working unchanged:
--   get_ci_contactability_v1 — app/app.js:49726 and app/app-business.js:31654, both
--     `sb.rpc('get_ci_contactability_v1', {p_business:...})` (named args, no p_branch/p_as_of);
--     db/migrations/20260902_nestly_v678_consultant_spine.sql:787 and
--     20260902_nestly_v688_consultant_spine_v2.sql:786,
--     `public.get_ci_contactability_v1(p_business, null)` (2 positional args). A trailing default
--     parameter is invisible to every one of these.
--   get_ci_funnel_v1 — app/app.js:49725 and app/app-business.js:31653,
--     `sb.rpc('get_ci_funnel_v1', {p_business:..., p_from:..., p_to:...})` (named args, no
--     p_branch/p_as_of). Unaffected.
--   get_ci_engagement_v1 — no live caller (app/app.js:49297 / app-business.js:31244 record it as
--     "deliberately NOT wired here"). No caller to break.
--   get_ci_marketing_funnel_v1 — no caller anywhere in app/ or supabase/ (introduced by v683,
--     unwired). No caller to break.
--   get_ci_retention_windows_v1 — signature unchanged, so this question does not apply; no live
--     UI/RPC caller found either way.
--
-- METHOD: extract-and-diff replace-equality, the same discipline as v668/v690/v695/v698 — every
-- "old" fragment below is asserted to occur EXACTLY ONCE in the LIVE pg_get_functiondef captured
-- at apply time (never hand-retyped from memory), the patched text is executed as-is, and the
-- result is proven to differ from the original by exactly the listed substitutions via a reverse
-- replace back to the live original. A drift in the live body (a concurrent migration changing
-- the same function first) fails loudly instead of silently clobbering someone else's edit.
--
-- Proven by db/tests/executed/v703_corpus_envelope_everywhere.sql.

\set ON_ERROR_STOP on
begin;

-- =================================================================================================
-- 1 · get_ci_contactability_v1(uuid,uuid) -> (uuid,uuid,timestamptz)
-- =================================================================================================
do $patch_contactability$
declare
  v_def text;

  v_anchor_sig constant text :=
    'CREATE OR REPLACE FUNCTION public.get_ci_contactability_v1(p_business uuid, p_branch uuid DEFAULT NULL::uuid)';
  v_new_sig constant text :=
    'CREATE OR REPLACE FUNCTION public.get_ci_contactability_v1(p_business uuid, p_branch uuid DEFAULT NULL::uuid, p_as_of timestamp with time zone DEFAULT clock_timestamp())';

  v_anchor_body constant text := 'AS $function$
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_no_branch_dimension_v667(p_branch, ''contactability'');
  return jsonb_build_object(
    ''business_offers'', app.contactable_counts_v1(p_business, ''business_offers''),
    ''rewards_and_points'', app.contactable_counts_v1(p_business, ''rewards_and_points''),
    ''note'', ''A customer counts only with an affirmative recorded consent for the channel; nobody is grandfathered.'');
end;
$function$';
  v_new_body constant text := 'AS $function$
declare
  v_today date := (p_as_of at time zone ''Asia/Singapore'')::date;
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_no_branch_dimension_v667(p_branch, ''contactability'');
  v_result := jsonb_build_object(
    ''business_offers'', app.contactable_counts_v1(p_business, ''business_offers''),
    ''rewards_and_points'', app.contactable_counts_v1(p_business, ''rewards_and_points''),
    ''note'', ''A customer counts only with an affirmative recorded consent for the channel; nobody is grandfathered.'');
  return app.ci_envelope_v680(''ci_contactability_v1'', p_business, p_branch, ''-infinity''::date, v_today,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, ''-infinity''::date, v_today, p_as_of), v_result);
end;
$function$';

  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_contactability_v1(uuid,uuid)')) into v_def;
  if v_def is null then raise exception 'v703: public.get_ci_contactability_v1(uuid,uuid) not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_sig, ''))) / length(v_anchor_sig);
  if v_count <> 1 then
    raise exception 'v703: contactability signature anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_body, ''))) / length(v_anchor_body);
  if v_count <> 1 then
    raise exception 'v703: contactability body anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_sig, v_new_sig);
  v_expected := replace(v_expected, v_anchor_body, v_new_body);

  drop function public.get_ci_contactability_v1(uuid,uuid);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_contactability_v1(uuid,uuid,timestamptz)')) into v_after;
  if v_after is null then raise exception 'v703: get_ci_contactability_v1(uuid,uuid,timestamptz) did not get created'; end if;

  v_roundtrip := replace(v_after, v_new_sig, v_anchor_sig);
  v_roundtrip := replace(v_roundtrip, v_new_body, v_anchor_body);
  if v_roundtrip <> v_def then
    raise exception
      'v703: get_ci_contactability_v1 changed by more than the two intended edits. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_contactability$;
revoke all on function public.get_ci_contactability_v1(uuid,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_contactability_v1(uuid,uuid,timestamptz) to authenticated, service_role;

-- =================================================================================================
-- 2 · get_ci_engagement_v1(uuid,integer,uuid) -> (uuid,integer,uuid,timestamptz)
-- =================================================================================================
do $patch_engagement$
declare
  v_def text;

  v_anchor_sig constant text :=
    'CREATE OR REPLACE FUNCTION public.get_ci_engagement_v1(p_business uuid, p_months integer DEFAULT 12, p_branch uuid DEFAULT NULL::uuid)';
  v_new_sig constant text :=
    'CREATE OR REPLACE FUNCTION public.get_ci_engagement_v1(p_business uuid, p_months integer DEFAULT 12, p_branch uuid DEFAULT NULL::uuid, p_as_of timestamp with time zone DEFAULT clock_timestamp())';

  v_anchor_preamble constant text := 'declare
  v_hist jsonb; v_current jsonb;
  v_this_month date := date_trunc(''month'', now() at time zone ''Asia/Singapore'')::date;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_no_branch_dimension_v667(p_branch, ''engagement'');';
  v_new_preamble constant text := 'declare
  v_hist jsonb; v_current jsonb;
  v_this_month date := date_trunc(''month'', p_as_of at time zone ''Asia/Singapore'')::date;
  v_today date := (p_as_of at time zone ''Asia/Singapore'')::date;
  v_from date := v_this_month - make_interval(months => greatest(1, least(coalesce(p_months,12), 36)));
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_no_branch_dimension_v667(p_branch, ''engagement'');';

  v_anchor_rollup_bound constant text :=
    '     and r.month >= (v_this_month - make_interval(months => greatest(1, least(coalesce(p_months,12), 36))));';
  v_new_rollup_bound constant text :=
    '     and r.month >= (v_this_month - make_interval(months => greatest(1, least(coalesce(p_months,12), 36))))
     and r.month <= v_this_month;';

  v_anchor_current_cutoff constant text :=
    '             and (occurred_at at time zone ''Asia/Singapore'')::date >= v_this_month';
  v_new_current_cutoff constant text :=
    '             and (occurred_at at time zone ''Asia/Singapore'')::date >= v_this_month
             and (occurred_at at time zone ''Asia/Singapore'') <= p_as_of';

  v_anchor_return constant text := '  return jsonb_build_object(''months'', v_hist, ''current_month'', v_current,
    ''observed_since'', app.metric_observed_since_v1(''engagement_rollups'', p_business));
end;
$function$';
  v_new_return constant text := '  v_result := jsonb_build_object(''months'', v_hist, ''current_month'', v_current,
    ''observed_since'', app.metric_observed_since_v1(''engagement_rollups'', p_business));
  return app.ci_envelope_v680(''ci_engagement_v1'', p_business, p_branch, v_from, v_today,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, v_from, v_today, p_as_of), v_result);
end;
$function$';

  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_engagement_v1(uuid,integer,uuid)')) into v_def;
  if v_def is null then raise exception 'v703: public.get_ci_engagement_v1(uuid,integer,uuid) not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_sig, ''))) / length(v_anchor_sig);
  if v_count <> 1 then
    raise exception 'v703: engagement signature anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_preamble, ''))) / length(v_anchor_preamble);
  if v_count <> 1 then
    raise exception 'v703: engagement preamble anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_rollup_bound, ''))) / length(v_anchor_rollup_bound);
  if v_count <> 1 then
    raise exception 'v703: engagement rollup-bound anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_current_cutoff, ''))) / length(v_anchor_current_cutoff);
  if v_count <> 1 then
    raise exception 'v703: engagement current-cutoff anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_return, ''))) / length(v_anchor_return);
  if v_count <> 1 then
    raise exception 'v703: engagement return anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_sig, v_new_sig);
  v_expected := replace(v_expected, v_anchor_preamble, v_new_preamble);
  v_expected := replace(v_expected, v_anchor_rollup_bound, v_new_rollup_bound);
  v_expected := replace(v_expected, v_anchor_current_cutoff, v_new_current_cutoff);
  v_expected := replace(v_expected, v_anchor_return, v_new_return);

  drop function public.get_ci_engagement_v1(uuid,integer,uuid);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_engagement_v1(uuid,integer,uuid,timestamptz)')) into v_after;
  if v_after is null then raise exception 'v703: get_ci_engagement_v1(uuid,integer,uuid,timestamptz) did not get created'; end if;

  v_roundtrip := replace(v_after, v_new_sig, v_anchor_sig);
  v_roundtrip := replace(v_roundtrip, v_new_preamble, v_anchor_preamble);
  v_roundtrip := replace(v_roundtrip, v_new_rollup_bound, v_anchor_rollup_bound);
  v_roundtrip := replace(v_roundtrip, v_new_current_cutoff, v_anchor_current_cutoff);
  v_roundtrip := replace(v_roundtrip, v_new_return, v_anchor_return);
  if v_roundtrip <> v_def then
    raise exception
      'v703: get_ci_engagement_v1 changed by more than the five intended edits. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_engagement$;
revoke all on function public.get_ci_engagement_v1(uuid,integer,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_engagement_v1(uuid,integer,uuid,timestamptz) to authenticated, service_role;

-- =================================================================================================
-- 3 · get_ci_funnel_v1(uuid,date,date,uuid) -> (uuid,date,date,uuid,timestamptz)
-- =================================================================================================
do $patch_funnel$
declare
  v_def text;

  v_anchor_sig constant text :=
    'CREATE OR REPLACE FUNCTION public.get_ci_funnel_v1(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid)';
  v_new_sig constant text :=
    'CREATE OR REPLACE FUNCTION public.get_ci_funnel_v1(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid, p_as_of timestamp with time zone DEFAULT clock_timestamp())';

  v_anchor_declare constant text := 'declare v_rows jsonb;';
  v_new_declare constant text := 'declare v_rows jsonb; v_result jsonb;';

  v_anchor_where constant text :=
    '               where business_id = p_business and day between p_from and p_to';
  v_new_where constant text :=
    '               where business_id = p_business and day between p_from and p_to
                 and day <= (p_as_of at time zone ''Asia/Singapore'')::date';

  v_anchor_return constant text := '  return jsonb_build_object(''funnel'', v_rows,
    ''observed_since'', app.metric_observed_since_v1(''public_funnel_counters'', p_business));
end;
$function$';
  v_new_return constant text := '  v_result := jsonb_build_object(''funnel'', v_rows,
    ''observed_since'', app.metric_observed_since_v1(''public_funnel_counters'', p_business));
  return app.ci_envelope_v680(''ci_funnel_v1'', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$function$';

  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_funnel_v1(uuid,date,date,uuid)')) into v_def;
  if v_def is null then raise exception 'v703: public.get_ci_funnel_v1(uuid,date,date,uuid) not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_sig, ''))) / length(v_anchor_sig);
  if v_count <> 1 then
    raise exception 'v703: funnel signature anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_declare, ''))) / length(v_anchor_declare);
  if v_count <> 1 then
    raise exception 'v703: funnel declare anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_where, ''))) / length(v_anchor_where);
  if v_count <> 1 then
    raise exception 'v703: funnel where anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_return, ''))) / length(v_anchor_return);
  if v_count <> 1 then
    raise exception 'v703: funnel return anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_sig, v_new_sig);
  v_expected := replace(v_expected, v_anchor_declare, v_new_declare);
  v_expected := replace(v_expected, v_anchor_where, v_new_where);
  v_expected := replace(v_expected, v_anchor_return, v_new_return);

  drop function public.get_ci_funnel_v1(uuid,date,date,uuid);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_funnel_v1(uuid,date,date,uuid,timestamptz)')) into v_after;
  if v_after is null then raise exception 'v703: get_ci_funnel_v1(uuid,date,date,uuid,timestamptz) did not get created'; end if;

  v_roundtrip := replace(v_after, v_new_sig, v_anchor_sig);
  v_roundtrip := replace(v_roundtrip, v_new_declare, v_anchor_declare);
  v_roundtrip := replace(v_roundtrip, v_new_where, v_anchor_where);
  v_roundtrip := replace(v_roundtrip, v_new_return, v_anchor_return);
  if v_roundtrip <> v_def then
    raise exception
      'v703: get_ci_funnel_v1 changed by more than the four intended edits. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_funnel$;
revoke all on function public.get_ci_funnel_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_funnel_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- =================================================================================================
-- 4 · get_ci_marketing_funnel_v1(uuid,date,date,uuid) -> (uuid,date,date,uuid,timestamptz)
-- =================================================================================================
do $patch_marketing_funnel$
declare
  v_def text;

  v_anchor_sig constant text :=
    'CREATE OR REPLACE FUNCTION public.get_ci_marketing_funnel_v1(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid)';
  v_new_sig constant text :=
    'CREATE OR REPLACE FUNCTION public.get_ci_marketing_funnel_v1(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid, p_as_of timestamp with time zone DEFAULT clock_timestamp())';

  v_anchor_declare constant text := 'declare
  v_sent integer;
  v_sent_in_app integer;
  v_read_in_app integer;
  v_mature integer;
  v_returned integer;
  v_incremental jsonb;
  v_not_observed constant jsonb := jsonb_build_object(''status'', ''not_observed'');
  v_today date := (now() at time zone ''Asia/Singapore'')::date;
begin';
  v_new_declare constant text := 'declare
  v_sent integer;
  v_sent_in_app integer;
  v_read_in_app integer;
  v_mature integer;
  v_returned integer;
  v_incremental jsonb;
  v_result jsonb;
  v_not_observed constant jsonb := jsonb_build_object(''status'', ''not_observed'');
  v_today date := (p_as_of at time zone ''Asia/Singapore'')::date;
begin';

  v_anchor_return constant text := '  return jsonb_build_object(
    ''scope'', jsonb_build_object(''business_id'', p_business, ''from'', p_from, ''to'', p_to),
    ''time_basis'', ''send_occurred_at'',
    ''stages'', jsonb_build_object(
      ''contacted'', v_not_observed,
      ''queued'', v_not_observed,
      ''sent'', jsonb_build_object(''status'', ''ok'', ''count'', v_sent),
      ''delivered'', v_not_observed,
      ''read'', jsonb_build_object(''status'', ''ok'', ''scope'', ''in_app channel only'',
                ''evidence'', app.subgroup_evidence_v1(v_sent_in_app),
                ''rate'', app.rate_block_floor_gated_v683(v_read_in_app, v_sent_in_app,
                          app.subgroup_evidence_v1(v_sent_in_app))),
      ''replied'', v_not_observed,
      ''redeemed'', v_not_observed,
      ''associated_purchase'', jsonb_build_object(''status'', ''ok'',
                ''immature'', v_sent - v_mature,
                ''evidence'', app.subgroup_evidence_v1(v_mature),
                ''rate'', app.rate_block_floor_gated_v683(v_returned, v_mature,
                          app.subgroup_evidence_v1(v_mature)))),
    ''incremental'', v_incremental);
end;
$function$';
  v_new_return constant text := '  v_result := jsonb_build_object(
    ''scope'', jsonb_build_object(''business_id'', p_business, ''from'', p_from, ''to'', p_to),
    ''time_basis'', ''send_occurred_at'',
    ''stages'', jsonb_build_object(
      ''contacted'', v_not_observed,
      ''queued'', v_not_observed,
      ''sent'', jsonb_build_object(''status'', ''ok'', ''count'', v_sent),
      ''delivered'', v_not_observed,
      ''read'', jsonb_build_object(''status'', ''ok'', ''scope'', ''in_app channel only'',
                ''evidence'', app.subgroup_evidence_v1(v_sent_in_app),
                ''rate'', app.rate_block_floor_gated_v683(v_read_in_app, v_sent_in_app,
                          app.subgroup_evidence_v1(v_sent_in_app))),
      ''replied'', v_not_observed,
      ''redeemed'', v_not_observed,
      ''associated_purchase'', jsonb_build_object(''status'', ''ok'',
                ''immature'', v_sent - v_mature,
                ''evidence'', app.subgroup_evidence_v1(v_mature),
                ''rate'', app.rate_block_floor_gated_v683(v_returned, v_mature,
                          app.subgroup_evidence_v1(v_mature)))),
    ''incremental'', v_incremental);
  return app.ci_envelope_v680(''ci_marketing_funnel_v1'', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$function$';

  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('public.get_ci_marketing_funnel_v1(uuid,date,date,uuid)')) into v_def;
  if v_def is null then raise exception 'v703: public.get_ci_marketing_funnel_v1(uuid,date,date,uuid) not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_sig, ''))) / length(v_anchor_sig);
  if v_count <> 1 then
    raise exception 'v703: marketing-funnel signature anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_declare, ''))) / length(v_anchor_declare);
  if v_count <> 1 then
    raise exception 'v703: marketing-funnel declare anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_return, ''))) / length(v_anchor_return);
  if v_count <> 1 then
    raise exception 'v703: marketing-funnel return anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_sig, v_new_sig);
  v_expected := replace(v_expected, v_anchor_declare, v_new_declare);
  v_expected := replace(v_expected, v_anchor_return, v_new_return);

  drop function public.get_ci_marketing_funnel_v1(uuid,date,date,uuid);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_ci_marketing_funnel_v1(uuid,date,date,uuid,timestamptz)')) into v_after;
  if v_after is null then raise exception 'v703: get_ci_marketing_funnel_v1(uuid,date,date,uuid,timestamptz) did not get created'; end if;

  v_roundtrip := replace(v_after, v_new_sig, v_anchor_sig);
  v_roundtrip := replace(v_roundtrip, v_new_declare, v_anchor_declare);
  v_roundtrip := replace(v_roundtrip, v_new_return, v_anchor_return);
  if v_roundtrip <> v_def then
    raise exception
      'v703: get_ci_marketing_funnel_v1 changed by more than the three intended edits. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_marketing_funnel$;
revoke all on function public.get_ci_marketing_funnel_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_marketing_funnel_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- =================================================================================================
-- 5 · get_ci_retention_windows_v1 — floor-gate the per-cohort per-horizon rate (check 61). Same
--    signature throughout (uuid,date,date,uuid,timestamptz) — a plain in-place patch, no drop.
-- =================================================================================================
do $patch_retention_floor$
declare
  v_def text;

  v_anchor constant text := '      select cohort_month, n,
             coalesce(jsonb_object_agg(horizon::text, app.rate_block_v1(returned_n, n))
                      filter (where is_mature), ''{}''::jsonb) as windows
        from cells
       group by cohort_month, n
    ) x;';
  v_new constant text := '      select cohort_month, n,
             coalesce(jsonb_object_agg(horizon::text,
                        app.rate_block_floor_gated_v683(returned_n, n, app.subgroup_evidence_v1(n::int)))
                      filter (where is_mature), ''{}''::jsonb) as windows
        from cells
       group by cohort_month, n
    ) x;';

  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then
    raise exception 'v703: public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz) not found';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_count <> 1 then
    raise exception 'v703: retention-windows floor-gate anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor, v_new);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, v_new, v_anchor);
  if v_roundtrip <> v_def then
    raise exception
      'v703: get_ci_retention_windows_v1 changed by more than the one intended edit. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_retention_floor$;
-- ACL restated verbatim from the live proacl (unchanged by this migration — same argument list).
revoke all on function public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_retention_windows_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

commit;
