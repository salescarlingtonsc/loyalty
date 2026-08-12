import assert from 'node:assert/strict';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const browser=await chromium.launch({
  headless:true,
  ...(process.env.PLAYWRIGHT_EXECUTABLE_PATH?{executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH}:{})
});
const appUrl=process.env.V167_APP_URL||'http://127.0.0.1:4173/index.html';
const serviceId='11111111-1111-4111-8111-111111111111';

for(const viewport of [{width:390,height:844},{width:430,height:932},{width:768,height:1024},{width:1440,height:1000}]){
  const page=await browser.newPage({viewport});
  await page.route('**/functions/v1/public-booking**',route=>route.fulfill({
    status:200,contentType:'application/json',body:JSON.stringify({
      name:'Spa Glow Orchard',slug:'spa-glow',currency:'SGD',brand_color:'#C24135',
      uses_tables:false,booking_auto_confirm:false,turnstile_site_key:'fixture-site-key',
      services:[{id:serviceId,name:'Signature Facial',duration_min:60,price_cents:8800}]
    })
  }));
  await page.goto(appUrl,{waitUntil:'domcontentloaded'});
  await page.evaluate(async service=>{
    S.user={id:'22222222-2222-4222-8222-222222222222',phone:'+6581234567',email:'mei@example.test',user_metadata:{full_name:'Mei Tan'}};
    sb.rpc=async name=>{
      if(name==='get_my_personas')return {data:{customer:[{business_slug:'spa-glow',business_name:'Spa Glow Orchard'}]},error:null};
      if(name==='customer_get_profile')return {data:{profile:{full_name:'Mei Tan'}},error:null};
      return {data:null,error:null};
    };
    customerRepeatBookingPreferencesV167.set(`spa-glow:${service}`,{staffName:'Jamie Tan'});
    history.replaceState(null,'',`${location.pathname}#/b/spa-glow?repeat_service=${service}`);
    await renderPortal('spa-glow');
  },serviceId);
  await page.getByRole('heading',{name:'Pick a date & time'}).waitFor();
  assert.equal(await page.getByText(/Booking as Mei Tan · \+65 •••• 4567/).count(),1);
  assert.equal(await page.getByRole('button',{name:'Edit booking details'}).count(),1);
  await page.getByRole('button',{name:'Back'}).click();
  assert.equal(await page.locator('#teamName').inputValue(),'Jamie Tan');
  assert.equal(await page.getByRole('button',{name:/Someone specific/}).getAttribute('aria-pressed'),'true');
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=document.documentElement.clientWidth),true);
  await page.screenshot({path:`/tmp/v167-phase3-booking-${viewport.width}.png`,fullPage:true});
  await page.close();
}

const fallback=await browser.newPage({viewport:{width:390,height:844}});
await fallback.goto(appUrl,{waitUntil:'domcontentloaded'});
await fallback.evaluate(()=>{
  Object.defineProperty(navigator,'mediaDevices',{configurable:true,value:undefined});
  openCustomerJoinScanner();
});
/* v281: the camera starts automatically when the sheet opens; with mediaDevices undefined the
   fallback must reveal itself without any tap. */
assert.equal(await fallback.getByText('Camera is unavailable in this browser. Choose a QR image or paste the QR link.',{exact:true}).count(),1);
assert.equal(await fallback.locator('#customerJoinScannerFallback').evaluate(node=>node.hidden),false);
assert.equal(await fallback.locator('#customerJoinScannerPaste').evaluate(node=>node.open),true);
assert.equal(await fallback.locator('#customerJoinScannerImage').evaluate(node=>node===document.activeElement),true);
assert.equal(await fallback.locator('#customerJoinScannerImage').getAttribute('capture'),null);
assert.equal(await fallback.evaluate(()=>document.documentElement.scrollWidth<=document.documentElement.clientWidth),true);
await fallback.screenshot({path:'/tmp/v167-phase3-camera-fallback-390.png',fullPage:true});

await browser.close();
process.stdout.write('V167 Phase 3 booking and camera browser acceptance PASS (390, 430, 768, 1440)\n');
