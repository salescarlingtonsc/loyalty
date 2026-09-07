-- EXECUTED acceptance fixture for nestly_v817
-- (db/migrations/20261007_nestly_v817_one_ci_gate_completion.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --migrated-only --filter=v817
--
-- WHY THIS EXISTS. nestly_v721 moved public.get_customer_intelligence_v83 onto the single shared
-- Customer Intelligence gate, app.ci_access_gate_v667, but left three sibling entry points with
-- their own private, merchant-only guard: public.create_customer_intelligence_export_v83,
-- public.get_customer_intelligence_export_page_v83 and public.get_revenue_truth_v106. nestly_v817
-- converts all three. The owner ruling behind it: converting them deliberately admits the
-- platform arm (super admin, assigned consultant) to those three as well — that is the intended
-- behaviour change, not a side effect.
--
-- ASSERTIONS (rows, with a fatal gate at the end):
--   T1-T3  An entitled owner (customerintel + view_finance, operational workspace) is SERVED by
--          all three converted functions on their own firm.
--   T4-T6  The SAME shape of owner, but on a firm with the customerintel module OFF, is REFUSED
--          42501 by all three.
--   T7-T9  A real-session super admin (platform arm) is SERVED by all three on the MODULE-OFF
--          firm — proving the platform arm bypasses merchant entitlement entirely, which is the
--          whole point of the conversion.
--   T10-T12  A staff member of an UNRELATED firm (holding full customerintel entitlement on
--          their OWN business, so the refusal below is tenant isolation, not an under-privileged
--          fixture) is REFUSED 42501 when asked to read the entitled firm's data through all
--          three functions.
--
-- Every assertion is recorded as a row; the final gate makes any FAIL fatal. Rolled back.
--
-- ROLE DISCIPLINE: pg_temp.v817_note always runs AFTER pg_temp.v817_as_system() has reset the
-- session back off `authenticated` — the temp table this fixture records into is owned by the
-- connecting (superuser) role and was never GRANTed to authenticated, on purpose, so a check
-- computed under an actor session is captured into a plpgsql variable FIRST and only recorded
-- once the role is reset. Recording while still impersonating an actor is a permission error,
-- not a silent pass — found by running this file, not reasoned about in the abstract.
begin;

create temp table v817_out(seq integer, step text, outcome text, detail text) on commit drop;

create or replace function pg_temp.v817_note(
  p_seq integer, p_step text, p_ok boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into v817_out values (p_seq, p_step, case when p_ok then 'PASS' else 'FAIL' end, p_detail);
end
$$;
grant execute on function pg_temp.v817_note(integer,text,boolean,text) to authenticated;

create or replace function pg_temp.v817_as_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.v817_as_system() to authenticated;

create or replace function pg_temp.v817_as_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','authenticated','aud','authenticated')::text, true);
end
$$;
grant execute on function pg_temp.v817_as_user(uuid) to authenticated;

-- A real platform session: the Google-OAuth claim shape app.is_super_admin() (nestly_v625)
-- requires, not merely a bare claim set.
create or replace function pg_temp.v817_as_super_admin(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object(
      'sub', p_uid, 'role','authenticated', 'aud','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
end
$$;
grant execute on function pg_temp.v817_as_super_admin(uuid) to authenticated;

do $v817_test$
declare
  v_now date := current_date;

  biz_on    uuid := '00000000-0000-4000-8000-000000817001'; -- entitled firm
  biz_off   uuid := '00000000-0000-4000-8000-000000817002'; -- customerintel OFF
  biz_other uuid := '00000000-0000-4000-8000-000000817003'; -- unrelated firm

  u_owner_on    uuid := '00000000-0000-4000-8000-000000817101';
  u_owner_off   uuid := '00000000-0000-4000-8000-000000817102';
  u_staff_other uuid := '00000000-0000-4000-8000-000000817103';
  u_sa          uuid := '00000000-0000-4000-8000-000000817104';

  v_export      uuid;
  v_export_off  uuid := '00000000-0000-4000-8000-000000817201';
  v_export_iso  uuid := '00000000-0000-4000-8000-000000817202';
  v_export_sa   uuid;

  v_res         jsonb;
  v_ok          boolean;
  v_sqlstate    text;
begin
  perform pg_temp.v817_as_system();

  ---------------------------------------------------------------------------------------------
  -- FIXTURE — three firms, the "genuinely operational" recipe (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md):
  -- approved workspace + active paid subscription + a staff row, or every read below refuses for
  -- a billing/approval reason rather than the entitlement reason under test.
  ---------------------------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_owner_on, 'zz-v817-owner-on@example.test'),
    (u_owner_off, 'zz-v817-owner-off@example.test'),
    (u_staff_other, 'zz-v817-staff-other@example.test'),
    (u_sa, 'zz-v817-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (u_sa, 'zz-v817-sa@example.test') on conflict do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz_on, 'ZZ v817 firm ON', 'zz-v817-on',
      array['dashboard','clients','sales','reports','customerintel']),
    (biz_off, 'ZZ v817 firm OFF', 'zz-v817-off',
      array['dashboard','clients','sales','reports']),
    (biz_other, 'ZZ v817 firm OTHER', 'zz-v817-other',
      array['dashboard','clients','sales','reports','customerintel']);

  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz_on, u_owner_on, 'owner', 'ZZ v817 owner ON', true, 'approved'),
    (biz_off, u_owner_off, 'owner', 'ZZ v817 owner OFF', true, 'approved'),
    (biz_other, u_staff_other, 'owner', 'ZZ v817 owner OTHER', true, 'approved');

  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  select b, 'approved', now(), 'v817 one-ci-gate-completion fixture'
    from unnest(array[biz_on, biz_off, biz_other]) b
  on conflict (business_id) do update
    set approval_status='approved', decided_at=now(),
        decision_reason='v817 one-ci-gate-completion fixture';
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  select b, 'current', false from unnest(array[biz_on, biz_off, biz_other]) b
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  select b, 'active', 'paid', now() + interval '30 days'
    from unnest(array[biz_on, biz_off, biz_other]) b
  on conflict (business_id) do update
    set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  ---------------------------------------------------------------------------------------------
  -- PRECONDITIONS — non-vacuity. If any of these is false, the assertion it feeds would pass or
  -- fail for the wrong reason.
  ---------------------------------------------------------------------------------------------
  perform pg_temp.v817_as_user(u_owner_on);
  v_ok := app.can_module(biz_on,'customerintel') and app.has_perm(biz_on,'view_finance');
  perform pg_temp.v817_as_system();
  perform pg_temp.v817_note(0, 'PRE owner_on genuinely holds customerintel + view_finance', v_ok);

  perform pg_temp.v817_as_user(u_owner_off);
  v_ok := app.has_perm(biz_off,'view_finance') and not app.can_module(biz_off,'customerintel');
  perform pg_temp.v817_as_system();
  perform pg_temp.v817_note(1, 'PRE owner_off holds view_finance but NOT customerintel '
    '(module-off is genuinely the module, not a role gap)', v_ok);

  perform pg_temp.v817_as_user(u_staff_other);
  v_ok := app.can_module(biz_other,'customerintel') and app.has_perm(biz_other,'view_finance');
  perform pg_temp.v817_as_system();
  perform pg_temp.v817_note(2, 'PRE staff_other genuinely holds customerintel on THEIR OWN firm '
    '(so the T10-T12 refusal below is tenant isolation, not an under-privileged fixture)', v_ok);

  perform pg_temp.v817_as_super_admin(u_sa);
  v_ok := app.is_super_admin();
  perform pg_temp.v817_as_system();
  perform pg_temp.v817_note(3, 'PRE the fixture super admin genuinely resolves is_super_admin()', v_ok);

  ---------------------------------------------------------------------------------------------
  -- T1-T3 — entitled owner, own firm, all three functions: SERVED.
  ---------------------------------------------------------------------------------------------
  perform pg_temp.v817_as_user(u_owner_on);
  v_res := null; v_sqlstate := null; v_export := null;
  begin
    v_res := public.create_customer_intelligence_export_v83(biz_on, null, v_now-30, v_now);
    v_export := (v_res->>'export_id')::uuid;
  exception when others then
    v_sqlstate := sqlstate;
  end;
  perform pg_temp.v817_as_system();
  perform pg_temp.v817_note(4, 'T1 entitled owner: create_customer_intelligence_export_v83 served',
    v_res is not null and v_export is not null, 'sqlstate='||coalesce(v_sqlstate,'<served>'));

  perform pg_temp.v817_as_user(u_owner_on);
  v_res := null; v_sqlstate := null;
  if v_export is not null then
    begin
      v_res := public.get_customer_intelligence_export_page_v83(v_export, 0, 500);
    exception when others then
      v_sqlstate := sqlstate;
    end;
  end if;
  perform pg_temp.v817_as_system();
  perform pg_temp.v817_note(5, 'T2 entitled owner: get_customer_intelligence_export_page_v83 served',
    v_res is not null, 'sqlstate='||coalesce(v_sqlstate,'<served>'));

  perform pg_temp.v817_as_user(u_owner_on);
  v_res := null; v_sqlstate := null;
  begin
    v_res := public.get_revenue_truth_v106(biz_on, v_now-30, v_now, null);
  exception when others then
    v_sqlstate := sqlstate;
  end;
  perform pg_temp.v817_as_system();
  perform pg_temp.v817_note(6, 'T3 entitled owner: get_revenue_truth_v106 served',
    v_res is not null and (v_res ? 'status'), 'sqlstate='||coalesce(v_sqlstate,'<served>'));

  ---------------------------------------------------------------------------------------------
  -- T4-T6 — same shape of owner, module OFF: REFUSED 42501 by all three.
  ---------------------------------------------------------------------------------------------
  perform pg_temp.v817_as_user(u_owner_off);
  v_sqlstate := null;
  begin
    perform public.create_customer_intelligence_export_v83(biz_off, null, v_now-30, v_now);
  exception when others then
    v_sqlstate := sqlstate;
  end;
  perform pg_temp.v817_as_system();
  perform pg_temp.v817_note(7, 'T4 module-OFF owner: create_customer_intelligence_export_v83 refused 42501',
    v_sqlstate = '42501', 'sqlstate='||coalesce(v_sqlstate,'<served>'));

  perform pg_temp.v817_as_user(u_owner_off);
  v_sqlstate := null;
  begin
    perform public.get_revenue_truth_v106(biz_off, v_now-30, v_now, null);
  exception when others then
    v_sqlstate := sqlstate;
  end;
  perform pg_temp.v817_as_system();
  perform pg_temp.v817_note(8, 'T5 module-OFF owner: get_revenue_truth_v106 refused 42501',
    v_sqlstate = '42501', 'sqlstate='||coalesce(v_sqlstate,'<served>'));

  -- get_customer_intelligence_export_page_v83 derives its entitlement from the EXPORT ROW's own
  -- business_id, and T4 already proved the owner cannot create one on biz_off — so an export row
  -- is seeded directly (bypassing the create RPC) to isolate this function's own gate.
  insert into public.customer_intelligence_exports_v83
    (id, business_id, branch_id, requested_by, from_date, to_date, snapshot_at, expires_at,
     scope, methodology, data_quality, summary, forecast, total_customers)
  values
    (v_export_off, biz_off, null, u_owner_off, v_now-30, v_now, clock_timestamp(),
     clock_timestamp() + interval '24 hours', '{}'::jsonb, '{}'::jsonb, '{}'::jsonb, '{}'::jsonb,
     '{}'::jsonb, 0);
  perform pg_temp.v817_as_user(u_owner_off);
  v_sqlstate := null;
  begin
    perform public.get_customer_intelligence_export_page_v83(v_export_off, 0, 500);
  exception when others then
    v_sqlstate := sqlstate;
  end;
  perform pg_temp.v817_as_system();
  perform pg_temp.v817_note(9, 'T6 module-OFF owner: get_customer_intelligence_export_page_v83 refused 42501',
    v_sqlstate = '42501', 'sqlstate='||coalesce(v_sqlstate,'<served>'));

  ---------------------------------------------------------------------------------------------
  -- T7-T9 — real-session super admin, on the MODULE-OFF firm: SERVED by all three. This is the
  -- behaviour nestly_v817 exists to add: the platform arm bypasses merchant entitlement entirely,
  -- module state included.
  ---------------------------------------------------------------------------------------------
  perform pg_temp.v817_as_super_admin(u_sa);
  v_res := null; v_sqlstate := null; v_export_sa := null;
  begin
    v_res := public.create_customer_intelligence_export_v83(biz_off, null, v_now-30, v_now);
    v_export_sa := (v_res->>'export_id')::uuid;
  exception when others then
    v_sqlstate := sqlstate;
  end;
  perform pg_temp.v817_as_system();
  perform pg_temp.v817_note(10, 'T7 super admin: create_customer_intelligence_export_v83 served on module-OFF firm',
    v_res is not null and v_export_sa is not null, 'sqlstate='||coalesce(v_sqlstate,'<served>'));

  perform pg_temp.v817_as_super_admin(u_sa);
  v_res := null; v_sqlstate := null;
  if v_export_sa is not null then
    begin
      v_res := public.get_customer_intelligence_export_page_v83(v_export_sa, 0, 500);
    exception when others then
      v_sqlstate := sqlstate;
    end;
  end if;
  perform pg_temp.v817_as_system();
  perform pg_temp.v817_note(11, 'T8 super admin: get_customer_intelligence_export_page_v83 served on module-OFF firm',
    v_res is not null, 'sqlstate='||coalesce(v_sqlstate,'<served>'));

  perform pg_temp.v817_as_super_admin(u_sa);
  v_res := null; v_sqlstate := null;
  begin
    v_res := public.get_revenue_truth_v106(biz_off, v_now-30, v_now, null);
  exception when others then
    v_sqlstate := sqlstate;
  end;
  perform pg_temp.v817_as_system();
  perform pg_temp.v817_note(12, 'T9 super admin: get_revenue_truth_v106 served on module-OFF firm',
    v_res is not null and (v_res ? 'status'), 'sqlstate='||coalesce(v_sqlstate,'<served>'));

  ---------------------------------------------------------------------------------------------
  -- T10-T12 — a staff member of an UNRELATED firm, fully entitled on THEIR OWN business (see
  -- PRE above), asked to read the ENTITLED firm's data: REFUSED 42501 by all three. Tenant
  -- isolation, not a generic under-privileged fixture.
  ---------------------------------------------------------------------------------------------
  perform pg_temp.v817_as_user(u_staff_other);
  v_sqlstate := null;
  begin
    perform public.create_customer_intelligence_export_v83(biz_on, null, v_now-30, v_now);
  exception when others then
    v_sqlstate := sqlstate;
  end;
  perform pg_temp.v817_as_system();
  perform pg_temp.v817_note(13, 'T10 unrelated staff: create_customer_intelligence_export_v83 refused 42501 on a foreign firm',
    v_sqlstate = '42501', 'sqlstate='||coalesce(v_sqlstate,'<served>'));

  perform pg_temp.v817_as_user(u_staff_other);
  v_sqlstate := null;
  begin
    perform public.get_revenue_truth_v106(biz_on, v_now-30, v_now, null);
  exception when others then
    v_sqlstate := sqlstate;
  end;
  perform pg_temp.v817_as_system();
  perform pg_temp.v817_note(14, 'T11 unrelated staff: get_revenue_truth_v106 refused 42501 on a foreign firm',
    v_sqlstate = '42501', 'sqlstate='||coalesce(v_sqlstate,'<served>'));

  -- Seed an export row OWNED by staff_other but scoped to the foreign firm biz_on, so the
  -- requested_by=v_actor check passes and the assertion isolates THIS function's own
  -- entitlement gate (not the "export not found" branch).
  insert into public.customer_intelligence_exports_v83
    (id, business_id, branch_id, requested_by, from_date, to_date, snapshot_at, expires_at,
     scope, methodology, data_quality, summary, forecast, total_customers)
  values
    (v_export_iso, biz_on, null, u_staff_other, v_now-30, v_now, clock_timestamp(),
     clock_timestamp() + interval '24 hours', '{}'::jsonb, '{}'::jsonb, '{}'::jsonb, '{}'::jsonb,
     '{}'::jsonb, 0);
  perform pg_temp.v817_as_user(u_staff_other);
  v_sqlstate := null;
  begin
    perform public.get_customer_intelligence_export_page_v83(v_export_iso, 0, 500);
  exception when others then
    v_sqlstate := sqlstate;
  end;
  perform pg_temp.v817_as_system();
  perform pg_temp.v817_note(15, 'T12 unrelated staff: get_customer_intelligence_export_page_v83 refused 42501 on a foreign firm',
    v_sqlstate = '42501', 'sqlstate='||coalesce(v_sqlstate,'<served>'));
end
$v817_test$;

select seq, step, outcome, detail from v817_out order by seq;

do $gate$
declare v_failed integer;
begin
  select count(*) into v_failed from v817_out where outcome <> 'PASS';
  if v_failed > 0 then
    raise exception 'nestly_v817 acceptance: % assertion(s) FAILED', v_failed;
  end if;
end
$gate$;

rollback;
