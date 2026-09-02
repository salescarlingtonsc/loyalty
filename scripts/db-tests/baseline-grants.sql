-- Baseline role privileges for the executed-SQL harness.
--
-- WHY THIS FILE EXISTS
--   tests/fixtures/db-schema-snapshot.sql is produced by pg_dump with --no-privileges
--   (scripts/db-tests/snapshot-schema.mjs), so the restored baseline has the tables, the
--   policies and the routines but NO table or routine privileges for anon / authenticated /
--   service_role. Production is a Supabase project where those roles hold the standard
--   schema-wide grants, so the harness baseline was not faithful to production.
--
--   That gap was not cosmetic. v599 (browser write boundaries) revokes a specific set of
--   privileges and then asserts the resulting ACL, including that a SELECT which must
--   survive is still present. Against a privilege-less baseline that post-condition can
--   never hold, so v599 raised and the migration chain stopped there — taking EVERY
--   later migration with it. Before this file, no v6xx migration applied in the harness,
--   which silently removed the entire Customer Intelligence layer (v620-v665, including
--   v628-v652) from the only place in this repo that executes real SQL.
--
--   The second-order risk was worse than the missing coverage. A tenant-isolation test run
--   as `authenticated` against a baseline where `authenticated` holds no grants at all
--   passes for the wrong reason: it proves the role cannot read anything anywhere, not that
--   the policy scopes it to its own tenant. Restoring the grants is what makes
--   `set local role authenticated` mean what it says.
--
-- WHAT IT REPRODUCES
--   Supabase's default posture for a project's exposed schema: anon, authenticated and
--   service_role each hold schema-wide privileges on `public`, and service_role holds them
--   on the internal `app` schema too. Migrations then revoke from that baseline — which is
--   the direction the committed migrations are written in. Postgres also grants EXECUTE on
--   functions to PUBLIC by default; the explicit service_role grants below matter because a
--   migration that revokes EXECUTE `from public, anon, authenticated` would otherwise strip
--   service_role's only route to the routine along with it.
--
-- APPLIED BY scripts/db-tests/run.mjs immediately after the snapshot is restored, so it
-- lands after the objects exist and before any pending migration runs.

