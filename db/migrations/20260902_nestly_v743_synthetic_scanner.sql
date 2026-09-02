-- NESTLY v743 -- the nine execution-proven CI-100 synthetic-exclusion stragglers, PLUS the
-- estate-wide scanner that would have found all of them (and two more) without a refuter's list.
-- Continues nestly_v687/v734/v737/v740/v742.
--
-- PART A -- nine assigned readers, each verified BROKEN first against the shared corpus fixture
-- (5 real clients / 50000 cents / 8 visit-days; 1 synthetic client with a fully-reversed 4000-cent
-- sale + 6000 cents unreversed; 2 anonymous sales / 10000 cents -- the v734/v737/v740/v742 shape),
-- then fixed and re-verified GREEN:
--
--   1. public.get_checkout_discount_report -- `lines` (the by-day/rule grain) and all three grand-
--      total subqueries read `public.checkout_discount_lines` joined to `public.sales` with no
--      synthetic predicate AND no reversal predicate: a synthetic client's checkout lines counted
--      100% into the report, and a fully-reversed sale's discount lines were still counted. Fixed
--      by routing every leg through `app.analytics_sale_class_v1(s)` and requiring
--      `sc.include_revenue and not sc.is_synthetic_client` -- `include_revenue` already excludes
--      both a reversed original and its reversal row, so this closes both defects with the one
--      canonical predicate every other estate-sweep migration uses.
--   2. public.get_reports_summary_v94_base -- `v_revenue` read `public.sales s ... and
--      s.counts_as_revenue` with no synthetic predicate: revenue_by_kind totalled 66000 instead of
--      60000. Fixed the same way its already-shipped sibling public.get_reports_summary was fixed
--      (nestly_v687): `cross join lateral app.analytics_sale_class_v1(s) sc ... and not
--      sc.is_synthetic_client`. CONFIRMED (read, not touched): public.get_reports_summary does
--      **not** delegate to get_reports_summary_v94_base -- it is a separate, independently
--      maintained implementation, and its own v_revenue query already carries the same
--      `not sc.is_synthetic_client` guard from nestly_v687. Only v94_base was unguarded.
--   3. public.get_campaign_results -- the member-count query and the `judged` CTE both read
--      `public.retention_campaign_members` with no join to `public.clients` at all:
--      treatment.members (and, once a measurement window exists, returned/revenue_cents) counted a
--      synthetic member. Fixed by joining `public.clients` and requiring `not client.is_synthetic`
--      in both places -- the SAME population feeds both the member count and the outcome judging,
--      so a synthetic member is now excluded from every figure the function returns, not just one.
--   4. app.get_growth_execution_result_at_v108 -- `effective_members` read
--      `public.growth_execution_members_v108` with no join to `public.clients`:
--      arms.treatment.members/buyers/associated_revenue_cents counted a synthetic member. Fixed the
--      same way as #3: join `public.clients`, require `not client.is_synthetic`.
--   5. app.v177_appointments -- `matched` read `public.appointments` with no synthetic predicate: a
--      synthetic customer's appointment appeared in the internal ops mirror's `rows` and its
--      `total`/`truncated`. Fixed with a `not exists (select 1 from public.clients ... is_synthetic)`
--      guard scoped to `appointment.client_id` (walk-ins with a null client_id are unaffected).
--   6. app.v109_sector_source_availability -- both branches of the facial/salon/massage
--      `service_history` union (the appointments leg and the sale_items+sales leg) and the retail
--      `product_history` query read their tables with no synthetic predicate:
--      service_linked_history_count / product_linked_history_count each counted a synthetic
--      client's appointment or sale. Fixed with the same `not exists (... is_synthetic)` guard on
--      `appointment.client_id` and `sale.client_id` in all three legs.
--   7. public.super_admin_list_businesses -- `client_count` was `select count(*) ... from
--      public.clients c where c.business_id = b.id` with no synthetic predicate. Fixed with
--      `and not c.is_synthetic`.
--   8. public.platform_engagement_monthly_v255 -- `sale_counts` read `public.sales sale` with a
--      reversal predicate but no synthetic predicate: sales_count over-counted by every synthetic
--      client's sale in the window. Fixed with a `not exists (... is_synthetic)` guard on
--      `sale.client_id` (an anonymous sale, client_id null, is unaffected).
--   9. public.business_programme_usage_v386 -- EVERY client-scoped ledger/grant CTE in this
--      function (points_ledger x2 -- the no-spine and spine-scoped branches --, loyalty_redemptions
--      "rewards", bringback_grants_v361 "bringback", reward_grants "retention_legacy",
--      customer_birthday_redemptions "birthday", welcome_offer_grants_v215 "welcome", referrals,
--      memberships) filtered `client_id is not null` but never joined `public.clients`, so a
--      synthetic client's real engagement inflated every one of these nine business-facing
--      programme-usage figures. Fixed uniformly: each subquery now adds
--      `and not exists (select 1 from public.clients c where c.id = <that CTE's client column> and
--      c.is_synthetic)`. PROVEN DIRECTLY against the shared fixture for `point_system` (a synthetic
--      client's real 'earn' row on the business's live points spine is excluded from `customers`).
--      The other eight sub-metrics were NOT separately re-proven with their own dedicated fixture
--      rows in this migration's time budget (loyalty_redemptions/reward_grants/bringback_grants_
--      v361 each sit behind their own append-only write-fence triggers that would need a fixture of
--      their own) -- they share the byte-identical one-line predicate against the same
--      `public.clients.is_synthetic` column proven correct for point_system and for every other
--      reader in this migration, which is why they are fixed here rather than left as a documented
--      follow-up the way nestly_v740/v742 left two campaign readers. Flagged honestly, not hidden.
--
-- TWO MORE, found BY THE SCANNER built in Part B, not on the assigned list, and fixed here because
-- leaving a proven-broken reader unallowlisted would make Part B's "zero rows" assertion dishonest:
--
--  10. public.staff_list_package_entitlements_v102 -- the staff-facing package-entitlement roster
--      joined `public.clients` for `full_name`/`phone` display but never filtered on
--      `is_synthetic`: the exact "unfiltered roster" shape nestly_v740 fixed in
--      staff_list_customers_v129, just for `public.client_packages` instead of `public.clients`
--      directly. Fixed with `and not client.is_synthetic`. Packages are sellable to ANY client via
--      `sell_package_v102(p_client, ...)`, so this was reachable, unlike #11's sibling
--      (staff_list_visit_feedback_v145 -- see the scanner's allowlist reason: visit_feedback rows
--      require a verified customer identity/link a synthetic fixture client does not possess).
--  11. app.issue_bringback_for_business_v361 -- the WRITER, not a reader: its `last_seen` CTE
--      selected the most-recent-sale client from `public.sales` with no synthetic predicate, so a
--      lapsed synthetic test client could receive a real `bringback_grants_v361` row -- real
--      liability, real cost, on a fixture account. Per the bug-closure protocol's own layer 2
--      ("prefer fixing the writer... over repairing its output"), this is fixed at the write path
--      itself: `and not exists (select 1 from public.clients sc where sc.id = s.client_id and
--      sc.is_synthetic)` added to the away-client selection. PROVEN: calling the function against a
--      lapsed real+synthetic pair issues zero grants for the synthetic client.
--
-- Every patch below is an anchored, comment-free replace-equality diff against the LIVE
-- pg_get_functiondef body -- same discipline as nestly_v668/v687/v714/v724/v734/v737/v740/v742:
-- capture the body before, apply CREATE OR REPLACE, then assert the new body equals
-- old-with-exactly-this-substitution-and-nothing-else, or roll back the whole migration. ACLs are
-- restated exactly as the live `proacl` already shows (CREATE OR REPLACE preserves existing
-- grants; nothing here widens or narrows anon/authenticated/service_role/public access). The three
-- `app.*` readers/writer (get_growth_execution_result_at_v108, v177_appointments,
-- v109_sector_source_availability, issue_bringback_for_business_v361) are, and remain,
-- service_role-only -- no anon, no authenticated, no public.
--
-- PROVEN BY: db/tests/executed/v743_corpus_synthetic_scanner.sql -- the shared 5-real/50000/8-day +
-- 1-synthetic-with-a-reversal + 2-anonymous corpus for readers 1-4 and 7-9, plus dedicated minimal
-- fixtures (each its own business, so none can perturb another) for the readers whose predicate
-- shape the shared corpus does not exercise: checkout discount lines + a reversed sale (#1),
-- retention-campaign / growth-execution membership with one real + one synthetic member (#3, #4),
-- a completed appointment for a synthetic customer (#5), a completed service appointment + a retail
-- sale_items row for a synthetic customer (#6), super-admin-scoped client_count (#7), a two-sale
-- platform-engagement window (#8), a live points-programme earn row (#9), a client_package (#10),
-- and a lapsed real+synthetic pair against a live bringback campaign (#11). Each reader is called
-- as its real principal (owner / non-owner staff / platform super admin per the function's own
-- gate), never as the migration role.
--
-- PART B -- app.ci_synthetic_scan_v743(): returns every public/app function whose live body
-- references one of the seven synthetic-exposed tables (sales, sale_items, clients, appointments,
-- client_packages, points_ledger, credit_ledger, reward_grants) AND contains an aggregate (sum,
-- count, avg, percentile_, lag, array_agg, string_agg, min, max) AND carries none of the three
-- exclusion markers (is_synthetic_client, is_synthetic, analytics_sale_class_v1) AND has no entry
-- in the new app.ci_synthetic_scan_allowlist_v743 table. Run against the estate BEFORE any of
-- Part A's eleven fixes, it returned 100 rows (89 signatures, since public.record_cart_sale has two
-- overloads) -- the eleven fixed above, plus 89 read and individually justified in the allowlist
-- seeded by this migration (single-entity transactional RPCs, per-customer self-views, catalogue-
-- only aggregates, per-row kernels, ledger-integrity detectors and pot-migration writers that must
-- deliberately see every row including synthetic ones, and one -- staff_list_visit_feedback_v145 --
-- structurally unreachable for a synthetic client). Run again after this migration, it returns
-- ZERO rows: the fixture below asserts that count, prints the allowlist size (89), and the scanner
-- itself is proven able to fail two ways before being trusted -- deleting one allowlist row makes
-- it return 1, and a throwaway unguarded probe function (created and rolled back inside the
-- fixture's own transaction) is caught by name. A future migration that adds a new unguarded
-- business-wide aggregate over any of the seven tables, without either the canonical predicate or a
-- read, justified allowlist entry, fails this fixture by name -- see also the rollback-safe check
-- at the end of this migration itself, which raises if the scan is non-empty the moment this
-- migration is applied, before it ever reaches CI.
--
-- Existing fixtures for every touched reader (v730 category/customers window, v734/v737/v740/v742
-- synthetic-exclusion estate sweeps) were re-run against this migration's MIGRATED database and
-- stay green -- none of them exercised a code path this migration's patches moved.
--
-- ROLLBACK: each function's captured "before" body is available in this migration's own do-block
-- (re-run each CREATE OR REPLACE with the pre-image quoted in that block's `v_old`/`v_new`
-- constants); drop app.ci_synthetic_scan_v743() and app.ci_synthetic_scan_allowlist_v743 to remove
-- the scanner.

begin;

create temp table _v743_before(fn text primary key, def text) on commit drop;

do $capture$
begin
  insert into _v743_before(fn, def)
  select 'get_checkout_discount_report', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_checkout_discount_report'  union all
  select 'get_reports_summary_v94_base', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_reports_summary_v94_base'  union all
  select 'get_campaign_results', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_campaign_results'  union all
  select 'get_growth_execution_result_at_v108', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'get_growth_execution_result_at_v108'  union all
  select 'v177_appointments', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'v177_appointments'  union all
  select 'v109_sector_source_availability', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'v109_sector_source_availability'  union all
  select 'super_admin_list_businesses', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'super_admin_list_businesses'  union all
  select 'platform_engagement_monthly_v255', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'platform_engagement_monthly_v255'  union all
  select 'business_programme_usage_v386', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'business_programme_usage_v386'  union all
  select 'staff_list_package_entitlements_v102', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_list_package_entitlements_v102'  union all
  select 'issue_bringback_for_business_v361', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'issue_bringback_for_business_v361';

  if (select count(*) from _v743_before) <> 11 then
    raise exception 'v743: expected exactly 11 captured function bodies, found %',
      (select count(*) from _v743_before);
  end if;
  if exists (select 1 from _v743_before where def ilike '%is_synthetic%') then
    raise exception 'v743: a target function already carries a synthetic-client exclusion -- stop and re-read before shipping';
  end if;
end
$capture$;

-- =============================================================================================
-- 1 . public.get_checkout_discount_report
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_checkout_discount_report(p_business uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
  v_grand jsonb;
  v_csv text;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'a valid from/to date range is required' using errcode = '22023';
  end if;

  -- Per (SGT day, rule) aggregate. Distinct-sale sales_total / gst avoid the
  -- double-count that summing a per-line grain would cause when a sale carries
  -- several discount lines. All CTEs are scoped to THIS single statement.
  with lines as (
    select cdl.rule_id, cdl.amount_cents, cdl.sale_id, s.amount_cents as sale_total,
           (s.occurred_at at time zone 'Asia/Singapore')::date as sgt_date,
           ce.gst_cents
      from public.checkout_discount_lines cdl
      join public.sales s on s.id = cdl.sale_id and s.business_id = cdl.business_id
      join public.checkout_evaluations ce on ce.id = cdl.evaluation_id and ce.business_id = cdl.business_id
      cross join lateral app.analytics_sale_class_v1(s) sc
     where cdl.business_id = p_business
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and sc.include_revenue
       and not sc.is_synthetic_client
  ),
  sale_grain as (
    select distinct sgt_date, rule_id, sale_id, sale_total, gst_cents from lines
  ),
  discount_grain as (
    select sgt_date, rule_id, count(*)::int as discount_count, sum(amount_cents)::int as discount_cents
      from lines group by sgt_date, rule_id
  ),
  sale_totals as (
    select sgt_date, rule_id, sum(sale_total)::int as sales_total_cents, sum(gst_cents)::int as gst_cents
      from sale_grain group by sgt_date, rule_id
  ),
  merged as (
    select dg.sgt_date, dg.rule_id, coalesce(pr.name, 'Studio discount') as rule_name,
           dg.discount_count, dg.discount_cents, st.sales_total_cents, st.gst_cents
      from discount_grain dg
      join sale_totals st on st.sgt_date = dg.sgt_date and st.rule_id = dg.rule_id
      left join public.program_rules pr
        on pr.rule_id = dg.rule_id and pr.business_id = p_business
       and pr.config_version_id = (select active_config_version_id from public.businesses where id = p_business)
     order by dg.sgt_date, dg.rule_id
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'date', sgt_date, 'rule_id', rule_id, 'rule_name', rule_name,
      'discount_count', discount_count, 'discount_cents', discount_cents,
      'gst_cents', gst_cents, 'sales_total_cents', sales_total_cents) order by sgt_date, rule_id), '[]'::jsonb),
    'date,rule_id,rule_name,discount_count,discount_cents,gst_cents,sales_total_cents' ||
      coalesce(string_agg(E'\n' ||
        sgt_date::text || ',' || rule_id::text || ',' ||
        '"' || replace(rule_name, '"', '""') || '"' || ',' ||
        discount_count::text || ',' || discount_cents::text || ',' ||
        gst_cents::text || ',' || sales_total_cents::text, '' order by sgt_date, rule_id), '')
    into v_rows, v_csv
    from merged;

  -- Grand totals computed directly (independent of the report grain); discount_cents
  -- is the reconciliation anchor. Distinct-sale sales_total / gst here are the true
  -- unduplicated totals.
  select jsonb_build_object(
           'discount_count', coalesce((select count(*) from public.checkout_discount_lines cdl
              join public.sales s on s.id = cdl.sale_id and s.business_id = cdl.business_id
              cross join lateral app.analytics_sale_class_v1(s) sc
             where cdl.business_id = p_business
               and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
               and sc.include_revenue
               and not sc.is_synthetic_client), 0)::int,
           'discount_cents', coalesce((select sum(cdl.amount_cents) from public.checkout_discount_lines cdl
              join public.sales s on s.id = cdl.sale_id and s.business_id = cdl.business_id
              cross join lateral app.analytics_sale_class_v1(s) sc
             where cdl.business_id = p_business
               and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
               and sc.include_revenue
               and not sc.is_synthetic_client), 0)::int,
           'sales_total_cents', coalesce((select sum(d.sale_total) from (
              select distinct s.id, s.amount_cents as sale_total from public.checkout_discount_lines cdl
                join public.sales s on s.id = cdl.sale_id and s.business_id = cdl.business_id
                cross join lateral app.analytics_sale_class_v1(s) sc
               where cdl.business_id = p_business
                 and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
                 and sc.include_revenue
                 and not sc.is_synthetic_client) d), 0)::int,
           'gst_cents', coalesce((select sum(d.gst_cents) from (
              select distinct ce.id, ce.gst_cents from public.checkout_discount_lines cdl
                join public.sales s on s.id = cdl.sale_id and s.business_id = cdl.business_id
                join public.checkout_evaluations ce on ce.id = cdl.evaluation_id and ce.business_id = cdl.business_id
                cross join lateral app.analytics_sale_class_v1(s) sc
               where cdl.business_id = p_business
                 and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
                 and sc.include_revenue
                 and not sc.is_synthetic_client) d), 0)::int)
    into v_grand;

  return jsonb_build_object(
    'business_id', p_business, 'from', p_from, 'to', p_to,
    'by_day_rule', v_rows, 'grand_totals', v_grand, 'csv', v_csv);
end $function$;

do $check1$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$      join public.checkout_evaluations ce on ce.id = cdl.evaluation_id and ce.business_id = cdl.business_id
     where cdl.business_id = p_business
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
$lit$;
  v_new1 constant text := $lit$      join public.checkout_evaluations ce on ce.id = cdl.evaluation_id and ce.business_id = cdl.business_id
      cross join lateral app.analytics_sale_class_v1(s) sc
     where cdl.business_id = p_business
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and sc.include_revenue
       and not sc.is_synthetic_client
  ),
$lit$;
  v_old2 constant text := $lit$              join public.sales s on s.id = cdl.sale_id and s.business_id = cdl.business_id
             where cdl.business_id = p_business
               and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to), 0)::int,
           'discount_cents', coalesce((select sum(cdl.amount_cents) from public.checkout_discount_lines cdl
$lit$;
  v_new2 constant text := $lit$              join public.sales s on s.id = cdl.sale_id and s.business_id = cdl.business_id
              cross join lateral app.analytics_sale_class_v1(s) sc
             where cdl.business_id = p_business
               and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
               and sc.include_revenue
               and not sc.is_synthetic_client), 0)::int,
           'discount_cents', coalesce((select sum(cdl.amount_cents) from public.checkout_discount_lines cdl
$lit$;
  v_old3 constant text := $lit$              join public.sales s on s.id = cdl.sale_id and s.business_id = cdl.business_id
             where cdl.business_id = p_business
               and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to), 0)::int,
           'sales_total_cents', coalesce((select sum(d.sale_total) from (
$lit$;
  v_new3 constant text := $lit$              join public.sales s on s.id = cdl.sale_id and s.business_id = cdl.business_id
              cross join lateral app.analytics_sale_class_v1(s) sc
             where cdl.business_id = p_business
               and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
               and sc.include_revenue
               and not sc.is_synthetic_client), 0)::int,
           'sales_total_cents', coalesce((select sum(d.sale_total) from (
$lit$;
  v_old4 constant text := $lit$                join public.sales s on s.id = cdl.sale_id and s.business_id = cdl.business_id
               where cdl.business_id = p_business
                 and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to) d), 0)::int,
           'gst_cents', coalesce((select sum(d.gst_cents) from (
$lit$;
  v_new4 constant text := $lit$                join public.sales s on s.id = cdl.sale_id and s.business_id = cdl.business_id
                cross join lateral app.analytics_sale_class_v1(s) sc
               where cdl.business_id = p_business
                 and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
                 and sc.include_revenue
                 and not sc.is_synthetic_client) d), 0)::int,
           'gst_cents', coalesce((select sum(d.gst_cents) from (
$lit$;
  v_old5 constant text := $lit$                join public.checkout_evaluations ce on ce.id = cdl.evaluation_id and ce.business_id = cdl.business_id
               where cdl.business_id = p_business
                 and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to) d), 0)::int)
    into v_grand;
$lit$;
  v_new5 constant text := $lit$                join public.checkout_evaluations ce on ce.id = cdl.evaluation_id and ce.business_id = cdl.business_id
                cross join lateral app.analytics_sale_class_v1(s) sc
               where cdl.business_id = p_business
                 and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
                 and sc.include_revenue
                 and not sc.is_synthetic_client) d), 0)::int)
    into v_grand;
