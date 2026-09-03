-- NESTLY v714 — check 4 refutation (estate sweep): a same-day split bill was still inflating
-- ten more visits/repeat/returning figures the nestly_v699/v709/v711 sweeps had not reached —
-- the owner-facing customer dashboard, the platform console, and two more Customer Intelligence
-- readers.
--
-- Contract: docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md (v672, frozen). Fixture guide:
-- docs/qa/CI-CORPUS-FIXTURE-GUIDE.md. Proven by
-- db/tests/executed/v714_corpus_visit_days_estate.sql.
--
-- ============================================================================================
-- WHAT WAS WRONG (check 4, estate refutation). Seeded two clients — R with 3 same-day sales
-- (a split bill) + 1 sale the next day + 1 sale a week later (3 true visit-days, 5 raw sale
-- rows), and C with 5 sales on 5 distinct days (5 true visit-days, 5 raw sale rows) — and called
-- every remaining visits/repeat/returning-shaped reader in the estate that nestly_v699/v709/v711
-- had not yet reached:
--
--   1. public.get_customer_intelligence_v83 — period_visits.visit_count was count(*) over
--      valid_period_visits (raw sale rows); returning_customer was
--      purchase.purchase_count>=2, itself a raw-row count over the revenue population, so a
--      same-day double-charge could flip a one-visit customer to "returning".
--   2. public.get_dashboard_summary / _v154 / _v155 — the 'visits' KPI was count(*) over
--      valid_visits (raw sale rows: R+C together read 10, not the true 8 visit-days); v154/v155's
--      repeat_customers/repeat_customer_percentage grouped the SAME raw rows with
--      having count(*)>=2, so R's split bill alone made R "repeat" off one afternoon.
--   3. public.retention_lapsed_candidates_v244 — per_client.net_visits was count(*) over
--      valid_visits, feeding both the p_min_visits floor and the returned net_visits figure.
--   4. public.get_recovery_report_v550 — the `visits` CTE lagged over raw sale rows, so
--      judged.prior_visits (the >=1-prior-visit eligibility gate) and window_cents both counted a
--      split bill as several visits.
--   5. app.ci_customer_classes_v1 — v_visits_180d (the `loyal` class's >=6-visits-in-180-days
--      gate, and the `at_risk`/`loyal` mutual-exclusion built on it) was count(*) over the same
--      180-day window, raw rows.
--   6. public.platform_generate_improvement_report_v82 — period_customers.visit_count was
--      count(*) filter(...) over sale rows; every downstream 'active_customers'/
--      'returning_customers' figure at customer, business and currency scope reads this same
--      column, so all of them inherited the inflation.
--   7. public.platform_list_enterprise_customers_v82 — the per-client lateral join's visit_count
--      was the same count(*) filter(...) shape, feeding both the exposed visit_count field and
--      returning_customer (visit_count>=2).
--   8. public.platform_get_assigned_firm_report_v94 — kpis.visits was a firm-wide count(*) over
--      valid_sales; returning_customers read customer_metrics.purchases>=2, where `purchases` is
--      count(valid_sales.id) — the SAME column the champions/loyal/at_risk cohort classifier
--      reads, so it could not simply be redefined without silently moving cohort thresholds too
--      (see WHAT THIS DOES below for how that conflict is avoided).
--   9. public.platform_get_enterprise_hierarchy_v82 — the per-firm returning_customers subquery
--      grouped raw sale rows by client_id with `having count(*)>=2`.
--
-- None of these are covered by nestly_v699's app.ci_visit_registry_v699 fixture, nestly_v709's
-- cadence/tier fixture, or nestly_v711's bring-back fixture — each proves only the readers it
-- names. This migration closes the remaining estate for visits/repeat/returning figures built
-- directly on sales, using the SAME authority (app.ci_visit_day_v699, nestly_v699) throughout.
--
-- ============================================================================================
-- WHAT THIS DOES. Nine extract-and-diff patches against the LIVE pg_get_functiondef body of each
-- function (anchored on the body exactly as it stands post-v711/v712, never an assumed source
-- formatting — same discipline as v668/v690/v699/v709/v711), plus the registry and dictionary:
--
--   (1) get_customer_intelligence_v83 — period_visits.visit_count becomes
--       count(distinct app.ci_visit_day_v699(sale.occurred_at)). returning_customer is NOT
--       redefined off purchase_count (that column also feeds average_revenue_per_purchase_cents,
--       a legitimate per-transaction figure this migration leaves alone) — instead
--       period_purchases gains a new purchase_day_count column
--       (count(distinct app.ci_visit_day_v699(...))), and returning_customer reads THAT. The
--       methodology text for 'returning_customer' is updated to say so.
--   (2) get_dashboard_summary / _v154 / _v155 — a new visit_days CTE collapses valid_visits to
--       distinct (client_id, visit-day) pairs (client_id is not null; an unattributed walk-in
--       sale cannot be deduped by identity and still counts on its own). 'visits' becomes
--       count(*) from visit_days plus the walk-in count. v154/v155's repeaters CTE groups
--       visit_days instead of raw sale rows, so repeat_customers/repeat_customer_percentage move
--       to the same distinct-day basis. The worked truth table this migration's fixture asserts:
--       R (3 same-day + 1 next-day + 1 a week later) collapses to 3 visit-days; C (5 distinct
--       days) stays 5; combined visits KPI 10 raw sales -> 8 visit-days.
--   (3) retention_lapsed_candidates_v244 — per_client.net_visits becomes
--       count(distinct app.ci_visit_day_v699(vv.occurred_at)), feeding both the p_min_visits
--       floor and the returned net_visits figure.
--   (4) get_recovery_report_v550 — the `visits` CTE is renamed conceptually but not textually:
--       a new raw_visits CTE holds the old per-sale query verbatim, and `visits` becomes a
--       day-collapse over it (visit-day anchored at that day's first qualifying sale, amounts
--       SUMMED per day so window_cents/gross_cents totals are unchanged — only the visit-count
--       denominator collapses). Every downstream reference (`visits v`, v.client_id,
--       v.occurred_at, v.amount_cents, in judged/eligible/baseline_cohort/baseline) is
--       byte-identical and untouched, because the CTE's own output shape did not change — the
--       same technique nestly_v709 used for app.customer_cadence_batch_v1 and nestly_v711 used
--       for refresh_growth_recommendation_v108.
--   (5) ci_customer_classes_v1 — v_visits_180d's count(*) becomes
--       count(distinct app.ci_visit_day_v699(occurred_at)), cascading automatically into the
--       `loyal` class (>=6 gate) and the at_risk/loyal mutual-exclusion built on it (no separate
--       edit needed there — same cascade-by-construction nestly_v709 relied on for
--       tier_resolve_v426's five delegates).
--   (6) platform_generate_improvement_report_v82 — period_customers.visit_count becomes
--       count(distinct app.ci_visit_day_v699(sale.occurred_at)) filter(...). Every
--       'active_customers'/'returning_customers' figure at customer_metrics, business_metrics and
--       currency_metrics scope reads this one column, so the fix cascades to all of them without
--       touching the business/branch/currency CTEs themselves. The 'returning_customer'
--       methodology text is updated to match.
--   (7) platform_list_enterprise_customers_v82 — the per-client lateral join's visit_count
--       becomes the same count(distinct ...) filter(...) shape; both the exposed visit_count
--       field and returning_customer (visit_count>=2) inherit the fix from this one column.
--   (8) platform_get_assigned_firm_report_v94 — customer_metrics gains a NEW visit_days column
--       (count(distinct app.ci_visit_day_v699(...)) filter (where counts_as_visit)), deliberately
--       SEPARATE from the existing `purchases` column (count(valid_sales.id)) that the
--       champions/loyal/at_risk/new/lapsed cohort classifier and customer_intelligence block
--       still read unchanged — redefining `purchases` itself would have silently moved cohort
--       thresholds, which this check does not ask for and no fixture covers. kpis.visits becomes
--       a firm-wide distinct (client_id, visit-day) count plus one per unidentified walk-in sale
--       (same shape as get_dashboard_summary); kpis.returning_customers moves from
--       `purchases>=2` to the new `visit_days>=2`.
--   (9) platform_get_enterprise_hierarchy_v82 — the returning_customers subquery's
--       `having count(*)>=2` becomes
--       `having count(distinct app.ci_visit_day_v699(sale.occurred_at))>=2`; grouped by
--       sale.client_id already, so this is the smallest possible fix.
--
-- (10) app.ci_visit_registry_v699 — extract-and-diff, anchored on its current last entry
--      (refresh_growth_recommendation_v108, nestly_v711): eleven new entries, one per function
--      fixed above, each uses_authority=true. A second anchor on the EXISTING
--      app.v179_business_insights entry adds a `caveat` field only — 'top_customers/
--      lifetime_visits/weekday_pattern all count distinct visit-days (nestly_v699, nestly_v715)' —
--      without touching app.v179_business_insights' own body. TWO sibling migrations landed while
--      this one was in flight and are both folded into that caveat's final wording: nestly_v706
--      (committed) re-emitted app.v179_business_insights to bucket weekday_pattern by the
--      resolved branch clock instead of a hardcoded Asia/Singapore — a real fix, but a DIFFERENT
--      dimension (which timezone a sale's weekday bucket uses) from this migration's check 4
--      (whether a same-day split bill counts once); v706's own header says weekday_pattern still
--      counted raw sale rows per bucket after it landed. nestly_v715 (committed f7c84f2e) then
--      closed that exact gap: weekday_pattern.visits now dedupes by (client_id,
--      app.ci_visit_day_v699(occurred_at)), the same authority every other figure in this
--      registry uses — v715's own header records that its registry entry (this one) was left
--      stale on purpose, owed to whoever next re-emits app.ci_visit_registry_v699. That is this
--      migration, so the caveat is worded for the fully-applied chain (v714 then v715), not the
--      transient instant between them — no client ever observes that instant, since a migration
--      run applies the whole ordered chain before serving anything.
--
-- (11) app.ci_metric_dictionary_v1 — extract-and-diff, replacing the whole 'visit' entry: it
--      named app.ci_visit_day_v699 as the one authority (rather than disclosing a v107-vs-v673
--      divergence that nestly_v699/v709/v711/v714 have now closed for every reader this registry
--      names), and states the one remaining owed item — see CLIENT-SIDE DRILL-DOWN below.
--
-- ============================================================================================
-- CLIENT-SIDE DRILL-DOWN — OWED, NOT FIXED HERE. app/app.js's owner-dashboard "Visits" KPI tile
-- opens a detail dialog (grep: `key==='visits'?validVisitSales(data||[])...`, the block ending
-- `${key==='visits'?esc(String(row.kind||''))...}`) that queries `public.sales` directly via
-- supabase-js and lists ONE ROW PER RAW SALE — it does not call get_dashboard_summary_v155 or any
-- day-deduped reader, and it has no visit-day collapse of its own. After this migration the
-- Visits tile itself shows 8 (R+C truth table above) while the drill-down dialog it opens still
-- lists all 10 rows — the dialog and the tile it belongs to now visibly disagree. This is a
-- browser-only file (`app/app.js` is the sole editable source per docs/design/PEEKAA-UI-STANDARD.
-- md; every other app-*.js is generated) and this migration touches only the database, so the fix
-- is OWED: collapse that dialog's rows to one per (client_id, calendar day) — anchored at the
-- day's first sale, matching every server-side fix in this migration — the next time app/app.js is
-- touched, and re-run `npm run bundle-stamp`.
--
-- ============================================================================================
-- NOT TOUCHED (explicitly out of scope for this migration):
--   - app.v179_business_insights (nestly_v706 already re-emitted it for the branch-clock sweep,
--     landed and committed while this migration was in flight; this migration only adds a
--     `caveat` field to its REGISTRY entry, never touches v179's own body).
--   - public.get_ci_opportunities_v1 (nestly_v712, a sibling migration touching it for
--     spine-wording closures).
--   - the AI evidence-pack builder (nestly_v713 — landed and committed while this migration was
--     in flight; not referenced by anything this migration changes).
--   - every fixture named in the corpus guide's existing-fixture check (v422, v554, v652, v684)
--     was verified BEFORE writing this migration to seed only distinct-calendar-day sales per
--     client for every one of the ten (eleven) functions above, so this migration's visit-day
--     collapse is a no-op for all of them and their existing truth tables hold exactly as written.
-- ============================================================================================
begin;

do $v714blk_ccc_1$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('app.ci_customer_classes_v1(uuid,uuid,timestamptz)')) into v_def;
  if v_def is null then raise exception 'v714: app.ci_customer_classes_v1(uuid,uuid,timestamptz) not found'; end if;

  -- anchor: visits_last_180d
  v_count := (length(v_def) - length(replace(v_def, $v714accc02$  )
  select
    count(*) filter (
      where occurred_at >= p_as_of - interval '180 days' and occurred_at <= p_as_of
    )::integer,
    min(occurred_at)
    into v_visits_180d, v_first_visit_at
    from elig;
$v714accc02$, ''))) / length($v714accc02$  )
  select
    count(*) filter (
      where occurred_at >= p_as_of - interval '180 days' and occurred_at <= p_as_of
    )::integer,
    min(occurred_at)
    into v_visits_180d, v_first_visit_at
    from elig;
$v714accc02$);
  if v_count <> 1 then
    raise exception 'v714: ccc anchor (visits_last_180d) occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := v_def;
  v_expected := replace(v_expected, $v714accc03$  )
  select
    count(*) filter (
      where occurred_at >= p_as_of - interval '180 days' and occurred_at <= p_as_of
    )::integer,
    min(occurred_at)
    into v_visits_180d, v_first_visit_at
    from elig;
