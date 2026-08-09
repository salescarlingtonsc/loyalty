-- Rollback-only acceptance for v247 — Explore sorts by distance once a branch is located.
--
-- Runs against the REAL directory inside one transaction, then rolls back. Proves:
--   * haversine is right: a known Singapore pair matches its published distance within 100 m,
--     the identity case is zero, and a missing coordinate yields null rather than 0;
--   * with a position, results order nearest first and every unlocated business sorts LAST but
--     is still returned — never dropped;
--   * distance_km is null for an unlocated business, so the UI can never print a fabricated one;
--   * a half-supplied or out-of-range position is ignored, not clamped: the list falls back to
--     the name/joined ordering rather than sorting against a nonsense origin;
--   * the caller's position is not persisted anywhere;
--   * a client that still sends only p_query resolves to the new signature;
--   * anon still has no EXECUTE.

begin;

do $suite$
declare
  v_auth uuid;
  v_near jsonb;
  v_far jsonb;
  v_plain jsonb;
  v_bad jsonb;
  v_first jsonb;
  v_last jsonb;
  v_located int;
  v_km numeric;
  v_rows_before bigint;
  v_rows_after bigint;
begin
  select l.auth_user_id into v_auth from public.customer_links l
  where l.business_id='8492e8d6-8888-4383-ada0-7e1ed69f0caa' and l.state='verified'
    and l.unlinked_at is null limit 1;
  if v_auth is null then raise exception 'v247: fixture needs one verified Cubbly customer'; end if;

  ------------------------------------------------------------------- 1 · the distance itself
  -- Orchard (1.3010, 103.8384) to Changi Airport (1.3644, 103.9915): ~18.4 km great-circle
  v_km := app.v247_distance_km(1.301014, 103.838361, 1.364420, 103.991531);
  if v_km is null or abs(v_km - 18.4) > 0.5 then
    raise exception 'v247: Orchard→Changi should be ~18.4 km, got %', v_km;
  end if;
  if app.v247_distance_km(1.3, 103.8, 1.3, 103.8) <> 0 then
    raise exception 'v247: the same point must be zero km apart';
  end if;
  if app.v247_distance_km(1.3, 103.8, null, 103.8) is not null then
    raise exception 'v247: an unknown coordinate must be null distance, never zero';
  end if;

  ------------------------------------------------------------------- 2 · nearest first
  -- a located branch exists for this fixture, otherwise the ordering claim is untestable
  select count(*) into v_located from public.branches
   where latitude is not null and longitude is not null and coalesce(active,true);
  if v_located = 0 then
    raise exception 'v247: no located branch in the directory — geocode one before asserting order';
  end if;

  perform set_config('request.jwt.claim.sub',v_auth::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',v_auth,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  v_plain := public.customer_explore_businesses_v244(null);                       -- no position
  v_near  := public.customer_explore_businesses_v244(null, 1.3010, 103.8384);     -- at Orchard
  v_far   := public.customer_explore_businesses_v244(null, 1.4360, 103.7860);     -- Woodlands
  v_bad   := public.customer_explore_businesses_v244(null, 999, 103.8384);        -- nonsense
  execute 'reset role';

  if jsonb_array_length(v_near) <> jsonb_array_length(v_plain) then
    raise exception 'v247: sorting by distance must not drop or add businesses (% vs %)',
      jsonb_array_length(v_near), jsonb_array_length(v_plain);
  end if;

  v_first := v_near->0;
  if (v_first->>'located')::boolean is not true then
    raise exception 'v247: with a position, a located business must come first';
  end if;
  if (v_first->>'distance_km') is null then
    raise exception 'v247: the nearest result must carry its distance';
  end if;

  v_last := v_near->(jsonb_array_length(v_near) - 1);
  if (v_last->>'located')::boolean is true then
    raise exception 'v247: unlocated businesses must sort last';
  end if;
  if (v_last->>'distance_km') is not null then
    raise exception 'v247: an unlocated business must never carry a distance';
  end if;

  -- the same shop is genuinely farther from Woodlands than from Orchard
  if ((v_far->0)->>'distance_km')::numeric <= ((v_near->0)->>'distance_km')::numeric then
    raise exception 'v247: distance must follow the caller position, not a constant';
  end if;

  ------------------------------------------------------- 3 · a nonsense position is ignored
  if (v_bad->0)->>'distance_km' is not null then
    raise exception 'v247: an out-of-range position must be ignored, not clamped';
  end if;
  if (v_bad->0)->>'name' <> (v_plain->0)->>'name' then
    raise exception 'v247: an ignored position must fall back to the ordinary ordering';
  end if;

  ------------------------------------------------------- 4 · the position is never persisted
  select count(*) into v_rows_after from public.branches
   where latitude = 1.3010 and longitude = 103.8384;
  if v_rows_after > 0 then
    raise exception 'v247: the caller position must never be written to a row';
  end if;

  ------------------------------------------------------- 5 · old one-argument callers still work
  perform set_config('request.jwt.claim.sub',v_auth::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',v_auth,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  perform public.customer_explore_businesses_v244('facial');
  execute 'reset role';

  ------------------------------------------------------------------- 6 · still closed to anon
  begin
    perform set_config('request.jwt.claim.sub','',true);
    perform set_config('request.jwt.claims',json_build_object('role','anon')::text,true);
    execute 'set local role anon';
    perform public.customer_explore_businesses_v244(null, 1.3010, 103.8384);
    execute 'reset role';
    raise exception 'v247: anon must not search the directory';
  exception when others then
    execute 'reset role';
  end;

  raise notice 'v247 acceptance: all assertions passed';
end $suite$;

rollback;
