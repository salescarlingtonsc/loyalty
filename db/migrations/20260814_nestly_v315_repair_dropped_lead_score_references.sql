-- nestly_v315_repair_dropped_lead_score_references
--
-- v313 dropped app.v297_lead_score, app.v297_refresh_lead_score and
-- public.sme_lead_scores. PL/pgSQL resolves function and table names at RUN
-- time, not at definition time, so nothing raised, nothing failed CI, and the
-- 2889-test suite stayed green — while five production functions were left
-- calling objects that no longer existed:
--
--   platform_crm_ingest_discovered_v297    EVERY Google import          42883
--   platform_crm_log_outreach_v297         every logged call/WhatsApp   42883
--   platform_crm_prospecting_detail_v297   the prospect drawer          42P01
--   platform_crm_prospecting_search_v297   the superseded search        42P01
--   app.v310_purge_expired_google_content  the NIGHTLY retention sweep  42P01
--
-- The retention one is the most serious: it is a pg_cron job, so it would have
-- failed silently every night at 03:30 SGT and left Google-derived content
-- stored beyond the 30-day limit the v310 work exists to enforce. A compliance
-- control that reports nothing looks identical to one that is working.
--
-- Each function is rebuilt FROM ITS OWN CURRENT SOURCE with only the scoring
-- lines removed, so no other behaviour changes. Every step asserts that the
-- reference is actually gone before executing, so a partial repair fails loudly
-- instead of leaving another silent break.
--
-- Ordering note: this cannot be folded into v313. It repairs functions as they
-- exist in production, and it must run after the drop.

begin;

-- 1. Import: delete the score-refresh call.
do $repair_import$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='platform_crm_ingest_discovered_v297';
  d := replace(d, '    perform app.v297_refresh_lead_score(v_prospect);' || E'\n', '');
  if position('v297_refresh_lead_score' in d) > 0 then
    raise exception 'import repair failed: score call survived';
  end if;
  execute d;
end $repair_import$;

-- 2. Retention sweep: remove the "recompute scores that used purged facts" loop
--    and its now-unused loop variable.
do $repair_retention$
declare parts text[]; i int; j int; d text;
begin
  select string_to_array(pg_get_functiondef(p.oid), E'\n') into parts
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='v310_purge_expired_google_content';
  i := array_position(parts, '  for v_prospect in');
  j := array_position(parts, '  end loop;');
  if i is null or j is null or j <= i then
    raise exception 'retention repair failed: loop boundaries not found (% .. %)', i, j;
  end if;
  parts := parts[1:i-1] || parts[j+1:array_length(parts,1)];
  d := array_to_string(parts, E'\n');
  d := replace(d, ' v_facts integer := 0; v_prospect uuid;', ' v_facts integer := 0;');
  if position('sme_lead_scores' in d) > 0 or position('v297_refresh_lead_score' in d) > 0 then
    raise exception 'retention repair failed: scoring reference survived';
  end if;
  execute d;
end $repair_retention$;

-- 3. Prospect drawer: drop the three-line lead_score payload key.
do $repair_drawer$
declare parts text[]; i int; j int; d text;
begin
  select string_to_array(pg_get_functiondef(p.oid), E'\n') into parts
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='platform_crm_prospecting_detail_v297';
  i := null;
  for j in 1..array_length(parts,1) loop
    if parts[j] like '%''lead_score'', coalesce(%' then i := j; exit; end if;
  end loop;
  if i is null then raise exception 'drawer repair failed: lead_score key not found'; end if;
  if parts[i+2] not like '%v297_lead_score(p_prospect)),%' then
    raise exception 'drawer repair failed: unexpected shape at line %', i+2;
  end if;
  parts := parts[1:i-1] || parts[i+3:array_length(parts,1)];
  d := array_to_string(parts, E'\n');
  if position('lead_score' in d) > 0 then
    raise exception 'drawer repair failed: scoring reference survived';
  end if;
  execute d;
end $repair_drawer$;

-- 4. Logged outreach: drop the refresh call and the score in the return payload.
do $repair_outreach$
declare parts text[]; i int; d text;
begin
  select string_to_array(pg_get_functiondef(p.oid), E'\n') into parts
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='platform_crm_log_outreach_v297';
  i := array_position(parts, '  perform app.v297_refresh_lead_score(p_prospect);');
  if i is null then raise exception 'log_outreach repair: refresh call not found'; end if;
  parts := parts[1:i-1] || parts[i+1:array_length(parts,1)];
  d := array_to_string(parts, E'\n');
  d := replace(d,
    ',' || E'\n' || '    ''lead_score'',(select score from public.sme_lead_scores where prospect_id=p_prospect));',
    ');');
  if position('lead_score' in d) > 0 then
    raise exception 'log_outreach repair failed: a scoring reference survived';
  end if;
  execute d;
end $repair_outreach$;

-- 5. Superseded search: drop the join, the score column, the score_min filter,
--    and the two orderings that ranked by score. Ranking falls back to review
--    volume — an observed fact, not an invented judgement.
do $repair_search$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='platform_crm_prospecting_search_v297';
  d := replace(d, 'coalesce(sc.score,0) as score, p.assigned_consultant_id,',
                  'p.assigned_consultant_id,');
  d := replace(d, '      left join public.sme_lead_scores sc on sc.prospect_id=p.id' || E'\n', '');
  d := replace(d,
    '       and (nullif(p_filters->>''score_min'','''') is null' || E'\n' ||
    '            or coalesce(sc.score,0) >= (p_filters->>''score_min'')::integer)' || E'\n', '');
  d := replace(d,
    '          ''score'',m.score,''rating'',m.rating,''contacted'',m.last_contacted_at is not null,',
    '          ''rating'',m.rating,''contacted'',m.last_contacted_at is not null,');
  d := replace(d,
    '               order by score desc limit v_marker_cap) m),''[]''::jsonb))',
    '               order by coalesce(review_count,0) desc limit v_marker_cap) m),''[]''::jsonb))');
  d := replace(d,
    '        from (select * from hits order by score desc, name',
    '        from (select * from hits order by coalesce(review_count,0) desc, name');
  if d ~ '\mscore\M' or position('sme_lead_scores' in d) > 0 then
    raise exception 'search repair failed: a scoring reference survived';
  end if;
  execute d;
end $repair_search$;

-- Final guard: no function anywhere may still reference the dropped objects.
do $verify$
declare v_left text;
begin
  select string_agg(n.nspname||'.'||p.proname, ', ') into v_left
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname in ('public','app') and p.prokind='f'
     and (pg_get_functiondef(p.oid) like '%sme_lead_scores%'
       or pg_get_functiondef(p.oid) like '%v297_lead_score%'
       or pg_get_functiondef(p.oid) like '%v297_refresh_lead_score%');
  if v_left is not null then
    raise exception 'lead-score references still present in: %', v_left;
  end if;
end $verify$;

commit;
