-- EXECUTED regression fixture for nestly_v725 — time basis on the three Customer Intelligence
-- readers check 35/13 left uncovered by nestly_v717, and the shared-gate + platform-diagnostic
-- tightening for get_ci_shadow_reconciliation_v685 (check 91 continuation).
--
-- WHY. The refuter's follow-up findings against the live engine:
--
--   (35/13) public.get_customer_intelligence_v83 and public.get_ci_category_customers_v1 carry
--           no `time_basis` key at all (nestly_v717 covered five other CI readers, not these
--           two). Both bucket on sales.occurred_at (confirmed by reading the live body, not
--           guessed) -> 'sale_occurred_at'. get_ci_shadow_reconciliation_v685 has no bucketing
--           window at all, but DOES have a real, meaningful timestamp column
--           (app.ci_shadow_runs_v685.captured_at) -> 'captured_at', not the 'not_applicable'
--           branch. get_ci_dictionary_v1 is exempt (static metric catalogue, no time dimension
--           anywhere in its payload) — recorded in nestly_v725's own header, not tested here as
--           a defect (there is nothing to assert against a function with no time_basis key by
--           design).
--   (91)    get_ci_shadow_reconciliation_v685 carried only its own inline app.is_super_admin()
--           gate, not the shared app.ci_access_gate_v667 every sibling CI reader defers to.
--           Fixed additively: the shared gate now runs FIRST (uniform refusal wording for a
--           caller with no CI access at all), then app.is_super_admin() remains a SECOND,
--           narrower condition — this is an SA-only ops diagnostic, so the shared gate's
--           platform arm (which would admit the firm's assigned consultant) is deliberately not
--           sufficient on its own.
--
-- T-SERIES — time_basis lands on the right key with the right value:
--   T1  get_customer_intelligence_v83's payload carries a top-level 'time_basis' =
--       'sale_occurred_at'.
--   T2  get_ci_category_customers_v1's payload (the normal, non-suppressed path — the fixture
--       has zero category sales, so v_count=0 does not satisfy "> 0 and < floor") carries a
--       top-level 'time_basis' = 'sale_occurred_at'.
--   T3  get_ci_shadow_reconciliation_v685's payload carries a top-level 'time_basis' =
--       'captured_at'.
--
-- S-SERIES — the shadow reader's two-armed gate (shared authority first, is_super_admin last):
--   S1  A fully entitled firm owner (customerintel + view_finance — the SAME merchant arm that
--       passes every other CI reader through the shared gate) is REFUSED reading the shadow
--       reconciliation, with the SA-only message, not the shared gate's generic one — proving
--       the shared gate's merchant arm is NOT sufficient here, on purpose.
--   S2  A caller with NO Customer Intelligence access at all (no staff row, no platform arm) is
--       refused by the SHARED GATE FIRST — 'customer intelligence access is required', not
--       'super admin access is required' — proving the shared gate now runs ahead of the
--       SA-only check, not merely coexists with it.
--   S3  A real-session (Google OAuth) super admin IS served — the population this reader exists
--       for is unaffected by either new check.
--
-- Named for v725: every T/S assertion must FAIL against the pre-v725 engine (T-series: no
-- 'time_basis' key exists at all; S2: the pre-v725 engine's only gate is is_super_admin(), so a
-- non-entitled non-admin caller gets 'super admin access is required', not the shared gate's
-- message — the message text itself is the proof the shared gate ran first, not just that SOME
-- 42501 was raised). One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v725$
declare
  biz         uuid := '00000000-0000-4000-8000-000000725001';
  u_sa        uuid := '00000000-0000-4000-8000-000000725101';
  u_owner     uuid := '00000000-0000-4000-8000-000000725102';
  u_nobody    uuid := '00000000-0000-4000-8000-000000725103';
  node_key    text;
  d_from      date := current_date - 20;
  d_to        date := current_date;
  v_run_id    uuid;
  g           jsonb;
  v_err       text;
  v_sqlstate  text;
