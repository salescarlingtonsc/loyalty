-- EXECUTED acceptance fixture for nestly_v741
-- (db/migrations/20260902_nestly_v741_roster_read_audit.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v741_corpus --migrated-only
--
-- WHY THIS EXISTS. CI-100 checklist check 96 (privacy and small-cell protection). Refuter's
-- finding: public.get_customer_intelligence_v83 returns a full customer roster
-- (name/phone/email/spend) to three populations admitted by app.ci_access_gate_v667 -- the
-- firm's own staff, this firm's assigned platform consultant, or a super admin -- but unlike
-- platform_list_enterprise_customers_v82 (audited since nestly_v623, action
-- PLATFORM_PII_READ_V623) it wrote no audit_log row for a PLATFORM read: a consultant or super
-- admin reading another firm's full roster left no trace at all, identical silence to the
-- firm's own owner reading their own customers.
--
-- THE FIX (see the migration's own header for the full account): one INSERT, added
-- immediately before RETURN once v_result already carries the finished payload, firing only
-- when app.is_salon_member(p_business) is false -- the only way to reach that point without
-- being staff is via ci_access_gate_v667's platform arm (app.v176_can_read_firm_report: super
-- admin or assigned consultant). One row per call, action 'PLATFORM_ROSTER_READ_V741',
-- mirroring nestly_v623's audit_log column shape (business_id, actor, action, entity,
-- entity_id, detail -- detail, never meta, per nestly_v454).
--
-- SCENARIO. One firm (owner + one branch), one assigned consultant (via platform_consultants +
-- sme_prospects, the same shape nestly_v667/v721 use), one super admin (real Google-session
-- claims, per nestly_v625), one stranger with no relationship to the firm at all. Two real
-- clients with sales inside the query window, so customers[] and summary carry real content to
-- compare payload-for-payload across readers.
--
-- ASSERTIONS:
--   R1  Owner (staff, merchant arm) reads v83 successfully; audit_log gains ZERO
--       PLATFORM_ROSTER_READ_V741 rows for this business. Routine self-service read, not a
--       platform PII exposure.
--   R2  The assigned consultant (platform arm, no staff row) reads v83 successfully; audit_log
--       gains EXACTLY ONE PLATFORM_ROSTER_READ_V741 row, actor = the consultant, business_id =
--       the firm, detail.reader = 'assigned_consultant', detail.customers_returned and
--       detail.total_customers equal the payload's own pagination counts (2), detail.from/to
--       equal the call's window.
--   R3  A super admin with a real Google-session (app.is_super_admin() true) reads v83
--       successfully; audit_log gains EXACTLY ONE further PLATFORM_ROSTER_READ_V741 row, actor
--       = the super admin, detail.reader = 'super_admin'.
--   R4  A stranger (authenticated user with no staff row, no consultant assignment, not a super
--       admin) is refused 42501 by the pre-existing ci_access_gate_v667 gate; audit_log gains
--       ZERO further rows -- the gate raises before the function body (and its audit insert)
--       ever runs.
--   R5  PAYLOAD PARITY: the owner's read (R1) and the consultant's read (R2) for the identical
--       business/branch/window return byte-identical 'customers' arrays and 'summary' objects
--       (compared as jsonb, order-insensitive on customers by content equality) -- this
--       migration changes AUDITING, never what any reader sees.
--   R6  Total PLATFORM_ROSTER_READ_V741 row count for this business across the whole scenario is
--       exactly 2 (R2 + R3, no more, no fewer) -- proves neither the owner read nor the refused
--       stranger call silently added a row.
--
-- MUTATION CHECK (documented, not re-run here): removing the `if not app.is_salon_member(...)`
-- insert, or firing it unconditionally (including for staff), turns R1 or R6 red; swapping the
-- reader case branches turns R2/R3 red on detail.reader.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v741$
declare
  v_owner    uuid := '00000000-0000-4000-8000-000000741001';
  v_cons     uuid := '00000000-0000-4000-8000-000000741002';
  v_sa       uuid := '00000000-0000-4000-8000-000000741003';
  v_stranger uuid := '00000000-0000-4000-8000-000000741004';
  v_biz      uuid := gen_random_uuid();
  v_branch   uuid := gen_random_uuid();
  v_cons_id  uuid := gen_random_uuid();
  v_co_id    uuid := gen_random_uuid();
  v_today    date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_from     date := v_today - 20;
  v_to       date := v_today;

  v_cA uuid := gen_random_uuid();
  v_cB uuid := gen_random_uuid();

  g          jsonb;
  g_owner    jsonb;
  g_cons     jsonb;
  v_err      text;
  v_sqlstate text;
  v_rows     integer;
