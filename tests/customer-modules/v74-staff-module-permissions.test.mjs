import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';

const root = new URL('../..', import.meta.url).pathname;
const read = (path) => readFile(join(root, path), 'utf8');
const sourcePath = 'db/migrations/20260726_frenly_v74_staff_module_permissions.sql';
const canonicalPath = 'supabase/migrations/20260725150000_frenly_v74_staff_module_permissions.sql';

const functionBlock = (sql, schema, name) =>
  sql.match(new RegExp(
    `create or replace function ${schema.replace('.', '\\.')}\\.${name}[\\s\\S]+?\\n\\$\\$;`,
    'i'
  ))?.[0] || '';

test('v74 module assignment is an owner-only tenant-scoped active-target boundary', async () => {
  const sql = await read(sourcePath);
  const fn = functionBlock(sql, 'public', 'set_staff_module_permissions_v74');
  assert.match(fn, /v_actor uuid := auth\.uid\(\)/i);
  assert.match(fn, /owner_staff\.business_id = target\.business_id/i);
  assert.match(fn, /owner_staff\.user_id = v_actor/i);
  assert.match(fn, /owner_staff\.role = 'owner'/i);
  assert.match(fn, /owner_staff\.active/i);
  assert.match(fn, /target\.active/i);
  assert.match(fn, /for update/i);
  assert.match(fn, /v_target\.role = 'owner'/i);
  assert.match(fn, /v_target\.role not in \('manager', 'staff', 'frontdesk', 'bookkeeper'\)/i);
});

