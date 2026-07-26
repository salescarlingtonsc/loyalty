import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';

const root = new URL('../..', import.meta.url).pathname;
const read = path => readFile(join(root, path), 'utf8');
const sourcePath = 'db/migrations/20260726_nestly_v75_sector_entitlements.sql';
const canonicalPath = 'supabase/migrations/20260726100000_nestly_v75_sector_entitlements.sql';
const functionBlock = (sql, schema, name) =>
  sql.match(new RegExp(
    `create or replace function ${schema}\\.${name}[\\s\\S]+?\\n\\$\\$;`,
    'i'
  ))?.[0] || '';

test('v75 source and canonical migrations are byte-identical after v74', async () => {
  const [source, canonical] = await Promise.all([read(sourcePath), read(canonicalPath)]);
  assert.equal(canonical, source);
  assert.match(source, /^-- NESTLY v75/m);
  assert.doesNotMatch(source, /stripe|payment_intent|invoice/i);
});

test('v75 keeps platform consultants separate from tenant staff', async () => {
  const sql = await read(sourcePath);
  assert.match(sql, /create table public\.platform_consultants/i);
  assert.match(sql, /user_id uuid not null unique references auth\.users/i);
  assert.match(sql, /tier in \('senior', 'junior'\)/i);
  assert.match(sql, /employment_started_on date not null/i);
  assert.doesNotMatch(
    sql.match(/create table public\.platform_consultants[\s\S]+?\n\);/)?.[0] || '',
    /business_id|references public\.staff/i
  );
});

test('v75 seeds all shipped industries through dependency-closed published bundles', async () => {
  const sql = await read(sourcePath);
  for (const sector of ['fnb', 'salon', 'facial', 'massage', 'fitness', 'retail', 'other']) {
    assert.match(sql, new RegExp(`\\('${sector}',`));
  }
  assert.match(sql, /app\.resolve_module_dependencies\(modules\)/i);
  assert.match(sql, /status = 'published'/i);
  assert.match(sql, /sector_bundle_versions_one_published_idx/i);
});

test('v75 compatibility backfill preserves current business modules exactly', async () => {
  const sql = await read(sourcePath);
  assert.match(sql, /v75 compatibility snapshot preserving pre-entitlement enabled modules/i);
  assert.match(sql, /select unnest\(resolved\.enabled_modules\)[\s\S]+except select unnest\(resolved\.bundle_modules\)/i);
  assert.match(sql, /select unnest\(resolved\.bundle_modules\)[\s\S]+except select unnest\(resolved\.enabled_modules\)/i);
  assert.match(sql, /business\.enabled_modules is distinct from app\.resolve_sector_entitlement_v75/i);
  assert.match(sql, /v75 compatibility backfill changed effective modules/i);
});

test('v75 assignments and overrides are versioned and override history is immutable', async () => {
  const sql = await read(sourcePath);
  assert.match(sql, /create table public\.business_sector_assignments/i);
  assert.match(sql, /version bigint not null default 1/i);
  assert.match(sql, /create table public\.business_sector_override_versions/i);
  assert.match(sql, /unique \(business_id, version\)/i);
  assert.match(sql, /business_sector_override_versions_immutable_guard/i);
  assert.match(sql, /a module cannot be both added and removed/i);
});

test('v75 fixed business modules compose with v74 staff permission subsets', async () => {
  const sql = await read(sourcePath);
  const guard = functionBlock(sql, 'app', 'business_sector_modules_guard_v75');
  const legacy = functionBlock(sql, 'public', 'set_business_modules');
  assert.match(guard, /business_sector_assignments/i);
  assert.match(guard, /app\.sector_entitlement_sync/i);
  assert.match(guard, /new\.industry is distinct from old\.industry/i);
  assert.match(guard, /business modules are fixed by the assigned sector entitlement/i);
  assert.match(sql, /before update of enabled_modules, industry on public\.businesses/i);
  assert.match(legacy, /business_sector_assignments/i);
  assert.match(legacy, /fixed by the assigned sector entitlement/i);
  const v74 = await read('db/migrations/20260726_frenly_v74_staff_module_permissions.sql');
  assert.match(v74, /unnest\(b\.enabled_modules\)/i);
  assert.match(v74, /module_perms/i);
});

test('v75 onboarding ignores browser module suggestions and assigns the server bundle', async () => {
  const sql = await read(sourcePath);
  const fn = functionBlock(sql, 'public', 'create_business');
  assert.match(fn, /select \* into v_bundle from public\.sector_bundle_versions/i);
  assert.match(fn, /v_sector text := case/i);
  assert.match(fn, /and status='published'/i);
  assert.match(fn, /values \(btrim\(p_name\),p_slug,v_sector,v_bundle\.modules\)/i);
  assert.match(fn, /insert into public\.business_sector_assignments/i);
  assert.match(fn, /'legacy_requested_modules_ignored',p_modules is not null/i);
  assert.doesNotMatch(fn, /coalesce\(p_modules/);
});

test('v75 sector mutation is finite, super-admin-only, previewable and audited', async () => {
  const sql = await read(sourcePath);
  for (const name of [
    'platform_create_sector_bundle_v75',
    'platform_publish_sector_bundle_v75',
    'platform_assign_business_sector_v75',
    'platform_set_business_sector_override_v75',
  ]) {
    const fn = functionBlock(sql, 'public', name);
    assert.match(fn, /if not app\.is_super_admin\(\)/i);
    assert.match(fn, /p_dry_run/i);
    assert.match(fn, /insert into public\.audit_log/i);
  }
  assert.match(sql, /sector assignment version conflict/i);
  assert.match(sql, /using errcode = '40001'/i);
  const assign = functionBlock(sql, 'public', 'platform_assign_business_sector_v75');
  assert.match(assign, /set enabled_modules = v_effective,\s+industry = v_bundle\.sector_key/i);
});

test('v75 tables are RPC-only and no general super-admin tenant write is added', async () => {
  const sql = await read(sourcePath);
  for (const table of [
    'platform_consultants',
    'sector_profiles',
    'sector_bundle_versions',
    'business_sector_override_versions',
    'business_sector_assignments',
  ]) {
    assert.match(sql, new RegExp(`alter table public\\.${table} enable row level security`, 'i'));
    assert.match(sql, new RegExp(`revoke all privileges on table public\\.${table}`, 'i'));
  }
  assert.doesNotMatch(sql, /create policy[\s\S]+businesses[\s\S]+for (?:all|update|insert|delete)/i);
  assert.doesNotMatch(sql, /grant (?:insert|update|delete|all)[\s\S]+public\.businesses/i);
});

test('v75 rollback SQL exercises previews, authorization, compatibility and fixed modules', async () => {
  const rollback = await read('db/tests/v75_sector_entitlements.sql');
  assert.match(rollback, /^begin;/m);
  assert.match(rollback, /^rollback;/m);
  for (const evidence of [
    'server onboarding did not assign the published sector bundle',
    'owner changed fixed sector modules',
    'owner changed fixed sector label',
    'bundle create dry-run persisted a row',
    'bundle publish dry-run changed status',
    'assignment dry-run changed the business',
    'override dry-run persisted a row',
    'sector override did not update effective modules',
    'super admin gained general tenant update authority',
  ]) assert.match(rollback, new RegExp(evidence));
});
