import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const repoRoot = fileURLToPath(new URL('../..', import.meta.url));
const planPath = path.join(repoRoot, 'supabase/canonical-migration-order.plan.json');

const sqlTestByVersion = new Map([
  ['v24a', 'db/tests/v24a_redemption_idempotency.sql'],
  ['v24b', 'db/tests/v24b_module_dependencies.sql'],
  ['v24c', 'db/tests/v24c_import_foundation.sql'],
  ['v25', 'db/tests/v25_draft_onboarding.sql'],
  ['v26', 'db/tests/v26_config_versions.sql'],
  ['v27', 'db/tests/v27_rich_rewards.sql'],
  ['v28', 'db/tests/v28_reward_taxonomy.sql'],
  ['v29', 'db/tests/v29_branch_overrides_custom_fields.sql'],
  ['v30', 'db/tests/v30_customer_identity.sql'],
  ['v31', 'db/tests/v31_customer_links_claims.sql'],
  ['v32', 'db/tests/v32_customer_wallet.sql'],
  ['v33', 'db/tests/v33_customer_actions_notifications.sql'],
  ['v34', 'db/tests/v34_reversal_provenance.sql'],
  ['v35', 'db/tests/v35_retention_recommendation.sql'],
  ['v36', 'db/tests/v36_safe_draft_reward_editor.sql'],
  ['v37', 'db/tests/v37_branch_override_editor_rpc.sql'],
  ['v37b', 'db/tests/v37b_versioned_retention_taxonomy.sql'],
  ['v38', 'db/tests/v38_customer_personas_and_gates.sql'],
  ['v39', 'db/tests/v39_detailed_customer_wallet.sql'],
  ['v40', 'db/tests/v40_staff_reversal_workflows.sql'],
  ['v41', 'db/tests/v41_customer_module_hardening.sql'],
  ['c42', 'db/tests/v42_consumer_registration_contracts.sql'],
  ['c44', 'db/tests/v44_actionable_customer_wallet.sql'],
  ['c45', 'db/tests/v45_birthday_benefits.sql'],
  ['v46', 'db/tests/v46_customer_in_app_inbox.sql'],
  ['v46a', 'db/tests/v46a_birthday_draft_runtime_fix.sql'],
  ['v47', 'db/tests/v47_smart_staff_scheduling.sql'],
  ['v47a', 'db/tests/v47_smart_staff_scheduling.sql'],
  ['v47b', 'db/tests/v47_smart_staff_scheduling.sql'],
  ['v48', 'db/tests/v48_calendar_details_reschedule.sql'],
  ['v49', 'db/tests/v49_billing_projection.sql'],
  ['v49a', 'db/tests/v49a_lint_and_rehearsal_repairs.sql'],
  ['v49b', 'db/tests/v49b_reports_read_authorization.sql'],
  ['v50', 'db/tests/v50_retention_measurement.sql'],
  ['v50a', 'db/tests/v50a_sgt_birthdate_guard.sql'],
  ['v50b', 'db/tests/v50b_contact_proof_constraint_repair.sql'],
  ['v51', 'db/tests/v51_sale_line_items.sql'],
  ['v51a', 'db/tests/v51a_idempotent_sell_overloads.sql'],
  ['v51b', 'db/tests/v51b_client_credit_history.sql'],
  ['v52', 'db/tests/v52_sgt_date_normalization.sql'],
  ['v53', 'db/tests/v53_visit_feedback.sql'],
  ['v53a', 'db/tests/v53a_wallet_review_url.sql'],
  ['v54', 'db/tests/v54_f2_write_hardening.sql'],
  ['v55', 'db/tests/v55_ps1a_authoring.sql']
]);

const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const statementCount = (sql, statement) =>
  [...sql.matchAll(new RegExp(`^\\s*${statement}\\s*;\\s*$`, 'gim'))].length;

async function pendingMigrations() {
  const plan = JSON.parse(await readFile(planPath, 'utf8'));
  return plan.items.filter(({ kind }) => kind === 'pending');
}

