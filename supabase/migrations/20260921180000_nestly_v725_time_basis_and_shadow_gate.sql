-- NESTLY v725 -- time basis on the three Customer Intelligence readers check 35/13 left
-- uncovered by nestly_v717, and one shared-gate + platform-diagnostic tightening for
-- get_ci_shadow_reconciliation_v685 (check 91).
--
-- ============================================================================================
-- CHECK 35/13 -- every time-derived Customer Intelligence payload carries a top-level
-- `time_basis` key naming the real timestamp column its bucketing reads (the frozen contract,
-- docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md convention 2). nestly_v717 covered five readers
-- plus get_ci_demographic_cohort_v1's dead-nested-copy fix; the refuter's follow-up pass found
-- three more surfaces v717 did not touch:
--
--   * public.get_customer_intelligence_v83       -- every period/lifetime CTE in this function
--     (period_sales, valid_period_purchases, valid_period_visits, valid_lifetime_purchases,
--     the forecast history/active-week/cash windows) filters and buckets on `sale.occurred_at`
--     (and app.ci_visit_day_v699(sale.occurred_at) for the visit-day count) -- read from the
--     live body, not guessed -> 'sale_occurred_at'. Added as a top-level key, sibling to
--     'scope', where every other v717 reader added it; this reader does not return through
--     app.ci_envelope_v680 at all (it builds its own top-level jsonb_build_object), so there is
--     no envelope `||` to worry about overwriting it, unlike v717's demographic-cohort case.
--
--   * public.get_ci_category_customers_v1        -- the customer list is windowed on
--     `(s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to` and visits
--     are counted via app.ci_visit_day_v699(s.occurred_at) -- same column, same answer ->
--     'sale_occurred_at'. This reader returns through app.ci_envelope_v680 (v680), which -- per
--     v717's own header -- only overwrites 'period'/'generated_at'/'as_of'/'exclusions'/
--     'trace_id'/'freshness' via `p_payload || jsonb_build_object(...)`; 'time_basis' is not one
--     of those keys, so a top-level key added to the reader's own p_payload survives untouched,
--     exactly as it does for the five v717 readers that also envelope. TWO payload sites need
--     the edit, not one: the small-cell-suppressed early return and the normal return both build
--     their own jsonb_build_object literal (the suppression check runs AFTER the cohort is
--     already computed on the same time basis, so both paths describe the same window).
--
--   * public.get_ci_shadow_reconciliation_v685    -- does NOT bucket on a sale timestamp at all
--     (it is a point-in-time reconciliation of one captured shadow run against an independently
--     recomputed oracle, not a windowed metric); the frozen contract's `time_basis` key is a
--     disclosure of "what timestamp column would you need to trust to trust this payload", and
--     for this reader that is app.ci_shadow_runs_v685.captured_at -- the moment the run's
--     `payload` (get_revenue_truth_v106) was frozen -- not `sale.occurred_at`, `s.created_at`,
--     or the run's own `window_from`/`window_to` (those are captured separately in the 'window'
--     key already returned). Read from the live schema (`\d app.ci_shadow_runs_v685`), not
--     assumed: 'captured_at' is a real, NOT NULL column with a genuine default
--     (clock_timestamp()), so this is the 'captured_at' branch of the check-35/13 instruction,
--     not the 'not_applicable' one -- there IS a real time dimension here, it is just not a
--     bucketing window like the other six readers'.
--
-- EXEMPT, recorded rather than touched: public.get_ci_dictionary_v1 (v684) returns
-- app.ci_metric_dictionary_v1() -- a static catalogue of metric names/definitions with no
-- historical rows, no window arguments, and no time-derived value anywhere in its payload. It
-- has no time dimension to disclose, so it carries no `time_basis` key and none is added here.
--
-- ============================================================================================
-- CHECK 91 (continuation) -- get_ci_shadow_reconciliation_v685 carries its own inline
-- `app.is_super_admin()` gate instead of the shared authority every other Customer Intelligence
-- reader defers to (app.ci_access_gate_v667, nestly_v667/v689/v721). Left as its own private
-- check, this reader is the one CI surface whose access rule cannot be read off the shared
-- gate's own header/tests -- exactly the "one capability, two gates" shape check 91 exists to
-- close for public.get_customer_intelligence_v83 in nestly_v721.
--
-- THE FIX IS NOT "replace the gate with the shared one" -- that would OVER-admit. This reader is
-- an SA-only ops diagnostic: it recomputes a firm's revenue independently and compares it byte-
-- for-byte against a frozen shadow-run capture, which is a platform correctness check on the CI
-- pipeline itself, not a firm-facing report. The shared gate's platform arm
-- (app.v176_can_read_firm_report: super admin OR the firm's assigned consultant) would let the
-- assigned consultant in -- correct for every OTHER CI reader they legitimately use for their
-- firm, wrong here, where the caller is auditing the pipeline that produces the consultant's own
-- reports, not reading one of them. So the fix is additive: call the shared gate FIRST (joining
-- this reader to the one-authority discipline the header names, and inheriting its business/
-- branch-scoped checks and refusal wording for the family of callers it already screens out),
-- THEN keep `app.is_super_admin()` as a SECOND, narrower condition evaluated after it -- passing
-- the shared gate is necessary but not sufficient for this one reader. A super admin already
-- satisfies the shared gate's platform arm (app.v176_can_read_firm_report includes
-- app.is_super_admin() directly), so this changes nothing for the population this reader is
-- actually meant to serve; it only makes the shared gate the FIRST word (for uniformity with
-- every sibling reader; a caller with no path to CI at all now gets the shared gate's
-- 'customer intelligence access is required' before ever reaching the SA-only check) while
-- is_super_admin() remains the LAST word (so the platform arm's second member, the assigned
-- consultant, is still refused here specifically).
--
-- p_branch is passed as null, never p_business's own branch concept applied here -- this reader
-- takes no p_branch argument at all (it operates on a whole captured shadow run, which is
-- itself business-scoped, not branch-scoped); null is the only value app.ci_access_gate_v667's
-- second argument can take for a caller with no branch to name.
--
-- ============================================================================================
-- WHAT THIS MIGRATION DOES NOT TOUCH. app.v176_evidence_pack / app.v176_gated_evidence /
-- app.ci_access_gate_v667's own body (nestly_v720 is in flight on the former in a sibling
-- session; the latter is not edited here at all -- get_ci_shadow_reconciliation_v685 gains a NEW
-- call into it, the gate's own body is untouched). ci_access_gate_v667(uuid,uuid)'s signature,
-- ACL and internal logic are exactly as nestly_v721 left them. No other CI reader
-- (get_ci_category_mix_v1, get_ci_acquisition_v1, get_ci_funnel_v1, get_ci_contactability_v1,
-- get_ci_engagement_v1, get_ci_demographic_cohort_v1, get_ci_daypart_v1, get_ci_discovery_v1,
-- get_ci_opportunities_v1) is edited.
--
-- ANCHORED EXTRACT-AND-DIFF, the pattern established by v668/v689/v713/v714/v717/v720/v721:
-- every edit below captures the LIVE pg_get_functiondef text, asserts its anchor occurs EXACTLY
-- ONCE, executes the literal modified DDL, then re-captures the new definition and asserts that
-- reversing the substitution reproduces the original byte-for-byte.
--
-- PROVEN BY: db/tests/executed/v725_corpus_time_basis_shadow_gate.sql.
--
-- ROLLBACK: reverse each anchored substitution below (drop the 'time_basis' keys; for
-- get_ci_shadow_reconciliation_v685, drop the `perform app.ci_access_gate_v667(p_business,
-- null);` line and restore the bare `app.is_super_admin()` check as the only gate).

