-- EXECUTED regression fixture for nestly_v721 — one Customer Intelligence gate, and branch
-- isolation actually enforced (docs/qa/CI-100-CHECKLIST.md checks 91 and 95).
--
-- WHY. The refuter's executed findings against the live engine:
--
--   (91) public.get_customer_intelligence_v83 carried its own inline gate (has_perm
--        view_finance AND can_module customerintel) with NO platform arm, so an assigned
--        consultant and a real-session super admin — the exact two populations nestly_v667's own
--        header names as entitled — were refused on THIS reader while being served by every
--        sibling CI reader. Fixed by deleting the private gate and calling
--        app.ci_access_gate_v667(p_business, null) instead — one authority.
--   (95) app.ci_access_gate_v667's branch check only asked "does p_branch belong to
--        p_business", never "may THIS caller see that branch", and never refused a null
--        (firm-wide) p_branch from a caller who is not entitled to firm-wide figures. A
--        branch-restricted employee (public.staff_branches) could read a branch they are not
--        assigned to, or substitute the whole firm's history for it, through every CI reader
--        gated only by the shared gate. Fixed by adding app.can_see_branch(p_business, p_branch)
--        to the merchant arm, excluding the sessionless internal drain and the platform arm (who
--        hold no staff row at all and are not branch-restricted employees).
--
-- G-SERIES — check 91, public.get_customer_intelligence_v83 entitlement:
--   G1  The assigned consultant is SERVED (was refused before v721 — no platform arm at all).
--   G2  A real-session (Google OAuth) super admin is SERVED (was refused before v721).
--   G3  A super admin session WITHOUT the Google OAuth claim is REFUSED (nestly_v625's own rule:
--       app.is_super_admin() only counts a real platform session; a bare claim set must not pass
--       through the platform arm this migration adds).
--   G4  Firm A's owner (holding customerintel + view_finance, unaffected by this migration) is
--       still SERVED — the merchant arm this reader already required is untouched.
--   G5  Firm B's owner is REFUSED on firm A's report (tenant isolation, pre-existing and
--       untouched — proven so a v721 regression on the entitlement side is not silently a
--       tenant-isolation regression too).
--
-- H-SERIES — check 95, branch isolation via app.ci_access_gate_v667 directly (the shared
-- authority every branch-scoped CI reader — get_ci_category_mix_v1 and friends — calls):
--   H1  A bookkeeper assigned (public.staff_branches) to branch A2 only is SERVED for A2.
--   H2  The SAME bookkeeper is REFUSED for branch A1 (a real branch of their own firm, just not
--       theirs), with the clear reason, not the generic entitlement message.
--   H3  The SAME bookkeeper is REFUSED firm-wide (p_branch = null) — they may not substitute
--       business-wide history for the branch they are actually restricted to.
--   H4  Firm A's owner passes for EVERY branch, including firm-wide — app.can_see_branch resolves
--       true unconditionally for an owner, so this migration must not have narrowed that.
--   H5  The assigned consultant (platform arm) passes for a null branch even though they hold no
--       staff row at all — proving the platform arm is excluded from the new branch check, not
--       accidentally admitted by some other path.
--   H6  A foreign branch (another firm's) is still refused for firm A's owner — the pre-existing
--       nestly_v667 branch-existence check is untouched by this migration.
--
-- I-SERIES — sanity that v721's check-91 fix (v83 now passes null, not p_branch, to the shared
-- gate) did not regress v83's OWN pre-existing, separate app.can_see_branch(p_business, p_branch)
-- check, which is what actually enforces branch scope for THIS specific reader (see the
-- migration header for why null is correct):
--   I1  The branch-restricted bookkeeper reading v83 for their OWN branch (A2) is SERVED.
--   I2  The SAME bookkeeper reading v83 for the OTHER branch (A1) is REFUSED — by v83's own
--       branch_visibility_required check, independent of the gate.
--
-- Named for v721: every assertion must FAIL against the pre-v721 engine. One transaction, rolled
-- back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v721$
declare
  biz_a       uuid := '00000000-0000-4000-8000-000000721001';
  biz_b       uuid := '00000000-0000-4000-8000-000000721002';
  br_a1       uuid := '00000000-0000-4000-8000-000000721011';
  br_a2       uuid := '00000000-0000-4000-8000-000000721012';
  br_b1       uuid := '00000000-0000-4000-8000-000000721013';
  u_sa        uuid := '00000000-0000-4000-8000-000000721101';
  u_cons      uuid := '00000000-0000-4000-8000-000000721102';
  u_owner_a   uuid := '00000000-0000-4000-8000-000000721103';
  u_owner_b   uuid := '00000000-0000-4000-8000-000000721104';
  u_bk        uuid := '00000000-0000-4000-8000-000000721105';
  staff_bk_id uuid := '00000000-0000-4000-8000-000000721205';
  cons_id     uuid := '00000000-0000-4000-8000-000000721201';
  co_id       uuid := '00000000-0000-4000-8000-000000721202';
  d_from      date := current_date - 20;
  d_to        date := current_date;
  g           jsonb;
  v_err       text;
