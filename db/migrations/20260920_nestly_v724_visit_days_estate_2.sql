-- NESTLY v724 — check 4 refutation (estate sweep, round 2): eleven more visits/repeat/returning-
-- shaped readers nestly_v699/v709/v711/v714/v715/v717 had not yet reached still counted raw sale
-- rows instead of distinct (client, visit-day) pairs.
--
-- Contract: docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md (v672, frozen). Fixture guide:
-- docs/qa/CI-CORPUS-FIXTURE-GUIDE.md. Proven by
-- db/tests/executed/v724_corpus_visit_days_estate_2.sql.
--
-- ============================================================================================
-- WHAT WAS WRONG (check 4, estate sweep round 2).
--
--   1. app.v176_sales_window / app.v177_sales_window -- the AI firm-report / workspace-mirror
--      sales-window builder's 'visits' figure was count(*) over valid_sales (raw sale rows).
--      app.v177_overview delegates its own 'sales.current'/'sales.prior'/'sales.growth.
--      visits_delta' entirely to these two functions and computes no visit count of its own, so
--      it inherits the fix without a patch of its own -- confirmed by reading its live body: it
--      never counts a sale row directly, only reads the 'visits' key back out of what
--      v176_sales_window/v177_sales_window already returned.
--   2. app.v177_customers -- each recent-joiner's 'visit_count' in the ten-row admin mirror was
--      count(*) over that one client's public.sales rows.
--   3. app.v666_till_customer_card -- the till's customer-card 'visits' field was count(*) over
--      the client's sales. public.staff_scan_member_qr_v327 (QR check-in) builds its returned
--      card entirely by calling app.v666_till_customer_card and computes no visit count of its
--      own (its own v_visits local variable is declared but never assigned or read), so it
--      inherits the fix without a patch of its own.
--   4. public.lookup_client_by_phone -- the till's phone-lookup customer card carries the exact
--      same count(*) 'visits' bug as app.v666_till_customer_card, independently, because the two
--      RPCs duplicate the same lookup rather than sharing one.
--   5. public.get_attention_list_v548 -- the owner's "needs attention" list's `visits` CTE
--      computed interval_days via lag() over RAW sale rows partitioned by client, ordered by
--      occurred_at, id. A same-day split bill therefore inserted a near-zero interval into the
--      cadence sequence, dragging the median cadence down and both the >=3-prior-visits
--      eligibility floor and the due/overdue/slipping thresholds it feeds off a false-frequent
--      cadence.
--   6. public.get_ci_acquisition_v1 -- repeat_customers counted `select count(*) from
--      public.sales ... >= 2`, raw rows, per acquisition source. A client with a single calendar
--      visit but two same-day sales (a split bill) was misclassified as a repeat customer. This
--      function was already re-emitted once by nestly_v717 for an unrelated reason (time basis /
--      category floor); this migration's anchor is taken against v717's live body, not v409's
--      original.
--   7. public.get_ci_demographics_v1 -- each demographic cell's 'visits' figure was
--      count(*) filter (where q.is_visit) over the qualifying CTE, raw sale rows, so a same-day
--      split bill inflated a cell's visit total same as every other reader in this family.
--   8. public.staff_list_returned_customers_v300 -- ordered's lag(occurred_at) ran directly over
--      valid_visits (raw sale rows), so a same-day split bill occurring ON the return visit
--      itself could become its own previous_visit_at (interval zero) and zero away_days,
--      silently hiding a real multi-month return from the "returned customers" list -- the
--      opposite failure mode from every other reader in this family (which over-counts repeat/
--      returning), this one can make a genuine comeback customer vanish entirely.
--
-- None of these are covered by nestly_v699/v709/v711/v714/v715/v717's own fixtures -- each proves
-- only the readers it names. This migration closes eleven more names in the same estate, using
-- the SAME authority (app.ci_visit_day_v699, nestly_v699) throughout.
--
-- ============================================================================================
-- WHAT THIS DOES. Nine extract-and-diff patches against the LIVE pg_get_functiondef body of each
-- function (anchored on the body exactly as it stands post-v717/v718/v721, never an assumed
-- source formatting -- same discipline as v668/v690/v699/v709/v711/v714), plus the registry:
--
--   (1) app.v176_sales_window -- valid_sales gains sale.occurred_at in its select list; a new
--       visit_days CTE collapses it to distinct (client_id, visit-day) pairs (client_id not
--       null -- an unattributed walk-in sale cannot be deduped by identity and still counts on
--       its own); 'visits' becomes count(*) from visit_days plus the walk-in count. Same pattern
--       nestly_v714 used for get_dashboard_summary.
--   (2) app.v177_sales_window -- the branch-scoped twin of (1); identical fix, one extra
--       branch_id predicate already present in both source CTEs untouched.
--   (3) app.v177_customers -- each recent-joiner's visit_count subquery becomes
--       count(distinct app.ci_visit_day_v699(sale.occurred_at)).
--   (4) app.v666_till_customer_card -- v_visits becomes
--       count(distinct app.ci_visit_day_v699(occurred_at)).
--   (5) public.lookup_client_by_phone -- the same v_visits fix as (4), independently (the two
--       RPCs do not share the lookup).
--   (6) public.get_attention_list_v548 -- the single `visits` CTE (which both selects sale rows
--       AND computes the lag() interval in one step) splits into raw_visits (verbatim old select,
--       no lag), visit_days (collapse to one row per client per visit-day, anchored at that day's
--       FIRST qualifying sale, amount_cents summed per day -- same anchor rule as nestly_v709/
--       v711/v714), and a new `visits` CTE that computes interval_days via lag() over visit_days.
--       Downstream `metrics` (and everything below it) is untouched -- its input CTE keeps the
--       name `visits` and the same output shape (client_id, occurred_at, amount_cents,
--       interval_days), only where those columns come from changed.
--   (7) public.get_ci_acquisition_v1 -- repeat_customers' inner `select count(*) from
--       public.sales s ...` becomes `select count(distinct app.ci_visit_day_v699(s.occurred_at))
--       from public.sales s ...`. Anchored against the LIVE body as nestly_v717 left it (v717
--       touched this same function for time-basis/category-floor reasons; this migration's anchor
--       is the post-v717 text, confirmed by reading pg_get_functiondef against the migrated
--       harness before writing this patch).
--   (8) public.get_ci_demographics_v1 -- qualifying gains s.occurred_at in its select list;
--       client_agg's `count(*) filter (where q.is_visit) as visits` becomes
--       `count(distinct app.ci_visit_day_v699(q.occurred_at)) filter (where q.is_visit) as
--       visits`.
--   (9) public.staff_list_returned_customers_v300 -- a new visit_days CTE sits between
--       valid_visits and ordered, collapsing to one row per (client_id, visit-day) with
--       min(occurred_at) as the day's anchor timestamp; `ordered` reads from visit_days instead
--       of valid_visits, otherwise byte-identical (same lag()/row_number() shape, same output
--       columns `returned` downstream reads).
--
-- (10) app.ci_visit_registry_v699 -- extract-and-diff, anchored on its current last entry
--      (platform_get_enterprise_hierarchy_v82, nestly_v714): eleven new entries, one per reader
--      named above, each uses_authority=true -- including app.v177_overview and
--      public.staff_scan_member_qr_v327, which get a registry entry recording that they inherit
--      the fix from app.v176_sales_window/app.v177_sales_window and app.v666_till_customer_card
--      respectively, without a code patch of their own (confirmed: neither computes its own visit
--      count -- v177_overview only reads back the 'visits' key its delegates already return, and
--      staff_scan_member_qr_v327's own v_visits local variable is declared but never assigned or
--      read, the whole card being built by app.v666_till_customer_card(...) at the return
--      statement).
--
-- ============================================================================================
-- NOT TOUCHED (explicitly out of scope for this migration):
--   - app.ci_metric_dictionary_v1 (nestly_v714 already names the one authority in its 'visit'
--     entry; nothing here changes what that entry says).
--   - every fixture named in the corpus guide's existing-fixture check (v176, v177, v300, v327,
--     v409, v548, v666, and the v674/v680/v717 acquisition/demographics corpus) was verified
--     BEFORE writing this migration to seed only distinct-calendar-day sales per client for every
--     one of the eleven readers above, so this migration's visit-day collapse is a no-op for all
--     of them and their existing truth tables hold exactly as written; re-run after applying, all
--     green.
-- ============================================================================================
begin;

-- ---------------------------------------------------------------------------------------------
-- 1 · app.v176_sales_window
-- ---------------------------------------------------------------------------------------------
do $v724blk_v176_1$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('app.v176_sales_window(uuid,date,date)')) into v_def;
  if v_def is null then raise exception 'v724: app.v176_sales_window(uuid,date,date) not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, $v724a176_1$  ), valid_sales as (
    select sale.id, sale.client_id, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
    select sale.client_id,
      min((sale.occurred_at at time zone 'Asia/Singapore')::date) as first_date
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and client.is_synthetic = false
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.client_id is not null
      and sale.counts_as_visit
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
    group by sale.client_id
  )
  select pg_catalog.jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', 'SGD',
    'net_revenue_cents', coalesce(
      (select sum(amount_cents) from valid_sales where counts_as_revenue), 0
    ),
    'revenue_transactions', (
      select count(*) from valid_sales where counts_as_revenue
    ),
    'visits', (select count(*) from valid_sales where counts_as_visit),
$v724a176_1$, ''))) / length($v724a176_1$  ), valid_sales as (
    select sale.id, sale.client_id, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
    select sale.client_id,
      min((sale.occurred_at at time zone 'Asia/Singapore')::date) as first_date
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and client.is_synthetic = false
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.client_id is not null
      and sale.counts_as_visit
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
    group by sale.client_id
  )
  select pg_catalog.jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', 'SGD',
    'net_revenue_cents', coalesce(
      (select sum(amount_cents) from valid_sales where counts_as_revenue), 0
    ),
    'revenue_transactions', (
      select count(*) from valid_sales where counts_as_revenue
    ),
    'visits', (select count(*) from valid_sales where counts_as_visit),
$v724a176_1$);
  if v_count <> 1 then
    raise exception 'v724: v176 anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, $v724a176_2$  ), valid_sales as (
    select sale.id, sale.client_id, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
    select sale.client_id,
      min((sale.occurred_at at time zone 'Asia/Singapore')::date) as first_date
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and client.is_synthetic = false
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.client_id is not null
      and sale.counts_as_visit
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
    group by sale.client_id
  )
  select pg_catalog.jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', 'SGD',
    'net_revenue_cents', coalesce(
      (select sum(amount_cents) from valid_sales where counts_as_revenue), 0
    ),
    'revenue_transactions', (
      select count(*) from valid_sales where counts_as_revenue
    ),
    'visits', (select count(*) from valid_sales where counts_as_visit),
$v724a176_2$, $v724r176_3$  ), valid_sales as (
    select sale.id, sale.client_id, sale.occurred_at, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
    select sale.client_id,
      min((sale.occurred_at at time zone 'Asia/Singapore')::date) as first_date
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and client.is_synthetic = false
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.client_id is not null
      and sale.counts_as_visit
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
    group by sale.client_id
  ), visit_days as (
    -- nestly_v724 (estate sweep 2): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699). Sales with no
    -- client_id (walk-ins) cannot be deduped by customer identity, so each still counts on its own
    -- below -- same technique as nestly_v714's get_dashboard_summary fix.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day
    from valid_sales
    where counts_as_visit and client_id is not null
    group by client_id, app.ci_visit_day_v699(occurred_at)
  )
  select pg_catalog.jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', 'SGD',
    'net_revenue_cents', coalesce(
      (select sum(amount_cents) from valid_sales where counts_as_revenue), 0
    ),
    'revenue_transactions', (
      select count(*) from valid_sales where counts_as_revenue
    ),
    'visits', (select count(*) from visit_days) + (select count(*) from valid_sales where counts_as_visit and client_id is null),
$v724r176_3$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('app.v176_sales_window(uuid,date,date)')) into v_after;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v724: v176 visit-day authority did not land';
  end if;
  v_roundtrip := replace(v_after, $v724r176_4$  ), valid_sales as (
    select sale.id, sale.client_id, sale.occurred_at, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
    select sale.client_id,
      min((sale.occurred_at at time zone 'Asia/Singapore')::date) as first_date
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and client.is_synthetic = false
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.client_id is not null
      and sale.counts_as_visit
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
    group by sale.client_id
  ), visit_days as (
    -- nestly_v724 (estate sweep 2): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699). Sales with no
    -- client_id (walk-ins) cannot be deduped by customer identity, so each still counts on its own
    -- below -- same technique as nestly_v714's get_dashboard_summary fix.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day
    from valid_sales
    where counts_as_visit and client_id is not null
    group by client_id, app.ci_visit_day_v699(occurred_at)
  )
  select pg_catalog.jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', 'SGD',
    'net_revenue_cents', coalesce(
      (select sum(amount_cents) from valid_sales where counts_as_revenue), 0
    ),
    'revenue_transactions', (
      select count(*) from valid_sales where counts_as_revenue
    ),
    'visits', (select count(*) from visit_days) + (select count(*) from valid_sales where counts_as_visit and client_id is null),
$v724r176_4$, $v724a176_5$  ), valid_sales as (
    select sale.id, sale.client_id, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
    select sale.client_id,
      min((sale.occurred_at at time zone 'Asia/Singapore')::date) as first_date
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and client.is_synthetic = false
    where sale.business_id = p_business
      and sale.reversal_of is null
      and sale.client_id is not null
      and sale.counts_as_visit
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
    group by sale.client_id
  )
  select pg_catalog.jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', 'SGD',
    'net_revenue_cents', coalesce(
      (select sum(amount_cents) from valid_sales where counts_as_revenue), 0
    ),
    'revenue_transactions', (
      select count(*) from valid_sales where counts_as_revenue
    ),
    'visits', (select count(*) from valid_sales where counts_as_visit),
$v724a176_5$);
  if v_roundtrip <> v_def then
    raise exception 'v724: v176 changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$v724blk_v176_1$;
revoke all on function app.v176_sales_window(uuid,date,date) from public, anon, authenticated, service_role;
grant execute on function app.v176_sales_window(uuid,date,date) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 2 · app.v177_sales_window (branch-scoped twin of (1))
-- ---------------------------------------------------------------------------------------------
do $v724blk_v177sw_1$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('app.v177_sales_window(uuid,uuid,date,date)')) into v_def;
  if v_def is null then raise exception 'v724: app.v177_sales_window(uuid,uuid,date,date) not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, $v724a177sw_1$  ), valid_sales as (
    select sale.id, sale.client_id, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
    select sale.client_id,
      min((sale.occurred_at at time zone 'Asia/Singapore')::date) as first_date
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and client.is_synthetic = false
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.client_id is not null
      and sale.counts_as_visit
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
    group by sale.client_id
  )
  select pg_catalog.jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', 'SGD',
    'net_revenue_cents', coalesce(
      (select sum(amount_cents) from valid_sales where counts_as_revenue), 0
    ),
    'revenue_transactions', (
      select count(*) from valid_sales where counts_as_revenue
    ),
    'visits', (select count(*) from valid_sales where counts_as_visit),
$v724a177sw_1$, ''))) / length($v724a177sw_1$  ), valid_sales as (
    select sale.id, sale.client_id, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
    select sale.client_id,
      min((sale.occurred_at at time zone 'Asia/Singapore')::date) as first_date
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and client.is_synthetic = false
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.client_id is not null
      and sale.counts_as_visit
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
    group by sale.client_id
  )
  select pg_catalog.jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', 'SGD',
    'net_revenue_cents', coalesce(
      (select sum(amount_cents) from valid_sales where counts_as_revenue), 0
    ),
    'revenue_transactions', (
      select count(*) from valid_sales where counts_as_revenue
    ),
    'visits', (select count(*) from valid_sales where counts_as_visit),
$v724a177sw_1$);
  if v_count <> 1 then
    raise exception 'v724: v177sw anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, $v724a177sw_2$  ), valid_sales as (
    select sale.id, sale.client_id, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
    select sale.client_id,
      min((sale.occurred_at at time zone 'Asia/Singapore')::date) as first_date
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and client.is_synthetic = false
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.client_id is not null
      and sale.counts_as_visit
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
    group by sale.client_id
  )
  select pg_catalog.jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', 'SGD',
    'net_revenue_cents', coalesce(
      (select sum(amount_cents) from valid_sales where counts_as_revenue), 0
    ),
    'revenue_transactions', (
      select count(*) from valid_sales where counts_as_revenue
    ),
    'visits', (select count(*) from valid_sales where counts_as_visit),
$v724a177sw_2$, $v724r177sw_3$  ), valid_sales as (
    select sale.id, sale.client_id, sale.occurred_at, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
    select sale.client_id,
      min((sale.occurred_at at time zone 'Asia/Singapore')::date) as first_date
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and client.is_synthetic = false
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.client_id is not null
      and sale.counts_as_visit
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
    group by sale.client_id
  ), visit_days as (
    -- nestly_v724 (estate sweep 2): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699). Sales with no
    -- client_id (walk-ins) cannot be deduped by customer identity, so each still counts on its own
    -- below -- same technique as nestly_v714's get_dashboard_summary fix.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day
    from valid_sales
    where counts_as_visit and client_id is not null
    group by client_id, app.ci_visit_day_v699(occurred_at)
  )
  select pg_catalog.jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', 'SGD',
    'net_revenue_cents', coalesce(
      (select sum(amount_cents) from valid_sales where counts_as_revenue), 0
    ),
    'revenue_transactions', (
      select count(*) from valid_sales where counts_as_revenue
    ),
    'visits', (select count(*) from visit_days) + (select count(*) from valid_sales where counts_as_visit and client_id is null),
$v724r177sw_3$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('app.v177_sales_window(uuid,uuid,date,date)')) into v_after;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v724: v177sw visit-day authority did not land';
  end if;
  v_roundtrip := replace(v_after, $v724r177sw_4$  ), valid_sales as (
    select sale.id, sale.client_id, sale.occurred_at, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
    select sale.client_id,
      min((sale.occurred_at at time zone 'Asia/Singapore')::date) as first_date
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and client.is_synthetic = false
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.client_id is not null
      and sale.counts_as_visit
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
    group by sale.client_id
  ), visit_days as (
    -- nestly_v724 (estate sweep 2): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699). Sales with no
    -- client_id (walk-ins) cannot be deduped by customer identity, so each still counts on its own
    -- below -- same technique as nestly_v714's get_dashboard_summary fix.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day
    from valid_sales
    where counts_as_visit and client_id is not null
    group by client_id, app.ci_visit_day_v699(occurred_at)
  )
  select pg_catalog.jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', 'SGD',
    'net_revenue_cents', coalesce(
      (select sum(amount_cents) from valid_sales where counts_as_revenue), 0
    ),
    'revenue_transactions', (
      select count(*) from valid_sales where counts_as_revenue
    ),
    'visits', (select count(*) from visit_days) + (select count(*) from valid_sales where counts_as_visit and client_id is null),
$v724r177sw_4$, $v724a177sw_5$  ), valid_sales as (
    select sale.id, sale.client_id, sale.amount_cents,
      sale.counts_as_revenue as counts_as_revenue,
      sale.counts_as_visit as counts_as_visit
    from public.sales sale, bounds
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
    select sale.client_id,
      min((sale.occurred_at at time zone 'Asia/Singapore')::date) as first_date
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and client.is_synthetic = false
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.client_id is not null
      and sale.counts_as_visit
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
    group by sale.client_id
  )
  select pg_catalog.jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', 'SGD',
    'net_revenue_cents', coalesce(
      (select sum(amount_cents) from valid_sales where counts_as_revenue), 0
    ),
    'revenue_transactions', (
      select count(*) from valid_sales where counts_as_revenue
    ),
    'visits', (select count(*) from valid_sales where counts_as_visit),
$v724a177sw_5$);
  if v_roundtrip <> v_def then
    raise exception 'v724: v177sw changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$v724blk_v177sw_1$;
revoke all on function app.v177_sales_window(uuid,uuid,date,date) from public, anon, authenticated, service_role;
grant execute on function app.v177_sales_window(uuid,uuid,date,date) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 3 · app.v177_customers
-- ---------------------------------------------------------------------------------------------
do $v724blk_v177c_1$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('app.v177_customers(uuid)')) into v_def;
  if v_def is null then raise exception 'v724: app.v177_customers(uuid) not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, $v724a177c_1$        'visit_count', (
          select count(*) from public.sales sale
          where sale.business_id = p_business
            and sale.client_id = recent.id
            and sale.counts_as_visit
            and sale.reversal_of is null
        )
$v724a177c_1$, ''))) / length($v724a177c_1$        'visit_count', (
          select count(*) from public.sales sale
          where sale.business_id = p_business
            and sale.client_id = recent.id
            and sale.counts_as_visit
            and sale.reversal_of is null
        )
$v724a177c_1$);
  if v_count <> 1 then
    raise exception 'v724: v177c anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, $v724a177c_2$        'visit_count', (
          select count(*) from public.sales sale
          where sale.business_id = p_business
            and sale.client_id = recent.id
            and sale.counts_as_visit
            and sale.reversal_of is null
        )
$v724a177c_2$, $v724r177c_3$        'visit_count', (
          select count(distinct app.ci_visit_day_v699(sale.occurred_at)) from public.sales sale
          where sale.business_id = p_business
            and sale.client_id = recent.id
            and sale.counts_as_visit
            and sale.reversal_of is null
        )
$v724r177c_3$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('app.v177_customers(uuid)')) into v_after;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v724: v177c visit-day authority did not land';
  end if;
  v_roundtrip := replace(v_after, $v724r177c_4$        'visit_count', (
          select count(distinct app.ci_visit_day_v699(sale.occurred_at)) from public.sales sale
          where sale.business_id = p_business
            and sale.client_id = recent.id
            and sale.counts_as_visit
            and sale.reversal_of is null
        )
$v724r177c_4$, $v724a177c_5$        'visit_count', (
          select count(*) from public.sales sale
          where sale.business_id = p_business
            and sale.client_id = recent.id
            and sale.counts_as_visit
            and sale.reversal_of is null
        )
$v724a177c_5$);
  if v_roundtrip <> v_def then
    raise exception 'v724: v177c changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$v724blk_v177c_1$;
revoke all on function app.v177_customers(uuid) from public, anon, authenticated, service_role;
grant execute on function app.v177_customers(uuid) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 4 · app.v666_till_customer_card
-- ---------------------------------------------------------------------------------------------
do $v724blk_v666_1$
declare
  v_def text;
  v_after text;
  v_roundtrip text;
  v_count integer;
  -- Merged 2026-09-03: main's nestly_v677 ("a reversed sale is not a visit") had already moved this
  -- line onto app.client_qualifying_visits_v677. The two rulings compose: a visit is a distinct
  -- Singapore day among the NON-REVERSED qualifying sales. The anchor is v677's line as production
  -- stores it (comment-free); the replacement keeps v677's reversal netting verbatim.
  v_anchor constant text := $v724blk_v666_1_a$ v_visits := app.client_qualifying_visits_v677(p_business, v_client.id);
$v724blk_v666_1_a$;
  v_new constant text := $v724blk_v666_1_n$ with visit_rows as (
    select s.id, s.reversal_of, s.occurred_at
      from public.sales s
     where s.business_id=p_business and s.client_id=v_client.id and s.counts_as_visit
  )
  select count(distinct app.ci_visit_day_v699(v.occurred_at)) into v_visits
    from visit_rows v
   where v.reversal_of is null
     and not exists (select 1 from visit_rows r where r.reversal_of = v.id);
$v724blk_v666_1_n$;
begin
  select pg_get_functiondef(to_regprocedure('app.v666_till_customer_card(uuid,uuid)')) into v_def;
  if v_def is null then raise exception 'v724: app.v666_till_customer_card(uuid,uuid) not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_count <> 1 then
    raise exception 'v724: v666 anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  execute replace(v_def, v_anchor, v_new);

  select pg_get_functiondef(to_regprocedure('app.v666_till_customer_card(uuid,uuid)')) into v_after;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v724: v666 visit-day authority did not land';
  end if;
  v_roundtrip := replace(v_after, v_new, v_anchor);
  if v_roundtrip <> v_def then
    raise exception 'v724: v666 changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$v724blk_v666_1$;
revoke all on function app.v666_till_customer_card(uuid,uuid) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 5 · public.lookup_client_by_phone
-- ---------------------------------------------------------------------------------------------
do $v724blk_lcbp_1$
declare
  v_def text;
  v_after text;
  v_roundtrip text;
  v_count integer;
  -- Merged 2026-09-03: main's nestly_v677 ("a reversed sale is not a visit") had already moved this
  -- line onto app.client_qualifying_visits_v677. The two rulings compose: a visit is a distinct
  -- Singapore day among the NON-REVERSED qualifying sales. The anchor is v677's line as production
  -- stores it (comment-free); the replacement keeps v677's reversal netting verbatim.
  v_anchor constant text := $v724blk_lcbp_1_a$ v_visits := app.client_qualifying_visits_v677(p_business, c.id);
$v724blk_lcbp_1_a$;
  v_new constant text := $v724blk_lcbp_1_n$ with visit_rows as (
    select s.id, s.reversal_of, s.occurred_at
      from public.sales s
     where s.business_id=p_business and s.client_id=c.id and s.counts_as_visit
  )
  select count(distinct app.ci_visit_day_v699(v.occurred_at)) into v_visits
    from visit_rows v
   where v.reversal_of is null
     and not exists (select 1 from visit_rows r where r.reversal_of = v.id);
$v724blk_lcbp_1_n$;
begin
  select pg_get_functiondef(to_regprocedure('public.lookup_client_by_phone(uuid,text)')) into v_def;
  if v_def is null then raise exception 'v724: public.lookup_client_by_phone(uuid,text) not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_count <> 1 then
    raise exception 'v724: lcbp anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  execute replace(v_def, v_anchor, v_new);

  select pg_get_functiondef(to_regprocedure('public.lookup_client_by_phone(uuid,text)')) into v_after;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v724: lcbp visit-day authority did not land';
  end if;
  v_roundtrip := replace(v_after, v_new, v_anchor);
  if v_roundtrip <> v_def then
    raise exception 'v724: lcbp changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$v724blk_lcbp_1$;
revoke all on function public.lookup_client_by_phone(uuid,text) from public, anon, authenticated, service_role;
grant execute on function public.lookup_client_by_phone(uuid,text) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 6 · public.get_attention_list_v548
-- ---------------------------------------------------------------------------------------------
do $v724blk_gal548_1$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('public.get_attention_list_v548(uuid,uuid,integer)')) into v_def;
  if v_def is null then raise exception 'v724: public.get_attention_list_v548(uuid,uuid,integer) not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, $v724agal_1$  with visits as (
    select s.client_id, s.occurred_at,
      app.v106_sale_residual_minor(s.id, v_now) as amount_cents,
      extract(epoch from (
        s.occurred_at - lag(s.occurred_at) over (
          partition by s.client_id order by s.occurred_at, s.id
        )
      )) / 86400.0 as interval_days
    from public.sales s
    where s.business_id = p_business
      and (p_branch is null or s.branch_id = p_branch)
      and s.client_id is not null
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at >= v_now - make_interval(days => v_window)
      and s.occurred_at < v_now
      and app.v106_sale_residual_minor(s.id, v_now) > 0
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id and r.reversal_of = s.id
      )
  ),
  metrics as (
$v724agal_1$, ''))) / length($v724agal_1$  with visits as (
    select s.client_id, s.occurred_at,
      app.v106_sale_residual_minor(s.id, v_now) as amount_cents,
      extract(epoch from (
        s.occurred_at - lag(s.occurred_at) over (
          partition by s.client_id order by s.occurred_at, s.id
        )
      )) / 86400.0 as interval_days
    from public.sales s
    where s.business_id = p_business
      and (p_branch is null or s.branch_id = p_branch)
      and s.client_id is not null
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at >= v_now - make_interval(days => v_window)
      and s.occurred_at < v_now
      and app.v106_sale_residual_minor(s.id, v_now) > 0
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id and r.reversal_of = s.id
      )
  ),
  metrics as (
$v724agal_1$);
  if v_count <> 1 then
    raise exception 'v724: gal548 anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, $v724agal_2$  with visits as (
    select s.client_id, s.occurred_at,
      app.v106_sale_residual_minor(s.id, v_now) as amount_cents,
      extract(epoch from (
        s.occurred_at - lag(s.occurred_at) over (
          partition by s.client_id order by s.occurred_at, s.id
        )
      )) / 86400.0 as interval_days
    from public.sales s
    where s.business_id = p_business
      and (p_branch is null or s.branch_id = p_branch)
      and s.client_id is not null
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at >= v_now - make_interval(days => v_window)
      and s.occurred_at < v_now
      and app.v106_sale_residual_minor(s.id, v_now) > 0
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id and r.reversal_of = s.id
      )
  ),
  metrics as (
$v724agal_2$, $v724rgal_3$  with raw_visits as (
    select s.client_id, s.occurred_at,
      app.v106_sale_residual_minor(s.id, v_now) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and (p_branch is null or s.branch_id = p_branch)
      and s.client_id is not null
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at >= v_now - make_interval(days => v_window)
      and s.occurred_at < v_now
      and app.v106_sale_residual_minor(s.id, v_now) > 0
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id and r.reversal_of = s.id
      )
  ),
  visit_days as (
    -- nestly_v724 (estate sweep 2): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699), anchored at the
    -- day's FIRST qualifying sale's occurred_at (same anchor rule as nestly_v709/v711/v714);
    -- amounts summed per day so average_transaction_cents/monthly_at_risk_cents totals reflect the
    -- true per-visit spend -- only the visit-count/cadence denominator collapses.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day,
           min(occurred_at) as occurred_at,
           sum(amount_cents) as amount_cents
    from raw_visits
    group by client_id, app.ci_visit_day_v699(occurred_at)
  ),
  visits as (
    select vd.client_id, vd.occurred_at, vd.amount_cents,
      extract(epoch from (
        vd.occurred_at - lag(vd.occurred_at) over (
          partition by vd.client_id order by vd.occurred_at
        )
      )) / 86400.0 as interval_days
    from visit_days vd
  ),
  metrics as (
$v724rgal_3$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_attention_list_v548(uuid,uuid,integer)')) into v_after;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v724: gal548 visit-day authority did not land';
  end if;
  v_roundtrip := replace(v_after, $v724rgal_4$  with raw_visits as (
    select s.client_id, s.occurred_at,
      app.v106_sale_residual_minor(s.id, v_now) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and (p_branch is null or s.branch_id = p_branch)
      and s.client_id is not null
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at >= v_now - make_interval(days => v_window)
      and s.occurred_at < v_now
      and app.v106_sale_residual_minor(s.id, v_now) > 0
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id and r.reversal_of = s.id
      )
  ),
  visit_days as (
    -- nestly_v724 (estate sweep 2): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699), anchored at the
    -- day's FIRST qualifying sale's occurred_at (same anchor rule as nestly_v709/v711/v714);
    -- amounts summed per day so average_transaction_cents/monthly_at_risk_cents totals reflect the
    -- true per-visit spend -- only the visit-count/cadence denominator collapses.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day,
           min(occurred_at) as occurred_at,
           sum(amount_cents) as amount_cents
    from raw_visits
    group by client_id, app.ci_visit_day_v699(occurred_at)
  ),
  visits as (
    select vd.client_id, vd.occurred_at, vd.amount_cents,
      extract(epoch from (
        vd.occurred_at - lag(vd.occurred_at) over (
          partition by vd.client_id order by vd.occurred_at
        )
      )) / 86400.0 as interval_days
    from visit_days vd
  ),
  metrics as (
$v724rgal_4$, $v724agal_5$  with visits as (
    select s.client_id, s.occurred_at,
      app.v106_sale_residual_minor(s.id, v_now) as amount_cents,
      extract(epoch from (
        s.occurred_at - lag(s.occurred_at) over (
          partition by s.client_id order by s.occurred_at, s.id
        )
      )) / 86400.0 as interval_days
    from public.sales s
    where s.business_id = p_business
      and (p_branch is null or s.branch_id = p_branch)
      and s.client_id is not null
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at >= v_now - make_interval(days => v_window)
      and s.occurred_at < v_now
      and app.v106_sale_residual_minor(s.id, v_now) > 0
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id and r.reversal_of = s.id
      )
  ),
  metrics as (
$v724agal_5$);
  if v_roundtrip <> v_def then
    raise exception 'v724: gal548 changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$v724blk_gal548_1$;
revoke all on function public.get_attention_list_v548(uuid,uuid,integer) from public, anon, authenticated, service_role;
grant execute on function public.get_attention_list_v548(uuid,uuid,integer) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 7 · public.get_ci_acquisition_v1 (anchored against the live body as nestly_v717 left it)
-- ---------------------------------------------------------------------------------------------
do $v724blk_gcav1_1$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_acquisition_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then raise exception 'v724: public.get_ci_acquisition_v1(uuid,date,date,uuid,timestamptz) not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, $v724agcav1_1$        'repeat_customers', count(*) filter (where (
          select count(*) from public.sales s
           where s.business_id = p_business and s.client_id = c.id
             and coalesce(s.counts_as_visit, false) and s.reversal_of is null
             and s.created_at <= p_as_of) >= 2)
$v724agcav1_1$, ''))) / length($v724agcav1_1$        'repeat_customers', count(*) filter (where (
          select count(*) from public.sales s
           where s.business_id = p_business and s.client_id = c.id
             and coalesce(s.counts_as_visit, false) and s.reversal_of is null
             and s.created_at <= p_as_of) >= 2)
$v724agcav1_1$);
  if v_count <> 1 then
    raise exception 'v724: gcav1 anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, $v724agcav1_2$        'repeat_customers', count(*) filter (where (
          select count(*) from public.sales s
           where s.business_id = p_business and s.client_id = c.id
             and coalesce(s.counts_as_visit, false) and s.reversal_of is null
             and s.created_at <= p_as_of) >= 2)
$v724agcav1_2$, $v724rgcav1_3$        'repeat_customers', count(*) filter (where (
          select count(distinct app.ci_visit_day_v699(s.occurred_at)) from public.sales s
           where s.business_id = p_business and s.client_id = c.id
             and coalesce(s.counts_as_visit, false) and s.reversal_of is null
             and s.created_at <= p_as_of) >= 2)
$v724rgcav1_3$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_acquisition_v1(uuid,date,date,uuid,timestamptz)')) into v_after;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v724: gcav1 visit-day authority did not land';
  end if;
  v_roundtrip := replace(v_after, $v724rgcav1_4$        'repeat_customers', count(*) filter (where (
          select count(distinct app.ci_visit_day_v699(s.occurred_at)) from public.sales s
           where s.business_id = p_business and s.client_id = c.id
             and coalesce(s.counts_as_visit, false) and s.reversal_of is null
             and s.created_at <= p_as_of) >= 2)
$v724rgcav1_4$, $v724agcav1_5$        'repeat_customers', count(*) filter (where (
          select count(*) from public.sales s
           where s.business_id = p_business and s.client_id = c.id
             and coalesce(s.counts_as_visit, false) and s.reversal_of is null
             and s.created_at <= p_as_of) >= 2)
$v724agcav1_5$);
  if v_roundtrip <> v_def then
    raise exception 'v724: gcav1 changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$v724blk_gcav1_1$;
revoke all on function public.get_ci_acquisition_v1(uuid,date,date,uuid,timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.get_ci_acquisition_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 8 · public.get_ci_demographics_v1
-- ---------------------------------------------------------------------------------------------
do $v724blk_gcdv1_1$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_demographics_v1(uuid,date,date,uuid,timestamptz)')) into v_def;
  if v_def is null then raise exception 'v724: public.get_ci_demographics_v1(uuid,date,date,uuid,timestamptz) not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, $v724agcdv1_1$  with qualifying as (
    select s.client_id, s.amount_cents,
           coalesce(s.counts_as_revenue, false) as is_revenue,
           coalesce(s.counts_as_visit, false) as is_visit
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and s.client_id is not null
       and not coalesce(c.is_synthetic, false)
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and s.created_at <= p_as_of
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and (coalesce(s.counts_as_revenue, false) or coalesce(s.counts_as_visit, false))
  ),
  client_agg as (
    select q.client_id,
           coalesce(sum(q.amount_cents) filter (where q.is_revenue), 0) as revenue_cents,
           count(*) filter (where q.is_revenue) as revenue_txns,
           count(*) filter (where q.is_visit) as visits
      from qualifying q
     group by q.client_id
  ),
$v724agcdv1_1$, ''))) / length($v724agcdv1_1$  with qualifying as (
    select s.client_id, s.amount_cents,
           coalesce(s.counts_as_revenue, false) as is_revenue,
           coalesce(s.counts_as_visit, false) as is_visit
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and s.client_id is not null
       and not coalesce(c.is_synthetic, false)
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and s.created_at <= p_as_of
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and (coalesce(s.counts_as_revenue, false) or coalesce(s.counts_as_visit, false))
  ),
  client_agg as (
    select q.client_id,
           coalesce(sum(q.amount_cents) filter (where q.is_revenue), 0) as revenue_cents,
           count(*) filter (where q.is_revenue) as revenue_txns,
           count(*) filter (where q.is_visit) as visits
      from qualifying q
     group by q.client_id
  ),
$v724agcdv1_1$);
  if v_count <> 1 then
    raise exception 'v724: gcdv1 anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, $v724agcdv1_2$  with qualifying as (
    select s.client_id, s.amount_cents,
           coalesce(s.counts_as_revenue, false) as is_revenue,
           coalesce(s.counts_as_visit, false) as is_visit
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and s.client_id is not null
       and not coalesce(c.is_synthetic, false)
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and s.created_at <= p_as_of
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and (coalesce(s.counts_as_revenue, false) or coalesce(s.counts_as_visit, false))
  ),
  client_agg as (
    select q.client_id,
           coalesce(sum(q.amount_cents) filter (where q.is_revenue), 0) as revenue_cents,
           count(*) filter (where q.is_revenue) as revenue_txns,
           count(*) filter (where q.is_visit) as visits
      from qualifying q
     group by q.client_id
  ),
$v724agcdv1_2$, $v724rgcdv1_3$  with qualifying as (
    select s.client_id, s.occurred_at, s.amount_cents,
           coalesce(s.counts_as_revenue, false) as is_revenue,
           coalesce(s.counts_as_visit, false) as is_visit
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and s.client_id is not null
       and not coalesce(c.is_synthetic, false)
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and s.created_at <= p_as_of
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and (coalesce(s.counts_as_revenue, false) or coalesce(s.counts_as_visit, false))
  ),
  client_agg as (
    select q.client_id,
           coalesce(sum(q.amount_cents) filter (where q.is_revenue), 0) as revenue_cents,
           count(*) filter (where q.is_revenue) as revenue_txns,
           -- nestly_v724 (estate sweep 2): distinct visit-days, not raw sale rows -- the one
           -- visit-day authority, app.ci_visit_day_v699 (nestly_v699).
           count(distinct app.ci_visit_day_v699(q.occurred_at)) filter (where q.is_visit) as visits
      from qualifying q
     group by q.client_id
  ),
$v724rgcdv1_3$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure(
    'public.get_ci_demographics_v1(uuid,date,date,uuid,timestamptz)')) into v_after;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v724: gcdv1 visit-day authority did not land';
  end if;
  v_roundtrip := replace(v_after, $v724rgcdv1_4$  with qualifying as (
    select s.client_id, s.occurred_at, s.amount_cents,
           coalesce(s.counts_as_revenue, false) as is_revenue,
           coalesce(s.counts_as_visit, false) as is_visit
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and s.client_id is not null
       and not coalesce(c.is_synthetic, false)
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and s.created_at <= p_as_of
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and (coalesce(s.counts_as_revenue, false) or coalesce(s.counts_as_visit, false))
  ),
  client_agg as (
    select q.client_id,
           coalesce(sum(q.amount_cents) filter (where q.is_revenue), 0) as revenue_cents,
           count(*) filter (where q.is_revenue) as revenue_txns,
           -- nestly_v724 (estate sweep 2): distinct visit-days, not raw sale rows -- the one
           -- visit-day authority, app.ci_visit_day_v699 (nestly_v699).
           count(distinct app.ci_visit_day_v699(q.occurred_at)) filter (where q.is_visit) as visits
      from qualifying q
     group by q.client_id
  ),
$v724rgcdv1_4$, $v724agcdv1_5$  with qualifying as (
    select s.client_id, s.amount_cents,
           coalesce(s.counts_as_revenue, false) as is_revenue,
           coalesce(s.counts_as_visit, false) as is_visit
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and s.client_id is not null
       and not coalesce(c.is_synthetic, false)
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and s.created_at <= p_as_of
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and (coalesce(s.counts_as_revenue, false) or coalesce(s.counts_as_visit, false))
  ),
  client_agg as (
    select q.client_id,
           coalesce(sum(q.amount_cents) filter (where q.is_revenue), 0) as revenue_cents,
           count(*) filter (where q.is_revenue) as revenue_txns,
           count(*) filter (where q.is_visit) as visits
      from qualifying q
     group by q.client_id
  ),
$v724agcdv1_5$);
  if v_roundtrip <> v_def then
    raise exception 'v724: gcdv1 changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$v724blk_gcdv1_1$;
revoke all on function public.get_ci_demographics_v1(uuid,date,date,uuid,timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.get_ci_demographics_v1(uuid,date,date,uuid,timestamptz) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 9 · public.staff_list_returned_customers_v300
-- ---------------------------------------------------------------------------------------------
do $v724blk_slrc300_1$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('public.staff_list_returned_customers_v300(uuid,integer,integer)')) into v_def;
  if v_def is null then raise exception 'v724: public.staff_list_returned_customers_v300(uuid,integer,integer) not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, $v724aslrc_1$  valid_visits as (
    -- validVisitSales, verbatim from v244: reversals are never visits; a reversed
    -- original is out. The two readers MUST agree on what a visit is.
    select v.client_id, v.occurred_at
    from visit_rows v
    where v.reversal_of is null
      and not exists (
        select 1 from visit_rows r where r.reversal_of = v.id
      )
  ),
  ordered as (
    select vv.client_id, vv.occurred_at,
           lag(vv.occurred_at) over (partition by vv.client_id order by vv.occurred_at) as previous_visit_at,
           row_number() over (partition by vv.client_id order by vv.occurred_at desc) as recency
    from valid_visits vv
  ),
$v724aslrc_1$, ''))) / length($v724aslrc_1$  valid_visits as (
    -- validVisitSales, verbatim from v244: reversals are never visits; a reversed
    -- original is out. The two readers MUST agree on what a visit is.
    select v.client_id, v.occurred_at
    from visit_rows v
    where v.reversal_of is null
      and not exists (
        select 1 from visit_rows r where r.reversal_of = v.id
      )
  ),
  ordered as (
    select vv.client_id, vv.occurred_at,
           lag(vv.occurred_at) over (partition by vv.client_id order by vv.occurred_at) as previous_visit_at,
           row_number() over (partition by vv.client_id order by vv.occurred_at desc) as recency
    from valid_visits vv
  ),
$v724aslrc_1$);
  if v_count <> 1 then
    raise exception 'v724: slrc300 anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, $v724aslrc_2$  valid_visits as (
    -- validVisitSales, verbatim from v244: reversals are never visits; a reversed
    -- original is out. The two readers MUST agree on what a visit is.
    select v.client_id, v.occurred_at
    from visit_rows v
    where v.reversal_of is null
      and not exists (
        select 1 from visit_rows r where r.reversal_of = v.id
      )
  ),
  ordered as (
    select vv.client_id, vv.occurred_at,
           lag(vv.occurred_at) over (partition by vv.client_id order by vv.occurred_at) as previous_visit_at,
           row_number() over (partition by vv.client_id order by vv.occurred_at desc) as recency
    from valid_visits vv
  ),
$v724aslrc_2$, $v724rslrc_3$  valid_visits as (
    -- validVisitSales, verbatim from v244: reversals are never visits; a reversed
    -- original is out. The two readers MUST agree on what a visit is.
    select v.client_id, v.occurred_at
    from visit_rows v
    where v.reversal_of is null
      and not exists (
        select 1 from visit_rows r where r.reversal_of = v.id
      )
  ),
  visit_days as (
    -- nestly_v724 (estate sweep 2): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699), anchored at the
    -- day's FIRST qualifying sale's occurred_at (same anchor rule as nestly_v709/v711/v714) --
    -- otherwise a same-day second sale on the RETURN visit itself becomes previous_visit_at and
    -- zeroes away_days, hiding a real multi-month lapse.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day,
           min(occurred_at) as occurred_at
    from valid_visits
    group by client_id, app.ci_visit_day_v699(occurred_at)
  ),
  ordered as (
    select vd.client_id, vd.occurred_at,
           lag(vd.occurred_at) over (partition by vd.client_id order by vd.occurred_at) as previous_visit_at,
           row_number() over (partition by vd.client_id order by vd.occurred_at desc) as recency
    from visit_days vd
  ),
$v724rslrc_3$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.staff_list_returned_customers_v300(uuid,integer,integer)')) into v_after;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v724: slrc300 visit-day authority did not land';
  end if;
  v_roundtrip := replace(v_after, $v724rslrc_4$  valid_visits as (
    -- validVisitSales, verbatim from v244: reversals are never visits; a reversed
    -- original is out. The two readers MUST agree on what a visit is.
    select v.client_id, v.occurred_at
    from visit_rows v
    where v.reversal_of is null
      and not exists (
        select 1 from visit_rows r where r.reversal_of = v.id
      )
  ),
  visit_days as (
    -- nestly_v724 (estate sweep 2): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699), anchored at the
    -- day's FIRST qualifying sale's occurred_at (same anchor rule as nestly_v709/v711/v714) --
    -- otherwise a same-day second sale on the RETURN visit itself becomes previous_visit_at and
    -- zeroes away_days, hiding a real multi-month lapse.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day,
           min(occurred_at) as occurred_at
    from valid_visits
    group by client_id, app.ci_visit_day_v699(occurred_at)
  ),
  ordered as (
    select vd.client_id, vd.occurred_at,
           lag(vd.occurred_at) over (partition by vd.client_id order by vd.occurred_at) as previous_visit_at,
           row_number() over (partition by vd.client_id order by vd.occurred_at desc) as recency
    from visit_days vd
  ),
$v724rslrc_4$, $v724aslrc_5$  valid_visits as (
    -- validVisitSales, verbatim from v244: reversals are never visits; a reversed
    -- original is out. The two readers MUST agree on what a visit is.
    select v.client_id, v.occurred_at
    from visit_rows v
    where v.reversal_of is null
      and not exists (
        select 1 from visit_rows r where r.reversal_of = v.id
      )
  ),
  ordered as (
    select vv.client_id, vv.occurred_at,
           lag(vv.occurred_at) over (partition by vv.client_id order by vv.occurred_at) as previous_visit_at,
           row_number() over (partition by vv.client_id order by vv.occurred_at desc) as recency
    from valid_visits vv
  ),
$v724aslrc_5$);
  if v_roundtrip <> v_def then
    raise exception 'v724: slrc300 changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$v724blk_slrc300_1$;
revoke all on function public.staff_list_returned_customers_v300(uuid,integer,integer) from public, anon, authenticated, service_role;
grant execute on function public.staff_list_returned_customers_v300(uuid,integer,integer) to public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 10 · app.ci_visit_registry_v699 -- eleven new entries, one per reader named above (including
--      the two that inherit without a code patch: app.v177_overview and
--      public.staff_scan_member_qr_v327).
-- ---------------------------------------------------------------------------------------------
do $v724blk_reg_1$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('app.ci_visit_registry_v699()')) into v_def;
  if v_def is null then raise exception 'v724: app.ci_visit_registry_v699() not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, $v724areg_1$      'platform_get_enterprise_hierarchy_v82', jsonb_build_object(
        'uses_authority', true,
        'note', 'returning_customers'' per-client having-clause counts distinct visit-days, not raw sale rows (nestly_v714, check 4)')
    )
  );
$function$
$v724areg_1$, ''))) / length($v724areg_1$      'platform_get_enterprise_hierarchy_v82', jsonb_build_object(
        'uses_authority', true,
        'note', 'returning_customers'' per-client having-clause counts distinct visit-days, not raw sale rows (nestly_v714, check 4)')
    )
  );
$function$
$v724areg_1$);
  if v_count <> 1 then
    raise exception 'v724: registry anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, $v724areg_2$      'platform_get_enterprise_hierarchy_v82', jsonb_build_object(
        'uses_authority', true,
        'note', 'returning_customers'' per-client having-clause counts distinct visit-days, not raw sale rows (nestly_v714, check 4)')
    )
  );
$function$
$v724areg_2$, $v724rreg_3$      'platform_get_enterprise_hierarchy_v82', jsonb_build_object(
        'uses_authority', true,
        'note', 'returning_customers'' per-client having-clause counts distinct visit-days, not raw sale rows (nestly_v714, check 4)'),
      'app.v176_sales_window', jsonb_build_object(
        'uses_authority', true,
        'note', 'the firm-wide visits figure counts distinct (client, visit-day) pairs, plus one count per unidentified walk-in sale, the same shape as nestly_v714''s get_dashboard_summary fix (nestly_v724, estate sweep 2)'),
      'app.v177_sales_window', jsonb_build_object(
        'uses_authority', true,
        'note', 'branch-scoped twin of app.v176_sales_window; same distinct visit-day fix (nestly_v724, estate sweep 2)'),
      'app.v177_customers', jsonb_build_object(
        'uses_authority', true,
        'note', 'each recent-joiner''s visit_count is a distinct-visit-day count (nestly_v724, estate sweep 2)'),
      'app.v177_overview', jsonb_build_object(
        'uses_authority', true,
        'note', 'computes no visit count of its own; sales.current/prior/growth.visits_delta all read app.v176_sales_window/app.v177_sales_window''s already-fixed visits figure, so this reader inherits without its own patch (nestly_v724, estate sweep 2)'),
      'app.v666_till_customer_card', jsonb_build_object(
        'uses_authority', true,
        'note', 'the till customer card''s visits field counts distinct visit-days (nestly_v724, estate sweep 2)'),
      'public.lookup_client_by_phone', jsonb_build_object(
        'uses_authority', true,
        'note', 'the phone-lookup customer card''s visits field counts distinct visit-days, the same shape as app.v666_till_customer_card (nestly_v724, estate sweep 2)'),
      'public.staff_scan_member_qr_v327', jsonb_build_object(
        'uses_authority', true,
        'note', 'computes no visit count of its own; the returned customer card is built entirely by app.v666_till_customer_card, so this reader inherits without its own patch (nestly_v724, estate sweep 2)'),
      'public.get_attention_list_v548', jsonb_build_object(
        'uses_authority', true,
        'note', 'prior_visits (the >=3 eligibility floor) and cadence_days (the lag() interval sequence feeding the due/overdue/slipping thresholds) are both computed over distinct visit-days, anchored at each day''s first qualifying sale; the same anchor rule as nestly_v709/v711/v714 (nestly_v724, estate sweep 2)'),
      'public.get_ci_acquisition_v1', jsonb_build_object(
        'uses_authority', true,
        'note', 'repeat_customers counts distinct visit-days, not raw revenue transactions; a same-day split bill no longer flips a one-visit customer to repeat (nestly_v724, estate sweep 2)'),
      'public.get_ci_demographics_v1', jsonb_build_object(
        'uses_authority', true,
        'note', 'each demographic cell''s visits figure sums distinct visit-days per customer, not raw sale rows (nestly_v724, estate sweep 2)'),
      'public.staff_list_returned_customers_v300', jsonb_build_object(
        'uses_authority', true,
        'note', 'previous_visit_at / away_days are computed over distinct visit-days; a same-day split bill on the return visit itself can no longer become its own previous_visit_at and zero away_days, hiding a real lapse (nestly_v724, estate sweep 2)')
    )
  );
$function$
$v724rreg_3$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('app.ci_visit_registry_v699()')) into v_after;
  if position('app.v176_sales_window' in v_after) = 0
     or position('public.staff_list_returned_customers_v300' in v_after) = 0 then
    raise exception 'v724: registry new entries did not land';
  end if;
  v_roundtrip := replace(v_after, $v724rreg_4$      'platform_get_enterprise_hierarchy_v82', jsonb_build_object(
        'uses_authority', true,
        'note', 'returning_customers'' per-client having-clause counts distinct visit-days, not raw sale rows (nestly_v714, check 4)'),
      'app.v176_sales_window', jsonb_build_object(
        'uses_authority', true,
        'note', 'the firm-wide visits figure counts distinct (client, visit-day) pairs, plus one count per unidentified walk-in sale, the same shape as nestly_v714''s get_dashboard_summary fix (nestly_v724, estate sweep 2)'),
      'app.v177_sales_window', jsonb_build_object(
        'uses_authority', true,
        'note', 'branch-scoped twin of app.v176_sales_window; same distinct visit-day fix (nestly_v724, estate sweep 2)'),
      'app.v177_customers', jsonb_build_object(
        'uses_authority', true,
        'note', 'each recent-joiner''s visit_count is a distinct-visit-day count (nestly_v724, estate sweep 2)'),
      'app.v177_overview', jsonb_build_object(
        'uses_authority', true,
        'note', 'computes no visit count of its own; sales.current/prior/growth.visits_delta all read app.v176_sales_window/app.v177_sales_window''s already-fixed visits figure, so this reader inherits without its own patch (nestly_v724, estate sweep 2)'),
      'app.v666_till_customer_card', jsonb_build_object(
        'uses_authority', true,
        'note', 'the till customer card''s visits field counts distinct visit-days (nestly_v724, estate sweep 2)'),
      'public.lookup_client_by_phone', jsonb_build_object(
        'uses_authority', true,
        'note', 'the phone-lookup customer card''s visits field counts distinct visit-days, the same shape as app.v666_till_customer_card (nestly_v724, estate sweep 2)'),
      'public.staff_scan_member_qr_v327', jsonb_build_object(
        'uses_authority', true,
        'note', 'computes no visit count of its own; the returned customer card is built entirely by app.v666_till_customer_card, so this reader inherits without its own patch (nestly_v724, estate sweep 2)'),
      'public.get_attention_list_v548', jsonb_build_object(
        'uses_authority', true,
        'note', 'prior_visits (the >=3 eligibility floor) and cadence_days (the lag() interval sequence feeding the due/overdue/slipping thresholds) are both computed over distinct visit-days, anchored at each day''s first qualifying sale; the same anchor rule as nestly_v709/v711/v714 (nestly_v724, estate sweep 2)'),
      'public.get_ci_acquisition_v1', jsonb_build_object(
        'uses_authority', true,
        'note', 'repeat_customers counts distinct visit-days, not raw revenue transactions; a same-day split bill no longer flips a one-visit customer to repeat (nestly_v724, estate sweep 2)'),
      'public.get_ci_demographics_v1', jsonb_build_object(
        'uses_authority', true,
        'note', 'each demographic cell''s visits figure sums distinct visit-days per customer, not raw sale rows (nestly_v724, estate sweep 2)'),
      'public.staff_list_returned_customers_v300', jsonb_build_object(
        'uses_authority', true,
        'note', 'previous_visit_at / away_days are computed over distinct visit-days; a same-day split bill on the return visit itself can no longer become its own previous_visit_at and zero away_days, hiding a real lapse (nestly_v724, estate sweep 2)')
    )
  );
$function$
$v724rreg_4$, $v724areg_5$      'platform_get_enterprise_hierarchy_v82', jsonb_build_object(
        'uses_authority', true,
        'note', 'returning_customers'' per-client having-clause counts distinct visit-days, not raw sale rows (nestly_v714, check 4)')
    )
  );
$function$
$v724areg_5$);
  if v_roundtrip <> v_def then
    raise exception 'v724: registry changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
end
$v724blk_reg_1$;
revoke all on function app.ci_visit_registry_v699() from public, anon, authenticated, service_role;
grant execute on function app.ci_visit_registry_v699() to service_role;

commit;