begin;

-- ============================================================================================
-- 1 * public.get_customer_intelligence_v83 -- top-level time_basis, sibling to 'scope'.
-- ============================================================================================
do $v725_v83$
declare
  v_def       text;
  v_after     text;
  v_roundtrip text;
  v_count     integer;
  v_anchor constant text := $anc83$    'generated_at',v_snapshot_at,
    'snapshot_at',v_snapshot_at,
    'scope',jsonb_build_object($anc83$;
  v_new_text constant text := $new83$    'generated_at',v_snapshot_at,
    'snapshot_at',v_snapshot_at,
    'time_basis','sale_occurred_at',
    'scope',jsonb_build_object($new83$;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid)'
  )) into v_def;
  if v_def is null then
    raise exception 'v725: public.get_customer_intelligence_v83(...) not found';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / greatest(length(v_anchor), 1);
  if v_count <> 1 then
    raise exception 'v725: v83 scope anchor occurs % times (expected 1) -- live body drifted '
      'from what this migration expects (re-extract with pg_get_functiondef)', v_count;
  end if;

  execute replace(v_def, v_anchor, v_new_text);

  select pg_get_functiondef(to_regprocedure(
    'public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid)'
  )) into v_after;
  v_roundtrip := replace(v_after, v_new_text, v_anchor);
  if v_roundtrip <> v_def then
    raise exception 'v725: get_customer_intelligence_v83 changed by more than the intended '
      'time_basis insertion'
      using detail = 'intended:' || E'\n' || v_def || E'\n' || 'actual (reversed):' || E'\n' || v_roundtrip;
  end if;
  if position($$'time_basis','sale_occurred_at'$$ in v_after) = 0 then
    raise exception 'v725: v83 time_basis did not land';
  end if;