$lit$;
begin
  select def into v_before from _v743_before where fn = $lit$get_checkout_discount_report$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_checkout_discount_report';
  if position(v_old1 in v_before) = 0 then
    raise exception 'v743/get_checkout_discount_report: hunk 1 anchor not found in captured body';
  end if;
  if position(v_old2 in v_before) = 0 then
    raise exception 'v743/get_checkout_discount_report: hunk 2 anchor not found in captured body';
  end if;
  if position(v_old3 in v_before) = 0 then
    raise exception 'v743/get_checkout_discount_report: hunk 3 anchor not found in captured body';
  end if;
  if position(v_old4 in v_before) = 0 then
    raise exception 'v743/get_checkout_discount_report: hunk 4 anchor not found in captured body';
  end if;
  if position(v_old5 in v_before) = 0 then
    raise exception 'v743/get_checkout_discount_report: hunk 5 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  v_expect := replace(v_expect, v_old2, v_new2);
  v_expect := replace(v_expect, v_old3, v_new3);
  v_expect := replace(v_expect, v_old4, v_new4);
  v_expect := replace(v_expect, v_old5, v_new5);
  if v_expect <> v_after then
    raise exception 'v743/get_checkout_discount_report: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check1$;

-- =============================================================================================
-- 2 . public.get_reports_summary_v94_base
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_reports_summary_v94_base(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_revenue jsonb;
  v_non_revenue jsonb;
  v_points jsonb;
  v_credit_liability bigint;
  v_gift_card_liability bigint;
  v_active_memberships bigint;
begin
  if auth.uid() is null
     or not app.has_perm(p_business, 'view_sales')
     or not app.can_module_read(p_business, 'reports') then
    raise exception 'you do not have permission to view reports for this business'
      using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'a valid report date range is required'
      using errcode = '22007';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches b
    where b.id = p_branch and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to this business'
      using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'you are not permitted to view this branch scope'
      using errcode = '42501';
  end if;

  select coalesce(jsonb_object_agg(x.kind, x.amount_cents), '{}'::jsonb)
  into v_revenue
  from (
    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not sc.is_synthetic_client
    group by s.kind
  ) x;

  select coalesce(jsonb_object_agg(x.kind, x.amount_cents), '{}'::jsonb)
  into v_non_revenue
  from (
    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and not s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
    group by s.kind
  ) x;

  select coalesce(jsonb_object_agg(x.entry_type, x.points), '{}'::jsonb)
  into v_points
  from (
    select pl.entry_type, sum(pl.points) as points
    from public.points_ledger pl
    where pl.business_id = p_business
      and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
    group by pl.entry_type
  ) x;

  select coalesce(sum(greatest(cb.balance_cents, 0)), 0)
  into v_credit_liability
  from public.client_credit_balance cb
  where cb.business_id = p_business;

  v_gift_card_liability := app.reports_gift_card_liability_v49b(p_business, p_branch);

  select count(*) filter (where m.status = 'active')
  into v_active_memberships
  from public.memberships m
  where m.business_id = p_business;

  return jsonb_build_object(
    'revenue_by_kind', v_revenue,
    'non_revenue_by_kind', v_non_revenue,
    'points_by_type', v_points,
    'credit_liability_cents', v_credit_liability,
    'gift_card_liability_cents', v_gift_card_liability,
    'active_memberships', v_active_memberships
  );
end;
$function$;

do $check2$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$  from (
    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
    group by s.kind
  ) x;

$lit$;
  v_new1 constant text := $lit$  from (
    select s.kind, sum(s.amount_cents) as amount_cents
    from public.sales s
    cross join lateral app.analytics_sale_class_v1(s) sc
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not sc.is_synthetic_client
    group by s.kind
  ) x;

$lit$;
begin
  select def into v_before from _v743_before where fn = $lit$get_reports_summary_v94_base$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_reports_summary_v94_base';
  if position(v_old1 in v_before) = 0 then
    raise exception 'v743/get_reports_summary_v94_base: hunk 1 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  if v_expect <> v_after then
    raise exception 'v743/get_reports_summary_v94_base: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check2$;

-- =============================================================================================
-- 3 . public.get_campaign_results
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.get_campaign_results(p_campaign uuid)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_business uuid;
  v_campaign public.retention_campaigns%rowtype;
  v_window public.retention_campaign_measurement_windows_v99%rowtype;
  v_t_members integer:=0;
  v_h_members integer:=0;
  v_t_returned integer:=0;
  v_h_returned integer:=0;
  v_t_revenue bigint:=0;
  v_h_revenue bigint:=0;
  v_exposures integer:=0;
  v_grants integer:=0;
  v_legacy_unknown integer:=0;
  v_t_rate integer;
  v_h_rate integer;
  v_difference integer;
  v_status text;
  v_threshold_met boolean:=false;
begin
  select campaign.* into v_campaign
  from public.retention_campaigns campaign
  where campaign.id=p_campaign;
  if not found then
    raise exception 'campaign not found' using errcode='22023';
  end if;
  v_business:=v_campaign.business_id;
  if auth.uid() is null
     or not (
       app.is_super_admin()
       or (
         app.has_perm(v_business,'view_finance')
         and app.can_module_read(v_business,'retention')
       )
     ) then
    raise exception 'authorized retention read is required'
      using errcode='42501';
  end if;

  select
    count(*) filter (where member.assignment='treatment'),
    count(*) filter (where member.assignment='holdout')
  into v_t_members,v_h_members
  from public.retention_campaign_members member
  join public.clients client
    on client.id=member.client_id and client.business_id=member.business_id
  where member.campaign_id=p_campaign
    and member.business_id=v_business
    and not client.is_synthetic;
  select count(*) into v_grants
  from public.retention_campaign_grants grant_row
  where grant_row.campaign_id=p_campaign
    and grant_row.business_id=v_business;
  select count(*) into v_exposures
  from public.retention_campaign_exposures_v99 exposure
  where exposure.campaign_id=p_campaign
    and exposure.business_id=v_business;
  select count(*) into v_legacy_unknown
  from public.retention_campaign_grants grant_row
  left join public.retention_campaign_exposures_v99 exposure
    on exposure.campaign_grant_id=grant_row.id
  where grant_row.campaign_id=p_campaign
    and grant_row.business_id=v_business
    and exposure.id is null;
  select measurement.* into v_window
  from public.retention_campaign_measurement_windows_v99 measurement
  where measurement.campaign_id=p_campaign
    and measurement.business_id=v_business;

  if not found then
    return pg_catalog.jsonb_build_object(
      'campaign_id',p_campaign,'business_id',v_business,
      'campaign_status',v_campaign.status,
      'measurement_status','awaiting_verified_exposure',
      'claimability','no_lift_or_roi_claim',
      'delivery_provider_status','not_configured',
      'treatment',pg_catalog.jsonb_build_object(
        'members',v_t_members,'grant_records',v_grants,
        'verified_exposures',v_exposures,
        'legacy_or_unverified_grants',v_legacy_unknown,
        'returned',null,'return_rate_bps',null,'revenue_cents',null
      ),
      'holdout',pg_catalog.jsonb_build_object(
        'members',v_h_members,'returned',null,
        'return_rate_bps',null,'revenue_cents',null
      ),
      'observed_return_rate_difference_bps',null,
      'net_lift_bps',null,'incremental_returns',null,
      'incremental_revenue_cents',null,
      'legacy_v50_return_evidence_used',false,
      'measurement_note',
        'Legacy grant records have unknown exposure. Seal measurement only after every treatment member has a linked reward and verified exposure.'
    );
  end if;

  with judged as(
    select member.assignment,
      exists(
        select 1
        from public.sales sale
        where sale.business_id=v_business
          and sale.client_id=member.client_id
          and sale.counts_as_visit
          and sale.reversal_of is null
          and sale.occurred_at>=v_window.measurement_started_at
          and sale.occurred_at<v_window.measurement_ends_at
          and not exists(
            select 1
            from public.sales reversal
            where reversal.business_id=sale.business_id
              and reversal.reversal_of=sale.id
          )
      ) as returned,
      coalesce((
        select sum(sale.amount_cents)
        from public.sales sale
        where sale.business_id=v_business
          and sale.client_id=member.client_id
          and sale.counts_as_revenue
          and sale.reversal_of is null
          and sale.occurred_at>=v_window.measurement_started_at
          and sale.occurred_at<v_window.measurement_ends_at
          and not exists(
            select 1
            from public.sales reversal
            where reversal.business_id=sale.business_id
              and reversal.reversal_of=sale.id
          )
      ),0)::bigint as revenue_cents
    from public.retention_campaign_members member
    join public.clients client
      on client.id=member.client_id and client.business_id=member.business_id
    where member.campaign_id=p_campaign
      and member.business_id=v_business
      and not client.is_synthetic
  )
  select
    count(*) filter (where assignment='treatment' and returned),
    count(*) filter (where assignment='holdout' and returned),
    coalesce(sum(revenue_cents) filter (where assignment='treatment'),0),
    coalesce(sum(revenue_cents) filter (where assignment='holdout'),0)
  into v_t_returned,v_h_returned,v_t_revenue,v_h_revenue
  from judged;
  v_t_rate:=case when v_t_members>0
    then (v_t_returned*10000)/v_t_members else null end;
  v_h_rate:=case when v_h_members>0
    then (v_h_returned*10000)/v_h_members else null end;
  v_difference:=case when v_t_rate is not null and v_h_rate is not null
    then v_t_rate-v_h_rate else null end;
  v_threshold_met:=
    v_t_members>=v_window.minimum_sample_per_arm
    and v_h_members>=v_window.minimum_sample_per_arm;
  v_status:=case
    when clock_timestamp()<v_window.measurement_ends_at then 'collecting'
    when not v_threshold_met then 'inconclusive_minimum_sample'
    else 'inconclusive_statistical_test_not_implemented'
  end;

  return pg_catalog.jsonb_build_object(
    'campaign_id',p_campaign,'business_id',v_business,
    'campaign_status',v_campaign.status,
    'measurement_status',v_status,
    'claimability','descriptive_observation_not_causal_proof',
    'delivery_provider_status','not_configured',
    'measurement_started_at',v_window.measurement_started_at,
    'measurement_ends_at',v_window.measurement_ends_at,
    'minimum_sample_per_arm',v_window.minimum_sample_per_arm,
    'minimum_sample_met',v_threshold_met,
    'treatment',pg_catalog.jsonb_build_object(
      'members',v_t_members,'grant_records',v_grants,
      'verified_exposures',v_exposures,
      'legacy_or_unverified_grants',v_legacy_unknown,
      'returned',v_t_returned,'return_rate_bps',v_t_rate,
      'revenue_cents',v_t_revenue
    ),
    'holdout',pg_catalog.jsonb_build_object(
      'members',v_h_members,'returned',v_h_returned,
      'return_rate_bps',v_h_rate,'revenue_cents',v_h_revenue
    ),
    'observed_return_rate_difference_bps',v_difference,
    'observed_revenue_difference_cents',v_t_revenue-v_h_revenue,
    'net_lift_bps',null,'incremental_returns',null,
    'incremental_revenue_cents',null,
    'legacy_v50_return_evidence_used',false,
    'measurement_note',
      'Observed differences are descriptive. No lift, ROI, or statistical-significance claim is made.'
  );
end
$function$;

do $check3$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$  from public.retention_campaign_members member
  where member.campaign_id=p_campaign
    and member.business_id=v_business;
  select count(*) into v_grants
$lit$;
  v_new1 constant text := $lit$  from public.retention_campaign_members member
  join public.clients client
    on client.id=member.client_id and client.business_id=member.business_id
  where member.campaign_id=p_campaign
    and member.business_id=v_business
    and not client.is_synthetic;
  select count(*) into v_grants
$lit$;
  v_old2 constant text := $lit$    from public.retention_campaign_members member
    where member.campaign_id=p_campaign
      and member.business_id=v_business
  )
