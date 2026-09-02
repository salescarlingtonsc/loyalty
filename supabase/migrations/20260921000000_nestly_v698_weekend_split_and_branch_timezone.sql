-- NESTLY v698 — weekday/weekend split in daypart (check 37), and per-branch timezone through the
-- daypart time-bucketing reader (check 8).
--
-- Reads docs/qa/CI-CORPUS-FIXTURE-GUIDE.md, docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md (v672,
-- frozen). Base for get_ci_daypart_v1: the body emitted by
-- db/migrations/20260920_nestly_v693_exclusions_and_typed_verdicts.sql (committed) — this
-- migration is an extract-and-diff replace-equality edit of that body (captures
-- pg_get_functiondef LIVE, at apply time, inside the migration itself, and proves the patched
-- body round-trips back to the exact live original once the intended edits are reversed), the
-- same discipline as v668/v690/v695 — never a hand-retyped guess at the base text.
--
-- Siblings in flight own get_ci_opportunities_v1 (v696), get_ci_service_intelligence_v1 (v697),
-- validate.mjs and app/. None of those files, or any function/table they own, is touched here.
--
-- ============================================================================================
-- PART 1 — public.branches ALREADY HAS A TIMEZONE COLUMN (no DDL needed)
-- ============================================================================================
-- Grepped first, per the task brief: `branches.timezone text not null default 'Asia/Singapore'`
-- was added in db/migrations/20260717_frenly_v11a_branches_staff_services.sql and is already
-- validated — not by a CHECK constraint, but by app.v106_assert_timezone(text) (nestly_v106),
-- which raises 22023 for anything not present in pg_catalog.pg_timezone_names, fired by
-- BEFORE INSERT and BEFORE UPDATE OF timezone triggers on public.branches
-- (trg_v106_branch_reporting_contract_insert / trg_v106_branch_reporting_contract_update). So
-- every branch row, old or new, already carries a name pg_timezone_names recognises. This
-- migration adds no column and no new constraint — it only reads the column.
--
-- ============================================================================================
-- PART 2 — app.ci_bucket_tz_v698(p_business, p_branch) — the ONE bucketing-timezone authority
-- ============================================================================================
-- Resolution order:
--   1. p_branch given -> that branch's own public.branches.timezone. timezone_basis:'branch'.
--   2. p_branch null (firm-wide) and every ACTIVE branch of the business shares one timezone
--      name -> that shared name. timezone_basis:'firm_agreed'.
--   3. Otherwise (branches disagree, or the business has zero active branches) ->
--      'Asia/Singapore', the firm's reporting zone (see app.ci_envelope_v680's own period.timezone
--      — unchanged by this migration; see the note at the end of this header for why).
--      timezone_basis:'mixed_branches_default', DISCLOSED so a caller building trust in a
--      firm-wide daypart number knows it did not resolve to one real branch's own clock.
-- This is intentionally a single fixed timezone for the WHOLE reader call, not a per-sale lookup
-- of that sale's own branch — get_ci_daypart_v1 already accepts p_branch to scope to one branch;
-- when a caller wants firm-wide numbers across branches on different clocks, "coherent, disclosed
-- default" is the only shape that keeps hour/weekday/weekend buckets meaningful as ONE table
-- (mixing per-sale zones would make "hour 10" mean a different wall-clock instant depending on
-- which branch a given sale happened to be at, defeating the point of a bucketed comparison).
-- Never returns null: an unmatched p_branch (wrong business, or no rows) falls through the outer
-- coalesce to the same disclosed default as the "no active branches" case.
--
-- ============================================================================================
-- PART 3 — get_ci_daypart_v1 re-emitted (check 8 + check 37)
-- ============================================================================================
-- (a) The bucketing timezone. Both places the body still hardcoded the literal 'Asia/Singapore'
--     (the 'scope' CTE's local_ts conversion, and its window-membership filter) now use a
--     v_tz variable resolved once, up front, via app.ci_bucket_tz_v698(p_business, p_branch).
--     'bucket_timezone' (the resolved zone) and 'timezone_basis' (how it was resolved) are new
--     additive keys next to the existing 'time_basis'. The 'basis_note' explanatory string, which
--     used to hardcode "converted to Asia/Singapore", is rewritten with format() to name the
--     ACTUAL resolved zone instead of asserting a zone that may no longer be true.
-- (b) 'weekend_split' — a new additive top-level key: {weekday:{visits, revenue_cents,
--     revenue_per_visit_cents, evidence}, weekend:{...}, evidence_class:'ASSOCIATION',
--     difference_note}. Built from the SAME 'scope' rows already computed for 'weekdays'/'hours'
--     (no new scan), grouped by ISO weekday in (6,7)=weekend vs (1..5)=weekday, using the
--     'scope' CTE's own local_ts (i.e. bucketed in v_tz, exactly like every other bucket in this
--     reader). revenue_per_visit_cents is floor-gated by app.subgroup_evidence_v1 on visits, the
--     same pattern the sibling 'hours' bucket was given in v693 (never an ungated average).
--     evidence_class is 'ASSOCIATION', not 'DIRECT_FACT': weekday-vs-weekend is a comparison
--     between two calendar groupings of the same population, not a single direct tally, the same
--     reasoning v693 already applied to 'most_valuable_weekday'.
--
-- NOT re-emitted here (left for a follow-up, as instructed): get_ci_funnel_conversion_v1,
-- get_ci_retention_windows_v1, get_ci_demographic_cohort_v1 and app.customer_cadence_v1 all bucket
-- time in a hardcoded 'Asia/Singapore' too and are candidates to route through the same
-- app.ci_bucket_tz_v698 authority next; none of their bodies, or any table/function they own, is
-- touched by this migration.
--
-- THE ENVELOPE STAYS SG, ON PURPOSE. app.ci_envelope_v680's 'period.timezone' is deliberately NOT
-- touched: the envelope's period is the firm's own reporting window (the same SG-anchored
-- calendar every other CI reader's 'period' block uses, and the one a firm's owner reads reports
-- in), while 'bucket_timezone'/'timezone_basis' are reader-level keys disclosing what actually
-- drove THIS reader's hour/weekday/weekend arithmetic. The two can legitimately differ (a
-- Perth-timezone branch bucketed at its own clock, reported inside an SG-dated period), and
-- collapsing them into one field would hide that.
--
-- Proven by db/tests/executed/v698_corpus_weekend_timezone.sql.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. app.ci_bucket_tz_v698 — the one bucketing-timezone authority.
-- ---------------------------------------------------------------------------------------------
create or replace function app.ci_bucket_tz_v698(p_business uuid, p_branch uuid default null)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce(
    case
      when p_branch is not null then (
        select jsonb_build_object('timezone', br.timezone, 'timezone_basis', 'branch')
          from public.branches br
         where br.id = p_branch and br.business_id = p_business
      )
      else (
        select case when count(distinct br.timezone) = 1
                    then jsonb_build_object('timezone', min(br.timezone),
                                             'timezone_basis', 'firm_agreed')
                    else jsonb_build_object('timezone', 'Asia/Singapore',
                                             'timezone_basis', 'mixed_branches_default')
               end
          from public.branches br
         where br.business_id = p_business and br.active
      )
    end,
    jsonb_build_object('timezone', 'Asia/Singapore', 'timezone_basis', 'mixed_branches_default')
  );
