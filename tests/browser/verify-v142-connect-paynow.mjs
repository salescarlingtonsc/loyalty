import {mkdir,writeFile} from 'node:fs/promises';
import {assertFixtureMatchesTree} from '../../scripts/quality/fixture-cross-tree-guard.mjs';

const base=process.env.V142_FIXTURE_URL||'http://127.0.0.1:4173/tests/browser/v142-connect-paynow-visual.html';
const evidence=new URL('../../docs/qa/evidence/v142-connect-paynow-pos/',import.meta.url);
const FIXTURE_FILE=new URL('./v142-connect-paynow-visual.html',import.meta.url);

/* CROSS-TREE CAPTURE GUARD (nestly_v448): runs BEFORE the playwright import below is even
   touched, so a mismatch aborts fast with no browser driver required. See
   scripts/quality/fixture-cross-tree-guard.mjs for why this exists (REG-009). */
await assertFixtureMatchesTree({servedUrl:base,localFixtureUrl:FIXTURE_FILE,label:'v142'});

const playwrightModule=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const {chromium}=playwrightModule.chromium?playwrightModule:playwrightModule.default;
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
    /* V392 (owner, photo 1): the quick grid leads with this customer's own last two services and
       two products, so an item further down the catalogue is no longer a tile. It is reached the
       way a cashier now reaches it — by typing in the search field beside the grid — which also
       makes this capture real evidence that the search works against the whole catalogue. */
    await page.locator('#tillItemSearchV392').fill('Harbour');
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