$v714accc03$, $v714rccc04$  )
  select
    count(distinct app.ci_visit_day_v699(occurred_at)) filter (
      where occurred_at >= p_as_of - interval '180 days' and occurred_at <= p_as_of
    )::integer,
    min(occurred_at)
    into v_visits_180d, v_first_visit_at
    from elig;
$v714rccc04$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('app.ci_customer_classes_v1(uuid,uuid,timestamptz)')) into v_after;
  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $v714rccc06$  )
  select
    count(distinct app.ci_visit_day_v699(occurred_at)) filter (
      where occurred_at >= p_as_of - interval '180 days' and occurred_at <= p_as_of
    )::integer,
    min(occurred_at)
    into v_visits_180d, v_first_visit_at
    from elig;
$v714rccc06$, $v714accc05$  )
  select
    count(*) filter (
      where occurred_at >= p_as_of - interval '180 days' and occurred_at <= p_as_of
    )::integer,
    min(occurred_at)
    into v_visits_180d, v_first_visit_at
    from elig;
$v714accc05$);
  if v_roundtrip <> v_def then
    raise exception 'v714: ccc changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v714: ccc visit-day authority did not land';
  end if;
end
$v714blk_ccc_1$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function app.ci_customer_classes_v1(uuid,uuid,timestamptz) from public, anon;
grant execute on function app.ci_customer_classes_v1(uuid,uuid,timestamptz) to service_role;

do $v714blk_ci83_7$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid)')) into v_def;
  if v_def is null then raise exception 'v714: public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid) not found'; end if;

  -- anchor: period_purchases/period_visits
  v_count := (length(v_def) - length(replace(v_def, $v714aci8308$  ),period_purchases as (
    select sale.client_id,count(*)::integer purchase_count,
           min(sale.occurred_at) period_first_purchase_at,
           max(sale.occurred_at) period_last_purchase_at
    from valid_period_purchases sale where sale.client_id is not null
    group by sale.client_id
  ),period_visits as (
    select sale.client_id,count(*)::integer visit_count
    from valid_period_visits sale where sale.client_id is not null
    group by sale.client_id
  ),period_cash as (
$v714aci8308$, ''))) / length($v714aci8308$  ),period_purchases as (
    select sale.client_id,count(*)::integer purchase_count,
           min(sale.occurred_at) period_first_purchase_at,
           max(sale.occurred_at) period_last_purchase_at
    from valid_period_purchases sale where sale.client_id is not null
    group by sale.client_id
  ),period_visits as (
    select sale.client_id,count(*)::integer visit_count
    from valid_period_visits sale where sale.client_id is not null
    group by sale.client_id
  ),period_cash as (
$v714aci8308$);
  if v_count <> 1 then
    raise exception 'v714: ci83 anchor (period_purchases/period_visits) occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  -- anchor: returning_customer
  v_count := (length(v_def) - length(replace(v_def, $v714aci8319$           coalesce(purchase.purchase_count,0)>=2 returning_customer,
$v714aci8319$, ''))) / length($v714aci8319$           coalesce(purchase.purchase_count,0)>=2 returning_customer,
$v714aci8319$);
  if v_count <> 1 then
    raise exception 'v714: ci83 anchor (returning_customer) occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  -- anchor: methodology text
  v_count := (length(v_def) - length(replace(v_def, $v714aci83210$      'returning_customer','At least two completed unreversed revenue transactions in the selected period.',
$v714aci83210$, ''))) / length($v714aci83210$      'returning_customer','At least two completed unreversed revenue transactions in the selected period.',
$v714aci83210$);
  if v_count <> 1 then
    raise exception 'v714: ci83 anchor (methodology text) occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := v_def;
  v_expected := replace(v_expected, $v714aci83011$  ),period_purchases as (
    select sale.client_id,count(*)::integer purchase_count,
           min(sale.occurred_at) period_first_purchase_at,
           max(sale.occurred_at) period_last_purchase_at
    from valid_period_purchases sale where sale.client_id is not null
    group by sale.client_id
  ),period_visits as (
    select sale.client_id,count(*)::integer visit_count
    from valid_period_visits sale where sale.client_id is not null
    group by sale.client_id
  ),period_cash as (
$v714aci83011$, $v714rci83012$  ),period_purchases as (
    select sale.client_id,count(*)::integer purchase_count,
           count(distinct app.ci_visit_day_v699(sale.occurred_at))::integer purchase_day_count,
           min(sale.occurred_at) period_first_purchase_at,
           max(sale.occurred_at) period_last_purchase_at
    from valid_period_purchases sale where sale.client_id is not null
    group by sale.client_id
  ),period_visits as (
    select sale.client_id,count(distinct app.ci_visit_day_v699(sale.occurred_at))::integer visit_count
    from valid_period_visits sale where sale.client_id is not null
    group by sale.client_id
  ),period_cash as (
$v714rci83012$);
  v_expected := replace(v_expected, $v714aci83113$           coalesce(purchase.purchase_count,0)>=2 returning_customer,
$v714aci83113$, $v714rci83114$           coalesce(purchase.purchase_day_count,0)>=2 returning_customer,
$v714rci83114$);
  v_expected := replace(v_expected, $v714aci83215$      'returning_customer','At least two completed unreversed revenue transactions in the selected period.',
$v714aci83215$, $v714rci83216$      'returning_customer','At least two completed unreversed revenue transactions on distinct days (Asia/Singapore) in the selected period; a same-day split bill counts once.',
$v714rci83216$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid)')) into v_after;
  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $v714rci83018$  ),period_purchases as (
    select sale.client_id,count(*)::integer purchase_count,
           count(distinct app.ci_visit_day_v699(sale.occurred_at))::integer purchase_day_count,
           min(sale.occurred_at) period_first_purchase_at,
           max(sale.occurred_at) period_last_purchase_at
    from valid_period_purchases sale where sale.client_id is not null
    group by sale.client_id
  ),period_visits as (
    select sale.client_id,count(distinct app.ci_visit_day_v699(sale.occurred_at))::integer visit_count
    from valid_period_visits sale where sale.client_id is not null
    group by sale.client_id
  ),period_cash as (
$v714rci83018$, $v714aci83017$  ),period_purchases as (
    select sale.client_id,count(*)::integer purchase_count,
           min(sale.occurred_at) period_first_purchase_at,
           max(sale.occurred_at) period_last_purchase_at
    from valid_period_purchases sale where sale.client_id is not null
    group by sale.client_id
  ),period_visits as (
    select sale.client_id,count(*)::integer visit_count
    from valid_period_visits sale where sale.client_id is not null
    group by sale.client_id
  ),period_cash as (
$v714aci83017$);
  v_roundtrip := replace(v_roundtrip, $v714rci83120$           coalesce(purchase.purchase_day_count,0)>=2 returning_customer,
$v714rci83120$, $v714aci83119$           coalesce(purchase.purchase_count,0)>=2 returning_customer,
$v714aci83119$);
  v_roundtrip := replace(v_roundtrip, $v714rci83222$      'returning_customer','At least two completed unreversed revenue transactions on distinct days (Asia/Singapore) in the selected period; a same-day split bill counts once.',
$v714rci83222$, $v714aci83221$      'returning_customer','At least two completed unreversed revenue transactions in the selected period.',
$v714aci83221$);
  if v_roundtrip <> v_def then
    raise exception 'v714: ci83 changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v714: ci83 visit-day authority did not land';
  end if;
