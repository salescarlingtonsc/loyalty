/* nestly_v456 (audit A, A-REG-013) — one address, one Staff Members page.
 *
 * THE BUG (audit A, 2026-08-22, measured at 1180 and 599). '#/staffmembers' and
 * '#/settings?tab=team' rendered two different pages, and they were not independent:
 * staffMembersPage() calls settingsPage() and then enhances the result, while settingsPage's own
 * selectSettingsTab() replaceState()s the address to '#/settings?tab=team' the instant the panel
 * opens. So the rail's click rewrote the URL to the variant that LOSES the sub-tabs and the
 * honestly-labelled "Import from Excel" control — reload or bookmark and the capability was gone,
 * with nothing to say a better page existed. The raw hash also rendered a state nobody designed:
 * #settab-team is `hidden` in the markup and nothing unhides it, so the team panel appeared under
 * a tab strip whose only visible tab said "Modules & plan".
 * Owner ruling 2026-08-22: the ENHANCED variant is canonical.
 *
 * WHAT THIS FILE PROVES, BY BOOTING THE REAL APP — real bundles, real router, real
 * settingsPage/staffMembersPage, an in-page fixture Supabase, and a real Chrome:
 *   1. via the rail hash '#/staffmembers': the enhanced page, and the address is LEFT ALONE
 *      (this is the replaceState regression itself under test).
 *   2. via the bookmarked hash '#/settings?tab=team', entered COLD: the same page.
 *   3. the two renders expose the SAME control set — compared as sets, so a control that exists
 *      on only one door fails regardless of which door gained or lost it.
 *   4. "Import from Excel" and the per-row actions are present on BOTH.
 *   5. ONE vocabulary: no control anywhere on either render says "Add staff without app access",
 *      and "Add staff" names exactly one control.
 *   6. round trip — rail click, then reload whatever address the app left in the bar — still the
 *      enhanced page. This is the owner's actual sequence, and it is what used to break.
 *   7. the OTHER settings tabs keep their deep-linkable ?tab= address, unchanged.
 *
 * Run:
 *   PLAYWRIGHT_MODULE="<...>/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v456-staff-members-one-page.mjs
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
const PORT=Number(process.env.V456_PORT||4456);
const ORIGIN=`http://127.0.0.1:${PORT}`;

/* index.html loads the GENERATED surface chunks, never app/app.js, so a browser test served
   straight out of app/ would run the last-stamped bundle and prove nothing about an edit made
   since. Committed chunks are the release step's business (never this test's), so the chunks are
   rendered from the current app/app.js into a throwaway directory and THAT is what gets served.
   build() is pure — it returns the bytes and writes nothing — so the worktree is untouched. */
