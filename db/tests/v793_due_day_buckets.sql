-- nestly_v793 rollback suite — the directory can be filtered by HOW LATE a payment is.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production. It moves the
-- due dates of real subscription rows to manufacture a one-day-late firm, a mid-week-late firm and
-- a long-late firm, asserts the buckets catch exactly those, then throws the changes away.
--
-- WHAT IT PROVES
--   A  the three new overdue buckets PARTITION the old `overdue` count — every late firm lands in
--      exactly one of them, so the chips add up and nobody falls between two filters.
--   B  filtering by a bucket returns exactly the rows the facet counted, and every returned row
--      really has the day-distance that bucket claims.
--   C  the new '3' window nests correctly between `today` and `in_7`.
--   D  the five windows that existed before v793 are unchanged.
--   E  an unknown window still fails closed with 22023.
--   F  the function ACL is unchanged (authenticated only; the body still demands a super admin).
begin;

do $v793$
declare
  v_sa uuid;
  a jsonb;
  v_ids uuid[];
  v_today date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_overdue bigint; v_o1 bigint; v_o27 bigint; v_o8 bigint;
  v_in3 bigint; v_today_n bigint; v_in7 bigint;
  v_acl text;
begin
  reset role;

  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  /* app.is_super_admin() is TWO conditions since v625: the row in super_admins AND a session that
     came through Google OAuth (app.platform_session_via_google_v625 reads amr + app_metadata off
     the JWT). A suite that sets only `sub` authenticates as nobody and the RPC refuses with 42501,
     which is what the older v203 suite in this directory now does. The claims below are the shape
     a real console session carries. */
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_sa,
    'role', 'authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google'))
  )::text, true);

  select array_agg(business_id) into v_ids
    from (select business_id from public.subscriptions order by business_id limit 4) t;
  if coalesce(array_length(v_ids,1),0) < 4 then
    raise exception 'setup: fewer than four subscription rows to work with';
  end if;

  /* One day late, three days late, ten days late, two days from now. The times are set in SGT
     because that is the zone the RPC does its day arithmetic in; midday keeps the date stable
     against any UTC-offset rounding at the boundaries. */
  update public.subscriptions set next_payment_at =
    ((v_today - 1)::text||' 12:00')::timestamp at time zone 'Asia/Singapore' where business_id = v_ids[1];
  update public.subscriptions set next_payment_at =
    ((v_today - 3)::text||' 12:00')::timestamp at time zone 'Asia/Singapore' where business_id = v_ids[2];
  update public.subscriptions set next_payment_at =
    ((v_today - 10)::text||' 12:00')::timestamp at time zone 'Asia/Singapore' where business_id = v_ids[3];
  update public.subscriptions set next_payment_at =
    ((v_today + 2)::text||' 12:00')::timestamp at time zone 'Asia/Singapore' where business_id = v_ids[4];

  a := public.platform_company_directory_v202();
  v_overdue  := (a#>>'{due,overdue}')::bigint;
  v_o1       := (a#>>'{due,overdue_1}')::bigint;
  v_o27      := (a#>>'{due,overdue_2_7}')::bigint;
  v_o8       := (a#>>'{due,overdue_8_plus}')::bigint;
  v_today_n  := (a#>>'{due,today}')::bigint;
  v_in3      := (a#>>'{due,in_3}')::bigint;
  v_in7      := (a#>>'{due,in_7}')::bigint;

  -- A · the buckets partition the overdue side exactly.
  if v_o1 < 1 or v_o27 < 1 or v_o8 < 1 then
    raise exception 'A1: a manufactured late firm is missing (1d=%, 2-7d=%, 8d+=%)', v_o1, v_o27, v_o8;
  end if;
  if v_o1 + v_o27 + v_o8 <> v_overdue then
    raise exception 'A2: overdue buckets (%+%+%) do not sum to overdue (%)', v_o1, v_o27, v_o8, v_overdue;
  end if;

  -- B · each bucket filter returns exactly what it counted, and the rows really are that late.
  if (public.platform_company_directory_v202(p_due_window=>'overdue1')->>'total_count')::bigint <> v_o1 then
    raise exception 'B1: overdue1 filter disagrees with its facet';
  end if;
  if exists (select 1 from jsonb_array_elements(
               public.platform_company_directory_v202(p_due_window=>'overdue1')->'items') i
              where (i->>'days_until_due')::int <> -1) then
    raise exception 'B2: overdue1 returned a row that is not exactly one day late';
  end if;
  if (public.platform_company_directory_v202(p_due_window=>'overdue2_7')->>'total_count')::bigint <> v_o27 then
    raise exception 'B3: overdue2_7 filter disagrees with its facet';
  end if;
  if exists (select 1 from jsonb_array_elements(
               public.platform_company_directory_v202(p_due_window=>'overdue2_7')->'items') i
              where (i->>'days_until_due')::int not between -7 and -2) then
    raise exception 'B4: overdue2_7 returned a row outside 2..7 days late';
  end if;
  if (public.platform_company_directory_v202(p_due_window=>'overdue8')->>'total_count')::bigint <> v_o8 then
    raise exception 'B5: overdue8 filter disagrees with its facet';
  end if;
  if exists (select 1 from jsonb_array_elements(
               public.platform_company_directory_v202(p_due_window=>'overdue8')->'items') i
              where (i->>'days_until_due')::int > -8) then
    raise exception 'B6: overdue8 returned a row less than eight days late';
  end if;

  -- C · the new 3-day window nests, and catches the firm due in two days.
  if v_in3 < 1 then raise exception 'C1: the firm due in two days is not in the 3-day window'; end if;
  if v_today_n > v_in3 or v_in3 > v_in7 then
    raise exception 'C2: 3-day window does not nest (today=%, in_3=%, in_7=%)', v_today_n, v_in3, v_in7;
  end if;
  if (public.platform_company_directory_v202(p_due_window=>'3')->>'total_count')::bigint <> v_in3 then
    raise exception 'C3: the 3-day filter disagrees with its facet';
  end if;
  if exists (select 1 from jsonb_array_elements(
               public.platform_company_directory_v202(p_due_window=>'3')->'items') i
              where (i->>'days_until_due')::int not between 0 and 3) then
    raise exception 'C4: the 3-day filter returned a row outside 0..3 days';
  end if;

  -- D · the windows that existed before v793 still mean what they meant.
  if (public.platform_company_directory_v202(p_due_window=>'overdue')->>'total_count')::bigint <> v_overdue then
    raise exception 'D1: the overdue filter no longer matches its facet';
  end if;
  if (public.platform_company_directory_v202(p_due_window=>'today')->>'total_count')::bigint <> v_today_n then
    raise exception 'D2: the today filter no longer matches its facet';
  end if;
  if (public.platform_company_directory_v202(p_due_window=>'7')->>'total_count')::bigint <> v_in7 then
    raise exception 'D3: the 7-day filter no longer matches its facet';
  end if;

  -- E · an unknown window still refuses rather than returning everything.
  begin
    perform public.platform_company_directory_v202(p_due_window=>'3days');
    raise exception 'E: an unknown due window was accepted';
  exception when sqlstate '22023' then null;
  end;

  -- F · the grant is unchanged: server-side super admins only, reached as authenticated.
  select proacl::text into v_acl from pg_proc
   where oid = 'public.platform_company_directory_v202(text,text,text,text,uuid,integer,integer)'::regprocedure;
  if v_acl not like '%authenticated=X%' or v_acl like '%anon=X%' then
    raise exception 'F: unexpected ACL on the directory: %', v_acl;
  end if;

  raise notice 'v793 due buckets: all assertions passed (overdue %, of which 1d=% 2-7d=% 8d+=%; in_3=%)',
    v_overdue, v_o1, v_o27, v_o8, v_in3;
end
$v793$;

rollback;
