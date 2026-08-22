import {writeFile} from 'node:fs/promises';
import {assertFixtureMatchesTree} from '../../scripts/quality/fixture-cross-tree-guard.mjs';

const base=process.env.V104_FIXTURE_URL||'http://127.0.0.1:4173/tests/browser/v104-promotions-visual.html';
const evidence=new URL('../../docs/qa/evidence/',import.meta.url);
const FIXTURE_FILE=new URL('./v104-promotions-visual.html',import.meta.url);

/* CROSS-TREE CAPTURE GUARD (nestly_v448): runs BEFORE the playwright import below is even
   touched, so a mismatch aborts fast with no browser driver required. See
   scripts/quality/fixture-cross-tree-guard.mjs for why this exists (REG-009). */
await assertFixtureMatchesTree({servedUrl:base,localFixtureUrl:FIXTURE_FILE,label:'v104'});

const playwrightModule=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const {chromium}=playwrightModule.chromium?playwrightModule:playwrightModule.default;
const cases={
  desktop1440:{width:1440,height:1000,query:'?openModal=1',screenshot:'v104-promotions-desktop-1440.png'},
  mobile390:{width:390,height:844,query:'?openTerms=0',screenshot:'v104-promotions-mobile-390.png'},
  mobile412:{width:412,height:915,query:'?openTerms=1',screenshot:'v104-promotions-mobile-412.png'}
};
const browser=await chromium.launch({
  headless:true,
  ...(process.env.PLAYWRIGHT_EXECUTABLE_PATH?{executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH}:{}),
});
const metrics={};
try{
  for(const [name,item] of Object.entries(cases)){
    const page=await browser.newPage({viewport:{width:item.width,height:item.height},deviceScaleFactor:1});
    await page.goto(base+item.query,{waitUntil:'networkidle'});
    await page.waitForSelector('.customer-promotion-card');
    await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
    metrics[name]=await page.evaluate(()=>window.v104AcceptanceMetrics());
    await page.screenshot({path:new URL(item.screenshot,evidence).pathname,fullPage:true});
    await page.close();
  }
  await writeFile(new URL('v104-promotions-production-render-metrics.json',evidence),JSON.stringify(metrics,null,2)+'\n');
  process.stdout.write(JSON.stringify({status:'PASS',sourceHash:metrics.desktop1440.sourceHash},null,2)+'\n');
}finally{await browser.close()}