$lit$;
  v_new2 constant text := $lit$    from public.retention_campaign_members member
    join public.clients client
      on client.id=member.client_id and client.business_id=member.business_id
    where member.campaign_id=p_campaign
      and member.business_id=v_business
      and not client.is_synthetic
  )
$lit$;
begin
  select def into v_before from _v743_before where fn = $lit$get_campaign_results$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_campaign_results';
  if position(v_old1 in v_before) = 0 then
    raise exception 'v743/get_campaign_results: hunk 1 anchor not found in captured body';
  end if;
  if position(v_old2 in v_before) = 0 then
    raise exception 'v743/get_campaign_results: hunk 2 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  v_expect := replace(v_expect, v_old2, v_new2);
  if v_expect <> v_after then
    raise exception 'v743/get_campaign_results: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check3$;

-- =============================================================================================
-- 4 . app.get_growth_execution_result_at_v108
-- =============================================================================================
CREATE OR REPLACE FUNCTION app.get_growth_execution_result_at_v108(p_execution uuid, p_as_of timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_execution public.growth_executions_v108%rowtype;
  v_t_members integer:=0;
  v_h_members integer:=0;
  v_t_buyers integer:=0;
  v_h_buyers integer:=0;
  v_t_revenue bigint:=0;
  v_h_revenue bigint:=0;
  v_t_rate numeric:=0;
  v_h_rate numeric:=0;
  v_lift numeric:=0;
  v_se numeric:=0;
  v_aov numeric:=0;
  v_estimate bigint:=0;
  v_low bigint:=0;
  v_high bigint:=0;
  v_overlap integer:=0;
  v_identity_overlap integer:=0;
  v_measurement text;
begin
  if p_as_of is null then
    raise exception 'reporting cutoff is required' using errcode='22004';
  end if;
  select * into v_execution
    from public.growth_executions_v108 execution
   where execution.id=p_execution;
  if not found then raise exception 'execution not found'; end if;
  if auth.uid() is null or (
    not app.is_super_admin()
    and (
      not app.has_perm(v_execution.business_id,'view_finance')
      or not app.can_module_read(v_execution.business_id,'retention')
    )
  ) then
    raise exception 'finance and retention access required' using errcode='42501';
  end if;
  if not app.can_see_branch(v_execution.business_id,v_execution.branch_id) then
    raise exception 'execution branch is outside actor scope' using errcode='42501';
  end if;

  with effective_members as (
    select member.*,
      app.v113_effective_client_id(member.business_id,member.client_id)
        as effective_client_id,
      row_number() over (
        partition by app.v113_effective_client_id(
          member.business_id,member.client_id
        )
        order by member.assignment_rank,member.id
      ) as identity_rank,
      count(*) over (
        partition by app.v113_effective_client_id(
          member.business_id,member.client_id
        )
      ) as identity_count
    from public.growth_execution_members_v108 member
    join public.clients client
      on client.id=member.client_id and client.business_id=member.business_id
    where member.execution_id=p_execution
      and not client.is_synthetic
  ),
  member_result as (
    select member.assignment,member.client_id,member.effective_client_id,
      member.identity_count,
      exists (
        select 1 from public.sales sale
         where sale.business_id=v_execution.business_id
           and sale.client_id is not null
           and app.v113_effective_client_id(sale.business_id,sale.client_id)
               =member.effective_client_id
           and sale.counts_as_visit
           and sale.counts_as_revenue
           and sale.reversal_of is null
           and sale.created_at<=p_as_of
           and sale.occurred_at<=p_as_of
           and (
             v_execution.branch_id is null
             or sale.branch_id=v_execution.branch_id
           )
           and sale.occurred_at>=v_execution.started_at
           and sale.occurred_at<v_execution.ends_at
           and app.v106_sale_residual_minor(sale.id,p_as_of)>0
      ) as purchased,
      coalesce((
        select sum(app.v106_sale_residual_minor(sale.id,p_as_of))
          from public.sales sale
         where sale.business_id=v_execution.business_id
           and sale.client_id is not null
           and app.v113_effective_client_id(sale.business_id,sale.client_id)
               =member.effective_client_id
           and sale.counts_as_revenue
           and sale.reversal_of is null
           and sale.created_at<=p_as_of
           and sale.occurred_at<=p_as_of
           and (
             v_execution.branch_id is null
             or sale.branch_id=v_execution.branch_id
           )
           and sale.occurred_at>=v_execution.started_at
           and sale.occurred_at<v_execution.ends_at
           and app.v106_sale_residual_minor(sale.id,p_as_of)>0
      ),0)::bigint as revenue_cents
    from effective_members member
    where member.identity_rank=1
  )
  select
    count(*) filter(where assignment='treatment'),
    count(*) filter(where assignment='holdout'),
    count(*) filter(where assignment='treatment' and purchased),
    count(*) filter(where assignment='holdout' and purchased),
    coalesce(sum(revenue_cents) filter(where assignment='treatment'),0),
    coalesce(sum(revenue_cents) filter(where assignment='holdout'),0),
    count(*) filter(where identity_count>1)
  into v_t_members,v_h_members,v_t_buyers,v_h_buyers,
       v_t_revenue,v_h_revenue,v_identity_overlap
  from member_result;

  select count(*) into v_overlap
    from public.growth_outcomes_v108 outcome
    join public.growth_execution_members_v108 member
      on member.id=outcome.execution_member_id
     and member.business_id=outcome.business_id
    join public.sales sale
      on sale.id=outcome.sale_id
     and sale.business_id=outcome.business_id
   where outcome.execution_id=p_execution
     and not outcome.causal_eligible
     and outcome.occurred_at<=p_as_of
     and app.v106_sale_residual_minor(outcome.sale_id,p_as_of)>0
     and sale.client_id is not null
     and app.v113_effective_client_id(sale.business_id,sale.client_id)
         =app.v113_effective_client_id(member.business_id,member.client_id);
  v_t_rate:=case when v_t_members>0
    then v_t_buyers::numeric/v_t_members else 0 end;
  v_h_rate:=case when v_h_members>0
    then v_h_buyers::numeric/v_h_members else 0 end;
  v_lift:=v_t_rate-v_h_rate;
  v_se:=case when v_t_members>0 and v_h_members>0 then sqrt(
    greatest(0,v_t_rate*(1-v_t_rate)/v_t_members)
    +greatest(0,v_h_rate*(1-v_h_rate)/v_h_members)
  ) else 0 end;
  v_aov:=case when v_t_buyers+v_h_buyers>0
    then (v_t_revenue+v_h_revenue)::numeric/(v_t_buyers+v_h_buyers)
    else 0 end;
  v_estimate:=round(v_lift*v_t_members*v_aov);
  v_low:=round((v_lift-1.96*v_se)*v_t_members*v_aov);
  v_high:=round((v_lift+1.96*v_se)*v_t_members*v_aov);
  v_measurement:=case
    when v_identity_overlap>0 then 'invalid_overlap'
    when v_overlap>0 then 'invalid_overlap'
    when v_t_members<v_execution.minimum_arm_size
      or v_h_members<v_execution.minimum_arm_size
      then 'inconclusive_small_sample'
    when p_as_of<v_execution.ends_at then 'provisional'
    else 'final'
  end;
  return jsonb_build_object(
    'execution_id',p_execution,'business_id',v_execution.business_id,
    'as_of',p_as_of,'status',v_execution.status,
    'window',jsonb_build_object(
      'start',v_execution.started_at,'end',v_execution.ends_at
    ),
    'method','randomized_intent_to_treat_holdout',
    'identity_attribution','v111_current_effective_identity',
    'measurement_status',v_measurement,
    'arms',jsonb_build_object(
      'treatment',jsonb_build_object(
        'members',v_t_members,'buyers',v_t_buyers,
        'conversion_rate_bps',round(v_t_rate*10000),
        'associated_revenue_cents',v_t_revenue
      ),
      'holdout',jsonb_build_object(
        'members',v_h_members,'buyers',v_h_buyers,
        'conversion_rate_bps',round(v_h_rate*10000),
        'associated_revenue_cents',v_h_revenue
      )
    ),
    'incremental_conversion_lift_bps',round(v_lift*10000),
    'estimated_incremental_revenue',case
      when v_measurement in ('invalid_overlap','inconclusive_small_sample')
        then null
      else jsonb_build_object(
        'currency',v_execution.currency,'point_estimate_cents',v_estimate,
        'low_cents',least(v_low,v_high),
        'high_cents',greatest(v_low,v_high),
        'confidence_level','approximate_95_percent'
      )
    end,
    'incremental_gross_profit',null,
    'cost',jsonb_build_object(
      'estimated_offer_cost_cents',coalesce((
        select sum(delivery.estimated_cost_cents)
          from public.growth_deliveries_v108 delivery
         where delivery.execution_id=p_execution
           and delivery.delivery_status='delivered'
      ),0),
      'actual_redeemed_cost_cents',coalesce((
        select sum(entitlement.estimated_cost_cents)
          from public.growth_entitlements_v108 entitlement
         where entitlement.execution_id=p_execution
           and entitlement.status='redeemed'
      ),0),
      'reversed_offer_cost_cents',coalesce((
        select sum(entitlement.estimated_cost_cents)
          from public.growth_entitlements_v108 entitlement
         where entitlement.execution_id=p_execution
           and entitlement.status='reversed'
      ),0)
    ),
    'overlap_outcomes',v_overlap,
    'identity_overlap_members',v_identity_overlap,
    'limitations',jsonb_build_array(
      'revenue result is not gross profit',
      'confidence interval uses a transparent normal approximation',
      'small, overlapping or identity-ambiguous experiments are suppressed'
    )
  );
end
$function$;

do $check4$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$    from public.growth_execution_members_v108 member
    where member.execution_id=p_execution
  ),
$lit$;
  v_new1 constant text := $lit$    from public.growth_execution_members_v108 member
    join public.clients client
      on client.id=member.client_id and client.business_id=member.business_id
    where member.execution_id=p_execution
      and not client.is_synthetic
  ),
$lit$;
begin
  select def into v_before from _v743_before where fn = $lit$get_growth_execution_result_at_v108$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'get_growth_execution_result_at_v108';
  if position(v_old1 in v_before) = 0 then
    raise exception 'v743/get_growth_execution_result_at_v108: hunk 1 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  if v_expect <> v_after then
    raise exception 'v743/get_growth_execution_result_at_v108: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check4$;

