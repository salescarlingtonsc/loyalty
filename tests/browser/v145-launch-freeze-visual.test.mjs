import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import {buildV145LaunchFreezeVisual} from './generate-v145-launch-freeze-visual.mjs';

test('V145 browser fixture executes the current production Dashboard, P&L and inbox renderers',async()=>{
  const app=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');
  const fixture=await readFile(new URL('./v145-launch-freeze-visual.html',import.meta.url),'utf8');
  assert.equal(fixture,buildV145LaunchFreezeVisual(app));
  assert.match(fixture,/production-source-sha256/);
  assert.match(fixture,/async function dashboard\(\)/);
  assert.match(fixture,/async function pnlPage\(\)/);
  assert.match(fixture,/async function renderCustomerInAppInbox\(/);
  assert.match(fixture,/function studioEmergencyPauseActorLabel\(actor\)/);
  assert.match(fixture,/Peekaa launch safety/);
  assert.match(fixture,/Valid visits/);
  assert.match(fixture,/const net=Number\(sum\.net_cash_cents\?\?\(cash-expTotal\)\)/);
  assert.doesNotMatch(fixture,/P&L expenses could not be loaded|P&L monthly sales could not be loaded/);
  assert.match(fixture,/Keep this reminder in my inbox/);
  assert.doesNotMatch(fixture,/customerInboxQuiet|future interruptive channel|Quiet hours are active/);
});
