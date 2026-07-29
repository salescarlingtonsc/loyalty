import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

import {buildV105AdminVisualFixture} from '../browser/generate-v105-admin-visual.mjs';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

test('admin visual acceptance fixture composes the real production components',async()=>{
  const [fixture,generated,platformConsole]=await Promise.all([
    buildV105AdminVisualFixture(),
    read('tests/browser/v105-admin-visual.html'),
    read('app/platform-console.js')
  ]);

  assert.equal(generated,fixture,'checked-in visual evidence must be regenerated from current production components');
  assert.match(fixture,/<script src="\.\.\/\.\.\/app\/customer-ui\.js"><\/script>/);
  assert.match(fixture,/<script src="\.\.\/\.\.\/app\/platform-console\.js"><\/script>/);
  assert.match(fixture,/name="v105-production-style-sha256"/);
  assert.doesNotMatch(fixture,/class="platform-today-item"/,
    'the fixture must not duplicate component markup that could drift from the application');
  assert.match(platformConsole,/data-platform-today-item/);
});

test('visual fixture covers realistic roles, Firm 360 and grouped module policy states',async()=>{
  const fixture=await buildV105AdminVisualFixture();

  for(const role of ['super_admin','admin','sales_staff','denied'])
    assert.match(fixture,new RegExp(role));
  for(const rpc of [
    'platform_get_enterprise_hierarchy_v82',
    'platform_list_enterprise_customers_v82',
    'platform_get_business_control_v94',
    'platform_list_my_firms_v105',
    'platform_get_effective_modules_v105',
    'platform_set_module_overrides_v105',
    'platform_list_sector_entitlements_v75'
  ])assert.match(fixture,new RegExp(rpc));
  for(const metric of [
    'firmModuleManagers','perModuleEditButtons','modulePolicy',
    'horizontalOverflow','touchTargets'
  ])assert.match(fixture,new RegExp(metric));
  assert.match(fixture,/branch-orchard/);
  assert.match(fixture,/branch-tampines/);
  assert.match(fixture,/customer_count:164/);
});
