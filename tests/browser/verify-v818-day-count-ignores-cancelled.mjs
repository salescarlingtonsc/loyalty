/* nestly_v818 — owner photo 5, measured in a real Chrome.
 *
 * The photo rings the Day view's per-member header: Amanda reads "1 appointment" while the only
 * thing in her column is a struck-through, cancelled 20:00–21:00 booking. Owner: "since
 * appointment is cancelled it should not show (1) - it should fall back to (0)".
 *
 * WHY THIS FILE EXISTS. The fix is one expression inside a template literal in a render function
 * that no unit test executes. `node --check` proves it parses; grepping the served bundle proves
 * the letters shipped. Neither proves the header now says 0 — see the repo's own lesson that a
 * source-regex test stays green while the behaviour is dead. So this boots the REAL business
 * bundle, built from the current app/app.js, against a stub Supabase holding exactly the shape in
 * the photo, and reads the header text off the rendered page.
 *
 * WHAT IT ASSERTS
 *   1. A member whose only appointment that day is CANCELLED reads "0 appointments".
 *   2. The cancelled booking is still DRAWN — v288 keeps it as a struck-through ghost so staff can
 *      see what was called off. A fix that made the count right by hiding the row would be a
 *      different, worse bug, so the tile is required to still be there.
 *   3. A member with one BOOKED appointment still reads "1 appointment" — the singular, and proof
 *      the counter was not simply zeroed.
 *   4. A member with one booked and one cancelled reads "1 appointment", not 2 and not 0.
 *   5. No uncaught page errors.
 *
 * NEGATIVE CONTROL. Run with V818_NEGATIVE=1 and the harness builds the served chunks from
 * app/app.js as it was in the commit BEFORE the fix (git show <base>:app/app.js). Assertions 1
 * and 4 must FAIL there, which is what makes a pass here mean something. The recorded run:
 *   pre-fix   cancelled-only "1 appointment"   booked+cancelled "2 appointments"
 *   post-fix  cancelled-only "0 appointments"  booked+cancelled "1 appointment"
 *
 * Run:
 *   PLAYWRIGHT_MODULE=/Users/cs/Downloads/loyalty-v577/node_modules/playwright-core/index.js \
 *   node tests/browser/verify-v818-day-count-ignores-cancelled.mjs
 */
