import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const migrationPath = 'db/migrations/20260720_frenly_v24c_import_job_foundation.sql';

test('imports are staged, validated and committed as one backend job', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /create table if not exists public\.import_jobs/i);
  assert.match(migration, /create table if not exists public\.import_rows/i);
  assert.match(migration, /unique\s*\(business_id, entity_type, idempotency_key\)/i);
  assert.match(migration, /create or replace function public\.stage_import_rows/i);
  assert.match(migration, /create or replace function public\.commit_import_job/i);
  assert.match(migration, /if v_job\.invalid_rows > 0 then/i);
  assert.match(migration, /select \* from public\.import_rows\s+where job_id = p_job and business_id = v_job\.business_id\s+order by row_number for update/i);
  assert.match(migration, /foreign key \(job_id, business_id\)[\s\S]*references public\.import_jobs\(id, business_id\)/i);
});

test('all setup entities normalize business data in PostgreSQL', async () => {
  const migration = await read(migrationPath);
  for (const entity of ['customers', 'services', 'inventory', 'staff', 'branches', 'reservations']) {
    assert.match(migration, new RegExp(`'${entity}'`));
  }
  assert.match(migration, /app\.norm_phone\(v_phone\)/i);
  assert.match(migration, /gender must be female, male or other/i);
  assert.match(migration, /duration must be between 1 and 1440 minutes/i);
  assert.match(migration, /insert into public\.stock_batches \(product_id, qty\)/i);
  assert.match(migration, /phone is duplicated in this import/i);
  assert.match(migration, /SKU is duplicated in this import/i);
  assert.match(migration, /jsonb_build_object\('_invalid_value', v_raw\)/i);
  assert.match(migration, /jsonb_build_object\('_omitted', true\)/i);
  assert.match(migration, /role must be manager, staff, frontdesk or bookkeeper/i);
  assert.match(migration, /select 1 from pg_timezone_names where name = v_timezone/i);
  assert.match(migration, /insert into public\.booking_tables/i);
  for (const message of [
    'matching service already exists',
    'staff email or phone already exists',
    'matching branch already exists',
    'matching reservation table already exists',
    'matching row is duplicated in this import'
  ]) assert.match(migration, new RegExp(message, 'i'));
});

test('staging tables expose owner reads but no browser writes', async () => {
  const migration = await read(migrationPath);
  assert.equal((migration.match(/enable row level security/gi) || []).length, 2);
  assert.match(migration, /using \(app\.is_salon_owner\(business_id\)\)/i);
  assert.match(migration, /revoke all privileges on table public\.import_jobs from public, anon, authenticated/i);
  assert.match(migration, /revoke all privileges on table public\.import_rows from public, anon, authenticated/i);
  assert.doesNotMatch(migration, /grant (?:insert|update|delete|all)\b[^;]*import_(?:jobs|rows)[^;]*authenticated/i);
});

test('the shipped importer no longer inserts business records row by row', async () => {
  const app = await read('app/index.html');
  const runImport = app.match(/async function runImport\([\s\S]*?\n}\n\/\* The modal/);
  assert.ok(runImport, 'runImport implementation not found');
  assert.match(runImport[0], /sb\.rpc\('stage_import_rows'/);
  assert.match(runImport[0], /sb\.rpc\('commit_import_job'/);
  assert.doesNotMatch(runImport[0], /sb\.from\(/);
  assert.match(app, /if\(!importIdem\) importIdem=crypto\.randomUUID\(\)/);
  assert.match(app, /Nothing imported\. Correct the source data/i);
});

test('frontend preserves invalid source values for backend validation', async () => {
  const app = await read('app/index.html');
  assert.doesNotMatch(app, /gender.*transform:/i);
  assert.doesNotMatch(app, /birth_date.*transform:/i);
});

test('staff, branch and reservation upload controls use the shared importer', async () => {
  const app = await read('app/index.html');
  for (const entity of ['staff', 'branches', 'reservations']) {
    assert.match(app, new RegExp(`${entity}:\\{title:`));
    assert.match(app, new RegExp(`importBtn\\('${entity}'\\)`));
  }
  assert.match(app, /Imported people are roster records; invite them separately/i);
});