test('all pending migrations and SQL acceptance suites have atomic boundaries', async () => {
  const pending = await pendingMigrations();
  assert.equal(pending.length, 44);
  assert.equal(sqlTestByVersion.size, pending.length);

  for (const migration of pending) {
    const migrationSql = await readFile(path.join(repoRoot, migration.sourcePath), 'utf8');
    assert.equal(statementCount(migrationSql, 'begin'), 1, `${migration.name} must begin one transaction`);
    assert.equal(statementCount(migrationSql, 'commit'), 1, `${migration.name} must commit one transaction`);

    const semanticVersion = migration.name.match(/^frenly_(v\d+[a-z]?|c\d+)(?:_|$)/)?.[1];
    const testPath = sqlTestByVersion.get(semanticVersion);
    assert.ok(testPath, `${semanticVersion} must have a mapped rollback suite`);
    const testSql = await readFile(path.join(repoRoot, testPath), 'utf8');
    assert.doesNotMatch(
      testSql,
      /^\\\\ir\s/m,
      `${testPath} must use one literal backslash for psql include commands`
    );
    assert.equal(statementCount(testSql, 'begin'), 1, `${testPath} must begin one transaction`);
    assert.equal(statementCount(testSql, 'rollback'), 1, `${testPath} must roll back its fixture changes`);
  }
});

test('every newly created public table has RLS and an explicit browser-role ACL', async () => {
  for (const migration of await pendingMigrations()) {
    const sql = await readFile(path.join(repoRoot, migration.sourcePath), 'utf8');
    const tables = [...sql.matchAll(/create table(?: if not exists)?\s+(public\.[a-z0-9_]+)/gi)]
      .map((match) => match[1]);

    for (const table of tables) {
      const escaped = escapeRegExp(table);
      assert.match(
        sql,
        new RegExp(`alter\\s+table\\s+${escaped}\\s+enable\\s+row\\s+level\\s+security`, 'i'),
        `${migration.name}: ${table} must enable RLS`
      );
      assert.match(
        sql,
        new RegExp(`(?:grant|revoke)[\\s\\S]{0,240}?on(?:\\s+table)?[\\s\\S]{0,240}?${escaped}`, 'i'),
        `${migration.name}: ${table} must declare its browser-role ACL explicitly`
      );
    }
  }
});

test('pending public SECURITY DEFINER RPCs pin search_path and revoke default execution', async () => {
  for (const migration of await pendingMigrations()) {
    const sql = await readFile(path.join(repoRoot, migration.sourcePath), 'utf8');
    const definitions = [...sql.matchAll(/create or replace function\s+(public\.[a-z0-9_]+)[\s\S]*?\$\$/gi)];

    for (let index = 0; index < definitions.length; index += 1) {
      const definition = definitions[index];
      const nextOffset = definitions[index + 1]?.index ?? sql.length;
      const block = sql.slice(definition.index, nextOffset);
      const functionName = definition[1];
      const retiredFailClosedStub=/security invoker/i.test(block)
        &&/Legacy phone-sale signature is retired/.test(block)
        &&functionName==='public.record_sale_by_phone';
      assert.ok(/security definer/i.test(block)||retiredFailClosedStub,
        `${migration.name}: ${functionName} must be SECURITY DEFINER or an explicitly retired fail-closed stub`);
      assert.match(block, /set search_path\s+(?:to|=)/i, `${migration.name}: ${functionName} must pin search_path`);
      assert.match(
        sql,
        new RegExp(`revoke\\s+all[\\s\\S]{0,240}?on\\s+function\\s+${escapeRegExp(functionName)}\\s*\\(`, 'i'),
        `${migration.name}: ${functionName} must revoke PostgreSQL's default PUBLIC execute grant`
      );
    }
  }
});

test('v27 establishes the tenant-safe products parent key before its composite FK', async () => {
  const sql = await readFile(
    path.join(repoRoot, 'db/migrations/20260720_frenly_v27_rich_rewards.sql'),
    'utf8'
  );
  const parentKey = sql.search(/products_id_business_uk\s+unique\s*\(\s*id\s*,\s*business_id\s*\)/i);
  const childReference = sql.search(/references\s+public\.products\s*\(\s*id\s*,\s*business_id\s*\)/i);

  assert.notEqual(parentKey, -1, 'v27 must add products(id,business_id) as a unique parent key');
  assert.notEqual(childReference, -1, 'v27 must keep the tenant-safe product eligibility FK');
  assert.ok(parentKey < childReference, 'the products parent key must exist before the FK is created');
});

test('v40 adversarial fixtures never bypass every database trigger', async () => {
  const sql = await readFile(
    path.join(repoRoot, 'db/tests/v40_staff_reversal_workflows.sql'),
    'utf8'
  );

  assert.doesNotMatch(sql, /session_replication_role/i);
  assert.match(
    sql,
    /disable trigger trg_loyalty_redemption_provenance_immutable/i,
    'v40 may disable only the named provenance immutability trigger'
  );
  assert.match(
    sql,
    /enable trigger trg_loyalty_redemption_provenance_immutable/i,
    'v40 must restore the named provenance immutability trigger'
  );
  assert.doesNotMatch(sql, /disable trigger all/i);
});
