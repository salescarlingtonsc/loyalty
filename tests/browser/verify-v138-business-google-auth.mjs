import assert from 'node:assert/strict';
import {mkdir} from 'node:fs/promises';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const base=process.env.V138_AUTH_FIXTURE_URL
  ||'http://127.0.0.1:4173/tests/browser/v130-self-serve-visual.html';
const evidenceDir=new URL('../../docs/qa/evidence/v138-business-google-auth-browser/',import.meta.url);
await mkdir(evidenceDir,{recursive:true});

const browser=await chromium.launch({headless:true,...(process.env.PLAYWRIGHT_EXECUTABLE_PATH
  ?{executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH}:{})});
try{
  const page=await browser.newPage({viewport:{width:390,height:844},deviceScaleFactor:1});
  const consoleErrors=[];
  page.on('console',message=>{if(message.type()==='error')consoleErrors.push(message.text())});

  await page.goto(`${base}?view=signup`,{waitUntil:'networkidle'});
  await page.waitForSelector('#applicationConsent');
  assert.equal(await page.locator('#applicationConsent').count(),1,'signup shows one legal checkbox');
  await page.locator('#businessApplicationGoogle').click();
  assert.match(await page.locator('#businessApplicationError').textContent(),/agree to the Terms of Service and acknowledge the Privacy Policy/i);
  let metrics=await page.evaluate(()=>window.v130Metrics());
  assert.equal(metrics.oauthStarts.length,0,'unchecked signup never leaves for Google');
  assert.equal(metrics.rpcCalls.filter(call=>call.name==='begin_business_google_oauth_signup_v138').length,0);
  await page.locator('#applicationConsent').check();
  await page.locator('#businessApplicationGoogle').click();
  metrics=await page.evaluate(()=>window.v130Metrics());
  const consentCalls=metrics.rpcCalls.filter(call=>call.name==='begin_business_google_oauth_signup_v138');
  assert.equal(consentCalls.length,1,'checked signup records one server consent attempt before Google');
  assert.equal(consentCalls[0].args.p_terms_version,'2026-08-03');
  assert.equal(consentCalls[0].args.p_terms_sha256,'1c7437280e9ba8386b5ef3998a919fefcdeca8e06cc497b31621633ae23dab04');
  assert.equal(consentCalls[0].args.p_privacy_sha256,'8e152d208b271da5a1f71630b17c5c82e8b7bd930c5508da8b4d95597c0a1568');
  assert.equal(metrics.oauthStarts.length,1);
  assert.equal(metrics.width,metrics.scrollWidth,'390px signup must not overflow');
  await page.screenshot({path:new URL('signup-consent-mobile-390.png',evidenceDir).pathname,fullPage:true});

  await page.goto(`${base}?view=login`,{waitUntil:'networkidle'});
  await page.waitForSelector('#businessGoogleSignIn');
  assert.equal(await page.locator('#applicationConsent').count(),0,'ordinary login hides legal checkbox');
  await page.locator('#businessGoogleSignIn').click();
  metrics=await page.evaluate(()=>window.v130Metrics());
  assert.equal(metrics.oauthStarts.length,1,'existing-account login starts Google without signup consent');
  assert.equal(metrics.rpcCalls.filter(call=>call.name==='begin_business_google_oauth_signup_v138').length,0);
  await page.screenshot({path:new URL('existing-login-no-checkbox-mobile-390.png',evidenceDir).pathname,fullPage:true});

  await page.evaluate(()=>{localStorage.removeItem('v138-persistent-session');return window.startInterruptedBusinessOAuthCallback()});
  await page.waitForFunction(()=>window.v130Metrics().transientSetSessionCalls===1);
  metrics=await page.evaluate(()=>window.v130Metrics());
  assert.equal(metrics.persistentSetSessionCalls,0,'provider token exchange remains memory-only while admission is pending');
  assert.equal(metrics.persistedSession,null,'an interrupted admission exposes no persisted session to another tab');
  /* The production callback scrubs to /business. The static fixture server has
     no SPA rewrite, so reload the same extracted login renderer explicitly. */
  await page.goto(`${base}?view=login`,{waitUntil:'networkidle'});
  metrics=await page.evaluate(()=>window.v130Metrics());
  assert.equal(metrics.persistedSession,null,'reload after interrupted admission has no onboarding authority');

  await page.goto(`${base}?view=login`,{waitUntil:'networkidle'});
  let callback=await page.evaluate(()=>window.runBusinessOAuthCallback({intent:'signin',admitted:true}));
  assert.equal(callback.transientSetSessionCalls,1,'admission uses one memory-only provider session');
  assert.equal(callback.persistentSetSessionCalls,1,'accepted identity is persisted only after admission');
  assert.equal(callback.persistedSession,'admitted');
  assert.equal(callback.signOutCalls,0);
  assert.equal(callback.rpcCalls.find(call=>call.name==='complete_business_google_oauth_v138')?.client,'transient');
  assert.deepEqual(callback.rpcCalls.find(call=>call.name==='complete_business_google_oauth_v138')?.args,
    {p_intent:'signin',p_attempt_token:null});

  await page.goto(`${base}?view=login`,{waitUntil:'networkidle'});
  callback=await page.evaluate(()=>window.runBusinessOAuthCallback({intent:'signin',admitted:false}));
  assert.equal(callback.transientSetSessionCalls,1,'provider session is established only in memory for server admission');
  assert.equal(callback.persistentSetSessionCalls,0,'new identity rejected from login is never persisted');
  assert.equal(callback.persistedSession,null);
  assert.equal(callback.signOutCalls,1,'any older local session is removed after rejected admission');
  assert.match(callback.notice,/No business account was found/);

  await page.goto(`${base}?view=login`,{waitUntil:'networkidle'});
  callback=await page.evaluate(()=>window.runBusinessOAuthCallback({intent:'signup',attemptToken:null,admitted:true}));
  assert.equal(callback.transientSetSessionCalls,0,'forged signup callback without server token is rejected before token exchange');
  assert.equal(callback.persistentSetSessionCalls,0,'forged signup callback never persists a session');

  await page.goto(`${base}?view=login`,{waitUntil:'networkidle'});
  callback=await page.evaluate(()=>window.runBusinessOAuthCallback({
    intent:'signup',attemptToken:'11111111-1111-4111-8111-111111111111',admitted:true
  }));
  assert.equal(callback.transientSetSessionCalls,1);
  assert.equal(callback.persistentSetSessionCalls,1);
  assert.equal(callback.signOutCalls,0);
  assert.deepEqual(callback.rpcCalls.find(call=>call.name==='complete_business_google_oauth_v138')?.args,{
    p_intent:'signup',p_attempt_token:'11111111-1111-4111-8111-111111111111'
  });

  await page.goto(`${base}?view=login`,{waitUntil:'networkidle'});
  await page.evaluate(async()=>{
    sessionStorage.setItem('nestly-business-google-oauth',JSON.stringify({
      startedAt:Date.now()-31*60*1000,returnPath:'/business',intent:'signin',legalAccepted:false,attemptToken:null
    }));
    history.replaceState(null,'',location.pathname+'?oauth=business#access_token=access&refresh_token=refresh');
    await consumeBusinessOAuthRedirect();
  });
  metrics=await page.evaluate(()=>window.v130Metrics());
  assert.equal(metrics.transientSetSessionCalls,0,'expired browser callback never exchanges provider tokens');
  assert.equal(metrics.persistentSetSessionCalls,0,'expired browser callback never persists a provider session');
  await page.evaluate(()=>consumeBusinessOAuthRedirect());
  metrics=await page.evaluate(()=>window.v130Metrics());
  assert.equal(metrics.transientSetSessionCalls,0,'consumed callback marker cannot replay');
  assert.equal(metrics.persistentSetSessionCalls,0,'replayed callback cannot persist a session');
  assert.deepEqual(consoleErrors,[]);

  process.stdout.write(JSON.stringify({status:'PASS',evidenceDir:evidenceDir.pathname},null,2)+'\n');
}finally{
  await browser.close();
}
