import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const migrationPath = 'db/migrations/20260720_frenly_v24b_module_dependency_registry.sql';

test('workflow modules declare their hard backend dependencies', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /\('till',\s*'Till',\s*'\{clients,sales\}'/i);
  assert.match(migration, /\('bookings',\s*'Bookings',\s*'\{appointments,clients,services\}'/i);
  assert.match(migration, /\('packages',\s*'Packages',\s*'\{clients,services,sales\}'/i);
  assert.match(migration, /\('loyalty',\s*'Loyalty',\s*'\{clients,sales\}'/i);
  assert.match(migration, /\('pnl',\s*'P&L',\s*'\{sales,expenses\}'/i);
});

test('database resolves transitive dependencies for every business write', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /with recursive closure\(module_key\)/i);
  assert.match(migration, /cross join lateral unnest\(mr\.requires_modules\) dependency/i);
  assert.match(migration, /unknown modules:/i);
  assert.match(migration, /before insert or update of enabled_modules on public\.businesses/i);
  assert.match(migration, /new\.enabled_modules := app\.resolve_module_dependencies\(new\.enabled_modules\)/i);
});

test('legacy module RPC remains owner-authorized while tenant settings are platform-controlled', async () => {
  const [migration, app] = await Promise.all([read(migrationPath), Promise.all([read('app/index.html'),read('app/app.js')]).then(f=>f.join('\n'))]);
  assert.match(migration, /if not app\.is_salon_owner\(p_business\)/i);
  assert.match(migration, /revoke all on function public\.set_business_modules\(uuid, text\[\]\) from public, anon/i);
  assert.match(migration, /grant execute on function public\.set_business_modules\(uuid, text\[\]\) to authenticated/i);
  assert.match(migration, /revoke all privileges on table public\.module_registry from public, anon, authenticated/i);
  assert.match(migration, /grant select on table public\.module_registry to authenticated/i);
  assert.doesNotMatch(app, /sb\.rpc\('set_business_modules',\{p_business:S\.biz\.id,p_modules:on\}\)/);
  assert.match(app, /Set by Peekaa for your sector/);
  assert.match(app, /<select id="bi" disabled/);
  assert.doesNotMatch(app, /from\('businesses'\)\.update\(\{enabled_modules:on\}/);
});

test('settings explains dependencies without presenting editable sector entitlements', async () => {
  const app = ((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  assert.match(app, /from\('module_registry'\)\s*\.select\('module_key,requires_modules'\)/);
  assert.match(app, /uses \$\{esc\(dependencyText\(m\)\)\}/);
  assert.doesNotMatch(app, /id="msave"/);
  assert.doesNotMatch(app, /industry:\$\('bi'\)\.value/);
});