end
$v714blk_ci83_7$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid) from public;
grant execute on function public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid) to anon, authenticated, service_role;

do $v714blk_dsb_23$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('public.get_dashboard_summary(uuid,date,date,uuid)')) into v_def;
  if v_def is null then raise exception 'v714: public.get_dashboard_summary(uuid,date,date,uuid) not found'; end if;

  -- anchor: visits KPI
  v_count := (length(v_def) - length(replace(v_def, $v714adsb024$  ), valid_visits as (
    select s.*
    from scoped_sales s
    where s.counts_as_visit
      and s.reversal_of is null
      and not exists (
        select 1
        from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  )
  select jsonb_build_object(
    'visits', (select count(*) from valid_visits),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue), 0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null)
  )
  into v_kpis;
$v714adsb024$, ''))) / length($v714adsb024$  ), valid_visits as (
    select s.*
    from scoped_sales s
    where s.counts_as_visit
      and s.reversal_of is null
      and not exists (
        select 1
        from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  )
  select jsonb_build_object(
    'visits', (select count(*) from valid_visits),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue), 0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null)
  )
  into v_kpis;
$v714adsb024$);
  if v_count <> 1 then
    raise exception 'v714: dsb anchor (visits KPI) occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := v_def;
  v_expected := replace(v_expected, $v714adsb025$  ), valid_visits as (
    select s.*
    from scoped_sales s
    where s.counts_as_visit
      and s.reversal_of is null
      and not exists (
        select 1
        from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  )
  select jsonb_build_object(
    'visits', (select count(*) from valid_visits),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue), 0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null)
  )
  into v_kpis;
$v714adsb025$, $v714rdsb026$  ), valid_visits as (
    select s.*
    from scoped_sales s
    where s.counts_as_visit
      and s.reversal_of is null
      and not exists (
        select 1
        from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  ), visit_days as (
    -- nestly_v714 (check 4 fix): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699). Sales with no
    -- client_id (walk-ins) cannot be deduped by customer identity, so each still counts on its own
    -- below.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day
    from valid_visits
    where client_id is not null
    group by client_id, app.ci_visit_day_v699(occurred_at)
  )
  select jsonb_build_object(
    'visits', (select count(*) from visit_days) + (select count(*) from valid_visits where client_id is null),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue), 0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null)
  )
  into v_kpis;
$v714rdsb026$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_dashboard_summary(uuid,date,date,uuid)')) into v_after;
  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $v714rdsb028$  ), valid_visits as (
    select s.*
    from scoped_sales s
    where s.counts_as_visit
      and s.reversal_of is null
      and not exists (
        select 1
        from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  ), visit_days as (
    -- nestly_v714 (check 4 fix): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699). Sales with no
    -- client_id (walk-ins) cannot be deduped by customer identity, so each still counts on its own
    -- below.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day
    from valid_visits
    where client_id is not null
    group by client_id, app.ci_visit_day_v699(occurred_at)
  )
  select jsonb_build_object(
    'visits', (select count(*) from visit_days) + (select count(*) from valid_visits where client_id is null),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue), 0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null)
  )
  into v_kpis;
$v714rdsb028$, $v714adsb027$  ), valid_visits as (
    select s.*
    from scoped_sales s
    where s.counts_as_visit
      and s.reversal_of is null
      and not exists (
        select 1
        from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  )
  select jsonb_build_object(
    'visits', (select count(*) from valid_visits),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue), 0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null)
  )
  into v_kpis;
$v714adsb027$);
  if v_roundtrip <> v_def then
    raise exception 'v714: dsb changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v714: dsb visit-day authority did not land';
  end if;
end
$v714blk_dsb_23$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_dashboard_summary(uuid,date,date,uuid) from public;
grant execute on function public.get_dashboard_summary(uuid,date,date,uuid) to anon, authenticated, service_role;

do $v714blk_ds154_29$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('public.get_dashboard_summary_v154(uuid,date,date,text,uuid[],uuid)')) into v_def;
  if v_def is null then raise exception 'v714: public.get_dashboard_summary_v154(uuid,date,date,text,uuid[],uuid) not found'; end if;

  -- anchor: visits/repeat_customers
  v_count := (length(v_def) - length(replace(v_def, $v714ads154030$  ), repeaters as (
    select s.client_id
    from valid_visits s
    where s.client_id is not null
    group by s.client_id
    having count(*) >= 2
  )
  select jsonb_build_object(
    'visits', (select count(*) from valid_visits),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue),0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null),
    'repeat_customers', (select count(*) from repeaters),
    'repeat_customer_percentage', case when (select count(distinct s.client_id) from valid_visits s where s.client_id is not null) = 0 then null
      else round(((select count(*) from repeaters)::numeric / nullif((select count(distinct s.client_id) from valid_visits s where s.client_id is not null),0)::numeric) * 100, 1) end
  ) into v_kpis;
$v714ads154030$, ''))) / length($v714ads154030$  ), repeaters as (
    select s.client_id
    from valid_visits s
    where s.client_id is not null
    group by s.client_id
    having count(*) >= 2
  )
  select jsonb_build_object(
    'visits', (select count(*) from valid_visits),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue),0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null),
    'repeat_customers', (select count(*) from repeaters),
    'repeat_customer_percentage', case when (select count(distinct s.client_id) from valid_visits s where s.client_id is not null) = 0 then null
      else round(((select count(*) from repeaters)::numeric / nullif((select count(distinct s.client_id) from valid_visits s where s.client_id is not null),0)::numeric) * 100, 1) end
  ) into v_kpis;
$v714ads154030$);
  if v_count <> 1 then
    raise exception 'v714: ds154 anchor (visits/repeat_customers) occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := v_def;
  v_expected := replace(v_expected, $v714ads154031$  ), repeaters as (
    select s.client_id
    from valid_visits s
    where s.client_id is not null
    group by s.client_id
    having count(*) >= 2
  )
  select jsonb_build_object(
    'visits', (select count(*) from valid_visits),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue),0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null),
    'repeat_customers', (select count(*) from repeaters),
    'repeat_customer_percentage', case when (select count(distinct s.client_id) from valid_visits s where s.client_id is not null) = 0 then null
      else round(((select count(*) from repeaters)::numeric / nullif((select count(distinct s.client_id) from valid_visits s where s.client_id is not null),0)::numeric) * 100, 1) end
  ) into v_kpis;
$v714ads154031$, $v714rds154032$  ), visit_days as (
    -- nestly_v714 (check 4 fix): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699). Sales with no
    -- client_id (walk-ins) cannot be deduped by customer identity, so each still counts on its own
    -- in the 'visits' total below; repeat_customers is necessarily identity-scoped already.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day
    from valid_visits
    where client_id is not null
    group by client_id, app.ci_visit_day_v699(occurred_at)
  ), repeaters as (
    select client_id
    from visit_days
    group by client_id
    having count(*) >= 2
  )
  select jsonb_build_object(
    'visits', (select count(*) from visit_days) + (select count(*) from valid_visits where client_id is null),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue),0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null),
    'repeat_customers', (select count(*) from repeaters),
    'repeat_customer_percentage', case when (select count(distinct s.client_id) from valid_visits s where s.client_id is not null) = 0 then null
      else round(((select count(*) from repeaters)::numeric / nullif((select count(distinct s.client_id) from valid_visits s where s.client_id is not null),0)::numeric) * 100, 1) end
  ) into v_kpis;
$v714rds154032$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_dashboard_summary_v154(uuid,date,date,text,uuid[],uuid)')) into v_after;
  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $v714rds154034$  ), visit_days as (
    -- nestly_v714 (check 4 fix): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699). Sales with no
    -- client_id (walk-ins) cannot be deduped by customer identity, so each still counts on its own
    -- in the 'visits' total below; repeat_customers is necessarily identity-scoped already.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day
    from valid_visits
    where client_id is not null
    group by client_id, app.ci_visit_day_v699(occurred_at)
  ), repeaters as (
    select client_id
    from visit_days
    group by client_id
    having count(*) >= 2
  )
  select jsonb_build_object(
    'visits', (select count(*) from visit_days) + (select count(*) from valid_visits where client_id is null),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue),0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null),
    'repeat_customers', (select count(*) from repeaters),
    'repeat_customer_percentage', case when (select count(distinct s.client_id) from valid_visits s where s.client_id is not null) = 0 then null
      else round(((select count(*) from repeaters)::numeric / nullif((select count(distinct s.client_id) from valid_visits s where s.client_id is not null),0)::numeric) * 100, 1) end
  ) into v_kpis;
$v714rds154034$, $v714ads154033$  ), repeaters as (
    select s.client_id
    from valid_visits s
    where s.client_id is not null
    group by s.client_id
    having count(*) >= 2
  )
  select jsonb_build_object(
    'visits', (select count(*) from valid_visits),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue),0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null),
    'repeat_customers', (select count(*) from repeaters),
    'repeat_customer_percentage', case when (select count(distinct s.client_id) from valid_visits s where s.client_id is not null) = 0 then null
      else round(((select count(*) from repeaters)::numeric / nullif((select count(distinct s.client_id) from valid_visits s where s.client_id is not null),0)::numeric) * 100, 1) end
  ) into v_kpis;
$v714ads154033$);
  if v_roundtrip <> v_def then
    raise exception 'v714: ds154 changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v714: ds154 visit-day authority did not land';
  end if;
end
$v714blk_ds154_29$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_dashboard_summary_v154(uuid,date,date,text,uuid[],uuid) from public, anon;
grant execute on function public.get_dashboard_summary_v154(uuid,date,date,text,uuid[],uuid) to authenticated, service_role;

