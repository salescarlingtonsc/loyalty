import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const migrationPath = 'db/migrations/20260719_frenly_v21_security_hardening.sql';
const sqlTestPath = 'db/tests/v21_security_hardening.sql';

function sqlArray(source, name) {
  const match = source.match(new RegExp(`${name} constant text\\[\\] := array\\[([\\s\\S]*?)\\]`, 'i'));
  assert.ok(match, `missing ${name} allowlist`);
  return new Set([...match[1].matchAll(/'([a-z0-9_]+)'/gi)].map((item) => item[1]));
}

function rpcNames(source) {
  return new Set([...source.matchAll(/\.rpc\(\s*'([a-z0-9_]+)'/gi)].map((item) => item[1]));
}

function authenticatedGrantNames(source) {
  return new Set([...source.matchAll(/grant execute on function public\.([a-z0-9_]+)\([^;]*?\)\s+to authenticated/gi)]
    .map((item) => item[1]));
}

function serviceGrantNames(source) {
  return new Set([...source.matchAll(/grant execute on function public\.([a-z0-9_]+)\([^;]*?\)\s+to service_role/gi)]
    .map((item) => item[1]));
}

function authenticatedGrantSignatures(source) {
  return new Set([...source.matchAll(/grant execute on function public\.([a-z0-9_]+)\(([^)]*)\)\s+to authenticated/gi)]
    .map(([, name, args]) => `${name}(${args.replaceAll(/\s+/g, '')})`));
}

function sqlSignatureArray(source, name) {
  const match = source.match(new RegExp(`${name} constant text\\[\\] := array\\[([\\s\\S]*?)\\]`, 'i'));
  assert.ok(match, `missing ${name} signature set`);
  return new Set([...match[1].matchAll(/'(app\.[a-z0-9_]+\([^']*\))'/gi)].map((item) => item[1]));
}

test('v21 is the single canonical post-v20 security migration', async () => {
  const [v18, v19, v20, v21] = await Promise.all([
    read('db/migrations/20260718135940_frenly_v18_scalable_reporting.sql'),
    read('db/migrations/20260718180602_frenly_v19_public_gateway_security.sql'),
    read('db/migrations/20260719_frenly_v20_financial_engine.sql'),
    read(migrationPath),
  ]);
  assert.ok(v18.length > 0 && v19.length > 0 && v20.length > 0);
  assert.match(v21, /v18 reporting -> v19 gateway\s+-- -> v20 financial engine -> v21 security hardening/i);
  assert.match(v21, /^begin;/im);
  assert.match(v21, /^commit;/im);
});

