-- EXECUTED regression fixture for nestly_v720 -- app.v176_evidence_pack access boundaries, and
-- an estate scan of every schema-`app` function reachable by anon/authenticated.
--
-- BACKGROUND. A refuter reported app.v176_evidence_pack(uuid,text,date,date) as PUBLIC-executable
-- -- ACL `{=X/postgres,...}` -- reachable by any authenticated session to read any business's
-- consultative report evidence (revenue, growth, retention, top customers). Checked directly
-- against production (gadpooereceldfpfxsod, read-only query, 2026-09-02): the function was
-- ALREADY owner-only there. The PUBLIC grant existed only in this local rehearsal harness, caused
-- by `pg_dump --no-privileges` stripping the ACL of every pre-watermark `app` routine on restore
-- (scripts/db-tests/snapshot-schema.mjs) -- Postgres's own default then re-grants EXECUTE to
-- PUBLIC on the bare CREATE FUNCTION the dump replays. Fixed at the source in
-- scripts/db-tests/baseline-grants.sql (same date): the harness now revokes EXECUTE on every
-- `app` function from public/anon/authenticated after restoring the snapshot, then re-grants
-- exactly what production actually exposes there.
--
-- nestly_v720 (db/migrations/20260920_nestly_v720_evidence_pack_grants.sql) is belt-and-braces
-- on top of that harness fix: it restates the revoke on app.v176_evidence_pack explicitly (a
-- no-op against the already-correct production ACL) AND adds an INTERNAL gate inside the
-- function body -- app.v676_internal_drain_active() OR app.v176_can_read_firm_report(p_business)
-- -- mirroring the table's own RLS policy (ai_firm_reports_v176_read), so the pack cannot be
-- misread even by a caller who reaches it some way the ACL does not cover (a future SECURITY
-- DEFINER chain, a mis-scoped service-role RPC, a superuser session running ad hoc SQL).
--
-- PART A (below) proves both layers under eight identities. PART B is an estate scan: every
-- function in schema `app` with EXECUTE granted to PUBLIC/anon/authenticated must be a member of
-- an explicit, justified allowlist, so a function that starts being exposed tomorrow fails this
-- suite by name.
--
-- Named for v720: every PART A assertion must FAIL against the frozen baseline (the internal gate
-- and the restated revoke do not exist there). One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

-- =================================================================================================
-- PART A -- app.v176_evidence_pack under eight identities, plus the raw ACL.
-- =================================================================================================
do $v720a$
declare
  biz_a       uuid := '00000000-0000-4000-8000-0000000720a1';
  biz_b       uuid := '00000000-0000-4000-8000-0000000720a2';
  u_sa        uuid := '00000000-0000-4000-8000-0000000720b1';
  u_cons      uuid := '00000000-0000-4000-8000-0000000720b2'; -- assigned to biz_a
  u_cons_off  uuid := '00000000-0000-4000-8000-0000000720b3'; -- NOT assigned to biz_a
  u_owner_a   uuid := '00000000-0000-4000-8000-0000000720b4';
  u_owner_b   uuid := '00000000-0000-4000-8000-0000000720b5'; -- cross-tenant owner
  u_customer  uuid := '00000000-0000-4000-8000-0000000720b6'; -- no staff/consultant tie at all
  cons_id     uuid := '00000000-0000-4000-8000-0000000720c1';
  cons_off_id uuid := '00000000-0000-4000-8000-0000000720c2';
  co_id       uuid := '00000000-0000-4000-8000-0000000720c3';
  d_start     date := date_trunc('month', current_date - 35)::date;
  d_end       date := (date_trunc('month', current_date - 35) + interval '1 month'
                        - interval '1 day')::date;
  v_pack      jsonb;
  v_err       text;
  v_ok        boolean;
  v_role      text;
  v_bypassed  boolean;
  v_role_err  text;
