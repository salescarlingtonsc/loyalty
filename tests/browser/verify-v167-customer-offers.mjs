import assert from 'node:assert/strict';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const browser=await chromium.launch({
  headless:true,
  ...(process.env.PLAYWRIGHT_EXECUTABLE_PATH?{executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH}:{})
});

const offer={
  id:'11111111-1111-4111-8111-111111111111',
  version_id:'11111111-1111-4111-8111-111111111111:2026-08-05T00:00:00Z',
  name:'Weekday recovery treat',
  ends_at:new Date(Date.now()+48*60*60*1000).toISOString(),
  business:{name:'Spa Glow Orchard',slug:'spa-glow'}
};

for(const viewport of [{width:390,height:844},{width:430,height:932},{width:1440,height:1000}]){
  const page=await browser.newPage({viewport});
  await page.goto(process.env.V167_APP_URL||'http://127.0.0.1:4173/index.html',{waitUntil:'domcontentloaded'});
  await page.evaluate(item=>{
    localStorage.removeItem('peekaa.customer.offers.seen.v1');
    root.innerHTML=`<div class="wallet-shell customer-shell"><main class="wallet-inner">${customerHomeOffersMarkupV167({status:'ready',items:[item]})}</main></div>`;
    wireCustomerHomeOffersV167(()=>{});
  },offer);
  assert.equal(await page.getByRole('heading',{name:'Offers for you'}).count(),1);
  assert.equal(await page.getByText('Ends soon',{exact:true}).count(),1);
  assert.equal(await page.getByText('New',{exact:true}).count(),1);
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=document.documentElement.clientWidth),true);
  await page.screenshot({path:`/tmp/v167-phase2-offers-${viewport.width}.png`,fullPage:true});
  await page.locator('[data-home-offer]').click();
  assert.match(page.url(),/#\/wallet\/spa-glow$/);
  assert.deepEqual(await page.evaluate(()=>JSON.parse(localStorage.getItem('peekaa.customer.offers.seen.v1'))),[offer.version_id]);
  await page.close();
}

const states=await browser.newPage({viewport:{width:390,height:844}});
await states.goto(process.env.V167_APP_URL||'http://127.0.0.1:4173/index.html',{waitUntil:'domcontentloaded'});
await states.evaluate(()=>{root.innerHTML=customerHomeOffersMarkupV167({status:'ready',items:[]})});
assert.equal(await states.getByText('No offers right now. New offers from your businesses appear here first.',{exact:true}).count(),1);
await states.evaluate(()=>{root.innerHTML=customerHomeOffersMarkupV167({status:'error',items:[]})});
assert.equal(await states.getByText('Offers couldn’t load.',{exact:true}).count(),1);
assert.equal(await states.getByRole('button',{name:'Try again'}).count(),1);
await states.evaluate(item=>{
  root.innerHTML='<div class="wallet-shell customer-shell"><main class="wallet-inner"><div id="walletBody"></div></main></div>';
  renderActionableWalletHome({cards:[]},{offersState:{status:'ready',items:[item]},legacyCards:[],pendingRedemption:null});
},offer);
const routedHomeText=await states.locator('body').innerText();
assert.equal(await states.getByRole('heading',{name:'Offers for you'}).count(),1,routedHomeText);
assert.equal(await states.getByRole('heading',{name:'Scan a loyalty QR'}).count(),1);
assert.equal(await states.getByText('Weekday recovery treat',{exact:true}).count(),1);
assert.equal(await states.evaluate(()=>document.documentElement.scrollWidth<=document.documentElement.clientWidth),true);
await browser.close();
process.stdout.write('V167 Phase 2 customer offers browser acceptance PASS (390, 430, 1440)\n');