test('authenticated RPC allowlist plus exact forward v41-C46/v47-v117 grants cover the shipped SPA', async () => {
  const [app, migration, v41, c42, c44, c45, c46, v47, v48, v49, v50, v51, v51a, v51b, v52, v53, v53a, v54, v55, v56, v57, v58, v60, v61, v62, v63, v64, v66, v67, v68a, v68c, v69, v70, v72, v73, v74, v75, v76, v77, v78, v79, v80, v81, v82, v83, v84, v85, v86, v87, v88, v89, v90, v91, v93, v94, v95, v96, v97, v99, v100, v102, v104, v115, v116, v117] = await Promise.all([
    read('app/index.html'), read(migrationPath),
    read('db/migrations/20260721_frenly_v41_customer_module_hardening.sql'),
    read('db/migrations/20260721_frenly_v42_consumer_registration_contracts.sql'),
    read('db/migrations/20260721_frenly_v44_actionable_customer_wallet.sql'),
    read('db/migrations/20260721_frenly_v45_birthday_benefits.sql'),
    read('db/migrations/20260722_frenly_v46_customer_in_app_inbox.sql'),
    read('db/migrations/20260722050339_frenly_v47_smart_staff_scheduling.sql'),
    read('db/migrations/20260722_frenly_v48_calendar_details_reschedule.sql'),
    read('db/migrations/20260722_frenly_v49_billing_projection_rpc.sql'),
    read('db/migrations/20260722_frenly_v50_retention_measurement.sql'),
    read('db/migrations/20260723_frenly_v51_sale_line_items.sql'),
    read('db/migrations/20260723_frenly_v51a_idempotent_sell_overloads.sql'),
    read('db/migrations/20260723_frenly_v51b_client_credit_history.sql'),
    read('db/migrations/20260723_frenly_v52_sgt_date_normalization.sql'),
    read('db/migrations/20260723_frenly_v53_visit_feedback.sql'),
    read('db/migrations/20260723_frenly_v53a_wallet_review_url.sql'),
    read('db/migrations/20260723_frenly_v54_f2_write_hardening.sql'),
    read('db/migrations/20260724_frenly_v55_ps1a_authoring.sql'),
    read('db/migrations/20260724_frenly_v56_ps1b_events_execution.sql'),
    read('db/migrations/20260724_frenly_v57_ps1b1_price_fail_closed.sql'),
    read('db/migrations/20260724_frenly_v58_ps1c_checkout_kernel.sql'),
    read('db/migrations/20260724_frenly_v60_ps1c2_execution_state.sql'),
    read('db/migrations/20260724_frenly_v61_ps2a_stored_value_foundation.sql'),
    read('db/migrations/20260724_frenly_v62_ps2b_shadow_reconciliation.sql'),
    read('db/migrations/20260724_frenly_v63_ps2c_redemption_mechanics.sql'),
    read('db/migrations/20260724_frenly_v64_ps2d_pause_controls.sql'),
    read('db/migrations/20260724_frenly_v66_ps2live_topup_sale.sql'),
    read('db/migrations/20260724_frenly_v67_ps2live_checkout_tender.sql'),
    read('db/migrations/20260724_frenly_v68a_chargeback_correction.sql'),
    read('db/migrations/20260724_frenly_v68c_customer_gift_cards.sql'),
    read('db/migrations/20260724_frenly_v69_controlled_cutover.sql'),
    read('db/migrations/20260724_frenly_v70_legacy_non_overlap.sql'),
    read('db/migrations/20260726_frenly_v72_booking_identity_sync.sql'),
    read('db/migrations/20260726_frenly_v73_booking_lifecycle.sql'),
    read('db/migrations/20260726_frenly_v74_staff_module_permissions.sql'),
    read('db/migrations/20260726_nestly_v75_sector_entitlements.sql'),
    read('db/migrations/20260726_nestly_v76_sme_crm.sql'),
    read('db/migrations/20260726_nestly_v77_stripe_billing.sql'),
    read('db/migrations/20260726_nestly_v78_consultant_commissions.sql'),
    read('db/migrations/20260726_nestly_v79_conversion_onboarding.sql'),
    read('db/migrations/20260726_nestly_v80_customer_legal_manifest.sql'),
    read('db/migrations/20260726_nestly_v81_customer_relationship_sync.sql'),
    read('db/migrations/20260726_nestly_v82_enterprise_intelligence.sql'),
    read('db/migrations/20260726_nestly_v83_customer_intelligence.sql'),
    read('db/migrations/20260726_nestly_v84_fast_sale_corrections.sql'),
    read('db/migrations/20260726_nestly_v85_conversion_guard_repair.sql'),
    read('db/migrations/20260726_nestly_v86_enterprise_sme_crm.sql'),
    read('db/migrations/20260726_nestly_v87_overdue_appointment_amendments.sql'),
    read('db/migrations/20260726_nestly_v88_platform_firm_onboarding.sql'),
    read('db/migrations/20260727_nestly_v89_customer_qr_redemption_platform_access.sql'),
    read('db/migrations/20260727_nestly_v90_production_readiness.sql'),
    read('db/migrations/20260727_nestly_v91_customer_game_notifications.sql'),
    read('db/migrations/20260728_nestly_v93_branch_scoped_merchant_redemption.sql'),
    read('db/migrations/20260728_nestly_v94_platform_control_intelligence.sql'),
    read('db/migrations/20260728_nestly_v95_bilingual_programmes.sql'),
    read('db/migrations/20260729_nestly_v96_customer_programme_selector_media.sql'),
    read('db/migrations/20260729_nestly_v97_workspace_interface_localization.sql'),
    read('db/migrations/20260729_nestly_v99_campaign_truth.sql'),
    read('db/migrations/20260729_nestly_v100_product_adoption_events.sql'),
    read('db/migrations/20260729_nestly_v102_package_checkout_entitlements.sql'),
    read('db/migrations/20260729_nestly_v104_marketing_offers.sql'),
    read('db/migrations/20260730_nestly_v115_effective_module_projection.sql'),
    read('db/migrations/20260730_nestly_v116_classic_reward_projection.sql'),
    read('db/migrations/20260730_nestly_v117_effective_loyalty_boundaries.sql')
  ]);
  const allowlist = sqlArray(migration, 'v_authenticated_rpc_names');
  const forward = new Set([...authenticatedGrantNames(v41), ...authenticatedGrantNames(c42), ...authenticatedGrantNames(c44), ...authenticatedGrantNames(c45), ...authenticatedGrantNames(c46), ...authenticatedGrantNames(v47), ...authenticatedGrantNames(v48), ...authenticatedGrantNames(v49), ...authenticatedGrantNames(v50), ...authenticatedGrantNames(v51), ...authenticatedGrantNames(v51a), ...authenticatedGrantNames(v51b), ...authenticatedGrantNames(v52), ...authenticatedGrantNames(v53), ...authenticatedGrantNames(v53a), ...authenticatedGrantNames(v54), ...authenticatedGrantNames(v55), ...authenticatedGrantNames(v56), ...authenticatedGrantNames(v57), ...authenticatedGrantNames(v58), ...authenticatedGrantNames(v60), ...authenticatedGrantNames(v61), ...authenticatedGrantNames(v62), ...authenticatedGrantNames(v63), ...authenticatedGrantNames(v64), ...authenticatedGrantNames(v66), ...authenticatedGrantNames(v67), ...authenticatedGrantNames(v68a), ...authenticatedGrantNames(v68c), ...authenticatedGrantNames(v69), ...authenticatedGrantNames(v70), ...authenticatedGrantNames(v72), ...authenticatedGrantNames(v73), ...authenticatedGrantNames(v74), ...authenticatedGrantNames(v75), ...authenticatedGrantNames(v76), ...authenticatedGrantNames(v77), ...authenticatedGrantNames(v78), ...authenticatedGrantNames(v79), ...authenticatedGrantNames(v80), ...authenticatedGrantNames(v81), ...authenticatedGrantNames(v82), ...authenticatedGrantNames(v83), ...authenticatedGrantNames(v84), ...authenticatedGrantNames(v85), ...authenticatedGrantNames(v86), ...authenticatedGrantNames(v87), ...authenticatedGrantNames(v88), ...authenticatedGrantNames(v89), ...authenticatedGrantNames(v90), ...authenticatedGrantNames(v91), ...authenticatedGrantNames(v93), ...authenticatedGrantNames(v94), ...authenticatedGrantNames(v95), ...authenticatedGrantNames(v96), ...authenticatedGrantNames(v97), ...authenticatedGrantNames(v99), ...authenticatedGrantNames(v100), ...authenticatedGrantNames(v102), ...authenticatedGrantNames(v104), ...authenticatedGrantNames(v115), ...authenticatedGrantNames(v116), ...authenticatedGrantNames(v117)]);
  const required = rpcNames(app);
  for (const rpc of required) {
    assert.ok(allowlist.has(rpc) || forward.has(rpc),
      `shipped app RPC ${rpc} is missing from v21 or its exact forward migration grants`);
  }
  assert.ok(allowlist.has('set_staff_modules'),
    'the legacy staff-module compatibility name must remain registered');
  const v74Signatures = authenticatedGrantSignatures(v74);
  for (const signature of [
    'set_staff_module_permissions_v74(uuid,jsonb)',
    'set_staff_modules(uuid,text[])',
    'set_staff_role_v74(uuid,text)'
  ]) {
    assert.ok(v74Signatures.has(signature), `v74 must grant exactly ${signature}`);
  }
  const c44Signatures = authenticatedGrantSignatures(c44);
  for (const signature of [
    'customer_get_actionable_wallet()',
    'customer_get_actionable_business(text)'
  ]) {
    assert.ok(c44Signatures.has(signature), `C44 must grant exactly ${signature} to authenticated`);
    assert.match(c44, new RegExp(`revoke all on function public\\.${signature.replace(/[()]/g, '\\$&')}\\s+from public, anon, authenticated`, 'i'),
      `C44 must revoke ${signature} before its authenticated-only grant`);
  }
  const c42Signatures = authenticatedGrantSignatures(c42);
  for (const signature of [
    'customer_register_verified_phone(text,date,text,boolean,boolean,boolean,text)',
    'customer_get_profile()',
    'customer_update_profile(text,text,text)',
    'customer_claim_link_by_verified_phone(text,text)'
  ]) {
    assert.ok(c42Signatures.has(signature), `C42 must grant exactly ${signature} to authenticated`);
    assert.match(c42, new RegExp(`revoke all on function public\\.${signature.replace(/[()]/g, '\\$&').replaceAll(',', '\\s*,\\s*')}\\s+from public, anon, authenticated`, 'i'),
      `C42 must revoke ${signature} before its authenticated-only grant`);
  }
  assert.ok(allowlist.has('super_admin_list_businesses'));
  assert.ok(allowlist.has('record_payment'));
  assert.ok(allowlist.has('reverse_sale'));
});

