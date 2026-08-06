import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import {buildV129TrialTestVisual} from './generate-v129-trial-test-visual.mjs';

test('V129 browser fixture executes the current production customer, profile, appointment and Record sale renderers',async()=>{
  const [app,customerUi]=await Promise.all([
    Promise.all([readFile(new URL('../../app/index.html',import.meta.url),'utf8'),readFile(new URL('../../app/app.js',import.meta.url),'utf8')]).then(f=>f.join('\n')),
    readFile(new URL('../../app/customer-ui.js',import.meta.url),'utf8')
  ]);
  const fixture=await readFile(new URL('./v129-trial-test-visual.html',import.meta.url),'utf8');
  assert.equal(fixture,buildV129TrialTestVisual(app,customerUi));
  assert.match(fixture,/production-source-sha256/);
  assert.match(fixture,/async function clientsPage\(\)/);
  assert.match(fixture,/async function clientDetail\(id\)/);
  assert.match(fixture,/function renderAppointmentDetails\(item/);
  assert.match(fixture,/async function tillPage\(\)/);
  assert.match(fixture,/row\.days_since_last_visit===null\|\|row\.days_since_last_visit>=threshold/);
  assert.doesNotMatch(fixture,/row\.days\s*>\s*threshold/);
  assert.doesNotMatch(fixture,/Inactive means no valid visit for more than/);
  assert.doesNotMatch(app,/<b>Customer gender<\/b>|labels:\['Female','Male','Other','Not set'\]/);
});
