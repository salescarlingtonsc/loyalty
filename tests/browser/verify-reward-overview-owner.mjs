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
  await page.goto(base,{waitUntil:'networkidle'});
  await page.waitForSelector('#rewardJourneyTitle');
  let metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.title,'Rewards overview');
  assert.equal(metrics.viewport.clientWidth,metrics.viewport.scrollWidth,'desktop must not overflow horizontally');
  assert.equal(metrics.consoleErrors.length,0);assert.equal(consoleErrors.length,0);
  assert.equal(metrics.birthdayRpcCalls,1,'production snapshot adapter must use the published birthday RPC');
  assert.equal(metrics.birthdayTableReads,0,'production snapshot adapter must not read the closed birthday table');
  assert.ok(metrics.cards.length>=5,'earn, two active rewards, birthday and archived reward are visible');
  assert.ok(metrics.cards.every(card=>card.height>=44),'every interactive overview card is at least 44px tall');
  const duplicates=metrics.cards.filter(card=>card.kind==='catalogue'&&card.text.includes('Signature reward'));
  assert.deepEqual(duplicates.map(card=>card.rewardId),[
    '11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222']);
  await page.locator('[data-reward-id="22222222-2222-4222-8222-222222222222"]').first().click();
  await page.waitForSelector('#rwCustomerName');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.openedRewardId,'22222222-2222-4222-8222-222222222222','duplicate-name click opens exact stable ID');
  assert.equal(metrics.activeElement,'rwCustomerName','exact reward editor keeps input focus');
  assert.equal(await page.locator('#openedRewardIdentity').textContent(),'22222222-2222-4222-8222-222222222222');
  await page.screenshot({path:new URL('owner-exact-reward-editor-desktop-1440.png',evidenceDir).pathname,fullPage:true});

  await page.setViewportSize({width:390,height:844});await page.goto(base,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.viewport.clientWidth,390);assert.equal(metrics.viewport.scrollWidth,390,'390px owner overview must not overflow');
  assert.ok(metrics.cards.every(card=>card.width<=366&&card.height>=44));
  await page.locator('[data-rewards-overview-edit="birthday"]').click();await page.waitForSelector('#birthdayLabel');
  assert.equal(await page.locator('#birthdayLabel').inputValue(),'Birthday Glow');
  await page.screenshot({path:new URL('owner-birthday-editor-mobile-390.png',evidenceDir).pathname,fullPage:true});

  await page.goto(`${base}?role=manager`,{waitUntil:'networkidle'});await page.waitForSelector('#rewardJourneyTitle');
  metrics=await page.evaluate(()=>window.rewardOverviewMetrics());
  assert.equal(metrics.role,'manager');assert.equal(metrics.editButtons,0,'read-only manager receives no edit control');
  assert.equal(metrics.birthdayRpcCalls,1,'read-only manager loads birthday through the same permission-safe RPC');
  assert.equal(metrics.birthdayTableReads,0);
  assert.ok(metrics.cards.every(card=>card.tag==='ARTICLE'));
  assert.equal(metrics.viewport.clientWidth,metrics.viewport.scrollWidth);
  await page.screenshot({path:new URL('manager-read-only-mobile-390.png',evidenceDir).pathname,fullPage:true});
  process.stdout.write(JSON.stringify({status:'PASS',sourceHash:metrics.sourceHash,evidenceDir:evidenceDir.pathname},null,2)+'\n');
}finally{await browser.close()}
