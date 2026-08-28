/* nestly_v588/v589 — the staff reference-code sign-up, walked in a real browser.
 *
 * The owner's report was about the JOURNEY, not one RPC: "even using the reference code to sign
 * up as staff, during sign up process - it is in a mess." The server half is proven against
 * production by the rolled-back suite; this file proves the half a person actually touches, by
 * booting the real bundles built from the current app.js in a real Chrome with a fixture Supabase:
 *
 *   1. a signed-out arrival is offered the door at all (#authStaffInviteDoorV588 on the business
 *      auth screen — before v588 the only way in was a link somebody had to send you).
 *   2. landing on the invite LINK (/?staff_invite=CODE) carries the code into the form itself,
 *      so nobody retypes an 8-character code off a phone screen.
 *   3. the preview names the business and the role before any account is created.
 *   4. accepting navigates INTO the named workspace and never corrupts S.biz with accept_invite's
 *      own payload — the v588 defect that left the whole app pointing at a business-shaped object
 *      with no id, whose only visible symptom was that everything afterwards was broken.
 *   5. a replay (the same person pressing it twice) reads as a welcome, not an accusation.
 *   6. a code that already parked someone for approval previews as waiting, not as invalid —
 *      the single most confusing screen in the old flow.
 *   7. no uncaught page errors anywhere in the walk.
 *
 * Run:
 *   PLAYWRIGHT_MODULE="<repo>/node_modules/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v589-staff-signup-walkthrough.mjs
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
const PORT=Number(process.env.V589_PORT||4589);
const ORIGIN=`http://127.0.0.1:${PORT}`;
const MARKER='authStaffInviteDoorV588';

const buildServedTree=async()=>{
  const dir=await mkdtemp(path.join(tmpdir(),'v589-app-'));
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
  throw new Error('server did not start, or the built chunk lacks the v588 invite door');
};

const CODE='L98KLE3A';
const SLUG='qa-kopi-lab';
const BIZ='b5890000-0000-4000-8000-000000000589';

/* `session` decides signed-in vs signed-out; `preview`/`accept` are exactly what the two RPCs
   return, so each screen is driven by a real server answer rather than a shortcut. */
const stub=({session,preview,accept})=>`(()=>{
  const AUD={rpcCalls:[],navs:[],toasts:[]};
  window.__V589=AUD;
  const SESSION=${JSON.stringify(session)};
  const PREVIEW=${JSON.stringify(preview)};
  const ACCEPT=${JSON.stringify(accept)};
  const MODULES=['dashboard','till','clients','sales','services','loyalty','reports','settings'];
  const bizRow={id:'${BIZ}',slug:'${SLUG}',name:'QA Kopi Lab (Bedok)',currency:'SGD',industry:'fnb',
    enabled_modules:MODULES,created_at:'2026-01-01T00:00:00Z'};
  const TABLES={businesses:[bizRow],
    branches:[{id:'br1',business_id:'${BIZ}',name:'Main',active:true,is_default:true,billing_state:'active'}],
    staff:[{id:'st1',business_id:'${BIZ}',full_name:'V589 Probe Teammate',role:'staff',
      user_id:'u-newbie',active:true,access_state:'pending',modules:null,module_perms:null}],
    clients:[],sales:[],points_ledger:[],appointments:[],memberships:[],client_packages:[],
    services:[],products:[],module_registry:[],business_programmes:[]};
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
  const rpcData=(name,args)=>{
    switch(name){
      case 'preview_staff_invite':return PREVIEW;
      case 'accept_invite':
        if(ACCEPT&&ACCEPT.__error)return {__error:ACCEPT.__error};
        return ACCEPT;
      case 'get_my_personas':return {staff:SESSION?[{business_id:'${BIZ}',business_slug:'${SLUG}',
        business_name:'QA Kopi Lab (Bedok)',role:'staff',modules:MODULES,access_state:'pending'}]:[],
        customer:[],default_route:'#/workspace/${SLUG}/dashboard'};
      case 'get_my_modules':case 'get_my_modules_at_v115':return {role:'staff',is_super_admin:false,
        modules:MODULES,capabilities:[],module_perms:Object.fromEntries(MODULES.map(m=>[m,'rw']))};
      case 'platform_get_business_control_v94':return {workspace_access:true};
      case 'get_customer_feature_capabilities':return {customer_wallet:true};
      case 'get_workspace_locale_preference_v97':return {locale:'en',version:1};
      case 'get_notifications':return {unread:0,items:[]};
      case 'get_dashboard_summary_v155':return {revenue_cents:0,visits:0,new_customers:0,
        visits_by_weekday:[0,0,0,0,0,0,0],points_issued:0,revenue_by_day:[],availability:{}};
      default:return null;
    }
  };
  const rpc=(name,args)=>{
    AUD.rpcCalls.push({name,args:args||null});
    return chainable(()=>{
      const out=rpcData(name,args);
      if(out&&out.__error)return {data:null,error:{message:out.__error}};
      return {data:out,error:null};
    },'rpc:'+name);
  };
  const channel=()=>{const c={on:()=>c,subscribe:()=>c,unsubscribe:()=>{}};return c};
  const auth=new Proxy({
    getSession:async()=>({data:{session:SESSION?{user:SESSION}:null},error:null}),
    getUser:async()=>({data:{user:SESSION||null},error:null}),
    onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
    signOut:async()=>({error:null})
  },{get:(t,k)=>k in t?t[k]:async()=>({data:null,error:null})});
  const client={from:query,rpc,auth,channel,removeChannel(){},
    functions:{invoke:async()=>({data:null,error:null})},
    storage:{from:()=>({getPublicUrl:()=>({data:{publicUrl:''}})})}};
  Object.defineProperty(window,'supabase',{value:{createClient:()=>client},writable:false,configurable:false});
  /* Record where the app decides to go, without letting a hashchange tear the page down mid-assert. */
  addEventListener('hashchange',()=>AUD.navs.push(location.hash));
})();`;

