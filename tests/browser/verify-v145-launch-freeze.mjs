import assert from 'node:assert/strict';
import {mkdir} from 'node:fs/promises';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const base=process.env.V145_FIXTURE_URL||'http://127.0.0.1:4173/tests/browser/v145-launch-freeze-visual.html';
const evidenceDir=new URL('../../docs/qa/evidence/v145-launch-freeze-browser/',import.meta.url);
await mkdir(evidenceDir,{recursive:true});

const browser=await chromium.launch({headless:true,...(process.env.PLAYWRIGHT_EXECUTABLE_PATH?{executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH}:{})});
try{
  let metrics;
  for(const viewport of [{name:'desktop-1440',width:1440,height:1000},{name:'mobile-390',width:390,height:844}]){
    const page=await browser.newPage({viewport:{width:viewport.width,height:viewport.height},deviceScaleFactor:1});
    const browserErrors=[];
    page.on('console',message=>{if(message.type()==='error')browserErrors.push(message.text())});
    page.on('pageerror',error=>browserErrors.push(error.message));
    await page.goto(`${base}?view=dashboard`,{waitUntil:'networkidle'});
    await page.waitForSelector('#kpis .kpi',{state:'attached'});
    await page.locator('.performance-panel').evaluate(element=>{element.open=true});
    metrics=await page.evaluate(()=>window.v145Metrics());
    assert.equal(metrics.overlay,false,`${viewport.name} dashboard has no framework error overlay`);
    assert.equal(metrics.width,metrics.scrollWidth,`${viewport.name} dashboard has no outer overflow`);
    assert.deepEqual(metrics.errors,[]);assert.deepEqual(browserErrors,[]);
    const kpis=metrics.kpis.map(value=>value.replace(/\s+/g,' ').trim().toLowerCase());
    assert.ok(kpis.some(value=>value.startsWith('valid visits · → · 1 ·')&&value.includes('valid original visits · orchard')),JSON.stringify(kpis));
    assert.ok(kpis.some(value=>value.startsWith('revenue · → · sgd 10.00 ·')&&value.includes('net sales · orchard')),JSON.stringify(kpis));
    assert.ok(kpis.some(value=>value.startsWith('new customer members · → · 4 ·')),JSON.stringify(kpis));
    assert.ok(kpis.some(value=>value.startsWith('inactive customers · → · 3 ·')),JSON.stringify(kpis));
    assert.ok(kpis.every(value=>!value.includes('gross points earned')&&!value.includes('credit liability')),
      'the simplified dashboard does not restore mixed-scope loyalty or liability KPIs');
    const revenueChart=metrics.chartConfigs.find(chart=>chart.id==='c2');
    assert.ok(revenueChart,'dashboard revenue chart renders');
    assert.equal(revenueChart.config.data.labels.length,30,'dashboard returns every date in the selected 30-day scope');
    assert.ok(revenueChart.config.data.datasets[0].data.includes(0),'zero-revenue dates remain visible');
    assert.doesNotMatch(metrics.text,/coming soon|placeholder|sample metric|demo data/i);
    assert.ok(metrics.visibleButtonHeights.every(height=>height>=44),`${viewport.name} visible dashboard buttons retain 44px targets`);
    await page.screenshot({path:new URL(`dashboard-${viewport.name}.png`,evidenceDir).pathname,fullPage:true});
    await page.close();
  }

  const gated=await browser.newPage({viewport:{width:390,height:844},deviceScaleFactor:1});
  const gatedErrors=[];gated.on('console',message=>{if(message.type()==='error')gatedErrors.push(message.text())});gated.on('pageerror',error=>gatedErrors.push(error.message));
  await gated.goto(`${base}?view=dashboard&clientsOff=1&loyaltyOff=1`,{waitUntil:'networkidle'});
  await gated.waitForSelector('#kpis .kpi',{state:'attached'});
  metrics=await gated.evaluate(()=>window.v145Metrics());
  assert.doesNotMatch(metrics.text,/Gross points earned/i,'disabled Loyalty never renders a plausible Dashboard points value');
  assert.doesNotMatch(metrics.text,/New customer members|Inactive customers|Age groups|Recorded gender/i,
    'disabled Clients hides business-wide customer facts and charts');
  assert.equal(metrics.width,metrics.scrollWidth,'390px gated Dashboard has no outer overflow');
  assert.deepEqual(metrics.errors,[]);assert.deepEqual(gatedErrors,[]);
  assert.equal(await gated.locator('[data-dashboard-metric="new"],[data-dashboard-metric="inactive"]').count(),0,
    'customer KPI actions are omitted when Clients access is unavailable');
  await gated.screenshot({path:new URL('dashboard-gated-mobile-390.png',evidenceDir).pathname,fullPage:true});
  await gated.close();

  const loyaltyGated=await browser.newPage({viewport:{width:390,height:844},deviceScaleFactor:1});
  const loyaltyGatedErrors=[];loyaltyGated.on('console',message=>{if(message.type()==='error')loyaltyGatedErrors.push(message.text())});loyaltyGated.on('pageerror',error=>loyaltyGatedErrors.push(error.message));
  await loyaltyGated.goto(`${base}?view=dashboard&loyaltyOff=1`,{waitUntil:'networkidle'});
  await loyaltyGated.waitForSelector('#kpis .kpi');
  metrics=await loyaltyGated.evaluate(()=>window.v145Metrics());
  assert.match(metrics.text,/New customer members/i,'Clients facts remain visible when only Loyalty is unavailable');
  assert.doesNotMatch(metrics.text,/Gross points earned|Credit liability/,'Loyalty-off Dashboard does not invent a points or liability value');
  assert.equal(metrics.width,metrics.scrollWidth,'390px clients-on/Loyalty-off Dashboard has no outer overflow');
  assert.deepEqual(metrics.errors,[]);assert.deepEqual(loyaltyGatedErrors,[]);
  await loyaltyGated.screenshot({path:new URL('dashboard-loyalty-off-mobile-390.png',evidenceDir).pathname,fullPage:true});
  await loyaltyGated.close();

  const branchCredit=await browser.newPage({viewport:{width:390,height:844},deviceScaleFactor:1});
  const branchCreditErrors=[];branchCredit.on('console',message=>{if(message.type()==='error')branchCreditErrors.push(message.text())});branchCredit.on('pageerror',error=>branchCreditErrors.push(error.message));
  await branchCredit.goto(`${base}?view=dashboard&creditOff=1&branchLimited=1`,{waitUntil:'networkidle'});
  await branchCredit.waitForSelector('#kpis .kpi',{state:'attached'});
  metrics=await branchCredit.evaluate(()=>window.v145Metrics());
  assert.equal(await branchCredit.locator('[data-dashboard-metric="credit"]').count(),0,
    'the simplified Dashboard never renders the removed business-wide credit KPI');
  assert.doesNotMatch(metrics.text,/Credit liability\s+→\s+SGD 0\.00/i,
    'unavailable business-wide credit never becomes a plausible zero');
  assert.equal(metrics.width,metrics.scrollWidth,'390px branch-limited Dashboard has no outer overflow');
  assert.deepEqual(metrics.errors,[]);assert.deepEqual(branchCreditErrors,[]);
  await branchCredit.screenshot({path:new URL('dashboard-credit-unavailable-mobile-390.png',evidenceDir).pathname,fullPage:true});
  await branchCredit.close();

  for(const viewport of [{name:'desktop-1440',width:1440,height:1000},{name:'mobile-390',width:390,height:844}]){
    const reports=await browser.newPage({viewport:{width:viewport.width,height:viewport.height},deviceScaleFactor:1});
    const reportErrors=[];reports.on('console',message=>{if(message.type()==='error')reportErrors.push(message.text())});reports.on('pageerror',error=>reportErrors.push(error.message));
    await reports.goto(`${base}?view=reports`,{waitUntil:'networkidle'});await reports.waitForSelector('#moneyAnswer');
    metrics=await reports.evaluate(()=>window.v145Metrics());
    assert.equal(metrics.rpcCalls.filter(call=>call.name==='get_reports_summary').length,0,`${viewport.name} Reports stays lazy before an answer is opened`);
    await reports.locator('#moneyAnswer').click();
    await reports.waitForFunction(()=>document.querySelector('#rbody')?.innerText.includes('Net total'));
    metrics=await reports.evaluate(()=>window.v145Metrics());
    assert.equal(metrics.rpcCalls.filter(call=>call.name==='get_reports_summary').length,1,`${viewport.name} one question click performs one report request`);
    assert.match(metrics.text,/Net total\s+SGD 30\.00/);
    assert.match(metrics.text,/Revenue reversed\s+−SGD 10\.00/);
    assert.match(metrics.text,/Net revenue from immutable rows\s+SGD 20\.00/);
    assert.match(metrics.text,/Customer credit outstanding\s+SGD 5\.00/,
      'complete business authority renders the current signed credit liability');
    assert.match(metrics.text,/Non-revenue sale amounts recorded: SGD 25\.00 gift card\. These are sale ledger amounts, not verified payment or cash-collection totals\./);
    assert.equal(metrics.width,metrics.scrollWidth,`${viewport.name} Reports has no outer overflow`);
    assert.ok(metrics.visibleButtonHeights.every(height=>height>=44),`${viewport.name} Reports controls retain 44px targets`);
    assert.deepEqual(metrics.errors,[]);assert.deepEqual(reportErrors,[]);
    await reports.screenshot({path:new URL(`reports-money-${viewport.name}.png`,evidenceDir).pathname,fullPage:true});
    await reports.close();
  }

  const reportsCredit=await browser.newPage({viewport:{width:390,height:844},deviceScaleFactor:1});
  const reportsCreditErrors=[];reportsCredit.on('console',message=>{if(message.type()==='error')reportsCreditErrors.push(message.text())});reportsCredit.on('pageerror',error=>reportsCreditErrors.push(error.message));
  await reportsCredit.goto(`${base}?view=reports&creditOff=1`,{waitUntil:'networkidle'});await reportsCredit.waitForSelector('#moneyAnswer');
  await reportsCredit.locator('#moneyAnswer').click();
  await reportsCredit.waitForFunction(()=>document.querySelector('#rbody')?.innerText.includes('Net total'));
  metrics=await reportsCredit.evaluate(()=>window.v145Metrics());
  assert.match(metrics.text,/Customer credit outstanding\s+Unavailable/i,
    'Reports explicitly labels business-wide credit unavailable when complete authority is absent');
  assert.match(metrics.text,/No zero is inferred/i);
  assert.doesNotMatch(metrics.text,/Customer credit outstanding\s+SGD 0\.00/i);
  assert.equal(metrics.width,metrics.scrollWidth,'390px unavailable-credit Reports has no outer overflow');
  assert.deepEqual(metrics.errors,[]);assert.deepEqual(reportsCreditErrors,[]);
  await reportsCredit.screenshot({path:new URL('reports-credit-unavailable-mobile-390.png',evidenceDir).pathname,fullPage:true});
  await reportsCredit.close();

  const safety=await browser.newPage({viewport:{width:390,height:844},deviceScaleFactor:1});
  const safetyErrors=[];safety.on('console',message=>{if(message.type()==='error')safetyErrors.push(message.text())});safety.on('pageerror',error=>safetyErrors.push(error.message));
  await safety.goto(`${base}?view=safety`,{waitUntil:'networkidle'});await safety.waitForSelector('.studio-emg-banner');
  metrics=await safety.evaluate(()=>window.v145Metrics());
  assert.match(metrics.text,/By Peekaa launch safety\./,
    'migration-created safety pauses are not misattributed to a business owner');
  assert.match(metrics.text,/Owner action remains attributed\. By owner-v145\./,
    'real owner actions retain their audited actor identity');
  assert.equal(metrics.width,metrics.scrollWidth,'390px launch-safety evidence has no outer overflow');
  assert.deepEqual(metrics.errors,[]);assert.deepEqual(safetyErrors,[]);
  await safety.screenshot({path:new URL('studio-launch-safety-attribution-mobile-390.png',evidenceDir).pathname,fullPage:true});
  await safety.close();

  for(const viewport of [{name:'desktop-1440',width:1440,height:1000},{name:'mobile-390',width:390,height:844}]){
    const daily=await browser.newPage({viewport:{width:viewport.width,height:viewport.height},deviceScaleFactor:1});
    const dailyErrors=[];daily.on('console',message=>{if(message.type()==='error')dailyErrors.push(message.text())});daily.on('pageerror',error=>dailyErrors.push(error.message));
    await daily.goto(`${base}?view=daily`,{waitUntil:'networkidle'});await daily.waitForSelector('#drBody .kpis');
    metrics=await daily.evaluate(()=>window.v145Metrics());
    assert.match(metrics.text,/Revenue\s+SGD -5\.00/i,'Daily report uses the authoritative signed revenue summary');
    assert.match(metrics.text,/Visits\s+0/i,'Daily report excludes fully reversed visits');
    assert.match(metrics.text,/Customer records with valid visits\s+0/i);
    assert.match(metrics.text,/Gift-card issuance amount recorded\s+SGD 25\.00/i,'non-revenue gift-card issuance stays visibly separate');
    assert.ok(metrics.chartConfigs.find(chart=>chart.id==='drC2')?.config.data.datasets[0].data.includes(-5),'signed revenue chart retains negative adjustments');
    assert.equal(metrics.dataCalls.filter(call=>call.table==='sales').length,1,'one complete sales reader supplies Daily detail');
    assert.equal(await daily.locator('#drBody .cui-table-wrap').count(),1,'Daily wide detail is contained in an internal scroll region');
    assert.equal(metrics.width,metrics.scrollWidth,`${viewport.name} Daily report has no outer overflow`);
    assert.ok(metrics.visibleButtonHeights.every(height=>height>=44),`${viewport.name} Daily report controls retain 44px targets`);
    assert.deepEqual(metrics.errors,[]);assert.deepEqual(dailyErrors,[]);
    await daily.screenshot({path:new URL(`daily-${viewport.name}.png`,evidenceDir).pathname,fullPage:true});
    await daily.close();
  }

  for(const viewport of [{name:'desktop-1440',width:1440,height:1000},{name:'mobile-390',width:390,height:844}]){
    const client=await browser.newPage({viewport:{width:viewport.width,height:viewport.height},deviceScaleFactor:1});
    const clientErrors=[];client.on('console',message=>{if(message.type()==='error')clientErrors.push(message.text())});client.on('pageerror',error=>clientErrors.push(error.message));
    await client.goto(`${base}?view=client`,{waitUntil:'networkidle'});await client.waitForSelector('#c360-loyalty');
    metrics=await client.evaluate(()=>window.v145Metrics());
    assert.match(metrics.text,/Staff view scope/);
    assert.match(metrics.text,/Visible sales total\s+SGD 30\.00/i);
    assert.match(metrics.text,/Business-wide points\s+300/i);
    assert.match(metrics.text,/Business-wide spendable credit\s+SGD 5\.00/i);
    assert.match(metrics.text,/SGD 10\.00 credit is ready now/);
    assert.equal(metrics.rpcCalls.filter(call=>call.name==='staff_get_customer_actionable_loyalty_v145').length,1,'Customer 360 reads one authoritative loyalty projection');
    for(const forbidden of ['client_points_balance','client_credit_balance','points_batches','loyalty_programs','loyalty_rewards']){
      assert.equal(metrics.dataCalls.filter(call=>call.table===forbidden).length,0,`Customer 360 does not reconstruct ${forbidden} in the browser`);
    }
    assert.equal(metrics.width,metrics.scrollWidth,`${viewport.name} Customer 360 has no outer overflow`);
    assert.ok(metrics.visibleButtonHeights.every(height=>height>=44),`${viewport.name} Customer 360 controls retain 44px targets`);
    assert.deepEqual(metrics.errors,[]);assert.deepEqual(clientErrors,[]);assert.deepEqual(metrics.handledErrors,[]);
    await client.screenshot({path:new URL(`customer-360-${viewport.name}.png`,evidenceDir).pathname,fullPage:true});
    await client.close();
  }

  const clientFacet=await browser.newPage({viewport:{width:390,height:844},deviceScaleFactor:1});
  const clientFacetErrors=[];clientFacet.on('console',message=>{if(message.type()==='error')clientFacetErrors.push(message.text())});clientFacet.on('pageerror',error=>clientFacetErrors.push(error.message));
  await clientFacet.goto(`${base}?view=client&facetError=1`,{waitUntil:'networkidle'});await clientFacet.waitForSelector('#c360-feedback');
  metrics=await clientFacet.evaluate(()=>window.v145Metrics());
  assert.match(metrics.text,/Feedback is temporarily unavailable\. The rest of this customer profile remains current\./);
  assert.match(metrics.text,/Business-wide points\s+300/i,'optional feedback failure does not hide authoritative loyalty facts');
  assert.equal(metrics.width,metrics.scrollWidth,'390px Customer 360 optional-facet error has no outer overflow');
  assert.deepEqual(metrics.errors,[]);assert.deepEqual(clientFacetErrors,[]);
  await clientFacet.screenshot({path:new URL('customer-360-feedback-retry-mobile-390.png',evidenceDir).pathname,fullPage:true});
  await clientFacet.close();

  for(const viewport of [{name:'desktop-1440',width:1440,height:1000},{name:'mobile-390',width:390,height:844}]){
    const expenses=await browser.newPage({viewport:{width:viewport.width,height:viewport.height},deviceScaleFactor:1});
    const expenseErrors=[];expenses.on('console',message=>{if(message.type()==='error')expenseErrors.push(message.text())});expenses.on('pageerror',error=>expenseErrors.push(error.message));
    await expenses.goto(`${base}?view=expenses`,{waitUntil:'networkidle'});await expenses.waitForSelector('#exList .cui-table-wrap');
    metrics=await expenses.evaluate(()=>window.v145Metrics());
    assert.equal((metrics.text.match(/Read-only expenses access/g)||[]).length,1,'read-only notice renders once');
    assert.match(metrics.text,/Receipt rolls\s+SGD 12\.00\s+active\s+View only/);
    assert.equal(await expenses.getByRole('button',{name:'Void',exact:true}).count(),0,'read-only Expenses exposes no write action');
    assert.equal(metrics.width,metrics.scrollWidth,`${viewport.name} Expenses has no outer overflow`);
    assert.ok(metrics.visibleButtonHeights.every(height=>height>=44),`${viewport.name} Expenses controls retain 44px targets`);
    assert.deepEqual(metrics.errors,[]);assert.deepEqual(expenseErrors,[]);
    await expenses.screenshot({path:new URL(`expenses-read-only-${viewport.name}.png`,evidenceDir).pathname,fullPage:true});
    await expenses.close();
  }

  for(const viewport of [{name:'desktop-1440',width:1440,height:1000},{name:'mobile-390',width:390,height:844}]){
    const inbox=await browser.newPage({viewport:{width:viewport.width,height:viewport.height},deviceScaleFactor:1});
    const inboxErrors=[];inbox.on('console',message=>{if(message.type()==='error')inboxErrors.push(message.text())});inbox.on('pageerror',error=>inboxErrors.push(error.message));
    await inbox.goto(`${base}?view=inbox`,{waitUntil:'networkidle'});await inbox.waitForSelector('.customerInboxPreference');
    metrics=await inbox.evaluate(()=>window.v145Metrics());
    assert.match(metrics.text,/Customer-safe updates from this business/);
    assert.match(metrics.text,/Choose which reminders this business may place in your inbox\. Nothing changes until you select Save\./);
    assert.doesNotMatch(metrics.text,/Quiet hours|Push notification|Offers by email/,'launch inbox shows only controls that affect the current in-app channel');
    if(viewport.name==='mobile-390'){
      await inbox.locator('.customerInboxPreference').first().check();
      await inbox.locator('.customerInboxPreferenceSave').first().click();
      await inbox.waitForFunction(()=>document.querySelector('#customerInboxStatus')?.textContent.includes('Inbox reminder saved.'));
      metrics=await inbox.evaluate(()=>window.v145Metrics());
      const write=metrics.rpcCalls.find(call=>call.name==='customer_set_in_app_inbox_preferences');
      assert.ok(write,'inbox preference save calls the existing write path');
      assert.equal(write.args.p_quiet_hours_timezone,null);assert.equal(write.args.p_quiet_hours_start,null);assert.equal(write.args.p_quiet_hours_end,null);
    }
    assert.equal(metrics.width,metrics.scrollWidth,`${viewport.name} Customer inbox has no outer overflow`);
    assert.ok(metrics.visibleButtonHeights.every(height=>height>=44),`${viewport.name} Customer inbox controls retain 44px targets`);
    assert.deepEqual(metrics.errors,[]);assert.deepEqual(inboxErrors,[]);
    await inbox.screenshot({path:new URL(`customer-inbox-${viewport.name}.png`,evidenceDir).pathname,fullPage:true});
    await inbox.close();
  }

  const pnl=await browser.newPage({viewport:{width:1440,height:1000},deviceScaleFactor:1});
  const pnlErrors=[];pnl.on('console',message=>{if(message.type()==='error')pnlErrors.push(message.text())});pnl.on('pageerror',error=>pnlErrors.push(error.message));
  await pnl.goto(`${base}?view=pnl`,{waitUntil:'networkidle'});await pnl.waitForSelector('#plBody .kpis');
  metrics=await pnl.evaluate(()=>window.v145Metrics());
  assert.equal(metrics.width,metrics.scrollWidth,'desktop P&L has no outer overflow');
  assert.deepEqual(metrics.errors,[]);assert.deepEqual(pnlErrors,[]);
  assert.ok(metrics.kpis.some(value=>value.toLowerCase().includes('cash-basis revenue less all business expenses')&&value.includes('+SGD 65.00')),'P&L displays the server-authoritative net value');
  assert.match(metrics.text,/Accrual revenue vs expenses by month/);
  assert.equal(metrics.chartConfigs.find(chart=>chart.id==='plC1')?.config.data.labels.length,2,'category chart uses the complete server aggregate');
  await pnl.screenshot({path:new URL('pnl-desktop-1440.png',evidenceDir).pathname,fullPage:true});
  await pnl.close();

  const retry=await browser.newPage({viewport:{width:390,height:844},deviceScaleFactor:1});
  const retryErrors=[];retry.on('console',message=>{if(message.type()==='error')retryErrors.push(message.text())});retry.on('pageerror',error=>retryErrors.push(error.message));
  await retry.goto(`${base}?view=pnl&error=1`,{waitUntil:'networkidle'});await retry.waitForSelector('#plRetry');
  assert.match(await retry.locator('#plBody').innerText(),/P&L summary could not be loaded/);
  await retry.locator('#plRetry').click();await retry.waitForSelector('#plBody .kpis');
  metrics=await retry.evaluate(()=>window.v145Metrics());
  assert.equal(metrics.width,metrics.scrollWidth,'390px P&L retry state and success do not overflow');
  assert.ok(metrics.visibleButtonHeights.every(height=>height>=44),'390px P&L actions retain 44px targets');
  assert.deepEqual(metrics.handledErrors,['Synthetic temporary reporting interruption'],'the first interruption is handled once before a successful retry');
  assert.doesNotMatch(metrics.text,/P&L summary could not be loaded/,'successful retry clears the transient error state');
  assert.deepEqual(retryErrors,[],'handled reporting interruption emits no browser exception');
  await retry.screenshot({path:new URL('pnl-retry-success-mobile-390.png',evidenceDir).pathname,fullPage:true});
  await retry.close();

  const empty=await browser.newPage({viewport:{width:390,height:844},deviceScaleFactor:1});
  await empty.goto(`${base}?view=pnl&empty=1`,{waitUntil:'networkidle'});await empty.waitForSelector('#plBody .kpis');
  metrics=await empty.evaluate(()=>window.v145Metrics());
  assert.ok(metrics.kpis.some(value=>value.toLowerCase().includes('cash-basis revenue less all business expenses')&&value.includes('+SGD 0.00')));
  assert.equal(metrics.width,metrics.scrollWidth,'390px empty P&L has no outer overflow');
  assert.deepEqual(metrics.errors,[]);
  await empty.screenshot({path:new URL('pnl-empty-mobile-390.png',evidenceDir).pathname,fullPage:true});
  await empty.close();

  process.stdout.write(JSON.stringify({status:'PASS',evidenceDir:decodeURIComponent(evidenceDir.pathname),viewports:['1440px','390px'],surfaces:['Dashboard','Dashboard gated modules','Dashboard Loyalty-off drill','Dashboard unavailable business credit','Reports lazy money answer','Reports unavailable business credit','Program Studio launch-safety attribution','Daily report','Customer 360 staff projection','Customer 360 optional-facet retry','Expenses read-only','Customer inbox preferences','P&L','P&L retry','P&L empty']},null,2)+'\n');
}finally{
  await browser.close();
}