begin
  ---------------------------------------------------------------------------
  -- fixture: two firms, a consultant assigned to firm A only, a second (unassigned) consultant,
  -- a super admin, a customer with no relationship to either firm.
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_sa,'zz-v720-sa@example.test'), (u_cons,'zz-v720-cons@example.test'),
    (u_cons_off,'zz-v720-cons-off@example.test'), (u_owner_a,'zz-v720-oa@example.test'),
    (u_owner_b,'zz-v720-ob@example.test'), (u_customer,'zz-v720-cust@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (u_sa,'zz-v720-sa@example.test') on conflict do nothing;

  insert into public.businesses (id, name, slug, is_demo, is_synthetic) values
    (biz_a,'ZZ v720 firm A','zz-v720-a', false, false),
    (biz_b,'ZZ v720 firm B','zz-v720-b', false, false)
  on conflict (id) do nothing;
  insert into public.staff (business_id, user_id, role, full_name, active, access_state) values
    (biz_a, u_owner_a, 'owner', 'ZZ v720 owner A', true, 'approved'),
    (biz_b, u_owner_b, 'owner', 'ZZ v720 owner B', true, 'approved')
  on conflict do nothing;

  /* Workspace-open preconditions -- v620 gates every membership/consultant check on approval +
     an active, unexpired subscription. Miss either and every refusal below is a billing refusal,
     not the access-boundary refusal this fixture measures -- the vacuous-pass trap (see v667). */
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  select b, 'approved', now(), 'v720 evidence-pack fixture' from unnest(array[biz_a,biz_b]) b
  on conflict (business_id) do update
    set approval_status='approved', decided_at=now(), decision_reason='v720 evidence-pack fixture';
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  select b, 'current', false from unnest(array[biz_a,biz_b]) b
  on conflict (business_id) do update set state='current', workspace_paused=false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  select b, 'active', 'paid', now() + interval '30 days' from unnest(array[biz_a,biz_b]) b
  on conflict (business_id) do update
    set status='active', payment_status='paid', current_period_end=now() + interval '30 days';

  /* Consultant assignment reads through sme_prospects.converted_business_id
     (app.assigned_consultant_v94) -- the prospect row IS the assignment. u_cons is assigned to
     firm A; u_cons_off is a real, active consultant assigned to NOTHING, which is what makes
     "unassigned consultant" meaningful rather than "not a consultant at all". */
  insert into public.platform_consultants
    (id, user_id, display_name, tier, employment_started_on, active) values
    (cons_id, u_cons, 'ZZ v720 consultant (assigned)', 'senior', current_date - 400, true),
    (cons_off_id, u_cons_off, 'ZZ v720 consultant (unassigned)', 'senior', current_date - 200, true)
  on conflict (id) do nothing;
  insert into public.sme_companies (id, legal_name, trading_name)
    values (co_id, 'ZZ v720 Firm A Pte Ltd', 'ZZ v720 Firm A')
  on conflict (id) do nothing;
  insert into public.sme_prospects (company_id, legacy_stage_raw, assigned_consultant_id,
                                    ownership_state, queue_key,
                                    converted_business_id, converted_at, converted_by)
  select co_id, 'zz-v720-fixture', cons_id, 'owned', null, biz_a, clock_timestamp(), u_sa
  where not exists (
    select 1 from public.sme_prospects where converted_business_id = biz_a
  );

  ---------------------------------------------------------------------------
  -- ACL layer: revoked from anon/authenticated/service_role at the SQL level, regardless of
  -- identity. Switching the DATABASE ROLE (not just the JWT claim) is what makes this a real
  -- check of the grant rather than of the internal gate -- see "verify as the real role" in
  -- this repo's own house rules: a probe run as postgres/owner never engages any ACL.
  ---------------------------------------------------------------------------
  foreach v_role in array array['anon','authenticated'] loop
    /* Record the outcome in a LOCAL variable, not directly into _fail, and write _fail only
       AFTER `reset role`. _fail is a temp table owned by this session's original role
       (postgres); an INSERT into it attempted while still running as anon/authenticated would
       itself raise insufficient_privilege -- and, written inline inside this same try block,
       that unrelated failure would be swallowed by the `when insufficient_privilege then null`
       arm below and misread as "the ACL correctly refused the call", silently hiding a real
       bypass. Caught in dry-run before this fixture was believed to pass. */
    v_bypassed := null;
    begin
      execute format('set local role %I', v_role);
      perform app.v176_evidence_pack(biz_a, 'monthly', d_start, d_end);
      v_bypassed := true;
    exception
      when insufficient_privilege then v_bypassed := false; -- expected
      when others then
        get stacked diagnostics v_err = returned_sqlstate;
        v_bypassed := null; -- neither pass nor the expected refusal
        v_role_err := v_err;
    end;
    reset role;
    if v_bypassed is true then
      insert into _fail values ('A0-acl',
        format('role %s executed app.v176_evidence_pack despite the revoked ACL', v_role));
    elsif v_bypassed is null then
      insert into _fail values ('A0-acl',
        format('role %s failed with %s, expected 42501 (insufficient_privilege)', v_role, v_role_err));
    end if;
  end loop;

  ---------------------------------------------------------------------------
  -- Internal-gate layer. Called as the table owner (this session, postgres) so the ACL cannot
  -- shortcut the test either way -- only auth.uid()/the drain token varies. This is what proves
  -- the gate is real and not merely decorative behind an ACL that already blocks everyone.
  ---------------------------------------------------------------------------

  -- A1 -- cross-tenant owner: firm B's owner must never read firm A's evidence pack.
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_b,'role','authenticated')::text, true);
  begin
    perform app.v176_evidence_pack(biz_a, 'monthly', d_start, d_end);
    insert into _fail values ('A1','a cross-tenant owner read another firm''s evidence pack');
  exception
    when sqlstate '42501' then null;
    when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('A1', format('refused with %s, expected 42501', v_err));
  end;

  -- A2 -- unassigned consultant: a real, active consultant with no assignment to firm A.
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_cons_off,'role','authenticated')::text, true);
  if app.v176_is_assigned_consultant(biz_a) then
    insert into _fail values ('A2-pre',
      'the unassigned consultant fixture resolves as assigned; A2 would be vacuous');
  end if;
  begin
    perform app.v176_evidence_pack(biz_a, 'monthly', d_start, d_end);
    insert into _fail values ('A2','an unassigned consultant read the evidence pack');
  exception
    when sqlstate '42501' then null;
    when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('A2', format('refused with %s, expected 42501', v_err));
  end;

  -- A3 -- customer: a session with no staff row and no consultant row anywhere.
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_customer,'role','authenticated')::text, true);
  begin
    perform app.v176_evidence_pack(biz_a, 'monthly', d_start, d_end);
    insert into _fail values ('A3','an unrelated customer session read the evidence pack');
  exception
    when sqlstate '42501' then null;
    when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('A3', format('refused with %s, expected 42501', v_err));
  end;

  -- A4 -- anon: no session at all, no drain open.
  perform set_config('request.jwt.claims', '', true);
  begin
    perform app.v176_evidence_pack(biz_a, 'monthly', d_start, d_end);
    insert into _fail values ('A4','a sessionless, drain-closed caller read the evidence pack');
  exception
    when sqlstate '42501' then null;
    when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('A4', format('refused with %s, expected 42501', v_err));
  end;

  -- A5 -- business owner. nestly_v720's third gate arm is app.has_perm(p_business,
  --       'view_finance'): an AI firm report is a paid feature of the firm's OWN dashboard, not
  --       platform-console-only, and app.has_perm is the canonical financial-visibility
  --       authority every other reader in this codebase defers to. Owner A must be SERVED.
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_owner_a,'role','authenticated')::text, true);
  if not app.is_salon_owner(biz_a) then
    insert into _fail values ('A5-pre','the fixture owner does not resolve as the firm''s owner; A5 would be vacuous');
  end if;
  if not app.has_perm(biz_a,'view_finance') then
    insert into _fail values ('A5-pre',
      'the fixture owner lacks view_finance, so A5 would not be testing nestly_v720''s third gate arm');
  end if;
  begin
    v_pack := app.v176_evidence_pack(biz_a, 'monthly', d_start, d_end);
    if not (v_pack ? 'contract_version') then
      insert into _fail values ('A5','the firm''s own owner got a malformed pack (no contract_version)');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('A5', format('the firm''s own owner was refused (%s)', v_err));
  end;

  -- A6 -- assigned consultant: must be SERVED (a fix that denies everyone is not a fix).
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_cons,'role','authenticated')::text, true);
  if not app.v176_is_assigned_consultant(biz_a) then
    insert into _fail values ('A6-pre','the assigned-consultant fixture does not resolve as assigned; A6 would be vacuous');
  end if;
  begin
    v_pack := app.v176_evidence_pack(biz_a, 'monthly', d_start, d_end);
    v_ok := v_pack ? 'contract_version';
    if not v_ok then
      insert into _fail values ('A6','the assigned consultant got a malformed pack (no contract_version)');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('A6', format('the assigned consultant was refused (%s)', v_err));
  end;

  -- A7 -- super admin, WITH a real Google-SSO session shape (v625: is_super_admin() also
  --       requires amr[0].method='oauth' + app_metadata.providers containing 'google'; a bare
  --       sub-only claim would refuse by design and prove nothing about A7).
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  if not app.is_super_admin() then
    insert into _fail values ('A7-pre','the SA fixture session does not resolve as super admin; A7 would be vacuous');
  end if;
  begin
    v_pack := app.v176_evidence_pack(biz_a, 'monthly', d_start, d_end);
    if not (v_pack ? 'contract_version') then
      insert into _fail values ('A7','the super admin got a malformed pack (no contract_version)');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('A7', format('the super admin was refused (%s)', v_err));
  end;

  perform set_config('request.jwt.claims', '', true);

  -- A8 -- sessionless internal drain: the one production caller
  --       (public.internal_claim_ai_firm_report_v176) must still be served.
  perform app.v676_open_internal_drain();
  begin
    v_pack := app.v176_evidence_pack(biz_a, 'monthly', d_start, d_end);
    if not (v_pack ? 'contract_version') then
      insert into _fail values ('A8','the sessionless internal drain got a malformed pack');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('A8', format('the sessionless internal drain was refused (%s)', v_err));
  end;
  perform app.v676_close_internal_drain();

  -- A9 -- the drain must not leak: once closed, a sessionless caller is refused again exactly
  --       like A4. (Same predicate as A4, different order in the fixture -- proves the drain is
  --       a WINDOW, not a standing exemption.)
  begin
    perform app.v176_evidence_pack(biz_a, 'monthly', d_start, d_end);
    insert into _fail values ('A9','a sessionless caller read the pack after the drain was closed');
  exception
    when sqlstate '42501' then null;
    when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('A9', format('refused with %s, expected 42501', v_err));
  end;
