import assert from 'node:assert/strict';
import {mkdir} from 'node:fs/promises';
import path from 'node:path';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
if(!chromium)throw new Error('Playwright Chromium is unavailable');

const base=process.env.V141_BASE_URL||'http://127.0.0.1:4173';
const evidence=process.env.V141_EVIDENCE_DIR||path.resolve('docs/qa/evidence/v141-dashboard-customer-usability');
await mkdir(evidence,{recursive:true});
const browser=await chromium.launch({headless:true,...(process.env.PLAYWRIGHT_EXECUTABLE_PATH?{executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH}:{})});

async function pageAt(viewport){
  const page=await browser.newPage({viewport});
  const pageErrors=[];
  page.on('pageerror',error=>pageErrors.push(String(error)));
  page.on('console',message=>{if(message.type()==='error')pageErrors.push(message.text())});
  return {page,pageErrors};
}

async function assertHealthy(page,pageErrors,metricsName){
  const body=await page.locator('body').innerText();
  assert.ok(body.trim().length>100,'page must render meaningful content');
  assert.equal(await page.locator('[data-nextjs-dialog],.vite-error-overlay,#webpack-dev-server-client-overlay').count(),0,'no framework error overlay');
  const metrics=await page.evaluate(name=>window[name]?.(),metricsName);
  assert.ok(metrics,`${metricsName} must be exposed`);
  assert.deepEqual(metrics.errors,[],'fixture must record no renderer errors');
  assert.deepEqual(pageErrors,[],'browser must record no page or console errors');
  return metrics;
}