begin
  ---------------------------------------------------------------------------
  -- actors, business
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_sa, 'zz-v725-sa@example.test'),
    (u_owner, 'zz-v725-owner@example.test'),
    (u_nobody, 'zz-v725-nobody@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (u_sa, 'zz-v725-sa@example.test') on conflict do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v725 time-basis fixture', 'zz-v725-tb',
      array['dashboard','clients','sales','reports','customerintel']);

  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz, u_owner, 'owner', 'ZZ v725 owner', true, 'approved');

  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v725 time-basis fixture')
    on conflict (business_id) do update
      set approval_status='approved', decided_at=now(),
          decision_reason='v725 time-basis fixture';
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  select n.node_key into node_key from public.taxonomy_nodes n
   where n.version_no = 1 limit 1;
  if node_key is null then
    insert into _fail values ('pre-taxonomy', 'no taxonomy node at version 1 — T2 cannot run');
    return;
  end if;

  ---------------------------------------------------------------------------
  -- PRECONDITIONS. The T/S assertions below are only meaningful if the fixture actors are what
  -- the header claims.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role', 'authenticated')::text, true);
  if not app.is_salon_member(biz) then
    insert into _fail values ('pre-owner', 'the owner fixture row is not a salon member; S1 would be vacuous');
  end if;
  if not app.can_module(biz, 'customerintel') then
    insert into _fail values ('pre-owner-module', 'the owner does not resolve customerintel; S1 would be vacuous');
  end if;
  if not app.has_perm(biz, 'view_finance') then
    insert into _fail values ('pre-owner-perm', 'the owner does not resolve view_finance; S1 would be vacuous');
  end if;
  begin
    perform app.ci_access_gate_v667(biz, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('pre-owner-gate',
      format('the owner fails the shared CI gate outright (%s) — S1 would not isolate the '
             'SA-only check at all', v_err));
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_nobody, 'role', 'authenticated')::text, true);
  if app.is_salon_member(biz) or app.is_super_admin() then
    insert into _fail values ('pre-nobody',
      'the no-access fixture user unexpectedly holds a staff row or super-admin grant; S2 would be vacuous');
  end if;

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  if not app.is_super_admin() then
    insert into _fail values ('pre-sa',
      'the Google-session fixture user does not resolve is_super_admin(); S3 and the run '
      'capture below would be vacuous');
  end if;

  ---------------------------------------------------------------------------
  -- T1 — get_customer_intelligence_v83 carries top-level time_basis = 'sale_occurred_at'.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_owner, 'role', 'authenticated')::text, true);
  begin
    g := public.get_customer_intelligence_v83(biz, null, d_from, d_to);
    if g->>'time_basis' is distinct from 'sale_occurred_at' then
      insert into _fail values ('T1', format('v83 time_basis = %s, expected sale_occurred_at',
        coalesce(g->>'time_basis', 'null')));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T1', format('get_customer_intelligence_v83 raised (%s)', v_err));
  end;

  ---------------------------------------------------------------------------
  -- T2 — get_ci_category_customers_v1 carries top-level time_basis = 'sale_occurred_at'
  --      (normal, non-suppressed path: zero category sales -> v_count=0, not "> 0 and < floor").
  ---------------------------------------------------------------------------
  begin
    g := public.get_ci_category_customers_v1(biz, node_key, d_from, d_to, 100);
    if g->>'time_basis' is distinct from 'sale_occurred_at' then
      insert into _fail values ('T2', format('category_customers time_basis = %s, expected sale_occurred_at',
        coalesce(g->>'time_basis', 'null')));
    end if;
    if g->'suppressed' is not null and g->'suppressed' <> 'null'::jsonb then
      insert into _fail values ('T2-pre',
        'the fixture cohort was unexpectedly suppressed; T2 did not exercise the path it claims to');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('T2', format('get_ci_category_customers_v1 raised (%s)', v_err));
  end;

  ---------------------------------------------------------------------------
  -- Capture a shadow run (SA-with-Google session — same auth context v685's own fixture uses)
  -- so T3/S1/S2/S3 have a real run_id to reconcile against.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  begin
    v_run_id := app.ci_shadow_capture_v685(biz, d_from, d_to);
  exception when others then
    get stacked diagnostics v_err = message_text;
    insert into _fail values ('pre-capture', format('ci_shadow_capture_v685 raised: %s', v_err));
  end;

  if v_run_id is null then
    insert into _fail values ('pre-capture', 'ci_shadow_capture_v685 returned no run id — T3/S1/S2/S3 cannot run');
  else
    ---------------------------------------------------------------------------
    -- T3 — get_ci_shadow_reconciliation_v685 carries top-level time_basis = 'captured_at'.
    ---------------------------------------------------------------------------
    begin
      g := public.get_ci_shadow_reconciliation_v685(biz, v_run_id);
      if g->>'time_basis' is distinct from 'captured_at' then
        insert into _fail values ('T3', format('shadow_reconciliation time_basis = %s, expected captured_at',
          coalesce(g->>'time_basis', 'null')));
      end if;
    exception when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('T3', format('get_ci_shadow_reconciliation_v685 raised (%s)', v_err));
    end;

    ---------------------------------------------------------------------------
    -- S3 — the SAME real-session super admin IS served (population this reader exists for is
    --      unaffected by either new check). Proven again, explicitly, alongside S1/S2 so the
    --      three sit together as one contrast.
    ---------------------------------------------------------------------------
    begin
      g := public.get_ci_shadow_reconciliation_v685(biz, v_run_id);
      if g is null then insert into _fail values ('S3', 'the Google-session super admin got no payload'); end if;
    exception when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('S3', format('the Google-session super admin was refused (%s)', v_err));
    end;

    ---------------------------------------------------------------------------
    -- S1 — a fully entitled firm owner (passes the shared gate's merchant arm outright, proven
    --      by the precondition above) is REFUSED, with the SA-only message — the shared gate's
    --      merchant arm must NOT be sufficient for this SA-only ops diagnostic.
    ---------------------------------------------------------------------------
    perform set_config('request.jwt.claims',
      json_build_object('sub', u_owner, 'role', 'authenticated')::text, true);
    v_sqlstate := null;
    v_err := null;
    begin
      perform public.get_ci_shadow_reconciliation_v685(biz, v_run_id);
      insert into _fail values ('S1', 'an entitled firm owner (not a super admin) read the shadow reconciliation');
    exception when others then
      get stacked diagnostics v_sqlstate = returned_sqlstate, v_err = message_text;
    end;
    if v_sqlstate is distinct from '42501' then
      insert into _fail values ('S1-sqlstate', format('expected 42501, got %s', coalesce(v_sqlstate, 'null')));
    elsif v_err is distinct from 'super admin access is required' then
      insert into _fail values ('S1-message', format(
        'refused with 42501 but the wrong reason (%s) — an entitled owner must fail the '
        'SA-only check, not the shared gate (which they pass)', coalesce(v_err, 'null')));
    end if;

    ---------------------------------------------------------------------------
    -- S2 — a caller with NO Customer Intelligence access at all is refused by the SHARED GATE
    --      FIRST — 'customer intelligence access is required', not the SA-only message — proving
    --      the shared gate now runs ahead of the is_super_admin() check, not merely alongside it.
    ---------------------------------------------------------------------------
    perform set_config('request.jwt.claims',
      json_build_object('sub', u_nobody, 'role', 'authenticated')::text, true);
    v_sqlstate := null;
    v_err := null;
    begin
      perform public.get_ci_shadow_reconciliation_v685(biz, v_run_id);
      insert into _fail values ('S2', 'a caller with no Customer Intelligence access at all read the shadow reconciliation');
    exception when others then
      get stacked diagnostics v_sqlstate = returned_sqlstate, v_err = message_text;
    end;
    if v_sqlstate is distinct from '42501' then
      insert into _fail values ('S2-sqlstate', format('expected 42501, got %s', coalesce(v_sqlstate, 'null')));
    elsif v_err is distinct from 'customer intelligence access is required' then
      insert into _fail values ('S2-message', format(
        'refused with 42501 but the wrong reason (%s) — a caller with no CI access at all must '
        'fail the SHARED gate first, proving it now runs ahead of the SA-only check',
        coalesce(v_err, 'null')));
    end if;
  end if;

  perform set_config('request.jwt.claims', null, true);
end
$v725$;

select case when count(*)=0
            then 'PASS — time_basis lands on v83/category_customers/shadow_reconciliation; the '
                 'shadow reader''s shared-gate-then-super-admin ordering holds'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v725: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