begin
  insert into auth.users (id, email) values
    (v_owner,    'zz-v741-owner@example.test'),
    (v_cons,     'zz-v741-cons@example.test'),
    (v_sa,       'zz-v741-sa@example.test'),
    (v_stranger, 'zz-v741-stranger@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (v_sa, 'zz-v741-sa@example.test') on conflict do nothing;

  ----------------------------------------------------------------------------------------------
  -- control rows: business, branch, staff, workspace/subscription, reporting contract.
  ----------------------------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, industry, enabled_modules)
  values (v_biz, 'ZZ v741 roster read audit', 'zz-v741-roster-read-audit', 'fnb',
          array['dashboard','clients','sales','reports','customerintel']);

  insert into public.branches (id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'ZZ v741 branch', true, true);

  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
  values (v_biz, v_owner, 'owner', 'ZZ v741 owner', true, 'approved');

  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (v_biz, 'approved', now(), 'v741 fixture')
  on conflict (business_id) do update
    set approval_status = 'approved', decided_at = now(), decision_reason = 'v741 fixture';

  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (v_biz, 'current', false)
  on conflict (business_id) do update set state = 'current', workspace_paused = false;

  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (v_biz, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update
    set status = 'active', payment_status = 'paid', current_period_end = now() + interval '30 days';

  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  values (v_biz, null,     2, '-infinity', 'Asia/Singapore', 'SGD', true),
         (v_biz, v_branch, 2, '-infinity', 'Asia/Singapore', 'SGD', true)
  on conflict do nothing;

  -- the assigned consultant for this firm, exactly the nestly_v667/v721 fixture shape.
  insert into public.platform_consultants
    (id, user_id, display_name, tier, employment_started_on, active)
  values (v_cons_id, v_cons, 'ZZ v741 consultant', 'senior', current_date - 400, true);
  insert into public.sme_companies (id, legal_name, trading_name)
  values (v_co_id, 'ZZ v741 Firm Pte Ltd', 'ZZ v741 Firm');
  insert into public.sme_prospects
    (company_id, legacy_stage_raw, assigned_consultant_id, ownership_state, queue_key,
     converted_business_id, converted_at, converted_by)
  values (v_co_id, 'zz-v741-fixture', v_cons_id, 'owned', null,
          v_biz, clock_timestamp(), v_sa);

  ----------------------------------------------------------------------------------------------
  -- 2 real clients, 2 sales, inside the query window.
  ----------------------------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name, is_synthetic) values
    (v_cA, v_biz, 'ZZ v741 real A', false),
    (v_cB, v_biz, 'ZZ v741 real B', false);

  alter table public.sales disable trigger user;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
    occurred_at, created_at, counts_as_revenue, counts_as_visit, earns_points,
    policy_resolved_at, commission_rate_bps, commission_resolved_at)
  select gen_random_uuid(), v_biz, v_branch, x.client_id, 'service', x.amount_cents,
         t.v_ts, t.v_ts, true, true, true, t.v_ts, 0, t.v_ts
    from (values
      (v_cA, 2, 5000::bigint),
      (v_cB, 4, 7000::bigint)
    ) as x(client_id, day_offset, amount_cents)
    cross join lateral (
      select ((v_from + x.day_offset)::timestamp + interval '12 hours')
               at time zone 'Asia/Singapore' as v_ts
    ) t;
  alter table public.sales enable trigger user;

  ----------------------------------------------------------------------------------------------
  -- PRECONDITIONS.
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  if not app.is_salon_member(v_biz) then
    insert into _fail values ('pre-owner', 'the owner fixture row is not a salon member -- R1/R5 would be vacuous');
  end if;
  if not app.can_module(v_biz, 'customerintel') then
    insert into _fail values ('pre-owner-module', 'the owner does not resolve customerintel');
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_cons, 'role', 'authenticated')::text, true);
  if app.is_salon_member(v_biz) then
    insert into _fail values ('pre-cons', 'the consultant unexpectedly resolves is_salon_member -- R2 would be vacuous (indistinguishable from a staff read)');
  end if;
  if not app.v176_can_read_firm_report(v_biz) then
    insert into _fail values ('pre-cons-2', 'the consultant does not resolve v176_can_read_firm_report -- the platform arm would refuse R2 before it could prove anything');
  end if;

  perform set_config('request.jwt.claims', json_build_object(
      'sub', v_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  if app.is_salon_member(v_biz) then
    insert into _fail values ('pre-sa', 'the super admin unexpectedly resolves is_salon_member -- R3 would be vacuous');
  end if;
  if not app.is_super_admin() then
    insert into _fail values ('pre-sa-2', 'the Google-session fixture user does not resolve is_super_admin() -- R3 would be vacuous');
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_stranger, 'role', 'authenticated')::text, true);
  if app.is_salon_member(v_biz) or app.v176_can_read_firm_report(v_biz) then
    insert into _fail values ('pre-stranger', 'the stranger unexpectedly resolves salon-member or platform-report access -- R4 would be vacuous');
  end if;

  select count(*) into v_rows from public.audit_log
   where business_id = v_biz and action = 'PLATFORM_ROSTER_READ_V741';
  if v_rows <> 0 then
    insert into _fail values ('pre-audit-empty',
      format('audit_log already carries %s PLATFORM_ROSTER_READ_V741 row(s) for this fresh business before any read happened', v_rows));
  end if;

  ----------------------------------------------------------------------------------------------
  -- R1 -- owner (staff) reads v83; audit_log gains no row.
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  begin
    g_owner := public.get_customer_intelligence_v83(v_biz, v_branch, v_from, v_to);
  exception when others then
    get stacked diagnostics v_err = message_text;
    insert into _fail values ('R1_owner_read', format('owner read raised: %s', v_err));
  end;
  select count(*) into v_rows from public.audit_log
   where business_id = v_biz and action = 'PLATFORM_ROSTER_READ_V741';
  if v_rows <> 0 then
    insert into _fail values ('R1_owner_no_audit',
      format('owner (staff) read wrote %s PLATFORM_ROSTER_READ_V741 row(s), expected 0', v_rows));
  end if;
  if g_owner is not null and (g_owner #>> '{pagination,returned_customers}')::int <> 2 then
    insert into _fail values ('R1_owner_roster_size',
      format('owner read returned_customers = %s (expected 2)', g_owner #>> '{pagination,returned_customers}'));
  end if;

  ----------------------------------------------------------------------------------------------
  -- R2 -- assigned consultant (platform arm) reads v83; exactly one audit row, reader =
  --       'assigned_consultant', counts and window match the payload.
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_cons, 'role', 'authenticated')::text, true);
  begin
    g_cons := public.get_customer_intelligence_v83(v_biz, v_branch, v_from, v_to);
  exception when others then
    get stacked diagnostics v_err = message_text;
    insert into _fail values ('R2_cons_read', format('consultant read raised: %s', v_err));
  end;

  select count(*) into v_rows from public.audit_log
   where business_id = v_biz and action = 'PLATFORM_ROSTER_READ_V741';
  if v_rows <> 1 then
    insert into _fail values ('R2_cons_audit_count',
      format('after the consultant read, audit_log carries %s PLATFORM_ROSTER_READ_V741 row(s) for this business, expected 1', v_rows));
  end if;

  if not exists (
    select 1 from public.audit_log
     where business_id = v_biz and action = 'PLATFORM_ROSTER_READ_V741'
       and actor = v_cons
       and entity = 'clients' and entity_id is null
       and detail->>'reader' = 'assigned_consultant'
       and (detail->>'branch_id')::uuid = v_branch
       and (detail->>'from')::date = v_from
       and (detail->>'to')::date = v_to
       and (detail->>'customers_returned')::int = 2
       and (detail->>'total_customers')::int = 2
  ) then
    insert into _fail values ('R2_cons_audit_shape',
      format('no PLATFORM_ROSTER_READ_V741 row matches the expected consultant shape; rows: %s',
        (select string_agg(row_to_json(a)::text, E'\n') from public.audit_log a
          where a.business_id = v_biz and a.action = 'PLATFORM_ROSTER_READ_V741')));
  end if;

  ----------------------------------------------------------------------------------------------
  -- R3 -- super admin (real Google session) reads v83; a second audit row, reader = 'super_admin'.
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', v_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  begin
    g := public.get_customer_intelligence_v83(v_biz, v_branch, v_from, v_to);
  exception when others then
    get stacked diagnostics v_err = message_text;
    insert into _fail values ('R3_sa_read', format('super admin read raised: %s', v_err));
  end;

  if not exists (
    select 1 from public.audit_log
     where business_id = v_biz and action = 'PLATFORM_ROSTER_READ_V741'
       and actor = v_sa
       and detail->>'reader' = 'super_admin'
       and (detail->>'customers_returned')::int = 2
  ) then
    insert into _fail values ('R3_sa_audit_shape',
      'no PLATFORM_ROSTER_READ_V741 row matches the expected super-admin shape');
  end if;

  ----------------------------------------------------------------------------------------------
  -- R4 -- a stranger with no relationship to the firm is refused 42501 by the pre-existing gate;
  --       no further audit row is written.
  ----------------------------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_stranger, 'role', 'authenticated')::text, true);
  begin
    g := public.get_customer_intelligence_v83(v_biz, v_branch, v_from, v_to);
    insert into _fail values ('R4_stranger_not_refused',
      'the stranger read succeeded instead of being refused 42501');
  exception when others then
    get stacked diagnostics v_sqlstate = returned_sqlstate;
    if v_sqlstate <> '42501' then
      insert into _fail values ('R4_stranger_wrong_sqlstate',
        format('stranger read raised %s, expected 42501', v_sqlstate));
    end if;
  end;

  ----------------------------------------------------------------------------------------------
  -- R5 -- payload parity: owner's and consultant's reads of the same window are byte-identical
  --       on customers[] and summary. This migration changes auditing, never what is returned.
  ----------------------------------------------------------------------------------------------
  if g_owner is not null and g_cons is not null then
    if (g_owner->'customers') <> (g_cons->'customers') then
      insert into _fail values ('R5_customers_mismatch',
        format('owner customers[] != consultant customers[]. owner=%s consultant=%s',
          g_owner->'customers', g_cons->'customers'));
    end if;
    if (g_owner->'summary') <> (g_cons->'summary') then
      insert into _fail values ('R5_summary_mismatch',
        format('owner summary != consultant summary. owner=%s consultant=%s',
          g_owner->'summary', g_cons->'summary'));
    end if;
  end if;

  ----------------------------------------------------------------------------------------------
  -- R6 -- total row count for this business across the whole scenario is exactly 2
  --       (R2 + R3 only -- the owner read and the refused stranger call added none).
  ----------------------------------------------------------------------------------------------
  select count(*) into v_rows from public.audit_log
   where business_id = v_biz and action = 'PLATFORM_ROSTER_READ_V741';
  if v_rows <> 2 then
    insert into _fail values ('R6_total_audit_rows',
      format('total PLATFORM_ROSTER_READ_V741 rows for this business = %s, expected exactly 2', v_rows));
  end if;

  perform set_config('request.jwt.claims', null, true);

  raise notice 'v741 | business_id=% | owner read: 0 audit rows | consultant read: +1 (reader=assigned_consultant) | super admin read: +1 (reader=super_admin) | stranger: 42501, +0 rows | total=2 | owner/consultant payloads identical',
    v_biz;
end
$v741$;

select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v741: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

select case when count(*) = 0
            then 'PASS — v741: get_customer_intelligence_v83 writes exactly one '
                 'PLATFORM_ROSTER_READ_V741 audit_log row per platform read (assigned '
                 'consultant, super admin), zero for the firm''s own staff, zero for a refused '
                 'stranger, and the roster payload is unchanged between a staff read and a '
                 'platform read of the same window'
            else 'FAIL' end as verdict,
       count(*) as failures
from _fail;

rollback;
