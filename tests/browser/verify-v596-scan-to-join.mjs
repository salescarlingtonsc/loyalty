/* nestly_v596 — scanning a business QR names the business, whoever is holding the phone.
 *
 * THE BUG, reproduced on production before this change: a customer who is not signed in scans the
 * counter QR, lands on https://www.peekaa.asia/#/join?token=…, and the router pockets the token,
 * strips it from the URL and renders the generic "Welcome to Peekaa" sign-in card. The gateway was
 * fine the whole time — GET public-join?token=… returns the business — but nothing on screen ever
 * said so, which is exactly the owner's report: "the qrcode scanned but failed to retrieve".
 *
 * WHAT THIS PROVES, by booting the real bundles in a real Chrome:
 *   1. signed OUT, a scan shows the join sheet, named for the business, with exactly two ways
 *      out — Yes and the close control — and no third choice smuggled in.
 *   2. Yes carries on into the real sign-up (mobile number), keeping the token.
 *   3. the answer survives the sign-up hop: arriving signed-in at #/join does NOT ask again, and
 *      joins straight through to that business's wallet.
 *   4. Close drops the token, so a stale scan cannot be replayed by a later render.
 *   5. signed IN, a first scan still gets the sheet — v571's protection against a silent join by
 *      a mis-scanned or stale printed code is untouched.
 *   6. an answer belongs to ONE token: scanning a different QR asks again.
 *
 * Run:
 *   PLAYWRIGHT_MODULE="<repo>/node_modules/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v596-scan-to-join.mjs
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
const PORT=Number(process.env.V596_PORT||4596);
const ORIGIN=`http://127.0.0.1:${PORT}`;
const MARKER='customerJoinAskedThisVisitV599';

const buildServedTree=async()=>{
  const dir=await mkdtemp(path.join(tmpdir(),'v596-app-'));
  await cp(path.join(REPO_ROOT,'app'),dir,{recursive:true});
  const {chunks,stamped}=await build(REPO_ROOT);
  for(const [surface,target] of Object.entries(OUTPUTS))
    await writeFile(path.join(dir,path.basename(target)),chunks[surface]);
  await writeFile(path.join(dir,'index.html'),stamped);
  return dir;
};

let step='(boot)';
const say=name=>{step=name;process.stdout.write(`STEP ${name}\n`)};
const ok=(condition,message)=>{
  if(!condition)throw new Error(`step ${step}: ${message}`);
  process.stdout.write(`  ok - ${message}\n`);
};

let server=null;
const probe=async()=>{
  try{
    const response=await fetch(`${ORIGIN}/app-core.js`);
    return response.ok&&(await response.text()).includes(MARKER);
  }catch{return false}
};
const serverReady=async()=>{
  if(await probe())throw new Error(`something already serves ${ORIGIN}; this test needs the port`);
  const dir=await buildServedTree();
  server=spawn('python3',['-m','http.server',String(PORT),'--bind','127.0.0.1'],{cwd:dir,stdio:'ignore'});
  for(let i=0;i<80;i++){if(await probe())return;await new Promise(r=>setTimeout(r,120))}
  throw new Error('server did not start, or the built chunk lacks the v596 marker');
};

const TOKEN='a'.repeat(64);
const OTHER_TOKEN='b'.repeat(64);
const SLUG='jess-salon';
const BIZ='b5960000-0000-4000-8000-000000000596';

/* The gateway preview and the join RPC are the two server answers this journey turns on; both are
   served here exactly as production shapes them, so the screens are driven by real payloads. */