$$;
revoke all on function app.ci_bucket_tz_v698(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 2. get_ci_daypart_v1 — anchored extract-and-diff patch of the LIVE body (v693's own emission),
--    captured via pg_get_functiondef at apply time, verified byte-faithful except the intended
--    additions via a reverse-replace round-trip.
-- ---------------------------------------------------------------------------------------------
do $patch_daypart$
declare
  v_def text;

  v_anchor_preamble constant text := 'declare
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception ''invalid date range'' using errcode = ''22023'';
  end if;

  with scope as (';
  v_new_preamble constant text := 'declare
  v_result jsonb;
  v_tzinfo jsonb;
  v_tz text;
  v_tz_basis text;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception ''invalid date range'' using errcode = ''22023'';
  end if;

  v_tzinfo := app.ci_bucket_tz_v698(p_business, p_branch);
  v_tz := coalesce(v_tzinfo->>''timezone'', ''Asia/Singapore'');
  v_tz_basis := coalesce(v_tzinfo->>''timezone_basis'', ''mixed_branches_default'');

  with scope as (';

  v_anchor_local_ts constant text :=
    '           (s.occurred_at at time zone ''Asia/Singapore'') as local_ts';
  v_new_local_ts constant text :=
    '           (s.occurred_at at time zone v_tz) as local_ts';

  v_anchor_scope_date constant text :=
    '       and (s.occurred_at at time zone ''Asia/Singapore'')::date between p_from and p_to
  ),';
  v_new_scope_date constant text :=
    '       and (s.occurred_at at time zone v_tz)::date between p_from and p_to
  ),';

  v_anchor_hours_busiest constant text := '  ),
  busiest as (
    select dow, label, visits from weekday_rated order by visits desc, dow asc limit 1
  ),';
  v_new_hours_busiest constant text := '  ),
  weekend_bucket as (
    select case when extract(isodow from local_ts)::int in (6, 7) then ''weekend'' else ''weekday'' end
             as bucket,
           count(*) filter (where include_visit) as visits,
           coalesce(sum(amount_cents) filter (where include_revenue), 0) as revenue_cents
      from scope
     group by 1
  ),
  weekend_rows as (
    select b.bucket, coalesce(wb.visits, 0) as visits, coalesce(wb.revenue_cents, 0) as revenue_cents,
           app.subgroup_evidence_v1(coalesce(wb.visits, 0)::int) as evidence
      from (values (''weekday''), (''weekend'')) as b(bucket)
      left join weekend_bucket wb on wb.bucket = b.bucket
  ),
  busiest as (
    select dow, label, visits from weekday_rated order by visits desc, dow asc limit 1
  ),';

  v_anchor_basis_note constant text := '    ''basis_note'',
      ''Bucketed on sale_occurred_at -- the till timestamp a sale was RECORDED at -- converted to ''
      ''Asia/Singapore. This is TILL time, not arrival time or service-start time: neither is ''
      ''captured anywhere in this schema today, so a customer who waited before being served, or ''
      ''a booking whose service began well before checkout, is bucketed by when the sale closed, ''
      ''not by when they walked in.'',';
  v_new_basis_note constant text := '    ''bucket_timezone'', v_tz,
    ''timezone_basis'', v_tz_basis,
    ''basis_note'',
      format(
        ''Bucketed on sale_occurred_at -- the till timestamp a sale was RECORDED at -- converted '' ||
        ''to %s (see bucket_timezone/timezone_basis for how this was resolved). This is TILL '' ||
        ''time, not arrival time or service-start time: neither is captured anywhere in this '' ||
        ''schema today, so a customer who waited before being served, or a booking whose service '' ||
        ''began well before checkout, is bucketed by when the sale closed, not by when they '' ||
        ''walked in.'', v_tz),';

  v_anchor_hours_key constant text := '        from hours h
    ),
    ''busiest_weekday'',';
  v_new_hours_key constant text := '        from hours h
    ),
    ''weekend_split'', (
      select jsonb_build_object(
        ''weekday'', jsonb_build_object(
          ''visits'', wd.visits, ''revenue_cents'', wd.revenue_cents,
          ''revenue_per_visit_cents'',
            case when wd.evidence ->> ''status'' = ''ok'' and wd.visits > 0
                 then round(wd.revenue_cents::numeric / wd.visits) else null end,
          ''evidence'', wd.evidence),
        ''weekend'', jsonb_build_object(
          ''visits'', we.visits, ''revenue_cents'', we.revenue_cents,
          ''revenue_per_visit_cents'',
            case when we.evidence ->> ''status'' = ''ok'' and we.visits > 0
                 then round(we.revenue_cents::numeric / we.visits) else null end,
          ''evidence'', we.evidence),
        ''evidence_class'', ''ASSOCIATION'',
        ''difference_note'',
          ''Weekday vs weekend revenue-per-visit is a comparison across two calendar groupings '' ||
          ''of the same business, not a randomised split, so any gap is an association between '' ||
          ''day-type and value, not a causal claim about what a weekend itself produces.'')
        from weekend_rows wd, weekend_rows we
       where wd.bucket = ''weekday'' and we.bucket = ''weekend''
    ),
    ''busiest_weekday'',';

  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_daypart_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then raise exception 'v698: public.get_ci_daypart_v1 not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor_preamble, ''))) / length(v_anchor_preamble);
  if v_count <> 1 then
    raise exception 'v698: preamble anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_local_ts, ''))) / length(v_anchor_local_ts);
  if v_count <> 1 then
    raise exception 'v698: local_ts anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_scope_date, ''))) / length(v_anchor_scope_date);
  if v_count <> 1 then
    raise exception 'v698: scope-date anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_hours_busiest, ''))) / length(v_anchor_hours_busiest);
  if v_count <> 1 then
    raise exception 'v698: hours/busiest anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_basis_note, ''))) / length(v_anchor_basis_note);
  if v_count <> 1 then
    raise exception 'v698: basis_note anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_anchor_hours_key, ''))) / length(v_anchor_hours_key);
  if v_count <> 1 then
    raise exception 'v698: hours-key anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, v_anchor_preamble, v_new_preamble);
  v_expected := replace(v_expected, v_anchor_local_ts, v_new_local_ts);
  v_expected := replace(v_expected, v_anchor_scope_date, v_new_scope_date);
  v_expected := replace(v_expected, v_anchor_hours_busiest, v_new_hours_busiest);
  v_expected := replace(v_expected, v_anchor_basis_note, v_new_basis_note);
  v_expected := replace(v_expected, v_anchor_hours_key, v_new_hours_key);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_daypart_v1(uuid,date,date,uuid,timestamptz)')) into v_after;

  v_roundtrip := replace(v_after, v_new_preamble, v_anchor_preamble);
  v_roundtrip := replace(v_roundtrip, v_new_local_ts, v_anchor_local_ts);
  v_roundtrip := replace(v_roundtrip, v_new_scope_date, v_anchor_scope_date);
  v_roundtrip := replace(v_roundtrip, v_new_hours_busiest, v_anchor_hours_busiest);
  v_roundtrip := replace(v_roundtrip, v_new_basis_note, v_anchor_basis_note);
  v_roundtrip := replace(v_roundtrip, v_new_hours_key, v_anchor_hours_key);
  if v_roundtrip <> v_def then
    raise exception
      'v698: get_ci_daypart_v1 changed by more than the six intended edits. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_daypart$;
-- ACL restated verbatim from the live proacl (unchanged by this migration — same argument list).
revoke all on function public.get_ci_daypart_v1(uuid,date,date,uuid,timestamptz) from public, anon;
grant execute on function public.get_ci_daypart_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

commit;
