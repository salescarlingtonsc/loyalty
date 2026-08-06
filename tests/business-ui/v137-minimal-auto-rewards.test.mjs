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

const grow=section('async function growPage(','/* ---------- Bring-back playbooks');
const popup=section('function openRewardsAutoSetup(','document.querySelectorAll(\'[data-reward-cost]\')');

test('new automatic setup is one truthful review sheet and one confirmation',()=>{
  assert.match(grow,/Create recommended rewards draft/);
  assert.doesNotMatch(popup,/Step 1 of 3|Step 2 of 3|Step 3 of 3/);
  assert.doesNotMatch(popup,/id="rewardAutoNext"|id="rewardAutoBack"/);
  assert.match(popup,/Review the recommended starting point/);
  assert.match(popup,/Earning rule \+ one return reward/);
  assert.match(popup,/Birthday, Referrals, Memberships and Gift cards are not changed/);
  assert.match(popup,/Real fulfilment cost is not included/);
  assert.equal((popup.match(/id="rewardAutoConfirm"/g)||[]).length,1);
});

test('existing draft is a direct one-action continuation with zero recommendation write',()=>{
  assert.match(grow,/Continue rewards setup/);
  assert.match(grow,/if\(growDraftVersionId\)return mountGrowSurface\('rewards',\{draftOverride:growDraftVersionId,focusTarget:'lm'\}\)/);
  const directHandler=grow.slice(grow.indexOf("const autoSetupButton=$('growAutoSetup')"),grow.indexOf("document.querySelectorAll('[data-rewards-overview-edit]')"));
  assert.ok(directHandler.indexOf('if(growDraftVersionId)')<directHandler.indexOf('openRewardsAutoSetup'));
  assert.doesNotMatch(directHandler,/generate_retention_recommendation/);
});

test('successful creation shows a concise, truthful draft-ready handoff',()=>{
  assert.match(popup,/Recommended draft ready/);
  assert.match(popup,/id="rewardAutoReviewDraft"/);
  assert.match(popup,/Reference price/);
  assert.match(popup,/Reward threshold/);
  assert.match(popup,/Nothing was published/);
  assert.match(popup,/mountGrowSurface\(nextAction\.surface,\{draftOverride:growDraftVersionId,\.\.\.nextAction\}\)/);
});

test('success handoff formats the RPC reward threshold as points or stamps, never currency',()=>{
  assert.match(popup,/data\?\.model==='stamps'\?'stamp':'point'/);
  assert.match(popup,/suggested_reward_cost[\s\S]*?thresholdUnit/);
  assert.doesNotMatch(popup,/suggestedMilestone[\s\S]{0,160}?money\(/);
  assert.match(popup,/<dt>Reward threshold<\/dt>/);
});

test('classic fallback preserves a null threshold as unset instead of inventing zero points',()=>{
  assert.match(popup,/rawThreshold=data\?\.suggested_reward_cost/);
  assert.match(popup,/rawThreshold!==null&&rawThreshold!==undefined&&rawThreshold!==''/);
  assert.match(popup,/'Set in the draft'/);
  assert.doesNotMatch(popup,/Number\(data\?\.suggested_reward_cost\)/);
});

test('one-sheet flow preserves no-write dismiss, idempotent retry and no-publish boundaries',()=>{
  const beforeConfirm=popup.slice(0,popup.indexOf("sb.rpc('generate_retention_recommendation'"));
  assert.doesNotMatch(beforeConfirm,/sb\.(?:rpc|from)\([^)]*\)\.(?:insert|update|upsert|delete)/);
  assert.match(popup,/rewardAutoSetupRequestKey\?\?=crypto\.randomUUID\(\)/);
  assert.match(popup,/rewardAutoConfirm\.disabled=true/);
  assert.match(popup,/Try creating draft again/);
  assert.doesNotMatch(popup,/publish_(?:config|loyalty)|studio_publish|publishProgram/);
});

test('primary actions stay visible on short portrait and landscape viewports',()=>{
  assert.match(app,/\.reward-auto-actions\{[^}]*position:sticky;bottom:0/);
  assert.match(app,/\.reward-auto-content\{[^}]*overflow:auto/);
  assert.match(app,/@media\(max-height:700px\)[\s\S]*?\.reward-auto-dialog/);
  assert.match(app,/\.reward-auto-actions[\s\S]*?\.btn\{min-height:44px/);
});
