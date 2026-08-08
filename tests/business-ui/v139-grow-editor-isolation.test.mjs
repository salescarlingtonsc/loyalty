import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const app=(readFileSync(new URL('../../app/index.html',import.meta.url),'utf8')+'\n'+readFileSync(new URL('../../app/app.js',import.meta.url),'utf8'));

function section(start,end){
  const from=app.indexOf(start),to=app.indexOf(end,from+start.length);
  assert.ok(from>=0,`missing section start: ${start}`);
  assert.ok(to>from,`missing section end: ${end}`);
  return app.slice(from,to);
}

const loyalty=section('async function loyaltyPage(','/* ---------- versioned retention programs');
const grow=section('async function growPage(','/* ---------- Bring-back playbooks');

test('Grow deep links carry one explicit Loyalty editor intent',()=>{
  assert.match(app,/function growLoyaltyEditorIntentV139\(/);
  assert.match(grow,/growLoyaltyEditorIntentV139\(\{focusTarget,rewardId\}\)/);
  assert.match(grow,/loyaltyPage\(undefined,draft,null,false,editorIntent\)/);
  assert.match(grow,/\$\('growOverview'\)\?\.classList\.add\('grow-editor-active'\)/);
  assert.match(app,/\.grow-overview\.grow-editor-active>:not\(\.grow-panel-shell\)\{display:none\}/);
});

test('the Loyalty renderer removes every sibling editor before interaction',()=>{
  assert.match(loyalty,/applyGrowLoyaltyEditorIsolationV139\(routeMain,editorIntent\)/);
  assert.match(loyalty,/id="loyaltyProgramEditor"/);
  assert.match(loyalty,/id="loyaltyRewardEditor"/);
  assert.match(loyalty,/id="birthdayEditorCard"/);
  assert.match(app,/function applyGrowLoyaltyEditorIsolationV139\(/);
  assert.match(app,/element\.remove\(\)/);
});

test('an exact reward or Add route leaves only the requested reward form',()=>{
  assert.match(loyalty,/isExactRewardIntentV139/);
  assert.match(loyalty,/document\.querySelectorAll\('\.rwEdit'\)/);
  assert.match(loyalty,/pruneRewardSiblingsV139\(routeMain\)/);
  assert.match(grow,/focusGrowTarget\(focusTarget,\{activate:activateTarget\}\)/);
  assert.match(grow,/focusTarget:kind==='earning'\?'lm':kind==='classic'\?'lr':kind==='birthday'\?'birthdayLabel':kind==='add'\?'rwAdd'/);
  assert.match(loyalty,/editorIntent\?\.kind==='reward'/);
});

test('isolated draft saves and Done return to the single Grow overview',()=>{
  assert.match(loyalty,/const finishGrowEditorV139=\(\)=>editorIntent\?nav\('#\/grow'\):nav\('#\/loyalty'\)/);
  // V238 put the editor in a dialog: Done closes the dialog when open, and still leaves the
  // editor when it is not. Same intent — Done never strands the owner inside an editor.
  assert.match(loyalty,/\$\('rwClose'\)\.onclick=\(\)=>document\.getElementById\('rewardDialogV238'\)\?closeRewardDialogV238\(true\):finishGrowEditorV139\(\)/);
  assert.match(loyalty,/finishGrowEditorV139\(\);/);
  assert.match(loyalty,/Birthday benefit draft saved[\s\S]{0,240}?nav\('#\/grow'\)/);
});

test('ordinary combined renderer remains available only without an editor intent',()=>{
  assert.match(app,/if\(!editorIntent\)return;/);
  assert.match(app,/const keepByKind=/);
});
