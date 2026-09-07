-- nestly_v822 — the Daily report counts one points pot, like every other reader.
--
-- FOUND BY an end-to-end walk of the business reports (db/tests/v820_business_reports_kpis_end_to_end.sql)
-- that compares each KPI against the other readers of the same ledger. For the same 30-day
-- window on the same tenant:
--
--     Daily report   get_dashboard_summary(uuid,date,date,uuid)   points_issued = 177
--     Dashboard      get_dashboard_summary_v155                   points_issued = 140
--     Insights       get_reports_summary                          earn          = 140
--     ledger, live pot only                                                       140
--     ledger, live pot + a SWITCHED-OFF stamps pot                                177
--
-- nestly_v460 fixed exactly this defect class — "business KPI readers summed every pot" — by
-- scoping get_dashboard_summary_v155 and get_reports_summary to
-- app.live_balance_programme_v381. It did not touch public.get_dashboard_summary, the 4-argument
-- sibling with its own copy of the points_issued body, and that is the one the Daily report
-- page calls (app/app.js ~55127). So the Daily report kept adding retired pots while the
-- Dashboard directly above it in the sidebar did not, and an owner comparing the two pages saw
-- two different "points issued" for one day. Three businesses show the discrepancy today:
-- Cubbly SPA (4402 vs 4349), QA Kopi Lab (198 vs 39), ÉLAN Wellness (177 vs 140).
--
-- THE FIX is the same one line v460 inserted into the sibling, applied by the same anchored
-- replacement against the live body rather than by retyping a ~230-line function: the anchor
-- is asserted to occur EXACTLY ONCE before anything executes, and the installed result is
-- re-read afterwards, so a shape change upstream fails here loudly rather than installing a
-- half-patched reader. Nothing else in the function changes.
--
-- ACL: create-or-replace preserves grants. Live ACL is
-- {postgres=X/postgres, authenticated=X/postgres, service_role=X/postgres}; PUBLIC and anon hold
-- nothing. The revoke/grant pair restates that verbatim (nestly_v810 last did so).

begin;

do $patch$
declare
  v_src  text;
  v_new  text;
  v_hits int;
  c_scope constant text :=
    '        and pl.programme_id = app.live_balance_programme_v381(p_business)' || E'\n';
  c_where constant text :=
    '      where pl.business_id = p_business' || E'\n' ||
    '        and pl.entry_type = ''earn''' || E'\n';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_dashboard_summary' and p.pronargs = 4;
  if v_src is null then
    raise exception 'v822: public.get_dashboard_summary(uuid,date,date,uuid) is missing';
  end if;

  if position(c_scope in v_src) > 0 then
    raise notice 'v822: get_dashboard_summary is already pot-scoped; left as it is';
  else
    v_hits := (length(v_src) - length(replace(v_src, c_where, ''))) / length(c_where);
    if v_hits <> 1 then
      raise exception 'v822: the points_issued WHERE anchor occurs % times in '
        'get_dashboard_summary, expected exactly 1', v_hits;
    end if;
    v_new := replace(v_src, c_where,
      '      where pl.business_id = p_business' || E'\n' || c_scope ||
      '        and pl.entry_type = ''earn''' || E'\n');
    execute v_new;
  end if;

  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_dashboard_summary' and p.pronargs = 4;
  if position(c_scope in v_src) = 0 then
    raise exception 'v822: get_dashboard_summary did not take the pot scope';
  end if;
end
$patch$;

revoke all on function public.get_dashboard_summary(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_dashboard_summary(uuid,date,date,uuid) to authenticated, service_role;

commit;