end
$v725_v83$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument
-- list, same grantees v714 left it with; NOT narrowed here).
revoke all on function public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid) from public;
grant execute on function public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid) to anon, authenticated, service_role;

-- ============================================================================================
-- 2 * public.get_ci_category_customers_v1 -- top-level time_basis in BOTH payload sites (the
--     small-cell-suppressed early return and the normal return), sibling to 'node_key'.
-- ============================================================================================
do $v725_catcust$
declare
  v_def       text;
  v_mid       text;
  v_new       text;
  v_after     text;
  v_roundtrip text;
  v_count     integer;
  -- Site A: the suppressed-cohort return, 6-space indent (nested inside the if-block).
  v_anchor_a constant text := $ancA$      'node_key', p_node_key,
      'visit_definition',$ancA$;
  v_new_a    constant text := $newA$      'node_key', p_node_key,
      'time_basis', 'sale_occurred_at',
      'visit_definition',$newA$;
  -- Site B: the normal return, 4-space indent (top-level in the function body).
  v_anchor_b constant text := $ancB$    'node_key', p_node_key,
    'visit_definition',$ancB$;
  v_new_b    constant text := $newB$    'node_key', p_node_key,
    'time_basis', 'sale_occurred_at',
    'visit_definition',$newB$;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz)'
  )) into v_def;
  if v_def is null then
    raise exception 'v725: public.get_ci_category_customers_v1(...) not found';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_a, ''))) / greatest(length(v_anchor_a), 1);
  if v_count <> 1 then
    raise exception 'v725: category_customers site A anchor occurs % times (expected 1) -- '
      'live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_b, ''))) / greatest(length(v_anchor_b), 1);
  if v_count <> 1 then
    raise exception 'v725: category_customers site B anchor occurs % times (expected 1) -- '
      'live body drifted', v_count;
  end if;

  v_mid := replace(v_def, v_anchor_a, v_new_a);
  v_new := replace(v_mid, v_anchor_b, v_new_b);
  execute v_new;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz)'
  )) into v_after;
  v_roundtrip := replace(replace(v_after, v_new_b, v_anchor_b), v_new_a, v_anchor_a);
  if v_roundtrip <> v_def then
    raise exception 'v725: get_ci_category_customers_v1 changed by more than the two intended '
      'time_basis insertions'
      using detail = 'intended:' || E'\n' || v_def || E'\n' || 'actual (reversed):' || E'\n' || v_roundtrip;
  end if;
  if (length(v_after) - length(replace(v_after, $$'time_basis', 'sale_occurred_at'$$, '')))
       / greatest(length($$'time_basis', 'sale_occurred_at'$$), 1) <> 2 then
    raise exception 'v725: category_customers time_basis did not land in both payload sites';
  end if;
end
$v725_catcust$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument
-- list).
revoke all on function public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz) to authenticated, service_role;

