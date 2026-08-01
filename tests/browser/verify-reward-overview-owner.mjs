import assert from 'node:assert/strict';
import {mkdir} from 'node:fs/promises';

const {chromium}=await import(process.env.PLAYWRIGHT_MODULE||'playwright');

const base=process.env.REWARD_OVERVIEW_FIXTURE_URL||'http://127.0.0.1:4173/tests/browser/reward-overview-owner-visual.html';
const evidenceDir=new URL('../../docs/qa/evidence/reward-overview-owner-browser/',import.meta.url);
await mkdir(evidenceDir,{recursive:true});
const browser=await chromium.launch({headless:true});
try{
  const page=await browser.newPage({viewport:{width:1440,height:1100},deviceScaleFactor:1});
  const consoleErrors=[];page.on('console',message=>{if(message.type()==='error')consoleErrors.push(message.text())});
  await page.goto(`${base}?draft=none`,{waitUntil:'networkidle'});
  await page.waitForSelector('#rewardJourneyTitle');
  let metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.title,'Rewards overview');
  assert.equal(metrics.autoSetupButtons,1,'writable owner receives one dominant automatic setup action');
  assert.ok(metrics.overviewTop<metrics.secondaryTop,'the complete overview appears before secondary settings');
  assert.equal(metrics.secondaryOpen,false,'journey anatomy and economics begin collapsed');
  assert.equal(metrics.viewport.clientWidth,metrics.viewport.scrollWidth,'desktop must not overflow horizontally');
  assert.equal(metrics.consoleErrors.length,0);assert.equal(consoleErrors.length,0);
  assert.equal(metrics.birthdayRpcCalls,1,'production snapshot adapter must use the published birthday RPC');
  assert.equal(metrics.birthdayTableReads,0,'production snapshot adapter must not read the closed birthday table');
  assert.ok(metrics.cards.length>=5,'earn, two active rewards, birthday and archived reward are visible');
  assert.ok(metrics.cards.every(card=>card.height>=44),'every interactive overview card is at least 44px tall');
  const duplicates=metrics.cards.filter(card=>card.kind==='catalogue'&&card.text.includes('Signature reward'));
  assert.deepEqual(duplicates.map(card=>card.rewardId),[
    '11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222']);

  await page.locator('#growAutoSetup').click();await page.waitForSelector('#rewardAutoSetupModal');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.recommendationCalls.length,0,'opening the popup performs zero recommendation writes');
  assert.equal(metrics.dialogStep,'Confirm the goal');
  assert.equal(metrics.activeElement,'rewardAutoGoal');
  await page.keyboard.press('Escape');await page.waitForSelector('#rewardAutoSetupModal',{state:'detached'});
  assert.equal(await page.evaluate(()=>document.activeElement?.id),'growAutoSetup','Escape returns focus to the starting action');
  assert.equal((await page.evaluate(()=>window.rewardOverviewMetrics())).recommendationCalls.length,0,'dismissal performs zero writes');

  await page.locator('#growAutoSetup').click();
  await page.locator('#rewardAutoNext').click();
  assert.equal(await page.locator('#rewardAutoStepTitle').textContent(),'See what Nestly will use');
  assert.match(await page.locator('#rewardAutoBody').textContent(),/facial/);
  assert.match(await page.locator('#rewardAutoBody').textContent(),/Product costs are not used/);
  assert.doesNotMatch(await page.locator('#rewardAutoBody').textContent(),/Earn 10 points per SGD 1 spent/,
    'the popup must not present the current published rule as the generated recommendation');
  await page.locator('#rewardAutoBack').click();
  assert.equal(await page.evaluate(()=>document.activeElement?.id),'rewardAutoStepTitle','Back keeps keyboard focus inside Step 1');
  await page.locator('#rewardAutoNext').click();
  await page.locator('#rewardAutoNext').click();
  assert.equal(await page.locator('#rewardAutoStepTitle').textContent(),'Review the safety check');
  assert.match(await page.locator('.reward-auto-safety').textContent(),/Nothing goes live until you review and publish/);
  await page.waitForTimeout(350);
  await page.screenshot({path:new URL('owner-automatic-setup-popup-desktop-1440.png',evidenceDir).pathname,fullPage:true});
  await page.locator('#rewardAutoConfirm').click();await page.waitForSelector('#lm');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.recommendationCalls.length,1,'confirmation creates one editable recommendation draft');
  assert.ok(metrics.recommendationCalls[0].p_idempotency_key,'the draft request has a stable identity');
  assert.equal(metrics.recommendationResult.model,'points_tiers','governed facial fixture generates the repeat-service model');
  assert.equal(metrics.recommendationResult.published,false,'automatic setup never publishes');
  await page.screenshot({path:new URL('owner-automatic-setup-draft-desktop-1440.png',evidenceDir).pathname,fullPage:true});

  await page.goto(`${base}?draft=none&failOnce=1`,{waitUntil:'networkidle'});await page.waitForSelector('#growAutoSetup');
  await page.locator('#growAutoSetup').click();await page.locator('#rewardAutoNext').click();await page.locator('#rewardAutoNext').click();
  await page.locator('#rewardAutoConfirm').click();await page.getByText('Draft could not be created. Nothing was published. Try again.').waitFor();
  let retryCalls=await page.evaluate(()=>window.rewardOverviewMetrics().recommendationCalls);
  assert.equal(retryCalls.length,1);
  await page.locator('#rewardAutoConfirm').click();await page.waitForSelector('#lm');
  retryCalls=await page.evaluate(()=>window.rewardOverviewMetrics().recommendationCalls);
  assert.equal(retryCalls.length,2);
  assert.equal(retryCalls[0].p_idempotency_key,retryCalls[1].p_idempotency_key,'lost-response retry reuses the same request identity');

  await page.goto(`${base}?draft=existing`,{waitUntil:'networkidle'});await page.waitForSelector('#growAutoSetup');
  await page.locator('#growAutoSetup').click();await page.locator('#rewardAutoNext').click();await page.locator('#rewardAutoNext').click();
  assert.equal(await page.locator('#rewardAutoConfirm').textContent(),'Open editable draft');
  await page.locator('#rewardAutoConfirm').click();await page.waitForSelector('#lm');
  assert.equal((await page.evaluate(()=>window.rewardOverviewMetrics())).recommendationCalls.length,0,'existing draft opens without replacement');

  await page.goto(`${base}?draft=none&concurrentDraft=1`,{waitUntil:'networkidle'});await page.waitForSelector('#growAutoSetup');
  await page.locator('#growAutoSetup').click();await page.locator('#rewardAutoNext').click();await page.locator('#rewardAutoNext').click();
  await page.locator('#rewardAutoConfirm').click();await page.waitForSelector('#lm');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.recommendationCalls.length,1,'stale second tab performs one serialized recommendation call');
  assert.equal(metrics.recommendationResult.status,'existing_draft');
  assert.equal(metrics.recommendationResult.resumed_existing,true,'server-created concurrent draft is resumed, not duplicated');

  await page.goto(`${base}?draft=existing`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  await page.locator('[data-reward-id="22222222-2222-4222-8222-222222222222"]').first().click();
  await page.waitForSelector('#rwCustomerName');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.openedRewardId,'22222222-2222-4222-8222-222222222222','duplicate-name click opens exact stable ID');
  assert.equal(metrics.activeElement,'rwCustomerName','exact reward editor keeps input focus');
  assert.equal(await page.locator('#openedRewardIdentity').textContent(),'22222222-2222-4222-8222-222222222222');
  await page.screenshot({path:new URL('owner-exact-reward-editor-desktop-1440.png',evidenceDir).pathname,fullPage:true});

  await page.setViewportSize({width:390,height:844});await page.goto(`${base}?draft=none`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.viewport.clientWidth,390);assert.equal(metrics.viewport.scrollWidth,390,'390px owner overview must not overflow');
  assert.ok(metrics.cards.every(card=>card.width<=366&&card.height>=44));
  await page.locator('#growAutoSetup').click();await page.waitForSelector('.reward-auto-dialog');
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth),390,'390px popup must not overflow');
  const mobileButtons=await page.locator('.reward-auto-actions .btn').evaluateAll(buttons=>buttons.map(button=>button.offsetHeight));
  assert.ok(mobileButtons.every(height=>height>=44),'popup actions retain 44px touch targets');
  await page.waitForTimeout(350);
  await page.screenshot({path:new URL('owner-automatic-setup-mobile-390.png',evidenceDir).pathname,fullPage:true});

  await page.goto(`${base}?role=manager`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.role,'manager');assert.equal(metrics.editButtons,0,'read-only manager receives no edit control');
  assert.equal(metrics.autoSetupButtons,0,'read-only manager receives no automatic setup writer');
  assert.equal(metrics.birthdayRpcCalls,1,'read-only manager loads birthday through the same permission-safe RPC');
  assert.equal(metrics.birthdayTableReads,0);
  assert.ok(metrics.cards.every(card=>card.tag==='ARTICLE'));
  assert.equal(metrics.viewport.clientWidth,metrics.viewport.scrollWidth);
  await page.screenshot({path:new URL('manager-read-only-mobile-390.png',evidenceDir).pathname,fullPage:true});
  process.stdout.write(JSON.stringify({status:'PASS',sourceHash:metrics.sourceHash,evidenceDir:evidenceDir.pathname},null,2)+'\n');
}finally{await browser.close()}
