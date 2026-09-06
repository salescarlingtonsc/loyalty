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
  /* V385 (owner markup, photo 11) made the Industry select editable; nestly_v798 SUPERSEDES that
     on the owner's ruling 2026-09-06 — the select is cosmetic, "just to let user to read the
     company's industry". It is read-only, and the write below no longer names businesses.industry
     at all, because that column MIRRORS the assigned sector bundle: app.business_sector_modules_
     guard_v75 raises 42501 at any other writer for a firm with a sector assignment, which is every
     self-service firm. What this test guards is stronger than before and still exactly the point —
     the sector carries no ENTITLEMENT and the workspace cannot move it at all. */
  assert.match(app, /Set with your plan when you signed up/);
  assert.match(app, /<select id="bi" disabled aria-describedby="biSectorHint">/);
  assert.doesNotMatch(app, /from\('businesses'\)\.update\(\{enabled_modules:on\}/);
  const brandSave=app.slice(app.indexOf('function wireWorkspaceBrandV259(){'),app.indexOf('function customerInterfaceStepperHtmlV325('));
  assert.doesNotMatch(brandSave, /enabled_modules|set_business_modules/,
    'editing the sector must never rewrite this firm\'s module entitlement');
  /* nestly_v798: and the workspace no longer writes the sector column itself either. */
  assert.doesNotMatch(brandSave, /\bindustry\s*[,:]/,
    'businesses.industry mirrors the assigned sector bundle — only the platform may move it');
});

test('the workspace never presents editable sector entitlements', async () => {
  const app = ((await read('app/index.html'))+'\n'+(await read('app/app.js')));
  /* nestly_v607 (owner: "dont need to show them the modules, just remove it. since only admin can
     edit"). The module list explained each entitlement's dependencies — honest, and read-only,
     which is exactly why it went: a list of things that look like settings and cannot be changed,
     on a page the owner opens to see the plan they pay for. The dependency TEXT went with the list
     it annotated. What this test still guards is what it always guarded: no editable entitlement
     control anywhere in the workspace. */
  assert.doesNotMatch(app, /settings-module-grid-v389/);
  assert.doesNotMatch(app, /uses \$\{esc\(dependencyText\(m\)\)\}/);
  assert.doesNotMatch(app, /id="msave"/);
  assert.doesNotMatch(app, /industry:\$\('bi'\)\.value/);
  assert.doesNotMatch(app, /id="sellsServices"/, 'nor the one entitlement pair that was editable');
});
