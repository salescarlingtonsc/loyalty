/* nestly_v597 — the two ways a business could lose its customers without being told.
 *
 * 1. THE DEAD QR. Owner, pre-go-live: "i still not able to scan the qrcode now." Traced on
 *    production: the token in their own screenshot answered correctly earlier the same day and
 *    then began returning 404, because the row had moved from active to revoked and a NEW one had
 *    been minted. The cause is this dialog. One button is both "Generate join QR" (nothing exists)
 *    and "Replace join QR" (destroy the live code, mint another), it rendered as the PRIMARY
 *    control of the row, and in the Replace state it rotated on a single unconfirmed tap — sitting
 *    directly under copy reading "This is your permanent sign-up code. Print it once — it stays
 *    the same." Meanwhile Revoke, which at least leaves no misleading replacement behind, has
 *    always asked. So the most prominent unconfirmed button on the screen silently invalidated
 *    every poster, counter card and saved copy the business had.
 *
 * 2. THE WHITE SCREEN. The customer wallet guarded an ERROR from customer_get_business_summary
 *    and a DENIAL, but not an empty reply with neither — and the renderer reads .business,
 *    .loyalty and .packages straight off it. A null threw mid-render, so the page painted nothing:
 *    no message, no retry, nothing to report.
 *
 * Run:
 *   PLAYWRIGHT_MODULE="<repo>/node_modules/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v597-join-qr-and-wallet-guard.mjs
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
const PORT=Number(process.env.V597_PORT||4597);
const ORIGIN=`http://127.0.0.1:${PORT}`;

const buildServedTree=async()=>{
  const dir=await mkdtemp(path.join(tmpdir(),'v597-app-'));
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
    const response=await fetch(`${ORIGIN}/app-business.js`);
    return response.ok&&(await response.text()).includes('setJoinQrActionV597');
  }catch{return false}
};
const serverReady=async()=>{
  if(await probe())throw new Error(`something already serves ${ORIGIN}; this test needs the port`);
  const dir=await buildServedTree();
  server=spawn('python3',['-m','http.server',String(PORT),'--bind','127.0.0.1'],{cwd:dir,stdio:'ignore'});
  for(let i=0;i<80;i++){if(await probe())return;await new Promise(r=>setTimeout(r,120))}
  throw new Error('server did not start, or the built chunk lacks the v597 marker');
};

const BIZ='b5970000-0000-4000-8000-000000000597';
const SLUG='jess-salon';
const MODULES=['dashboard','till','clients','sales','services','loyalty','reports','settings','customerintel'];

/* `hasQr` decides whether the business already has a printed code — the whole point of the
   Replace/Generate distinction. `summary` is the wallet payload, null in the white-screen case. */