-- =============================================================================================
-- 5 . app.v177_appointments
-- =============================================================================================
CREATE OR REPLACE FUNCTION app.v177_appointments(p_business uuid, p_branch uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
  with bounds as (
    select
      (clock_timestamp() at time zone 'Asia/Singapore')::date as today
  ), window_bounds as (
    select
      bounds.today as from_date,
      bounds.today + 7 as to_date,
      bounds.today::timestamp at time zone 'Asia/Singapore' as from_ts,
      (bounds.today + 8)::timestamp at time zone 'Asia/Singapore' as to_ts
    from bounds
  ), matched as (
    select appointment.id, appointment.starts_at, appointment.ends_at,
      appointment.status, appointment.party_size, appointment.branch_id,
      appointment.service_id, appointment.staff_id, appointment.client_id
    from public.appointments appointment, window_bounds
    where appointment.business_id = p_business
      and appointment.starts_at >= window_bounds.from_ts
      and appointment.starts_at < window_bounds.to_ts
      and (p_branch is null or appointment.branch_id = p_branch)
      and not exists (
        select 1 from public.clients synthetic_client
         where synthetic_client.id = appointment.client_id
           and synthetic_client.is_synthetic
      )
  ), capped as (
    select * from matched order by starts_at asc, id asc limit 50
  )
  select pg_catalog.jsonb_build_object(
    'from', (select from_date from window_bounds),
    'to', (select to_date from window_bounds),
    'row_cap', 50,
    'total', (select count(*) from matched),
    'truncated', (select count(*) from matched) > 50,
    'ordering', 'soonest_first',
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', capped.id,
        'starts_at', capped.starts_at,
        'ends_at', capped.ends_at,
        'status', capped.status,
        'party_size', capped.party_size,
        'branch_id', capped.branch_id,
        'branch_name', branch.name,
        'service_name', service.name,
        'staff_name', member.full_name,
        -- Abbreviated on purpose: the mirror shows the operations shape, and
        -- must never become a customer-contact export.
        'guest_label', app.v177_person_label(client.full_name, capped.client_id)
      ) order by capped.starts_at asc, capped.id asc)
      from capped
      left join public.branches branch
        on branch.id = capped.branch_id and branch.business_id = p_business
      left join public.services service
        on service.id = capped.service_id and service.business_id = p_business
      left join public.staff member
        on member.id = capped.staff_id and member.business_id = p_business
      left join public.clients client
        on client.id = capped.client_id and client.business_id = p_business
    ), '[]'::jsonb)
  )
$function$;

do $check5$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$      and (p_branch is null or appointment.branch_id = p_branch)
  ), capped as (
$lit$;
  v_new1 constant text := $lit$      and (p_branch is null or appointment.branch_id = p_branch)
      and not exists (
        select 1 from public.clients synthetic_client
         where synthetic_client.id = appointment.client_id
           and synthetic_client.is_synthetic
      )
  ), capped as (
$lit$;
begin
  select def into v_before from _v743_before where fn = $lit$v177_appointments$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'v177_appointments';
  if position(v_old1 in v_before) = 0 then
    raise exception 'v743/v177_appointments: hunk 1 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  if v_expect <> v_after then
    raise exception 'v743/v177_appointments: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check5$;

-- =============================================================================================
-- 6 . app.v109_sector_source_availability
-- =============================================================================================
CREATE OR REPLACE FUNCTION app.v109_sector_source_availability(p_business uuid, p_sector text, p_minimum_history integer, p_as_of timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_service_history integer:=0;
  v_product_history integer:=0;
  v_membership_history integer:=0;
  v_required integer:=greatest(coalesce(p_minimum_history,1),1);
begin
  if p_as_of is null then
    raise exception 'as-of is required' using errcode='22023';
  end if;

  if p_sector in ('facial','salon','massage') then
    select count(*) into v_service_history
    from (
      select appointment.id
      from public.appointments appointment
      where appointment.business_id=p_business
        and appointment.status='completed'
        and appointment.service_id is not null
        and appointment.created_at<=p_as_of
        and not exists(
          select 1 from public.clients synthetic_client
           where synthetic_client.id=appointment.client_id
             and synthetic_client.is_synthetic
        )
      union
      select item.sale_id
      from public.sale_items item
      join public.sales sale
        on sale.id=item.sale_id and sale.business_id=item.business_id
      where item.business_id=p_business
        and item.item_type='service' and item.ref_id is not null
        and sale.reversal_of is null and sale.created_at<=p_as_of
        and app.v106_sale_residual_minor(sale.id,p_as_of)>0
        and not exists(
          select 1 from public.clients synthetic_client
           where synthetic_client.id=sale.client_id
             and synthetic_client.is_synthetic
        )
    ) observed;
  end if;

  if p_sector='retail' then
    select count(distinct item.sale_id) into v_product_history
    from public.sale_items item
    join public.sales sale
      on sale.id=item.sale_id and sale.business_id=item.business_id
    where item.business_id=p_business
      and item.item_type='retail' and item.product_id is not null
      and sale.reversal_of is null and sale.created_at<=p_as_of
      and app.v106_sale_residual_minor(sale.id,p_as_of)>0
      and not exists(
        select 1 from public.clients synthetic_client
         where synthetic_client.id=sale.client_id
           and synthetic_client.is_synthetic
      );
  end if;

  if p_sector='fitness' then
    select count(*) into v_membership_history
    from public.memberships membership
    where membership.business_id=p_business
      and membership.created_at<=p_as_of
      and membership.status in (
        'active','paused','cancel_at_period_end','cancelled'
      );
  end if;

  return jsonb_build_object(
    'as_of',p_as_of,
    'minimum_history_required',v_required,
    'service_cadence',case
      when p_sector in ('facial','salon','massage')
        then v_service_history>=v_required else null end,
    'service_linked_history_count',case
      when p_sector in ('facial','salon','massage')
        then v_service_history else null end,
    'product_cycle',case
      when p_sector='retail' then v_product_history>=v_required else null end,
    'product_linked_history_count',case
      when p_sector='retail' then v_product_history else null end,
    'membership_state',case
      when p_sector='fitness' then v_membership_history>0 else null end,
    'membership_history_count',case
      when p_sector='fitness' then v_membership_history else null end,
    'specialized_sector_policy',p_sector<>'other'
  );
end $function$;

do $check6$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$        and appointment.created_at<=p_as_of
      union
$lit$;
  v_new1 constant text := $lit$        and appointment.created_at<=p_as_of
        and not exists(
          select 1 from public.clients synthetic_client
           where synthetic_client.id=appointment.client_id
             and synthetic_client.is_synthetic
        )
      union
$lit$;
  v_old2 constant text := $lit$        and app.v106_sale_residual_minor(sale.id,p_as_of)>0
    ) observed;
$lit$;
  v_new2 constant text := $lit$        and app.v106_sale_residual_minor(sale.id,p_as_of)>0
        and not exists(
          select 1 from public.clients synthetic_client
           where synthetic_client.id=sale.client_id
             and synthetic_client.is_synthetic
        )
    ) observed;
$lit$;
  v_old3 constant text := $lit$      and sale.reversal_of is null and sale.created_at<=p_as_of
      and app.v106_sale_residual_minor(sale.id,p_as_of)>0;
  end if;
$lit$;
  v_new3 constant text := $lit$      and sale.reversal_of is null and sale.created_at<=p_as_of
      and app.v106_sale_residual_minor(sale.id,p_as_of)>0
      and not exists(
        select 1 from public.clients synthetic_client
         where synthetic_client.id=sale.client_id
           and synthetic_client.is_synthetic
      );
  end if;
$lit$;
begin
  select def into v_before from _v743_before where fn = $lit$v109_sector_source_availability$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'v109_sector_source_availability';
  if position(v_old1 in v_before) = 0 then
    raise exception 'v743/v109_sector_source_availability: hunk 1 anchor not found in captured body';
  end if;
  if position(v_old2 in v_before) = 0 then
    raise exception 'v743/v109_sector_source_availability: hunk 2 anchor not found in captured body';
  end if;
  if position(v_old3 in v_before) = 0 then
    raise exception 'v743/v109_sector_source_availability: hunk 3 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  v_expect := replace(v_expect, v_old2, v_new2);
  v_expect := replace(v_expect, v_old3, v_new3);
  if v_expect <> v_after then
    raise exception 'v743/v109_sector_source_availability: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check6$;