test('v74 accepts only enabled assignable r/rw object entries and finance-capable expenses', async () => {
  const sql = await read(sourcePath);
  const fn = functionBlock(sql, 'public', 'set_staff_module_permissions_v74');
  assert.match(fn, /jsonb_typeof\(p_module_perms\) <> 'object'/i);
  assert.match(fn, /jsonb_typeof\(entry\.value\) <> 'string'/i);
  assert.match(fn, /entry\.value #>> '\{\}' not in \('r', 'rw'\)/i);
  assert.match(fn, /left join public\.module_registry/i);
  assert.match(fn, /key_row\.module_key = any\(coalesce\(v_enabled_modules/i);
  assert.match(fn, /key_row\.module_key in \('branches', 'settings', 'setup'\)/i);
  assert.match(fn, /'expenses' = any\(v_permission_closure\)[\s\S]+'pnl' = any\(v_permission_closure\)/i);
  assert.match(fn, /'view_finance' = any\(app\.role_perms\(v_target\.role\)\)/i);
});

test('v74 resolves only required dependency closure with explicit modes taking precedence', async () => {
  const sql = await read(sourcePath);
  const fn = functionBlock(sql, 'public', 'set_staff_module_permissions_v74');
  assert.match(fn, /with recursive permission_closure\(module_key\)/i);
  assert.match(fn, /unnest\(registry\.requires_modules\)/i);
  assert.doesNotMatch(fn, /recommended_modules/i);
  assert.match(fn, /coalesce\(p_module_perms ->> module_key, 'r'\)/i);
  assert.match(fn, /required module dependencies are not currently enabled and assignable/i);
  assert.match(fn, /set module_perms = v_resolved_perms/i);
  assert.match(fn, /'new_module_perms', v_resolved_perms/i);
  assert.match(fn, /'module_perms', v_resolved_perms/i);
});

test('v74 keeps legacy modules coherent and audits exactly one prior/new assignment', async () => {
  const sql = await read(sourcePath);
  const fn = functionBlock(sql, 'public', 'set_staff_module_permissions_v74');
  assert.match(fn, /array_agg\(key_row\.module_key order by key_row\.module_key\)/i);
  assert.match(fn, /v_new_modules := null/i);
  assert.match(fn, /set module_perms = v_resolved_perms,\s+modules = v_new_modules/i);
  assert.equal((fn.match(/insert into public\.audit_log/gi) || []).length, 1);
  assert.match(fn, /'STAFF_MODULE_PERMISSIONS_SET_V74'/);
  assert.match(fn, /'prior_module_perms', v_target\.module_perms/i);
  assert.match(fn, /'new_module_perms', v_resolved_perms/i);
  assert.match(fn, /'prior_modules', to_jsonb\(v_target\.modules\)/i);
  assert.match(fn, /'new_modules', to_jsonb\(v_new_modules\)/i);
});

test('v74 legacy module signature is a single-audit compatibility wrapper', async () => {
  const [sql, v14b] = await Promise.all([
    read(sourcePath),
    read('supabase/migrations/20260718180548_frenly_v14b_billing_module_perms.sql'),
  ]);
  const wrapper = functionBlock(sql, 'public', 'set_staff_modules');
  assert.match(wrapper, /returns json/i);
  assert.match(wrapper, /security definer/i);
  assert.match(wrapper, /set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
  assert.match(wrapper, /if p_modules is null then\s+v_module_perms := null/i);
  assert.match(wrapper, /jsonb_object_agg\(module_name, 'rw'::text order by module_name\)/i);
  assert.match(wrapper, /select distinct requested_module as module_name\s+from unnest\(p_modules\)/i);
  assert.equal(
    (wrapper.match(/public\.set_staff_module_permissions_v74\(/gi) || []).length,
    1,
    'legacy compatibility must delegate exactly once'
  );
  assert.doesNotMatch(wrapper, /update\s+public\.staff|insert into public\.audit_log/i);
  assert.match(wrapper, /return row_to_json\(v_staff\)/i);
  const template = v14b.match(
    /create or replace function public\.apply_module_template[\s\S]+?end \$\$;/
  )?.[0] || '';
  assert.match(template, /return public\.set_staff_modules\(p_staff, t\.modules\)/i);
});

test('v74 role changes are atomic, canonical and strip explicit ineligible expenses', async () => {
  const sql = await read(sourcePath);
  const fn = functionBlock(sql, 'public', 'set_staff_role_v74');
  assert.match(fn, /p_role not in \('manager', 'staff', 'frontdesk', 'bookkeeper'\)/i);
  assert.match(fn, /v_target\.role = 'owner'/i);
  assert.match(fn, /v_target\.role not in \('manager', 'staff', 'frontdesk', 'bookkeeper'\)/i);
  assert.match(fn, /not \('view_finance' = any\(app\.role_perms\(p_role\)\)\)/i);
  assert.match(fn, /v_new_module_perms := v_new_module_perms - 'expenses' - 'pnl'/i);
  assert.match(fn, /where module_name not in \('expenses', 'pnl'\)/i);
  assert.match(fn, /set role = p_role,\s+module_perms = v_new_module_perms,\s+modules = v_new_modules/i);
  assert.equal((fn.match(/insert into public\.audit_log/gi) || []).length, 1);
  for (const field of [
    'prior_role', 'new_role', 'prior_module_perms', 'new_module_perms',
    'prior_modules', 'new_modules',
  ]) assert.match(fn, new RegExp(`'${field}'`));
});

test('v74 effective resolution filters unusable and role-ineligible inherited modules', async () => {
  const sql = await read(sourcePath);
  const fn = functionBlock(sql, 'app', 'staff_module_perms');
  assert.match(fn, /s\.role = 'owner'\s+or module_name not in \('branches', 'settings', 'setup'\)/i);
  assert.match(fn, /module_name not in \('expenses', 'pnl'\)\s+or 'view_finance' = any\(app\.role_perms\(s\.role\)\)/i);
  assert.match(fn, /s\.module_perms is null and \(s\.modules is null or module_name = any\(s\.modules\)\)/i);
  assert.doesNotMatch(fn, /module_name\s*(?:<>|not in)[\s\S]*dashboard/i);
});

test('v74 exposes only fixed-search-path authenticated RPCs and no direct staff write grant', async () => {
  const sql = await read(sourcePath);
  for (const name of [
    'set_staff_module_permissions_v74', 'set_staff_modules', 'set_staff_role_v74',
  ]) {
    const fn = functionBlock(sql, 'public', name);
    assert.match(fn, /security definer/i);
    assert.match(fn, /set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
  }
  assert.match(sql, /revoke all on function public\.set_staff_module_permissions_v74\(uuid,jsonb\)\s+from public, anon, authenticated/i);
  assert.match(sql, /grant execute on function public\.set_staff_module_permissions_v74\(uuid,jsonb\)\s+to authenticated/i);
  assert.match(sql, /revoke all on function public\.set_staff_modules\(uuid,text\[\]\)\s+from public, anon, authenticated/i);
  assert.match(sql, /grant execute on function public\.set_staff_modules\(uuid,text\[\]\)\s+to authenticated/i);
  assert.match(sql, /revoke all on function public\.set_staff_role_v74\(uuid,text\)\s+from public, anon, authenticated/i);
  assert.match(sql, /grant execute on function public\.set_staff_role_v74\(uuid,text\)\s+to authenticated/i);
  assert.doesNotMatch(sql, /grant\s+(?:update|insert|delete|all)[\s\S]*public\.staff/i);
});

test('v74 rollback evidence covers stale, foreign, invalid role/key/value and audit behavior', async () => {
  const rollback = await read('db/tests/v74_staff_module_permissions.sql');
  assert.match(rollback, /^begin;/m);
  assert.match(rollback, /^rollback;/m);
  for (const evidence of [
    'valid assignment did not emit exactly one prior/new audit',
    'required module closure did not add only required read dependencies',
    'legacy module wrapper did not delegate resolved coherent permissions',
    'legacy module wrapper emitted a second assignment audit',
    'apply_module_template did not remain functional through v74 wrapper',
    'legacy NULL module wrapper did not restore coherent inheritance',
    'owner assigned modules to foreign staff',
    'owner assigned modules to stale inactive staff',
    'invalid text permission value was accepted',
    'non-string permission value was accepted',
    'disabled module key was accepted',
    'unknown module key was accepted',
    'owner-only or unusable module key was accepted',
    'finance-ineligible role received expenses',
    'finance-ineligible role received pnl',
    'effective resolver exposed unusable inherited modules',
    'finance downgrade retained explicit expenses',
    'role downgrade froze NULL inheritance',
    'invalid stored target role received modules',
    'invalid stored target role was rewritten',
  ]) assert.match(rollback, new RegExp(evidence.replaceAll(/[.*+?^${}()|[\]\\]/g, '\\$&')));
});

test('v74 source and canonical materialization are exact after v73', async () => {
  const [source, canonical, sourcePlan, canonicalPlan] = await Promise.all([
    read(sourcePath),
    read(canonicalPath),
    read('db/migrations/migration-order.plan.json'),
    read('supabase/canonical-migration-order.plan.json'),
  ]);
  assert.equal(canonical, source);
  assert.match(sourcePlan, /v73_booking_lifecycle[\s\S]+v74_staff_module_permissions/);
  assert.match(canonicalPlan, /20260725140000[\s\S]+20260725150000/);
});
