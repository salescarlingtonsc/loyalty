-- Rollback-only v202 acceptance: one directory answers sector, search,
-- collection mode and every due window from the same rows.
begin;

do $v202$
declare v_sa uuid; a jsonb; v_all bigint; v_chase bigint; v_auto bigint;
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text, true);

  a := public.platform_company_directory_v202();
  v_all := (a->>'total_count')::bigint;
  if v_all < 1 then raise exception 'A: directory returned no companies'; end if;

  -- Every company must carry a collection mode; there is no third state.
  if exists (select 1 from jsonb_array_elements(a->'items') i
              where i->>'collection_mode' not in ('auto','chase')) then
    raise exception 'B: a company has no collection mode';
  end if;

  -- auto + chase must account for every company, or a firm is invisible to the
  -- chase list without anyone noticing.
  v_auto := coalesce((a#>>'{collection,auto}')::bigint,0);
  v_chase := coalesce((a#>>'{collection,chase}')::bigint,0);
  if v_auto + v_chase <> v_all then
    raise exception 'C: collection facets (%+%) do not cover all % companies',
      v_auto, v_chase, v_all;
  end if;

  -- Filtering by collection mode must agree with the facet count.
  if (public.platform_company_directory_v202(p_collection=>'chase')->>'total_count')::bigint <> v_chase then
    raise exception 'D: chase filter disagrees with the chase facet';
  end if;

  -- Sector facets must cover every company too.
  if (select coalesce(sum((s->>'n')::bigint),0) from jsonb_array_elements(a->'sectors') s) <> v_all then
    raise exception 'E: sector facets do not cover every company';
  end if;

  -- Due windows must nest: today <= 7 <= 14 <= 30.
  if (a#>>'{due,today}')::bigint > (a#>>'{due,in_7}')::bigint
     or (a#>>'{due,in_7}')::bigint > (a#>>'{due,in_14}')::bigint
     or (a#>>'{due,in_14}')::bigint > (a#>>'{due,in_30}')::bigint then
    raise exception 'F: due windows are not nested: %', a->'due';
  end if;

  -- Search must narrow, never widen.
  if (public.platform_company_directory_v202(p_search=>'zzzz-no-such-firm')->>'total_count')::bigint <> 0 then
    raise exception 'G: search matched a company that should not exist';
  end if;

  -- Paging must be bounded and self-describing.
  a := public.platform_company_directory_v202(p_limit=>1);
  if jsonb_array_length(a->'items') <> 1 then raise exception 'H: limit was ignored'; end if;
  if v_all > 1 and not (a->>'has_more')::boolean then
    raise exception 'I: has_more is false while more companies exist';
  end if;

  -- Bad filters fail closed rather than silently returning everything.
  begin
    perform public.platform_company_directory_v202(p_collection=>'giro');
    raise exception 'J: an unknown collection filter was accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.platform_company_directory_v202(p_due_window=>'soon');
    raise exception 'K: an unknown due window was accepted';
  exception when sqlstate '22023' then null;
  end;

  raise notice 'v202 company directory: all assertions passed (% companies, % chase)', v_all, v_chase;
end
$v202$;

rollback;