begin
  ---------------------------------------------------------------------------
  -- actors
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_sa,'zz-v721-sa@example.test'), (u_cons,'zz-v721-cons@example.test'),
    (u_owner_a,'zz-v721-oa@example.test'), (u_owner_b,'zz-v721-ob@example.test'),
    (u_bk,'zz-v721-bk@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (u_sa,'zz-v721-sa@example.test') on conflict do nothing;

  ---------------------------------------------------------------------------
  -- two firms, three branches
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz_a,'ZZ v721 firm A','zz-v721-a',
      array['dashboard','clients','sales','reports','customerintel']),
    (biz_b,'ZZ v721 firm B','zz-v721-b',
      array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br_a1, biz_a, 'ZZ v721 A-one', true,  true),
    (br_a2, biz_a, 'ZZ v721 A-two', false, true),
    (br_b1, biz_b, 'ZZ v721 B-one', true,  true);

  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz_a, u_owner_a, 'owner', 'ZZ v721 owner A', true, 'approved'),
    (biz_b, u_owner_b, 'owner', 'ZZ v721 owner B', true, 'approved');
  /* app.role_class('bookkeeper') = 'employee' (nestly_v17), so this role is branch-restricted
     unless assigned. app.role_perms('bookkeeper') already carries view_finance (nestly_v59), and
     enabled_modules carries 'customerintel', so this member resolves the FULL merchant-arm
     entitlement (is_salon_member + can_module + has_perm) -- the only thing standing between them
     and every CI reader, before this migration, was nothing at all. That is exactly what makes
     H1-H3 and I1-I2 measure the branch check and nothing else. */
  insert into public.staff (id, business_id, user_id, role, full_name, active, access_state)
    values (staff_bk_id, biz_a, u_bk, 'bookkeeper', 'ZZ v721 bookkeeper', true, 'approved');
  insert into public.staff_branches (business_id, staff_id, branch_id)
    values (biz_a, staff_bk_id, br_a2);

  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  select b, 'approved', now(), 'v721 one-ci-gate fixture' from unnest(array[biz_a,biz_b]) b
    on conflict (business_id) do update
      set approval_status='approved', decided_at=now(),
          decision_reason='v721 one-ci-gate fixture';
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  select b, 'current', false from unnest(array[biz_a,biz_b]) b
    on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  select b, 'active', 'paid', now() + interval '30 days' from unnest(array[biz_a,biz_b]) b
    on conflict (business_id) do update
      set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  /* The assigned consultant for firm A only, exactly the nestly_v667 fixture's own shape. */
  insert into public.platform_consultants (id, user_id, display_name, tier, employment_started_on, active)
    values (cons_id, u_cons, 'ZZ v721 consultant', 'senior', current_date - 400, true);
  insert into public.sme_companies (id, legal_name, trading_name)
    values (co_id, 'ZZ v721 Firm A Pte Ltd', 'ZZ v721 Firm A');
  insert into public.sme_prospects (company_id, legacy_stage_raw, assigned_consultant_id,
                                    ownership_state, queue_key,
                                    converted_business_id, converted_at, converted_by)
    values (co_id, 'zz-v721-fixture', cons_id, 'owned', null,
            biz_a, clock_timestamp(), u_sa);

  ---------------------------------------------------------------------------
  -- PRECONDITIONS. Confirm the fixture actors are what the header claims, or the assertions
  -- below could pass or fail for the wrong reason.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_bk,'role','authenticated')::text, true);
  if app.role_class('bookkeeper') <> 'employee' then
    insert into _fail values ('pre','app.role_class(''bookkeeper'') is no longer employee-class; the H/I series would be vacuous');
  end if;
  if not app.is_salon_member(biz_a) then
    insert into _fail values ('pre','the bookkeeper fixture row is not a salon member; H/I would be vacuous');
  end if;
  if not app.can_module(biz_a,'customerintel') then
    insert into _fail values ('pre','the bookkeeper does not resolve customerintel; H/I would be vacuous');
  end if;
  if not app.has_perm(biz_a,'view_finance') then
    insert into _fail values ('pre','the bookkeeper does not resolve view_finance; H/I would be vacuous');
  end if;
  if app.can_see_branch(biz_a, null) then
    insert into _fail values ('pre','the bookkeeper already passes can_see_branch(firm-wide); H/I would be vacuous');
  end if;
  if not app.can_see_branch(biz_a, br_a2) then
    insert into _fail values ('pre','the bookkeeper does not pass can_see_branch for their OWN assigned branch A2; the fixture assignment is wrong');
  end if;
  if app.can_see_branch(biz_a, br_a1) then
    insert into _fail values ('pre','the bookkeeper already passes can_see_branch for A1, which they are NOT assigned to; H2/I2 would be vacuous');
  end if;

  ---------------------------------------------------------------------------
  -- G1 — the assigned consultant reads v83. Before v721 this always 42501'd: v83's private gate
  -- had no platform arm at all.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_cons,'role','authenticated')::text, true);
  begin
    g := public.get_customer_intelligence_v83(biz_a, null, d_from, d_to);
    if g is null then insert into _fail values ('G1','the assigned consultant got no payload'); end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('G1', format('the assigned consultant was refused (%s) — v83 has no platform arm', v_err));
  end;

  ---------------------------------------------------------------------------
  -- G2 — a real-session (Google OAuth) super admin reads v83.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  if not app.is_super_admin() then
    insert into _fail values ('G2-pre','the Google-session fixture user does not resolve is_super_admin(); G2 would be vacuous');
  end if;
  begin
    g := public.get_customer_intelligence_v83(biz_a, null, d_from, d_to);
    if g is null then insert into _fail values ('G2','the Google-session super admin got no payload'); end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('G2', format('the Google-session super admin was refused (%s) — v83 has no platform arm', v_err));
  end;

  ---------------------------------------------------------------------------
  -- G3 — a super admin session WITHOUT the Google OAuth claim must still be REFUSED
  -- (nestly_v625: a bare claim set is not a real platform session).
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_sa,'role','authenticated')::text, true);
  if app.is_super_admin() then
    insert into _fail values ('G3-pre','the bare-claims fixture user resolves is_super_admin() anyway; G3 would be vacuous');
  end if;
  begin
    g := public.get_customer_intelligence_v83(biz_a, null, d_from, d_to);
    insert into _fail values ('G3','a super admin session without the Google OAuth claim reached v83');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('G3', format('refused with %s, expected 42501', v_err));
  end;

  ---------------------------------------------------------------------------
  -- G4 — firm A's owner (merchant arm, unaffected by this migration) is still served.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_a,'role','authenticated')::text, true);
  begin
    g := public.get_customer_intelligence_v83(biz_a, null, d_from, d_to);
    if g is null then insert into _fail values ('G4','the entitled firm A owner got no payload from v83'); end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('G4', format('the entitled firm A owner was refused (%s)', v_err));
  end;

  ---------------------------------------------------------------------------
  -- G5 — firm B's owner must never read firm A's intelligence via v83 (tenant isolation,
  -- untouched by this migration).
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_b,'role','authenticated')::text, true);
  begin
    g := public.get_customer_intelligence_v83(biz_a, null, d_from, d_to);
    insert into _fail values ('G5','firm B''s owner read firm A''s intelligence via v83');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('G5', format('refused with %s, expected 42501', v_err));
  end;

  ---------------------------------------------------------------------------
  -- H1 — the branch-restricted bookkeeper passes the shared gate for their OWN branch, A2.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_bk,'role','authenticated')::text, true);
  begin
    perform app.ci_access_gate_v667(biz_a, br_a2);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('H1', format('the bookkeeper was refused their OWN assigned branch A2 (%s)', v_err));
  end;

  ---------------------------------------------------------------------------
  -- H2 — the SAME bookkeeper is refused for A1 — a real branch of their own firm, just not
  -- theirs — with the clear reason, not the generic entitlement message.
  ---------------------------------------------------------------------------
  begin
    perform app.ci_access_gate_v667(biz_a, br_a1);
    insert into _fail values ('H2','the bookkeeper read a branch (A1) they are not assigned to');
  exception when insufficient_privilege then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'branch-restricted staff must pass their branch' then
      insert into _fail values ('H2', format(
        'refused with 42501 but the wrong reason (%s) — this must be the branch-restriction '
        'message, not the generic entitlement one', v_err));
    end if;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('H2', format('refused with %s, expected 42501', v_err));
  end;

  ---------------------------------------------------------------------------
  -- H3 — the SAME bookkeeper is refused FIRM-WIDE (p_branch = null) — they may not substitute
  -- business-wide history for the one branch they are actually restricted to.
  ---------------------------------------------------------------------------
  begin
    perform app.ci_access_gate_v667(biz_a, null);
    insert into _fail values ('H3','the bookkeeper substituted firm-wide history for their branch restriction');
  exception when insufficient_privilege then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'branch-restricted staff must pass their branch' then
      insert into _fail values ('H3', format(
        'refused with 42501 but the wrong reason (%s)', v_err));
    end if;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('H3', format('refused with %s, expected 42501', v_err));
  end;

  ---------------------------------------------------------------------------
  -- H4 — firm A's owner passes for EVERY branch, including firm-wide. app.can_see_branch
  -- resolves true unconditionally for an owner; this migration must not have narrowed that.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_a,'role','authenticated')::text, true);
  begin
    perform app.ci_access_gate_v667(biz_a, br_a1);
    perform app.ci_access_gate_v667(biz_a, br_a2);
    perform app.ci_access_gate_v667(biz_a, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('H4', format('firm A''s owner was refused a branch they own the whole firm for (%s)', v_err));
  end;

  ---------------------------------------------------------------------------
  -- H5 — the assigned consultant (platform arm, no staff row at all) passes for a null branch —
  -- proving the platform arm is excluded from the new branch check, not accidentally admitted.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_cons,'role','authenticated')::text, true);
  if app.is_salon_member(biz_a) then
    insert into _fail values ('H5-pre','the assigned consultant unexpectedly holds a staff row; H5 would not test the platform arm''s exclusion');
  end if;
  begin
    perform app.ci_access_gate_v667(biz_a, null);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('H5', format('the assigned consultant was refused a firm-wide read (%s) — the platform arm must be excluded from the branch-restriction check', v_err));
  end;

  ---------------------------------------------------------------------------
  -- H6 — a foreign branch (firm B's) is still refused for firm A's owner. The pre-existing
  -- nestly_v667 branch-existence check must be untouched by this migration.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_a,'role','authenticated')::text, true);
  begin
    perform app.ci_access_gate_v667(biz_a, br_b1);
    insert into _fail values ('H6','a foreign branch id was accepted for firm A''s owner');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('H6', format('foreign branch refused with %s, expected 42501', v_err));
  end;

  ---------------------------------------------------------------------------
  -- I1 — sanity: v83's OWN pre-existing app.can_see_branch check (independent of the shared
  -- gate, which v83 now calls with p_branch=null) still serves the bookkeeper their own branch.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_bk,'role','authenticated')::text, true);
  begin
    g := public.get_customer_intelligence_v83(biz_a, br_a2, d_from, d_to);
    if g is null then insert into _fail values ('I1','the bookkeeper got no payload from v83 for their own branch A2'); end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('I1', format('the bookkeeper was refused their own branch A2 via v83 (%s)', v_err));
  end;

  ---------------------------------------------------------------------------
  -- I2 — the SAME bookkeeper reading v83 for the OTHER branch (A1) is refused — by v83's own
  -- branch_visibility_required check, independent of the shared gate's null-branch call.
  ---------------------------------------------------------------------------
  begin
    g := public.get_customer_intelligence_v83(biz_a, br_a1, d_from, d_to);
    insert into _fail values ('I2','the bookkeeper read another branch (A1) via v83');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('I2', format('refused with %s, expected 42501', v_err));
  end;

  perform set_config('request.jwt.claims', null, true);
end
$v721$;

select case when count(*)=0
            then 'PASS — one CI gate: v83 entitlement matches the six siblings, branch restriction holds'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v721: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
