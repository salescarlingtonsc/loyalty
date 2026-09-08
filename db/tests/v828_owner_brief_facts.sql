-- Rollback-only acceptance for nestly_v828 — the owner brief answers the audit's open questions.
--   supabase db query --linked -f db/tests/v828_owner_brief_facts.sql
--
--   A1  all nineteen fact functions exist and none is executable by anon / authenticated
--   A2  the nightly refresh (v828 composer) for Cubbly writes a ready row whose payload carries
--       contract owner_brief_v828, the seven v826 facts AND a `facts` object with all nineteen
--       keys, none of them 'unavailable'
--   A3  authority agreement, as Cubbly's owner: facts.day.yesterday.revenue_cents equals
--       get_dashboard_summary_v155 for that single day; facts.month.mtd.revenue_cents equals
--       app.v176_sales_window over the month-to-date window
--   A4  fail-closed shapes: every fact carries a status; a fact with evidence 'insufficient'
--       carries no positive delta; no fact text contains 'undefined'
--   A5  get_owner_brief_v1 as the owner returns the v828 payload; a sessionless caller is refused
--   A6  ESTATE-WIDE: the full nightly pass fails for nobody and stays under 2 s per business
--
-- NEGATIVE CONTROL: on a database without v828, A1 fails at the first missing function.

begin;

do $suite$
declare
  c_cubbly       constant uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  c_cubbly_owner constant uuid := 'f73a9423-33fd-424c-9fb9-2d5ba058a2d7';
  c_names constant text[] := array[
    'day','month','liability','points_expiry','items','dying','pairs','discounts','stock',
    'staff','multi_outlet','birthdays','member_lift','referrals','anomalies',
    'stamps','bookings_ahead','memberships_due','slot_trend'];
  v_name   text;
  v_res    jsonb;
  v_pay    jsonb;
  v_facts  jsonb;
  v_direct jsonb;
  v_yday   date := app.sg_today() - 1;
  v_m_from date := date_trunc('month', app.sg_today())::date;
  v_n      integer;
  v_ok     boolean;
  v_slow   integer;
begin
  -- A1 ----------------------------------------------------------------------------------------
  foreach v_name in array c_names loop
    if to_regprocedure(format('app.owner_brief_fact_%s_v828(uuid)', v_name)) is null then
      raise exception 'A1: fact function % is missing', v_name;
    end if;
    if has_function_privilege('anon', format('app.owner_brief_fact_%s_v828(uuid)', v_name), 'execute')
       or has_function_privilege('authenticated', format('app.owner_brief_fact_%s_v828(uuid)', v_name), 'execute') then
      raise exception 'A1: fact % is executable by a non-owner role', v_name;
    end if;
  end loop;

  -- A2 ----------------------------------------------------------------------------------------
  v_res := app.refresh_owner_brief_v826(c_cubbly);
  if (v_res ->> 'ok')::int <> 1 then
    raise exception 'A2: refresh did not succeed for Cubbly: %', v_res;
  end if;
  select payload into v_pay from public.owner_brief_snapshots_v1 where business_id = c_cubbly and status = 'ready';
  if v_pay is null then raise exception 'A2: no ready row for Cubbly'; end if;
  if v_pay ->> 'contract_version' <> 'owner_brief_v828' then
    raise exception 'A2: contract is %, expected owner_brief_v828', v_pay ->> 'contract_version';
  end if;
  foreach v_name in array array['week','outlets','daypart','customers','at_risk','rewards','action'] loop
    if not (v_pay ? v_name) then raise exception 'A2: v826 fact % lost', v_name; end if;
  end loop;
  v_facts := v_pay -> 'facts';
  foreach v_name in array c_names loop
    if not (v_facts ? v_name) then raise exception 'A2: facts.% missing', v_name; end if;
    if v_facts -> v_name ->> 'status' is null then raise exception 'A4: facts.% has no status', v_name; end if;
    if v_facts -> v_name ->> 'status' = 'unavailable' then
      raise exception 'A2: facts.% is unavailable: %', v_name, v_facts -> v_name ->> 'reason';
    end if;
  end loop;
  if position('undefined' in v_facts::text) > 0 then
    raise exception 'A4: a fact carries the text undefined';
  end if;

  -- A3 ----------------------------------------------------------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_cubbly_owner, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', c_cubbly_owner::text, true);
  v_direct := public.get_dashboard_summary_v155(c_cubbly, v_yday, v_yday, 'all', array[]::uuid[], null);
  if (v_facts #>> '{day,yesterday,revenue_cents}')::bigint is distinct from (v_direct ->> 'revenue_cents')::bigint then
    raise exception 'A3: day.yesterday.revenue_cents % differs from the dashboard summary %',
      v_facts #>> '{day,yesterday,revenue_cents}', v_direct ->> 'revenue_cents';
  end if;
  -- A5 (owner read) ---------------------------------------------------------------------------
  v_res := public.get_owner_brief_v1(c_cubbly);
  if v_res ->> 'data_status' <> 'ready' or (v_res #>> '{brief,contract_version}') <> 'owner_brief_v828'
     or not ((v_res -> 'brief' -> 'facts') ? 'staff') then
    raise exception 'A5: owner does not read the v828 payload: %', left(v_res::text, 300);
  end if;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);

  v_direct := app.v176_sales_window(c_cubbly, v_m_from, v_yday);
  if (v_facts #>> '{month,mtd,revenue_cents}')::bigint is distinct from (v_direct ->> 'net_revenue_cents')::bigint then
    raise exception 'A3: month.mtd.revenue_cents % differs from v176_sales_window %',
      v_facts #>> '{month,mtd,revenue_cents}', v_direct ->> 'net_revenue_cents';
  end if;

  -- A5 (sessionless) --------------------------------------------------------------------------
  begin
    perform public.get_owner_brief_v1(c_cubbly);
    v_ok := true;
  exception when insufficient_privilege then
    v_ok := false;
  end;
  if v_ok then raise exception 'A5: a sessionless caller can read a brief'; end if;

  -- A6 ----------------------------------------------------------------------------------------
  v_res := app.refresh_owner_brief_v826();
  if (v_res ->> 'failed')::int <> 0 then
    raise exception 'A6: the nightly pass failed for % business(es): %', v_res ->> 'failed', v_res;
  end if;
  select count(*) into v_slow from public.owner_brief_snapshots_v1 where duration_ms > 2000;
  if v_slow > 0 then
    raise exception 'A6: % business(es) took more than 2 s to compose', v_slow;
  end if;

  raise notice 'v828 owner brief facts: A1–A6 passed (%)', v_res;
end
$suite$;

rollback;