do $v714blk_ds155_35$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('public.get_dashboard_summary_v155(uuid,date,date,text,uuid[],uuid)')) into v_def;
  if v_def is null then raise exception 'v714: public.get_dashboard_summary_v155(uuid,date,date,text,uuid[],uuid) not found'; end if;

  -- anchor: visits/repeat_customers
  v_count := (length(v_def) - length(replace(v_def, $v714ads155036$  ), repeaters as (
    select s.client_id
    from valid_visits s
    where s.client_id is not null
    group by s.client_id
    having count(*) >= 2
  )
  select jsonb_build_object(
    'visits', (select count(*) from valid_visits),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue),0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null),
    'repeat_customers', (select count(*) from repeaters),
    'repeat_customer_percentage', case when (select count(distinct s.client_id) from valid_visits s where s.client_id is not null) = 0 then null
      else round(((select count(*) from repeaters)::numeric / nullif((select count(distinct s.client_id) from valid_visits s where s.client_id is not null),0)::numeric) * 100, 1) end
  ) into v_kpis;
$v714ads155036$, ''))) / length($v714ads155036$  ), repeaters as (
    select s.client_id
    from valid_visits s
    where s.client_id is not null
    group by s.client_id
    having count(*) >= 2
  )
  select jsonb_build_object(
    'visits', (select count(*) from valid_visits),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue),0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null),
    'repeat_customers', (select count(*) from repeaters),
    'repeat_customer_percentage', case when (select count(distinct s.client_id) from valid_visits s where s.client_id is not null) = 0 then null
      else round(((select count(*) from repeaters)::numeric / nullif((select count(distinct s.client_id) from valid_visits s where s.client_id is not null),0)::numeric) * 100, 1) end
  ) into v_kpis;
$v714ads155036$);
  if v_count <> 1 then
    raise exception 'v714: ds155 anchor (visits/repeat_customers) occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := v_def;
  v_expected := replace(v_expected, $v714ads155037$  ), repeaters as (
    select s.client_id
    from valid_visits s
    where s.client_id is not null
    group by s.client_id
    having count(*) >= 2
  )
  select jsonb_build_object(
    'visits', (select count(*) from valid_visits),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue),0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null),
    'repeat_customers', (select count(*) from repeaters),
    'repeat_customer_percentage', case when (select count(distinct s.client_id) from valid_visits s where s.client_id is not null) = 0 then null
      else round(((select count(*) from repeaters)::numeric / nullif((select count(distinct s.client_id) from valid_visits s where s.client_id is not null),0)::numeric) * 100, 1) end
  ) into v_kpis;
$v714ads155037$, $v714rds155038$  ), visit_days as (
    -- nestly_v714 (check 4 fix): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699). Sales with no
    -- client_id (walk-ins) cannot be deduped by customer identity, so each still counts on its own
    -- in the 'visits' total below; repeat_customers is necessarily identity-scoped already.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day
    from valid_visits
    where client_id is not null
    group by client_id, app.ci_visit_day_v699(occurred_at)
  ), repeaters as (
    select client_id
    from visit_days
    group by client_id
    having count(*) >= 2
  )
  select jsonb_build_object(
    'visits', (select count(*) from visit_days) + (select count(*) from valid_visits where client_id is null),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue),0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null),
    'repeat_customers', (select count(*) from repeaters),
    'repeat_customer_percentage', case when (select count(distinct s.client_id) from valid_visits s where s.client_id is not null) = 0 then null
      else round(((select count(*) from repeaters)::numeric / nullif((select count(distinct s.client_id) from valid_visits s where s.client_id is not null),0)::numeric) * 100, 1) end
  ) into v_kpis;
$v714rds155038$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_dashboard_summary_v155(uuid,date,date,text,uuid[],uuid)')) into v_after;
  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $v714rds155040$  ), visit_days as (
    -- nestly_v714 (check 4 fix): collapse same-day sales (a split bill) into ONE visit-day per
    -- client via the one visit-day authority (app.ci_visit_day_v699, nestly_v699). Sales with no
    -- client_id (walk-ins) cannot be deduped by customer identity, so each still counts on its own
    -- in the 'visits' total below; repeat_customers is necessarily identity-scoped already.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day
    from valid_visits
    where client_id is not null
    group by client_id, app.ci_visit_day_v699(occurred_at)
  ), repeaters as (
    select client_id
    from visit_days
    group by client_id
    having count(*) >= 2
  )
  select jsonb_build_object(
    'visits', (select count(*) from visit_days) + (select count(*) from valid_visits where client_id is null),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue),0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null),
    'repeat_customers', (select count(*) from repeaters),
    'repeat_customer_percentage', case when (select count(distinct s.client_id) from valid_visits s where s.client_id is not null) = 0 then null
      else round(((select count(*) from repeaters)::numeric / nullif((select count(distinct s.client_id) from valid_visits s where s.client_id is not null),0)::numeric) * 100, 1) end
  ) into v_kpis;
$v714rds155040$, $v714ads155039$  ), repeaters as (
    select s.client_id
    from valid_visits s
    where s.client_id is not null
    group by s.client_id
    having count(*) >= 2
  )
  select jsonb_build_object(
    'visits', (select count(*) from valid_visits),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue),0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null),
    'repeat_customers', (select count(*) from repeaters),
    'repeat_customer_percentage', case when (select count(distinct s.client_id) from valid_visits s where s.client_id is not null) = 0 then null
      else round(((select count(*) from repeaters)::numeric / nullif((select count(distinct s.client_id) from valid_visits s where s.client_id is not null),0)::numeric) * 100, 1) end
  ) into v_kpis;
$v714ads155039$);
  if v_roundtrip <> v_def then
    raise exception 'v714: ds155 changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v714: ds155 visit-day authority did not land';
  end if;
end
$v714blk_ds155_35$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_dashboard_summary_v155(uuid,date,date,text,uuid[],uuid) from public, anon;
grant execute on function public.get_dashboard_summary_v155(uuid,date,date,text,uuid[],uuid) to authenticated, service_role;

do $v714blk_rlc_41$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('public.retention_lapsed_candidates_v244(uuid,integer,integer)')) into v_def;
  if v_def is null then raise exception 'v714: public.retention_lapsed_candidates_v244(uuid,integer,integer) not found'; end if;

  -- anchor: net_visits
  v_count := (length(v_def) - length(replace(v_def, $v714arlc042$  per_client as (
    select vv.client_id,
           count(*)::integer as net_visits,
           max(vv.occurred_at) as last_visit_at
    from valid_visits vv
    group by vv.client_id
$v714arlc042$, ''))) / length($v714arlc042$  per_client as (
    select vv.client_id,
           count(*)::integer as net_visits,
           max(vv.occurred_at) as last_visit_at
    from valid_visits vv
    group by vv.client_id
$v714arlc042$);
  if v_count <> 1 then
    raise exception 'v714: rlc anchor (net_visits) occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := v_def;
  v_expected := replace(v_expected, $v714arlc043$  per_client as (
    select vv.client_id,
           count(*)::integer as net_visits,
           max(vv.occurred_at) as last_visit_at
    from valid_visits vv
    group by vv.client_id
$v714arlc043$, $v714rrlc044$  per_client as (
    select vv.client_id,
           count(distinct app.ci_visit_day_v699(vv.occurred_at))::integer as net_visits,
           max(vv.occurred_at) as last_visit_at
    from valid_visits vv
    group by vv.client_id
$v714rrlc044$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.retention_lapsed_candidates_v244(uuid,integer,integer)')) into v_after;
  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $v714rrlc046$  per_client as (
    select vv.client_id,
           count(distinct app.ci_visit_day_v699(vv.occurred_at))::integer as net_visits,
           max(vv.occurred_at) as last_visit_at
    from valid_visits vv
    group by vv.client_id
$v714rrlc046$, $v714arlc045$  per_client as (
    select vv.client_id,
           count(*)::integer as net_visits,
           max(vv.occurred_at) as last_visit_at
    from valid_visits vv
    group by vv.client_id
$v714arlc045$);
  if v_roundtrip <> v_def then
    raise exception 'v714: rlc changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v714: rlc visit-day authority did not land';
  end if;
end
$v714blk_rlc_41$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.retention_lapsed_candidates_v244(uuid,integer,integer) from public;
grant execute on function public.retention_lapsed_candidates_v244(uuid,integer,integer) to public, anon, authenticated, service_role;

do $v714blk_rr550_47$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('public.get_recovery_report_v550(uuid,date,date)')) into v_def;
  if v_def is null then raise exception 'v714: public.get_recovery_report_v550(uuid,date,date) not found'; end if;

  -- anchor: visits CTE / prior_visits
  v_count := (length(v_def) - length(replace(v_def, $v714arr550048$  with visits as (
    select s.client_id, s.occurred_at,
      app.v106_sale_residual_minor(s.id, v_now) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.client_id is not null
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at < v_now
      and app.v106_sale_residual_minor(s.id, v_now) > 0
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id and r.reversal_of = s.id
      )
  ),
$v714arr550048$, ''))) / length($v714arr550048$  with visits as (
    select s.client_id, s.occurred_at,
      app.v106_sale_residual_minor(s.id, v_now) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.client_id is not null
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at < v_now
      and app.v106_sale_residual_minor(s.id, v_now) > 0
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id and r.reversal_of = s.id
      )
  ),
$v714arr550048$);
  if v_count <> 1 then
    raise exception 'v714: rr550 anchor (visits CTE / prior_visits) occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := v_def;
  v_expected := replace(v_expected, $v714arr550049$  with visits as (
    select s.client_id, s.occurred_at,
      app.v106_sale_residual_minor(s.id, v_now) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.client_id is not null
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at < v_now
      and app.v106_sale_residual_minor(s.id, v_now) > 0
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id and r.reversal_of = s.id
      )
  ),
$v714arr550049$, $v714rrr550050$  with raw_visits as (
    select s.client_id, s.occurred_at,
      app.v106_sale_residual_minor(s.id, v_now) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.client_id is not null
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at < v_now
      and app.v106_sale_residual_minor(s.id, v_now) > 0
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id and r.reversal_of = s.id
      )
  ),
  visits as (
    -- nestly_v714 (check 4 fix): collapse same-day sales (a split bill -- several tickets, one
    -- customer, one afternoon) into ONE visit -- the one visit-day authority, nestly_v699 --
    -- before prior_visits / last_visit_before / returned / window_cents are computed downstream.
    -- Anchored at the day's FIRST qualifying sale's occurred_at (same anchor rule as nestly_v709/
    -- v711); amounts are summed per day so window_cents/gross_cents totals are unchanged, only the
    -- visit-count denominator collapses. Every downstream reference (visits v, v.client_id,
    -- v.occurred_at, v.amount_cents) is untouched -- this CTE's own output shape is unchanged.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day,
           min(occurred_at) as occurred_at,
           sum(amount_cents) as amount_cents
    from raw_visits
    group by client_id, app.ci_visit_day_v699(occurred_at)
  ),
$v714rrr550050$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.get_recovery_report_v550(uuid,date,date)')) into v_after;
  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $v714rrr550052$  with raw_visits as (
    select s.client_id, s.occurred_at,
      app.v106_sale_residual_minor(s.id, v_now) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.client_id is not null
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at < v_now
      and app.v106_sale_residual_minor(s.id, v_now) > 0
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id and r.reversal_of = s.id
      )
  ),
  visits as (
    -- nestly_v714 (check 4 fix): collapse same-day sales (a split bill -- several tickets, one
    -- customer, one afternoon) into ONE visit -- the one visit-day authority, nestly_v699 --
    -- before prior_visits / last_visit_before / returned / window_cents are computed downstream.
    -- Anchored at the day's FIRST qualifying sale's occurred_at (same anchor rule as nestly_v709/
    -- v711); amounts are summed per day so window_cents/gross_cents totals are unchanged, only the
    -- visit-count denominator collapses. Every downstream reference (visits v, v.client_id,
    -- v.occurred_at, v.amount_cents) is untouched -- this CTE's own output shape is unchanged.
    select client_id, app.ci_visit_day_v699(occurred_at) as visit_day,
           min(occurred_at) as occurred_at,
           sum(amount_cents) as amount_cents
    from raw_visits
    group by client_id, app.ci_visit_day_v699(occurred_at)
  ),
$v714rrr550052$, $v714arr550051$  with visits as (
    select s.client_id, s.occurred_at,
      app.v106_sale_residual_minor(s.id, v_now) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.client_id is not null
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at < v_now
      and app.v106_sale_residual_minor(s.id, v_now) > 0
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id and r.reversal_of = s.id
      )
  ),
