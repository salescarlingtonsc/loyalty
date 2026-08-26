-- nestly_v545 — the AI and the superadmin mirror stop being told points+stamps as one number.
--
-- WHAT WAS WRONG, measured read-only on production 2026-08-26.
-- app.v179_business_insights builds the `loyalty` block of the evidence pack that
-- supabase/functions/ai-firm-reports sends to Claude, and app.v177_overview builds the same shape
-- for the superadmin workspace mirror. Both summed public.points_ledger across EVERY programme pot:
--
--   Cubbly SPA, monthly 2026-08:
--     points_outstanding_total handed to the model   3155
--     live pot (points, active)                      2341
--     dormant pot (stamps, active=false)              814
--
-- 3155 = 2341 points + 814 STAMPS. The model was told a single figure that adds two incompatible
-- units, and the report would state it to the owner as their outstanding liability — overstated
-- 34.8% by a pot in a different unit that nobody can spend. Same defect family as the historical
-- 855-vs-758 incident and as nestly_v544's customer-facing reader.
--
-- The aggravating detail, and the reason a rename would not have been enough:
--
--     'points_outstanding_by_programme_tag', case
--       when app.programme_pot_is_split_v310(p_business) then null    -- <-- withholds the breakdown
--       else <the breakdown> end                                      --     exactly when it matters
--
-- When the pots ARE split — the only case where the total is dangerous — the breakdown that would
-- have revealed the mix was replaced with null, leaving the combined total as the sole figure. The
-- logic is precisely inverted. Both functions carried it.
--
-- Earned and redeemed were unscoped too: `points_window` summed every pot, so Cubbly's
-- points_earned_this_period read 4893 where the pot-scoped figure get_dashboard_summary_v155
-- reports for the same window is 4840.
--
-- WHAT THIS DOES. Both functions now emit a programme-aware shape:
--
--   loyalty.active_programme = { programme_id, unit, is_running, outstanding,
--                                earned_this_period, redeemed_this_period, redemption_rate_pct }
--   loyalty.historical_programmes = [ { unit, outstanding }, ... ]   -- never summed, never merged
--   loyalty.unit_rule = the sentence the model must obey
--
-- `points_outstanding_total` is REMOVED rather than renamed. A cross-programme total is not a
-- quantity: adding 2341 points to 814 stamps produces a number with no unit and no meaning, and any
-- field carrying it invites the model to quote it. There is deliberately no total anywhere in the
-- new shape. The historical pots are still exposed, each with its own unit, because a report may
-- legitimately say "814 stamps remain from the programme you stopped" — it may never say 3155.
--
-- The breakdown is now unconditional: split pots get MORE detail, not less.
--
-- WHAT IS NOT CHANGED.
--   * The evidence pack's other blocks. The anonymous-sales exclusion inside the insights CTE
--     (measured: Kaya Toast headline 23 visits / 660150 against a weekday partition of 22 / 659650)
--     is a separate defect with its own decision to make, and is not touched here.
--   * app.programme_pot_is_split_v310 keeps its callers; only the inverted branch goes.
--   * No unit conversion is introduced anywhere. There is none to introduce.
--
-- CONSUMER IMPACT. The only consumers are the ai-firm-reports edge function (whose system prompt
-- ships alongside this migration, gaining a rule that forbids combining units) and the superadmin
-- mirror in app/platform-console.js. Both are read-only presentations; no stored report is
-- rewritten, and the two already-generated production reports keep their narrative text.
--
-- ROLLBACK: db/tests/v545_programme_aware_loyalty_evidence.sql

begin;

