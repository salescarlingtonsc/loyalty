-- NESTLY v715 — check 4 estate sweep (continued): app.v179_business_insights.weekday_pattern
-- was still summing RAW SALE ROWS per isodow while its own sibling fields (top_customers.visits,
-- retention.*, lifetime_visits) count distinct visit-days. Same tenant, same window: two same-day
-- clients with sales 3+1+1 and 5 respectively made weekday_pattern.rows[].visits sum to 10, while
-- top_customers/lifetime_visits (correctly deduped by nestly_v699) read 3 and 5 for those two
-- clients. One function, two visit definitions, in the SAME jsonb payload.
--
-- Re-emits ONLY app.v179_business_insights. Anchored extract-and-diff replace-equality against
-- the LIVE body (pg_get_functiondef captured at apply time), same discipline as
-- nestly_v668/v690/v699/v706 — never a hand-retyped guess at the base text. Live body going in
-- is nestly_v706's re-emit (committed 8e07eca8): the `weekday` CTE buckets isodow on the resolved
-- branch-clock timezone (app.ci_bucket_tz_v698 via the `tzinfo` CTE) and the weekday_pattern
-- object discloses bucket_timezone/timezone_basis. That branch-clock bucketing is correct and is
-- NOT touched here — only the `visits` figure inside each isodow bucket changes shape, from
-- `count(*) filter (where counts_as_visit)` (raw sale rows) to a dedupe by
-- (client_id, app.ci_visit_day_v699(occurred_at)), with anonymous (client_id is null) sales still
-- counted individually since they cannot be deduped by customer identity — same shape v699/v709/
-- v711/v714 already use everywhere else in the estate.
--
-- DELIBERATE SPLIT OF AUTHORITY (state this precisely, it is easy to get backwards): the VISIT
-- DAY identity stays SG-anchored via app.ci_visit_day_v699 — that function is SG-only on purpose
-- per its own header and nestly_v699's migration, and this migration does not touch it. The
-- WEEKDAY LABEL a visit is bucketed under keeps following the resolved bucket_timezone (SG,
-- branch, or mixed_branches_default), exactly as nestly_v706 set it up. So a visit's "which day"
-- is decided in SG time (consistent with every other visit-day reader in the estate); its "which
-- weekday" is decided in the resolved clock (consistent with every other bucketing site nestly_v706
-- touched). The two clocks can disagree at a day boundary for a non-SG branch; that is accepted,
-- disclosed behaviour, not a new bug — nestly_v706 already made this same tradeoff for every other
-- reader it touched, and v179's weekday_pattern was simply the one site the sweep had not reached.
--
-- Also adds a `visit_definition` field inside weekday_pattern itself (mirroring the top-level one
-- nestly_v699 already added next to contract_version), so a caller reading weekday_pattern alone
-- does not have to cross-reference the top-level note to learn what `visits` means there.
--
-- NOT TOUCHED: app.ci_visit_registry_v699 (nestly_v714 is concurrently re-emitting it in a sibling
-- session; its `app.v179_business_insights` entry currently carries
-- 'caveat', 'top_customers/lifetime_visits deduped; weekday_pattern owed to v706' — that caveat is
-- now STALE after this migration (weekday_pattern.visits is deduped too) and is OWED AS A FOLLOW-UP
-- to whoever next re-emits the registry: the caveat should either drop the weekday_pattern
-- qualifier entirely or read something like 'top_customers/lifetime_visits/weekday_pattern all
-- count distinct visit-days'. Recorded here, not applied here, per this session's scope (it is not
-- this migration's function to own).
--
-- Fixture: db/tests/executed/v715_corpus_v179_weekday.sql. Two clients in one window — R with 3
-- same-day Monday sales + 1 Tuesday sale + 1 sale the following Monday (3 true visit-days: 2
-- Mondays + 1 Tuesday, 5 raw sale rows), and C with 5 sales on 5 distinct days including one
-- Monday (5 true visit-days, 5 raw sale rows). Hand-computed: weekday_pattern.rows sum to 8 visits
-- (not 10), with isodow=1 (Monday) = 3 (R's two Mondays + C's one Monday); top_customers.visits
-- and lifetime_visits remain 3 and 5 respectively (unchanged — already correct since nestly_v699).
-- A mutation that reverts the dedupe (or that breaks the anonymous-sale fallback) turns the
-- fixture red.
--
-- Existing v179-touching fixtures (v179 itself, v551, v690, v695, v699, v706, and every other
-- executed test that calls app.v179_business_insights) were re-run against this migration and
-- stayed green — none of them asserts a weekday_pattern.visits value that this change alters,
-- because none of their fixtures seeds same-day multi-sale visits inside the weekday_pattern
-- population.

begin;

do $patch_v179_weekday$
declare
  v_def text;
  v_count integer;
  v_expected text;
  v_after text;
  v_roundtrip text;
begin
  select pg_get_functiondef(to_regprocedure('app.v179_business_insights(uuid,date,date,date,date)')) into v_def;
  if v_def is null then
    raise exception 'v715: app.v179_business_insights(uuid,date,date,date,date) not found';
  end if;

  -- anchor 1: the weekday CTE body (raw-row count).
  v_count := (length(v_def) - length(replace(v_def, $zzv715tag1zzz$  ), weekday as (
    select extract(isodow from (occurred_at at time zone (select info->>'timezone' from tzinfo)))::int as isodow,
      coalesce(sum(amount_cents) filter (where counts_as_revenue), 0) as revenue_cents,
      count(*) filter (where counts_as_visit) as visits
    from window_all_sales group by 1
  ),$zzv715tag1zzz$, ''))) / greatest(length($zzv715tag2zzz$  ), weekday as (
    select extract(isodow from (occurred_at at time zone (select info->>'timezone' from tzinfo)))::int as isodow,
      coalesce(sum(amount_cents) filter (where counts_as_revenue), 0) as revenue_cents,
      count(*) filter (where counts_as_visit) as visits
    from window_all_sales group by 1
  ),$zzv715tag2zzz$), 1);
  if v_count <> 1 then
    raise exception 'v715: v179.weekday_cte anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  -- anchor 2: the weekday_pattern jsonb object header (note/bucket_timezone/timezone_basis, no
  -- visit_definition yet).
  v_count := (length(v_def) - length(replace(v_def, $zzv715tag3zzz$    'weekday_pattern', pg_catalog.jsonb_build_object(
      'note', 'isodow: 1=Monday .. 7=Sunday, bucketed at bucket_timezone (see below); all sales including anonymous',
      'bucket_timezone', (select info->>'timezone' from tzinfo),
      'timezone_basis', (select info->>'timezone_basis' from tzinfo),
      'rows', coalesce(($zzv715tag3zzz$, ''))) / greatest(length($zzv715tag4zzz$    'weekday_pattern', pg_catalog.jsonb_build_object(
      'note', 'isodow: 1=Monday .. 7=Sunday, bucketed at bucket_timezone (see below); all sales including anonymous',
      'bucket_timezone', (select info->>'timezone' from tzinfo),
      'timezone_basis', (select info->>'timezone_basis' from tzinfo),
      'rows', coalesce(($zzv715tag4zzz$), 1);
  if v_count <> 1 then
    raise exception 'v715: v179.weekday_pattern_header anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := v_def;
  v_expected := replace(v_expected, $zzv715tag5zzz$  ), weekday as (
    select extract(isodow from (occurred_at at time zone (select info->>'timezone' from tzinfo)))::int as isodow,
      coalesce(sum(amount_cents) filter (where counts_as_revenue), 0) as revenue_cents,
      count(*) filter (where counts_as_visit) as visits
    from window_all_sales group by 1
  ),$zzv715tag5zzz$, $zzv715tag6zzz$  ), weekday as (
    -- nestly_v715: visits dedupe by (client_id, app.ci_visit_day_v699(occurred_at)) -- the same
    -- SG-anchored visit-day identity every other visit-counting reader in the estate uses since
    -- nestly_v699 -- grouped into the isodow bucket the resolved bucket_timezone assigns each row
    -- to. Anonymous (no client_id) sales cannot be deduped by customer identity and each still
    -- counts on its own, same fallback as nestly_v714.
    select isodow,
      coalesce(sum(amount_cents) filter (where counts_as_revenue), 0) as revenue_cents,
      count(distinct (client_id, visit_day)) filter (where counts_as_visit and client_id is not null)
        + count(*) filter (where counts_as_visit and client_id is null) as visits
    from (
      select
        extract(isodow from (occurred_at at time zone (select info->>'timezone' from tzinfo)))::int as isodow,
        client_id,
        app.ci_visit_day_v699(occurred_at) as visit_day,
        amount_cents,
        counts_as_revenue,
        counts_as_visit
      from window_all_sales
    ) w
    group by isodow
  ),$zzv715tag6zzz$);
  v_expected := replace(v_expected, $zzv715tag7zzz$    'weekday_pattern', pg_catalog.jsonb_build_object(
      'note', 'isodow: 1=Monday .. 7=Sunday, bucketed at bucket_timezone (see below); all sales including anonymous',
      'bucket_timezone', (select info->>'timezone' from tzinfo),
      'timezone_basis', (select info->>'timezone_basis' from tzinfo),
      'rows', coalesce(($zzv715tag7zzz$, $zzv715tag8zzz$    'weekday_pattern', pg_catalog.jsonb_build_object(
      'note', 'isodow: 1=Monday .. 7=Sunday, bucketed at bucket_timezone (see below); all sales including anonymous',
      'bucket_timezone', (select info->>'timezone' from tzinfo),
      'timezone_basis', (select info->>'timezone_basis' from tzinfo),
      'visit_definition', 'visits count distinct customer-visit-days (Asia/Singapore-anchored, via app.ci_visit_day_v699), placed in the weekday their sales fell on at bucket_timezone; a same-day split bill counts once, anonymous (no client_id) sales each count as their own visit',
      'rows', coalesce(($zzv715tag8zzz$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('app.v179_business_insights(uuid,date,date,date,date)')) into v_after;

  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $zzv715tag9zzz$    'weekday_pattern', pg_catalog.jsonb_build_object(
      'note', 'isodow: 1=Monday .. 7=Sunday, bucketed at bucket_timezone (see below); all sales including anonymous',
      'bucket_timezone', (select info->>'timezone' from tzinfo),
      'timezone_basis', (select info->>'timezone_basis' from tzinfo),
      'visit_definition', 'visits count distinct customer-visit-days (Asia/Singapore-anchored, via app.ci_visit_day_v699), placed in the weekday their sales fell on at bucket_timezone; a same-day split bill counts once, anonymous (no client_id) sales each count as their own visit',
      'rows', coalesce(($zzv715tag9zzz$, $zzv715tag10zzz$    'weekday_pattern', pg_catalog.jsonb_build_object(
      'note', 'isodow: 1=Monday .. 7=Sunday, bucketed at bucket_timezone (see below); all sales including anonymous',
      'bucket_timezone', (select info->>'timezone' from tzinfo),
      'timezone_basis', (select info->>'timezone_basis' from tzinfo),
      'rows', coalesce(($zzv715tag10zzz$);
  v_roundtrip := replace(v_roundtrip, $zzv715tag11zzz$  ), weekday as (
    -- nestly_v715: visits dedupe by (client_id, app.ci_visit_day_v699(occurred_at)) -- the same
    -- SG-anchored visit-day identity every other visit-counting reader in the estate uses since
    -- nestly_v699 -- grouped into the isodow bucket the resolved bucket_timezone assigns each row
    -- to. Anonymous (no client_id) sales cannot be deduped by customer identity and each still
    -- counts on its own, same fallback as nestly_v714.
    select isodow,
      coalesce(sum(amount_cents) filter (where counts_as_revenue), 0) as revenue_cents,
      count(distinct (client_id, visit_day)) filter (where counts_as_visit and client_id is not null)
        + count(*) filter (where counts_as_visit and client_id is null) as visits
    from (
      select
        extract(isodow from (occurred_at at time zone (select info->>'timezone' from tzinfo)))::int as isodow,
        client_id,
        app.ci_visit_day_v699(occurred_at) as visit_day,
        amount_cents,
        counts_as_revenue,
        counts_as_visit
      from window_all_sales
    ) w
    group by isodow
  ),$zzv715tag11zzz$, $zzv715tag12zzz$  ), weekday as (
    select extract(isodow from (occurred_at at time zone (select info->>'timezone' from tzinfo)))::int as isodow,
      coalesce(sum(amount_cents) filter (where counts_as_revenue), 0) as revenue_cents,
      count(*) filter (where counts_as_visit) as visits
    from window_all_sales group by 1
  ),$zzv715tag12zzz$);
  if v_roundtrip <> v_def then
    raise exception
      'v715: app.v179_business_insights changed by more than the 2 intended edit(s) [weekday_cte, weekday_pattern_header]. Before:%  %After (reversed):%  %',
      E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$patch_v179_weekday$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- no direct grants;
-- this SECURITY DEFINER function is reached only via other server-side callers).
revoke all privileges on function
  app.v179_business_insights(uuid, date, date, date, date)
  from public, anon, authenticated, service_role;

commit;