const VALID_PREVIEW={status:'valid',business_name:'QA Kopi Lab (Bedok)',role:'staff',restricted_email:null};
const WAITING_PREVIEW={status:'awaiting_approval',business_name:'QA Kopi Lab (Bedok)',role:'staff'};
const NEWBIE={id:'u-newbie',email:'qa-golive@example.invalid'};

const browser=await chromium.launch({headless:true,
  executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
const pageErrors=[];
try{
  await serverReady();

  const open=async({session=null,preview=VALID_PREVIEW,accept=null,url='/index.html'})=>{
    const context=await browser.newContext({viewport:{width:430,height:900},bypassCSP:true});
    await context.route('**/*',route=>{
      const target=route.request().url();
      if(target.startsWith(ORIGIN)&&!target.includes('/sw.js'))return route.continue();
      if(target.startsWith('https://cdn.jsdelivr.net/'))return route.continue();
      return route.abort();
    });
    await context.addInitScript(stub({session,preview,accept}));
    const page=await context.newPage();
    page.on('pageerror',error=>pageErrors.push(`${url}: ${error}`));
    await page.goto(`${ORIGIN}${url}`,{waitUntil:'domcontentloaded'});
    try{await page.waitForSelector('#main',{timeout:30000})}
    catch(error){
      const dump=await page.evaluate(()=>({html:(document.body.innerHTML||'').slice(0,900),
        text:(document.body.innerText||'').slice(0,400)}));
      throw new Error(`#main never appeared. errors=${JSON.stringify(pageErrors)} text=${dump.text} html=${dump.html}`);
    }
    await page.waitForTimeout(2200);
    return {context,page};
  };
  const textOf=page=>page.evaluate(()=>(document.body.innerText||'').replace(/\s+/g,' '));

  /* ---- 1. the door exists for someone who was only handed a code ---- */
  say('1. a signed-out arrival is offered a way in with just a code');
  {
    const {context,page}=await open({url:'/index.html#/business'});
    const door=await page.$('#authStaffInviteDoorV588');
    ok(!!door,'the business auth screen offers "Joining a team? Enter your staff invite code"');
    await door.click();
    await page.waitForTimeout(600);
    const text=await textOf(page);
    ok(text.includes('Join an existing business'),'clicking it opens the join screen');
    ok(!!(await page.$('#staffInviteCodeV151')),'with a field for the company invite code');
    await context.close();
  }

  /* ---- 2 + 3. the LINK carries the code, and the preview names the business ---- */
  say('2. the invite link fills the code in, and previews the business before any account exists');
  {
    const {context,page}=await open({url:`/index.html?staff_invite=${CODE}#/business`});
    /* A signed-out arrival ON THE LINK skips the door entirely: route() sees the code and opens
       the join screen directly, which is the point of sending a link. */
    if(!(await page.$('#staffInviteCodeV151'))){
      const door=await page.$('#authStaffInviteDoorV588');
      ok(!!door,'the door is offered when the link did not open the join screen outright');
      await door.click();
      await page.waitForTimeout(800);
    }else{
      ok(true,'the invite link opens the join screen directly — no door to hunt for');
    }
    const value=await page.$eval('#staffInviteCodeV151',el=>el.value);
    ok(value===CODE,`the code from the link is already in the field (${value||'empty'})`);
    const preview=await page.evaluate(()=>document.querySelector('#staffInvitePreviewV151')?.innerText||'');
    ok(/QA Kopi Lab/.test(preview),`the preview names the business (${preview.replace(/\s+/g,' ').trim()})`);
    ok(/staff|Team member/i.test(preview),'and the role being offered');
    await context.close();
  }

  /* ---- 4. accepting lands INSIDE the workspace, and S.biz survives ---- */
  say('4. accepting navigates into the named workspace and never corrupts S.biz');
  {
    const {context,page}=await open({session:NEWBIE,url:`/index.html?staff_invite=${CODE}#/business`,
      accept:{status:'awaiting_approval',business_id:BIZ,business_slug:SLUG,
        business_name:'QA Kopi Lab (Bedok)',message:'Your request has been sent. You can sign in once the owner approves it.'}});
    const text=await textOf(page);
    ok(text.includes('Join business workspace'),'a signed-in arrival gets the accept screen, not the code form again');
    ok(text.includes(CODE),'which shows the code it is about to use');
    const go=await page.$('#staffInviteAcceptGo');
    ok(!!go,'and a single "Join business" button');
    await go.click();
    await page.waitForTimeout(1800);
    const audit=await page.evaluate(()=>window.__V589);
    ok(audit.rpcCalls.some(c=>c.name==='accept_invite'&&c.args?.p_code===CODE),
      'the button calls accept_invite with the code');
    const landed=await page.evaluate(()=>location.hash);
    ok(landed===`#/workspace/${SLUG}/dashboard`,
      `it lands in the named workspace rather than a dead end (${landed})`);
    /* THE v588 DEFECT: `S.biz=data` replaced the business with accept_invite's own payload — an
       object with a business_id but no id, which every later screen then read. */
    const biz=await page.evaluate(()=>{
      const s=window.S||{};const b=s.biz;
      return b?{hasId:!!b.id,hasStatus:'status' in b,hasMessage:'message' in b}:null;
    });
    ok(biz===null||(!biz.hasStatus&&!biz.hasMessage),
      `S.biz was never overwritten with the accept payload (${JSON.stringify(biz)})`);
    await context.close();
  }

  /* ---- 5. pressing it twice is a welcome, not an accusation ---- */
  say('5. the same person replaying their own code is welcomed back');
  {
    const {context,page}=await open({session:NEWBIE,url:`/index.html?staff_invite=${CODE}#/business`,
      preview:WAITING_PREVIEW,
      accept:{status:'approved',business_id:BIZ,business_slug:SLUG,business_name:'QA Kopi Lab (Bedok)',
        replayed:true,message:'You are already on this team. Opening the workspace.'}});
    await (await page.$('#staffInviteAcceptGo')).click();
    await page.waitForTimeout(1800);
    const text=await textOf(page);
    ok(!/already been used/i.test(text),'no "this code has already been used" accusation');
    ok(!/not active/i.test(text),'and the client did not refuse the code before the server saw it');
    const landed=await page.evaluate(()=>location.hash);
    ok(landed===`#/workspace/${SLUG}/dashboard`,`the replay opens the workspace too (${landed})`);
    await context.close();
  }

  /* ---- 6. a parked code reads as waiting, not broken ---- */
  say('6. a code that already parked someone previews as waiting, not invalid');
  {
    const {context,page}=await open({session:NEWBIE,url:`/index.html?staff_invite=${CODE}#/business`,
      preview:WAITING_PREVIEW,accept:null});
    const preview=await page.evaluate(()=>document.querySelector('#staffInviteAcceptPreviewV151')?.innerText||'');
    ok(/QA Kopi Lab/.test(preview),'the parked code still names the business');
    ok(!/invalid|expired|revoked/i.test(preview),
      `and is not called invalid (${preview.replace(/\s+/g,' ').trim()})`);
    ok(/approv|wait/i.test(preview),'it says an approval is pending');
    await context.close();
  }

  ok(pageErrors.length===0,
    `no uncaught page errors across the whole walk (${pageErrors.length}${pageErrors.length?': '+pageErrors.join(' | '):''})`);
  process.stdout.write('\nV589 staff sign-up walkthrough: all steps passed\n');
}catch(error){
  process.stdout.write(`\nFAILED: ${error.message}\n`);
  if(pageErrors.length)process.stdout.write(`page errors:\n  ${pageErrors.join('\n  ')}\n`);
  process.exitCode=1;
}finally{
  await browser.close();
  if(server)server.kill();
}