const stub=({role='owner',hasQr=true,summary='present',customer=false})=>`(()=>{
  const AUD={rotations:0,revocations:0,rpc:[]};
  window.__V597=AUD;
  const HAS_QR=${JSON.stringify(hasQr)};
  const SUMMARY_MODE=${JSON.stringify(summary)};
  const CUSTOMER=${JSON.stringify(customer)};
  const MODULES=${JSON.stringify(MODULES)};
  const bizRow={id:'${BIZ}',slug:'${SLUG}',name:'Jess Salon',currency:'SGD',industry:'salon',
    enabled_modules:MODULES,join_enabled:true,created_at:'2026-01-01T00:00:00Z',brand_color:'#FF6B5E'};
  const TABLES={businesses:[bizRow],
    branches:[{id:'br1',business_id:'${BIZ}',name:'Main',active:true,is_default:true,billing_state:'active'}],
    staff:[{id:'st1',business_id:'${BIZ}',full_name:'Owner',role:'${role}',user_id:'u1',active:true,
      modules:null,module_perms:null,access_state:'approved'}],
    clients:[],sales:[],points_ledger:[],services:[],products:[],module_registry:[],
    business_programmes:[],appointments:[],memberships:[],client_packages:[]};
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
  const query=table=>chainable(q=>{
    const rows=(TABLES[table]||[]).slice();
    if(q.countMode&&q.head)return {data:null,count:rows.length,error:null};
    if(q.single)return {data:rows[0]??null,error:null};
    return {data:rows,count:q.countMode?rows.length:null,error:null};
  },table);
  const TOKEN_A='a'.repeat(64),TOKEN_B='b'.repeat(64);
  let liveToken=HAS_QR?TOKEN_A:'';
  const rpcData=(name)=>{
    switch(name){
      case 'business_ensure_customer_join_qr_v91':
      case 'business_get_customer_join_qr_status_v91':
        return liveToken?{join_token:liveToken,created:false,expires_at:'2126-01-01T00:00:00Z',active_count:1}
                        :{join_token:null,active_count:0};
      case 'business_rotate_customer_join_qr_v90':
        AUD.rotations+=1;liveToken=TOKEN_B;
        return {join_token:TOKEN_B,expires_at:'2126-01-01T00:00:00Z',replaced_count:1};
      case 'business_revoke_customer_join_qrs_v90':
        AUD.revocations+=1;liveToken='';return {revoked_count:1};
      case 'get_my_personas':return CUSTOMER
        ?{staff:[],customer:[{business_id:'${BIZ}',business_slug:'${SLUG}',business_name:'Jess Salon'}],
          default_route:'#/wallet'}
        :{staff:[{business_id:'${BIZ}',business_slug:'${SLUG}',business_name:'Jess Salon',
          role:'${role}',modules:MODULES}],customer:[],default_route:'#/workspace/${SLUG}/dashboard'};
      case 'get_my_modules':case 'get_my_modules_at_v115':return {role:'${role}',is_super_admin:false,
        modules:MODULES,capabilities:[],module_perms:Object.fromEntries(MODULES.map(m=>[m,'rw']))};
      case 'platform_get_business_control_v94':return {workspace_access:true};
      case 'get_customer_feature_capabilities':return {customer_wallet:true,customer_phone_registration:true};
      case 'get_workspace_locale_preference_v97':return {locale:'en',version:1};
      case 'get_notifications':return {unread:0,items:[]};
      /* The wallet read at the heart of the white screen. */
      case 'customer_get_business_summary':
        return SUMMARY_MODE==='null'?null
          :{business:{id:'${BIZ}',slug:'${SLUG}',name:'Jess Salon',currency:'SGD'},
            loyalty:{},packages:{},membership:{}};
      default:return {};
    }
  };
  const rpc=name=>{AUD.rpc.push(name);return chainable(()=>({data:rpcData(name),error:null}),'rpc:'+name)};
  const auth=new Proxy({
    getSession:async()=>({data:{session:{user:{id:'u1',email:'owner@jess.invalid'}}},error:null}),
    getUser:async()=>({data:{user:{id:'u1',email:'owner@jess.invalid'}},error:null}),
    onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
    signOut:async()=>({error:null})
  },{get:(t,k)=>k in t?t[k]:async()=>({data:null,error:null})});
  const client={from:query,rpc,auth,channel:()=>{const c={on:()=>c,subscribe:()=>c,unsubscribe(){}};return c},
    removeChannel(){},functions:{invoke:async()=>({data:null,error:null})},
    storage:{from:()=>({getPublicUrl:()=>({data:{publicUrl:''}})})}};
  Object.defineProperty(window,'supabase',{value:{createClient:()=>client},writable:false,configurable:false});
})();`;

