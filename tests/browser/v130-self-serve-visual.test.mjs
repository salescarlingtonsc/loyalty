import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import {buildV130SelfServeVisual} from './generate-v130-self-serve-visual.mjs';

test('V130 browser fixture executes current production signup, setup and payment-control renderers',async()=>{
  const app=((await readFile(new URL('../../app/index.html',import.meta.url),'utf8'))+'\n'+(await readFile(new URL('../../app/app.js',import.meta.url),'utf8')));
  const fixture=await readFile(new URL('./v130-self-serve-visual.html',import.meta.url),'utf8');
  assert.equal(fixture,buildV130SelfServeVisual(app));
  assert.match(fixture,/production-source-sha256/);
  assert.match(fixture,/function businessGoogleButtonHtml\(id\)/);
  assert.match(fixture,/signInWithOAuth:async/);
  assert.ok(fixture.indexOf('function businessGoogleButtonHtml(id)')<fixture.indexOf('function renderBusinessApplication()'));
  assert.match(fixture,/function renderBusinessApplication\(\)/);
  assert.match(fixture,/function renderOnboard\(\)/);
  assert.match(fixture,/function renderBusinessWorkspaceControl\(/);
  assert.match(fixture,/function accountDeletionCardHtml\(\)/);
  assert.match(fixture,/provider-confirmed payment/);
});