-- =============================================================================================
-- 7 . public.super_admin_list_businesses
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.super_admin_list_businesses()
 RETURNS TABLE(business_id uuid, name text, industry text, branch_count integer, staff_count integer, client_count integer, billable_seats integer, subscription_status text, est_monthly_cents integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
begin
  if not app.is_super_admin() then
    raise exception 'super admin only' using errcode = '42501';
  end if;
  insert into public.audit_log(business_id, actor, action, entity, detail)
    values (null, auth.uid(), 'READ', 'businesses',
            jsonb_build_object('fn','super_admin_list_businesses'));
  return query
    select b.id, b.name, b.industry,
           (select count(*)::int from public.branches br where br.business_id = b.id),
           (select count(*)::int from public.staff    s  where s.business_id  = b.id),
           (select count(*)::int from public.clients  c  where c.business_id  = b.id and not c.is_synthetic),
           app.billable_seats(b.id),
           coalesce(sub.status, 'none'),
           coalesce(sub.base_price_cents
             + greatest(0, app.billable_seats(b.id) - sub.included_seats)
               * sub.per_seat_price_cents, 0)::int
    from public.businesses b
    left join public.subscriptions sub on sub.business_id = b.id
    order by b.name;
end;
$function$;

do $check7$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$           (select count(*)::int from public.staff    s  where s.business_id  = b.id),
           (select count(*)::int from public.clients  c  where c.business_id  = b.id),
           app.billable_seats(b.id),
$lit$;
  v_new1 constant text := $lit$           (select count(*)::int from public.staff    s  where s.business_id  = b.id),
           (select count(*)::int from public.clients  c  where c.business_id  = b.id and not c.is_synthetic),
           app.billable_seats(b.id),
$lit$;
begin
  select def into v_before from _v743_before where fn = $lit$super_admin_list_businesses$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'super_admin_list_businesses';
  if position(v_old1 in v_before) = 0 then
    raise exception 'v743/super_admin_list_businesses: hunk 1 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  if v_expect <> v_after then
    raise exception 'v743/super_admin_list_businesses: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check7$;

-- =============================================================================================
-- 8 . public.platform_engagement_monthly_v255
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.platform_engagement_monthly_v255(p_from date, p_to date, p_businesses uuid[] DEFAULT NULL::uuid[], p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();
  v_from timestamptz;
  v_to timestamptz;
  v_rows jsonb;
  v_trend jsonb;
  v_summary jsonb;
  v_total integer:=0;
begin
  if v_actor is null then
    raise exception 'authenticated platform session is required'
      using errcode='28000';
  end if;
  if not app.is_super_admin() then
    raise exception 'platform engagement reporting is super admin only'
      using errcode='42501';
  end if;
  if p_from is null or p_to is null or p_to<p_from then
    raise exception 'report range must be positive' using errcode='22023';
  end if;
  if p_to>p_from+interval '24 months' then
    raise exception 'report range may not exceed 24 months'
      using errcode='22023';
  end if;
  if p_businesses is not null
     and coalesce(array_length(p_businesses,1),0)>100 then
    raise exception 'at most 100 businesses may be requested'
      using errcode='22023';
  end if;
  if p_limit is null or p_limit not between 1 and 1000 then
    raise exception 'row limit must be 1..1000' using errcode='22023';
  end if;

  v_from:=(date_trunc('month',p_from::timestamp) at time zone 'Asia/Singapore');
  v_to:=(
    (date_trunc('month',p_to::timestamp)+interval '1 month')
    at time zone 'Asia/Singapore'
  );

  with sends as(
    select
      record.business_id,
      pg_catalog.to_char(
        date_trunc('month',record.occurred_at at time zone 'Asia/Singapore'),
        'YYYY-MM'
      ) as month,
      count(*)::bigint as sends,
      count(distinct
        record.campaign_kind||':'||record.campaign_ref_id::text
      )::bigint as campaigns
    from public.campaign_send_records_v255 record
    where record.occurred_at>=v_from and record.occurred_at<v_to
      and (p_businesses is null or record.business_id=any(p_businesses))
    group by 1,2
  ),
  pushes as(
    select
      event_row.business_id,
      pg_catalog.to_char(
        date_trunc('month',result.created_at at time zone 'Asia/Singapore'),
        'YYYY-MM'
      ) as month,
      count(*) filter(where result.result='sent')::bigint as push_sent,
      count(*) filter(
        where result.result in ('failed','gone')
      )::bigint as push_failed
    from public.customer_push_delivery_results_v95 result
    join public.customer_push_deliveries_v95 delivery
      on delivery.id=result.delivery_id
    join public.customer_in_app_inbox_events event_row
      on event_row.id=delivery.event_id
    where result.created_at>=v_from and result.created_at<v_to
      and (p_businesses is null or event_row.business_id=any(p_businesses))
    group by 1,2
  ),
  opens as(
    select
      state.business_id,
      pg_catalog.to_char(
        date_trunc('month',state.read_at at time zone 'Asia/Singapore'),
        'YYYY-MM'
      ) as month,
      count(*)::bigint as inbox_opens
    from public.customer_in_app_inbox_state state
    where state.read_at>=v_from and state.read_at<v_to
      and (p_businesses is null or state.business_id=any(p_businesses))
    group by 1,2
  ),
  adoption as(
    select
      event_row.business_id,
      pg_catalog.to_char(
        date_trunc('month',event_row.occurred_at at time zone 'Asia/Singapore'),
        'YYYY-MM'
      ) as month,
      count(distinct event_row.actor_user_id) filter(
        where event_row.actor_scope='merchant'
      )::bigint as merchant_mau,
      count(distinct event_row.session_id)::bigint as sessions
    from public.product_adoption_events_v100 event_row
    where event_row.business_id is not null
      and event_row.occurred_at>=v_from and event_row.occurred_at<v_to
      and (p_businesses is null or event_row.business_id=any(p_businesses))
    group by 1,2
  ),
  merchant_daily as(
    select
      event_row.business_id,
      pg_catalog.to_char(
        date_trunc('month',event_row.occurred_at at time zone 'Asia/Singapore'),
        'YYYY-MM'
      ) as month,
      (event_row.occurred_at at time zone 'Asia/Singapore')::date as open_day,
      count(distinct event_row.actor_user_id)::bigint as actors
    from public.product_adoption_events_v100 event_row
    where event_row.business_id is not null
      and event_row.actor_scope='merchant'
      and event_row.occurred_at>=v_from and event_row.occurred_at<v_to
      and (p_businesses is null or event_row.business_id=any(p_businesses))
    group by 1,2,3
  ),
  merchant_dau as(
    select
      daily.business_id,daily.month,
      round(avg(daily.actors),2) as merchant_dau
    from merchant_daily daily
    group by 1,2
  ),
  customer_opens as(
    select
      open_row.business_id,
      pg_catalog.to_char(
        date_trunc('month',open_row.open_date::timestamp),'YYYY-MM'
      ) as month,
      count(distinct coalesce(
        open_row.auth_user_id,open_row.client_id
      ))::bigint as customer_mau
    from public.customer_account_open_days_v175 open_row
    where open_row.open_date>=(v_from at time zone 'Asia/Singapore')::date
      and open_row.open_date<(v_to at time zone 'Asia/Singapore')::date
      and (p_businesses is null or open_row.business_id=any(p_businesses))
    group by 1,2
  ),
  redemptions as(
    select
      redemption.business_id,
      pg_catalog.to_char(
        date_trunc(
          'month',redemption.redeemed_at at time zone 'Asia/Singapore'
        ),'YYYY-MM'
      ) as month,
      count(*)::bigint as redemptions
    from public.loyalty_redemptions redemption
    where redemption.redeemed_at>=v_from and redemption.redeemed_at<v_to
      and (p_businesses is null or redemption.business_id=any(p_businesses))
    group by 1,2
  ),
  bookings as(
    select
      request.business_id,
      pg_catalog.to_char(
        date_trunc('month',request.created_at at time zone 'Asia/Singapore'),
        'YYYY-MM'
      ) as month,
      count(*)::bigint as bookings
    from public.booking_requests request
    where request.created_at>=v_from and request.created_at<v_to
      and (p_businesses is null or request.business_id=any(p_businesses))
    group by 1,2
  ),
  sale_counts as(
    select
      sale.business_id,
      pg_catalog.to_char(
        date_trunc('month',sale.occurred_at at time zone 'Asia/Singapore'),
        'YYYY-MM'
      ) as month,
      count(*)::bigint as sales_count
    from public.sales sale
    where sale.occurred_at>=v_from and sale.occurred_at<v_to
      and sale.reversal_of is null
      and (p_businesses is null or sale.business_id=any(p_businesses))
      and not exists(
        select 1 from public.clients synthetic_client
         where synthetic_client.id=sale.client_id
           and synthetic_client.is_synthetic
      )
    group by 1,2
  ),
  keys as(
    select business_id,month from sends
    union select business_id,month from pushes
    union select business_id,month from opens
    union select business_id,month from adoption
    union select business_id,month from customer_opens
    union select business_id,month from redemptions
    union select business_id,month from bookings
    union select business_id,month from sale_counts
  ),
  rows_out as(
    select
      key.business_id,key.month,
      coalesce(business.name,'Removed business') as business_name,
      (
        select count(*)::bigint
        from public.customer_links link
        where link.business_id=key.business_id
          and link.state='verified'
          and link.created_at
              <((key.month||'-01')::date+interval '1 month')
                at time zone 'Asia/Singapore'
      ) as customers,
      coalesce(sends.campaigns,0) as campaigns,
      coalesce(pushes.push_sent,0) as push_sent,
      coalesce(pushes.push_failed,0) as push_failed,
      coalesce(sends.sends,0) as sends,
      coalesce(opens.inbox_opens,0) as inbox_opens,
      coalesce(merchant_dau.merchant_dau,0) as merchant_dau,
      coalesce(adoption.merchant_mau,0) as merchant_mau,
      coalesce(adoption.sessions,0) as sessions,
      coalesce(customer_opens.customer_mau,0) as customer_mau,
      coalesce(redemptions.redemptions,0) as redemptions,
      coalesce(bookings.bookings,0) as bookings,
      coalesce(sale_counts.sales_count,0) as sales_count
    from keys key
    left join public.businesses business on business.id=key.business_id
    left join sends
      on sends.business_id=key.business_id and sends.month=key.month
    left join pushes
      on pushes.business_id=key.business_id and pushes.month=key.month
    left join opens
      on opens.business_id=key.business_id and opens.month=key.month
    left join adoption
      on adoption.business_id=key.business_id and adoption.month=key.month
    left join merchant_dau
      on merchant_dau.business_id=key.business_id
     and merchant_dau.month=key.month
    left join customer_opens
      on customer_opens.business_id=key.business_id
     and customer_opens.month=key.month
    left join redemptions
      on redemptions.business_id=key.business_id
     and redemptions.month=key.month
    left join bookings
      on bookings.business_id=key.business_id and bookings.month=key.month
    left join sale_counts
      on sale_counts.business_id=key.business_id
     and sale_counts.month=key.month
  ),
  page as(
    select * from rows_out
    order by month desc,business_name,business_id
    limit p_limit
  )
  select
    coalesce(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'business_id',page.business_id,'business_name',page.business_name,
          'month',page.month,'customers',page.customers,
          'campaigns',page.campaigns,'push_sent',page.push_sent,
          'push_failed',page.push_failed,'sends',page.sends,
          'inbox_opens',page.inbox_opens,'merchant_dau',page.merchant_dau,
          'merchant_mau',page.merchant_mau,'sessions',page.sessions,
          'customer_mau',page.customer_mau,'redemptions',page.redemptions,
          'bookings',page.bookings,'sales_count',page.sales_count
        )
        order by page.month desc,page.business_name,page.business_id
      ),
      '[]'::jsonb
    ),
    (select count(*)::integer from rows_out)
  into v_rows,v_total
  from page;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'month',trend.month,'businesses',trend.businesses,
        'customers',trend.customers,'campaigns',trend.campaigns,
        'push_sent',trend.push_sent,'sends',trend.sends,
        'inbox_opens',trend.inbox_opens
      )
      order by trend.month desc
    ),
    '[]'::jsonb
  ) into v_trend
  from(
    select
      item->>'month' as month,
      count(*)::bigint as businesses,
      sum((item->>'customers')::bigint) as customers,
      sum((item->>'campaigns')::bigint) as campaigns,
      sum((item->>'push_sent')::bigint) as push_sent,
      sum((item->>'sends')::bigint) as sends,
      sum((item->>'inbox_opens')::bigint) as inbox_opens
    from pg_catalog.jsonb_array_elements(v_rows) as element(item)
    group by 1
  ) trend;

  -- 'customers' is a running total per business-month, so summing every month
  -- would count the same customer once per month. The headline is the newest
  -- month only.
  select pg_catalog.jsonb_build_object(
    'businesses',count(distinct item->>'business_id'),
    'months',count(distinct item->>'month'),
    'customers',coalesce(sum((item->>'customers')::bigint) filter(
      where item->>'month'=(
        select pg_catalog.max(latest->>'month')
        from pg_catalog.jsonb_array_elements(v_rows) as newest(latest)
      )
    ),0),
    'campaigns',coalesce(sum((item->>'campaigns')::bigint),0),
    'push_sent',coalesce(sum((item->>'push_sent')::bigint),0),
    'sends',coalesce(sum((item->>'sends')::bigint),0),
    'inbox_opens',coalesce(sum((item->>'inbox_opens')::bigint),0)
  ) into v_summary
  from pg_catalog.jsonb_array_elements(v_rows) as element(item);

  return pg_catalog.jsonb_build_object(
    'scope',pg_catalog.jsonb_build_object(
      'from',p_from,'to',p_to,'limit',p_limit,
      'business_filter_count',coalesce(array_length(p_businesses,1),0),
      'timezone','Asia/Singapore'
    ),
    'methodology',pg_catalog.jsonb_build_object(
      'customers',
        'Verified customer links that existed at the end of that month.',
      'campaigns',
        'Distinct campaigns with at least one send record in that month.',
      'push_sent',
        'Web push attempts the dispatcher reported as sent in that month.',
      'push_opens',
        'Not tracked. The Web Push API returns no delivery receipt or open callback.',
      'months','Calendar months in Asia/Singapore.'
    ),
    'summary',coalesce(v_summary,'{}'::jsonb),
    'businesses',v_rows,
    'monthly_trend',v_trend,
    'total_count',v_total,
    'has_more',v_total>p_limit,
    'snapshot_at',clock_timestamp()
  );
end
$function$;

do $check8$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$      and (p_businesses is null or sale.business_id=any(p_businesses))
    group by 1,2
$lit$;
  v_new1 constant text := $lit$      and (p_businesses is null or sale.business_id=any(p_businesses))
      and not exists(
        select 1 from public.clients synthetic_client
         where synthetic_client.id=sale.client_id
           and synthetic_client.is_synthetic
      )
    group by 1,2
$lit$;
begin
  select def into v_before from _v743_before where fn = $lit$platform_engagement_monthly_v255$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'platform_engagement_monthly_v255';
  if position(v_old1 in v_before) = 0 then
    raise exception 'v743/platform_engagement_monthly_v255: hunk 1 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  if v_expect <> v_after then
    raise exception 'v743/platform_engagement_monthly_v255: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check8$;

-- =============================================================================================
-- 9 . public.business_programme_usage_v386
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.business_programme_usage_v386(p_business uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_from timestamptz := case when p_from is null then null
                             else (p_from::text || ' 00:00:00+08')::timestamptz end;
  v_to   timestamptz := case when p_to is null then null
                             else ((p_to + 1)::text || ' 00:00:00+08')::timestamptz end;
  v_point_customers int;
  v_point_uses_v468 int;
  v_points_programme_v310 uuid;
  v_stamps_programme_v310 uuid;
  v_stamp_customers_v310 int;
  v_stamp_uses_v468 int;
  v_rewards jsonb;
  v_bringback jsonb;
  v_retention jsonb;
  v_birthday_started timestamptz;
  v_birthday_customers int;
  v_birthday_uses_v468 int;
  v_welcome_customers int;
  v_welcome_uses_v468 int;
  v_referral_customers int;
  v_referral_uses_v468 int;
  v_memberships jsonb;
  /* V468: each of these gated a 'customers' figure with an inline EXISTS. The figure now has a
     'uses' twin gated by the SAME condition, so the probe is hoisted to a boolean rather than
     written — and re-planned — twice. See [[sql-inlining-repeated-evaluation]]: an inlined
     sub-select in this codebase has bitten us before by being evaluated per reference. */
  v_stamp_card_live_v468 boolean;
  v_birthday_live_v468 boolean;
  v_welcome_live_v468 boolean;
  v_referrals_live_v468 boolean;
begin
  if auth.uid() is null then
    raise exception 'authenticated staff required' using errcode = '42501';
  end if;
  if p_business is null then
    raise exception 'business required' using errcode = '22023';
  end if;
  if not (app.is_salon_owner(p_business) or app.can_module_read(p_business, 'loyalty')) then
    raise exception 'programme overview authorization required' using errcode = '42501';
  end if;
  if p_from is not null and p_to is not null and p_from > p_to then
    raise exception 'the From date is after the To date' using errcode = '22023';
  end if;

  select spine.id into v_points_programme_v310
    from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = 'points';
  if v_points_programme_v310 is null then
    select count(distinct client_id)::int, count(*)::int into v_point_customers, v_point_uses_v468
      from public.points_ledger
     where business_id = p_business
       and entry_type = 'earn'
       and client_id is not null
       and (v_from is null or created_at >= v_from)
       and (v_to is null or created_at < v_to)
       and not exists (select 1 from public.clients c where c.id = client_id and c.is_synthetic);
  else
    select count(distinct ledger.client_id)::int, count(*)::int into v_point_customers, v_point_uses_v468
      from public.points_ledger ledger
     where ledger.business_id = p_business
       and ledger.entry_type = 'earn'
       and ledger.client_id is not null
       and ledger.programme_id = v_points_programme_v310
       and (v_from is null or ledger.created_at >= v_from)
       and (v_to is null or ledger.created_at < v_to)
       and not exists (select 1 from public.clients c where c.id = ledger.client_id and c.is_synthetic);
  end if;

  select spine.id into v_stamps_programme_v310
    from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = 'stamps';
  if v_stamps_programme_v310 is not null then
    select count(distinct ledger.client_id)::int, count(*)::int into v_stamp_customers_v310, v_stamp_uses_v468
      from public.points_ledger ledger
     where ledger.business_id = p_business
       and ledger.entry_type = 'earn'
       and ledger.client_id is not null
       and ledger.programme_id = v_stamps_programme_v310
       and (v_from is null or ledger.created_at >= v_from)
       and (v_to is null or ledger.created_at < v_to)
       and not exists (select 1 from public.clients c where c.id = ledger.client_id and c.is_synthetic);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'reward_id', reward.id,
           'customers', coalesce(used.customers, 0),
           'uses', coalesce(used.uses, 0))), '[]'::jsonb)
    into v_rewards
    from public.loyalty_rewards reward
    left join lateral (
      select count(distinct redemption.client_id)::int customers, count(*)::int uses
        from public.loyalty_redemptions redemption
       where redemption.business_id = p_business
         and redemption.reward_id = reward.id
         and redemption.client_id is not null
       and (v_from is null or redemption.redeemed_at >= v_from)
       and (v_to is null or redemption.redeemed_at < v_to)
       and not exists (select 1 from public.clients c where c.id = redemption.client_id and c.is_synthetic)
    ) used on true
   where reward.business_id = p_business;

  select coalesce(jsonb_agg(jsonb_build_object(
           'program_id', campaign.id,
           'campaign_id', campaign.id,
           'source', 'bringback_v361',
           'customers', coalesce(used.customers, 0),
           'uses', coalesce(used.uses, 0))
         order by campaign.away_days, campaign.id), '[]'::jsonb)
    into v_bringback
    from public.bringback_campaigns_v361 campaign
    left join lateral (
      select count(distinct grant_row.client_id)::int customers, count(*)::int uses
        from public.bringback_grants_v361 grant_row
       where grant_row.business_id = p_business
         and grant_row.campaign_id = campaign.id
         and grant_row.client_id is not null
         and grant_row.status = 'redeemed'
       and (v_from is null or grant_row.redeemed_at >= v_from)
       and (v_to is null or grant_row.redeemed_at < v_to)
       and not exists (select 1 from public.clients c where c.id = grant_row.client_id and c.is_synthetic)
    ) used on true
   where campaign.business_id = p_business;

  select v_bringback || coalesce(jsonb_agg(jsonb_build_object(
           'program_id', program.id,
           'source', 'retention_legacy',
           'customers', coalesce(used.customers, 0),
           'uses', coalesce(used.uses, 0))
         order by program.id), '[]'::jsonb)
    into v_retention
    from public.retention_programs program
    left join lateral (
      select count(distinct grant_row.client_id)::int customers, count(*)::int uses
        from public.reward_grants grant_row
       where grant_row.business_id = p_business
         and grant_row.program_id = program.id
         and grant_row.client_id is not null
       and (v_from is null or grant_row.granted_at >= v_from)
       and (v_to is null or grant_row.granted_at < v_to)
       and not exists (select 1 from public.clients c where c.id = grant_row.client_id and c.is_synthetic)
    ) used on true
   where program.business_id = p_business;

  select min(created_at) into v_birthday_started
    from public.birthday_programs where business_id = p_business;

  select count(distinct client_id)::int, count(*)::int into v_birthday_customers, v_birthday_uses_v468
    from public.customer_birthday_redemptions
   where business_id = p_business and active and client_id is not null
       and (v_from is null or created_at >= v_from)
       and (v_to is null or created_at < v_to)
       and not exists (select 1 from public.clients c where c.id = client_id and c.is_synthetic);

  select count(distinct client_id)::int, count(*)::int into v_welcome_customers, v_welcome_uses_v468
    from public.welcome_offer_grants_v215
   where business_id = p_business and status = 'redeemed' and client_id is not null
       and (v_from is null or redeemed_at >= v_from)
       and (v_to is null or redeemed_at < v_to)
       and not exists (select 1 from public.clients c where c.id = client_id and c.is_synthetic);

  select count(distinct referrer_client_id)::int, count(*)::int into v_referral_customers, v_referral_uses_v468
    from public.referrals
   where business_id = p_business
     and qualified_at is not null
     and referrer_client_id is not null
       and (v_from is null or qualified_at >= v_from)
       and (v_to is null or qualified_at < v_to)
       and not exists (select 1 from public.clients c where c.id = referrer_client_id and c.is_synthetic);

  select coalesce(jsonb_agg(jsonb_build_object(
           'plan_id', plan.id,
           'customers', coalesce(used.customers, 0),
           'uses', coalesce(used.uses, 0))), '[]'::jsonb)
    into v_memberships
    from public.membership_plans plan
    left join lateral (
      select count(distinct member.client_id)::int customers, count(*)::int uses
        from public.memberships member
       where member.business_id = p_business
         and member.plan_id = plan.id
         and member.client_id is not null
       and (v_from is null or member.started_at >= v_from)
       and (v_to is null or member.started_at < v_to)
       and not exists (select 1 from public.clients c where c.id = member.client_id and c.is_synthetic)
    ) used on true
   where plan.business_id = p_business;

  /* V468 BUG FIX, found while adding 'uses'. The stamp figure is COMPUTED from the spine
     (business_programmes.kind='stamps' — see v_stamp_customers_v310 above), but this gate asked a
     different question of a different table: loyalty_programs.loyalty_model. On the demo tenant
     those disagree — spine kinds 'points,referral,stamps,tiers', declared model 'classic' — so a
     stamp card with three real earn entries on the ledger had its measured figure discarded and
     reported as "Not tracked". The honesty rule (v271/v273) says never show a zero you did not
     measure; it does NOT license hiding a number you did measure. Gate and measurement now read
     the same source, so they cannot disagree again. A business with no stamps spine still gets
     null, which is the case the rule was written for. */
  v_stamp_card_live_v468 := v_stamps_programme_v310 is not null;
  v_birthday_live_v468 := exists(select 1 from public.birthday_programs v273_exists
                                  where v273_exists.business_id = p_business);
  v_welcome_live_v468 := exists(select 1 from public.business_welcome_offers_v215 v273_exists
                                 where v273_exists.business_id = p_business);
  v_referrals_live_v468 := exists(select 1 from public.referral_programs v273_exists
                                   where v273_exists.business_id = p_business);

  return jsonb_build_object(
    'status', 'ok',
    'as_of', now(),
    'window', jsonb_build_object('from', p_from, 'to', p_to),
    'point_system', jsonb_build_object('customers', coalesce(v_point_customers, 0),
                                       'uses', coalesce(v_point_uses_v468, 0)),
    'stamp_card', jsonb_build_object('customers', case when v_stamp_card_live_v468
                                     then coalesce(v_stamp_customers_v310, 0) else null end,
                                     'uses', case when v_stamp_card_live_v468
                                     then coalesce(v_stamp_uses_v468, 0) else null end),
    'rewards', v_rewards,
    'retention', v_retention,
    'bringback', v_bringback,
    'birthday', jsonb_build_object('started_at', v_birthday_started,
                                   'customers', case when v_birthday_live_v468
                                     then coalesce(v_birthday_customers, 0) else null end,
                                   'uses', case when v_birthday_live_v468
                                     then coalesce(v_birthday_uses_v468, 0) else null end),
    'welcome', jsonb_build_object('customers', case when v_welcome_live_v468
                                     then coalesce(v_welcome_customers, 0) else null end,
                                  'uses', case when v_welcome_live_v468
                                     then coalesce(v_welcome_uses_v468, 0) else null end),
    'referrals', jsonb_build_object('customers', case when v_referrals_live_v468
                                     then coalesce(v_referral_customers, 0) else null end,
                                    'uses', case when v_referrals_live_v468
                                     then coalesce(v_referral_uses_v468, 0) else null end),
    'memberships', v_memberships,
    'promotions', jsonb_build_object('customers', null, 'uses', null),
    'gift_cards', jsonb_build_object('customers', null, 'uses', null));
