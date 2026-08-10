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

const snapshot=section('async function growOverviewSnapshot','function ownerRewardJourneyV122');
const grow=section('async function growPage(','/* ---------- Bring-back playbooks');
const retention=section('async function retentionPage(','/* ---------- Grow: one customer journey');

test('Grow starts with one task and one complete single-column programme overview',()=>{
  // The standalone growAutoSetup launcher was retired when Programmes became one list; setup is
  // now started from the programme rows, which call openRewardsAutoSetup as the draft gate.
  assert.match(grow,/openRewardsAutoSetup\(action\)/);
  // V173 made this heading follow the selected tab (Running / To set up / List) instead of one
  // fixed title, so assert the element and its tab-driven content rather than the old string.
  /* V229 added the drilled-topic title in front of the tab-driven one; the tab-driven content
     this line protects is still the fallback and is asserted as such. */
  /* V245: the owner asked "Pending setup — where is it?", so the view names now match the
     nav row and the V244 tile group word-for-word. Same views, one vocabulary. */
  /* V271 put the owner's two new views (Overview, History) ahead of the older three in the same
     fallback chain; the tab-driven heading this line protects is unchanged in kind. */
  assert.match(grow,/id="rewardJourneyTitle">\$\{growActiveTopicV229\?esc\(growActiveTopicV229\.title\):\(programmeView==='overview'\?'Overview'/);
  assert.match(grow,/programmeView==='ongoing'\?'Ongoing programmes'/);
  assert.match(grow,/class="grow-programme-list"/);
  assert.match(app,/\.grow-programme-list\{display:grid;grid-template-columns:1fr/);
  assert.doesNotMatch(grow,/class="rewards-overview-grid"/,
    'the everyday overview must not return to a left/right reward grid');
  assert.ok(grow.indexOf('id="rewardJourneyTitle"')<grow.indexOf('id="growSecondarySettings"'));
});

test('configured and not-yet-configured programme families share the overview',()=>{
  for(const kind of ['earning','redeemable','birthday']){
    assert.match(grow,new RegExp(`data-programme-kind="${kind}"`),`${kind} is missing from the overview`);
  }
  for(const kind of ['bringback','referrals','memberships','giftcards']){
    assert.match(grow,new RegExp(`kind:'${kind}'`),`${kind} is missing from the overview`);
  }
  assert.match(grow,/Not set up/);
  assert.match(grow,/Not included/);
  assert.match(grow,/Read only/);
});

test('overview reads enough server state to label programme status without inventing setup',()=>{
  assert.match(snapshot,/referral_programs/);
  assert.match(snapshot,/membership_plans/);
  assert.match(snapshot,/business_get_checkout_preferences_v102/);
  // V271 added created_at so Programmes History can say when a bring-back reward ran.
  assert.match(snapshot,/retention_programs'\)\.select\('id,name,active,goal_visits,period_days,starts_on,created_at'/);
  assert.match(snapshot,/overviewErrors:[\s\S]*referrals:[\s\S]*memberships:[\s\S]*giftcards:/);
  assert.match(grow,/snapshot\.retention\.length\?snapshot\.retention\.map/);
  assert.match(grow,/const retentionOverviewState=program=>/);
  assert.match(grow,/startsOn>growAsOfDate/);
  assert.match(grow,/status:'Scheduled'/);
  assert.match(grow,/status:state\.status,statusTone:state\.tone/);
  assert.match(grow,/title:['"]Bring-back rewards['"][\s\S]*status:['"]Not set up['"]/);
  assert.match(grow,/snapshot\.referral\?['"]Paused['"]:['"]Not set up['"]/);
  assert.match(grow,/snapshot\.memberships\.length\?['"]Paused['"]:['"]Not set up['"]/);
  assert.match(grow,/giftCardsLive\?['"]Live['"]:['"]Off['"]/);
  for(const source of ['loyalty','rewards','birthday']){
    assert.match(grow,new RegExp(`overviewErrors\\?\\.${source}`),`${source} read failures need a row-level unavailable state`);
  }
});

test('not-yet-configured standalone modules deep-link to the exact create control',()=>{
  assert.match(grow,/#\/referrals\/fe/);
  assert.match(grow,/#\/memberships\/mn/);
  assert.match(grow,/#\/giftcards\/giftCardEnabled/);
  assert.match(app,/async function referralsPage\(\)[\s\S]{0,80}?routedFocus/);
  assert.match(app,/async function membershipsPage\(\)[\s\S]{0,80}?routedFocus/);
  assert.match(app,/async function giftcardsPage\(\)[\s\S]{0,80}?routedFocus/);
  assert.match(app,/focusRoutedWorkspaceControl\(routedFocus/);
});

test('earning, birthday, bring-back and stable reward routes retain exact edit intent',()=>{
  assert.match(grow,/function growFocusPath/);
  assert.match(grow,/reward~/);
  assert.match(grow,/routedFocus/);
  assert.match(grow,/decodeURIComponent/);
  assert.match(grow,/rewardId:kind==='catalogue'\?button\.dataset\.rewardId/);
  assert.match(grow,/directFocusTokens/);
  assert.match(grow,/data-program-id/);
  assert.match(grow,/program~/);
  assert.match(grow,/editProgramId:button\.dataset\.programId\|\|null/);
  assert.match(grow,/retentionPage\(draft,editProgramId/);
  assert.match(grow,/if\(!hashParamIsProgrammeView&&\(\(routedAction&&isOwner\)/);
  assert.match(retention,/const exactProgramMissing=Boolean\(editProgramId&&!editing\)/);
  assert.match(retention,/retentionExactProgramMissing/);
  assert.match(retention,/draftVersionId&&isOwner&&!exactProgramMissing/);
  assert.match(retention,/draftVersionId&&isOwner&&!exactProgramMissing\?`<div class="card"[^`]*Quick templates/);
  assert.match(retention,/draftVersionId&&isOwner&&!exactProgramMissing\?`<button class="btn ghost sm retentionEdit"/);
});

test('read-only and unavailable rows expose status but no dead writer',()=>{
  assert.match(grow,/canWriteModule\('referrals'\)/);
  assert.match(grow,/canWriteModule\('memberships'\)/);
  assert.match(grow,/canWriteModule\('giftcards'\)/);
  assert.match(grow,/programmeAction/);
  assert.match(grow,/if\(!canWrite\)return ''/);
  assert.match(grow,/const canSetupWinback=isOwner&&canWinback&&canWriteModule\('retention'\)/);
  assert.match(grow,/need owner edit access to configure it/);
});

test('advanced journey, profitability and technical tools remain collapsed after the overview',()=>{
  assert.match(grow,/<details class="grow-secondary" id="growSecondarySettings">/);
  assert.match(grow,/Product cost and profitability/);
  assert.match(grow,/<details class="grow-advanced"/);
});