const stub=({session})=>`(()=>{
  const AUD={rpc:[],gateway:[]};
  window.__V596=AUD;
  const SESSION=${JSON.stringify(session)};
  const chainable=(resolveOut,table)=>{
    const q={single:false,head:false,countMode:null,table,filters:[]};
    const chain={};
    for(const m of ['neq','is','in','not','gte','lte','lt','gt','or','ilike','like','contains',
      'overlaps','order','limit','range','abortSignal','filter','match'])chain[m]=()=>chain;
    chain.eq=(c,v)=>{q.filters.push([c,String(v)]);return chain};
    chain.select=(cols,opts)=>{if(opts&&opts.count){q.countMode=opts.count;q.head=!!opts.head}return chain};
    chain.single=()=>{q.single=true;return chain};
    chain.maybeSingle=()=>{q.single=true;return chain};
    chain.update=()=>chain;chain.insert=()=>chain;chain.upsert=()=>chain;chain.delete=()=>chain;
    chain.then=(res,rej)=>Promise.resolve(resolveOut(q)).then(res,rej);
    return chain;
  };
  const TABLES={businesses:[],clients:[],branches:[],business_programmes:[]};
  const query=table=>chainable(q=>{
    const rows=(TABLES[table]||[]).slice();
    if(q.countMode&&q.head)return {data:null,count:rows.length,error:null};
    if(q.single)return {data:rows[0]??null,error:null};
    return {data:rows,count:q.countMode?rows.length:null,error:null};
  },table);
  const rpcData=name=>{
    switch(name){
      case 'customer_join_business_from_qr_v89':
        return {outcome:'joined',business_id:'${BIZ}',business_slug:'${SLUG}'};
      case 'get_customer_feature_capabilities':
        return {customer_wallet:true,customer_phone_registration:true};
      case 'get_customer_phone_otp_capabilities':return {sms:true,whatsapp:false};
      case 'customer_get_profile':return {profile:{full_name:'Ben Tan'}};
      case 'get_my_personas':return {staff:[],customer:[{business_id:'${BIZ}',
        business_slug:'${SLUG}',business_name:'Jess Salon'}],default_route:'#/wallet'};
      /* The wallet the join lands on. Present so the walk ends on a rendered page rather than on
         a renderer reading .business off a null payload — which is a stub gap, not a defect. */
      case 'customer_get_business_summary':return {business:{id:'${BIZ}',slug:'${SLUG}',
        name:'Jess Salon',currency:'SGD'},loyalty:{},packages:{},membership:{},cards:[]};
      /* The wallet the join lands on reads a dozen payloads this walk does not care about. An
         empty object rather than null keeps that page from throwing on a stub gap, so the
         "no uncaught page errors" check below stays about the join flow itself. */
      default:return {};
    }
  };
  const rpc=name=>{AUD.rpc.push(name);return chainable(()=>({data:rpcData(name),error:null}),'rpc:'+name)};
  const auth=new Proxy({
    getSession:async()=>({data:{session:SESSION?{user:SESSION}:null},error:null}),
    getUser:async()=>({data:{user:SESSION||null},error:null}),
    onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
    signOut:async()=>({error:null})
  },{get:(t,k)=>k in t?t[k]:async()=>({data:null,error:null})});
  const client={from:query,rpc,auth,channel:()=>{const c={on:()=>c,subscribe:()=>c,unsubscribe(){}};return c},
    removeChannel(){},functions:{invoke:async()=>({data:null,error:null})},
    storage:{from:()=>({getPublicUrl:()=>({data:{publicUrl:''}})})}};
  Object.defineProperty(window,'supabase',{value:{createClient:()=>client},writable:false,configurable:false});
  /* The read-only preview the sheet uses to learn the business name. */
  const realFetch=window.fetch.bind(window);
  window.fetch=async(input,init)=>{
    const url=String(input&&input.url?input.url:input||'');
    if(url.includes('/public-join')){
      AUD.gateway.push(url);
      return new Response(JSON.stringify({name:'Jess Salon',slug:'${SLUG}',industry:'salon',
        brand_color:'#FF6B5E',join_token:new URL(url,location.href).searchParams.get('token')}),
        {status:200,headers:{'content-type':'application/json'}});
    }
    return realFetch(input,init);
  };
})();`;

const CUSTOMER={id:'u-cust',email:'ben@example.invalid',phone:'+6580000590'};

