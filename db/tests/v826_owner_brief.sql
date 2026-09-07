-- Rollback-only acceptance for nestly_v826 — the owner brief is computed nightly and read as one row.
--   supabase db query --linked -f db/tests/v826_owner_brief.sql
--
-- Every figure in the brief is compared with the reader the owner already sees on screen,
-- called directly AS THAT OWNER. Nothing here reads a function's source text.
--
--   A1  the snapshot table is unreadable through the API (anon, authenticated)
--   A2  the nightly refresh, run for ÉLAN alone, writes one 'ready' row dated yesterday
--   A3  as ÉLAN's owner, get_owner_brief_v1 answers 'ready' and its week revenue, visits,
--       busiest weekday and reward totals equal the underlying readers called directly
--   A4  Cubbly's owner cannot read ÉLAN's brief (42501); a sessionless caller cannot either
--   A5  a row older than 30 hours reads as 'stale' (brief still returned); an 'error' row reads
--       as 'error' with no brief; no row reads as 'not_computed'
--   A6  ESTATE-WIDE: the full nightly pass fails for nobody, and every business with a sale in
--       the last 30 days and an owner login gets a row
--   A7  the nightly job is scheduled at the agreed slot, after the 19:xx–20:15 sweeps
--   A8  the refresh restores the caller's claims (no owner identity leaks past the loop)
--
-- NEGATIVE CONTROL: on a database without v826, A1 fails at once (relation does not exist).

begin;

do $suite$
declare
  c_elan        constant uuid := '8ccace3a-9736-447e-bb1e-da842622592d';  -- ÉLAN Wellness
  c_elan_owner  constant uuid := '8efcffc8-61a5-4235-ad45-54a8954208f9';
  c_cubbly      constant uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';  -- Cubbly SPA
  c_cubbly_owner constant uuid := 'f73a9423-33fd-424c-9fb9-2d5ba058a2d7';
  v_res   jsonb;
  v_brief jsonb;
  v_direct jsonb;
  v_day   jsonb;
  v_rew   jsonb;
  v_from  date := app.sg_today() - 7;
  v_to    date := app.sg_today() - 1;
  v_bfrom date := app.sg_today() - 63;   -- computed here, as postgres: app.sg_today() is owner-only
  v_n     integer;
  v_missing integer;
  v_ok    boolean;