$v714arr550051$);
  if v_roundtrip <> v_def then
    raise exception 'v714: rr550 changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v714: rr550 visit-day authority did not land';
  end if;
end
$v714blk_rr550_47$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.get_recovery_report_v550(uuid,date,date) from public, anon;
grant execute on function public.get_recovery_report_v550(uuid,date,date) to authenticated, service_role;

do $v714blk_pgir_53$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('public.platform_generate_improvement_report_v82(text,uuid[],uuid,date,date,text,timestamptz)')) into v_def;
  if v_def is null then raise exception 'v714: public.platform_generate_improvement_report_v82(text,uuid[],uuid,date,date,text,timestamptz) not found'; end if;

  -- anchor: visit_count
  v_count := (length(v_def) - length(replace(v_def, $v714apgir054$      count(*) filter(
        where sale.id is not null and sale.reversal_of is null
          and sale.amount_cents>0 and sale.counts_as_visit
          and not exists(
            select 1 from public.sales reversal
            where reversal.business_id=sale.business_id
              and reversal.reversal_of=sale.id
              and reversal.created_at<=v_snapshot_at
              and reversal.occurred_at<v_to_ts
          )
      )::integer visit_count,
$v714apgir054$, ''))) / length($v714apgir054$      count(*) filter(
        where sale.id is not null and sale.reversal_of is null
          and sale.amount_cents>0 and sale.counts_as_visit
          and not exists(
            select 1 from public.sales reversal
            where reversal.business_id=sale.business_id
              and reversal.reversal_of=sale.id
              and reversal.created_at<=v_snapshot_at
              and reversal.occurred_at<v_to_ts
          )
      )::integer visit_count,
$v714apgir054$);
  if v_count <> 1 then
    raise exception 'v714: pgir anchor (visit_count) occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  -- anchor: methodology text
  v_count := (length(v_def) - length(replace(v_def, $v714apgir155$      'returning_customer','at least two unreversed visit-counting sales in the selected period',
$v714apgir155$, ''))) / length($v714apgir155$      'returning_customer','at least two unreversed visit-counting sales in the selected period',
$v714apgir155$);
  if v_count <> 1 then
    raise exception 'v714: pgir anchor (methodology text) occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := v_def;
  v_expected := replace(v_expected, $v714apgir056$      count(*) filter(
        where sale.id is not null and sale.reversal_of is null
          and sale.amount_cents>0 and sale.counts_as_visit
          and not exists(
            select 1 from public.sales reversal
            where reversal.business_id=sale.business_id
              and reversal.reversal_of=sale.id
              and reversal.created_at<=v_snapshot_at
              and reversal.occurred_at<v_to_ts
          )
      )::integer visit_count,
$v714apgir056$, $v714rpgir057$      count(distinct app.ci_visit_day_v699(sale.occurred_at)) filter(
        where sale.id is not null and sale.reversal_of is null
          and sale.amount_cents>0 and sale.counts_as_visit
          and not exists(
            select 1 from public.sales reversal
            where reversal.business_id=sale.business_id
              and reversal.reversal_of=sale.id
              and reversal.created_at<=v_snapshot_at
              and reversal.occurred_at<v_to_ts
          )
      )::integer visit_count,
$v714rpgir057$);
  v_expected := replace(v_expected, $v714apgir158$      'returning_customer','at least two unreversed visit-counting sales in the selected period',
$v714apgir158$, $v714rpgir159$      'returning_customer','at least two unreversed visit-counting sales on distinct days (Asia/Singapore) in the selected period; a same-day split bill counts once',
$v714rpgir159$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.platform_generate_improvement_report_v82(text,uuid[],uuid,date,date,text,timestamptz)')) into v_after;
  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $v714rpgir061$      count(distinct app.ci_visit_day_v699(sale.occurred_at)) filter(
        where sale.id is not null and sale.reversal_of is null
          and sale.amount_cents>0 and sale.counts_as_visit
          and not exists(
            select 1 from public.sales reversal
            where reversal.business_id=sale.business_id
              and reversal.reversal_of=sale.id
              and reversal.created_at<=v_snapshot_at
              and reversal.occurred_at<v_to_ts
          )
      )::integer visit_count,
$v714rpgir061$, $v714apgir060$      count(*) filter(
        where sale.id is not null and sale.reversal_of is null
          and sale.amount_cents>0 and sale.counts_as_visit
          and not exists(
            select 1 from public.sales reversal
            where reversal.business_id=sale.business_id
              and reversal.reversal_of=sale.id
              and reversal.created_at<=v_snapshot_at
              and reversal.occurred_at<v_to_ts
          )
      )::integer visit_count,
$v714apgir060$);
  v_roundtrip := replace(v_roundtrip, $v714rpgir163$      'returning_customer','at least two unreversed visit-counting sales on distinct days (Asia/Singapore) in the selected period; a same-day split bill counts once',
$v714rpgir163$, $v714apgir162$      'returning_customer','at least two unreversed visit-counting sales in the selected period',
$v714apgir162$);
  if v_roundtrip <> v_def then
    raise exception 'v714: pgir changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v714: pgir visit-day authority did not land';
  end if;
end
$v714blk_pgir_53$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.platform_generate_improvement_report_v82(text,uuid[],uuid,date,date,text,timestamptz) from public;
grant execute on function public.platform_generate_improvement_report_v82(text,uuid[],uuid,date,date,text,timestamptz) to public, anon, authenticated, service_role;

do $v714blk_plec_64$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('public.platform_list_enterprise_customers_v82(text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid,text)')) into v_def;
  if v_def is null then raise exception 'v714: public.platform_list_enterprise_customers_v82(text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid,text) not found'; end if;

  -- anchor: visit_count
  v_count := (length(v_def) - length(replace(v_def, $v714aplec065$        count(*) filter(
          where sale.reversal_of is null and sale.amount_cents>0
            and sale.counts_as_visit and not exists(
              select 1 from public.sales reversal
              where reversal.business_id=sale.business_id
                and reversal.reversal_of=sale.id
                and reversal.created_at<=v_snapshot_at
                and reversal.occurred_at<v_to_ts
            )
        )::integer visit_count,
$v714aplec065$, ''))) / length($v714aplec065$        count(*) filter(
          where sale.reversal_of is null and sale.amount_cents>0
            and sale.counts_as_visit and not exists(
              select 1 from public.sales reversal
              where reversal.business_id=sale.business_id
                and reversal.reversal_of=sale.id
                and reversal.created_at<=v_snapshot_at
                and reversal.occurred_at<v_to_ts
            )
        )::integer visit_count,
$v714aplec065$);
  if v_count <> 1 then
    raise exception 'v714: plec anchor (visit_count) occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := v_def;
  v_expected := replace(v_expected, $v714aplec066$        count(*) filter(
          where sale.reversal_of is null and sale.amount_cents>0
            and sale.counts_as_visit and not exists(
              select 1 from public.sales reversal
              where reversal.business_id=sale.business_id
                and reversal.reversal_of=sale.id
                and reversal.created_at<=v_snapshot_at
                and reversal.occurred_at<v_to_ts
            )
        )::integer visit_count,
$v714aplec066$, $v714rplec067$        count(distinct app.ci_visit_day_v699(sale.occurred_at)) filter(
          where sale.reversal_of is null and sale.amount_cents>0
            and sale.counts_as_visit and not exists(
              select 1 from public.sales reversal
              where reversal.business_id=sale.business_id
                and reversal.reversal_of=sale.id
                and reversal.created_at<=v_snapshot_at
                and reversal.occurred_at<v_to_ts
            )
        )::integer visit_count,
$v714rplec067$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.platform_list_enterprise_customers_v82(text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid,text)')) into v_after;
  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $v714rplec069$        count(distinct app.ci_visit_day_v699(sale.occurred_at)) filter(
          where sale.reversal_of is null and sale.amount_cents>0
            and sale.counts_as_visit and not exists(
              select 1 from public.sales reversal
              where reversal.business_id=sale.business_id
                and reversal.reversal_of=sale.id
                and reversal.created_at<=v_snapshot_at
                and reversal.occurred_at<v_to_ts
            )
        )::integer visit_count,
$v714rplec069$, $v714aplec068$        count(*) filter(
          where sale.reversal_of is null and sale.amount_cents>0
            and sale.counts_as_visit and not exists(
              select 1 from public.sales reversal
              where reversal.business_id=sale.business_id
                and reversal.reversal_of=sale.id
                and reversal.created_at<=v_snapshot_at
                and reversal.occurred_at<v_to_ts
            )
        )::integer visit_count,
$v714aplec068$);
  if v_roundtrip <> v_def then
    raise exception 'v714: plec changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v714: plec visit-day authority did not land';
  end if;
