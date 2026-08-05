import assert from 'node:assert/strict';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const browser=await chromium.launch({
  headless:true,
  ...(process.env.PLAYWRIGHT_EXECUTABLE_PATH?{executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH}:{})
});
const appUrl=process.env.V167_APP_URL||'http://127.0.0.1:4173/index.html';
const luminance=hex=>{
  const rgb=hex.replace('#','').match(/.{2}/g).map(value=>parseInt(value,16)/255)
    .map(value=>value<=.04045?value/12.92:((value+.055)/1.055)**2.4);
  return .2126*rgb[0]+.7152*rgb[1]+.0722*rgb[2];
};
const contrast=(a,b)=>{const [bright,dark]=[luminance(a),luminance(b)].sort((x,y)=>y-x);return (bright+.05)/(dark+.05)};

for(const colorScheme of ['light','dark']){
  for(const viewport of [{width:390,height:844},{width:430,height:932},{width:768,height:1024},{width:1440,height:1000}]){
    const page=await browser.newPage({viewport,colorScheme});
    await page.route('**/functions/v1/public-booking**',route=>route.fulfill({
      status:200,contentType:'application/json',body:JSON.stringify({
        name:'Spa Glow Orchard',slug:'spa-glow',currency:'SGD',brand_color:'#C24135',
        uses_tables:false,booking_auto_confirm:false,turnstile_site_key:'fixture-site-key',
        services:[{id:'11111111-1111-4111-8111-111111111111',name:'Signature Facial',duration_min:60,price_cents:8800}]
      })
    }));
    await page.goto(appUrl,{waitUntil:'domcontentloaded'});
    await page.evaluate(async()=>{
      history.replaceState(null,'',`${location.pathname}#/b/spa-glow`);
      await renderPortal('spa-glow');
    });
    await page.getByRole('heading',{name:'What would you like?'}).waitFor();
    await page.evaluate(()=>{
      const qr=document.createElement('div');qr.className='redemption-qr';qr.textContent='QR scan surface';
      document.querySelector('#bookingFormCard')?.append(qr);
    });
    const styles=await page.evaluate(()=>{
      const style=selector=>{const node=document.querySelector(selector);return node?getComputedStyle(node):null};
      const surface=style('.customer-surface');
      const body=style('body');
      const card=style('#bookingFormCard');
      const input=style('#pn');
      const qr=style('.redemption-qr');
      const choice=style('.svc');
      const ghost=style('#mfind');
      if(!surface||!body||!card||!input||!qr||!choice||!ghost)return {missing:true,html:document.querySelector('.customer-surface')?.className||'',
        selectors:{surface:!!surface,body:!!body,card:!!card,input:!!input,qr:!!qr,choice:!!choice,ghost:!!ghost}};
      return {surface:surface.backgroundColor,body:body.backgroundColor,card:card.backgroundColor,input:input.backgroundColor,
        ink:card.color,qr:qr.backgroundColor,qrColor:qr.color,choice:choice.backgroundColor,
        choiceColor:choice.color,ghost:ghost.backgroundColor,ghostColor:ghost.color,
        accent:surface.getPropertyValue('--coral').trim(),
        overflow:document.documentElement.scrollWidth<=document.documentElement.clientWidth};
    });
    assert.notEqual(styles.missing,true,`missing themed fixture element: ${styles.html||'unknown'} ${JSON.stringify(styles.selectors||{})}`);
    assert.equal(styles.overflow,true);
    assert.equal(styles.qr,'rgb(255, 255, 255)');
    assert.equal(styles.qrColor,'rgb(23, 22, 26)');
    if(colorScheme==='dark'){
      assert.equal(styles.surface,'rgb(15, 17, 21)');
      assert.equal(styles.body,'rgb(15, 17, 21)');
      assert.equal(styles.card,'rgb(25, 28, 34)');
      assert.equal(styles.input,'rgb(25, 28, 34)');
      assert.equal(styles.ink,'rgb(247, 244, 239)');
      assert.equal(styles.choice,'rgb(25, 28, 34)');
      assert.equal(styles.choiceColor,'rgb(247, 244, 239)');
      assert.equal(styles.ghost,'rgb(25, 28, 34)');
      assert.equal(styles.ghostColor,'rgb(247, 244, 239)');
      assert.ok(contrast(styles.accent,'#191C22')>=4.5,`configured merchant dark accent contrast was ${contrast(styles.accent,'#191C22')}`);
    }else{
      assert.equal(styles.card,'rgb(255, 255, 255)');
    }
    await page.screenshot({path:`/tmp/v167-phase4-${colorScheme}-${viewport.width}.png`,fullPage:true});

    await page.evaluate(()=>renderCustomerShell({active:'home',body:`<section id="darkWalletFixture" class="card">
      <h1>Your Peekaa</h1><p class="muted">Rewards and offers</p>
      <a class="customer-home-offer customer-home-offer--no-media" href="#/wallet/spa-glow"><span class="customer-home-offer-copy"><b>Welcome offer</b></span></a>
      <button class="btn ghost" type="button">View reward</button><div class="redemption-qr">Wallet QR surface</div>
    </section>`}));
    await page.locator('#darkWalletFixture').waitFor();
    const walletStyles=await page.evaluate(()=>{
      const style=selector=>getComputedStyle(document.querySelector(selector));
      return {body:style('body').backgroundColor,shell:style('.customer-shell').backgroundColor,
        card:style('#darkWalletFixture').backgroundColor,nav:style('.customer-primary-nav').backgroundColor,
        offer:style('.customer-home-offer').backgroundColor,ghost:style('#darkWalletFixture .btn.ghost').backgroundColor,
        qr:style('#darkWalletFixture .redemption-qr').backgroundColor,
        logoFilter:style('.customer-shell .brand-logo').filter,
        overflow:document.documentElement.scrollWidth<=document.documentElement.clientWidth};
    });
    assert.equal(walletStyles.overflow,true);
    assert.equal(walletStyles.qr,'rgb(255, 255, 255)');
    if(colorScheme==='dark'){
      for(const key of ['body','shell','card','nav','offer','ghost'])assert.notEqual(walletStyles[key],'rgb(255, 255, 255)',`${key} stayed white`);
      assert.notEqual(walletStyles.logoFilter,'none');
    }else{
      assert.equal(walletStyles.card,'rgb(255, 255, 255)');
      assert.equal(walletStyles.logoFilter,'none');
    }
    await page.screenshot({path:`/tmp/v167-phase4-wallet-${colorScheme}-${viewport.width}.png`,fullPage:true});
    await page.close();
  }
}