test('v21 retains only the exact legacy manual points-expiry RPC signature', async () => {
  const [app, legacy, migration, runtimeTest] = await Promise.all([
    read('app/index.html'),
    read('db/migrations/20260716_frenly_v3_engine.note.md'),
    read(migrationPath),
    read(sqlTestPath),
  ]);
  assert.match(legacy, /run_expiry_now\(business\) RPC/i);
  assert.doesNotMatch(app, /\.rpc\('run_expiry_now'/i);
  assert.equal(sqlArray(migration, 'v_authenticated_rpc_names').has('run_expiry_now'), false);
  assert.match(migration, /to_regprocedure\('public\.run_expiry_now\(uuid\)'\)/i);
  assert.match(migration, /revoke all on function public\.run_expiry_now\(uuid\)\s+from public, anon, authenticated/i);
  const expiryGrantSignatures = [...migration.matchAll(/grant execute on function public\.run_expiry_now\(([^)]*)\)/gi)]
    .map((match) => match[1]);
  assert.deepEqual(expiryGrantSignatures, ['uuid']);
  assert.match(runtimeTest, /v_expiry_proc := to_regprocedure\('public\.run_expiry_now\(uuid\)'\)/i);
  assert.match(runtimeTest, /has_function_privilege\('authenticated', v_expiry_proc, 'execute'\)/i);
  assert.match(runtimeTest, /has_function_privilege\('anon', v_expiry_proc, 'execute'\)/i);
  assert.match(runtimeTest, /unexpected run_expiry_now overload is authenticated-executable/i);
});

