import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const sourcePath = 'db/migrations/20260726_nestly_v85_conversion_guard_repair.sql';
const canonicalPath = 'supabase/migrations/20260726200000_nestly_v85_conversion_guard_repair.sql';
const sqlTestPath = 'db/tests/v85_conversion_guard_repair.sql';
const read = (path) => readFile(new URL(path, root), 'utf8');

test('v85 source and canonical migrations are byte-identical', async () => {
  const [source, canonical] = await Promise.all([
    read(sourcePath), read(canonicalPath)
  ]);
  assert.equal(source, canonical);
  assert.match(source, /^-- NESTLY v85[\s\S]*?\nbegin;/i);
  assert.match(source, /commit;\s*$/i);
});

test('v85 narrows the polymorphic trigger record before table-specific access', async () => {
  const sql = await read(sourcePath);
  const businessAt = sql.indexOf("if tg_table_name = 'businesses' then");
  const branchAt = sql.indexOf("elsif tg_table_name = 'branches' then");
  const activeAt = sql.indexOf('if old.active = false');
  assert.ok(businessAt >= 0, 'businesses branch is missing');
  assert.ok(branchAt > businessAt, 'branches branch must follow businesses');
  assert.ok(activeAt > branchAt,
    'OLD.active must only be dereferenced inside the branches branch');
  assert.match(sql,
    /old\.source_prospect_id is not null[\s\S]*new\.registration_number is distinct from old\.registration_number/i);
  assert.match(sql,
    /old\.active = false[\s\S]*new\.active = true[\s\S]*business\.source_prospect_id is not null/i);
  assert.match(sql,
    /current_setting\('app\.v79_system_transition', true\)[\s\S]*return new/i);
  assert.match(sql,
    /revoke all on function app\.guard_converted_workspace_activation_v79\(\)[\s\S]*from public, anon, authenticated/i);
});

test('v85 rollback suite covers ordinary and converted business/branch updates', async () => {
  const suite = await read(sqlTestPath);
  assert.match(suite, /^begin;/im);
  assert.match(suite, /^rollback;/im);
  for (const term of [
    'ordinary businesses update',
    'converted business identity',
    'converted branch activation',
    'ordinary branch activation',
    'v79_system_transition'
  ]) assert.match(suite, new RegExp(term, 'i'), `missing regression: ${term}`);
});
