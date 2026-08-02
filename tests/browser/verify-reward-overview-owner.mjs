import assert from 'node:assert/strict';
import {mkdir} from 'node:fs/promises';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;

const base=process.env.REWARD_OVERVIEW_FIXTURE_URL||'http://127.0.0.1:4173/tests/browser/reward-overview-owner-visual.html';
const evidenceDir=new URL('../../docs/qa/evidence/reward-overview-owner-browser/',import.meta.url);
await mkdir(evidenceDir,{recursive:true});
const browser=await chromium.launch({headless:true,...(process.env.PLAYWRIGHT_EXECUTABLE_PATH?{executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH}:{})});
try{
  const page=await browser.newPage({viewport:{width:1440,height:1100},deviceScaleFactor:1});
  const consoleErrors=[];page.on('console',message=>{if(message.type()==='error')consoleErrors.push(message.text())});
  await page.goto(`${base}?draft=none`,{waitUntil:'networkidle'});
  await page.waitForSelector('#rewardJourneyTitle');
  let metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.title,'All reward programmes');
  assert.equal(metrics.autoSetupButtons,1,'writable owner receives one dominant automatic setup action');
  assert.ok(metrics.overviewTop<metrics.secondaryTop,'the complete overview appears before secondary settings');
  assert.equal(metrics.secondaryOpen,false,'journey anatomy and economics begin collapsed');
  assert.equal(metrics.viewport.clientWidth,metrics.viewport.scrollWidth,'desktop must not overflow horizontally');
  assert.equal(metrics.consoleErrors.length,0);assert.equal(consoleErrors.length,0);
  assert.equal(metrics.birthdayRpcCalls,1,'production snapshot adapter must use the published birthday RPC');
  assert.equal(metrics.birthdayTableReads,0,'production snapshot adapter must not read the closed birthday table');
  assert.ok(metrics.cards.length>=10,'configured rewards and every available programme family are visible');
  assert.deepEqual([...new Set(metrics.cards.map(card=>card.programmeKind))].sort(),
    ['birthday','bringback','earning','giftcards','memberships','redeemable','referrals']);
  assert.equal(metrics.cards.find(card=>card.programmeKind==='referrals')?.href,'#/referrals/fe');
  assert.equal(metrics.cards.find(card=>card.programmeKind==='memberships')?.href,'#/memberships/plist');
  assert.equal(metrics.cards.find(card=>card.programmeKind==='giftcards')?.href,'#/giftcards/giftCardEnabled');
  assert.match(metrics.cards.find(card=>card.programmeKind==='giftcards')?.text||'',/Off/);
  assert.ok(metrics.cards.every(card=>card.height>=44),'every interactive overview card is at least 44px tall');
  const duplicates=metrics.cards.filter(card=>card.kind==='catalogue'&&card.text.includes('Signature reward'));
  assert.deepEqual(duplicates.map(card=>card.rewardId),[
    '11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222']);
  assert.deepEqual(metrics.cards.filter(card=>card.programmeKind==='bringback').map(card=>card.programId),['bring-back-1','bring-back-2']);

  await page.goto(`${base}?draft=none&futureRetention=1`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  const scheduledBringBack=await page.locator('[data-program-id="bring-back-1"]').innerText();
  assert.match(scheduledBringBack,/Scheduled/,'an active future-dated Bring-back programme must not be labelled Live');
  assert.match(scheduledBringBack,/Starts 1 January 2099/,'the owner sees when the scheduled programme begins');
  await page.goto(`${base}?draft=none`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');

  await page.locator('#growAutoSetup').click();await page.waitForSelector('#rewardAutoSetupModal');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.recommendationCalls.length,0,'opening the popup performs zero recommendation writes');
  assert.equal(metrics.dialogStep,'Recommended for more repeat visits');
  assert.equal(metrics.activeElement,'rewardAutoConfirm');
  assert.equal(await page.locator('#rewardAutoNext').count(),0,'the review sheet has no pseudo-step Next action');
  assert.equal(await page.locator('#rewardAutoBack').count(),0,'the review sheet has no pseudo-step Back action');
  const reviewCopy=await page.locator('#rewardAutoBody').textContent();
  assert.match(reviewCopy,/facial/);
  assert.match(reviewCopy,/Earning rule \+ one return reward/);
  assert.match(reviewCopy,/Real fulfilment cost is not included/);
  assert.match(reviewCopy,/Birthday, Referrals, Memberships and Gift cards are not changed/);
  assert.match(reviewCopy,/Nothing goes live until you review and publish/);
  await page.keyboard.press('Escape');await page.waitForSelector('#rewardAutoSetupModal',{state:'detached'});
  assert.equal(await page.evaluate(()=>document.activeElement?.id),'growAutoSetup','Escape returns focus to the starting action');
  assert.equal((await page.evaluate(()=>window.rewardOverviewMetrics())).recommendationCalls.length,0,'dismissal performs zero writes');

  await page.locator('#growAutoSetup').click();
  await page.waitForTimeout(350);
  await page.screenshot({path:new URL('owner-auto-review-desktop-1440.png',evidenceDir).pathname,fullPage:true});
  await page.locator('#rewardAutoConfirm').click();await page.waitForSelector('#rewardAutoReady');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.recommendationCalls.length,1,'confirmation creates one editable recommendation draft');
  assert.ok(metrics.recommendationCalls[0].p_idempotency_key,'the draft request has a stable identity');
  assert.equal(metrics.recommendationResult.model,'points_tiers','governed facial fixture generates the repeat-service model');
  assert.equal(metrics.recommendationResult.published,false,'automatic setup never publishes');
  const readyCopy=await page.locator('#rewardAutoSetupModal').textContent();
  assert.match(readyCopy,/Recommended draft ready/);
  assert.match(readyCopy,/SGD 64\.00/);
  assert.match(readyCopy,/320 points/);
  assert.doesNotMatch(readyCopy,/SGD 3\.20/,'RPC reward cost is a points threshold, not cents');
  assert.match(readyCopy,/Nothing was published/);
  await page.screenshot({path:new URL('owner-auto-ready-desktop-1440.png',evidenceDir).pathname,fullPage:true});
  await page.locator('#rewardAutoReviewDraft').click();await page.waitForSelector('#lm');

  await page.goto(`${base}?draft=none&sector=cafe`,{waitUntil:'networkidle'});await page.waitForSelector('#growAutoSetup');
  await page.locator('#growAutoSetup').click();
  assert.match(await page.locator('#rewardAutoBody').textContent(),/cafe/,'CAFE-HARBOUR uses the governed cafe sector');
  await page.locator('#rewardAutoConfirm').click();await page.waitForSelector('#rewardAutoReady');
  const cafeReadyCopy=await page.locator('#rewardAutoSetupModal').textContent();
  assert.match(cafeReadyCopy,/Stamp card/);
  assert.match(cafeReadyCopy,/SGD 12\.00/);
  assert.match(cafeReadyCopy,/8 stamps/,'F&B RPC reward cost is a stamp threshold');
  assert.doesNotMatch(cafeReadyCopy,/SGD 0\.08/,'stamp threshold must never be formatted as cents');
  const cafeMetrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(cafeMetrics.recommendationResult.model,'stamps');
  assert.equal(cafeMetrics.recommendationResult.suggested_reward_cost,8);
  assert.equal(cafeMetrics.recommendationResult.suggested_spend_per_stamp_cents,600);
  await page.screenshot({path:new URL('owner-auto-ready-cafe-desktop-1440.png',evidenceDir).pathname,fullPage:true});
  await page.locator('#rewardAutoReviewDraft').click();await page.waitForSelector('#lm');

  await page.goto(`${base}?draft=none&sector=other`,{waitUntil:'networkidle'});await page.waitForSelector('#growAutoSetup');
  await page.locator('#growAutoSetup').click();await page.locator('#rewardAutoConfirm').click();await page.waitForSelector('#rewardAutoReady');
  const classicReadyCopy=await page.locator('#rewardAutoSetupModal').textContent();
  assert.match(classicReadyCopy,/Simple points/);
  assert.match(classicReadyCopy,/SGD 30\.00/);
  assert.match(classicReadyCopy,/Set in the draft/,'classic RPC null threshold remains explicitly unset');
  assert.doesNotMatch(classicReadyCopy,/0 points/,'classic RPC null must not be coerced into a false zero threshold');
  const classicMetrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(classicMetrics.recommendationResult.model,'classic');
  assert.equal(classicMetrics.recommendationResult.suggested_reward_cost,null);
  await page.screenshot({path:new URL('owner-auto-ready-classic-desktop-1440.png',evidenceDir).pathname,fullPage:true});
  await page.locator('#rewardAutoReviewDraft').click();await page.waitForSelector('#lm');

  await page.goto(`${base}?draft=none&failOnce=1`,{waitUntil:'networkidle'});await page.waitForSelector('#growAutoSetup');
  await page.locator('#growAutoSetup').click();
  await page.locator('#rewardAutoConfirm').click();await page.getByText('Draft could not be created. Nothing was published. Try again.').waitFor();
  let retryCalls=await page.evaluate(()=>window.rewardOverviewMetrics().recommendationCalls);
  assert.equal(retryCalls.length,1);
  await page.locator('#rewardAutoConfirm').click();await page.waitForSelector('#rewardAutoReady');
  retryCalls=await page.evaluate(()=>window.rewardOverviewMetrics().recommendationCalls);
  assert.equal(retryCalls.length,2);
  assert.equal(retryCalls[0].p_idempotency_key,retryCalls[1].p_idempotency_key,'lost-response retry reuses the same request identity');
  await page.locator('#rewardAutoReviewDraft').click();await page.waitForSelector('#lm');

  await page.goto(`${base}?draft=existing`,{waitUntil:'networkidle'});await page.waitForSelector('#growAutoSetup');
  assert.equal(await page.locator('#growAutoSetup').textContent(),'Continue rewards setup');
  await page.locator('#growAutoSetup').click();await page.waitForSelector('#lm');
  assert.equal(await page.locator('#rewardAutoSetupModal').count(),0,'existing draft opens without an unnecessary popup');
  assert.equal((await page.evaluate(()=>window.rewardOverviewMetrics())).recommendationCalls.length,0,'existing draft opens without replacement');

  await page.goto(`${base}?draft=none&concurrentDraft=1`,{waitUntil:'networkidle'});await page.waitForSelector('#growAutoSetup');
  await page.locator('#growAutoSetup').click();await page.locator('#rewardAutoConfirm').click();await page.waitForSelector('#rewardAutoReady');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.recommendationCalls.length,1,'stale second tab performs one serialized recommendation call');
  assert.equal(metrics.recommendationResult.status,'existing_draft');
  assert.equal(metrics.recommendationResult.resumed_existing,true,'server-created concurrent draft is resumed, not duplicated');
  await page.locator('#rewardAutoReviewDraft').click();await page.waitForSelector('#lm');

  await page.goto(`${base}?draft=existing`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  await page.locator('[data-reward-id="22222222-2222-4222-8222-222222222222"]').first().click();
  await page.waitForSelector('#rwCustomerName');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.openedRewardId,'22222222-2222-4222-8222-222222222222','duplicate-name click opens exact stable ID');
  assert.equal(metrics.activeElement,'rwCustomerName','exact reward editor keeps input focus');
  assert.equal(await page.evaluate(()=>location.hash),'#/loyalty/draft-v2/reward~22222222-2222-4222-8222-222222222222');
  assert.equal(await page.locator('#openedRewardIdentity').textContent(),'22222222-2222-4222-8222-222222222222');
  await page.screenshot({path:new URL('owner-exact-reward-editor-desktop-1440.png',evidenceDir).pathname,fullPage:true});
  await page.reload({waitUntil:'networkidle'});await page.waitForSelector('#rwCustomerName');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.openedRewardId,'22222222-2222-4222-8222-222222222222','exact stable-ID intent survives refresh');
  assert.equal(metrics.activeElement,'rwCustomerName');

  await page.goto(`${base}?draft=none&retentionExact=1`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  await page.locator('[data-program-id="bring-back-1"]').click();await page.waitForSelector('#rn');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.retentionName,'Glow regular return','configured Bring-back click opens the exact production editor record');
  assert.equal(metrics.activeElement,'rn');
  assert.deepEqual(metrics.growDraftCalls,[{
    p_business:'business-spa-glow',p_based_on:'published-v1',p_source:'grow_retention_edit'
  }],'configured Bring-back click creates or resumes one shared editable draft');
  assert.equal(await page.evaluate(()=>location.hash),'#/retention/draft-v2/program~bring-back-1');
  await page.screenshot({path:new URL('owner-exact-bringback-editor-desktop-1440.png',evidenceDir).pathname,fullPage:true});
  await page.reload({waitUntil:'networkidle'});await page.waitForSelector('#rn');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.retentionName,'Glow regular return','exact Bring-back ID survives refresh through the production renderer');
  assert.equal(metrics.retentionMissing,false);
  await page.goto(`${base}?draft=existing&pausedExact=1#/retention/draft-v2/program~bring-back-2`,{waitUntil:'networkidle'});await page.waitForSelector('#rn');
  assert.equal(await page.locator('#rn').inputValue(),'Paused facial return','second stable Bring-back ID opens its own production editor');
  await page.goto(`${base}?draft=existing&missingExact=1#/retention/draft-v2/program~missing-rule`,{waitUntil:'networkidle'});await page.waitForSelector('#retentionExactProgramMissing');
  assert.equal(await page.locator('#rn').count(),0,'missing exact ID must not silently become a new-program editor');
  const missingRouteDeadButtons=await page.locator('button:not([disabled])').evaluateAll(buttons=>buttons
    .filter(button=>button.offsetParent!==null&&typeof button.onclick!=='function')
    .map(button=>button.textContent.trim()));
  assert.deepEqual(missingRouteDeadButtons,[],'missing-ID fail-closed state exposes no visible enabled button without a handler');

  await page.goto(`${base}?draft=none&empty=1`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  assert.match(await page.locator('[data-programme-kind="earning"]').first().textContent(),/Not set up/);
  assert.match(await page.locator('[data-programme-kind="redeemable"]').first().textContent(),/Not set up/);
  assert.match(await page.locator('[data-programme-kind="birthday"]').first().textContent(),/Not set up/);
  await page.locator('[data-programme-kind="bringback"]').click();await page.waitForSelector('#rn');
  assert.equal(await page.locator('#rn').inputValue(),'','not-yet-configured Bring-back opens the exact new-program editor');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.growDraftCalls.length,1,'not-yet-configured Bring-back creates or resumes one shared editable draft');
  assert.equal(await page.evaluate(()=>location.hash),'#/retention/draft-v2/new');

  await page.goto(`${base}?draft=none&partial=1`,{waitUntil:'networkidle'});await page.waitForSelector('#growRewardsRetry');
  assert.equal(await page.locator('#growRewardsRetry').textContent(),'Retry programme overview');
  assert.match(await page.locator('[data-programme-kind="referrals"]').textContent(),/Unavailable/);

  await page.goto(`${base}?draft=none&configured=off`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  for(const kind of ['referrals','memberships']){
    assert.match(await page.locator(`[data-programme-kind="${kind}"]`).textContent(),/Paused/,`${kind} configured-off state must not be called not set up`);
  }
  assert.ok((await page.locator('[data-programme-kind="bringback"]').allTextContents()).every(text=>/Paused/.test(text)),'every configured-off Bring-back rule is paused');
  assert.match(await page.locator('[data-programme-kind="giftcards"]').textContent(),/Off/);

  await page.goto(`${base}?draft=none&partial=all`,{waitUntil:'networkidle'});await page.waitForSelector('#growRewardsRetry');
  for(const kind of ['earning','redeemable','birthday','bringback','referrals','memberships','giftcards']){
    const row=page.locator(`[data-programme-kind="${kind}"]`).first();
    assert.match(await row.textContent(),/Unavailable/,`${kind} read failure must remain unknown`);
    assert.equal(await row.evaluate(element=>['BUTTON','A'].includes(element.tagName)),false,`${kind} unavailable row must expose no writer`);
  }

  await page.goto(`${base}?modules=retention`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  assert.equal(await page.locator('#growAutoSetup').count(),0,'retention-only owner has no loyalty setup action');
  const retentionOnlyRows=page.locator('[data-programme-kind="bringback"]');
  assert.equal(await retentionOnlyRows.count(),2);
  assert.ok((await retentionOnlyRows.evaluateAll(rows=>rows.map(row=>row.tagName))).every(tag=>tag==='BUTTON'),'retention-only owner receives a working exact editor action');
  await retentionOnlyRows.first().click();await page.waitForSelector('#rn');
  assert.equal(await page.locator('#rn').inputValue(),'Glow regular return');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.deepEqual(metrics.growDraftCalls,[{
    p_business:'business-spa-glow',p_based_on:'published-v1',p_source:'grow_retention_edit'
  }]);
  assert.equal(await page.evaluate(()=>location.hash),'#/retention/draft-v2/program~bring-back-1');

  await page.goto(`${base}?draft=none&modules=loyalty`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  for(const kind of ['bringback','referrals','memberships','giftcards']){
    const row=page.locator(`[data-programme-kind="${kind}"]`);
    assert.match(await row.textContent(),/Not included/);
    assert.equal(await row.evaluate(element=>['BUTTON','A'].includes(element.tagName)),false,`${kind} has no dead writer`);
  }

  await page.setViewportSize({width:375,height:667});await page.goto(`${base}?draft=none`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.viewport.clientWidth,375);assert.equal(metrics.viewport.scrollWidth,375,'375px owner overview must not overflow');
  assert.ok(metrics.cards.every(card=>card.width<=351&&card.height>=44));
  await page.locator('#growAutoSetup').click();await page.waitForSelector('.reward-auto-dialog');
  await page.waitForTimeout(350);
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth),375,'375px popup must not overflow');
  const mobileButtons=await page.locator('.reward-auto-actions .btn').evaluateAll(buttons=>buttons.map(button=>{const box=button.getBoundingClientRect();return {height:box.height,top:box.top,bottom:box.bottom}}));
  assert.ok(mobileButtons.every(button=>button.height>=44&&button.top>=0&&button.bottom<=667),`popup actions remain visible and retain 44px touch targets: ${JSON.stringify(mobileButtons)}`);
  await page.screenshot({path:new URL('owner-auto-review-small-375.png',evidenceDir).pathname,fullPage:true});

  await page.setViewportSize({width:844,height:390});await page.goto(`${base}?draft=none`,{waitUntil:'networkidle'});await page.waitForSelector('#growAutoSetup');
  await page.locator('#growAutoSetup').click();await page.waitForSelector('.reward-auto-dialog');
  await page.waitForTimeout(350);
  const landscapeButtons=await page.locator('.reward-auto-actions .btn').evaluateAll(buttons=>buttons.map(button=>{const box=button.getBoundingClientRect();return {height:box.height,top:box.top,bottom:box.bottom}}));
  assert.ok(landscapeButtons.every(button=>button.height>=44&&button.top>=0&&button.bottom<=390),`landscape popup actions remain visible and retain 44px targets: ${JSON.stringify(landscapeButtons)}`);
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth),844,'landscape popup must not overflow');
  await page.screenshot({path:new URL('owner-auto-review-landscape-844.png',evidenceDir).pathname,fullPage:true});

  await page.setViewportSize({width:412,height:915});await page.goto(`${base}?draft=none`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth),412,'412px owner overview must not overflow');
  assert.ok((await page.locator('.grow-programme-row').evaluateAll(rows=>rows.map(row=>row.getBoundingClientRect().height))).every(height=>height>=44));

  await page.setViewportSize({width:390,height:844});
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