const browser=await chromium.launch({headless:true,
  executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
const pageErrors=[];
try{
  await serverReady();

  const open=async({hash,...rest})=>{
    const context=await browser.newContext({viewport:{width:1180,height:900},bypassCSP:true});
    await context.route('**/*',route=>{
      const target=route.request().url();
      if(target.startsWith(ORIGIN)&&!target.includes('/sw.js'))return route.continue();
      if(target.startsWith('https://cdn.jsdelivr.net/'))return route.continue();
      return route.abort();
    });
    await context.addInitScript(stub(rest));
    const page=await context.newPage();
    page.on('pageerror',error=>pageErrors.push(String(error)));
    await page.goto(`${ORIGIN}/index.html${hash}`,{waitUntil:'domcontentloaded'});
    await page.waitForSelector('#main',{timeout:30000});
    await page.waitForTimeout(2600);
    return {context,page};
  };
  /* The dialog lives in the profile menu (V368). It is opened by its own function rather than by
     hunting the menu, so this walk is about the button inside it, not about finding it. */
  const openJoinQrDialog=async page=>{
    const opened=await page.evaluate(()=>{
      if(typeof openBusinessQrModalV368!=='function')return false;
      openBusinessQrModalV368();return true;
    });
    if(!opened)throw new Error('openBusinessQrModalV368 is not reachable on this surface');
    await page.waitForSelector('#createJoinQr',{timeout:15000});
    await page.waitForTimeout(1600);
  };

  /* ---------------- 1. replacing a live QR must ask first ---------------- */
  say('1. Replace asks before it kills every printed copy');
  {
    const {context,page}=await open({hash:`#/workspace/${SLUG}/dashboard`,hasQr:true});
    await openJoinQrDialog(page);
    ok(!!(await page.$('#createJoinQr')),'the My Business QR dialog is open');
    const state=await page.evaluate(()=>{
      const b=document.querySelector('#createJoinQr');
      return {label:b.querySelector('span').textContent.trim(),cls:b.className};
    });
    ok(state.label==='Replace join QR',`with a live QR the button offers Replace (${state.label})`);
    /* THE EMPHASIS FIX: the destructive action is no longer the primary control of the row. */
    ok(/ghost/.test(state.cls),`and it is a quiet control, not the primary one (${state.cls})`);

    await page.click('#createJoinQr');
    await page.waitForTimeout(700);
    const confirm=await page.evaluate(()=>{
      const el=document.querySelector('#confirmActionOkV386');
      /* Two modals are stacked here; read the CONFIRMATION's own card, not the QR dialog's. */
      return el?el.closest('.modal-card').innerText.replace(/\s+/g,' '):'';
    });
    ok(!!confirm,'a confirmation is raised instead of rotating on the spot');
    ok(/printed/i.test(confirm)&&/stops working/i.test(confirm),
      `and it says what is actually lost (${confirm.slice(0,120)})`);
    ok((await page.evaluate(()=>window.__V597.rotations))===0,
      'nothing has been rotated while the question is on screen');

    /* Cancel must be a real cancel. */
    await page.click('#confirmActionCancelV386');
    await page.waitForTimeout(800);
    ok((await page.evaluate(()=>window.__V597.rotations))===0,
      'declining the confirmation leaves the live QR alone');
    const afterCancel=await page.evaluate(()=>({
      qrDialog:!!document.querySelector('#businessQrModalV368'),
      button:!!document.querySelector('#createJoinQr'),
      confirmGone:!document.querySelector('#confirmActionOkV386'),
      disabled:document.querySelector('#createJoinQr')?.disabled}));
    ok(afterCancel.confirmGone,'the question closes when declined');
    ok(afterCancel.qrDialog&&afterCancel.button,
      `and the QR dialog is still open behind it (${JSON.stringify(afterCancel)})`);
    ok(afterCancel.disabled===false,'with its button live, not left disabled by the cancelled press');

    /* And confirming still works — this is a guard, not a block. */
    await page.click('#createJoinQr');
    await page.waitForTimeout(600);
    await page.click('#confirmActionOkV386');
    await page.waitForTimeout(1600);
    ok((await page.evaluate(()=>window.__V597.rotations))===1,
      'confirming replaces the QR exactly once');
    await context.close();
  }

  /* ---------------- 2. a FIRST QR destroys nothing, so it must not nag ---------------- */
  say('2. generating a first QR still goes through on one tap');
  {
    const {context,page}=await open({hash:`#/workspace/${SLUG}/dashboard`,hasQr:false});
    await openJoinQrDialog(page);
    const state=await page.evaluate(()=>{
      const b=document.querySelector('#createJoinQr');
      return b?{label:b.querySelector('span').textContent.trim(),cls:b.className}:null;
    });
    ok(state&&state.label==='Generate join QR',`with no QR the button offers Generate (${state?.label})`);
    ok(state&&!/ghost/.test(state.cls),
      `and generating IS the primary action here (${state?.cls})`);
    await page.click('#createJoinQr');
    await page.waitForTimeout(1500);
    ok(!(await page.$('#confirmActionOkV386')),'no confirmation is raised — there is nothing to lose');
    ok((await page.evaluate(()=>window.__V597.rotations))===1,'and the first QR is created');
    await context.close();
  }

  /* ---------------- 3. the wallet white screen ---------------- */
  say('3. an empty wallet payload shows a retry, not a blank page');
  {
    const {context,page}=await open({hash:`#/wallet/${SLUG}`,customer:true,summary:'null'});
    const text=await page.evaluate(()=>(document.body.innerText||'').replace(/\s+/g,' ').trim());
    ok(text.length>0,'the page painted something at all');
    ok(/could not be loaded/i.test(text),
      `and says the business could not be loaded (${text.slice(0,120)})`);
    ok(pageErrors.length===0,
      `with no uncaught TypeError mid-render (${pageErrors.join(' | ')})`);
    await context.close();
  }

  /* ---------------- 4. the healthy wallet is untouched ---------------- */
  say('4. a normal wallet payload still renders normally');
  {
    const {context,page}=await open({hash:`#/wallet/${SLUG}`,customer:true,summary:'present'});
    const text=await page.evaluate(()=>(document.body.innerText||'').replace(/\s+/g,' ').trim());
    ok(/Jess Salon/.test(text),`the business renders as before (${text.slice(0,90)})`);
    ok(!/could not be loaded/i.test(text),'and the new guard does not fire on a good payload');
    await context.close();
  }

  ok(pageErrors.length===0,
    `no uncaught page errors across the walk (${pageErrors.length}${pageErrors.length?': '+pageErrors.join(' | '):''})`);
  process.stdout.write('\nV597 join QR + wallet guard: all steps passed\n');
}catch(error){
  process.stdout.write(`\nFAILED: ${error.message}\n`);
  if(pageErrors.length)process.stdout.write(`page errors:\n  ${pageErrors.join('\n  ')}\n`);
  process.exitCode=1;
}finally{
  await browser.close();
  if(server)server.kill();
}
