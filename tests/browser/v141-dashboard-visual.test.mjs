import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import {buildV141DashboardVisual} from './generate-v141-dashboard-visual.mjs';

test('V141 dashboard browser fixture executes the current production dashboard renderer',async()=>{
  const [app,customerUi,fixture]=await Promise.all([
    readFile(new URL('../../app/index.html',import.meta.url),'utf8'),
    readFile(new URL('../../app/customer-ui.js',import.meta.url),'utf8'),
    readFile(new URL('./v141-dashboard-visual.html',import.meta.url),'utf8')
  ]);
  assert.equal(fixture,buildV141DashboardVisual(app,customerUi));
  assert.match(fixture,/production-source-sha256/);
  assert.match(fixture,/async function dashboard\(\)/);
  assert.match(fixture,/async function refreshBranchFilter/);
  assert.match(fixture,/v141DashboardMetrics/);
});