end
$v720a$;

-- =================================================================================================
-- PART B -- estate scan. Every function in schema `app` with EXECUTE granted to
-- PUBLIC/anon/authenticated must be named in one of two lists below, or the migration that
-- exposed it fails this suite.
--
--   v_allowlist_43  -- verified against production (gadpooereceldfpfxsod), read-only query,
--                      2026-09-02. Each entry carries the internal check it performs (or, for a
--                      pure value/format helper with no session-scoped data, "no session data --
--                      deterministic/lookup only").
--   v_known_other   -- NOT verified by this migration. Found by this same scan to already be
--                      exposed (schema-app EXECUTE to anon/authenticated) as of 2026-09-02,
--                      created by unrelated, concurrently in-flight migrations (v514-v718) this
--                      task was not scoped to audit. Recorded here, rather than silently ignored,
--                      so this scan still catches anything NEW beyond both lists -- and flagged
--                      separately for its own estate audit (see the spawned follow-up task).
--                      A name in this list is NOT a statement that the exposure is safe.
-- =================================================================================================
do $v720b$
declare
  v_allowlist_43 constant text[] := array[
    -- authority primitives -- the check IS the function; nothing above them to delegate to.
    'is_super_admin',            -- super_admins membership AND v625 Google-SSO session shape
    'is_salon_member',           -- workspace-open AND an active/approved staff row for auth.uid()
    'is_salon_owner',            -- same, role = owner
    'has_perm',                  -- workspace-open AND staff row AND p_perm in app.role_perms(role)
    'can_module','can_module_read','can_module_write',
    'can_module_read_at_v94','can_module_write_at_v94', -- staff module mode for auth.uid()'s staff row
    'can_see_branch','staff_can_see_branch',            -- auth.uid() null/SA/staff-branch checks inline
    'role_class','role_perms',   -- pure role-name -> static permission-set lookup, no row data
    -- v176 firm-report authority chain
    'v176_can_read_firm_report', -- auth.uid() not null AND (is_super_admin OR platform_firm_report_access_v94)
    'v176_is_assigned_consultant', -- auth.uid() not null AND assigned_consultant_v94() match
    'v177_can_view_workspace',   -- auth.uid() not null AND (is_super_admin OR v176_is_assigned_consultant)
    -- customer-facing feedback (v53) -- gated on the caller's own linked customer identity
    'v53_customer_feedback_context', -- raises 28000 when auth.uid() is null; scopes to the caller's own link
    'v53_feedback_link_visible',     -- exists() scoped to auth.uid() through customer_identities
    'v53_feedback_json','v53_feedback_staff_json', -- pure row->jsonb shape helpers, no auth of their own
                                                     -- (safe: callable only with a row already read under RLS)
    -- reporting scope / branch resolution -- session-gated internally
    'resolve_reporting_branch_scope_v154','resolve_reporting_branch_scope_v155', -- raises 28000 if auth.uid() is null
    'reporting_scope_label_v154','reporting_scope_label_v155', -- delegates to the resolvers above
    'reports_gift_card_liability_v49b', -- auth.uid() null / has_perm('view_sales') / module-scope checks inline
    'promotion_available_at_branch_v155', -- pure branch/plan lookup, no customer or financial data
    'branch_offers_package_v627','branch_offers_product_v627', -- same, product/package branch scoping
    -- deterministic value/format helpers -- no session-scoped row data, safe to expose as pure functions
    'analytics_business_included_v1','analytics_sale_class_v1','metric_observed_since_v1',
    'customer_demographics_v1',  -- explicit 42501 guard: is_salon_member OR is_super_admin
    'evidence_block_v1','campaign_holdout_bucket','normalized_business_identity_v79',
    'package_expires_at_v593','norm_phone','phone_match_key',
    'sale_policy_defaults',      -- static per-sale-kind default table, no business/customer data
    -- trigger plumbing -- Postgres refuses to invoke a trigger function outside trigger context
    -- regardless of EXECUTE, so the grant is inert; kept in the allowlist because it is real,
    -- verified production state, not because the grant is meaningful.
    'forbid_mutation','touch_updated_at',
    'v95_storage_path_owned'     -- pure filename-shape predicate, no row access
  ];
  v_known_other constant text[] := array[
    -- ****************************************************************************************
    -- SHRUNK 2026-09-02 (security audit, branch claude/ci-proof-100): sixteen pure CI/stat
    -- helpers that were granted `to authenticated, service_role` in their own migrations
    -- (v672/v683/v684/v686/v690/v696/v699/v705/v709/v711/v714/v718) with no internal auth check
    -- and no invoker-rights caller (grepped app.js for a direct .rpc() call and every migration's
    -- RLS policies -- none reach these by name; every real caller is a SECURITY DEFINER reader
    -- that already runs as table owner) were revoked from authenticated and re-granted to
    -- service_role only: subgroup_evidence_v1, rate_block_v1, distribution_block_v1,
    -- comparisons_note_v1, rate_block_floor_gated_v683, ci_metric_dictionary_v1,
    -- ci_customer_classes_v1, erf_v686, normal_two_tailed_p_v686, two_prop_p_value_v686,
    -- ci_floor_registry_v690, ci_verdict_class_v696, ci_visit_day_v699, ci_visit_registry_v699,
    -- ci_materiality_threshold_bps_v705, ci_standard_incentive_cents_v718. The three FLAGGED
    -- v724 entries this list used to carry below (v176_sales_window/v177_sales_window/
    -- v177_customers -- explicit `grant ... to public`, no internal check, same "arbitrary
    -- business revenue for a plain uuid argument" shape as app.v176_evidence_pack itself)
    -- were fixed the same way: revoked from public and re-granted to service_role only,
    -- restoring the original nestly_v176/v177 owner-only ACL. All nineteen are removed from
    -- this array below because the estate scan (PART B) no longer finds them exposed to
    -- anon/authenticated at all -- they need no allowlist entry, justified or otherwise.
    -- app.customer_demographics_v1 is NOT in this removal set: it carries its own internal
    -- gate (auth.uid() is not null AND (is_salon_member OR is_super_admin), nestly_v674) and
    -- stays correctly granted to authenticated, listed in v_allowlist_43 above.
    -- ****************************************************************************************
    -- REMAINING, still NOT cleared by this audit: created by migrations outside this task's
    -- scope (v479, v514, v531, v572, v628-v650, v691 -- not in the v672-v724 set this audit was
    -- asked to grep), found exposed to anon/authenticated by this same PART B scan, and not
    -- individually reviewed here. A name in this list is NOT a statement that the exposure is
    -- safe -- most read as trigger-plumbing (Postgres refuses to invoke a trigger function
    -- outside trigger context regardless of EXECUTE, same shape as forbid_mutation/
    -- touch_updated_at in v_allowlist_43 above) but that has not been verified per-function the
    -- way the sixteen above were. Flagged for its own estate audit (follow-up task already
    -- spawned, see nestly_v720's original header).
    'appointment_status_events_guard_v631','appointments_rebook_guard_v632',
    'appointments_status_event_v631','attribution_associations_guard_v635',
    'bump_customer_wallet_signal_v479','business_pack_v648',
    'ci_effective_node_v650','ci_reports_gate_v650',
    'clients_first_acquisition_default_v629','clients_first_acquisition_guard_v629',
    'consents_no_update_v572','discovery_dim_label_v691',
    'redemption_sale_links_guard_v630',
    'retention_cooldown_days_v572','rollup_guard_v646','sale_items_category_stamp_v649',
    'sales_operator_default_v683','seed_customer_capabilities_v514',
    'service_map_history_guard_v648','service_map_history_v648',
    'support_extract_entry_token_v531','support_strip_entry_token_v531','taxonomy_guard_v647',
    'tier_observe_from_ladder_v633','tier_observe_from_ledger_v633',
    'tier_observe_from_sale_v633','tier_transition_events_guard_v633',
    'v515_gift_intent_guard','v550_attention_outreach_immutable','v551_retention_status_rank',
    'v665_gift_reversal_guard','watermark_guard_v628'
    -- nestly_v729 (db/migrations/20260920_nestly_v729_visit_days_estate_3.sql) briefly
    -- re-regressed app.ci_metric_dictionary_v1 and app.ci_visit_registry_v699 back to
    -- `authenticated, service_role` via its own anchored CREATE OR REPLACE; both are now
    -- corrected back to service_role-only ACLs in that same migration, so neither needs an
    -- allowlist entry here -- the estate scan (PART B) finds them clean, matching the
    -- sixteen documented above.
  ];
  v_baseline constant text[] := v_allowlist_43 || v_known_other;
  v_exposed  text[];
  v_new      text[];
  v_locked   text[] := array[
    'app.v176_evidence_pack(uuid,text,date,date)',
    'app.v176_gated_evidence(uuid,date,date)',
    'app.ci_access_gate_v667(uuid,uuid)'
  ];
  v_sig text;
begin
  select coalesce(array_agg(p.proname order by p.proname), '{}') into v_exposed
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app'
    and (
      pg_catalog.has_function_privilege('anon', p.oid, 'execute')
      or pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
    );

  select array_agg(name) into v_new
  from unnest(v_exposed) name
  where name <> all(v_baseline);

  if v_new is not null then
    insert into _fail values ('B1', format(
      'schema app now exposes %s function(s) to anon/authenticated NOT in the v720 allowlist '
      '(neither the verified-43 nor the documented pre-existing set): %s '
      '-- name it, justify it (which internal check does it perform?), and add it to '
      'v_allowlist_43 in this fixture, or revoke the grant',
      array_length(v_new,1), v_new));
  end if;

  -- The actual regression this migration closes: the three pack-path functions must never be
  -- reachable by a non-owner role, under any name variant / overload.
  foreach v_sig in array v_locked loop
    if pg_catalog.has_function_privilege('anon', v_sig, 'execute')
       or pg_catalog.has_function_privilege('authenticated', v_sig, 'execute')
       or pg_catalog.has_function_privilege('service_role', v_sig, 'execute') then
      insert into _fail values ('B2', format('%s is executable by a non-owner role', v_sig));
    end if;
  end loop;
end
$v720b$;

select case when count(*)=0
            then 'PASS -- app.v176_evidence_pack access boundaries hold; no undocumented app.* exposure'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v720: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