test('v21 retains authenticated-only execution on the exact legacy referral resolver', async () => {
  const [v20, migration, runtimeTest] = await Promise.all([
    read('db/migrations/20260719_frenly_v20_financial_engine.sql'),
    read(migrationPath),
    read(sqlTestPath),
  ]);
  assert.match(v20, /create or replace function public\.resolve_legacy_referral\(\s*p_business uuid,\s*p_referral uuid,\s*p_selected_sale uuid default null,\s*p_reason text default null\)/i);
  assert.equal(sqlArray(migration, 'v_authenticated_rpc_names').has('resolve_legacy_referral'), false);
  assert.match(migration, /to_regprocedure\('public\.resolve_legacy_referral\(uuid,uuid,uuid,text\)'\)/i);
  assert.match(migration, /revoke all on function public\.resolve_legacy_referral\(uuid, uuid, uuid, text\)\s+from public, anon, authenticated/i);
  const referralGrantSignatures = [...migration.matchAll(/grant execute on function public\.resolve_legacy_referral\(([^)]*)\)/gi)]
    .map((match) => match[1].replaceAll(' ', ''));
  assert.deepEqual(referralGrantSignatures, ['uuid,uuid,uuid,text']);
  assert.match(runtimeTest, /v_referral_proc := to_regprocedure\(\s*'public\.resolve_legacy_referral\(uuid,uuid,uuid,text\)'\)/i);
  assert.match(runtimeTest, /has_function_privilege\('authenticated', v_referral_proc, 'execute'\)/i);
  assert.match(runtimeTest, /has_function_privilege\('anon', v_referral_proc, 'execute'\)/i);
  assert.match(runtimeTest, /unexpected resolve_legacy_referral overload is authenticated-executable/i);
});

test('service-only allowlist plus v89/v95 replacements exactly cover the Edge Function call graph', async () => {
  const [migration, v89, v95, ...edgeSources] = await Promise.all([
    read(migrationPath),
    read('db/migrations/20260727_nestly_v89_customer_qr_redemption_platform_access.sql'),
    read('db/migrations/20260728_nestly_v95_bilingual_programmes.sql'),
    read('supabase/functions/_shared/gateway.ts'),
    read('supabase/functions/public-join/index.ts'),
    read('supabase/functions/public-booking/index.ts'),
    read('supabase/functions/manage-booking/index.ts'),
    read('supabase/functions/public-business-application/index.ts'),
  ]);
  const retiredByV89 = new Set(['internal_public_join', 'internal_public_join_page']);
  const allowlist = new Set(
    [...sqlArray(migration, 'v_service_rpc_names')]
      .filter((name) => !retiredByV89.has(name))
  );
  for (const name of serviceGrantNames(v89)) allowlist.add(name);
  for (const name of serviceGrantNames(v95)) allowlist.add(name);
  const required = new Set(edgeSources.flatMap((source) => [...rpcNames(source)]));
  assert.deepEqual([...allowlist].sort(), [...required].sort());
  assert.match(v89, /revoke all on function public\.internal_public_join_page\(text\)\s+from public,anon,authenticated,service_role/i);
  assert.match(v89, /revoke all on function public\.internal_public_join\(text,text,text,text,boolean\)\s+from public,anon,authenticated,service_role/i);
});