begin
  -- A1 ----------------------------------------------------------------------------------------
  if has_table_privilege('anon', 'public.owner_brief_snapshots_v1', 'select')
     or has_table_privilege('authenticated', 'public.owner_brief_snapshots_v1', 'select') then
    raise exception 'A1: owner_brief_snapshots_v1 is readable through the API';
  end if;

  -- A2 ----------------------------------------------------------------------------------------
  v_res := app.refresh_owner_brief_v826(c_elan);
  if (v_res ->> 'ok')::int <> 1 or (v_res ->> 'failed')::int <> 0 then
    raise exception 'A2: refresh for one business did not succeed: %', v_res;
  end if;
  select count(*) into v_n from public.owner_brief_snapshots_v1
   where business_id = c_elan and status = 'ready' and as_of = app.sg_today() - 1;
  if v_n <> 1 then
    raise exception 'A2: expected one ready row dated yesterday for ÉLAN, found %', v_n;
  end if;

  -- A8 (claims restored before anyone else reads) ---------------------------------------------
  if auth.uid() is not null then
    raise exception 'A8: the refresh left an owner identity behind: %', auth.uid();
  end if;

  -- A3 ----------------------------------------------------------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_elan_owner, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', c_elan_owner::text, true);

  v_res := public.get_owner_brief_v1(c_elan);
  if v_res ->> 'data_status' <> 'ready' then
    raise exception 'A3: owner reads data_status % not ready', v_res ->> 'data_status';
  end if;
  v_brief := v_res -> 'brief';
  if v_brief ->> 'contract_version' <> 'owner_brief_v826' then
    raise exception 'A3: wrong contract %', v_brief ->> 'contract_version';
  end if;

  v_direct := public.get_dashboard_summary_v155(c_elan, v_from, v_to, 'all', array[]::uuid[], null);
  if (v_brief #>> '{week,revenue_cents}')::bigint is distinct from (v_direct ->> 'revenue_cents')::bigint
     or (v_brief #>> '{week,visits}')::bigint is distinct from (v_direct ->> 'visits')::bigint then
    raise exception 'A3: week revenue/visits % / % differ from the dashboard summary % / %',
      v_brief #>> '{week,revenue_cents}', v_brief #>> '{week,visits}',
      v_direct ->> 'revenue_cents', v_direct ->> 'visits';
  end if;

  v_day := public.get_ci_daypart_v1(c_elan, v_bfrom, v_to, null, now());
  if (v_brief #> '{daypart,busiest_weekday}') is distinct from (v_day -> 'busiest_weekday') then
    raise exception 'A3: busiest weekday % differs from the daypart reader %',
      v_brief #> '{daypart,busiest_weekday}', v_day -> 'busiest_weekday';
  end if;

  v_rew := public.get_ci_reward_popularity_v1(c_elan, v_bfrom, v_to, null, now());
  if (v_brief #>> '{rewards,redemptions}')::int is distinct from (v_rew #>> '{totals,redemptions}')::int then
    raise exception 'A3: reward redemptions % differ from the popularity reader %',
      v_brief #>> '{rewards,redemptions}', v_rew #>> '{totals,redemptions}';
  end if;

  -- A4 ----------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', c_cubbly_owner, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', c_cubbly_owner::text, true);
  begin
    perform public.get_owner_brief_v1(c_elan);
    v_ok := true;
  exception when insufficient_privilege then
    v_ok := false;
  end;
  if v_ok then
    raise exception 'A4: Cubbly''s owner can read ÉLAN''s brief';
  end if;

  reset role;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    perform public.get_owner_brief_v1(c_elan);
    v_ok := true;
  exception when insufficient_privilege then
    v_ok := false;
  end;
  if v_ok then
    raise exception 'A4: a sessionless caller can read a brief';
  end if;

  -- A5 ----------------------------------------------------------------------------------------
  update public.owner_brief_snapshots_v1 set computed_at = now() - interval '31 hours' where business_id = c_elan;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_elan_owner, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', c_elan_owner::text, true);
  v_res := public.get_owner_brief_v1(c_elan);
  if v_res ->> 'data_status' <> 'stale' or v_res -> 'brief' is null or jsonb_typeof(v_res -> 'brief') = 'null' then
    raise exception 'A5: a 31-hour-old row should read stale with its brief, got %', v_res ->> 'data_status';
  end if;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);

  update public.owner_brief_snapshots_v1 set status = 'error', payload = '{}'::jsonb, error = 'test' where business_id = c_elan;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_elan_owner, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', c_elan_owner::text, true);
  v_res := public.get_owner_brief_v1(c_elan);
  if v_res ->> 'data_status' <> 'error' or jsonb_typeof(v_res -> 'brief') <> 'null' then
    raise exception 'A5: an error row should read error with no brief, got % / %', v_res ->> 'data_status', v_res -> 'brief';
  end if;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);

  delete from public.owner_brief_snapshots_v1 where business_id = c_elan;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_elan_owner, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', c_elan_owner::text, true);
  v_res := public.get_owner_brief_v1(c_elan);
  if v_res ->> 'data_status' <> 'not_computed' then
    raise exception 'A5: no row should read not_computed, got %', v_res ->> 'data_status';
  end if;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);

  -- A6 ----------------------------------------------------------------------------------------
  v_res := app.refresh_owner_brief_v826();
  if (v_res ->> 'failed')::int <> 0 then
    raise exception 'A6: the nightly pass failed for % business(es): %', v_res ->> 'failed', v_res;
  end if;
  select count(*) into v_missing
    from public.businesses b
   where exists (select 1 from public.sales sl where sl.business_id = b.id and sl.created_at > now() - interval '30 days')
     and exists (select 1 from public.staff s where s.business_id = b.id and s.role = 'owner' and s.active and s.user_id is not null)
     and not exists (select 1 from public.owner_brief_snapshots_v1 o where o.business_id = b.id and o.status = 'ready');
  if v_missing <> 0 then
    raise exception 'A6: % active business(es) with an owner have no ready brief', v_missing;
  end if;

  -- A7 ----------------------------------------------------------------------------------------
  if not exists (select 1 from cron.job where jobname = 'nestly-v826-owner-brief' and schedule = '40 20 * * *') then
    raise exception 'A7: nestly-v826-owner-brief is not scheduled at 20:40 UTC';
  end if;

  raise notice 'v826 owner brief: A1–A8 passed (%)', v_res;
end
$suite$;

rollback;