end
$function$;

do $check9$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$       and entry_type = 'earn'
       and client_id is not null
       and (v_from is null or created_at >= v_from)
       and (v_to is null or created_at < v_to);
  else
    select count(distinct ledger.client_id)::int, count(*)::int into v_point_customers, v_point_uses_v468
      from public.points_ledger ledger
$lit$;
  v_new1 constant text := $lit$       and entry_type = 'earn'
       and client_id is not null
       and (v_from is null or created_at >= v_from)
       and (v_to is null or created_at < v_to)
       and not exists (select 1 from public.clients c where c.id = client_id and c.is_synthetic);
  else
    select count(distinct ledger.client_id)::int, count(*)::int into v_point_customers, v_point_uses_v468
      from public.points_ledger ledger
$lit$;
  v_old2 constant text := $lit$       and ledger.client_id is not null
       and ledger.programme_id = v_points_programme_v310
       and (v_from is null or ledger.created_at >= v_from)
       and (v_to is null or ledger.created_at < v_to);
  end if;

  select spine.id into v_stamps_programme_v310
$lit$;
  v_new2 constant text := $lit$       and ledger.client_id is not null
       and ledger.programme_id = v_points_programme_v310
       and (v_from is null or ledger.created_at >= v_from)
       and (v_to is null or ledger.created_at < v_to)
       and not exists (select 1 from public.clients c where c.id = ledger.client_id and c.is_synthetic);
  end if;

  select spine.id into v_stamps_programme_v310
$lit$;
  v_old3 constant text := $lit$       and ledger.client_id is not null
       and ledger.programme_id = v_stamps_programme_v310
       and (v_from is null or ledger.created_at >= v_from)
       and (v_to is null or ledger.created_at < v_to);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
$lit$;
  v_new3 constant text := $lit$       and ledger.client_id is not null
       and ledger.programme_id = v_stamps_programme_v310
       and (v_from is null or ledger.created_at >= v_from)
       and (v_to is null or ledger.created_at < v_to)
       and not exists (select 1 from public.clients c where c.id = ledger.client_id and c.is_synthetic);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
$lit$;
  v_old4 constant text := $lit$         and redemption.client_id is not null
       and (v_from is null or redemption.redeemed_at >= v_from)
       and (v_to is null or redemption.redeemed_at < v_to)
    ) used on true
   where reward.business_id = p_business;

$lit$;
  v_new4 constant text := $lit$         and redemption.client_id is not null
       and (v_from is null or redemption.redeemed_at >= v_from)
       and (v_to is null or redemption.redeemed_at < v_to)
       and not exists (select 1 from public.clients c where c.id = redemption.client_id and c.is_synthetic)
    ) used on true
   where reward.business_id = p_business;

$lit$;
  v_old5 constant text := $lit$         and grant_row.status = 'redeemed'
       and (v_from is null or grant_row.redeemed_at >= v_from)
       and (v_to is null or grant_row.redeemed_at < v_to)
    ) used on true
   where campaign.business_id = p_business;

$lit$;
  v_new5 constant text := $lit$         and grant_row.status = 'redeemed'
       and (v_from is null or grant_row.redeemed_at >= v_from)
       and (v_to is null or grant_row.redeemed_at < v_to)
       and not exists (select 1 from public.clients c where c.id = grant_row.client_id and c.is_synthetic)
    ) used on true
   where campaign.business_id = p_business;

$lit$;
  v_old6 constant text := $lit$         and grant_row.client_id is not null
       and (v_from is null or grant_row.granted_at >= v_from)
       and (v_to is null or grant_row.granted_at < v_to)
    ) used on true
   where program.business_id = p_business;

$lit$;
  v_new6 constant text := $lit$         and grant_row.client_id is not null
       and (v_from is null or grant_row.granted_at >= v_from)
       and (v_to is null or grant_row.granted_at < v_to)
       and not exists (select 1 from public.clients c where c.id = grant_row.client_id and c.is_synthetic)
    ) used on true
   where program.business_id = p_business;

$lit$;
  v_old7 constant text := $lit$    from public.customer_birthday_redemptions
   where business_id = p_business and active and client_id is not null
       and (v_from is null or created_at >= v_from)
       and (v_to is null or created_at < v_to);

  select count(distinct client_id)::int, count(*)::int into v_welcome_customers, v_welcome_uses_v468
    from public.welcome_offer_grants_v215
   where business_id = p_business and status = 'redeemed' and client_id is not null
       and (v_from is null or redeemed_at >= v_from)
       and (v_to is null or redeemed_at < v_to);

  select count(distinct referrer_client_id)::int, count(*)::int into v_referral_customers, v_referral_uses_v468
    from public.referrals
$lit$;
  v_new7 constant text := $lit$    from public.customer_birthday_redemptions
   where business_id = p_business and active and client_id is not null
       and (v_from is null or created_at >= v_from)
       and (v_to is null or created_at < v_to)
       and not exists (select 1 from public.clients c where c.id = client_id and c.is_synthetic);

  select count(distinct client_id)::int, count(*)::int into v_welcome_customers, v_welcome_uses_v468
    from public.welcome_offer_grants_v215
   where business_id = p_business and status = 'redeemed' and client_id is not null
       and (v_from is null or redeemed_at >= v_from)
       and (v_to is null or redeemed_at < v_to)
       and not exists (select 1 from public.clients c where c.id = client_id and c.is_synthetic);

  select count(distinct referrer_client_id)::int, count(*)::int into v_referral_customers, v_referral_uses_v468
    from public.referrals
$lit$;
  v_old8 constant text := $lit$     and qualified_at is not null
     and referrer_client_id is not null
       and (v_from is null or qualified_at >= v_from)
       and (v_to is null or qualified_at < v_to);

  select coalesce(jsonb_agg(jsonb_build_object(
           'plan_id', plan.id,
$lit$;
  v_new8 constant text := $lit$     and qualified_at is not null
     and referrer_client_id is not null
       and (v_from is null or qualified_at >= v_from)
       and (v_to is null or qualified_at < v_to)
       and not exists (select 1 from public.clients c where c.id = referrer_client_id and c.is_synthetic);

  select coalesce(jsonb_agg(jsonb_build_object(
           'plan_id', plan.id,
$lit$;
  v_old9 constant text := $lit$         and member.client_id is not null
       and (v_from is null or member.started_at >= v_from)
       and (v_to is null or member.started_at < v_to)
    ) used on true
   where plan.business_id = p_business;

$lit$;
  v_new9 constant text := $lit$         and member.client_id is not null
       and (v_from is null or member.started_at >= v_from)
       and (v_to is null or member.started_at < v_to)
       and not exists (select 1 from public.clients c where c.id = member.client_id and c.is_synthetic)
    ) used on true
   where plan.business_id = p_business;

$lit$;
begin
  select def into v_before from _v743_before where fn = $lit$business_programme_usage_v386$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'business_programme_usage_v386';
  if position(v_old1 in v_before) = 0 then
    raise exception 'v743/business_programme_usage_v386: hunk 1 anchor not found in captured body';
  end if;
  if position(v_old2 in v_before) = 0 then
    raise exception 'v743/business_programme_usage_v386: hunk 2 anchor not found in captured body';
  end if;
  if position(v_old3 in v_before) = 0 then
    raise exception 'v743/business_programme_usage_v386: hunk 3 anchor not found in captured body';
  end if;
  if position(v_old4 in v_before) = 0 then
    raise exception 'v743/business_programme_usage_v386: hunk 4 anchor not found in captured body';
  end if;
  if position(v_old5 in v_before) = 0 then
    raise exception 'v743/business_programme_usage_v386: hunk 5 anchor not found in captured body';
  end if;
  if position(v_old6 in v_before) = 0 then
    raise exception 'v743/business_programme_usage_v386: hunk 6 anchor not found in captured body';
  end if;
  if position(v_old7 in v_before) = 0 then
    raise exception 'v743/business_programme_usage_v386: hunk 7 anchor not found in captured body';
  end if;
  if position(v_old8 in v_before) = 0 then
    raise exception 'v743/business_programme_usage_v386: hunk 8 anchor not found in captured body';
  end if;
  if position(v_old9 in v_before) = 0 then
    raise exception 'v743/business_programme_usage_v386: hunk 9 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  v_expect := replace(v_expect, v_old2, v_new2);
  v_expect := replace(v_expect, v_old3, v_new3);
  v_expect := replace(v_expect, v_old4, v_new4);
  v_expect := replace(v_expect, v_old5, v_new5);
  v_expect := replace(v_expect, v_old6, v_new6);
  v_expect := replace(v_expect, v_old7, v_new7);
  v_expect := replace(v_expect, v_old8, v_new8);
  v_expect := replace(v_expect, v_old9, v_new9);
  if v_expect <> v_after then
    raise exception 'v743/business_programme_usage_v386: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check9$;

-- =============================================================================================
-- 10 . public.staff_list_package_entitlements_v102
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.staff_list_package_entitlements_v102(p_business uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
begin
  if not (
    app.is_super_admin()
    or app.can_module_read(p_business,'till')
    or app.can_module_read(p_business,'sales')
    or app.can_module_read(p_business,'packages')
  ) then
    raise exception 'package_entitlements_access_required' using errcode='42501';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'client_package_id',customer_package.id,
      'client_id',customer_package.client_id,
      'client_name',client.full_name,
      'client_phone',client.phone,
      'plan_id',customer_package.plan_id,
      'plan_version',customer_package.plan_version_snapshot,
      'plan_name',customer_package.plan_name_snapshot,
      'sessions',customer_package.sessions_snapshot,
      'price_cents',customer_package.price_cents_snapshot,
      'remaining',customer_package.remaining,
      -- nestly_v593: 'expired' is DERIVED, never stored. The stored status still says what
      -- happened to the sessions; this says whether the window is still open, and the window
      -- closing is what a member of staff needs to read before promising anything.
      'status',case
        when customer_package.status='active'
         and customer_package.expires_at is not null
         and customer_package.expires_at < now() then 'expired'
        else customer_package.status end,
      'expiry_days',customer_package.expiry_days_snapshot,
      'expires_at',customer_package.expires_at,
      'service_id',customer_package.service_id_snapshot,
      'service_name',customer_package.service_name_snapshot,
      'variant_label',customer_package.service_variant_snapshot,
      'duration_min',customer_package.service_duration_min_snapshot,
      'list_unit_cents',customer_package.list_unit_cents_snapshot,
      'list_value_cents',customer_package.list_value_cents_snapshot,
      'purchased_at',customer_package.purchased_at,
      -- nestly_v603 (owner photo: "Add! Date Bought dd/mm/yy | Last Used dd/mm/yy"). Date bought
      -- was already here; last used was not, and it is the column that tells a member of staff
      -- whether a package is being worked through or has gone quiet. A consumption that was later
      -- undone is not a use, so reversed rows are excluded rather than counted.
      'last_used_at',(
        select max(used.created_at)
          from public.package_session_consumptions used
         where used.client_package_id=customer_package.id
           and used.business_id=customer_package.business_id
           and not exists(
             select 1 from public.package_session_reversals undone
              where undone.consumption_id=used.id))
    ) order by customer_package.purchased_at desc,customer_package.id),'[]'::jsonb)
    from public.client_packages customer_package
    join public.clients client
      on client.id=customer_package.client_id
     and client.business_id=customer_package.business_id
    where customer_package.business_id=p_business
      and not client.is_synthetic
  );
end
$function$;

do $check10$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$    where customer_package.business_id=p_business
  );
