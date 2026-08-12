-- Rolled-back acceptance for V292 (demo request capture). Everything runs inside
-- ONE transaction that is rolled back: no demo request survives the run.
--
-- This suite reads the DEPLOYED objects. It does NOT replay the migration's DDL,
-- because a suite that creates the shape it then asserts would run green against
-- a drifted or half-applied production. Run it immediately AFTER applying
-- `nestly_v292_demo_requests`; before that it fails at section A with
-- "relation public.demo_requests_v292 does not exist", which is the correct
-- answer to "is V292 live?".
--
-- The block ENDS in `raise exception 'V292_RESULT ALL PASS -- %'`. A bare assert
-- prints nothing when it passes, so a green run would be indistinguishable from a
-- run that asserted nothing; raising prints every measured value AND aborts the
-- transaction, so the suite rolls itself back even when fed to a single-statement
-- executor that never sees the trailing `rollback;`.

begin;

do $v292$
declare
  v_policies integer; v_rls boolean;
  v_anon_table integer; v_auth_table integer;
  v_anon_submit integer; v_anon_list integer;
  v_result jsonb; v_id uuid; v_second jsonb;
  v_rows integer; v_status text; v_phone text; v_email text;
  v_contacted_at timestamptz; v_first_contacted timestamptz;
  v_raised text;
  v_sa uuid;
  v_backdated timestamptz;
  v_log text := '';