do $patch$
declare d text; n text; v_changed integer := 0;
begin
  -- ============================================================ app.v179_business_insights
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='app' and p.proname='v179_business_insights';
  if d is null then raise exception 'v545: app.v179_business_insights is missing'; end if;

  if position('active_programme' in d) > 0 then
    raise notice 'v545: v179 is already programme-aware';
  else
    -- 1. the earn/redeem window follows the live pot
    n := replace(d,
E'    from public.points_ledger, bounds
    where business_id = p_business
      and created_at >= bounds.from_ts and created_at < bounds.to_ts',
E'    from public.points_ledger, bounds
    where business_id = p_business
      -- v545: earn and redeem belong to ONE pot. Unscoped, Cubbly read 4893 where the
      -- pot-scoped figure every other surface reports for the same window is 4840.
      and programme_id is not distinct from app.live_balance_programme_v381(p_business)
      and created_at >= bounds.from_ts and created_at < bounds.to_ts');
    if n = d then raise exception 'v545: v179 points_window anchor not found'; end if;
    d := n;

    -- 2. the loyalty block becomes programme-aware, and loses its cross-unit total
    n := replace(d,
E'    ''loyalty'', pg_catalog.jsonb_build_object(
      ''points_earned_this_period'', (select earned from points_window),
      ''points_redeemed_this_period'', (select redeemed from points_window),
      ''redemption_rate_pct'', (
        select case when earned = 0 then null
          else round(100.0 * redeemed / earned, 1) end from points_window
      ),
      ''points_outstanding_total'', coalesce((
        select sum(points) from public.points_ledger where business_id = p_business
      ), 0),
      ''pot_is_split'', app.programme_pot_is_split_v310(p_business),
      ''by_programme_note'',
        ''ledger tag provenance, not a spendable pot (V309 currentness gap)'',
      ''points_outstanding_by_programme_tag'', case
        when app.programme_pot_is_split_v310(p_business) then null
        else coalesce((
          select pg_catalog.jsonb_agg(
                   pg_catalog.jsonb_build_object(''kind'', spine.kind, ''points'', tag.points)
                   order by spine.sort)
            from (
              select entry.programme_id, sum(entry.points) as points
                from public.points_ledger entry
               where entry.business_id = p_business
               group by entry.programme_id
            ) tag
            join public.business_programmes spine on spine.id = tag.programme_id
        ), ''[]''::jsonb) end
    )',
E'    /* v545: one programme per figure, every figure carrying its unit. There is deliberately no
       total: adding points to stamps produces a number with no unit, and a field holding it is an
       invitation to quote it. Split pots now get MORE detail, not less - the old shape withheld
       the breakdown precisely when the pots were split. */
    ''loyalty'', pg_catalog.jsonb_build_object(
      ''active_programme'', pg_catalog.jsonb_build_object(
        ''programme_id'', app.live_balance_programme_v381(p_business),
        ''unit'', (select spine.kind from public.business_programmes spine
                    where spine.id = app.live_balance_programme_v381(p_business)),
        ''is_running'', app.live_balance_programme_v381(p_business) is not null,
        ''outstanding'', case when app.live_balance_programme_v381(p_business) is null then null
          else coalesce((select sum(entry.points) from public.points_ledger entry
                          where entry.business_id = p_business
                            and entry.programme_id = app.live_balance_programme_v381(p_business)), 0)
          end,
        ''earned_this_period'', (select earned from points_window),
        ''redeemed_this_period'', (select redeemed from points_window),
        ''redemption_rate_pct'', (
          select case when earned = 0 then null
            else round(100.0 * redeemed / earned, 1) end from points_window
        )
      ),
      ''historical_programmes'', coalesce((
        select pg_catalog.jsonb_agg(
                 pg_catalog.jsonb_build_object(''unit'', spine.kind, ''outstanding'', tag.points)
                 order by spine.sort)
          from (
            select entry.programme_id, sum(entry.points) as points
              from public.points_ledger entry
             where entry.business_id = p_business
               and entry.programme_id is distinct from app.live_balance_programme_v381(p_business)
             group by entry.programme_id
          ) tag
          join public.business_programmes spine on spine.id = tag.programme_id
         where tag.points <> 0
      ), ''[]''::jsonb),
      ''unit_rule'',
        ''Each figure belongs to one programme and carries its unit. Points and stamps are different things: never add them together, never convert between them, and never state a total across programmes.''
    )');
    if n = d then raise exception 'v545: v179 loyalty block anchor not found'; end if;
    execute n;
    v_changed := v_changed + 1;
  end if;

  -- ============================================================ app.v177_overview
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='app' and p.proname='v177_overview';
  if d is null then raise exception 'v545: app.v177_overview is missing'; end if;

  if position('active_programme' in d) > 0 then
    raise notice 'v545: v177 is already programme-aware';
  else
    n := replace(d,
E'    ''outstanding'', jsonb_build_object(
      ''scope'', ''whole_firm'',
      ''points'', coalesce(
        (select sum(entry.points) from public.points_ledger entry
         where entry.business_id = p_business), 0
      ),
      ''pot_is_split'', app.programme_pot_is_split_v310(p_business),
      ''by_programme_note'',
        ''ledger tag provenance, not a spendable pot (V309 currentness gap)'',
      ''points_outstanding_by_programme_tag'', case
        when app.programme_pot_is_split_v310(p_business) then null
        else coalesce((
          select jsonb_agg(jsonb_build_object(''kind'', spine.kind, ''points'', tag.points)
                   order by spine.sort)
            from (
              select entry.programme_id, sum(entry.points) as points
                from public.points_ledger entry
               where entry.business_id = p_business
               group by entry.programme_id
            ) tag
            join public.business_programmes spine on spine.id = tag.programme_id
        ), ''[]''::jsonb) end,',
E'    /* v545: the superadmin mirror carried the same cross-unit total as the AI pack - a firm''s
       loyalty liability read 35% high on Cubbly because a dormant stamps pot was added to a live
       points one. Same shape as v179 now: one programme per figure, each with its unit, no total. */
    ''outstanding'', jsonb_build_object(
      ''scope'', ''whole_firm'',
      ''active_programme'', jsonb_build_object(
        ''programme_id'', app.live_balance_programme_v381(p_business),
        ''unit'', (select spine.kind from public.business_programmes spine
                    where spine.id = app.live_balance_programme_v381(p_business)),
        ''is_running'', app.live_balance_programme_v381(p_business) is not null,
        ''outstanding'', case when app.live_balance_programme_v381(p_business) is null then null
          else coalesce((select sum(entry.points) from public.points_ledger entry
                          where entry.business_id = p_business
                            and entry.programme_id = app.live_balance_programme_v381(p_business)), 0)
          end
      ),
      ''historical_programmes'', coalesce((
        select jsonb_agg(jsonb_build_object(''unit'', spine.kind, ''outstanding'', tag.points)
                 order by spine.sort)
          from (
            select entry.programme_id, sum(entry.points) as points
              from public.points_ledger entry
             where entry.business_id = p_business
               and entry.programme_id is distinct from app.live_balance_programme_v381(p_business)
             group by entry.programme_id
          ) tag
          join public.business_programmes spine on spine.id = tag.programme_id
         where tag.points <> 0
      ), ''[]''::jsonb),
      ''unit_rule'',
        ''Balances in different units are never combined; there is no total across programmes.'',');
    if n = d then raise exception 'v545: v177 outstanding block anchor not found'; end if;
    execute n;
    v_changed := v_changed + 1;
  end if;

  raise notice 'v545: % function(s) made programme-aware', v_changed;
end
$patch$;

-- ============================================================================================
-- PART 2 — the AI report stops calling an existing-customer share a "repeat rate".
--
-- MEASURED, Cubbly SPA. Three computations, three numbers, for the same tenant and month:
--     app.v179_business_insights   repeat_rate_pct                40.0%
--     get_customer_intelligence_v83 returning_rate_pct            60.0%
--     get_dashboard_summary_v155   repeat_customer_percentage     80.0%
--     get_customer_lifecycle_v107  existing_customer_share_pct    40.00%
--                                  repeat_in_period_rate_pct      60.00%
--
-- They are not inconsistent; they are DIFFERENT QUESTIONS wearing one English word. v179's field
-- is `not is_new and visits > 0` over `visits > 0` — the share of this period's customers who had
-- bought BEFORE it. That is v107's existing_customer_share_pct, carrying v155's field name.
--
-- The harm is not the arithmetic, it is the label. QA Kaya Toast, Aug 2026: repeat_rate_pct 0.0
-- while the same pack listed customers with 11 and 10 visits that month. The one production
-- narrative ever generated (ai_firm_reports_v176 522fa492) reads "Repeat rate this month is 0%.
-- All 3 customers served were new" for a month in which a customer visited 15 times, because the
-- system prompt told the model to present this field as "how many customers came back".
--
-- This renames the field to what it computes. NO NUMBER CHANGES — the expressions are untouched.
-- The system prompt shipping with this migration stops calling it a repeat rate.
--
-- WHAT IS NOT DONE HERE, deliberately. The pack still has no repeat-in-period figure. Adding one
-- would mean a THIRD implementation of a concept get_customer_lifecycle_v107 already owns, which
-- is the disease rather than the cure — and v107 cannot simply be called from here, because it
-- guards on auth.uid() and this pack is assembled by the pg_cron/service-role drain where there is
-- no session. Doing it properly means extracting v107's computation into an auth-free core that
-- both call, which is a contained refactor of a 12 KB function and does not belong in a migration
-- about units. Recorded as LIFECYCLE-010. Until then the pack states one true thing rather than
-- one false one.
--
-- ALSO NOT CHANGED: get_dashboard_summary_v155's repeat_customers / repeat_customer_percentage.
-- Grep across app/app.js and every generated chunk finds no render site: the 80% is computed and
-- never shown to anyone. Renaming a field nobody reads would be churn; it is recorded as a dead
-- field (LIFECYCLE-011) instead. Business Insights already labels the two concepts separately and
-- correctly ("Returning customers" and "Repeat purchasing", both from v107), so no owner-facing
-- surface other than the AI report conflates them.
-- ============================================================================================
do $patch$
declare d text; n text;
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='app' and p.proname='v179_business_insights';

  if position('existing_customer_return_rate_pct' in d) > 0 then
    raise notice 'v545: v179 retention labels are already honest';
    return;
  end if;

  n := replace(d,
E'      ''returning_customers'', (select count(*) from window_clients where not is_new and visits > 0),
      ''repeat_rate_pct'', (',
E'      /* v545: this counts customers who had bought BEFORE the window and bought again in it.
         That is an existing-customer return share, not a repeat rate, and the two differ by 20
         points on the same tenant and month. The computation is unchanged; only the name is. */
      ''existing_customers_who_returned'', (select count(*) from window_clients where not is_new and visits > 0),
      ''existing_customer_return_rate_pct'', (');
  if n = d then raise exception 'v545: v179 retention anchor not found'; end if;
  execute n;
  raise notice 'v545: v179 retention field renamed to existing_customer_return_rate_pct';
end
$patch$;

do $verify$
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='app' and p.proname='v179_business_insights'
       and pg_get_functiondef(p.oid) like '%''repeat_rate_pct''%'
  ) then
    raise exception 'v545: the ambiguous repeat_rate_pct label survived';
  end if;
end
$verify$;

/* Neither function may keep a cross-programme total. Fail the migration rather than ship one. */
do $verify$
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='app' and p.proname in ('v179_business_insights','v177_overview')
       and pg_get_functiondef(p.oid) like '%points_outstanding_total%'
  ) then
    raise exception 'v545: a cross-programme points total survived the patch';
  end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='app' and p.proname in ('v179_business_insights','v177_overview')
       and pg_get_functiondef(p.oid) not like '%active_programme%'
  ) then
    raise exception 'v545: a loyalty evidence builder is not programme-aware';
  end if;
end
$verify$;

commit;