const browser=await chromium.launch({headless:true,
  executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
const pageErrors=[];
try{
  await serverReady();

  const open=async({session=null,token=TOKEN,seed=null})=>{
    const context=await browser.newContext({viewport:{width:390,height:844},bypassCSP:true});
    await context.route('**/*',route=>{
      const target=route.request().url();
      if(target.startsWith(ORIGIN)&&!target.includes('/sw.js'))return route.continue();
      if(target.startsWith('https://cdn.jsdelivr.net/'))return route.continue();
      return route.abort();
    });
    await context.addInitScript(stub({session}));
    if(seed)await context.addInitScript(`(()=>{try{sessionStorage.setItem(${JSON.stringify(seed.key)},${JSON.stringify(seed.value)})}catch{}})();`);
    const page=await context.newPage();
    page.on('pageerror',error=>pageErrors.push(String(error)+' :: '+String(error.stack||'').split('\n').slice(0,4).join(' | ')));
    await page.goto(`${ORIGIN}/index.html#/join?token=${token}`,{waitUntil:'domcontentloaded'});
    await page.waitForTimeout(2600);
    return {context,page};
  };
  const sheetText=page=>page.evaluate(()=>
    (document.querySelector('.customer-join-sheet-v587')?.innerText||'').replace(/\s+/g,' ').trim());
  const bodyText=page=>page.evaluate(()=>(document.body.innerText||'').replace(/\s+/g,' '));

  /* ---- 1. the signed-out scan finally names the business ---- */
  say('1. a signed-out scan shows the join sheet, named for the business');
  {
    const {context,page}=await open({session:null});
    const sheet=await sheetText(page);
    ok(!!sheet,'the join sheet is on screen instead of a bare sign-in card');
    ok(/Jess Salon/.test(sheet),`and it names the business (${sheet})`);
    ok((await page.evaluate(()=>window.__V596.gateway.length))>0,
      'the name came from the read-only preview, so nothing was joined to learn it');
    const buttons=await page.evaluate(()=>Array.from(
      document.querySelectorAll('.customer-join-sheet-v587 button')).map(b=>b.id||b.className));
    ok(buttons.length===2,`exactly two controls: yes and close (${buttons.join(', ')})`);
    ok(buttons.includes('customerJoinGoV571')&&buttons.includes('customerJoinCancelV571'),
      'and they are the Yes and the close control');

    /* ---- 2. Yes goes on into the REAL sign-up, token intact ---- */
    await page.click('#customerJoinGoV571');
    await page.waitForTimeout(2000);
    ok(!(await sheetText(page)),'pressing Yes dismisses the sheet');
    const after=await bodyText(page);
    ok(/mobile number/i.test(after),`and lands on the real sign-up (${after.slice(0,90)})`);
    const kept=await page.evaluate(()=>({
      token:sessionStorage.getItem('nestly.customer.pendingJoinToken'),
      confirmed:sessionStorage.getItem('nestly.customer.joinConfirmedV596')}));
    ok(kept.token===TOKEN,'the join token is still held through sign-up');
    ok(String(kept.confirmed||'').includes(SLUG),
      `and the answer is remembered with the business (${kept.confirmed})`);
    await context.close();
  }

  /* ---- 2b. A SECOND SCAN MUST ASK AGAIN (nestly_v599) ----
     v596 consulted the remembered answer here, so the first scan showed the sheet and every scan
     afterwards on the same device silently skipped it and dropped the person on the sign-in card.
     Reported by the owner scanning their own QR twice. */
  say('2b. scanning again after answering once still asks');
  {
    const {context,page}=await open({session:null});
    ok(!!(await sheetText(page)),'the first scan asks');
    await page.click('#customerJoinGoV571');
    await page.waitForTimeout(1500);
    ok(!(await sheetText(page)),'and the sheet closes');
    /* the same QR, scanned again in the same session — a fresh navigation carrying the token */
    await page.goto(`${ORIGIN}/index.html#/join?token=${TOKEN}`,{waitUntil:'domcontentloaded'});
    await page.waitForTimeout(2600);
    ok(!!(await sheetText(page)),'the SECOND scan asks again rather than skipping to sign-in');
    ok(/Jess Salon/.test(await sheetText(page)),'and still names the business');
    await context.close();
  }

  /* ---- 3. the resume after sign-up must not ask twice ---- */
  say('3. arriving signed-in with the answer already given joins straight through');
  {
    const {context,page}=await open({session:CUSTOMER,
      seed:{key:'nestly.customer.joinConfirmedV596',value:JSON.stringify({token:TOKEN,slug:SLUG})}});
    ok(!(await sheetText(page)),'the sheet is NOT shown a second time');
    const audit=await page.evaluate(()=>window.__V596.rpc);
    ok(audit.includes('customer_join_business_from_qr_v89'),'the join ran on its own');
    const landed=await page.evaluate(()=>location.hash);
    ok(landed.includes(SLUG),`and it landed inside that exact business (${landed})`);
    await context.close();
  }

  /* ---- 4. Close is a real "not now" ---- */
  say('4. Close drops the scan so a stale QR cannot be replayed');
  {
    const {context,page}=await open({session:null});
    ok(!!(await sheetText(page)),'the sheet is up');
    await page.click('#customerJoinCancelV571');
    await page.waitForTimeout(1200);
    const left=await page.evaluate(()=>({
      token:sessionStorage.getItem('nestly.customer.pendingJoinToken'),
      confirmed:sessionStorage.getItem('nestly.customer.joinConfirmedV596')}));
    ok(!left.token,'the token is dropped');
    ok(!left.confirmed,'and no consent is left behind');
    await context.close();
  }

  /* ---- 5. a signed-in FIRST scan is still confirmed (v571 is untouched) ---- */
  say('5. a signed-in first scan is still asked to confirm');
  {
    const {context,page}=await open({session:CUSTOMER});
    const sheet=await sheetText(page);
    ok(/Jess Salon/.test(sheet),'the sheet still guards a silent join by a stale printed code');
    const audit=await page.evaluate(()=>window.__V596.rpc);
    ok(!audit.includes('customer_join_business_from_qr_v89'),
      'and nothing was joined before the customer answered');
    await context.close();
  }

  /* ---- 6. one answer, one token ---- */
  say('6. an answer for one QR never covers a different QR');
  {
    const {context,page}=await open({session:CUSTOMER,token:OTHER_TOKEN,
      seed:{key:'nestly.customer.joinConfirmedV596',value:JSON.stringify({token:TOKEN,slug:SLUG})}});
    ok(!!(await sheetText(page)),'a different token asks again rather than inheriting the yes');
    await context.close();
  }

  ok(pageErrors.length===0,
    `no uncaught page errors across the walk (${pageErrors.length}${pageErrors.length?': '+pageErrors.join(' | '):''})`);
  process.stdout.write('\nV596 scan-to-join: all steps passed\n');
}catch(error){
  process.stdout.write(`\nFAILED: ${error.message}\n`);
  if(pageErrors.length)process.stdout.write(`page errors:\n  ${pageErrors.join('\n  ')}\n`);
  process.exitCode=1;
}finally{
  await browser.close();
  if(server)server.kill();
}