-- ============================================================================================
-- 3 * public.get_ci_shadow_reconciliation_v685 -- (a) the shared gate joins, as-is-not-sufficient,
--     ahead of the existing SA-only check; (b) top-level time_basis, sibling to 'window'.
-- ============================================================================================
do $v725_shadow$
declare
  v_def       text;
  v_mid       text;
  v_new       text;
  v_after     text;
  v_roundtrip text;
  v_count     integer;
  -- Patch 1: the shared CI gate joins ahead of the existing SA-only check (check 91).
  v_anchor_gate constant text := $ancg$  -- Same refusal convention as every other super-admin-only RPC in this codebase (v66/v79/v86/
  -- v147): anyone who is not a super admin gets 42501, no partial data, no different message.
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode = '42501';
  end if;$ancg$;
  v_new_gate constant text := $newg$  -- Same refusal convention as every other super-admin-only RPC in this codebase (v66/v79/v86/
  -- v147): anyone who is not a super admin gets 42501, no partial data, no different message.
  -- This reader now ALSO calls the shared Customer Intelligence gate
  -- (app.ci_access_gate_v667), the single authority every other CI reader defers to, instead of
  -- carrying only its own hand-rolled entitlement check in isolation -- one authority, not two.
  -- The shared gate's platform arm (app.v176_can_read_firm_report: super admin OR the firm's
  -- assigned consultant) is DELIBERATELY not sufficient on its own here: this reconciliation
  -- compares a captured shadow-run payload against an independently recomputed oracle -- an
  -- SA-only ops diagnostic auditing the CI pipeline itself, not a firm-facing report -- so the
  -- assigned consultant, who legitimately reads every OTHER CI surface for their firm through
  -- that same platform arm, must still be refused here. app.is_super_admin() is kept as a
  -- second, narrower condition evaluated AFTER the shared gate for exactly that reason: passing
  -- the shared gate is necessary but not sufficient. p_branch is null -- this reader takes no
  -- branch argument; it audits a whole captured business-scoped run, not a branch-scoped one.
  perform app.ci_access_gate_v667(p_business, null);
  if not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode = '42501';
  end if;$newg$;
  -- Patch 2: top-level time_basis, naming the real column (app.ci_shadow_runs_v685.captured_at)
  -- this point-in-time reconciliation would need trusted to trust the payload -- not a
  -- bucketing window like the other six readers', but a genuine, NOT NULL timestamp column.
  v_anchor_tb constant text := $anct$  return jsonb_build_object(
    'run_id', v_run.id,
    'business_id', v_run.business_id,
    'window', v_run.payload->'window',
    'metrics', v_metrics,$anct$;
  v_new_tb constant text := $newt$  return jsonb_build_object(
    'run_id', v_run.id,
    'business_id', v_run.business_id,
    'window', v_run.payload->'window',
    'time_basis', 'captured_at',
    'metrics', v_metrics,$newt$;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_shadow_reconciliation_v685(uuid,uuid)'
  )) into v_def;
  if v_def is null then
    raise exception 'v725: public.get_ci_shadow_reconciliation_v685(uuid,uuid) not found';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_gate, ''))) / greatest(length(v_anchor_gate), 1);
  if v_count <> 1 then
    raise exception 'v725: shadow_reconciliation gate anchor occurs % times (expected 1) -- '
      'live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_tb, ''))) / greatest(length(v_anchor_tb), 1);
  if v_count <> 1 then
    raise exception 'v725: shadow_reconciliation time_basis anchor occurs % times (expected 1) '
      '-- live body drifted', v_count;
  end if;

  v_mid := replace(v_def, v_anchor_gate, v_new_gate);
  v_new := replace(v_mid, v_anchor_tb, v_new_tb);
  execute v_new;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_shadow_reconciliation_v685(uuid,uuid)'
  )) into v_after;
  v_roundtrip := replace(replace(v_after, v_new_tb, v_anchor_tb), v_new_gate, v_anchor_gate);
  if v_roundtrip <> v_def then
    raise exception 'v725: get_ci_shadow_reconciliation_v685 changed by more than the two '
      'intended edits [gate, time_basis]'
      using detail = 'intended:' || E'\n' || v_def || E'\n' || 'actual (reversed):' || E'\n' || v_roundtrip;
  end if;
  if position('app.ci_access_gate_v667(p_business, null)' in v_after) = 0 then
    raise exception 'v725: the shared-gate call did not land in get_ci_shadow_reconciliation_v685';
  end if;
  if position($$'time_basis', 'captured_at'$$ in v_after) = 0 then
    raise exception 'v725: shadow_reconciliation time_basis did not land';
  end if;
end
$v725_shadow$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument
-- list).
revoke all on function public.get_ci_shadow_reconciliation_v685(uuid,uuid) from public, anon;
grant execute on function public.get_ci_shadow_reconciliation_v685(uuid,uuid) to authenticated, service_role;

-- ============================================================================================
-- 4 * No grant was loosened by any same-signature CREATE OR REPLACE above -- asserted, not
--     assumed (the v713/v721 discipline).
-- ============================================================================================
do $v725_acl$
begin
  if not pg_catalog.has_function_privilege('authenticated',
      'public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid)',
      'execute')
  then
    raise exception 'v725: authenticated lost execute on get_customer_intelligence_v83';
  end if;
  if not pg_catalog.has_function_privilege('anon',
      'public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid)',
      'execute')
  then
    raise exception 'v725: anon lost execute on get_customer_intelligence_v83 -- v714 left it '
      'granted; this migration must not narrow it (out of scope to fix here)';
  end if;
  if not pg_catalog.has_function_privilege('authenticated',
      'public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz)', 'execute')
  then
    raise exception 'v725: authenticated lost execute on get_ci_category_customers_v1';
  end if;
  if pg_catalog.has_function_privilege('anon',
      'public.get_ci_category_customers_v1(uuid,text,date,date,integer,uuid,timestamptz)', 'execute')
  then
    raise exception 'v725: anon gained execute on get_ci_category_customers_v1 -- it never had it';
  end if;
  if not pg_catalog.has_function_privilege('authenticated',
      'public.get_ci_shadow_reconciliation_v685(uuid,uuid)', 'execute')
  then
    raise exception 'v725: authenticated lost execute on get_ci_shadow_reconciliation_v685';
  end if;
  if pg_catalog.has_function_privilege('anon',
      'public.get_ci_shadow_reconciliation_v685(uuid,uuid)', 'execute')
  then
    raise exception 'v725: anon gained execute on get_ci_shadow_reconciliation_v685 -- it never '
      'had it, and this reader''s own SA-only check must not be relied on alone at the ACL layer';
  end if;
end
$v725_acl$;

commit;
