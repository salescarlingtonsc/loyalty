/* nestly_v860 — the biometric APP LOCK, proved in a REAL Chrome against the REAL app/app.js bundle.
 *
 * This is new code on a path no unit test executes (a `Capacitor.Plugins.App` lifecycle event, a
 * synchronous DOM cover painted from inside a background handler, a fake LocalAuthentication
 * ceremony) — exactly the shape the repo's own lesson warns about: a source-regex test stays green
 * while the behaviour underneath it is dead. So this boots the built app-core.js/app-customer.js
 * bundles from the current app/app.js against a FAKE native shell — `window.Capacitor` installed
 * before any page script runs, with a controllable `BiometricCredential` plugin and an `App` plugin
 * that captures the `appStateChange` listener the lock binds to — and a stub Supabase carrying one
 * signed-in customer. Every assertion below reads the DOM (getBoundingClientRect/getComputedStyle,
 * textContent, class lists) or the fake's own call log — never the source text.
 *
 * WHAT IT PROVES
 *   1. Launch, lock off: no cover, authenticate never called.
 *   2. Launch, lock on, auth ok: the cover appears then is removed; authenticate called once with
 *      reason 'Unlock Peekaa'.
 *   3. A failed unlock keeps the app shut: the cover stays, offers Unlock + Sign out, and actually
 *      covers the viewport (measured rect/opacity/z-index, not just an attribute) — then a
 *      subsequent successful Unlock click removes it.
 *   4. Cancel / fail / lockout render three different visible messages, and canceled does not let
 *      the customer in.
 *   5. A dead mechanism (status 'unavailable') fails OPEN — the cover is removed AND the native
 *      preference is switched off via setLockPreference(enabled:false).
 *   6. Backgrounding paints the cover SYNCHRONOUSLY (measured in the same evaluate call as the
 *      appStateChange event) and it leaks no text while covered.
 *   7. A foreground within the 15s grace lifts the cover with no new authenticate call; past the
 *      grace, foregrounding re-authenticates.
 *   8. Sign out from behind a failed-unlock cover always works and clears the cover.
 *   9. The Settings → "Lock this app" switch: turning on requires and records a successful check;
 *      a cancelled attempt reverts the switch and calls nothing; no biometrics on the phone shows
 *      an explanation instead of a dead switch.
 *  10. No uncaught page errors at any point. The web (non-native) case renders no lock card and no
 *      cover at all.
 *
 * Run:
 *   PLAYWRIGHT_MODULE=/private/tmp/claude-501/-Users-cs-Downloads-loyalty-main/9538021f-5363-4d80-a86c-f2544723a5a6/scratchpad/pw/node_modules/playwright-core/index.js \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Users/cs/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" \
 *   node tests/browser/verify-v860-app-lock.mjs
 */
