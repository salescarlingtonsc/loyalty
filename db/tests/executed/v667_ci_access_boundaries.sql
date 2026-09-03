-- EXECUTED regression fixture for nestly_v667 — Customer Intelligence access boundaries.
--
-- WHY. The 2026-09-01 proof baseline (docs/qa/CI-PROOF-BASELINE-2026-09-01.md) confirmed four
-- P0 defects in the v650 CI read layer. Three of them are access-boundary failures and are
-- proven here; the fourth (the consultant-report UI/SQL payload mismatch) is a browser defect
-- and is proven by tests/platform-console/v667-consultative-payload.test.mjs instead.
--
--   B1  ENTITLEMENT SERVES THE MERCHANT. An ENTITLED firm owner must be SERVED.
--       This assertion was first written the other way round, from PRODUCT-TRUTH.md:228
--       ("a platform/consulting capability, not a self-service owner module"). That line dates
--       from 2026-08-02. nestly_v523 records an owner ruling of 2026-08-26 — twenty-four days
--       later — that the module follows entitlement again. The later ruling governs, so encoding
--       the older line as a test would have reversed an owner decision. Corrected before commit.
--   B1b ENTITLEMENT IS WHAT EARNS IT. A member of the SAME firm whose role does not carry the
--       reports module must still be refused, or "entitled" would mean nothing.
--   B1c NESTLY_V689 — MODULE ALONE IS NOT ENOUGH. app.can_module reads staff.modules /
--       staff.module_perms directly and never consults app.role_perms or app.has_perm, so a
--       per-staff allowlist can hand a role the 'customerintel' entitlement even when that role's
--       OWN permission set carries no view_finance — exactly the gap the client (FINANCE_MODULES /
--       roleCanUseModule), v573's get_revenue_truth_v106 gate and v523's own
--       staff_module_perms_at_v115 already close. A member who holds 'customerintel' per-staff but
--       whose role lacks view_finance must still be refused, or the module entitlement would be
--       sufficient on its own — which is the caller nestly_v689 closes.
--   B2  TENANT. A member of another firm must be refused, and must never receive rows.
--   B3  ENTITLEMENT SURVIVES. The assigned consultant and the super admin must still be served
--       — a fix that denies everyone is not a fix.
--   B4  BRANCH SCOPE. v650 took no branch parameter at all, so branch scoping was not weakly
--       enforced, it was absent. A branch-scoped call must return that branch's revenue only.
--   B5  BRANCH INJECTION. A branch belonging to another firm must be refused, never silently
--       ignored (which would serve firm-wide figures to a caller who asked for one branch).
--   B6  SMALL CELL. get_ci_category_customers_v1 returned raw full_name for any group size, so
--       a category with one customer identified that person. Below the floor the cohort must be
--       suppressed or anonymised.
--   B7  FAIL CLOSED. Every refusal above must raise 42501. Returning an empty or zero-valued
--       payload would read as "this firm has no data" — the misleading-output failure mode.
--   B8  THE OWNER RULING IS IN FORCE (nestly_v668). v523 recorded an owner ruling of 2026-08-26
--       that Customer Intelligence "resolve[s] exactly like every other one", but it removed the
--       hand-placed override from only one of the two resolvers, so app.can_module(b,
--       'customerintel') stayed false for every caller and the ruling never took effect. B8
--       asserts the module now follows entitlement in BOTH directions: a firm that LISTS
--       'customerintel' resolves true for its owner, and a firm that does not still resolves
--       false for its own (equally operational) owner. A one-directional assertion would pass
--       against a resolver that simply says yes to everybody.
--
-- Named for v667: every assertion must FAIL against the frozen baseline. One transaction,
-- rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v667$
declare
  biz_a      uuid := '00000000-0000-4000-8000-00000006f001';
  biz_b      uuid := '00000000-0000-4000-8000-00000006f002';
  br_a1      uuid := '00000000-0000-4000-8000-00000006f011';
  br_a2      uuid := '00000000-0000-4000-8000-00000006f012';
  br_b1      uuid := '00000000-0000-4000-8000-00000006f013';
  u_sa       uuid := '00000000-0000-4000-8000-00000006f101';
  u_cons     uuid := '00000000-0000-4000-8000-00000006f102';
  u_owner_a  uuid := '00000000-0000-4000-8000-00000006f103';
  u_owner_b  uuid := '00000000-0000-4000-8000-00000006f104';
  u_nofin    uuid := '00000000-0000-4000-8000-00000006f105';
  u_ci_nofin uuid := '00000000-0000-4000-8000-00000006f106';
  cons_id    uuid := '00000000-0000-4000-8000-00000006f201';
  co_id      uuid := '00000000-0000-4000-8000-00000006f202';
  svc_pop    uuid := '00000000-0000-4000-8000-00000006f301';
  svc_rare   uuid := '00000000-0000-4000-8000-00000006f302';
  cl_solo    uuid := '00000000-0000-4000-8000-00000006f404';
  /* Five is the small-cell floor v667 adopts, so the above-floor cohort is exactly five. */
  k_floor    int  := 5;
  d_from     date := current_date - 20;
  d_to       date := current_date;
  node_pop   text;
  node_rare  text;
  g          jsonb;
  v_a1_rev   bigint;
  v_all_rev  bigint;
  v_names    int;
  v_ci_a     boolean;
  v_ci_b     boolean;
  v_err      text;
