import assert from 'node:assert/strict';
import {mkdir} from 'node:fs/promises';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const base=process.env.V143_FIXTURE_URL||'http://127.0.0.1:4173/tests/browser/v143-effective-loyalty-boundaries.html';
const evidenceDir=new URL('../../docs/qa/evidence/v143-effective-loyalty-boundaries/',import.meta.url);
await mkdir(evidenceDir,{recursive:true});
const browser=await chromium.launch({headless:true,...(process.env.PLAYWRIGHT_EXECUTABLE_PATH?{executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH}:{})});
try{
  const page=await browser.newPage({viewport:{width:1440,height:1100}});
  await page.goto(`${base}?role=owner`,{waitUntil:'networkidle'});
  let metrics=await page.evaluate(()=>window.v143Metrics());
  assert.deepEqual([...new Set(metrics.statuses)].sort(),['ended','live','paused','scheduled']);
  assert.equal(metrics.width,metrics.scrollWidth);
  assert.equal(metrics.consoleErrors.length,0);
  assert.equal(await page.locator('input[type="datetime-local"]').count(),2);
  assert.equal(metrics.pointsCost,'500');
  await page.locator('#productSource').selectOption('serum');
  await page.locator('#addDefaults').click();
  await page.locator('#addRewardBenefit').click();
  metrics=await page.evaluate(()=>window.v143Metrics());
  assert.equal(metrics.customerName,'Radiance Serum');
  assert.equal(metrics.budget,'26.00');
  assert.equal(metrics.pointsCost,'2600');
  assert.equal(metrics.tierBenefits,'Priority booking\nGlow Facial (500 points)');
  assert.match(await page.locator('#productEconomics').innerText(),/sells for SGD 88\.00.*company cost SGD 26\.00/);
  assert.match(await page.locator('#defaultTiers').innerText(),/Member.*Plus.*VIP/s);
  assert.match(await page.locator('#draftStatus').innerText(),/Nothing was published/);
  await page.screenshot({path:new URL('owner-desktop-1440.png',evidenceDir).pathname,fullPage:true});

  await page.goto(`${base}?role=owner&defaultsLost=1`,{waitUntil:'networkidle'});
  await page.locator('#addDefaults').click();
  await page.waitForFunction(()=>window.v143Metrics().tierDefaultCalls.length===1);
  metrics=await page.evaluate(()=>window.v143Metrics());
  assert.equal(metrics.defaultTierRows,0);
  assert.equal(metrics.buttons.find(button=>button.text==='Retry adding tiers')?.disabled,false);
  assert.match(metrics.draftStatus,/may have reached the server.*Retry safely/i);
  const lostResponseKey=metrics.tierDefaultCalls[0].args.p_idempotency_key;
  await page.locator('#addDefaults').click();
  await page.waitForFunction(()=>window.v143Metrics().tierDefaultCalls.length===2&&window.v143Metrics().defaultTierRows===3);
  metrics=await page.evaluate(()=>window.v143Metrics());
  assert.equal(metrics.tierDefaultCalls[1].args.p_idempotency_key,lostResponseKey);
  assert.equal(metrics.defaultTierRows,3);
  assert.match(metrics.draftStatus,/Nothing was published/);
  assert.equal(metrics.width,metrics.scrollWidth);
  await page.screenshot({path:new URL('owner-retry-desktop-1440.png',evidenceDir).pathname,fullPage:true});

  await page.goto(`${base}?role=staff`,{waitUntil:'networkidle'});
  metrics=await page.evaluate(()=>window.v143Metrics());
  assert.deepEqual(metrics.statuses,['live']);
  assert.ok(metrics.buttons.every(button=>button.disabled));
  assert.equal(metrics.width,metrics.scrollWidth);
  await page.screenshot({path:new URL('staff-desktop-1440.png',evidenceDir).pathname,fullPage:true});

  await page.goto(`${base}?role=customer`,{waitUntil:'networkidle'});
  metrics=await page.evaluate(()=>window.v143Metrics());
  assert.equal(metrics.buttons.filter(button=>button.text==='Redeem').length,1);
  assert.equal(await page.getByText('Available soon').count(),1);
  assert.equal(await page.getByText('Offer ended').count(),1);
  assert.equal(await page.getByText('Priority booking',{exact:true}).count(),1);
  assert.equal(await page.getByText('Glow Facial (500 points)',{exact:true}).count(),1);
  assert.equal(metrics.width,metrics.scrollWidth);
  await page.screenshot({path:new URL('customer-desktop-1440.png',evidenceDir).pathname,fullPage:true});

  await page.setViewportSize({width:390,height:844});
  await page.goto(`${base}?role=owner`,{waitUntil:'networkidle'});
  await page.locator('#productSource').selectOption('serum');
  await page.locator('#addDefaults').click();
  await page.locator('#addRewardBenefit').click();
  metrics=await page.evaluate(()=>window.v143Metrics());
  assert.equal(metrics.width,390);assert.equal(metrics.scrollWidth,390);
  assert.equal(metrics.customerName,'Radiance Serum');
  assert.equal(metrics.pointsCost,'2600');
  assert.equal(metrics.tierBenefits,'Priority booking\nGlow Facial (500 points)');
  assert.match(await page.locator('#draftStatus').innerText(),/Nothing was published/);
  await page.screenshot({path:new URL('owner-mobile-390.png',evidenceDir).pathname,fullPage:true});

  await page.goto(`${base}?role=owner&defaultsLost=1`,{waitUntil:'networkidle'});
  await page.locator('#addDefaults').click();
  await page.waitForFunction(()=>window.v143Metrics().tierDefaultCalls.length===1);
  metrics=await page.evaluate(()=>window.v143Metrics());
  assert.equal(metrics.defaultTierRows,0);
  assert.equal(metrics.buttons.find(button=>button.text==='Retry adding tiers')?.disabled,false);
  const mobileLostResponseKey=metrics.tierDefaultCalls[0].args.p_idempotency_key;
  await page.locator('#addDefaults').click();
  await page.waitForFunction(()=>window.v143Metrics().tierDefaultCalls.length===2&&window.v143Metrics().defaultTierRows===3);
  metrics=await page.evaluate(()=>window.v143Metrics());
  assert.equal(metrics.tierDefaultCalls[1].args.p_idempotency_key,mobileLostResponseKey);
  assert.equal(metrics.defaultTierRows,3);
  assert.match(metrics.draftStatus,/Nothing was published/);
  assert.equal(metrics.width,390);assert.equal(metrics.scrollWidth,390);
  await page.screenshot({path:new URL('owner-retry-mobile-390.png',evidenceDir).pathname,fullPage:true});

  await page.goto(`${base}?role=staff`,{waitUntil:'networkidle'});
  metrics=await page.evaluate(()=>window.v143Metrics());
  assert.deepEqual(metrics.statuses,['live']);
  assert.ok(metrics.buttons.every(button=>button.disabled));
  assert.equal(metrics.width,metrics.scrollWidth);
  await page.screenshot({path:new URL('staff-mobile-390.png',evidenceDir).pathname,fullPage:true});

  await page.goto(`${base}?role=customer`,{waitUntil:'networkidle'});
  metrics=await page.evaluate(()=>window.v143Metrics());
  assert.equal(metrics.buttons.filter(button=>button.text==='Redeem').length,1);
  assert.equal(await page.getByText('Available soon').count(),1);
  assert.equal(await page.getByText('Offer ended').count(),1);
  assert.equal(await page.getByText('Priority booking',{exact:true}).count(),1);
  assert.equal(await page.getByText('Glow Facial (500 points)',{exact:true}).count(),1);
  assert.equal(metrics.width,metrics.scrollWidth);
  await page.screenshot({path:new URL('customer-mobile-390.png',evidenceDir).pathname,fullPage:true});

  for(const state of ['empty','disabled','retry']){
    await page.goto(`${base}?state=${state}`,{waitUntil:'networkidle'});
    assert.equal((await page.evaluate(()=>window.v143Metrics())).width,(await page.evaluate(()=>window.v143Metrics())).scrollWidth);
  }
}finally{await browser.close()}
process.stdout.write('v143 browser acceptance passed\n');
