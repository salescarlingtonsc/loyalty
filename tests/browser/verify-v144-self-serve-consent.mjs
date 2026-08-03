import assert from 'node:assert/strict';
import {mkdir} from 'node:fs/promises';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const base=(process.env.V144_APP_URL||'http://127.0.0.1:4180').replace(/\/$/,'');
const evidenceDir=new URL('../../docs/qa/evidence/v144-self-serve-consent-browser/',import.meta.url);
await mkdir(evidenceDir,{recursive:true});

const browser=await chromium.launch({headless:true,...(process.env.PLAYWRIGHT_EXECUTABLE_PATH
  ?{executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH}:{})});
try{
  for(const viewport of [{name:'desktop-1440',width:1440,height:1000},{name:'mobile-390',width:390,height:844}]){
    const page=await browser.newPage({viewport:{width:viewport.width,height:viewport.height},deviceScaleFactor:1});
    for(const documentName of ['terms','privacy']){
      await page.goto(`${base}/${documentName}.html?return=business-signup`,{waitUntil:'networkidle'});
      const back=page.locator('.return-to-signup');
      assert.equal(await back.count(),1,`${documentName} must expose one return action`);
      assert.equal(await back.getAttribute('href'),'/business?signup=1');
      assert.equal((await back.textContent()).trim(),'← Back to owner account creation');
      const box=await back.boundingBox();
      assert.ok(box&&box.height>=44,`${documentName} return target must be at least 44px`);
      assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth),viewport.width,
        `${documentName} must not create outer horizontal overflow at ${viewport.width}px`);
      if(documentName==='terms'){
        const body=await page.locator('body').innerText();
        assert.match(body,/subscription fees are non-refundable once payment is completed/i);
        assert.match(body,/does not limit any right or remedy that cannot lawfully be excluded/i);
        assert.doesNotMatch(body,/request a refund within 30 days|money-back request window/i);
      }
      await page.screenshot({
        path:new URL(`${documentName}-${viewport.name}.png`,evidenceDir).pathname,
        fullPage:true
      });
    }
    await page.close();
  }

  const page=await browser.newPage({viewport:{width:390,height:844},deviceScaleFactor:1});
  await page.goto(`${base}/terms.html?return=business-signup`,{waitUntil:'networkidle'});
  await page.locator('.return-to-signup').click();
  await page.waitForLoadState('domcontentloaded');
  const destination=new URL(page.url());
  assert.equal(destination.pathname,'/business');
  assert.equal(destination.search,'?signup=1');
  await page.close();

  console.log(JSON.stringify({
    status:'PASS',
    evidenceDir:decodeURIComponent(evidenceDir.pathname),
    viewports:['1440px','390px'],
    pages:['Terms','Privacy']
  },null,2));
}finally{
  await browser.close();
}