end
$v714blk_plec_64$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.platform_list_enterprise_customers_v82(text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid,text) from public, anon;
grant execute on function public.platform_list_enterprise_customers_v82(text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid,text) to authenticated, service_role;

do $v714blk_pgafr_70$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('public.platform_get_assigned_firm_report_v94(uuid,uuid,date,date)')) into v_def;
  if v_def is null then raise exception 'v714: public.platform_get_assigned_firm_report_v94(uuid,uuid,date,date) not found'; end if;

  -- anchor: customer_metrics.visit_days
  v_count := (length(v_def) - length(replace(v_def, $v714apgafr071$  ), customer_metrics as (
    select client.id,count(valid_sales.id) purchases,
      coalesce(sum(valid_sales.amount_cents),0) revenue_cents,
      min(valid_sales.occurred_at) first_purchase_at,
      max(valid_sales.occurred_at) last_purchase_at
    from public.clients client
    left join valid_sales on valid_sales.client_id=client.id
    where client.business_id=p_business and client.is_synthetic=false
    group by client.id
$v714apgafr071$, ''))) / length($v714apgafr071$  ), customer_metrics as (
    select client.id,count(valid_sales.id) purchases,
      coalesce(sum(valid_sales.amount_cents),0) revenue_cents,
      min(valid_sales.occurred_at) first_purchase_at,
      max(valid_sales.occurred_at) last_purchase_at
    from public.clients client
    left join valid_sales on valid_sales.client_id=client.id
    where client.business_id=p_business and client.is_synthetic=false
    group by client.id
$v714apgafr071$);
  if v_count <> 1 then
    raise exception 'v714: pgafr anchor (customer_metrics.visit_days) occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  -- anchor: kpis.visits
  v_count := (length(v_def) - length(replace(v_def, $v714apgafr172$      'visits',(select count(*) from valid_sales where counts_as_visit),
$v714apgafr172$, ''))) / length($v714apgafr172$      'visits',(select count(*) from valid_sales where counts_as_visit),
$v714apgafr172$);
  if v_count <> 1 then
    raise exception 'v714: pgafr anchor (kpis.visits) occurs % times (expected 1) -- live body drifted', v_count;
  end if;
  -- anchor: returning_customers
  v_count := (length(v_def) - length(replace(v_def, $v714apgafr273$      'returning_customers',(select count(*) from customer_metrics where purchases>=2),
$v714apgafr273$, ''))) / length($v714apgafr273$      'returning_customers',(select count(*) from customer_metrics where purchases>=2),
$v714apgafr273$);
  if v_count <> 1 then
    raise exception 'v714: pgafr anchor (returning_customers) occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := v_def;
  v_expected := replace(v_expected, $v714apgafr074$  ), customer_metrics as (
    select client.id,count(valid_sales.id) purchases,
      coalesce(sum(valid_sales.amount_cents),0) revenue_cents,
      min(valid_sales.occurred_at) first_purchase_at,
      max(valid_sales.occurred_at) last_purchase_at
    from public.clients client
    left join valid_sales on valid_sales.client_id=client.id
    where client.business_id=p_business and client.is_synthetic=false
    group by client.id
$v714apgafr074$, $v714rpgafr075$  ), customer_metrics as (
    select client.id,count(valid_sales.id) purchases,
      count(distinct app.ci_visit_day_v699(valid_sales.occurred_at)) filter (where valid_sales.counts_as_visit) visit_days,
      coalesce(sum(valid_sales.amount_cents),0) revenue_cents,
      min(valid_sales.occurred_at) first_purchase_at,
      max(valid_sales.occurred_at) last_purchase_at
    from public.clients client
    left join valid_sales on valid_sales.client_id=client.id
    where client.business_id=p_business and client.is_synthetic=false
    group by client.id
$v714rpgafr075$);
  v_expected := replace(v_expected, $v714apgafr176$      'visits',(select count(*) from valid_sales where counts_as_visit),
$v714apgafr176$, $v714rpgafr177$      'visits',(select count(distinct (client_id, app.ci_visit_day_v699(occurred_at))) filter (where client_id is not null and counts_as_visit) + count(*) filter (where client_id is null and counts_as_visit) from valid_sales),
$v714rpgafr177$);
  v_expected := replace(v_expected, $v714apgafr278$      'returning_customers',(select count(*) from customer_metrics where purchases>=2),
$v714apgafr278$, $v714rpgafr279$      'returning_customers',(select count(*) from customer_metrics where visit_days>=2),
$v714rpgafr279$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.platform_get_assigned_firm_report_v94(uuid,uuid,date,date)')) into v_after;
  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $v714rpgafr081$  ), customer_metrics as (
    select client.id,count(valid_sales.id) purchases,
      count(distinct app.ci_visit_day_v699(valid_sales.occurred_at)) filter (where valid_sales.counts_as_visit) visit_days,
      coalesce(sum(valid_sales.amount_cents),0) revenue_cents,
      min(valid_sales.occurred_at) first_purchase_at,
      max(valid_sales.occurred_at) last_purchase_at
    from public.clients client
    left join valid_sales on valid_sales.client_id=client.id
    where client.business_id=p_business and client.is_synthetic=false
    group by client.id
$v714rpgafr081$, $v714apgafr080$  ), customer_metrics as (
    select client.id,count(valid_sales.id) purchases,
      coalesce(sum(valid_sales.amount_cents),0) revenue_cents,
      min(valid_sales.occurred_at) first_purchase_at,
      max(valid_sales.occurred_at) last_purchase_at
    from public.clients client
    left join valid_sales on valid_sales.client_id=client.id
    where client.business_id=p_business and client.is_synthetic=false
    group by client.id
$v714apgafr080$);
  v_roundtrip := replace(v_roundtrip, $v714rpgafr183$      'visits',(select count(distinct (client_id, app.ci_visit_day_v699(occurred_at))) filter (where client_id is not null and counts_as_visit) + count(*) filter (where client_id is null and counts_as_visit) from valid_sales),
$v714rpgafr183$, $v714apgafr182$      'visits',(select count(*) from valid_sales where counts_as_visit),
$v714apgafr182$);
  v_roundtrip := replace(v_roundtrip, $v714rpgafr285$      'returning_customers',(select count(*) from customer_metrics where visit_days>=2),
$v714rpgafr285$, $v714apgafr284$      'returning_customers',(select count(*) from customer_metrics where purchases>=2),
$v714apgafr284$);
  if v_roundtrip <> v_def then
    raise exception 'v714: pgafr changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v714: pgafr visit-day authority did not land';
  end if;
end
$v714blk_pgafr_70$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.platform_get_assigned_firm_report_v94(uuid,uuid,date,date) from public;
grant execute on function public.platform_get_assigned_firm_report_v94(uuid,uuid,date,date) to public, anon, authenticated, service_role;

do $v714blk_pgeh_86$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('public.platform_get_enterprise_hierarchy_v82(text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid)')) into v_def;
  if v_def is null then raise exception 'v714: public.platform_get_enterprise_hierarchy_v82(text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid) not found'; end if;

  -- anchor: returning_customers having
  v_count := (length(v_def) - length(replace(v_def, $v714apgeh087$              group by sale.client_id having count(*)>=2
$v714apgeh087$, ''))) / length($v714apgeh087$              group by sale.client_id having count(*)>=2
$v714apgeh087$);
  if v_count <> 1 then
    raise exception 'v714: pgeh anchor (returning_customers having) occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := v_def;
  v_expected := replace(v_expected, $v714apgeh088$              group by sale.client_id having count(*)>=2
$v714apgeh088$, $v714rpgeh089$              group by sale.client_id having count(distinct app.ci_visit_day_v699(sale.occurred_at))>=2
$v714rpgeh089$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('public.platform_get_enterprise_hierarchy_v82(text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid)')) into v_after;
  v_roundtrip := v_after;
  v_roundtrip := replace(v_roundtrip, $v714rpgeh091$              group by sale.client_id having count(distinct app.ci_visit_day_v699(sale.occurred_at))>=2
$v714rpgeh091$, $v714apgeh090$              group by sale.client_id having count(*)>=2
$v714apgeh090$);
  if v_roundtrip <> v_def then
    raise exception 'v714: pgeh changed by more than the intended substitution(s). Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('app.ci_visit_day_v699' in v_after) = 0 then
    raise exception 'v714: pgeh visit-day authority did not land';
  end if;
end
$v714blk_pgeh_86$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function public.platform_get_enterprise_hierarchy_v82(text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid) from public;
grant execute on function public.platform_get_enterprise_hierarchy_v82(text,uuid[],uuid,date,date,text,integer,timestamptz,timestamptz,uuid) to public, anon, authenticated, service_role;
do $v714blk_registry_1$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('app.ci_visit_registry_v699()')) into v_def;
  if v_def is null then raise exception 'v714: app.ci_visit_registry_v699 not found'; end if;

  -- anchor 1: the registry's current last entry (refresh_growth_recommendation_v108, nestly_v711)
  v_count := (length(v_def) - length(replace(v_def, $v714regl_a2$      'refresh_growth_recommendation_v108', jsonb_build_object(
        'uses_authority', true,
        'note', 'prior_visits / cadence_days are computed over distinct visit-days, not raw sale rows; a visit-day is anchored at that day''s first qualifying sale; last_visit_at and the average/historical revenue amounts are unchanged (nestly_v711, check 4)')
    )
  );
$function$$v714regl_a2$, ''))) / length($v714regl_a2$      'refresh_growth_recommendation_v108', jsonb_build_object(
        'uses_authority', true,
        'note', 'prior_visits / cadence_days are computed over distinct visit-days, not raw sale rows; a visit-day is anchored at that day''s first qualifying sale; last_visit_at and the average/historical revenue amounts are unchanged (nestly_v711, check 4)')
    )
  );
