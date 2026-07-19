import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = resolve(import.meta.dirname, '../..');
const tool = join(root, 'db/cutover/compare-cutover-inventories.mjs');
const sourceFixture = join(import.meta.dirname, 'fixtures/base-source.json');
const targetFixture = join(import.meta.dirname, 'fixtures/base-target.json');

function readJson(path) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

function writeJson(tempDir, name, value) {
  const file = join(tempDir, name);
  writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
  return file;
}

function runCompare(sourcePath, targetPath) {
  const result = spawnSync(process.execPath, [tool, sourcePath, targetPath], {
    cwd: root,
    encoding: 'utf8'
  });
  let parsed = null;
  if (result.stdout.trim()) parsed = JSON.parse(result.stdout);
  return { ...result, parsed };
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

test('passes exact source/target match while ignoring source/target project refs', () => {
  const result = runCompare(sourceFixture, targetFixture);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.parsed.ok, true);
  assert.equal(result.parsed.launch_blocked, false);
  assert.equal(result.parsed.summary.findings, 0);
});

test('blocks on row-count mismatch', () => {
  const tempDir = mkdtempSync(join(tmpdir(), 'cutover-row-count-'));
  const source = readJson(sourceFixture);
  const target = readJson(targetFixture);
  target.inventory.metrics.table_row_counts[0].row_count = 9;
  const result = runCompare(writeJson(tempDir, 'source.json', source), writeJson(tempDir, 'target.json', target));
  assert.equal(result.status, 1);
  assert.equal(result.parsed.launch_blocked, true);
  assert.match(JSON.stringify(result.parsed.findings), /P0_DATA_LOSS/);
});

test('blocks on financial liability mismatch', () => {
  const tempDir = mkdtempSync(join(tmpdir(), 'cutover-finance-'));
  const source = readJson(sourceFixture);
  const target = readJson(targetFixture);
  target.reconciliation.metrics.gift_card_member_liability.tenant_rows[0].gift_card_liability_cents = 100;
  const result = runCompare(writeJson(tempDir, 'source.json', source), writeJson(tempDir, 'target.json', target));
  assert.equal(result.status, 1);
  assert.equal(result.parsed.launch_blocked, true);
  assert.match(JSON.stringify(result.parsed.findings), /P0_FINANCIAL/);
});

test('blocks on missing RLS policy', () => {
  const tempDir = mkdtempSync(join(tmpdir(), 'cutover-policy-'));
  const source = readJson(sourceFixture);
  const target = readJson(targetFixture);
  target.inventory.sections.policies = [];
  const result = runCompare(writeJson(tempDir, 'source.json', source), writeJson(tempDir, 'target.json', target));
  assert.equal(result.status, 1);
  assert.equal(result.parsed.launch_blocked, true);
  assert.match(JSON.stringify(result.parsed.findings), /P0_SECURITY/);
});

test('blocks on unexpected anon function execute grant even when source and target match', () => {
  const tempDir = mkdtempSync(join(tmpdir(), 'cutover-anon-grant-'));
  const source = readJson(sourceFixture);
  const target = clone(source);
  const exposure = {
    schema_name: 'public',
    function_name: 'admin_export',
    identity_arguments: '',
    grantee: 'anon',
    security_definer: true,
    search_path: 'public'
  };
  source.reconciliation.metrics.function_execute_exposure.unexpected_anon_execute_grants.push(exposure);
  target.reconciliation.metrics.function_execute_exposure.unexpected_anon_execute_grants.push(exposure);
  const result = runCompare(writeJson(tempDir, 'source.json', source), writeJson(tempDir, 'target.json', target));
  assert.equal(result.status, 1);
  assert.equal(result.parsed.launch_blocked, true);
  assert.match(JSON.stringify(result.parsed.findings), /unexpected anon execute grants/);
});

test('blocks on unexpected overload of accepted public RPC name', () => {
  const tempDir = mkdtempSync(join(tmpdir(), 'cutover-overload-'));
  const source = readJson(sourceFixture);
  const target = clone(source);
  const exposure = {
    schema_name: 'public',
    function_name: 'get_business_public',
    identity_arguments: 'p_slug text, p_locale text',
    grantee: 'anon',
    security_definer: true,
    search_path: 'public'
  };
  source.reconciliation.metrics.function_execute_exposure.unexpected_anon_execute_grants.push(exposure);
  target.reconciliation.metrics.function_execute_exposure.unexpected_anon_execute_grants.push(exposure);
  const result = runCompare(writeJson(tempDir, 'source.json', source), writeJson(tempDir, 'target.json', target));
  assert.equal(result.status, 1);
  assert.equal(result.parsed.launch_blocked, true);
  assert.match(JSON.stringify(result.parsed.findings), /P0_SECURITY/);
  assert.match(JSON.stringify(result.parsed.findings), /get_business_public/);
});

test('blocks on known phone-only public appointment RPC exposure', () => {
  const tempDir = mkdtempSync(join(tmpdir(), 'cutover-known-risk-'));
  const source = readJson(sourceFixture);
  const target = clone(source);
  const exposure = {
    schema_name: 'public',
    function_name: 'list_my_appointments',
    identity_arguments: 'p_slug text, p_phone text',
    grantee: 'anon',
    security_definer: true,
    search_path: 'public',
    risk_code: 'PHONE_ONLY_APPOINTMENT_LOOKUP',
    hardening_required: 'OTP or signed-token proof before returning appointments'
  };
  source.reconciliation.metrics.function_execute_exposure.known_risk_public_execute_grants.push(exposure);
  target.reconciliation.metrics.function_execute_exposure.known_risk_public_execute_grants.push(exposure);
  const result = runCompare(writeJson(tempDir, 'source.json', source), writeJson(tempDir, 'target.json', target));
  assert.equal(result.status, 1);
  assert.equal(result.parsed.launch_blocked, true);
  assert.match(JSON.stringify(result.parsed.findings), /known risk public execute grants/);
  assert.match(JSON.stringify(result.parsed.findings), /PHONE_ONLY_APPOINTMENT_LOOKUP/);
});

test('blocks on duplicate cron jobs even when source and target match', () => {
  const tempDir = mkdtempSync(join(tmpdir(), 'cutover-cron-'));
  const source = readJson(sourceFixture);
  const target = clone(source);
  const duplicate = {
    job_fingerprint: 'dupe',
    duplicate_count: 2,
    schedules: ['* * * * *'],
    command_fingerprints: ['cmd']
  };
  source.reconciliation.metrics.duplicate_cron_jobs.push(duplicate);
  target.reconciliation.metrics.duplicate_cron_jobs.push(duplicate);
  const result = runCompare(writeJson(tempDir, 'source.json', source), writeJson(tempDir, 'target.json', target));
  assert.equal(result.status, 1);
  assert.equal(result.parsed.launch_blocked, true);
  assert.match(JSON.stringify(result.parsed.findings), /duplicate cron job definitions/);
});

test('rejects accidental PII keys before comparison', () => {
  const tempDir = mkdtempSync(join(tmpdir(), 'cutover-pii-'));
  const source = readJson(sourceFixture);
  const target = readJson(targetFixture);
  source.reconciliation.metrics.raw_customer_dump = [{ customer_email: 'person@example.com' }];
  const result = runCompare(writeJson(tempDir, 'source.json', source), writeJson(tempDir, 'target.json', target));
  assert.equal(result.status, 2);
  assert.match(result.stderr, /PII_GUARD/);
});