test('v21 retains every required v17 policy helper while allowing later guarded helpers', async () => {
  const [migration, runtimeTest] = await Promise.all([read(migrationPath), read(sqlTestPath)]);
  const expectedAtV21 = new Set([
    'app.can_module(uuid,text)',
    'app.can_see_branch(uuid,uuid)',
    'app.has_perm(uuid,text)',
    'app.is_salon_member(uuid)',
    'app.is_salon_owner(uuid)',
    'app.is_super_admin()',
  ]);
  const expectedAfterV41 = new Set([...expectedAtV21, 'app.can_module_read(uuid,text)']);
  assert.deepEqual(sqlSignatureArray(migration, 'v_required_policy_helper_signatures'), expectedAtV21);
  assert.deepEqual(sqlSignatureArray(runtimeTest, 'v_required_policy_helper_signatures'), expectedAfterV41);
  for (const source of [migration, runtimeTest]) {
    assert.match(source, /from pg_depend d[\s\S]+join pg_policy pol[\s\S]+d\.refclassid = 'pg_proc'::regclass/i);
    assert.match(source, /array_agg\(distinct p\.oid::regprocedure::text order by p\.oid::regprocedure::text\)/i);
  }
  assert.match(migration, /is distinct from v_required_policy_helper_signatures/i);
  assert.match(runtimeTest,
    /v_policy_helper_signatures\s*@>\s*v_required_policy_helper_signatures/i,
    'the cross-version runtime test must retain the complete required dependency subset');
  assert.doesNotMatch(runtimeTest,
    /v_policy_helper_signatures\s*<@\s*v_required_policy_helper_signatures/i,
    'later migrations may add independently reviewed policy helpers');
  assert.match(migration, /to_regprocedure\(required\.signature\)/i);
  assert.match(migration, /grant execute on function %s to authenticated/i);
  assert.match(runtimeTest, /has_function_privilege\('authenticated', v_proc\.oid, 'execute'\)/i);
  assert.match(runtimeTest, /has_function_privilege\('anon', v_proc\.oid, 'execute'\)/i);
});

test('v21 closes default-PUBLIC definer grants without widening other ACLs', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /revoke all on function %s from public, anon, authenticated/i);
  assert.match(migration, /grant execute on function %s to service_role/i);
  assert.match(migration, /alter function %s set search_path to pg_catalog, public, app, pg_temp/i);
  assert.match(migration, /'super_admin_list_businesses'/i);
  assert.doesNotMatch(migration, /grant execute on function %s to anon/i);
});

test('v21 removes only unrestricted direct intake and preserves create_business onboarding', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /drop policy if exists salons_insert on public\.businesses/i);
  assert.match(migration, /revoke insert on table public\.businesses from public, anon, authenticated/i);
  assert.match(migration, /drop policy if exists leads_insert_anon on public\.leads/i);
  assert.match(migration, /revoke insert, update, delete, truncate on table public\.leads/i);
  assert.doesNotMatch(migration, /revoke update on table public\.businesses/i);
  assert.match(migration, /'create_business'/i);
});

test('runtime catalog test rejects anonymous definer RPCs and always-true write policies', async () => {
  const sqlTest = await read(sqlTestPath);
  assert.match(sqlTest, /has_function_privilege\('anon', p\.oid, 'execute'\)/i);
  assert.match(sqlTest, /aclexplode\(coalesce\(p\.proacl, acldefault\('f', p\.proowner\)\)\)/i);
  assert.match(sqlTest, /has_function_privilege\('service_role', p\.oid, 'execute'\)/i);
  assert.match(sqlTest, /pol\.polcmd in \('a', 'w', '\*'\)/i);
  assert.match(sqlTest, /always-true public write policy remains/i);
  assert.match(sqlTest, /unapproved or missing search_path/i);
  assert.match(sqlTest, /approved SECURITY DEFINER search_path schema is browser-writable/i);
  assert.match(sqlTest, /has_schema_privilege\('authenticated',n\.oid,'create'\)/i);
  assert.match(sqlTest, /legacy unrestricted intake policy remains/i);
});