$function$$v714regl_a2$);
  if v_count <> 1 then
    raise exception 'v714: ci_visit_registry_v699 last-entry anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  -- anchor 2: the existing v179_business_insights entry, to add a 'caveat' field only -- v179's
  -- own body is NOT touched here (nestly_v706 owns it, in flight).
  v_count := (length(v_def) - length(replace(v_def, $v714regv_a4$      'app.v179_business_insights', jsonb_build_object(
        'uses_authority', true,
        'note', 'lifetime_visits / window_clients.visits = distinct visit-day; the regulars gate '
                '(lifetime_visits >= 2) inherits this at its source (nestly_v699)'),$v714regv_a4$, ''))) / length($v714regv_a4$      'app.v179_business_insights', jsonb_build_object(
        'uses_authority', true,
        'note', 'lifetime_visits / window_clients.visits = distinct visit-day; the regulars gate '
                '(lifetime_visits >= 2) inherits this at its source (nestly_v699)'),$v714regv_a4$);
  if v_count <> 1 then
    raise exception 'v714: ci_visit_registry_v699 v179 anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, $v714regl_a2$      'refresh_growth_recommendation_v108', jsonb_build_object(
        'uses_authority', true,
        'note', 'prior_visits / cadence_days are computed over distinct visit-days, not raw sale rows; a visit-day is anchored at that day''s first qualifying sale; last_visit_at and the average/historical revenue amounts are unchanged (nestly_v711, check 4)')
    )
  );
$function$$v714regl_a2$, $v714regl_r3$      'refresh_growth_recommendation_v108', jsonb_build_object(
        'uses_authority', true,
        'note', 'prior_visits / cadence_days are computed over distinct visit-days, not raw sale rows; a visit-day is anchored at that day''s first qualifying sale; last_visit_at and the average/historical revenue amounts are unchanged (nestly_v711, check 4)'),
      'app.ci_customer_classes_v1', jsonb_build_object(
        'uses_authority', true,
        'note', 'visits_last_180d (the loyal-class >=6 gate) counts distinct visit-days, not raw sale rows (nestly_v714, check 4)'),
      'get_customer_intelligence_v83', jsonb_build_object(
        'uses_authority', true,
        'note', 'per-customer visit_count is a distinct-visit-day count; returning_customer is >=2 distinct purchase-days in the period, not >=2 raw revenue transactions (nestly_v714, check 4)'),
      'get_dashboard_summary', jsonb_build_object(
        'uses_authority', true,
        'note', 'the visits KPI counts distinct (client, visit-day) pairs, plus one count per unidentified walk-in sale (nestly_v714, check 4)'),
      'get_dashboard_summary_v154', jsonb_build_object(
        'uses_authority', true,
        'note', 'visits and repeat_customers both derive from distinct (client, visit-day) pairs, not raw sale rows (nestly_v714, check 4)'),
      'get_dashboard_summary_v155', jsonb_build_object(
        'uses_authority', true,
        'note', 'visits and repeat_customers both derive from distinct (client, visit-day) pairs, not raw sale rows (nestly_v714, check 4)'),
      'retention_lapsed_candidates_v244', jsonb_build_object(
        'uses_authority', true,
        'note', 'net_visits (the min-visits floor and the returned candidate figure) counts distinct visit-days, not raw sale rows (nestly_v714, check 4)'),
      'get_recovery_report_v550', jsonb_build_object(
        'uses_authority', true,
        'note', 'prior_visits / the returned-window test are computed over distinct visit-days; a visit-day is anchored at that day''s first qualifying sale and its residual amounts summed, so gross_cents/window_cents totals are unchanged (nestly_v714, check 4)'),
      'platform_generate_improvement_report_v82', jsonb_build_object(
        'uses_authority', true,
        'note', 'per-customer visit_count (and therefore returning_customers, which reads visit_count>=2 at firm, branch and currency scope) counts distinct visit-days, not raw sale rows (nestly_v714, check 4)'),
      'platform_list_enterprise_customers_v82', jsonb_build_object(
        'uses_authority', true,
        'note', 'per-customer visit_count (and therefore returning_customer) counts distinct visit-days, not raw sale rows (nestly_v714, check 4)'),
      'platform_get_assigned_firm_report_v94', jsonb_build_object(
        'uses_authority', true,
        'note', 'kpis.visits is a firm-wide distinct (client, visit-day) count, plus one per unidentified walk-in sale; returning_customers reads a new visit_days column on customer_metrics, kept separate from the unrelated purchases-based cohort classifier (nestly_v714, check 4)'),
      'platform_get_enterprise_hierarchy_v82', jsonb_build_object(
        'uses_authority', true,
        'note', 'returning_customers'' per-client having-clause counts distinct visit-days, not raw sale rows (nestly_v714, check 4)')
    )
  );
$function$$v714regl_r3$);
  v_expected := replace(v_expected, $v714regv_a4$      'app.v179_business_insights', jsonb_build_object(
        'uses_authority', true,
        'note', 'lifetime_visits / window_clients.visits = distinct visit-day; the regulars gate '
                '(lifetime_visits >= 2) inherits this at its source (nestly_v699)'),$v714regv_a4$, $v714regv_r5$      'app.v179_business_insights', jsonb_build_object(
        'uses_authority', true,
        'note', 'lifetime_visits / window_clients.visits = distinct visit-day; the regulars gate '
                '(lifetime_visits >= 2) inherits this at its source (nestly_v699)',
        'caveat', 'top_customers/lifetime_visits/weekday_pattern all count distinct visit-days (nestly_v699, nestly_v715)'),$v714regv_r5$);

  execute v_expected;

  select pg_get_functiondef(to_regprocedure('app.ci_visit_registry_v699()')) into v_after;
  v_roundtrip := replace(replace(v_after, $v714regl_r3$      'refresh_growth_recommendation_v108', jsonb_build_object(
        'uses_authority', true,
        'note', 'prior_visits / cadence_days are computed over distinct visit-days, not raw sale rows; a visit-day is anchored at that day''s first qualifying sale; last_visit_at and the average/historical revenue amounts are unchanged (nestly_v711, check 4)'),
      'app.ci_customer_classes_v1', jsonb_build_object(
        'uses_authority', true,
        'note', 'visits_last_180d (the loyal-class >=6 gate) counts distinct visit-days, not raw sale rows (nestly_v714, check 4)'),
      'get_customer_intelligence_v83', jsonb_build_object(
        'uses_authority', true,
        'note', 'per-customer visit_count is a distinct-visit-day count; returning_customer is >=2 distinct purchase-days in the period, not >=2 raw revenue transactions (nestly_v714, check 4)'),
      'get_dashboard_summary', jsonb_build_object(
        'uses_authority', true,
        'note', 'the visits KPI counts distinct (client, visit-day) pairs, plus one count per unidentified walk-in sale (nestly_v714, check 4)'),
      'get_dashboard_summary_v154', jsonb_build_object(
        'uses_authority', true,
        'note', 'visits and repeat_customers both derive from distinct (client, visit-day) pairs, not raw sale rows (nestly_v714, check 4)'),
      'get_dashboard_summary_v155', jsonb_build_object(
        'uses_authority', true,
        'note', 'visits and repeat_customers both derive from distinct (client, visit-day) pairs, not raw sale rows (nestly_v714, check 4)'),
      'retention_lapsed_candidates_v244', jsonb_build_object(
        'uses_authority', true,
        'note', 'net_visits (the min-visits floor and the returned candidate figure) counts distinct visit-days, not raw sale rows (nestly_v714, check 4)'),
      'get_recovery_report_v550', jsonb_build_object(
        'uses_authority', true,
        'note', 'prior_visits / the returned-window test are computed over distinct visit-days; a visit-day is anchored at that day''s first qualifying sale and its residual amounts summed, so gross_cents/window_cents totals are unchanged (nestly_v714, check 4)'),
      'platform_generate_improvement_report_v82', jsonb_build_object(
        'uses_authority', true,
        'note', 'per-customer visit_count (and therefore returning_customers, which reads visit_count>=2 at firm, branch and currency scope) counts distinct visit-days, not raw sale rows (nestly_v714, check 4)'),
      'platform_list_enterprise_customers_v82', jsonb_build_object(
        'uses_authority', true,
        'note', 'per-customer visit_count (and therefore returning_customer) counts distinct visit-days, not raw sale rows (nestly_v714, check 4)'),
      'platform_get_assigned_firm_report_v94', jsonb_build_object(
        'uses_authority', true,
        'note', 'kpis.visits is a firm-wide distinct (client, visit-day) count, plus one per unidentified walk-in sale; returning_customers reads a new visit_days column on customer_metrics, kept separate from the unrelated purchases-based cohort classifier (nestly_v714, check 4)'),
      'platform_get_enterprise_hierarchy_v82', jsonb_build_object(
        'uses_authority', true,
        'note', 'returning_customers'' per-client having-clause counts distinct visit-days, not raw sale rows (nestly_v714, check 4)')
    )
  );
$function$$v714regl_r3$, $v714regl_a2$      'refresh_growth_recommendation_v108', jsonb_build_object(
        'uses_authority', true,
        'note', 'prior_visits / cadence_days are computed over distinct visit-days, not raw sale rows; a visit-day is anchored at that day''s first qualifying sale; last_visit_at and the average/historical revenue amounts are unchanged (nestly_v711, check 4)')
    )
  );
