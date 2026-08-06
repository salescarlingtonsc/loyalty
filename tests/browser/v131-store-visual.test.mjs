import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import {buildV131StoreVisual} from './generate-v131-store-visual.mjs';

test('V131 browser fixture executes the current production native companion and deletion flow',async()=>{
  const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));
  const fixture=await readFile(new URL('./v131-store-visual.html',import.meta.url),'utf8');
  assert.equal(fixture,buildV131StoreVisual(app));
  assert.match(fixture,/production-source-sha256/);
  assert.match(fixture,/function renderNativeBusinessCompanion\(\)/);
  assert.match(fixture,/function renderPersonaChoice\(/);
  assert.match(fixture,/function renderCustomerWalletUnavailable\(/);
  assert.match(fixture,/function renderCustomerCapabilityRetry\(/);
  assert.match(fixture,/function renderPersonaResolutionUnavailable\(\)/);
  assert.match(fixture,/function renderWorkspaceAccessUnavailable\(\)/);
  assert.match(fixture,/function openAccountDeletionDialog\(/);
  assert.match(fixture,/subscription setup, and subscription changes are not available in this app/);
  assert.match(fixture,/fixtureState==='load-error'/);
  assert.match(fixture,/fixtureState==='submit-error'/);
  assert.match(fixture,/fixtureState==='pending'/);
  assert.match(fixture,/fixtureState==='completed-deleted'/);
  assert.match(fixture,/fixtureState==='completed-retained'/);
  assert.match(fixture,/Deletion request reviewed/);
  assert.match(fixture,/Retention review date/);
});