-- -------------------------------------------------------------------------------------------
-- nestly_v720 (part 2): production's DEFAULT PRIVILEGES, not just its current objects.
--
-- Read from prod (gadpooereceldfpfxsod, read-only query on pg_default_acl, 2026-09-02):
--   * role postgres, no schema (global)   -> functions: PUBLIC has no EXECUTE by default
--     (`{postgres=X/postgres}` -- Postgres's OWN built-in "grant EXECUTE to PUBLIC on CREATE
--     FUNCTION" default is overridden off, for every schema, for anything postgres creates).
--   * role postgres, schema public        -> functions: EXECUTE to anon/authenticated/
--     service_role; tables: the full read/write set (arwdDxtm) to the same three; sequences:
--     USAGE/SELECT/UPDATE (rwU) to the same three.
--   * role postgres, schema app           -> no override at all -- app inherits the GLOBAL
--     default above (no PUBLIC EXECUTE), and nothing grants authenticated/anon anything by
--     default either. Every app.* function that IS reachable earns it through its own explicit
--     `grant execute ... to authenticated` (or, for the few exceptions in this harness, from
--     scripts/db-tests/baseline-grants.sql's own re-grant of the 43-function allowlist below).
--
-- Without this, a brand-new function created by any PENDING migration this session replays
-- (i.e. one running for the first time inside this harness, not restored from the snapshot)
-- gets Postgres's raw built-in default -- PUBLIC EXECUTE -- rather than production's overridden
-- one. That is exactly how nestly_v724's DROP-and-CREATE of app.v176_sales_window / v177_
-- customers / v177_sales_window came back anon/authenticated-executable in THIS harness only
-- (2026-09-02): the migration never grants those names to anyone, and previously nothing
-- stopped Postgres's own default from filling the gap. Set BEFORE any pending migration
-- creates anything, so every function/table/sequence created from here on inherits prod's
-- posture without needing its own migration to restate it.
-- -------------------------------------------------------------------------------------------
alter default privileges for role postgres revoke execute on functions from public;
alter default privileges for role postgres in schema public
  grant execute on functions to anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on sequences to anon, authenticated, service_role;

grant usage on schema public to anon, authenticated, service_role;

/* `authenticated` holds USAGE on `app` in production: frenly_v19_public_gateway_security grants
   `usage on schema app to authenticated, service_role`. That migration is BELOW the v422
   snapshot watermark, so the grant survives only inside the snapshot — and the snapshot strips
   privileges. Nothing replays it, so omitting it here would leave the harness STRICTER than
   production, which is the dangerous direction: an isolation test would pass locally while the
   real database is more permissive than the test believes. Individual app.* routines are still
   governed by their own explicit revokes in the migrations that define them. */
grant usage on schema app to authenticated, service_role;

grant all on all tables    in schema public to anon, authenticated, service_role;
grant all on all sequences in schema public to anon, authenticated, service_role;
grant all on all functions in schema public to anon, authenticated, service_role;

grant all on all tables    in schema app to service_role;
grant all on all sequences in schema app to service_role;
grant all on all functions in schema app to service_role;

-- -------------------------------------------------------------------------------------------
-- nestly_v720: undo pg_dump --no-privileges' default PUBLIC EXECUTE grant on schema `app`
-- functions defined BEFORE the v422 snapshot watermark.
--
-- Found: app.v176_evidence_pack (created in nestly_v176/v179, both below the watermark) carried
-- ACL {=X/postgres,service_role=X/postgres,postgres=X/postgres} in this harness -- PUBLIC
-- execute -- while the same function in production (gadpooereceldfpfxsod, read-only query,
-- 2026-09-02) carries only {postgres=X/postgres}. app.v176_gated_evidence and
-- app.ci_access_gate_v667 were checked the same way and are clean in both places, because a
-- post-watermark migration happens to touch each of THOSE by name and re-issues its revoke
-- (nestly_v676 for v176_gated_evidence; nestly_v667/v689 for ci_access_gate_v667).
-- app.v176_evidence_pack is redefined post-watermark too (v690, v713) but always by CREATE OR
-- REPLACE, which preserves whatever ACL is already there -- and what was already there, after a
-- --no-privileges restore, is Postgres's own default of PUBLIC EXECUTE on every freshly
-- (re-)created routine. Production never suffered this because its ACL is the accumulated
-- effect of every REVOKE ever actually run against it; --no-privileges is a harness-only lossy
-- step that silently discards that history for every pre-watermark routine nothing downstream
-- happens to re-touch by name.
--
-- Fix, in the harness only (production is unaffected and already correct): revoke EXECUTE on
-- every function in schema `app` from public/anon/authenticated (service_role is untouched --
-- it is not in the revoke list, and its blanket grant above already ran), then re-grant EXECUTE
-- to authenticated, and additionally to anon where marked, on EXACTLY the set production
-- exposes there. This list was read from prod with a read-only aclexplode-style query,
-- 2026-09-02; db/tests/executed/v720_corpus_evidence_pack_grants.sql asserts the live set of
-- app.* functions executable by anon/authenticated equals this same list, so a future migration
-- that grants a NEW app.* function to anon/authenticated is required to update both places
-- together or the suite fails loudly rather than silently drifting from prod again.
-- -------------------------------------------------------------------------------------------
revoke execute on all functions in schema app from public, anon, authenticated;

do $v720_app_grants$
declare
  -- authenticated only
  v_authenticated_only constant text[] := array[
    'analytics_business_included_v1','analytics_sale_class_v1','branch_offers_package_v627',
    'branch_offers_product_v627','campaign_holdout_bucket','can_module','can_module_read',
    'can_module_read_at_v94','can_module_write','can_module_write_at_v94','can_see_branch',
    'customer_demographics_v1','evidence_block_v1','has_perm','is_salon_member',
    'is_salon_owner','is_super_admin','metric_observed_since_v1',
    'normalized_business_identity_v79','package_expires_at_v593',
    'promotion_available_at_branch_v154','promotion_available_at_branch_v155',
    'reporting_scope_label_v154','reporting_scope_label_v155',
    'reports_gift_card_liability_v49b','resolve_reporting_branch_scope_v154',
    'resolve_reporting_branch_scope_v155','staff_can_see_branch',
    'v176_can_read_firm_report','v176_is_assigned_consultant','v177_can_view_workspace',
    'v53_customer_feedback_context','v53_feedback_json','v53_feedback_link_visible',
    'v53_feedback_staff_json','v95_storage_path_owned'
  ];
  -- authenticated AND anon
  v_anon_too constant text[] := array[
    'forbid_mutation','norm_phone','phone_match_key','role_class','role_perms',
    'sale_policy_defaults','touch_updated_at'
  ];
  v_all constant text[] := v_authenticated_only || v_anon_too;
  v_proc record;
  v_seen text[] := '{}';
  v_missing text[];
begin
  for v_proc in
    select p.oid, p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = any(v_all)
  loop
    execute format('grant execute on function %s to authenticated', v_proc.oid::regprocedure);
    if v_proc.proname = any(v_anon_too) then
      execute format('grant execute on function %s to anon', v_proc.oid::regprocedure);
    end if;
    v_seen := v_seen || v_proc.proname;
  end loop;

  select array_agg(name) into v_missing
  from unnest(v_all) name
  where name <> all(v_seen);

  /* NOT an error. This file runs ONCE, immediately after the snapshot restore and BEFORE any
     pending (post-watermark) migration replays -- so an allowlisted function defined by a
     pending migration (e.g. metric_observed_since_v1, analytics_sale_class_v1) legitimately
     does not exist yet here. Its own migration carries its own `grant execute ... to
     authenticated` and runs later in the same session; failing this file over that would take
     every later migration down with it (exactly the v599 incident described in the file header
     above). A RAISE EXCEPTION here was tried and reverted 2026-09-02 after it broke the harness
     for every session: verify the FULL, post-migration set instead, in
     db/tests/executed/v720_corpus_evidence_pack_grants.sql, which runs after all pending
     migrations have applied and can see the complete picture this file cannot. */
  if v_missing is not null then
    raise notice
      'baseline-grants.sql: % allowlisted app.* function(s) not present yet at the snapshot '
      'watermark (expected for ones a later migration defines): %',
      array_length(v_missing, 1), v_missing;
  end if;
end
$v720_app_grants$;