$function$$v714regl_a2$), $v714regv_r5$      'app.v179_business_insights', jsonb_build_object(
        'uses_authority', true,
        'note', 'lifetime_visits / window_clients.visits = distinct visit-day; the regulars gate '
                '(lifetime_visits >= 2) inherits this at its source (nestly_v699)',
        'caveat', 'top_customers/lifetime_visits/weekday_pattern all count distinct visit-days (nestly_v699, nestly_v715)'),$v714regv_r5$, $v714regv_a4$      'app.v179_business_insights', jsonb_build_object(
        'uses_authority', true,
        'note', 'lifetime_visits / window_clients.visits = distinct visit-day; the regulars gate '
                '(lifetime_visits >= 2) inherits this at its source (nestly_v699)'),$v714regv_a4$);
  if v_roundtrip <> v_def then
    raise exception 'v714: ci_visit_registry_v699 changed by more than the intended additions. Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('app.ci_customer_classes_v1' in v_after) = 0
     or position('platform_get_enterprise_hierarchy_v82' in v_after) = 0
     or position('caveat' in v_after) = 0 then
    raise exception 'v714: ci_visit_registry_v699 did not gain the expected entries';
  end if;
end
$v714blk_registry_1$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function app.ci_visit_registry_v699() from public, anon;
grant execute on function app.ci_visit_registry_v699() to service_role;
do $v714blk_dict_6$
declare
  v_def text;
  v_expected text;
  v_after text;
  v_roundtrip text;
  v_count integer;
begin
  select pg_get_functiondef(to_regprocedure('app.ci_metric_dictionary_v1()')) into v_def;
  if v_def is null then raise exception 'v714: app.ci_metric_dictionary_v1 not found'; end if;

  v_count := (length(v_def) - length(replace(v_def, $v714dict_a7$      'visit', jsonb_build_object(
        'definition', 'A qualifying visit: an original sale with counts_as_visit=true, not '
          || 'itself a reversal (reversal_of is null) and not itself later reversed. v673''s '
          || 'funnel/retention readers additionally bucket the visit to one Singapore-time '
          || 'calendar date (visit_date), so more than one qualifying sale on the same SGT day '
          || 'is a single visit for sequencing purposes.',
        'unit', 'count (sale-level unless noted as day-deduped)',
        'numerator', null,
        'denominator', null,
        'source_function', jsonb_build_array(
          'app.customer_cadence_batch_v1',
          'public.get_ci_funnel_conversion_v1',
          'public.get_ci_retention_windows_v1'
        ),
        'since_version', 'v107 (sale-level count); v673 (day-deduped visit_date)',
        'notes', 'DISCLOSED DIVERGENCE, not reconciled here: v107/v651 (paid_visits) and v179 '
          || '(lifetime_visits) count one visit per qualifying SALE row; v673 dedupes '
          || 'same-SGT-day sales into a single visit_date for first/second/third-visit '
          || 'sequencing. Both are "as implemented" in live production readers.'
      ),$v714dict_a7$, ''))) / length($v714dict_a7$      'visit', jsonb_build_object(
        'definition', 'A qualifying visit: an original sale with counts_as_visit=true, not '
          || 'itself a reversal (reversal_of is null) and not itself later reversed. v673''s '
          || 'funnel/retention readers additionally bucket the visit to one Singapore-time '
          || 'calendar date (visit_date), so more than one qualifying sale on the same SGT day '
          || 'is a single visit for sequencing purposes.',
        'unit', 'count (sale-level unless noted as day-deduped)',
        'numerator', null,
        'denominator', null,
        'source_function', jsonb_build_array(
          'app.customer_cadence_batch_v1',
          'public.get_ci_funnel_conversion_v1',
          'public.get_ci_retention_windows_v1'
        ),
        'since_version', 'v107 (sale-level count); v673 (day-deduped visit_date)',
        'notes', 'DISCLOSED DIVERGENCE, not reconciled here: v107/v651 (paid_visits) and v179 '
          || '(lifetime_visits) count one visit per qualifying SALE row; v673 dedupes '
          || 'same-SGT-day sales into a single visit_date for first/second/third-visit '
          || 'sequencing. Both are "as implemented" in live production readers.'
      ),$v714dict_a7$);
  if v_count <> 1 then
    raise exception 'v714: ci_metric_dictionary_v1 visit-entry anchor occurs % times (expected 1) -- live body drifted', v_count;
  end if;

  v_expected := replace(v_def, $v714dict_a7$      'visit', jsonb_build_object(
        'definition', 'A qualifying visit: an original sale with counts_as_visit=true, not '
          || 'itself a reversal (reversal_of is null) and not itself later reversed. v673''s '
          || 'funnel/retention readers additionally bucket the visit to one Singapore-time '
          || 'calendar date (visit_date), so more than one qualifying sale on the same SGT day '
          || 'is a single visit for sequencing purposes.',
        'unit', 'count (sale-level unless noted as day-deduped)',
        'numerator', null,
        'denominator', null,
        'source_function', jsonb_build_array(
          'app.customer_cadence_batch_v1',
          'public.get_ci_funnel_conversion_v1',
          'public.get_ci_retention_windows_v1'
        ),
        'since_version', 'v107 (sale-level count); v673 (day-deduped visit_date)',
        'notes', 'DISCLOSED DIVERGENCE, not reconciled here: v107/v651 (paid_visits) and v179 '
          || '(lifetime_visits) count one visit per qualifying SALE row; v673 dedupes '
          || 'same-SGT-day sales into a single visit_date for first/second/third-visit '
          || 'sequencing. Both are "as implemented" in live production readers.'
      ),$v714dict_a7$, $v714dict_r8$      'visit', jsonb_build_object(
        'definition', 'A qualifying visit: an original sale with counts_as_visit=true, not '
          || 'itself a reversal (reversal_of is null) and not itself later reversed, bucketed to '
          || 'one Singapore-time calendar day (app.ci_visit_day_v699, the one visit-day '
          || 'authority) -- more than one qualifying sale on the same SGT day (a split bill) is '
          || 'a single visit.',
        'unit', 'count of distinct (client, visit-day) pairs',
        'numerator', null,
        'denominator', null,
        'source_function', jsonb_build_array(
          'app.ci_visit_day_v699',
          'app.ci_visit_registry_v699'
        ),
        'since_version', 'v107 (sale-level count, now superseded); v673 (day-deduped visit_date, '
          || 'the funnel/retention precedent); v699/v709/v711/v714 (the one authority, generalised '
          || 'to every visits/repeat/returning-shaped reader in Customer Intelligence, the owner '
          || 'dashboard and the platform console)',
        'notes', 'RECONCILED as of nestly_v714: call app.ci_visit_registry_v699() for the '
          || 'definitive, fixture-proven list of which readers defer to this authority and how. '
          || 'One item remains OUTSIDE the database: the owner dashboard''s Visits-KPI drill-down '
          || 'dialog (app/app.js) still lists one row per raw sale, not per visit-day, so the '
          || 'dialog''s row count can exceed the tile it opened from -- an owed client-side fix, '
          || 'not a database one; see this migration''s header.'
      ),$v714dict_r8$);
  execute v_expected;

  select pg_get_functiondef(to_regprocedure('app.ci_metric_dictionary_v1()')) into v_after;
  v_roundtrip := replace(v_after, $v714dict_r8$      'visit', jsonb_build_object(
        'definition', 'A qualifying visit: an original sale with counts_as_visit=true, not '
          || 'itself a reversal (reversal_of is null) and not itself later reversed, bucketed to '
          || 'one Singapore-time calendar day (app.ci_visit_day_v699, the one visit-day '
          || 'authority) -- more than one qualifying sale on the same SGT day (a split bill) is '
          || 'a single visit.',
        'unit', 'count of distinct (client, visit-day) pairs',
        'numerator', null,
        'denominator', null,
        'source_function', jsonb_build_array(
          'app.ci_visit_day_v699',
          'app.ci_visit_registry_v699'
        ),
        'since_version', 'v107 (sale-level count, now superseded); v673 (day-deduped visit_date, '
          || 'the funnel/retention precedent); v699/v709/v711/v714 (the one authority, generalised '
          || 'to every visits/repeat/returning-shaped reader in Customer Intelligence, the owner '
          || 'dashboard and the platform console)',
        'notes', 'RECONCILED as of nestly_v714: call app.ci_visit_registry_v699() for the '
          || 'definitive, fixture-proven list of which readers defer to this authority and how. '
          || 'One item remains OUTSIDE the database: the owner dashboard''s Visits-KPI drill-down '
          || 'dialog (app/app.js) still lists one row per raw sale, not per visit-day, so the '
          || 'dialog''s row count can exceed the tile it opened from -- an owed client-side fix, '
          || 'not a database one; see this migration''s header.'
      ),$v714dict_r8$, $v714dict_a7$      'visit', jsonb_build_object(
        'definition', 'A qualifying visit: an original sale with counts_as_visit=true, not '
          || 'itself a reversal (reversal_of is null) and not itself later reversed. v673''s '
          || 'funnel/retention readers additionally bucket the visit to one Singapore-time '
          || 'calendar date (visit_date), so more than one qualifying sale on the same SGT day '
          || 'is a single visit for sequencing purposes.',
        'unit', 'count (sale-level unless noted as day-deduped)',
        'numerator', null,
        'denominator', null,
        'source_function', jsonb_build_array(
          'app.customer_cadence_batch_v1',
          'public.get_ci_funnel_conversion_v1',
          'public.get_ci_retention_windows_v1'
        ),
        'since_version', 'v107 (sale-level count); v673 (day-deduped visit_date)',
        'notes', 'DISCLOSED DIVERGENCE, not reconciled here: v107/v651 (paid_visits) and v179 '
          || '(lifetime_visits) count one visit per qualifying SALE row; v673 dedupes '
          || 'same-SGT-day sales into a single visit_date for first/second/third-visit '
          || 'sequencing. Both are "as implemented" in live production readers.'
      ),$v714dict_a7$);
  if v_roundtrip <> v_def then
    raise exception 'v714: ci_metric_dictionary_v1 changed by more than the visit-entry replacement. Before:%  %After (reversed):%  %', E'\n', v_def, E'\n', v_roundtrip;
  end if;
  if position('ci_visit_day_v699' in (v_after)) = 0 then
    raise exception 'v714: ci_metric_dictionary_v1 visit entry did not reference the authority';
  end if;
end
$v714blk_dict_6$;
-- ACL restated verbatim from the live proacl (unchanged by this migration -- same argument list).
revoke all on function app.ci_metric_dictionary_v1() from public, anon;
grant execute on function app.ci_metric_dictionary_v1() to service_role;

commit;
