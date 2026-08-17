import {mkdir,writeFile} from 'node:fs/promises';

const playwrightModule=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const {chromium}=playwrightModule.chromium?playwrightModule:playwrightModule.default;
const base=process.env.V142_FIXTURE_URL||'http://127.0.0.1:4173/tests/browser/v142-connect-paynow-visual.html';
const evidence=new URL('../../docs/qa/evidence/v142-connect-paynow-pos/',import.meta.url);
await mkdir(evidence,{recursive:true});
const browser=await chromium.launch({headless:true,...(process.env.PLAYWRIGHT_EXECUTABLE_PATH?{executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH}:{})});
const metrics={};
try{
  for(const [name,viewport] of Object.entries({desktop:{width:1440,height:1000},mobile390:{width:390,height:844}})){
    const page=await browser.newPage({viewport,deviceScaleFactor:1});
    await page.goto(base,{waitUntil:'networkidle'});
    /* tillPage renders the phone step before its permission/catalogue reads settle, then
       redraws it once. Wait for that production initialization so automation does not
       type into the short-lived first input. */
    await page.waitForTimeout(500);
    for(const digit of '81863833')await page.locator(`[data-k="${digit}"]`).click();
    await page.getByRole('button',{name:'Next'}).click();
    await page.getByRole('button',{name:/Harbour Lunch Set/}).waitFor();
    await page.getByRole('button',{name:/Harbour Lunch Set/}).click();
    /* V373: the tender and the confirm button live on the review stage now — one tap after the
       item, exactly as a cashier reaches them. */
    await page.getByRole('button',{name:/Review sale/}).click();
    await page.getByRole('button',{name:'PayNow QR'}).click();
    await page.getByRole('button',{name:/Record sale · SGD 10\.00/}).waitFor();
    await page.getByRole('button',{name:/Record sale · SGD 10\.00/}).click();
    await page.getByRole('heading',{name:'PayNow · SGD 10.00'}).waitFor();
    const before=await page.evaluate(()=>window.v142Metrics());
    await page.locator('#posReceiptV142').waitFor({timeout:6000});
    const print=page.getByRole('button',{name:'Print receipt'});
    await print.click();
    const after=await page.evaluate(()=>window.v142Metrics());
    metrics[name]={before,after};
    await page.screenshot({path:new URL(`${name}.png`,evidence).pathname,fullPage:true});
    await page.close();
  }
  await writeFile(new URL('metrics.json',evidence),JSON.stringify(metrics,null,2)+'\n');
  process.stdout.write(JSON.stringify({status:'PASS',sourceHash:metrics.desktop.after.sourceHash},null,2)+'\n');
}finally{await browser.close()}