import {spawn,execFileSync} from 'node:child_process';
import {cp,mkdtemp,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {OUTPUTS} from '../../scripts/quality/split-app-bundle.mjs';
import {build} from '../../scripts/quality/stamp-app-bundle.mjs';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;

const REPO_ROOT=fileURLToPath(new URL('../../',import.meta.url));
const PORT=Number(process.env.V818_PORT||4818);
const ORIGIN=`http://127.0.0.1:${PORT}`;
const NEGATIVE=process.env.V818_NEGATIVE==='1';
const BASE_REF=process.env.V818_BASE_REF||'52b90654^';

/* index.html loads the GENERATED surface chunks, never app/app.js, so serving app/ straight out
   of the worktree would run the last-stamped bundle and prove nothing about the current edit.
   build() is pure — it returns bytes and writes nothing — so the worktree is untouched. */
const buildServedTree=async()=>{
  const dir=await mkdtemp(path.join(tmpdir(),'v818-app-'));
  await cp(path.join(REPO_ROOT,'app'),dir,{recursive:true});
  let root=REPO_ROOT;
  if(NEGATIVE){
    /* The negative control needs the PRE-FIX app.js compiled by the CURRENT splitter, so the only
       difference between the two runs is the one expression under test. */
    root=await mkdtemp(path.join(tmpdir(),'v818-base-'));
    await cp(path.join(REPO_ROOT,'app'),path.join(root,'app'),{recursive:true});
    await cp(path.join(REPO_ROOT,'scripts'),path.join(root,'scripts'),{recursive:true});
    const before=execFileSync('git',['show',`${BASE_REF}:app/app.js`],
      {cwd:REPO_ROOT,encoding:'utf8',maxBuffer:64*1024*1024});
    await writeFile(path.join(root,'app/app.js'),before);
  }
  const {chunks,stamped}=await build(root);
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
/* Serving SOMETHING is not serving THIS build: a sibling worktree's server on this port would
   silently prove the wrong tree. */
const probe=async()=>{
  try{
    const response=await fetch(`${ORIGIN}/app-business.js`);
    if(!response.ok)return false;
    const text=await response.text();
    return NEGATIVE?!text.includes('liveCountV818'):text.includes('liveCountV818');
  }catch{return false}
};
const serverReady=async()=>{
  const dir=await buildServedTree();
  server=spawn('python3',['-m','http.server',String(PORT),'--bind','127.0.0.1'],{cwd:dir,stdio:'ignore'});
  for(let i=0;i<120;i++){if(await probe())return;await new Promise(r=>setTimeout(r,100))}
  throw new Error(`static server did not start on ${ORIGIN}, or the built chunk is the wrong tree `
    +`(expected liveCountV818 to be ${NEGATIVE?'ABSENT':'PRESENT'})`);
};

const BIZ='b8180000-0000-4000-8000-000000000818';
const SLUG='v818co';
/* Fixed local day so the fixture never straddles midnight in Singapore. */
const DAY=new Date(Date.now()+2*86400000).toISOString().slice(0,10);

const ownerStub=`(()=>{
  const BIZ='${BIZ}',SLUG='${SLUG}',DAY='${DAY}';
  const MODULES=['loyalty','clients','sales','services','till','bookings','appointments','reports',
    'inventory','packages','staffperf','branches','staffmembers','settings','setup'];
  const at=(h,m)=>DAY+'T'+String(h).padStart(2,'0')+':'+String(m).padStart(2,'0')+':00+08:00';
  const bizRow={id:BIZ,slug:SLUG,name:'V818 Co',currency:'SGD',industry:'beauty',points_mode:'both',
    enabled_modules:MODULES,join_enabled:true,brand_color:'#b8562a',created_at:'2026-01-01T00:00:00Z'};
  /* Three members, each isolating one case the header must get right. */
  const staff=[
    {id:'st-cancel',business_id:BIZ,full_name:'Cancelled Only',role:'staff',user_id:null,active:true,
     title:'Therapist',calendar_color:'#C63B31',customer_bookable:true,created_at:'2026-01-01T00:00:00Z'},
    {id:'st-booked',business_id:BIZ,full_name:'Booked Only',role:'staff',user_id:null,active:true,
     title:'Therapist',calendar_color:'#2f6f4f',customer_bookable:true,created_at:'2026-01-01T00:00:00Z'},
    {id:'st-mixed',business_id:BIZ,full_name:'Mixed Day',role:'staff',user_id:null,active:true,
     title:'Therapist',calendar_color:'#3b5ea8',customer_bookable:true,created_at:'2026-01-01T00:00:00Z'}];
  const svc={id:'svc1',business_id:BIZ,name:'Signature Massage',price_cents:8800,duration_min:60,active:true};
  const cli={id:'cl1',business_id:BIZ,full_name:'Kiat Ke Ying',phone:'81863833'};
  const appt=(id,staff_id,status,h)=>({id,business_id:BIZ,branch_id:'br1',client_id:'cl1',
    service_id:'svc1',staff_id,status,starts_at:at(h,0),ends_at:at(h+1,0),note:null,
    clients:{full_name:'Kiat Ke Ying'},services:{name:'Signature Massage',duration_min:60}});
  const TABLES={
    businesses:[bizRow],
    branches:[{id:'br1',business_id:BIZ,name:'Main',active:true,is_default:true,billing_state:'active'}],
    branch_hours:[0,1,2,3,4,5,6].map(d=>({business_id:BIZ,branch_id:'br1',weekday:d,
      opens:'10:00',closes:'21:00',closed:false})),
    staff,staff_invites:[],staff_hours:[],staff_services:[],
    /* branchStaff() builds the Day view's columns from staff_branches, so a member with no row
       here has no column at all and their appointments fall into Unassigned. */
    staff_branches:staff.map(s=>({business_id:BIZ,staff_id:s.id,branch_id:'br1'})),
    services:[svc],products:[],clients:[cli],sales:[],
    appointments:[
      appt('ap-cancel','st-cancel','cancelled',20),
      appt('ap-booked','st-booked','booked',15),
      appt('ap-mix-b','st-mixed','booked',13),
      appt('ap-mix-c','st-mixed','cancelled',17)],
    booking_requests:[],blocked_time:[],staff_blocked_time:[],
    module_registry:[],module_templates:[],loyalty_programs:[],waitlist:[]
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
      case 'get_my_personas':return {staff:[{business_id:BIZ,business_slug:SLUG,business_name:'V818 Co',
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
    getSession:async()=>({data:{session:{user:{id:'u-owner',email:'owner@v818.co'}}},error:null}),
    getUser:async()=>({data:{user:{id:'u-owner',email:'owner@v818.co'}},error:null}),
    onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
    signOut:async()=>({error:null})
  },{get:(t,k)=>k in t?t[k]:async()=>({data:null,error:null})});
  const client={from:query,rpc,auth,channel,removeChannel(){},
    functions:{invoke:async()=>({data:null,error:null})},
    storage:{from:()=>({getPublicUrl:()=>({data:{publicUrl:''}})})}};
  Object.defineProperty(window,'supabase',{value:{createClient:()=>client},writable:false,configurable:false});
})();`;

/* Read the header line under each member's name off the RENDERED page, plus which appointment
   tiles were actually drawn in that member's column. */
const READ=`(()=>{
  const heads=[...document.querySelectorAll('.day-team-head')].map(head=>({
    name:((head.querySelector('h3')||{}).textContent||'').trim(),
    line:((head.querySelector('p')||{}).textContent||'').replace(/\\s+/g,' ').trim()
  }));
  const tiles=[...document.querySelectorAll('.day-timeline-event')].map(tile=>({
    text:(tile.textContent||'').replace(/\\s+/g,' ').trim(),
    ghost:tile.classList.contains('appointment-inactive-v288')
  }));
  return {heads,tiles,hash:location.hash};
})()`;

const browser=await chromium.launch({
  headless:true,
  ...(process.env.PLAYWRIGHT_EXECUTABLE_PATH?{executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH}:{})
});
const pageErrors=[];
try{
  await serverReady();
  const context=await browser.newContext({viewport:{width:1440,height:1000},bypassCSP:true});
  await context.route('**/*',route=>{
    const url=route.request().url();
    if(url.startsWith(ORIGIN)&&!url.includes('/sw.js'))return route.continue();
    return route.abort();
  });
  await context.addInitScript(ownerStub);
  const page=await context.newPage();
  page.on('pageerror',error=>pageErrors.push(String(error)));

  say('open the Day view');
  await page.goto(`${ORIGIN}/index.html#/appointments`,{waitUntil:'domcontentloaded'});
  await page.waitForFunction(()=>document.querySelectorAll('.day-team-head').length>0,
    null,{timeout:30000});
  /* The day the fixture seeds is two days ahead; step the Day view onto it. */
  for(let i=0;i<2;i++){
    await page.click('#wkNext');
    await page.waitForTimeout(400);
  }
  await page.waitForFunction(()=>document.querySelectorAll('.day-timeline-event').length>0,
    null,{timeout:30000});
  const seen=await page.evaluate(READ);
  const head=name=>(seen.heads.find(h=>h.name===name)||{line:'(no column)'}).line;

  say('photo 5 — a member whose only appointment is cancelled');
  ok(/·\s*0 appointments\b/.test(head('Cancelled Only')),
    `"Cancelled Only" reads 0 appointments — got "${head('Cancelled Only')}"`);

  say('the cancellation is still visible, not hidden to make the count right');
  ok(seen.tiles.some(t=>t.ghost&&/Kiat Ke Ying/.test(t.text)),
    'the cancelled booking is still drawn as a struck-through ghost');

  say('control — a booked appointment still counts, and still reads singular');
  ok(/·\s*1 appointment\b/.test(head('Booked Only'))&&!/appointments/.test(head('Booked Only')),
    `"Booked Only" reads 1 appointment — got "${head('Booked Only')}"`);

  say('control — one booked plus one cancelled is 1, not 2 and not 0');
  ok(/·\s*1 appointment\b/.test(head('Mixed Day'))&&!/appointments/.test(head('Mixed Day')),
    `"Mixed Day" reads 1 appointment — got "${head('Mixed Day')}"`);

  say('no uncaught page errors');
  ok(pageErrors.length===0,`no page errors (${pageErrors.slice(0,2).join(' | ')||'none'})`);

  process.stdout.write(`\nHEADERS AS RENDERED${NEGATIVE?' (NEGATIVE CONTROL, pre-fix bundle)':''}\n`);
  for(const h of seen.heads)process.stdout.write(`  ${h.name.padEnd(16)} ${h.line}\n`);
}finally{
  await browser.close().catch(()=>{});
  if(server)server.kill();
}

if(NEGATIVE){
  if(failures.length===0){
    process.stdout.write('\nNEGATIVE CONTROL DID NOT FAIL — the assertions do not discriminate.\n');
    process.exit(1);
  }
  process.stdout.write(`\nNEGATIVE CONTROL failed ${failures.length} assertion(s), as it must:\n`
    +failures.map(f=>`  - ${f}\n`).join(''));
  process.exit(0);
}
if(failures.length){
  process.stdout.write(`\n${failures.length} FAILED:\n`+failures.map(f=>`  - ${f}\n`).join(''));
  process.exit(1);
}
process.stdout.write('\nphoto 5 verified in a real browser.\n');