begin
  ---------------------------------------------------------------------------
  -- actors
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_sa,'zz-v667-sa@example.test'), (u_cons,'zz-v667-cons@example.test'),
    (u_owner_a,'zz-v667-oa@example.test'), (u_owner_b,'zz-v667-ob@example.test'),
    (u_nofin,'zz-v667-nofin@example.test'), (u_ci_nofin,'zz-v667-ci-nofin@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (u_sa,'zz-v667-sa@example.test') on conflict do nothing;

  ---------------------------------------------------------------------------
  -- two firms, three branches
  ---------------------------------------------------------------------------
  /* enabled_modules must actually contain 'reports': the resolver reads it to decide a module's
     mode, so a firm with an empty set has no reports access and B1/B1b would prove nothing.
     'customerintel' is listed for firm A and withheld from firm B — that contrast is what B8
     measures, in both directions.

     This USED to carry a longer note explaining why 'customerintel' could not be listed at all:
     nestly_v523 (owner ruling 2026-08-26) removed the hand-placed override only from
     app.staff_module_perms_at_v115, while app.effective_platform_module_mode_v94 went on
     answering 'disabled' / 'global_platform_only_policy' ahead of the entitlement, so listing the
     module here would have implied an entitlement no firm could actually hold. That is now
     history: nestly_v668 removed the short-circuit from the second resolver too, so
     app.can_module(b,'customerintel') means what enabled_modules says. nestly_v689 then closed the
     remaining gap ONE LEVEL UP, in the gate that reads app.can_module: the merchant arm now also
     requires app.has_perm(business,'view_finance'), because app.can_module alone can be satisfied
     by a per-staff allowlist grant regardless of the holder's role (B1c, below). Firm A's owner
     satisfies both the module and the permission; firm A's B1c member satisfies only the module. */
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz_a,'ZZ v667 firm A','zz-v667-a',
      array['dashboard','clients','sales','reports','customerintel']),
    (biz_b,'ZZ v667 firm B','zz-v667-b',
      array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br_a1, biz_a, 'ZZ v667 A-one', true,  true),
    (br_a2, biz_a, 'ZZ v667 A-two', false, true),
    (br_b1, biz_b, 'ZZ v667 B-one', true,  true);

  /* access_state matters: app.is_salon_member (v207) requires an ACTIVE, APPROVED staff row,
     not merely a staff row. Without it the owner is not a member and B1 passes vacuously. */
  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz_a, u_owner_a, 'owner', 'ZZ v667 owner A', true, 'approved'),
    (biz_b, u_owner_b, 'owner', 'ZZ v667 owner B', true, 'approved');
  /* A member of firm A whose allowlist omits 'reports'. B1b needs someone who IS a member but is
     NOT entitled, or "entitled" is untested. */
  insert into public.staff (business_id, user_id, role, full_name, active, access_state, modules)
  values (biz_a, u_nofin, 'staff', 'ZZ v667 no-reports', true, 'approved',
          array['dashboard','clients']);
  /* B1c (nestly_v689). A member of firm A whose PER-STAFF allowlist explicitly grants BOTH
     'reports' and 'customerintel' — app.can_module(biz_a,'reports') AND
     app.can_module(biz_a,'customerintel') both resolve true for this user, because app.can_module
     reads staff.modules directly and never consults app.role_perms — but whose ROLE ('staff')
     carries no view_finance (app.role_perms('staff') = {view_sales,create_sales}). 'reports' is
     included deliberately: without it, the OLD (pre-v689) gate would have refused this user for
     an unrelated reason (no 'reports') and B1c would pass whether or not v689 is applied, proving
     nothing. WITH 'reports' present, the old gate — which checked only
     app.can_module(b,'reports') — SERVED this user; only nestly_v689's added view_finance
     requirement refuses them. */
  insert into public.staff (business_id, user_id, role, full_name, active, access_state, modules)
  values (biz_a, u_ci_nofin, 'staff', 'ZZ v667 ci-module-no-finance', true, 'approved',
          array['dashboard','clients','reports','customerintel']);

  /* is_salon_member also requires an OPEN workspace, which v620 resolves through BOTH the
     approval control and the subscription lifecycle. A firm insert seeds both rows in the
     pending shape, so these upserts promote them. Miss either and every gate below refuses
     for a billing reason rather than a CI-entitlement one — the vacuous-pass trap. */
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  select b, 'approved', now(), 'v667 access-boundary fixture' from unnest(array[biz_a,biz_b]) b
    on conflict (business_id) do update
      set approval_status='approved', decided_at=now(),
          decision_reason='v667 access-boundary fixture';
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  select b, 'current', false from unnest(array[biz_a,biz_b]) b
    on conflict (business_id) do update set state='current', workspace_paused=false;

  /* v620's operational predicate also demands a paying (or in-trial) subscription. Every other
     column on public.subscriptions carries a default, so paid + an unexpired period is the
     whole requirement. Without this the workspace is closed and every gate refuses for a
     BILLING reason, which is the third way this fixture could have passed vacuously. */
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  select b, 'active', 'paid', now() + interval '30 days' from unnest(array[biz_a,biz_b]) b
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  /* The assigned consultant for firm A only. app.assigned_consultant_v94 reads the assignment
     through sme_prospects.converted_business_id, not a column on businesses, so the prospect
     row IS the assignment — and its conversion-shape check demands all three converted_* fields
     together. Firm B deliberately gets no prospect row, which is what makes B2 meaningful. */
  insert into public.platform_consultants (id, user_id, display_name, tier, employment_started_on, active)
    values (cons_id, u_cons, 'ZZ v667 consultant', 'senior', current_date - 400, true);
  insert into public.sme_companies (id, legal_name, trading_name)
    values (co_id, 'ZZ v667 Firm A Pte Ltd', 'ZZ v667 Firm A');
  insert into public.sme_prospects (company_id, legacy_stage_raw, assigned_consultant_id,
                                    ownership_state, queue_key,
                                    converted_business_id, converted_at, converted_by)
    values (co_id, 'zz-v667-fixture', cons_id, 'owned', null,
            biz_a, clock_timestamp(), u_sa);

  ---------------------------------------------------------------------------
  -- catalogue: one popular category (3 customers) and one rare one (1 customer)
  ---------------------------------------------------------------------------
  select n.node_key into node_pop from public.taxonomy_nodes n
   where n.version_no=1 and n.level=2 order by n.node_key limit 1;
  select n.node_key into node_rare from public.taxonomy_nodes n
   where n.version_no=1 and n.level=2 and n.node_key <> node_pop order by n.node_key limit 1;
  if node_pop is null or node_rare is null then
    insert into _fail values ('B0','taxonomy v1 has fewer than two level-2 nodes; fixture cannot run');
    return;
  end if;

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_pop,  biz_a, 'ZZ v667 popular', 5000, 30),
    (svc_rare, biz_a, 'ZZ v667 rare',    9000, 30);
  insert into public.service_canonical_map
    (business_id, service_id, node_key, version_no, method, mapped_by) values
    (biz_a, svc_pop,  node_pop,  1, 'owner_chosen', u_owner_a),
    (biz_a, svc_rare, node_rare, 1, 'owner_chosen', u_owner_a);

  /* Five above-floor customers on branch A1, one identifiable customer on A2. */
  insert into public.clients (id, business_id, full_name)
  select ('00000000-0000-4000-8000-00000006f4' || lpad((10 + ser.i)::text, 2, '0'))::uuid,
         biz_a, 'ZZ v667 Popular ' || ser.i
    from generate_series(1, k_floor) as ser(i);
  insert into public.clients (id, business_id, full_name) values
    (cl_solo, biz_a, 'ZZ v667 Solo Identifiable');

  /* Branch A1 carries the three popular customers; branch A2 carries the solo customer.
     A1 revenue is therefore strictly less than firm-wide revenue, which is what B4 measures. */
  /* TRUTH TABLE. Branch A1: 5 x 5000 = 25000. Branch A2: 1 x 9000 = 9000. Firm-wide 34000.
     B4 asserts exactly these three numbers, so a branch filter that silently does nothing
     cannot pass. */
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                            occurred_at, counts_as_revenue, counts_as_visit)
  select gen_random_uuid(), biz_a, br_a1, c.id, 'service', 5000,
         (current_date - 5)::timestamp at time zone 'Asia/Singapore', true, true
    from public.clients c
   where c.business_id = biz_a and c.id <> cl_solo;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                            occurred_at, counts_as_revenue, counts_as_visit)
  values
    (gen_random_uuid(), biz_a, br_a2, cl_solo, 'service', 9000,
       (current_date - 2)::timestamp at time zone 'Asia/Singapore', true, true);

  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select s.business_id, s.id, 'service',
         case when s.client_id = cl_solo then svc_rare else svc_pop end,
         1, s.amount_cents, s.amount_cents
    from public.sales s
   where s.business_id = biz_a and s.branch_id in (br_a1, br_a2);

  ---------------------------------------------------------------------------
  -- B1 — a firm owner must be REFUSED. CI is not a self-service owner module.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_a,'role','authenticated')::text, true);

  /* PRECONDITION. B1 is only meaningful if this owner genuinely holds ordinary reports access —
     otherwise the refusal below proves nothing about CI entitlement and the assertion passes
     vacuously. Record the real predicate values so a reader can see B1 was earned. */
  if not app.is_salon_member(biz_a) then
    insert into _fail values ('B1-pre','fixture owner is not a salon member; B1 would be vacuous');
  end if;
  if not app.can_module(biz_a,'reports') then
    insert into _fail values ('B1-pre',
      'fixture owner lacks the reports module, so a refusal below proves nothing about CI '
      'entitlement — B1 would pass vacuously');
  end if;
  /* nestly_v689: the merchant arm now also requires view_finance directly (app.can_module alone
     does not check it — see B1c). Owner holds it via app.role_perms('owner'), but assert the real
     predicate rather than assume the role map, or a refusal below could be blamed on entitlement
     when it was actually this permission that was missing. */
  if not app.has_perm(biz_a,'view_finance') then
    insert into _fail values ('B1-pre',
      'fixture owner lacks view_finance, so a refusal below proves nothing about CI entitlement — '
      'B1 would pass vacuously');
  end if;

  /* An ENTITLED merchant owner must be SERVED.
     This assertion was originally written the other way round, on the strength of
     PRODUCT-TRUTH.md:228 ("a platform/consulting capability, not a self-service owner module").
     That line dates from 2026-08-02; nestly_v523 records an owner ruling of 2026-08-26 that the
     module follows entitlement again. The later ruling governs, so refusing the owner here would
     have encoded a stale document as a test and reversed an owner decision. */
  begin
    g := public.get_ci_acquisition_v1(biz_a, d_from, d_to);
    if g is null or g->'sources' is null then
      insert into _fail values ('B1','the entitled owner got no acquisition payload');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('B1',
      format('an entitled firm owner was refused (%s); nestly_v523 rules the module follows entitlement', v_err));
  end;
  begin
    g := public.get_ci_category_mix_v1(biz_a, d_from, d_to);
    if g is null then insert into _fail values ('B1','the entitled owner got no category mix'); end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('B1', format('entitled owner refused on category mix (%s)', v_err));
  end;

  /* B1b — entitlement is what earns it. A member of the SAME firm whose role does not carry the
     reports module must still be refused, or "entitled" would mean nothing. */
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_nofin,'role','authenticated')::text, true);
  if not app.is_salon_member(biz_a) then
    insert into _fail values ('B1b-pre','the restricted staff row is not a member; B1b would be vacuous');
  end if;
  if app.can_module(biz_a,'reports') then
    insert into _fail values ('B1b-pre','the restricted staff member still holds reports; B1b would be vacuous');
  end if;
  begin
    g := public.get_ci_acquisition_v1(biz_a, d_from, d_to);
    insert into _fail values ('B1b','a member without the reports module reached the CI readers');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('B1b', format('refused with %s, expected 42501', v_err));
  end;

  ---------------------------------------------------------------------------
  -- B1c (nestly_v689) — the module entitlement alone is not enough. A member who holds
  -- 'customerintel' through a PER-STAFF allowlist grant, but whose role carries no view_finance,
  -- must still be refused. Before v689 this exact caller reached every CI reader: the old gate
  -- checked app.can_module(b,'reports'), which this user's role satisfies via enabled_modules,
  -- and never checked view_finance at all.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_ci_nofin,'role','authenticated')::text, true);

  /* PRECONDITIONS. Both halves of the gap must be real, or the refusal below proves nothing:
     the member must genuinely hold the module (so this is not just B1b again) and must
     genuinely lack the permission (so this is not a membership or workspace problem). */
  if not app.is_salon_member(biz_a) then
    insert into _fail values ('B1c-pre','the ci-module member is not a salon member; B1c would be vacuous');
  end if;
  if not app.can_module(biz_a,'customerintel') then
    insert into _fail values ('B1c-pre',
      'the ci-module member does not resolve customerintel at all; B1c would not be testing the '
      'module-without-permission gap, it would just be B1b again');
  end if;
  if app.has_perm(biz_a,'view_finance') then
    insert into _fail values ('B1c-pre',
      'the ci-module member holds view_finance after all; B1c would be vacuous — pick a role '
      'that truly lacks it (app.role_perms confirms staff = {view_sales,create_sales})');
  end if;

  begin
    g := public.get_ci_acquisition_v1(biz_a, d_from, d_to);
    insert into _fail values ('B1c',
      'a member holding customerintel per-staff but no view_finance reached the CI readers — '
      'the module entitlement alone was treated as sufficient');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('B1c', format('refused with %s, expected 42501', v_err));
  end;

  ---------------------------------------------------------------------------
  -- B2 — cross-tenant: firm B's owner must never reach firm A's intelligence
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_b,'role','authenticated')::text, true);
  begin
    g := public.get_ci_acquisition_v1(biz_a, d_from, d_to);
    insert into _fail values ('B2','another firm''s owner read firm A intelligence');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('B2', format('refused with %s, expected 42501', v_err));
  end;

  ---------------------------------------------------------------------------
  -- B3 — the entitled callers must still be served
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_cons,'role','authenticated')::text, true);
  begin
    g := public.get_ci_category_mix_v1(biz_a, d_from, d_to);
    if g is null or g->>'status' is null then
      insert into _fail values ('B3','the assigned consultant got no payload');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('B3', format('the assigned consultant was refused (%s)', v_err));
  end;

  /* v625: a platform session only counts when it came through Google SSO — app.is_super_admin
     checks amr[0].method='oauth' and app_metadata.providers containing 'google'. A bare
     sub-only claim set is refused BY DESIGN, so the fixture must present a real platform
     session or B3 would report a product defect that does not exist. */
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  begin
    g := public.get_ci_acquisition_v1(biz_a, d_from, d_to);
    if g is null then insert into _fail values ('B3','the super admin got no payload'); end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('B3', format('the super admin was refused (%s)', v_err));
  end;

  ---------------------------------------------------------------------------
  -- B4 — branch scope. A1 holds 15000; the firm holds 24000.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_cons,'role','authenticated')::text, true);
  begin
    g := public.get_ci_category_mix_v1(biz_a, d_from, d_to, br_a1);
    v_a1_rev := coalesce((g->'coverage'->>'stampable_revenue_cents')::bigint, -1);
    g := public.get_ci_category_mix_v1(biz_a, d_from, d_to, null);
    v_all_rev := coalesce((g->'coverage'->>'stampable_revenue_cents')::bigint, -1);
    if v_a1_rev <> 25000 then
      insert into _fail values ('B4',
        format('branch A1 revenue was %s, expected 25000 (branch filter not applied)', v_a1_rev));
    end if;
    if v_all_rev <> 34000 then
      insert into _fail values ('B4',
        format('firm-wide revenue was %s, expected 34000', v_all_rev));
    end if;
  exception when undefined_function then
    insert into _fail values ('B4','get_ci_category_mix_v1 takes no branch argument; branch scope is absent');
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('B4', format('branch-scoped read raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- B5 — a branch belonging to ANOTHER firm must be refused, never ignored
  ---------------------------------------------------------------------------
  begin
    g := public.get_ci_category_mix_v1(biz_a, d_from, d_to, br_b1);
    insert into _fail values ('B5',
      'a foreign branch id was accepted; the caller asked for one branch and got firm-wide data');
  exception when insufficient_privilege then null;
           when undefined_function then
             insert into _fail values ('B5','no branch argument exists to validate');
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('B5', format('foreign branch refused with %s, expected 42501', v_err));
  end;

  ---------------------------------------------------------------------------
  -- B6 — small cell. The rare category has exactly one customer: no name may leave.
  ---------------------------------------------------------------------------
  begin
    g := public.get_ci_category_customers_v1(biz_a, node_rare, d_from, d_to, 100);
    select count(*) into v_names
      from jsonb_array_elements(coalesce(g->'customers','[]'::jsonb)) c
     where coalesce(c->>'full_name','') <> ''
       and c->>'full_name' not in ('Withheld','withheld');
    if v_names > 0 then
      insert into _fail values ('B6',
        format('a %s-customer category disclosed %s identifiable name(s)',
               jsonb_array_length(coalesce(g->'customers','[]'::jsonb)), v_names));
    end if;
    if coalesce(g->>'suppressed','') = '' then
      insert into _fail values ('B6','the payload does not say the cohort was suppressed');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('B6', format('small-cell read raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- B7 — the popular category (3 customers, at/over the floor) must still answer,
  --       so the suppression is a floor and not a blanket refusal.
  ---------------------------------------------------------------------------
  begin
    g := public.get_ci_category_customers_v1(biz_a, node_pop, d_from, d_to, 100);
    if jsonb_array_length(coalesce(g->'customers','[]'::jsonb)) < k_floor then
      insert into _fail values ('B7', format(
        'the %s-customer category returned %s rows; an at-floor cohort must still answer',
        k_floor, jsonb_array_length(coalesce(g->'customers','[]'::jsonb))));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('B7', format('above-floor read raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- B8 — nestly_v668: customerintel follows entitlement, both ways.
  --       Firm A lists it, firm B does not; both firms are equally operational and both
  --       owners are equally approved, so the only difference between the two answers is
  --       the entitlement itself.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_a,'role','authenticated')::text, true);

  /* PRECONDITIONS. Owner A must genuinely be an operating member holding another module, or a
     true answer below could come from something other than the entitlement, and a false one
     from a closed workspace. */
  if not app.is_salon_member(biz_a) then
    insert into _fail values ('B8-pre','owner A is not a member; B8 would measure membership, not entitlement');
  end if;
  if not app.can_module(biz_a,'reports') then
    insert into _fail values ('B8-pre',
      'owner A cannot resolve the reports module either, so a customerintel refusal would prove '
      'nothing about the v523 ruling');
  end if;
  if not exists (select 1 from public.businesses b
                  where b.id = biz_a
                    and 'customerintel' = any(coalesce(b.enabled_modules,'{}'::text[]))) then
    insert into _fail values ('B8-pre',
      'firm A does not carry customerintel in enabled_modules; B8 would assert nothing');
  end if;

  v_ci_a := app.can_module(biz_a,'customerintel');
  if v_ci_a is distinct from true then
    insert into _fail values ('B8',
      'an entitled firm''s owner still cannot resolve customerintel; the owner ruling recorded '
      'in nestly_v523 (2026-08-26) is not in force — app.effective_platform_module_mode_v94 is '
      'still short-circuiting the module to disabled ahead of the entitlement');
  end if;

  /* The other direction. Firm B is operational and its owner is approved; it simply is not
     entitled. Without this, B8 would also pass against a resolver that grants the module to
     everybody, which is the opposite defect. */
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_b,'role','authenticated')::text, true);
  if not app.is_salon_member(biz_b) then
    insert into _fail values ('B8-pre','owner B is not a member; the negative half of B8 would be vacuous');
  end if;
  if not app.can_module(biz_b,'reports') then
    insert into _fail values ('B8-pre',
      'owner B cannot resolve any module, so a customerintel refusal is not about entitlement');
  end if;
  if exists (select 1 from public.businesses b
              where b.id = biz_b
                and 'customerintel' = any(coalesce(b.enabled_modules,'{}'::text[]))) then
    insert into _fail values ('B8-pre','firm B was entitled after all; the negative half of B8 is void');
  end if;

  v_ci_b := app.can_module(biz_b,'customerintel');
  if v_ci_b is distinct from false then
    insert into _fail values ('B8',
      'a firm that is NOT entitled to customerintel resolved it anyway; v523 rules that "a '
      'business that is not entitled still does not get it"');
  end if;

  perform set_config('request.jwt.claims', null, true);
end
$v667$;

select case when count(*)=0
            then 'PASS — CI access boundaries hold: entitlement, tenant, branch, small cell'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  /* The harness surfaces the raised message, not the select above, so the detail has to
     travel with the exception or a failure reads as a bare count. */
  if n > 0 then raise exception 'v667: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