begin
  -- ------------------------------------------------------------------
  -- A. The table is platform-managed: RLS on, ZERO policies, and no
  --    browser role holds any privilege on it. A demo request is
  --    cross-tenant prospect data; a single permissive policy here would
  --    expose every prospect to every tenant.
  -- ------------------------------------------------------------------
  select relrowsecurity into v_rls
    from pg_class where oid = 'public.demo_requests_v292'::regclass;
  if v_rls is not true then
    raise exception 'A: demo_requests_v292 does not have RLS enabled';
  end if;
  select count(*) into v_policies
    from pg_policy where polrelid = 'public.demo_requests_v292'::regclass;
  if v_policies <> 0 then
    raise exception 'A: demo_requests_v292 carries % policy/policies; it must carry zero', v_policies;
  end if;
  -- has_table_privilege rather than information_schema: the catalog view is
  -- filtered by the querying role, so it can under-report and pass by accident.
  select count(*) into v_anon_table
    from unnest(array['SELECT','INSERT','UPDATE','DELETE','REFERENCES','TRIGGER','TRUNCATE']) as privilege
   where has_table_privilege('anon', 'public.demo_requests_v292', privilege);
  select count(*) into v_auth_table
    from unnest(array['SELECT','INSERT','UPDATE','DELETE','REFERENCES','TRIGGER','TRUNCATE']) as privilege
   where has_table_privilege('authenticated', 'public.demo_requests_v292', privilege);
  if v_anon_table <> 0 or v_auth_table <> 0 then
    raise exception 'A: browser roles hold table privileges (anon=%, authenticated=%)',
      v_anon_table, v_auth_table;
  end if;
  v_log := v_log || format('A: rls=%s policies=%s anon_table_grants=%s auth_table_grants=%s. ',
    v_rls, v_policies, v_anon_table, v_auth_table);

  -- ------------------------------------------------------------------
  -- B. The capture is anon-callable; the two platform readers are NOT.
  --    This is the whole security posture of V292 in two numbers, so it
  --    is asserted rather than assumed from the migration text.
  -- ------------------------------------------------------------------
  select count(*) into v_anon_submit
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
   where p.proname = 'submit_demo_request_v292'
     and has_function_privilege('anon', p.oid, 'EXECUTE');
  select count(*) into v_anon_list
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
   where p.proname in ('platform_list_demo_requests_v292', 'platform_mark_demo_request_v292')
     and has_function_privilege('anon', p.oid, 'EXECUTE');
  if v_anon_submit <> 1 then
    raise exception 'B: anon must hold EXECUTE on exactly one submit_demo_request_v292 (found %)', v_anon_submit;
  end if;
  if v_anon_list <> 0 then
    raise exception 'B: anon holds EXECUTE on % platform demo-request function(s); it must hold none', v_anon_list;
  end if;
  v_log := v_log || format('B: anon_submit=%s anon_platform=%s. ', v_anon_submit, v_anon_list);

  -- ------------------------------------------------------------------
  -- C. A real capture. The phone is typed the way a Singapore prospect
  --    actually types it and must be stored normalised, and the email
  --    must be folded to lower case, or two spellings of one prospect
  --    become two cards in the queue.
  -- ------------------------------------------------------------------
  v_result := public.submit_demo_request_v292(
    '  Priya Menon ', ' Kopi Corner Pte Ltd ', ' Priya@KopiCorner.SG ', '+65 8123 4567',
    'F&B', 'Would like to see the loyalty side.');
  if v_result->>'outcome' <> 'recorded' then
    raise exception 'C: first submission was not recorded (%)', v_result;
  end if;
  v_id := (v_result->>'request_id')::uuid;
  select contact_phone, contact_email, status
    into v_phone, v_email, v_status
    from public.demo_requests_v292 where id = v_id;
  if v_phone <> '81234567' then
    raise exception 'C: phone stored as % instead of the normalised 81234567', v_phone;
  end if;
  if v_email <> 'priya@kopicorner.sg' then
    raise exception 'C: email stored as % instead of lower case', v_email;
  end if;
  if v_status <> 'new' then
    raise exception 'C: a fresh request landed with status % instead of new', v_status;
  end if;
  v_log := v_log || format('C: id=%s phone=%s email=%s status=%s. ', v_id, v_phone, v_email, v_status);

  -- ------------------------------------------------------------------
  -- D. The double tap. The same prospect submitting again within the
  --    dedupe window is ONE request. The second call must succeed (the
  --    prospect must never see an error for pressing twice) and must not
  --    create a second row.
  -- ------------------------------------------------------------------
  v_second := public.submit_demo_request_v292(
    'Priya Menon', 'Kopi Corner Pte Ltd', 'priya@kopicorner.sg', '8123 4567', 'F&B', 'again');
  if v_second->>'status' <> 'ok' or v_second->>'outcome' <> 'duplicate_ignored' then
    raise exception 'D: the repeat submission answered % instead of duplicate_ignored', v_second;
  end if;
  select count(*) into v_rows
    from public.demo_requests_v292
   where dedupe_hash = (select dedupe_hash from public.demo_requests_v292 where id = v_id);
  if v_rows <> 1 then
    raise exception 'D: the double tap produced % rows', v_rows;
  end if;
  v_log := v_log || format('D: rows_after_double_tap=%s. ', v_rows);

  -- ------------------------------------------------------------------
  -- E. Refusals. A request with no way to reach the prospect is worse
  --    than no request at all -- it looks like a lead and is not one.
  -- ------------------------------------------------------------------
  begin
    perform public.submit_demo_request_v292('Ada Tan', 'Nowhere Pte Ltd', null, null, null, null);
    raise exception 'E: a contactless demo request was accepted';
  exception when sqlstate '22023' then
    v_raised := 'contactless refused';
  end;
  begin
    perform public.submit_demo_request_v292('Ada Tan', 'Nowhere Pte Ltd', 'not-an-email', null, null, null);
    raise exception 'E: an invalid email was accepted';
  exception when sqlstate '22023' then
    v_raised := v_raised || ', bad email refused';
  end;
  begin
    perform public.submit_demo_request_v292('A', 'Nowhere Pte Ltd', 'ada@nowhere.sg', null, null, null);
    raise exception 'E: a one-character contact name was accepted';
  exception when sqlstate '22023' then
    v_raised := v_raised || ', short name refused';
  end;
  v_log := v_log || format('E: %s. ', v_raised);

  -- ------------------------------------------------------------------
  -- CORRECTION 1 (scaffolding gap, found on the first-ever run 2026-08-12).
  --   Sections F and G call SECURITY DEFINER platform functions that gate on
  --   auth.uid() and app.is_super_admin(). The suite never established an
  --   identity, so under ANY executor -- psql, MCP, CI -- it aborted at F with
  --   28000 'authenticated platform session is required'. The suite had never
  --   been run; sections F and G had never asserted anything.
  --   Adopt a REAL super admin out of public.super_admins rather than a
  --   hardcoded uuid (which rots the moment the roster changes), and set the
  --   `request.jwt.claims` GUC that auth.uid() actually reads. is_local = true,
  --   so the impersonation dies with the transaction.
  -- ------------------------------------------------------------------
  select sa.user_id into v_sa from public.super_admins sa order by sa.user_id limit 1;
  if v_sa is null then
    raise exception 'CORRECTION 1: no super admin exists to run sections F/G as';
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_sa, 'role', 'authenticated')::text, true);
  if not app.is_super_admin() then
    raise exception 'CORRECTION 1: impersonation of super admin % did not take', v_sa;
  end if;
  v_log := v_log || format('CORRECTION1: acting_as_super_admin=%s. ', v_sa);

  -- ------------------------------------------------------------------
  -- F. The queue reader returns the page AND the real total, which is the
  --    entire point of the V292 pagination contract: the console must be
  --    able to say "50 of N" instead of truncating in silence.
  -- ------------------------------------------------------------------
  v_result := public.platform_list_demo_requests_v292(null, 'Kopi Corner', 50, 0);
  if v_result->>'status' <> 'ok' then
    raise exception 'F: the queue reader refused a super-admin read (%)', v_result;
  end if;
  if (v_result->>'total_count')::bigint < 1 then
    raise exception 'F: total_count is % with a fixture row present', v_result->>'total_count';
  end if;
  if jsonb_array_length(v_result->'items') < 1 then
    raise exception 'F: the page carries no items while total_count is %', v_result->>'total_count';
  end if;
  if (v_result->>'has_more')::boolean is null then
    raise exception 'F: has_more is absent; the console cannot page without it';
  end if;
  v_log := v_log || format('F: total=%s page=%s has_more=%s. ',
    v_result->>'total_count', jsonb_array_length(v_result->'items'), v_result->>'has_more');

  -- A page smaller than the total must say so, or the operator is told the
  -- queue is empty below the fold when it is not.
  v_result := public.platform_list_demo_requests_v292(null, null, 1, 0);
  if (v_result->>'total_count')::bigint > 1 and (v_result->>'has_more')::boolean is not true then
    raise exception 'F: a 1-row page of % said has_more=false', v_result->>'total_count';
  end if;
  v_log := v_log || format('F2: limit1_total=%s has_more=%s. ',
    v_result->>'total_count', v_result->>'has_more');

  -- ------------------------------------------------------------------
  -- G. Triage. Marking contacted is idempotent on the timestamp: a second
  --    mark must not rewrite when the prospect was actually reached.
  -- ------------------------------------------------------------------
  perform public.platform_mark_demo_request_v292(v_id, 'contacted', 'Called, demo booked Thursday.');
  select status, contacted_at into v_status, v_first_contacted
    from public.demo_requests_v292 where id = v_id;
  if v_status <> 'contacted' or v_first_contacted is null then
    raise exception 'G: mark contacted left status=% contacted_at=%', v_status, v_first_contacted;
  end if;
  -- CORRECTION 2 (the test was vacuous). now() is frozen for the whole
  -- transaction, so a second mark issued in-transaction would write the SAME
  -- timestamp the first one did, and the equality below would pass even if
  -- `coalesce(request.contacted_at, now())` were plain `now()`. Back-date the
  -- first mark so the two candidate values are genuinely different; only a
  -- real coalesce keeps the back-dated one.
  update public.demo_requests_v292
     set contacted_at = v_first_contacted - interval '3 days'
   where id = v_id;
  select contacted_at into v_backdated from public.demo_requests_v292 where id = v_id;
  v_first_contacted := v_backdated;

  perform public.platform_mark_demo_request_v292(v_id, 'contacted', 'Called again.');
  select contacted_at into v_contacted_at
    from public.demo_requests_v292 where id = v_id;
  if v_contacted_at <> v_first_contacted then
    raise exception 'G: re-marking moved contacted_at from % to %', v_first_contacted, v_contacted_at;
  end if;
  begin
    perform public.platform_mark_demo_request_v292(v_id, 'invented_status', null);
    raise exception 'G: an unknown status was accepted';
  exception when sqlstate '22023' then
    v_raised := 'unknown status refused';
  end;
  v_log := v_log || format('G: status=%s contacted_at_stable=%s %s. ',
    v_status, (v_contacted_at = v_first_contacted), v_raised);

  raise exception 'V292_RESULT ALL PASS -- %', v_log;
end
$v292$;

rollback;
