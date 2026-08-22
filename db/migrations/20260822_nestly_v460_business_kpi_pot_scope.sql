-- nestly_v460 — the dashboard's "Points earned" stops adding stamps to points.
--
-- THE DEFECT (audit D finding D-REG-013, measured against production gadpooereceldfpfxsod):
-- public.get_dashboard_summary_v155 and public.get_reports_summary sum public.points_ledger
-- filtered only by business + period + entry_type. Neither names programme_id. So both add up
-- EVERY pot the tenant has ever had: the live one, the retired one, and — because points and
-- stamps live in the same ledger under different programme_id values — TWO DIFFERENT UNITS.
--
-- This is not theoretical and it is not QA-only. Measured across all tenants:
--   Cubbly SPA (kopi-tiam-tyeh)   dashboard "Points earned" 78,308  ·  live pot holds 16
--   Hougang ABC (hougang-abc-ts3u)                             847  ·  live pot holds 500
--   QA Kopi Lab (qa-kopi-lab)                                  170  ·  live pot holds 159
-- Cubbly is a STAMPS tenant. Its live pot is the stamps pot (16 stamps earned); the 78,292 the
-- dashboard is adding in belongs to a points pot that was RETIRED and already re-denominated
-- into stamps by the v384 conversion (adjust -76,100 on points, +761 on stamps). The owner's
-- first screen every morning has been overstating the figure by a factor of ~4,894 and calling
-- stamps "points" while doing it.
--
-- THE RULE, AND WHERE IT COMES FROM. v312 established the programme pot; v381 named the pot a
-- balance belongs to in app.live_balance_programme_v381(business) -> uuid, and the customer
-- readers plus the staff readers were moved onto it. Four functions already use it today:
-- app.c45_base_actionable_wallet_card, app.client_points_balance_v409,
-- public.staff_get_customer_actionable_loyalty_v145 and public.staff_list_customers_v155.
-- These two business report readers were simply never migrated. This change does NOT invent a
-- second definition of "which pot counts" — it calls the same helper, so there remains exactly
-- one answer in the database.
--
-- WHAT THE KPI MEANS AFTER THIS CHANGE:
--   "Loyalty units issued by the programme that is running now."
-- Concretely: earn (and, in the reports breakdown, redeem/expire/adjust) belonging to the ONE
-- active accruing programme returned by app.live_balance_programme_v381. A retired pot
-- contributes nothing. Because points and stamps are mutually exclusive (R2, and the helper
-- enforces it by returning at most one row), the figure is now always in exactly ONE unit and
-- can never again be a sum of two.
--   * tenant running POINTS  -> the figure is points
--   * tenant running STAMPS  -> the figure is STAMPS, and both payloads now say so
--   * tenant running neither -> app.live_balance_programme_v381 returns NULL. points_ledger
--     .programme_id is NOT NULL (v311) with zero null rows in production, so the predicate
--     matches nothing and the figure is 0 rather than "everything ever earned". That is the
--     honest answer for a firm with no accruing programme.
--
-- Both payloads gain a new key, 'loyalty_unit' ('points' | 'stamps' | null), read from the live
-- pot's own business_programmes.kind. It is ADDITIVE: no key is removed or renamed, and a client
-- that ignores it renders exactly as it does today.
--
-- ⚖️ THE LABEL IS STILL WRONG FOR A STAMPS TENANT, AND THAT HALF IS NOT IN THIS MIGRATION.
-- app/app.js hardcodes the word "Points" in both places that render these figures —
-- app.js:17258 ({label:'Points earned'} on the dashboard loyalty strip) and app.js:41371-41374
-- (the Reports money card's four rows). After this change Cubbly's dashboard reads a correct
-- 16 under an incorrect heading. 'loyalty_unit' is emitted precisely so that fix is a label
-- lookup and not another query; it is handed to the orchestrator rather than made here, because
-- this session does not edit app.js.
--
-- HOW IT IS PATCHED: extract-and-replace against the deployed definition, the same method
-- nestly_v213 and nestly_v454 used. Both functions are long (get_dashboard_summary_v155 alone is
-- ~220 lines of plpgsql with six CTEs) and retyping either body would risk drifting from what is
-- actually running. Each anchor is asserted to occur EXACTLY ONCE before anything is executed,
-- and the installed result is re-read and verified afterwards, so a shape change upstream fails
-- this migration loudly instead of silently installing a half-patched function.
--
-- ACL: create-or-replace preserves grants. The live ACL of both functions is
-- {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres} — PUBLIC and anon hold
-- nothing. The revoke/grant pairs below restate that verbatim; they are a no-op reassertion.

begin;

do $patch$
declare
  v_src text;
  v_new text;
  v_hits int;

  -- The programme predicate, inserted verbatim into both readers.
  c_scope constant text :=
    '        and pl.programme_id = app.live_balance_programme_v381(p_business)' || E'\n';

  -- Anchors, each verified unique against the deployed body before use.
  c_dash_where constant text :=
    '      where pl.business_id = p_business' || E'\n' ||
    '        and pl.entry_type = ''earn''' || E'\n';
  c_dash_tail constant text :=
    '    ) else null end' || E'\n' || '  );' || E'\n';
  c_reports_where constant text :=
    '      from public.points_ledger pl' || E'\n' ||
    '      where pl.business_id = p_business' || E'\n';
  c_reports_tail constant text :=
    '    ''points_by_type'', v_points,' || E'\n';

  c_unit_sql constant text :=
    '(select spine.kind from public.business_programmes spine'
    || ' where spine.id = app.live_balance_programme_v381(p_business))';
begin
  ------------------------------------------------------ public.get_dashboard_summary_v155
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_dashboard_summary_v155';
  if v_src is null then
    raise exception 'v460: public.get_dashboard_summary_v155 is missing';
  end if;

  if position(c_scope in v_src) > 0 then
    raise notice 'v460: get_dashboard_summary_v155 is already pot-scoped; left as it is';
  else
    v_hits := (length(v_src) - length(replace(v_src, c_dash_where, ''))) / length(c_dash_where);
    if v_hits <> 1 then
      raise exception 'v460: the points_issued WHERE anchor occurs % times in '
        'get_dashboard_summary_v155, expected exactly 1', v_hits;
    end if;
    v_hits := (length(v_src) - length(replace(v_src, c_dash_tail, ''))) / length(c_dash_tail);
    if v_hits <> 1 then
      raise exception 'v460: the points_issued output anchor occurs % times in '
        'get_dashboard_summary_v155, expected exactly 1', v_hits;
    end if;

    -- (1) scope the sum to the live pot
    v_new := replace(v_src, c_dash_where,
      '      where pl.business_id = p_business' || E'\n' || c_scope ||
      '        and pl.entry_type = ''earn''' || E'\n');
    -- (2) name the unit the figure is counted in
    v_new := replace(v_new, c_dash_tail,
      '    ) else null end,' || E'\n' ||
      '    ''loyalty_unit'', case when v_loyalty_available then ' || c_unit_sql || ' else null end'
      || E'\n' || '  );' || E'\n');
    execute v_new;
  end if;

  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_dashboard_summary_v155';
  if position(c_scope in v_src) = 0 or position('''loyalty_unit''' in v_src) = 0 then
    raise exception 'v460: get_dashboard_summary_v155 did not take the pot scope';
  end if;

  ------------------------------------------------------------ public.get_reports_summary
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_reports_summary';
  if v_src is null then
    raise exception 'v460: public.get_reports_summary is missing';
  end if;

  if position(c_scope in v_src) > 0 then
    raise notice 'v460: get_reports_summary is already pot-scoped; left as it is';
  else
    v_hits := (length(v_src) - length(replace(v_src, c_reports_where, ''))) / length(c_reports_where);
    if v_hits <> 1 then
      raise exception 'v460: the points_by_type FROM/WHERE anchor occurs % times in '
        'get_reports_summary, expected exactly 1', v_hits;
    end if;
    v_hits := (length(v_src) - length(replace(v_src, c_reports_tail, ''))) / length(c_reports_tail);
    if v_hits <> 1 then
      raise exception 'v460: the points_by_type output anchor occurs % times in '
        'get_reports_summary, expected exactly 1', v_hits;
    end if;

    v_new := replace(v_src, c_reports_where,
      '      from public.points_ledger pl' || E'\n' ||
      '      where pl.business_id = p_business' || E'\n' || c_scope);
    v_new := replace(v_new, c_reports_tail,
      '    ''points_by_type'', v_points,' || E'\n' ||
      '    ''loyalty_unit'', case when v_loyalty_available then ' || c_unit_sql || ' else null end,'
      || E'\n');
    execute v_new;
  end if;

  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_reports_summary';
  if position(c_scope in v_src) = 0 or position('''loyalty_unit''' in v_src) = 0 then
    raise exception 'v460: get_reports_summary did not take the pot scope';
  end if;
end
$patch$;

revoke all on function public.get_dashboard_summary_v155(uuid, date, date, text, uuid[], uuid) from public, anon;
grant execute on function public.get_dashboard_summary_v155(uuid, date, date, text, uuid[], uuid) to authenticated, service_role;

revoke all on function public.get_reports_summary(uuid, date, date, uuid) from public, anon;
grant execute on function public.get_reports_summary(uuid, date, date, uuid) to authenticated, service_role;

commit;