const extreme=await browser.newPage({viewport:{width:390,height:844},colorScheme:'dark'});
await extreme.route('**/functions/v1/public-booking**',route=>route.fulfill({
  status:200,contentType:'application/json',body:JSON.stringify({
    name:'Midnight Studio',slug:'midnight',currency:'SGD',brand_color:'#000000',uses_tables:false,
    booking_auto_confirm:false,turnstile_site_key:'fixture-site-key',services:[]
  })
}));
await extreme.goto(appUrl,{waitUntil:'domcontentloaded'});
await extreme.evaluate(async()=>{history.replaceState(null,'',`${location.pathname}#/b/midnight`);await renderPortal('midnight')});
await extreme.getByRole('heading',{name:'Start your booking'}).waitFor();
const extremeAccent=await extreme.locator('.portal.customer-surface').evaluate(node=>getComputedStyle(node).getPropertyValue('--coral').trim());
assert.equal(extremeAccent.toUpperCase(),'#FF8A7E');
assert.ok(contrast(extremeAccent,'#191C22')>=4.5,`extreme dark merchant accent contrast was ${contrast(extremeAccent,'#191C22')}`);
await extreme.screenshot({path:'/tmp/v167-phase4-dark-extreme-brand-390.png',fullPage:true});
await extreme.close();

await browser.close();
process.stdout.write('V167 Phase 4 customer dark-mode acceptance PASS (light/dark; 390, 430, 768, 1440)\n');