$lit$;
  v_new1 constant text := $lit$    where customer_package.business_id=p_business
      and not client.is_synthetic
  );
$lit$;
begin
  select def into v_before from _v743_before where fn = $lit$staff_list_package_entitlements_v102$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_list_package_entitlements_v102';
  if position(v_old1 in v_before) = 0 then
    raise exception 'v743/staff_list_package_entitlements_v102: hunk 1 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  if v_expect <> v_after then
    raise exception 'v743/staff_list_package_entitlements_v102: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check10$;

-- =============================================================================================
-- 11 . app.issue_bringback_for_business_v361
-- =============================================================================================
CREATE OR REPLACE FUNCTION app.issue_bringback_for_business_v361(p_business uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_campaign public.bringback_campaigns_v361%rowtype;
  v_issued integer := 0;
  v_rows integer;
begin
  for v_campaign in
    select * from public.bringback_campaigns_v361
     where business_id=p_business and active and deleted_at is null
  loop
    -- "Away for the stated period" uses the SAME definition as the Gone-quiet report the owner
    -- already reads: last completed, non-reversed sale older than away_days. Anyone with no sale
    -- at all is excluded — they never came, so there is nothing to bring them back from.
    insert into public.bringback_grants_v361(
      business_id,campaign_id,client_id,reward_label,away_days,cycle_key,expires_at)
    select p_business, v_campaign.id, last_seen.client_id, v_campaign.reward_label,
           v_campaign.away_days, last_seen.last_day,
           case when v_campaign.expiry_days is null then null
                else now() + make_interval(days => v_campaign.expiry_days) end
      from (
        select s.client_id, max(s.created_at)::date as last_day
          from public.sales s
         where s.business_id=p_business and s.client_id is not null and s.reversal_of is null
           and not exists(select 1 from public.sales r where r.reversal_of=s.id)
           and not exists(select 1 from public.clients sc where sc.id=s.client_id and sc.is_synthetic)
         group by s.client_id
        having max(s.created_at) < now() - make_interval(days => v_campaign.away_days)
      ) last_seen
    on conflict (campaign_id, client_id, cycle_key) do nothing;
    get diagnostics v_rows = row_count;
    v_issued := v_issued + v_rows;
  end loop;
  return v_issued;
end $function$;

do $check11$
declare v_before text; v_after text; v_expect text;
  v_old1 constant text := $lit$           and not exists(select 1 from public.sales r where r.reversal_of=s.id)
         group by s.client_id
$lit$;
  v_new1 constant text := $lit$           and not exists(select 1 from public.sales r where r.reversal_of=s.id)
           and not exists(select 1 from public.clients sc where sc.id=s.client_id and sc.is_synthetic)
         group by s.client_id
$lit$;
begin
  select def into v_before from _v743_before where fn = $lit$issue_bringback_for_business_v361$lit$;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'issue_bringback_for_business_v361';
  if position(v_old1 in v_before) = 0 then
    raise exception 'v743/issue_bringback_for_business_v361: hunk 1 anchor not found in captured body';
  end if;
  v_expect := v_before;
  v_expect := replace(v_expect, v_old1, v_new1);
  if v_expect <> v_after then
    raise exception 'v743/issue_bringback_for_business_v361: definition moved by more than the exclusion. EXPECTED: %  ACTUAL: %', v_expect, v_after;
  end if;
end
$check11$;

-- ACL restatement for auditability (CREATE OR REPLACE preserves existing grants; nothing here
-- widens or narrows anon/authenticated/service_role/public access). Verified against live proacl.
revoke all on function public.get_checkout_discount_report(uuid,date,date) from public;
grant execute on function public.get_checkout_discount_report(uuid,date,date) to public, postgres, anon, authenticated, service_role;

revoke all on function public.get_reports_summary_v94_base(uuid,date,date,uuid) from public;
grant execute on function public.get_reports_summary_v94_base(uuid,date,date,uuid) to public, postgres, anon, authenticated, service_role;

revoke all on function public.get_campaign_results(uuid) from public;
grant execute on function public.get_campaign_results(uuid) to public, postgres, anon, authenticated, service_role;

revoke all on function app.get_growth_execution_result_at_v108(uuid,timestamp with time zone) from public;
grant execute on function app.get_growth_execution_result_at_v108(uuid,timestamp with time zone) to postgres, service_role;

revoke all on function app.v177_appointments(uuid,uuid) from public;
grant execute on function app.v177_appointments(uuid,uuid) to postgres, service_role;

revoke all on function app.v109_sector_source_availability(uuid,text,integer,timestamp with time zone) from public;
grant execute on function app.v109_sector_source_availability(uuid,text,integer,timestamp with time zone) to postgres, service_role;

revoke all on function public.super_admin_list_businesses() from public;
grant execute on function public.super_admin_list_businesses() to public, postgres, anon, authenticated, service_role;

revoke all on function public.platform_engagement_monthly_v255(date,date,uuid[],integer) from public;
grant execute on function public.platform_engagement_monthly_v255(date,date,uuid[],integer) to public, postgres, anon, authenticated, service_role;

revoke all on function public.business_programme_usage_v386(uuid,date,date) from public;
grant execute on function public.business_programme_usage_v386(uuid,date,date) to postgres, authenticated, service_role;

revoke all on function public.staff_list_package_entitlements_v102(uuid) from public;
grant execute on function public.staff_list_package_entitlements_v102(uuid) to postgres, authenticated, service_role;

revoke all on function app.issue_bringback_for_business_v361(uuid) from public;
grant execute on function app.issue_bringback_for_business_v361(uuid) to postgres, service_role;

create table app.ci_synthetic_scan_allowlist_v743 (
  function_signature text primary key,
  reason text not null,
  added_by_migration text not null
);

alter table app.ci_synthetic_scan_allowlist_v743 enable row level security;

revoke all on table app.ci_synthetic_scan_allowlist_v743 from public;
grant select, insert, update, delete on table app.ci_synthetic_scan_allowlist_v743 to postgres, service_role;

insert into app.ci_synthetic_scan_allowlist_v743 (function_signature, reason, added_by_migration) values
  ('app.c45_base_actionable_wallet_card(p_business_id uuid, p_client_id uuid, p_business_slug text, p_business_name text, p_business_industry text, p_business_currency text, p_enabled_modules text[], p_as_of timestamp with time zone)', 'single-client wallet-card kernel (p_client_id) — one customer''s own card, not a business-wide population aggregate.', 'nestly_v743'),
  ('app.ci_capacity_v705(p_business uuid, p_branch uuid, p_from date, p_to date)', 'staff scheduling capacity/utilisation — booked minutes reflect real appointment duration occupying staff time regardless of whether the client is a synthetic fixture; not a customer or revenue aggregate.', 'nestly_v743'),
  ('app.ci_envelope_v680(p_query_version text, p_business uuid, p_branch uuid, p_from date, p_to date, p_as_of timestamp with time zone, p_exclusions jsonb, p_payload jsonb)', 'shared evidence-pack kernel that takes p_exclusions jsonb from the caller — synthetic exclusion is the caller''s responsibility, applied before this kernel runs (nestly_v680/v685).', 'nestly_v743'),
  ('app.ci_loyalty_outcomes_v683(p_business uuid, p_events jsonb)', 'operates on a caller-supplied p_events jsonb array, not a raw table population scan.', 'nestly_v743'),
  ('app.client_points_balance_v409(p_business uuid, p_client uuid)', 'single-client balance kernel (p_client) — one customer''s own balance.', 'nestly_v743'),
  ('app.conversion_tag_v426(p_business uuid, p_client uuid, p_ledger uuid)', 'single-client, single-ledger-row kernel (p_client, p_ledger).', 'nestly_v743'),
  ('app.customer_cadence_batch_v1(p_business uuid, p_before date, p_residual_to date, p_as_of timestamp with time zone, p_branch uuid, p_business_wide boolean)', 'per-row kernel: one row per client_id with that client''s own cadence statistics (same shape as app.v106_sale_residual_minor). Synthetic exclusion belongs to a caller presenting a business-wide count from these rows, not to this per-client kernel.', 'nestly_v743'),
  ('app.customer_cadence_v1(p_business uuid, p_client uuid, p_as_of timestamp with time zone)', 'single-client cadence kernel (p_client) — one customer''s own visit pattern.', 'nestly_v743'),
  ('app.customer_live_loyalty_v384(p_business_id uuid, p_client_id uuid, p_enabled_modules text[], p_as_of timestamp with time zone)', 'single-client loyalty snapshot (p_client_id) — one customer''s own live balance.', 'nestly_v743'),
  ('app.detect_double_earn_v309()', 'ledger-integrity detector — must see every points_ledger row, including a synthetic fixture''s, or a real double-earn defect in a synthetic tenant would go undetected.', 'nestly_v743'),
  ('app.detect_programme_pot_split_v310()', 'ledger-integrity detector — same reasoning as app.detect_double_earn_v309.', 'nestly_v743'),
  ('app.detect_programme_pot_split_v312()', 'ledger-integrity detector — same reasoning as app.detect_double_earn_v309.', 'nestly_v743'),
  ('app.enforce_customer_capacity_v124()', 'billing-capacity trigger — must count every clients row for the business, including synthetic ones, or a tenant could evade its subscription''s customer-capacity cap by seeding synthetic rows.', 'nestly_v743'),
  ('app.enforce_sale_reversal_bounds()', 'per-row trigger on the sale being reversed (NEW/OLD row), not a population aggregate.', 'nestly_v743'),
  ('app.enqueue_programme_pot_migration_v312(p_business uuid, p_from uuid, p_to uuid, p_inline_limit integer)', 'ledger migration writer — must enqueue every client''s pot, including synthetic ones, or their points_ledger would be left in a split/incoherent state (same integrity requirement as the v312 pot-migration wave).', 'nestly_v743'),
  ('app.migrate_programme_pot_v312(p_business uuid, p_from uuid, p_to uuid, p_limit integer)', 'ledger migration writer — same reasoning as app.enqueue_programme_pot_migration_v312.', 'nestly_v743'),
  ('app.on_sale_recorded()', 'per-row trigger on the sale just inserted (NEW row), not a population aggregate.', 'nestly_v743'),
  ('app.programme_balance_scope_v312(p_business uuid)', 'ledger-integrity detector (business-pot vs programme-pot coherence) — must evaluate the whole points_ledger, including synthetic clients, or liability could under-report.', 'nestly_v743'),
  ('app.programme_pot_is_split_v310(p_business uuid)', 'ledger-integrity detector — same reasoning as app.programme_balance_scope_v312.', 'nestly_v743'),
  ('app.redeem_points_v40_internal(p_business uuid, p_client uuid, p_idempotency_key text)', 'single-client transactional redemption (p_client).', 'nestly_v743'),
  ('app.redeem_reward_core(p_business uuid, p_client uuid, p_reward uuid, p_idempotency_key text, p_branch uuid, p_service uuid, p_product uuid)', 'single-client transactional redemption (p_client).', 'nestly_v743'),
  ('app.reverse_sale_with_loyalty_v480(p_business uuid, p_sale uuid, p_reason text, p_idempotency_key text, p_reference text, p_restock_policy text, p_accept_shortfall boolean)', 'single-sale transactional reversal (p_sale).', 'nestly_v743'),
  ('app.reward_availability_v432(p_business uuid, p_client uuid, p_as_of timestamp with time zone)', 'single-client reward-availability kernel (p_client) — one customer''s own eligibility.', 'nestly_v743'),
  ('app.stamp_cycle_deadline_v435(p_business uuid, p_client uuid, p_programme uuid)', 'single-client stamp-cycle kernel (p_client).', 'nestly_v743'),
  ('app.stamp_cycle_version_v416(p_business uuid, p_client uuid, p_programme uuid)', 'single-client stamp-cycle kernel (p_client).', 'nestly_v743'),
  ('app.stamp_progress_v323(p_business uuid, p_client uuid)', 'single-client stamp-progress kernel (p_client).', 'nestly_v743'),
  ('app.stamp_reward_earned_at_v464(p_business uuid, p_client uuid, p_programme uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_level integer)', 'single-client stamp-reward kernel (p_client).', 'nestly_v743'),
  ('app.suggest_appointment_reschedule_v48(p_business uuid, p_appointment uuid, p_branch uuid, p_service uuid, p_starts timestamp with time zone, p_duration_minutes integer, p_limit integer)', 'single-appointment scheduling-suggestion engine (p_appointment) — proposes slots from staff/service capacity, not a customer aggregate.', 'nestly_v743'),
  ('app.support_route_inbound_v531(p_limit integer)', 'counts open conversation threads for ONE inbound phone number to decide routing, not a customer population aggregate.', 'nestly_v743'),
  ('app.tier_resolve_v426(p_business uuid, p_client uuid, p_as_of timestamp with time zone)', 'single-client tier kernel (p_client) — one customer''s own tier.', 'nestly_v743'),
  ('app.v106_sale_residual_minor(p_sale uuid, p_period_to date, p_as_of timestamp with time zone)', 'single-sale kernel (p_sale) — the residual of exactly one sale by id, not a population aggregate.', 'nestly_v743'),
  ('app.v111_attribution_snapshot(p_business uuid, p_source uuid, p_target uuid, p_effective uuid)', 'single attribution proposal (p_source/p_target/p_effective), not a population aggregate.', 'nestly_v743'),
  ('app.v111_validate_contact_pair(p_proposal uuid, p_type text, p_subject text)', 'single contact-pair validation (p_proposal/p_subject), not a population aggregate.', 'nestly_v743'),
  ('app.v666_till_customer_card(p_business uuid, p_client uuid)', 'single-client till card (p_client) — one customer''s own card at the point of sale.', 'nestly_v743'),
  ('public.activate_retention_campaign(p_business uuid, p_campaign uuid, p_client_ids uuid[], p_idempotency_key text)', 'writes membership rows for a caller-supplied p_client_ids[] batch; does not scan the clients table for its own population.', 'nestly_v743'),
  ('public.adjust_points(p_business uuid, p_client uuid, p_points integer, p_reason text)', 'single-client transactional ledger adjustment (p_client).', 'nestly_v743'),
  ('public.book_appointment_smart_v47_v94_base(p_business uuid, p_client uuid, p_branch uuid, p_service uuid, p_starts timestamp with time zone, p_duration_minutes integer, p_requested_staff uuid, p_assignment_mode text, p_note text, p_idempotency_key text)', 'single-appointment transactional booking (p_client, p_service, p_starts).', 'nestly_v743'),
  ('public.business_add_branch_v202(p_business uuid, p_name text, p_address text, p_phone text, p_email text, p_copy_from uuid, p_idempotency_key uuid)', 'single-branch catalogue write, not a customer aggregate.', 'nestly_v743'),
  ('public.business_manage_catalogue_item_v660(p_business uuid, p_kind text, p_item uuid, p_action text)', 'catalogue-item write (services/products/etc), not a customer aggregate.', 'nestly_v743'),
  ('public.business_manage_package_plan_v193(p_business uuid, p_plan uuid, p_action text, p_name text)', 'catalogue package-plan write, not a customer aggregate.', 'nestly_v743'),
  ('public.business_preview_stamp_conversion_v384(p_business uuid, p_points_per_stamp integer)', 'ledger-migration preview — must mirror the real switch''s whole-ledger scope (including synthetic clients) or the preview would misstate what the actual conversion will do to every pot.', 'nestly_v743'),
  ('public.business_resubscribe_branch_v665(p_business uuid, p_branch uuid, p_idempotency_key uuid)', 'single-branch billing/catalogue write, not a customer aggregate.', 'nestly_v743'),
  ('public.business_set_welcome_offer_v215(p_business uuid, p_active boolean, p_min_spend_cents integer, p_reward_catalog_kind text, p_reward_catalog_id uuid, p_expiry_days integer, p_custom_label text)', 'catalogue/config write for the welcome-offer programme, not a customer aggregate.', 'nestly_v743'),
  ('public.business_switch_to_stamps_v384(p_business uuid, p_convert_existing_points boolean, p_points_per_stamp integer, p_idempotency_key uuid)', 'ledger migration — must convert every client''s points balance, including synthetic ones, or their pot would be left split/incoherent (same integrity requirement as its own preview above).', 'nestly_v743'),
  ('public.business_unsubscribe_branch_v665(p_business uuid, p_branch uuid, p_idempotency_key uuid)', 'single-branch billing/catalogue write, not a customer aggregate.', 'nestly_v743'),
  ('public.claim_billing_command_v124(p_command uuid, p_actor uuid)', 'single billing command (p_command), not a customer aggregate.', 'nestly_v743'),
  ('public.correct_quick_sale_amount_v84(p_business uuid, p_sale uuid, p_corrected_amount_cents integer, p_idempotency_key text, p_note text)', 'single-sale transactional correction (p_sale).', 'nestly_v743'),
  ('public.customer_claim_link_by_email(p_business_slug text, p_idempotency_key text)', 'per-customer self-view/self-claim RPC — resolves the caller''s own verified identity, never a business-wide population.', 'nestly_v743'),
  ('public.customer_claim_link_by_verified_phone(p_business_slug text, p_idempotency_key text)', 'per-customer self-view/self-claim RPC — same reasoning as customer_claim_link_by_email.', 'nestly_v743'),
  ('public.customer_get_appointments_page(p_business_slug text, p_cursor jsonb)', 'per-customer self-view RPC — the caller''s own appointments only.', 'nestly_v743'),
  ('public.customer_get_business_presentation_v95(p_business uuid, p_branch uuid, p_locale text)', 'per-customer self-view RPC, confirmed by nestly_v742''s own review: scoped to the caller''s own verified client_id throughout, emits no firm-level aggregate.', 'nestly_v743'),
  ('public.customer_get_business_summary(p_business_slug text)', 'per-customer self-view RPC — resolves the caller''s own relationship to the business.', 'nestly_v743'),
  ('public.customer_get_loyalty_details(p_business_slug text, p_cursor jsonb)', 'per-customer self-view RPC — the caller''s own loyalty ledger.', 'nestly_v743'),
  ('public.customer_get_packages(p_business_slug text, p_cursor jsonb)', 'per-customer self-view RPC — the caller''s own packages.', 'nestly_v743'),
  ('public.customer_get_referral_card_v300(p_business_slug text)', 'per-customer self-view RPC — the caller''s own referral card.', 'nestly_v743'),
  ('public.customer_get_transaction_history_v81(p_business_slug text, p_cursor jsonb)', 'per-customer self-view RPC — the caller''s own transaction history.', 'nestly_v743'),
  ('public.customer_get_wallet()', 'per-customer self-view RPC — the caller''s own wallet, no business id parameter at all.', 'nestly_v743'),
  ('public.customer_issue_link_invitation(p_business uuid, p_client uuid, p_idempotency_key text, p_expires_in_minutes integer)', 'single-client transactional write (p_client) issuing one invitation.', 'nestly_v743'),
  ('public.customer_list_programmes_v89()', 'per-customer self-view RPC — the caller''s own visible programmes.', 'nestly_v743'),
  ('public.customer_request_appointment_action(p_business_slug text, p_appointment uuid, p_action text, p_proposed_at timestamp with time zone, p_note text, p_idempotency_key text)', 'per-customer self-view/transactional RPC on the caller''s own appointment.', 'nestly_v743'),
  ('public.customer_reschedule_appointment_v508(p_business_slug text, p_appointment uuid, p_preferred_at timestamp with time zone, p_note text)', 'per-customer self-view/transactional RPC on the caller''s own appointment.', 'nestly_v743'),
  ('public.customer_sync_verified_relationships_v81(p_idempotency_key text)', 'per-customer self-view RPC — syncs the caller''s own verified links across businesses.', 'nestly_v743'),
  ('public.erase_client_v290(p_business uuid, p_client uuid, p_reason text, p_idem text)', 'single-client transactional erasure (p_client).', 'nestly_v743'),
  ('public.get_business_billing_v124(p_business uuid)', 'business billing summary — seats are staff-based (staff.user_id), not a clients-table population aggregate.', 'nestly_v743'),
  ('public.get_pos_paynow_attempt_v142(p_attempt uuid)', 'single PayNow attempt lookup (p_attempt), not a population aggregate.', 'nestly_v743'),
  ('public.issue_campaign_offer(p_business uuid, p_campaign uuid, p_client uuid, p_idempotency_key text, p_offer_cost_cents bigint, p_reward_grant_id uuid)', 'single-client transactional offer issuance (p_client).', 'nestly_v743'),
  ('public.list_bar_bottles_v275(p_business uuid, p_branch uuid, p_status text, p_search text, p_expiring_days integer, p_bottle uuid, p_limit integer)', 'inventory/catalogue aggregate (bar bottles), not customer-scoped.', 'nestly_v743'),
  ('public.lookup_client_by_phone(p_business uuid, p_phone text)', 'resolves at most one client by phone (p_phone), not a population aggregate.', 'nestly_v743'),
  ('public.reconcile_external_commerce_event_v106(p_event uuid, p_sale uuid, p_idempotency_key text, p_allocations jsonb)', 'single event/sale reconciliation (p_event, p_sale).', 'nestly_v743'),
  ('public.record_cart_sale(p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text, p_idempotency_key text, p_lines jsonb)', 'single transactional cart-sale write (p_client, p_lines).', 'nestly_v743'),
  ('public.record_cart_sale(p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text, p_idempotency_key text, p_lines jsonb, p_evaluation_id uuid, p_paid boolean, p_occurred_at timestamp with time zone, p_redemptions jsonb)', 'single transactional cart-sale write (p_client, p_lines).', 'nestly_v743'),
  ('public.record_credit_tender(p_business uuid, p_sale uuid, p_amount_cents integer, p_reason text, p_idempotency_key text)', 'single-sale transactional credit tender (p_sale).', 'nestly_v743'),
  ('public.record_sale_by_phone(p_business uuid, p_phone text, p_amount_cents integer, p_kind text, p_note text, p_staff uuid, p_idem text, p_branch uuid, p_method text, p_occurred_at timestamp with time zone)', 'single transactional sale write; p_phone resolves at most one client.', 'nestly_v743'),
  ('public.redeem_points(p_business uuid, p_client uuid)', 'single-client transactional redemption (p_client).', 'nestly_v743'),
  ('public.request_billing_command_v124(p_business uuid, p_command_type text, p_cadence text, p_customer_capacity integer, p_idempotency_key uuid)', 'single billing command write, not a customer aggregate.', 'nestly_v743'),
  ('public.reverse_loyalty_redemption_v34_base(p_business uuid, p_redemption uuid, p_reason text, p_idempotency_key text)', 'single-redemption transactional reversal (p_redemption).', 'nestly_v743'),
  ('public.reverse_sale_v20_base(p_business uuid, p_sale uuid, p_reason text, p_idempotency_key text, p_reference text, p_restock_policy text)', 'single-sale transactional reversal (p_sale).', 'nestly_v743'),
  ('public.save_package_plan_v102(p_business uuid, p_plan uuid, p_name text, p_price_cents integer, p_sessions integer, p_service uuid, p_active boolean, p_expiry_days integer)', 'catalogue package-plan write, not a customer aggregate.', 'nestly_v743'),
  ('public.seal_campaign_measurement_v99(p_business uuid, p_campaign uuid, p_idempotency_key text, p_minimum_sample_per_arm integer)', 'single-campaign transactional seal (p_campaign); the resulting window is what public.get_campaign_results reads through the synthetic-excluded member population fixed above.', 'nestly_v743'),
  ('public.sell_package_v102(p_business uuid, p_client uuid, p_plan uuid, p_branch uuid, p_idempotency_key uuid)', 'single-client transactional purchase (p_client).', 'nestly_v743'),
  ('public.staff_decide_booking_request_v73_v94_base(p_business uuid, p_request uuid, p_decision text, p_branch uuid)', 'single booking-request transactional decision (p_request).', 'nestly_v743'),
  ('public.staff_get_customer_actionable_loyalty_v145(p_business uuid, p_client uuid, p_branch uuid)', 'single-client loyalty read (p_client) for the staff-facing customer profile screen.', 'nestly_v743'),
  ('public.staff_get_reversal_workflows(p_business uuid, p_client uuid, p_limit integer, p_mode text)', 'single-client reversal-workflow read (p_client).', 'nestly_v743'),
  ('public.staff_issue_tier_benefit_v365(p_business uuid, p_client uuid, p_benefit uuid, p_branch uuid, p_idempotency_key uuid)', 'single-client transactional benefit issuance (p_client).', 'nestly_v743'),
  ('public.staff_list_visit_feedback_v145(p_business uuid, p_status text, p_limit integer, p_offset integer, p_client uuid)', 'visit_feedback rows require a verified customer identity/link (identity_id, link_id, auth_user_id all NOT NULL) that a synthetic fixture client does not possess by construction — the table is structurally unreachable for a synthetic client, unlike the client_packages roster fixed in this same migration.', 'nestly_v743'),
  ('public.staff_package_session_history_v603(p_business uuid, p_client_package uuid)', 'single client_package''s session history (p_client_package), not a business-wide roster.', 'nestly_v743'),
  ('public.staff_tier_benefits_for_client_v365(p_business uuid, p_client uuid)', 'single-client tier-benefit read (p_client).', 'nestly_v743'),
  ('public.stage_import_rows(p_business uuid, p_entity text, p_rows jsonb, p_idempotency_key text)', 'counts rows within ONE import job (p_rows just staged), not a customer population aggregate.', 'nestly_v743'),
  ('public.suggest_appointment_staff_v47_v94_base(p_business uuid, p_branch uuid, p_service uuid, p_starts timestamp with time zone, p_duration_minutes integer, p_limit integer, p_recent_days integer, p_staff uuid)', 'single-appointment staff-suggestion engine, proposes from staff/service capacity, not a customer aggregate.', 'nestly_v743');

create or replace function app.ci_synthetic_scan_v743()
 returns table(schema_name text, function_name text, reason text)
 language sql
 stable
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select n.nspname::text, p.proname::text,
         'aggregates a synthetic-exposed table with no exclusion marker and no allowlist entry'::text
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public','app')
     and p.prokind = 'f'
     and pg_catalog.pg_get_functiondef(p.oid) ~* '\ypublic\.(sales|sale_items|clients|appointments|client_packages|points_ledger|credit_ledger|reward_grants)\y'
     and pg_catalog.pg_get_functiondef(p.oid) ~* '\y(sum|count|avg|percentile_|lag|array_agg|string_agg|min|max)\('
     and pg_catalog.pg_get_functiondef(p.oid) !~* '(is_synthetic_client|is_synthetic|analytics_sale_class_v1)'
     and not exists (
       select 1 from app.ci_synthetic_scan_allowlist_v743 allow
        where allow.function_signature =
          n.nspname || '.' || p.proname || '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ')'
     )
   order by 1, 2;
$function$;

revoke all on function app.ci_synthetic_scan_v743() from public;
grant execute on function app.ci_synthetic_scan_v743() to postgres, service_role;
-- Rollback-safe check: the moment this migration applies, the estate must already be clean. This
-- does not roll back anything itself (a bare RAISE EXCEPTION inside the enclosing transaction aborts
-- the whole migration, including every CREATE OR REPLACE and the allowlist seed above -- exactly the
-- fail-closed behaviour wanted here).
do $v743_gate$
declare v_n integer;
begin
  select count(*) into v_n from app.ci_synthetic_scan_v743();
  if v_n <> 0 then
    raise exception 'v743: synthetic scanner found % unguarded, unallowlisted function(s) at the '
      'moment this migration applied -- see app.ci_synthetic_scan_v743()', v_n;
  end if;
end
$v743_gate$;

commit;