import {spawn} from 'node:child_process';
import {cp,mkdtemp,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {OUTPUTS} from '../../scripts/quality/split-app-bundle.mjs';
import {build} from '../../scripts/quality/stamp-app-bundle.mjs';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;

const REPO_ROOT=fileURLToPath(new URL('../../',import.meta.url));
const PORT=Number(process.env.V860_PORT||4833);
const ORIGIN=`http://127.0.0.1:${PORT}`;

const buildServedTree=async()=>{
  const dir=await mkdtemp(path.join(tmpdir(),'v860-app-'));
  await cp(path.join(REPO_ROOT,'app'),dir,{recursive:true});
  const {chunks,stamped}=await build(REPO_ROOT);
  for(const [surface,target] of Object.entries(OUTPUTS)){
    await writeFile(path.join(dir,path.basename(target)),chunks[surface]);
  }
  await writeFile(path.join(dir,'index.html'),stamped);
  return dir;
};

let step='(boot)';
const failures=[];
const say=name=>{step=name;process.stdout.write(`STEP ${name}\n`)};
const ok=(condition,message)=>{
  if(condition){process.stdout.write(`  ok   - ${message}\n`);return}
  failures.push(`step ${step}: ${message}`);
  process.stdout.write(`  FAIL - ${message}\n`);
};

let server=null;
const probe=async()=>{
  try{
    const response=await fetch(`${ORIGIN}/app-core.js`);
    if(!response.ok)return false;
    return (await response.text()).includes('startAppLockV860');
  }catch{return false}
};
const serverReady=async()=>{
  const dir=await buildServedTree();
  server=spawn('python3',['-m','http.server',String(PORT),'--bind','127.0.0.1'],{cwd:dir,stdio:'ignore'});
  for(let i=0;i<120;i++){if(await probe())return;await new Promise(r=>setTimeout(r,100))}
  throw new Error(`static server did not start on ${ORIGIN}, or the built chunk is the wrong tree`);
};

const BIZ='b8320000-0000-4000-8000-000000000832';
const SLUG='v860co';
const CUSTOMER={id:'u-v860',email:'customer@v860.example'};

/* One stub installed as an init script, so it runs before ANY page script — including
   native-bridge.js, which reads `Capacitor.isNativePlatform()` and freezes its answer at load
   time. `nativePlatform:false` is the one knob the "web case" flips; everything else is the
   controllable fake native shell / customer session.

   window.__lockFake is the single source of truth the fake BiometricCredential plugin reads and
   the test mutates between steps (same document — no reload — so a `page.evaluate` mutation
   sticks): { available, biometry, nextAuth, enabledPref, authCalls:[], setCalls:[] }.
   window.__appStateHandler is the `appStateChange` callback the lock bound, captured off the fake
   Capacitor.Plugins.App so the test can fire background/foreground synthetically.
   window.__signOutCalls counts real sb.auth.signOut() calls, so the sign-out escape hatch can be
   proven to actually reach Supabase, not just clear the cover. */
const stub=({nativePlatform=true,available=true,biometry='faceId',nextAuth='ok',enabledPref=false}={})=>`(()=>{
  window.__lockFake={available:${JSON.stringify(available)},biometry:${JSON.stringify(biometry)},
    nextAuth:${JSON.stringify(nextAuth)},enabledPref:${JSON.stringify(enabledPref)},authCalls:[],setCalls:[]};
  window.__signOutCalls=0;
  /* Deliberately slower than a real Face ID prompt would ever be (which itself takes at least a
     few hundred ms) so the test's own polling reliably observes the cover mid-flight rather than
     only ever seeing it after it has already been removed. */
  const authDelay=()=>new Promise(r=>setTimeout(r,400));
  const BiometricCredential={
    async availability(){return {available:window.__lockFake.available!==false,biometry:window.__lockFake.biometry||'faceId'}},
    async enrolled(){return {enrolled:false}},
    async store(){return {status:'ok'}},
    async retrieve(){return {status:'missing'}},
    async clear(){return {status:'ok'}},
    async authenticate({reason}={}){
      window.__lockFake.authCalls.push({reason});
      await authDelay();
      return {status:window.__lockFake.nextAuth};
    },
    async lockPreference(){return {enabled:window.__lockFake.enabledPref===true}},
    async setLockPreference({enabled}={}){
      window.__lockFake.setCalls.push({enabled});
      window.__lockFake.enabledPref=enabled===true;
      return {status:'ok',enabled:enabled===true};
    }
  };
  const appListeners={};
  const App={
    addListener(event,cb){
      appListeners[event]=cb;
      if(event==='appStateChange')window.__appStateHandler=cb;
      return {remove(){}};
    }
  };
  window.Capacitor={
    isNativePlatform:()=>${nativePlatform?'true':'false'},
    getPlatform:()=>'ios',
    Plugins:{BiometricCredential,App,Network:{addListener(){return {remove(){}}}}}
  };
  const BUSINESS={id:'${BIZ}',slug:'${SLUG}',name:'V860 Co',currency:'SGD'};
  const chainable=resolveOut=>{
    const q={single:false,head:false,countMode:null,op:'select'};
    const chain={};
    for(const m of ['eq','neq','is','in','not','gte','lte','lt','gt','or','ilike','like','contains',
      'overlaps','order','limit','range','abortSignal','filter','match'])chain[m]=()=>chain;
    chain.select=(cols,opts)=>{if(opts&&opts.count){q.countMode=opts.count;q.head=!!opts.head}return chain};
    chain.single=()=>{q.single=true;return chain};
    chain.maybeSingle=()=>{q.single=true;return chain};
    chain.update=()=>{q.op='update';return chain};
    chain.insert=()=>{q.op='insert';return chain};
    chain.upsert=()=>{q.op='upsert';return chain};
    chain.delete=()=>{q.op='delete';return chain};
    chain.then=(res,rej)=>Promise.resolve(resolveOut(q)).then(res,rej);
    return chain;
  };
  const query=()=>chainable(q=>q.single?{data:null,error:null}:{data:[],count:0,error:null});
  window.__v860Rpc=[];
  const rpcData=name=>{
    switch(name){
      case 'get_customer_feature_capabilities':return {customer_wallet:true,customer_phone_registration:true,
        customer_in_app_inbox:true,customer_identity:false,customer_notifications:false,
        customer_actionable_wallet:false,customer_actions:false,customer_birthday_benefits:false};
      case 'customer_get_profile':return {profile:{full_name:'V860 Customer',birth_date:'1992-01-01',
        preferred_language:'en',phone:'81234567'}};
      case 'get_my_personas':return {staff:[],customer:[{business_id:'${BIZ}',business_slug:'${SLUG}',
        business_name:BUSINESS.name}],default_route:'#/wallet'};
      case 'customer_get_platform_marketing_preference':return {opted_in:true};
      case 'customer_get_consent_history_v282':return {entries:[]};
      case 'get_notifications':return {unread:0,items:[]};
      default:return {};
    }
  };
  const rpc=name=>{window.__v860Rpc.push(name);return chainable(()=>({data:rpcData(name),error:null}))};
  const channel=()=>{const c={on:()=>c,subscribe:()=>c,unsubscribe:()=>{}};return c};
  const auth=new Proxy({
    getSession:async()=>({data:{session:{user:${JSON.stringify(CUSTOMER)}}},error:null}),
    getUser:async()=>({data:{user:${JSON.stringify(CUSTOMER)}},error:null}),
    onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
    signOut:async()=>{window.__signOutCalls++;return {error:null}}
  },{get:(t,k)=>k in t?t[k]:async()=>({data:null,error:null})});
  const client={from:query,rpc,auth,channel,removeChannel(){},
    functions:{invoke:async()=>({data:null,error:null})},
    storage:{from:()=>({getPublicUrl:()=>({data:{publicUrl:''}})})}};
  Object.defineProperty(window,'supabase',{value:{createClient:()=>client},writable:false,configurable:false});
})();`;

const READ_COVER=`(()=>{
  const cover=document.getElementById('appLockCoverV860');
  if(!cover)return {present:false};
  const rect=cover.getBoundingClientRect();
  const cs=getComputedStyle(cover);
  return {
    present:true,
    connected:cover.isConnected,
    text:(cover.textContent||'').replace(/\\s+/g,' ').trim(),
    hasUnlock:!!document.getElementById('appLockUnlockV860'),
    hasSignOut:!!document.getElementById('appLockSignOutV860'),
    message:(document.getElementById('appLockMessageV860')?.textContent||'').trim(),
    rect:{width:rect.width,height:rect.height,top:rect.top,left:rect.left},
    viewport:{width:window.innerWidth,height:window.innerHeight},
    position:cs.position,
    zIndex:Number(cs.zIndex)||0,
    bgAlphaIsOpaque:/^rgba?\\(([^)]+)\\)$/.exec(cs.backgroundColor)
      ? (cs.backgroundColor.split(',').length<4 || parseFloat(cs.backgroundColor.split(',')[3])===1)
      : true
  };
})()`;

const browser=await chromium.launch({
  headless:true,
  executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH
    ||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
});
const pageErrors=[];

const newPage=async(context,opts={})=>{
  await context.addInitScript(stub(opts));
  const page=await context.newPage();
  page.on('pageerror',error=>pageErrors.push(String(error)));
  return page;
};
const newContext=async()=>{
  const context=await browser.newContext({viewport:{width:390,height:844},bypassCSP:true});
  await context.route('**/*',route=>{
    const url=route.request().url();
    if(url.startsWith(ORIGIN)&&!url.includes('/sw.js'))return route.continue();
    return route.abort();
  });
  return context;
};
const setFake=(page,patch)=>page.evaluate(p=>Object.assign(window.__lockFake,p),patch);
const lockState=page=>page.evaluate(()=>({authCalls:window.__lockFake.authCalls.slice(),
  setCalls:window.__lockFake.setCalls.slice(),signOutCalls:window.__signOutCalls}));
const waitForCover=async(page,present,timeout=5000)=>{
  await page.waitForFunction(want=>!!document.getElementById('appLockCoverV860')===want,present,{timeout});
};

try{
  await serverReady();

  say('1. launch, lock off: no cover, authenticate never called');
  {
    const context=await newContext();
    const page=await newPage(context,{enabledPref:false,nextAuth:'ok'});
    await page.goto(`${ORIGIN}/index.html#/customer/settings`,{waitUntil:'domcontentloaded'});
    await page.waitForFunction(()=>document.getElementById('customerAppLockV860')!==null,null,{timeout:15000});
    await page.waitForTimeout(300);
    const cover=await page.evaluate(READ_COVER);
    const calls=await lockState(page);
    ok(cover.present===false,`no cover exists when the lock is off — got ${JSON.stringify(cover)}`);
    ok(calls.authCalls.length===0,`authenticate was never called — got ${calls.authCalls.length}`);
    await context.close();
  }

  say('2. launch, lock on, auth ok: cover appears then is removed, authenticate called once');
  let sharedContext,sharedPage;
  {
    const context=await newContext();
    const page=await newPage(context,{enabledPref:true,nextAuth:'ok'});
    await page.goto(`${ORIGIN}/index.html#/customer/settings`,{waitUntil:'domcontentloaded'});
    await waitForCover(page,true);
    const whileUp=await page.evaluate(READ_COVER);
    ok(whileUp.present===true,'the cover appeared on launch while armed');
    await waitForCover(page,false);
    const calls=await lockState(page);
    ok(calls.authCalls.length===1,`authenticate called exactly once — got ${calls.authCalls.length}`);
    ok(calls.authCalls[0]?.reason==='Unlock Peekaa',`reason was "Unlock Peekaa" — got "${calls.authCalls[0]?.reason}"`);
    sharedContext=context;sharedPage=page; // reused for steps 6/7/8 below (same document, no reload)
  }

  say('3. a failed unlock keeps the app shut, measured on the real DOM');
  {
    const context=await newContext();
    const page=await newPage(context,{enabledPref:true,nextAuth:'failed'});
    await page.goto(`${ORIGIN}/index.html#/customer/settings`,{waitUntil:'domcontentloaded'});
    await waitForCover(page,true);
    await page.waitForFunction(()=>!!document.getElementById('appLockUnlockV860')&&!document.getElementById('appLockUnlockV860').disabled,null,{timeout:5000});
    const cover=await page.evaluate(READ_COVER);
    ok(cover.hasUnlock&&cover.hasSignOut,'the locked cover offers both Unlock and Sign out');
    ok(cover.position==='fixed',`cover is position:fixed — got "${cover.position}"`);
    ok(cover.rect.width>=cover.viewport.width-1&&cover.rect.height>=cover.viewport.height-1,
      `cover's measured rect covers the viewport — rect ${JSON.stringify(cover.rect)} vs viewport ${JSON.stringify(cover.viewport)}`);
    ok(cover.bgAlphaIsOpaque,'cover background is opaque, not a see-through overlay');
    ok(cover.zIndex>210,`cover z-index (${cover.zIndex}) is above the stylesheet's highest (.modal at 210)`);
    await setFake(page,{nextAuth:'ok'});
    await page.click('#appLockUnlockV860');
    await waitForCover(page,false);
    ok(true,'clicking Unlock after fixing nextAuth removes the cover');
    await context.close();
  }

  say('4. cancel / fail / lockout render three different messages; canceled does not let the customer in');
  {
    const context=await newContext();
    const page=await newPage(context,{enabledPref:true,nextAuth:'failed'});
    await page.goto(`${ORIGIN}/index.html#/customer/settings`,{waitUntil:'domcontentloaded'});
    await waitForCover(page,true);
    await page.waitForFunction(()=>!!document.getElementById('appLockUnlockV860')&&!document.getElementById('appLockUnlockV860').disabled,null,{timeout:5000});
    const failedMsg=(await page.evaluate(READ_COVER)).message;

    await setFake(page,{nextAuth:'canceled'});
    await page.evaluate(()=>window.promptAppLockV860({trigger:'manual'}));
    await page.waitForFunction(()=>!!document.getElementById('appLockUnlockV860')&&!document.getElementById('appLockUnlockV860').disabled,null,{timeout:5000});
    const afterCancel=await page.evaluate(READ_COVER);
    ok(afterCancel.present===true,'a canceled attempt does NOT remove the cover — the customer stays shut out');
    const canceledMsg=afterCancel.message;

    await setFake(page,{nextAuth:'lockout'});
    await page.evaluate(()=>window.promptAppLockV860({trigger:'manual'}));
    await page.waitForFunction(()=>!!document.getElementById('appLockUnlockV860')&&!document.getElementById('appLockUnlockV860').disabled,null,{timeout:5000});
    const lockoutMsg=(await page.evaluate(READ_COVER)).message;

    ok(!!failedMsg&&!!canceledMsg&&!!lockoutMsg,`all three states show a message — failed="${failedMsg}" canceled="${canceledMsg}" lockout="${lockoutMsg}"`);
    ok(new Set([failedMsg,canceledMsg,lockoutMsg]).size===3,
      `the three messages are all different — failed="${failedMsg}" canceled="${canceledMsg}" lockout="${lockoutMsg}"`);
    await context.close();
  }

  say('5. a dead mechanism (unavailable) fails open and switches the preference off');
  {
    const context=await newContext();
    const page=await newPage(context,{enabledPref:true,nextAuth:'unavailable'});
    await page.goto(`${ORIGIN}/index.html#/customer/settings`,{waitUntil:'domcontentloaded'});
    await waitForCover(page,true); // painted synchronously before the async authenticate resolves
    await waitForCover(page,false); // then lifted once 'unavailable' comes back
    const calls=await lockState(page);
    ok(calls.setCalls.some(c=>c.enabled===false),
      `setLockPreference(false) was called so Settings tells the truth — got ${JSON.stringify(calls.setCalls)}`);
    await context.close();
  }

  say('6/7/8. background/foreground/grace/sign-out, continuing the unlocked session from step 2');
  {
    const page=sharedPage,context=sharedContext;
    // Sanity check the harness's own premise before relying on it (per task instructions).
    const bareIdentifierReachable=await page.evaluate(()=>{
      const before=appLockHiddenAtV860;
      appLockHiddenAtV860=123456789;
      const after=appLockHiddenAtV860;
      appLockHiddenAtV860=before;
      return after===123456789;
    }).catch(()=>false);
    ok(bareIdentifierReachable===true,
      'top-level `let appLockHiddenAtV860` in app.js is reachable and assignable as a bare identifier from page.evaluate (classic scripts share one global lexical scope)');

    say('6. backgrounding paints the cover synchronously and it leaks no text');
    const backgroundResult=await page.evaluate(()=>{
      window.__appStateHandler({isActive:false});
      const cover=document.getElementById('appLockCoverV860');
      return {presentImmediately:!!cover,text:(cover?.textContent||'').trim()};
    });
    ok(backgroundResult.presentImmediately===true,
      'the cover exists in the SAME evaluate call as the appStateChange event — no await needed');
    ok(backgroundResult.text==='','the covered (snapshot) state shows no text at all');

    say('7. foreground within grace lifts the cover with no new authenticate call');
    const beforeGraceCalls=(await lockState(page)).authCalls.length;
    await page.evaluate(()=>window.__appStateHandler({isActive:true}));
    await waitForCover(page,false);
    const afterGraceCalls=(await lockState(page)).authCalls.length;
    ok(afterGraceCalls===beforeGraceCalls,
      `no new authenticate call inside the grace period — before ${beforeGraceCalls}, after ${afterGraceCalls}`);

    say('7b. foreground past the grace period re-authenticates');
    await setFake(page,{nextAuth:'ok'});
    const beforePastGrace=(await lockState(page)).authCalls.length;
    await page.evaluate(()=>window.__appStateHandler({isActive:false}));
    await waitForCover(page,true);
    await page.evaluate(()=>{appLockHiddenAtV860=Date.now()-20000}); // past APP_LOCK_PROMPT_GRACE_MS_V860 (15000)
    await page.evaluate(()=>window.__appStateHandler({isActive:true}));
    await page.waitForFunction(expected=>window.__lockFake.authCalls.length>expected,beforePastGrace,{timeout:5000});
    const afterPastGrace=(await lockState(page)).authCalls.length;
    ok(afterPastGrace>beforePastGrace,
      `authenticate was called again once the grace window had passed — before ${beforePastGrace}, after ${afterPastGrace}`);
    await waitForCover(page,false);

    say('8. sign out from behind a failed-unlock cover always escapes');
    await setFake(page,{nextAuth:'failed'});
    await page.evaluate(()=>window.__appStateHandler({isActive:false}));
    await waitForCover(page,true);
    // Past the grace window, exactly like 7b, so foregrounding actually re-authenticates
    // (asking again is what leaves the "locked" cover up with Unlock + Sign out to test).
    await page.evaluate(()=>{appLockHiddenAtV860=Date.now()-20000});
    await page.evaluate(()=>window.__appStateHandler({isActive:true}));
    await page.waitForFunction(()=>!!document.getElementById('appLockUnlockV860')&&!document.getElementById('appLockUnlockV860').disabled,null,{timeout:5000});
    const signOutBefore=(await lockState(page)).signOutCalls;
    await page.click('#appLockSignOutV860');
    await waitForCover(page,false);
    const signOutAfter=(await lockState(page)).signOutCalls;
    ok(signOutAfter>signOutBefore,`sign out reached the real sb.auth.signOut() — before ${signOutBefore}, after ${signOutAfter}`);
    await context.close();
  }

  say('9. the Settings switch');
  {
    const READ_TOGGLE=`(()=>{
      const card=document.getElementById('customerAppLockV860');
      const toggle=document.getElementById('customerAppLockToggleV860');
      return {cardPresent:!!card,toggleExists:!!toggle,checked:toggle?toggle.checked:null,
        disabled:toggle?toggle.disabled:null,
        bodyText:(document.getElementById('customerAppLockBodyV860')?.textContent||'').trim(),
        statusText:(document.getElementById('customerAppLockStatusV860')?.textContent||'').trim()};
    })()`;

    const context=await newContext();
    const page=await newPage(context,{available:true,enabledPref:false,nextAuth:'ok'});
    await page.goto(`${ORIGIN}/index.html#/customer/settings`,{waitUntil:'domcontentloaded'});
    await page.waitForFunction(()=>document.getElementById('customerAppLockV860')?.getAttribute('aria-busy')==='false',null,{timeout:15000});

    let seen=await page.evaluate(READ_TOGGLE);
    ok(seen.cardPresent&&seen.toggleExists,'Lock this app card renders with a real checkbox toggle');
    ok(seen.checked===false,'toggle starts unchecked (lock currently off)');

    say('9a. turning ON with a successful check calls setLockPreference(true) and confirms');
    await page.click('#customerAppLockToggleV860');
    await page.waitForFunction(()=>!document.getElementById('customerAppLockToggleV860').disabled,null,{timeout:5000});
    seen=await page.evaluate(READ_TOGGLE);
    const stateA=await lockState(page);
    ok(seen.checked===true,'toggle ends up checked');
    ok(stateA.setCalls.some(c=>c.enabled===true),`setLockPreference(true) was called — got ${JSON.stringify(stateA.setCalls)}`);
    ok(seen.statusText.length>0,`a confirming status message is shown — got "${seen.statusText}"`);

    say('9b. turning it off, then attempting ON again with a canceled check reverts and calls nothing new');
    await page.click('#customerAppLockToggleV860'); // back off
    await page.waitForFunction(()=>!document.getElementById('customerAppLockToggleV860').disabled,null,{timeout:5000});
    await setFake(page,{nextAuth:'canceled'});
    const setCallsBefore=(await lockState(page)).setCalls.length;
    await page.click('#customerAppLockToggleV860'); // attempt ON, will be canceled
    await page.waitForFunction(()=>!document.getElementById('customerAppLockToggleV860').disabled,null,{timeout:5000});
    seen=await page.evaluate(READ_TOGGLE);
    const setCallsAfter=(await lockState(page)).setCalls.length;
    ok(seen.checked===false,`a canceled attempt reverts the switch back to off — got checked=${seen.checked}`);
    ok(seen.disabled===false,'the toggle is re-enabled after the canceled attempt');
    ok(seen.statusText.length>0,`a message explains the cancellation — got "${seen.statusText}"`);
    ok(setCallsAfter===setCallsBefore,
      `setLockPreference was NOT called for the canceled attempt — before ${setCallsBefore}, after ${setCallsAfter}`);
    await context.close();
  }

  say('9c. no biometrics on the phone explains instead of showing a dead switch');
  {
    const context=await newContext();
    const page=await newPage(context,{available:false});
    await page.goto(`${ORIGIN}/index.html#/customer/settings`,{waitUntil:'domcontentloaded'});
    await page.waitForFunction(()=>document.getElementById('customerAppLockV860')?.getAttribute('aria-busy')==='false',null,{timeout:15000});
    const seen=await page.evaluate(()=>({toggleExists:!!document.getElementById('customerAppLockToggleV860'),
      bodyText:(document.getElementById('customerAppLockBodyV860')?.textContent||'').trim()}));
    ok(seen.toggleExists===false,'no switch is rendered when biometrics/passcode are unavailable');
    ok(seen.bodyText.length>0,`an explanation is shown instead — got "${seen.bodyText}"`);
    await context.close();
  }

  say('10. the web (non-native) case: no lock card, no cover, ever');
  {
    const context=await newContext();
    // even "enabled" on the web must do nothing
    const page=await newPage(context,{nativePlatform:false,enabledPref:true,nextAuth:'ok'});
    await page.goto(`${ORIGIN}/index.html#/customer/settings`,{waitUntil:'domcontentloaded'});
    await page.waitForFunction(()=>document.getElementById('walletBody')!==null&&document.getElementById('walletBody').innerHTML.length>0,null,{timeout:15000});
    await page.waitForTimeout(500);
    const seen=await page.evaluate(()=>({card:!!document.getElementById('customerAppLockV860'),
      cover:!!document.getElementById('appLockCoverV860')}));
    ok(seen.card===false,'no #customerAppLockV860 card renders on the web');
    ok(seen.cover===false,'no cover is ever created on the web, even with the preference set');
    await context.close();
  }

  say('no uncaught page errors across every scenario');
  ok(pageErrors.length===0,`no page errors (${pageErrors.slice(0,4).join(' | ')||'none'})`);
}finally{
  await browser.close().catch(()=>{});
  if(server)server.kill();
}

if(failures.length){
  process.stdout.write(`\n${failures.length} FAILED:\n`+failures.map(f=>`  - ${f}\n`).join(''));
  process.exit(1);
}
process.stdout.write('\nBiometric app lock (v860) verified in a real browser.\n');