try{
  {
    const {page,pageErrors}=await pageAt({width:1440,height:1000});
    await page.goto(`${base}/tests/browser/v141-dashboard-visual.html`,{waitUntil:'networkidle'});
    await page.locator('[data-dashboard-metric="inactive"]').waitFor();
    let metrics=await assertHealthy(page,pageErrors,'v141DashboardMetrics');
    assert.equal(metrics.taskCards,0,'duplicate task cards must be absent');
    assert.equal(metrics.branchInAppbar,true,'branch selector must be in the app bar');
    assert.deepEqual(metrics.metricKeys,['visits','revenue','unique','new','points','credit','inactive']);
    assert.deepEqual(metrics.charts,['Busiest days','Revenue over time','Age groups','Recorded gender','Services and goods sold']);
    assert.equal(metrics.saleItemsReads,1,'owner may read the existing owner-visible item detail');
    assert.equal(metrics.itemMixUnavailable,'');
    assert.deepEqual(metrics.saleMixValues,[1280,392,65],'signed checkout discounts must be excluded from gross positive item mix');
    await page.locator('[data-dashboard-metric="unique"]').click();
    await page.locator('#dashboardMetricModal').waitFor();
    metrics=await page.evaluate(()=>window.v141DashboardMetrics());
    assert.equal(metrics.modalTitle,'Unique customers');
    assert.match(await page.locator('#dashboardMetricModal').innerText(),/counted once even after several entries/i);
    await page.locator('#dashboardMetricClose').click();
    await page.locator('#dashboardBranchWrap select').selectOption('branch-one');
    await page.locator('[data-dashboard-metric="new"]').click();
    assert.match(await page.locator('#dashboardMetricModal').innerText(),/All business customers/i,'business-wide KPI must not claim selected-branch scope');
    await page.locator('#dashboardMetricClose').click();
    await page.locator('[data-dashboard-metric="visits"]').click();
    assert.match(await page.locator('#dashboardMetricModal').innerText(),/Orchard/i,'branch-scoped KPI must name the applied branch');
    await page.locator('#dashboardMetricClose').click();
    await page.locator('#df').fill('2026-07-01');
    await page.locator('[data-dashboard-metric="visits"]').click();
    assert.doesNotMatch(await page.locator('#dashboardMetricModal').innerText(),/2026-07-01/,'edited but unapplied dates must not relabel stale KPI values');
    await page.locator('#dashboardMetricClose').click();
    await page.locator('#apply').click();
    await page.locator('[data-dashboard-metric="visits"]').click();
    assert.match(await page.locator('#dashboardMetricModal').innerText(),/2026-07-01/,'successful Apply must update the authoritative displayed scope');
    await page.locator('#dashboardMetricClose').click();
    await page.locator('[data-dashboard-metric="inactive"]').click();
    await page.locator('#dashboardMetricGo').click();
    assert.equal((await page.evaluate(()=>window.v141DashboardMetrics())).lastNavigation,'#/clients');
    await page.waitForTimeout(1000);
    await page.screenshot({path:path.join(evidence,'dashboard-desktop-1440.png'),fullPage:true});
    await page.close();
  }
  for(const role of ['manager','frontdesk']){
    for(const viewport of [{width:1440,height:1000},{width:1180,height:820},{width:390,height:844}]){
      const {page,pageErrors}=await pageAt(viewport);
      await page.goto(`${base}/tests/browser/v141-dashboard-visual.html?role=${role}`,{waitUntil:'networkidle'});
      await page.locator('[data-dashboard-metric="inactive"]').waitFor();
      const metrics=await assertHealthy(page,pageErrors,'v141DashboardMetrics');
      assert.equal(metrics.role,role);
      assert.equal(metrics.saleItemsReads,0,`${role} must not issue an owner-only sale_items read at ${viewport.width}px`);
      assert.match(metrics.itemMixUnavailable,/available to owners/i,`${role} must see a truthful unavailable item-mix state at ${viewport.width}px`);
      assert.ok(metrics.scrollWidth<=metrics.width+1,`${role} dashboard overflowed at ${viewport.width}px`);
      if(viewport.width===390)assert.equal(await page.locator('.side').isVisible(),false,`${role} desktop rail must collapse on phone`);
      if(role==='manager'&&viewport.width===1180){await page.waitForTimeout(1000);await page.screenshot({path:path.join(evidence,'dashboard-manager-ipad-1180.png'),fullPage:true})}
      await page.close();
    }
  }
  {
    const {page,pageErrors}=await pageAt({width:1180,height:820});
    await page.goto(`${base}/tests/browser/v141-dashboard-visual.html`,{waitUntil:'networkidle'});
    await page.locator('[data-dashboard-metric="inactive"]').waitFor();
    const metrics=await assertHealthy(page,pageErrors,'v141DashboardMetrics');
    assert.ok(metrics.scrollWidth<=metrics.width+1,`iPad-class page overflowed: ${metrics.scrollWidth} > ${metrics.width}`);
    await page.waitForTimeout(1000);
    await page.screenshot({path:path.join(evidence,'dashboard-ipad-1180.png'),fullPage:true});
    await page.close();
  }
  {
    const {page,pageErrors}=await pageAt({width:390,height:844});
    await page.goto(`${base}/tests/browser/v141-dashboard-visual.html`,{waitUntil:'networkidle'});
    await page.locator('[data-dashboard-metric="inactive"]').waitFor();
    const metrics=await assertHealthy(page,pageErrors,'v141DashboardMetrics');
    assert.ok(metrics.scrollWidth<=metrics.width+1,`phone page overflowed: ${metrics.scrollWidth} > ${metrics.width}`);
    assert.equal(await page.locator('.side').isVisible(),false,'desktop rail must collapse on phone');
    await page.waitForTimeout(1000);
    await page.screenshot({path:path.join(evidence,'dashboard-phone-390.png'),fullPage:true});
    await page.close();
  }
  {
    const {page,pageErrors}=await pageAt({width:390,height:844});
    await page.goto(`${base}/tests/browser/v141-dashboard-visual.html?report_error=1`,{waitUntil:'networkidle'});
    await page.locator('#dashboardReportRetry').waitFor();
    assert.match(await page.locator('#dashboardStatus').innerText(),/Performance data could not be loaded/i);
    assert.equal(await page.locator('[data-dashboard-metric]').count(),0,'failed report must not leave stale KPI values');
    assert.equal(await page.locator('#kpis').getAttribute('aria-busy'),'false','failed report must end the KPI busy state');
    assert.equal(await page.locator('#charts').getAttribute('aria-busy'),'false','failed report must end the chart busy state');
    await page.locator('#dashboardReportRetry').click();
    await page.locator('[data-dashboard-metric="inactive"]').waitFor();
    const metrics=await assertHealthy(page,pageErrors,'v141DashboardMetrics');
    assert.equal(metrics.reportReads,2,'report Retry must issue one fresh report read');
    assert.equal(metrics.dashboardStatus,'','successful report Retry must clear the error');
    await page.close();
  }
  {
    const {page,pageErrors}=await pageAt({width:390,height:844});
    await page.goto(`${base}/tests/browser/v141-dashboard-visual.html?inactive_error=1`,{waitUntil:'networkidle'});
    await page.locator('#dashboardInactiveRetry').waitFor();
    assert.equal(await page.locator('[data-dashboard-metric="inactive"] .v').innerText(),'Unavailable');
    await page.locator('#dashboardInactiveRetry').click();
    await page.locator('[data-dashboard-metric="inactive"] .v').filter({hasText:'2'}).waitFor();
    const metrics=await assertHealthy(page,pageErrors,'v141DashboardMetrics');
    assert.equal(metrics.inactiveReads,2,'inactive-count Retry must issue one fresh count read');
    assert.equal(metrics.dashboardStatus,'','successful inactivity Retry must clear the error');
    await page.close();
  }
  {
    const {page,pageErrors}=await pageAt({width:390,height:844});
    await page.goto(`${base}/tests/browser/v141-dashboard-visual.html?item_error=1`,{waitUntil:'networkidle'});
    await page.locator('#dashboardSaleMixRetry').waitFor();
    assert.match(await page.locator('.dashboard-chart-card:last-of-type').innerText(),/Services and goods detail could not be loaded/i);
    await page.locator('#dashboardSaleMixRetry').click();
    await page.locator('#c6').waitFor();
    const metrics=await assertHealthy(page,pageErrors,'v141DashboardMetrics');
    assert.equal(metrics.saleItemsReads,2,'item-detail Retry must issue one fresh owner read');
    assert.deepEqual(metrics.saleMixValues,[1280,392,65],'retried mix must exclude signed discount lines');
    await page.close();
  }
  {
    const {page,pageErrors}=await pageAt({width:1180,height:820});
    await page.goto(`${base}/tests/browser/v129-trial-test-visual.html?view=customers&inactive=30`,{waitUntil:'domcontentloaded'});
    await page.locator('#list table').waitFor();
    let metrics=await assertHealthy(page,pageErrors,'v129Metrics');
    assert.ok(metrics.rows>=1,'inactive customer list must render results');
    assert.match(await page.locator('#list').innerText(),/Date joined/i);
    assert.equal(await page.locator('#clientInactivity').inputValue(),'30');
    await page.screenshot({path:path.join(evidence,'customers-ipad-1180.png'),fullPage:true});
    await page.close();
  }
  {
    const {page,pageErrors}=await pageAt({width:390,height:844});
    await page.goto(`${base}/tests/browser/v129-trial-test-visual.html?view=profile`,{waitUntil:'domcontentloaded'});
    await page.locator('.c360-rewards-head').waitFor();
    const metrics=await assertHealthy(page,pageErrors,'v129Metrics');
    assert.ok(metrics.scrollWidth<=metrics.width+1,`profile overflowed: ${metrics.scrollWidth} > ${metrics.width}`);
    assert.match(await page.locator('.c360-nba').innerText(),/Peekaa's suggestion/i);
    assert.match(await page.locator('.c360-points-expiry').innerText(),/300 points expire 28 Sept? 2026/i);
    assert.match(await page.locator('.c360-rewards-head').innerText(),/Balance, earning and next unlock/i);
    assert.ok(metrics.buttons.every(height=>height>=43.5),'visible buttons and links must preserve 44px-class targets');
    await page.screenshot({path:path.join(evidence,'customer-profile-phone-390.png'),fullPage:true});
    await page.close();
  }
  {
    const {page,pageErrors}=await pageAt({width:390,height:844});
    await page.goto(`${base}/tests/browser/v129-trial-test-visual.html?view=customers&joined_error=1`,{waitUntil:'domcontentloaded'});
    await page.locator('#customerJoinedRetry').waitFor();
    assert.ok(await page.locator('#list table').count(),'join-date interruption must leave customer rows usable');
    await page.locator('#customerJoinedRetry').click();
    await page.locator('#list table').waitFor();
    assert.equal(await page.locator('#customerJoinedRetry').count(),0,'retry must restore Date joined values');
    await assertHealthy(page,pageErrors,'v129Metrics');
    await page.close();
  }
  {
    const {page,pageErrors}=await pageAt({width:390,height:844});
    await page.goto(`${base}/tests/browser/v129-trial-test-visual.html?view=profile&expiry_error=1`,{waitUntil:'domcontentloaded'});
    await page.locator('#c360ExpiryRetry').waitFor();
    assert.doesNotMatch(await page.locator('.c360-points-expiry').innerText(),/No points are currently scheduled/i);
    await page.locator('#c360ExpiryRetry').click();
    await page.locator('.c360-points-expiry').filter({hasText:'300 points expire'}).waitFor();
    await assertHealthy(page,pageErrors,'v129Metrics');
    await page.close();
  }
  for(const query of ['no_expiry=1','no_programme=1','role=readonly']){
    const {page,pageErrors}=await pageAt({width:390,height:844});
    await page.goto(`${base}/tests/browser/v129-trial-test-visual.html?view=profile&${query}`,{waitUntil:'domcontentloaded'});
    await page.locator('.c360-rewards-card').waitFor();
    await assertHealthy(page,pageErrors,'v129Metrics');
    if(query==='no_expiry=1')assert.match(await page.locator('.c360-points-expiry').innerText(),/No points are currently scheduled/i);
    if(query==='no_programme=1')assert.match(await page.locator('.c360-rewards-card').innerText(),/not set up yet/i);
    if(query==='role=readonly')assert.match(await page.locator('.c360-rewards-card').innerText(),/read only/i);
    await page.close();
  }
  process.stdout.write(`V141 browser acceptance PASS\nEvidence: ${evidence}\n`);
}finally{
  await browser.close();
}