const buildServedTree=async()=>{
  const dir=await mkdtemp(path.join(tmpdir(),'v456-app-'));
  await cp(path.join(REPO_ROOT,'app'),dir,{recursive:true});
  const {chunks,stamped}=await build(REPO_ROOT);
  for(const [surface,target] of Object.entries(OUTPUTS)){
    await writeFile(path.join(dir,path.basename(target)),chunks[surface]);
  }
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
/* Serving SOMETHING is not serving THIS build — a sibling worktree's server on this port would
   silently prove the wrong tree. The v456 team redirect, in the chunk the browser actually runs,
   is the marker. */
const MARKER="requestedSettingsTab==='team')return nav('#/staffmembers')";
const probe=async()=>{
  try{
    const response=await fetch(`${ORIGIN}/app-business.js`);
    if(!response.ok)return false;
    return (await response.text()).includes(MARKER);
  }catch{return false}
};
const serverReady=async()=>{
  if(await probe())throw new Error(
    `something is already serving ${ORIGIN}; this test needs the port to itself so it can serve `
    +'chunks freshly built from app/app.js');
  const dir=await buildServedTree();
  server=spawn('python3',['-m','http.server',String(PORT),'--bind','127.0.0.1'],{cwd:dir,stdio:'ignore'});
  for(let i=0;i<80;i++){if(await probe())return;await new Promise(r=>setTimeout(r,100))}
  throw new Error(`static server did not start on ${ORIGIN}, or the built chunk lacks the v456 marker`);
};

const BIZ='b4560000-0000-4000-8000-000000000456';
const SLUG='v456co';
const ownerStub=`(()=>{
  const BIZ='${BIZ}',SLUG='${SLUG}';
  const MODULES=['loyalty','clients','sales','services','till','bookings','reports','inventory',
    'packages','staffperf','branches','staffmembers','settings','setup'];
  const bizRow={id:BIZ,slug:SLUG,name:'V456 Co',currency:'SGD',industry:'fnb',points_mode:'both',
    enabled_modules:MODULES,join_enabled:true,brand_color:'#b8562a',created_at:'2026-01-01T00:00:00Z'};
  const staff=[
    {id:'st1',business_id:BIZ,full_name:'Owner Person',role:'owner',user_id:'u-owner',active:true,
     email:'owner@v456.co',phone:'81110000',title:'Owner',module_perms:null,modules:null,
     commission_service_bps:null,commission_product_bps:null,created_at:'2026-01-01T00:00:00Z'},
    {id:'st2',business_id:BIZ,full_name:'Siti Rahmah',role:'staff',user_id:null,active:true,
     email:'',phone:'82220000',title:'Barista',module_perms:{till:'rw'},modules:['till'],
     commission_service_bps:500,commission_product_bps:200,created_at:'2026-02-01T00:00:00Z'}];
  const TABLES={
    businesses:[bizRow],
    branches:[{id:'br1',business_id:BIZ,name:'Main',active:true,is_default:true,billing_state:'active'}],
    staff,staff_invites:[],staff_hours:[],staff_branches:[],staff_services:[],
    services:[],products:[],clients:[],sales:[],appointments:[],module_registry:[],
    module_templates:[],loyalty_programs:[],branch_hours:[]
  };
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
  const query=table=>chainable(q=>{
    const rows=(TABLES[table]||[]).slice();
    if(q.op!=='select')return {data:null,error:null};
    if(q.countMode&&q.head)return {data:null,count:rows.length,error:null};
    if(q.single)return {data:rows[0]??null,error:null};
    return {data:rows,count:q.countMode?rows.length:null,error:null};
  });
  const rpcData=name=>{
    switch(name){
      case 'get_my_personas':return {staff:[{business_id:BIZ,business_slug:SLUG,business_name:'V456 Co',
        role:'owner',modules:MODULES}],customer:[],default_route:'#/workspace/'+SLUG+'/dashboard'};
      case 'platform_get_business_control_v94':return {workspace_access:true,quick_earn_catalogue_enabled:true};
      case 'get_my_modules':case 'get_my_modules_at_v115':return {role:'owner',is_super_admin:false,
        modules:MODULES,capabilities:[],module_perms:Object.fromEntries(MODULES.map(m=>[m,'rw']))};
      case 'get_customer_feature_capabilities':return {customer_wallet:true,customer_phone_registration:false};
      case 'get_workspace_locale_preference_v97':return {locale:'en',version:1};
      case 'get_notifications':return {unread:0,items:[]};
      case 'get_business_billing_v125':return {plan:'standard',seats_used:1,seats_included:1,
        monthly_cents:2500,status:'active',currency:'SGD'};
      case 'get_programmes_v314':case 'business_get_programmes_v314':
        return {programmes:[],programmes_contract:'v391'};
      default:return null;
    }
  };
  const rpc=name=>chainable(()=>({data:rpcData(name),error:null}));
  const channel=()=>{const c={on:()=>c,subscribe:()=>c,unsubscribe:()=>{}};return c};
  const auth=new Proxy({
    getSession:async()=>({data:{session:{user:{id:'u-owner',email:'owner@v456.co'}}},error:null}),
    getUser:async()=>({data:{user:{id:'u-owner',email:'owner@v456.co'}},error:null}),
    onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
    signOut:async()=>({error:null})
  },{get:(t,k)=>k in t?t[k]:async()=>({data:null,error:null})});
  const client={from:query,rpc,auth,channel,removeChannel(){},
    functions:{invoke:async()=>({data:null,error:null})},
    storage:{from:()=>({getPublicUrl:()=>({data:{publicUrl:''}})})}};
  Object.defineProperty(window,'supabase',{value:{createClient:()=>client},writable:false,configurable:false});
})();`;

/* Everything an owner can see and press on the rendered page, plus the identity of the page. */
const READ=`(()=>{
  const main=document.querySelector('#main');
  if(!main)return {missing:true};
  const visible=el=>typeof el.checkVisibility==='function'
    ?el.checkVisibility({checkVisibilityCSS:true,contentVisibilityAuto:true})
      &&el.getBoundingClientRect().width>0
    :getComputedStyle(el).display!=='none';
  const label=el=>(el.getAttribute('aria-label')||el.textContent||'').replace(/\\s+/g,' ').trim();
  /* Sub-tab panels are hidden one at a time by design, so every panel is opened before the
     inventory is taken — otherwise "the same controls" would only mean "the same first tab". */
  main.querySelectorAll('.staff-members-tab-panel').forEach(panel=>{panel.hidden=false});
  main.querySelectorAll('details').forEach(node=>{node.open=true});
  const controls=[...main.querySelectorAll('button,a[href],input,select')]
    .filter(visible).map(label).filter(Boolean);
  return {
    hash:location.hash,
    h1:(main.querySelector('h1')||{}).textContent||'',
    enhanced:!!main.querySelector('.staff-members-toolbar,[data-staff-tab]'),
    staffTabs:[...main.querySelectorAll('[data-staff-tab]')].map(label),
    controls,
    text:(main.innerText||'').replace(/\\s+/g,' ')
  };
})()`;

const browser=await chromium.launch({
  headless:true,
  executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
});
const pageErrors=[];
try{
  await serverReady();
  const context=await browser.newContext({viewport:{width:1180,height:900},bypassCSP:true});
  await context.route('**/*',route=>{
    const url=route.request().url();
    if(url.startsWith(ORIGIN)&&!url.includes('/sw.js'))return route.continue();
    return route.abort();
  });
  await context.addInitScript(ownerStub);
  const page=await context.newPage();
  page.on('pageerror',error=>pageErrors.push(String(error)));

  /* Every visit is COLD: a full document load, not a hash flip, because the bug is about what a
     reload or a bookmark produces. */
  const openCold=async hash=>{
    await page.goto(`${ORIGIN}/index.html${hash}`,{waitUntil:'domcontentloaded'});
    await page.waitForFunction(()=>{
      const main=document.querySelector('#main');
      return !!main&&/Staff|Team|Settings/.test(main.innerText||'');
    },null,{timeout:30000});
    await page.waitForTimeout(1200);
    return page.evaluate(READ);
  };

  say('1. the rail hash renders the enhanced page and keeps its own address');
  const viaRail=await openCold('#/staffmembers');
  ok(!viaRail.missing,'the page rendered');
  ok(viaRail.enhanced,'#/staffmembers is the enhanced Staff Members page');
  ok(viaRail.h1.trim()==='Staff Members',`its heading is "Staff Members" (got "${viaRail.h1.trim()}")`);
  ok(viaRail.hash.startsWith('#/staffmembers'),
    `and the address still says #/staffmembers — it is no longer rewritten to the weaker hash (got ${viaRail.hash})`);

  say('2. the bookmarked hash, entered cold, renders the SAME page');
  const viaBookmark=await openCold('#/settings?tab=team');
  ok(viaBookmark.enhanced,'#/settings?tab=team is the enhanced page too, not the raw settings card');
  ok(viaBookmark.h1.trim()==='Staff Members',
    `its heading is "Staff Members" (got "${viaBookmark.h1.trim()}")`);
  ok(viaBookmark.hash.startsWith('#/staffmembers'),
    `and it landed on the canonical address (got ${viaBookmark.hash})`);

  say('3. both doors expose exactly the same control set');
  const railSet=new Set(viaRail.controls),bookmarkSet=new Set(viaBookmark.controls);
  const onlyRail=[...railSet].filter(c=>!bookmarkSet.has(c));
  const onlyBookmark=[...bookmarkSet].filter(c=>!railSet.has(c));
  ok(onlyRail.length===0,`nothing is reachable ONLY from the rail (${JSON.stringify(onlyRail)})`);
  ok(onlyBookmark.length===0,`nothing is reachable ONLY from the bookmark (${JSON.stringify(onlyBookmark)})`);
  ok(railSet.size>0,`and the comparison is not vacuous — ${railSet.size} controls compared`);

  say('4. the controls that used to disappear are present on both');
  for(const [name,render] of [['rail',viaRail],['bookmark',viaBookmark]]){
    ok(render.controls.includes('Import from Excel'),
      `${name}: "Import from Excel" is present (this is what a reload used to lose)`);
    ok(render.controls.includes('Add staff'),`${name}: "Add staff" is present`);
    ok(render.staffTabs.length===2,
      `${name}: both sub-tabs are rendered (${JSON.stringify(render.staffTabs)})`);
    for(const rowAction of ['Modules','Deactivate','Delete']){
      ok(render.controls.includes(rowAction),`${name}: the per-row "${rowAction}" action is present`);
    }
  }

  say('5. one vocabulary — the same job is not called two different things');
  for(const [name,render] of [['rail',viaRail],['bookmark',viaBookmark]]){
    ok(!render.text.includes('Add staff without app access'),
      `${name}: the old second name for the importer is gone from the page text`);
    ok(!render.controls.some(c=>c==='Add staff without app access'),
      `${name}: ...and from its controls`);
    const addStaffControls=render.controls.filter(c=>c==='Add staff');
    ok(addStaffControls.length===1,
      `${name}: "Add staff" names exactly one control (found ${addStaffControls.length})`);
  }

  say('6. round trip — rail click, then reload whatever address the app left behind');
  await page.goto(`${ORIGIN}/index.html#/dashboard`,{waitUntil:'domcontentloaded'});
  await page.waitForSelector('#main',{timeout:30000});
  await page.waitForTimeout(1500);
  await page.evaluate(()=>{
    const link=[...document.querySelectorAll('a[href]')]
      .find(a=>a.getAttribute('href')==='#/staffmembers');
    if(!link)throw new Error('the rail has no Staff Members link to click');
    link.click();
  });
  await page.waitForFunction(()=>/Staff Members/.test(document.querySelector('#main')?.innerText||''),
    null,{timeout:30000});
  await page.waitForTimeout(1200);
  const afterClick=await page.evaluate(READ);
  ok(afterClick.enhanced,'clicking the rail link gives the enhanced page');
  const parkedAddress=afterClick.hash;
  const reloaded=await openCold(parkedAddress);
  ok(reloaded.enhanced,
    `reloading the address the app parked (${parkedAddress}) still gives the enhanced page`);
  ok(reloaded.controls.includes('Import from Excel'),
    '...with Import from Excel intact — the exact capability the owner used to lose on refresh');

  say('7. the other Settings tabs keep their own deep-linkable address');
  const modules=await openCold('#/settings?tab=modules');
  ok(!modules.enhanced,'#/settings?tab=modules is still the Settings page, not Staff Members');
  ok(modules.hash.includes('#/settings'),
    `and it keeps a #/settings address (got ${modules.hash})`);
  const bare=await openCold('#/settings');
  ok(!bare.enhanced,'#/settings itself is still the Settings page');

  ok(pageErrors.length===0,`no uncaught page errors (${pageErrors.length}${pageErrors.length?': '+pageErrors.join(' | '):''})`);
  await context.close();
  process.stdout.write('\nV456 staff members one-page: all steps passed\n');
}catch(error){
  process.stdout.write(`\nFAILED: ${error.message}\n`);
  if(pageErrors.length)process.stdout.write(`page errors:\n  ${pageErrors.join('\n  ')}\n`);
  process.exitCode=1;
}finally{
  await browser.close();
  if(server)server.kill();
}
