/* nestly_v461 — the unit word follows the pot the figure was scoped to, on all three surfaces.
 *
 * THE BUG. get_dashboard_summary_v155 and get_reports_summary summed points_ledger with no
 * programme scope, so they added every pot a tenant has ever had. Measured on production by the
 * coordinator: Cubbly SPA's live pot is STAMPS holding 53, and the dashboard showed 78,345 —
 * re-counting a retired points pot that v384 had already converted INTO those stamps — under a
 * heading reading "Points earned", for a stamps merchant. v460 fixes the figures server-side and
 * adds `loyalty_unit` to both payloads. This file is the other half: the WORDS.
 * The Customer 360 Activity column had the same disease in the client: it summed every pot and
 * then labelled each row with the LIVE unit, so a historical points earn rendered "+3 stamps".
 *
 * WHAT THIS FILE PROVES, BY BOOTING THE REAL APP — real bundles built from the current app.js,
 * real router, real dashboard/reports/clientDetail, an in-page fixture Supabase that RECORDS the
 * filters each query carried, and a real Chrome:
 *   1. the dashboard loyalty strip renders NOTHING today (loyaltyVisibleV170 === false), so its
 *      label is proven by execution in the sibling unit test rather than asserted from a page
 *      that cannot show it. Asserted here so that a future render does not slip past unproven.
 *   2. reports money card, both payloads -> all three unit rows follow it, and "Manual
 *      adjustments" (which names an action, not a unit) does not move.
 *   3. NO payload field at all (an older server, or the gap between this deploy and v460) -> the
 *      reports words still follow the spine rather than defaulting to points on a stamps merchant.
 *   4. Customer 360: the points_ledger read is SCOPED to the live pot — the recorded filters carry
 *      programme_id = the live pot — and the retired pot's rows do not reach the Earned column.
 *   5. a firm with nothing accruing issues no ledger read at all and shows an empty column,
 *      rather than a retired pot's history under a unit nobody is running.
 *   6. THE NUMBERS ARE NOT TOUCHED. Every figure rendered is exactly what the fixture supplied;
 *      this change owns words and query scope, and nothing else.
 *
 * Run:
 *   PLAYWRIGHT_MODULE="<...>/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v461-loyalty-unit-labels.mjs
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
const PORT=Number(process.env.V461_PORT||4461);
const ORIGIN=`http://127.0.0.1:${PORT}`;

/* index.html loads the GENERATED chunks, never app/app.js, so serving app/ straight would run the
   last-stamped bundle and prove nothing about an edit made since. Committed chunks belong to the
   release step; build() is pure, so the chunks are rendered into a throwaway tree and served. */
const buildServedTree=async()=>{
  const dir=await mkdtemp(path.join(tmpdir(),'v461-app-'));
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
const MARKER='liveBalanceProgrammeIdV461';
const probe=async()=>{
  try{
    const response=await fetch(`${ORIGIN}/app-business.js`);
    return response.ok&&(await response.text()).includes(MARKER);
  }catch{return false}
};
const serverReady=async()=>{
  if(await probe())throw new Error(`something already serves ${ORIGIN}; this test needs the port`);
  const dir=await buildServedTree();
  server=spawn('python3',['-m','http.server',String(PORT),'--bind','127.0.0.1'],{cwd:dir,stdio:'ignore'});
  for(let i=0;i<80;i++){if(await probe())return;await new Promise(r=>setTimeout(r,100))}
  throw new Error('server did not start, or the built chunk lacks the v461 marker');
};

const BIZ='b4610000-0000-4000-8000-000000000461';
const SLUG='v461co';
const CLIENT='c4610000-0000-4000-8000-000000000461';
const STAMP_POT='11111111-1111-4111-8111-111111111111';
const POINT_POT='22222222-2222-4222-8222-222222222222';

/* `spine` decides which pots are active; `unit` is what v460 puts in the payloads (null = an older
   server). The ledger deliberately holds rows from BOTH pots so a scoping failure is visible. */
const ownerStub=({spine,unit})=>`(()=>{
  const BIZ='${BIZ}',SLUG='${SLUG}',CLIENT='${CLIENT}';
  const SPINE=${JSON.stringify(spine)};
  const UNIT=${JSON.stringify(unit)};
  const AUD={ledgerFilters:[],ledgerReads:0};
  window.__V461=AUD;
  const MODULES=['loyalty','clients','sales','services','till','reports','staffperf','settings','dashboard'];
  const bizRow={id:BIZ,slug:SLUG,name:'V461 Co',currency:'SGD',industry:'fnb',
    enabled_modules:MODULES,created_at:'2026-01-01T00:00:00Z'};
  /* 30 from the LIVE stamp pot, 900 from the RETIRED points pot, on two different sales. If the
     360 read is unscoped, the retired 900 appears in the Earned column. */
  const LEDGER=[
    {id:'pl-live',sale_id:'sale-1',points:30,programme_id:'${STAMP_POT}',entry_type:'earn'},
    {id:'pl-retired',sale_id:'sale-2',points:900,programme_id:'${POINT_POT}',entry_type:'earn'}];
  const SALES=[
    {id:'sale-1',business_id:BIZ,client_id:CLIENT,kind:'service',total_cents:3000,amount_cents:3000,
     occurred_at:'2026-08-20T02:00:00Z',counts_as_visit:true,reversal_of:null,staff_id:null,note:''},
    {id:'sale-2',business_id:BIZ,client_id:CLIENT,kind:'service',total_cents:90000,amount_cents:90000,
     occurred_at:'2026-02-10T02:00:00Z',counts_as_visit:true,reversal_of:null,staff_id:null,note:''}];
  const TABLES={
    businesses:[bizRow],
    branches:[{id:'br1',business_id:BIZ,name:'Main',active:true,is_default:true,billing_state:'active'}],
    clients:[{id:CLIENT,business_id:BIZ,full_name:'Mei Ling',phone:'81863833',email:'',
      referral_code:'ABC',marketing_consent:true,created_at:'2026-01-05T00:00:00Z'}],
    sales:SALES,points_ledger:LEDGER,staff:[{id:'st1',business_id:BIZ,full_name:'Owner Person',
      role:'owner',user_id:'u-owner',active:true,modules:null,module_perms:null}],
    business_programmes:SPINE,
    appointments:[],memberships:[],client_packages:[],client_field_definitions:[],
    client_field_values:[],client_field_options:[],services:[],products:[],module_registry:[]
  };
  const chainable=(resolveOut,table)=>{
    const q={single:false,head:false,countMode:null,op:'select',table,filters:[]};
    const chain={};
    for(const m of ['neq','is','in','not','gte','lte','lt','gt','or','ilike','like','contains',
      'overlaps','order','limit','range','abortSignal','filter','match'])chain[m]=()=>chain;
    chain.eq=(column,value)=>{q.filters.push([column,String(value)]);return chain};
    chain.select=(cols,opts)=>{if(opts&&opts.count){q.countMode=opts.count;q.head=!!opts.head}return chain};
    chain.single=()=>{q.single=true;return chain};
    chain.maybeSingle=()=>{q.single=true;return chain};
    chain.update=()=>chain;chain.insert=()=>chain;chain.upsert=()=>chain;chain.delete=()=>chain;
    chain.then=(res,rej)=>Promise.resolve(resolveOut(q)).then(res,rej);
    return chain;
  };
  const query=table=>chainable(q=>{
    let rows=(TABLES[table]||[]).slice();
    if(table==='points_ledger'){
      AUD.ledgerReads+=1;
      AUD.ledgerFilters.push(q.filters.map(f=>f.join('=')));
      /* Honour a programme_id filter exactly as PostgREST would, so a MISSING filter really does
         return the retired pot's row and the assertion below can see it. */
      const scoped=q.filters.find(f=>f[0]==='programme_id');
      if(scoped)rows=rows.filter(row=>String(row.programme_id)===scoped[1]);
    }
    if(q.countMode&&q.head)return {data:null,count:rows.length,error:null};
    if(q.single)return {data:rows[0]??null,error:null};
    return {data:rows,count:q.countMode?rows.length:null,error:null};
  },table);
  const SUMMARY={revenue_cents:120000,visits:2,new_customers:1,
    visits_by_weekday:[0,0,1,0,0,1,0],points_issued:30,
    revenue_by_day:[{day:'2026-08-20',amount_cents:120000}],
    availability:{sales:true,clients:true,loyalty:true}};
  const REPORTS={revenue_by_kind:{service:120000},non_revenue_by_kind:{},
    points_by_type:{earn:30,redeem:-5,expire:-2,adjust:4},
    availability:{clients_export:true,credit_liability:true,loyalty:true,gift_cards:true,
      memberships:true,sales_export:true},
    credit_liability_cents:0,gift_card_liability_cents:0,active_memberships:0,
    reversal_reconciliation:{compensating_rows:0,reversed_revenue_cents:0,net_revenue_cents:120000}};
  if(UNIT!==null){SUMMARY.loyalty_unit=UNIT;REPORTS.loyalty_unit=UNIT}
  const rpcData=name=>{
    switch(name){
      case 'get_my_personas':return {staff:[{business_id:BIZ,business_slug:SLUG,business_name:'V461 Co',
        role:'owner',modules:MODULES}],customer:[],default_route:'#/workspace/'+SLUG+'/dashboard'};
      case 'platform_get_business_control_v94':return {workspace_access:true,quick_earn_catalogue_enabled:true};
      case 'get_my_modules':case 'get_my_modules_at_v115':return {role:'owner',is_super_admin:false,
        modules:MODULES,capabilities:[],module_perms:Object.fromEntries(MODULES.map(m=>[m,'rw']))};
      case 'get_customer_feature_capabilities':return {customer_wallet:true,customer_phone_registration:false};
      case 'get_workspace_locale_preference_v97':return {locale:'en',version:1};
      case 'get_notifications':return {unread:0,items:[]};
      case 'get_dashboard_summary_v155':return SUMMARY;
      case 'get_reports_summary':return REPORTS;
      case 'staff_list_customers_v155':return {total:1,customers:[]};
      case 'preview_campaign_audience_v155':return {total:0};
      case 'staff_customer_bucket_counts_v290':return {counts:{}};
      case 'staff_list_visit_feedback_v145':return [];
      case 'list_customer_redemption_history_v145':return [];
      case 'staff_get_customer_actionable_loyalty_v145':
        return {balance:30,unit:UNIT||'points',rewards:[],redemption_enabled:true,
          program:{unit:UNIT||'points'}};
      case 'staff_get_reward_entitlements_v99':return [];
      case 'get_programmes_v314':case 'business_get_programmes_v314':
        return {programmes:SPINE.map(p=>({kind:p.kind,active:p.active,customer_visible:true})),
          programmes_contract:'v391'};
      default:return null;
    }
  };
  const rpc=name=>chainable(()=>({data:rpcData(name),error:null}),'rpc:'+name);
  const channel=()=>{const c={on:()=>c,subscribe:()=>c,unsubscribe:()=>{}};return c};
  const auth=new Proxy({
    getSession:async()=>({data:{session:{user:{id:'u-owner',email:'owner@v461.co'}}},error:null}),
    getUser:async()=>({data:{user:{id:'u-owner',email:'owner@v461.co'}},error:null}),
    onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
    signOut:async()=>({error:null})
  },{get:(t,k)=>k in t?t[k]:async()=>({data:null,error:null})});
  const client={from:query,rpc,auth,channel,removeChannel(){},
    functions:{invoke:async()=>({data:null,error:null})},
    storage:{from:()=>({getPublicUrl:()=>({data:{publicUrl:''}})})}};
  Object.defineProperty(window,'supabase',{value:{createClient:()=>client},writable:false,configurable:false});
})();`;

const STAMPS_LIVE=[{id:STAMP_POT,kind:'stamps',active:true,deactivated_at:null},
  {id:POINT_POT,kind:'points',active:false,deactivated_at:'2026-06-01T00:00:00Z'}];
const POINTS_LIVE=[{id:POINT_POT,kind:'points',active:true,deactivated_at:null}];
const NOTHING_LIVE=[{id:POINT_POT,kind:'points',active:false,deactivated_at:'2026-06-01T00:00:00Z'}];

const browser=await chromium.launch({headless:true,
  executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
const pageErrors=[];
try{
  await serverReady();

  const open=async({spine,unit,hash})=>{
    const context=await browser.newContext({viewport:{width:1180,height:900},bypassCSP:true});
    await context.route('**/*',route=>{
      const url=route.request().url();
      if(url.startsWith(ORIGIN)&&!url.includes('/sw.js'))return route.continue();
      if(url.startsWith('https://cdn.jsdelivr.net/'))return route.continue();
      return route.abort();
    });
    await context.addInitScript(ownerStub({spine,unit}));
    const page=await context.newPage();
    page.on('pageerror',error=>pageErrors.push(`${hash}: ${error}`));
    await page.goto(`${ORIGIN}/index.html${hash}`,{waitUntil:'domcontentloaded'});
    await page.waitForSelector('#main',{timeout:30000});
    await page.waitForTimeout(3000);
    return {context,page};
  };
  const textOf=page=>page.evaluate(()=>(document.querySelector('#main')?.innerText||'').replace(/\s+/g,' '));

  /* ---------------- 1. dashboard ----------------
     The dashboard's loyalty strip — the tile that carries this label — sits behind
     `const loyaltyVisibleV170=false` (V224: "the owner struck out the whole Loyalty this period
     strip"), and `if(!loyaltyVisibleV170)loyalty.innerHTML=''` blanks it on every render. It
     therefore CANNOT be asserted from a rendered page: there is nothing on screen to read. The
     label expression is proven by execution instead, in
     tests/business-ui/v461-loyalty-unit-words.test.mjs, and the fact that the strip renders
     nowhere today is asserted HERE so that a future render is caught by this file rather than
     shipping an unproven label. */
  say('1. the dashboard loyalty strip is still not rendered (its label is unit-tested instead)');
  {
    const {context,page}=await open({spine:STAMPS_LIVE,unit:'stamps',hash:'#/dashboard'});
    const text=await textOf(page);
    ok(!text.includes('Points earned')&&!text.includes('Stamps earned'),
      'no loyalty-flow tile is on the dashboard — loyaltyVisibleV170 is false, so this label ships nowhere');
    ok(text.includes('Dashboard'),'and the dashboard itself rendered, so the check is not vacuous');
    await context.close();
  }

  /* ---------------- 2. reports money card ---------------- */
  for(const [label,spine,unit,noun,other] of [
    ['stamps payload',STAMPS_LIVE,'stamps','Stamps','Points'],
    ['points payload',POINTS_LIVE,'points','Points','Stamps']]){
    say(`2. reports loyalty flow — ${label}`);
    const {context,page}=await open({spine,unit,hash:'#/reports'});
    const text=await textOf(page);
    for(const row of ['earned','redeemed','expired']){
      ok(text.includes(`${noun} ${row}`),`the row reads "${noun} ${row}"`);
      ok(!text.includes(`${other} ${row}`),`and never "${other} ${row}"`);
    }
    ok(text.includes('Manual adjustments'),
      'and "Manual adjustments" is untouched — it names an action, not a unit');
    /* The four figures are the fixture's, unchanged: 30 / 5 / 2 / 4. */
    for(const figure of ['30','5','2','4'])
      ok(new RegExp(`\\b${figure}\\b`).test(text),`figure ${figure} is rendered as supplied`);
    await context.close();
  }

  /* ---------------- 4. Customer 360 activity scope ---------------- */
  say('4. Customer 360 Earned column is scoped to the live pot');
  {
    const {context,page}=await open({spine:STAMPS_LIVE,unit:'stamps',hash:`#/client/${CLIENT}`});
    const audit=await page.evaluate(()=>window.__V461);
    ok(audit.ledgerReads>0,`the ledger was read (${audit.ledgerReads}x)`);
    const scoped=audit.ledgerFilters.filter(filters=>filters.some(f=>f.startsWith('programme_id=')));
    ok(scoped.length===audit.ledgerReads,
      `every points_ledger read carried a programme_id filter (${JSON.stringify(audit.ledgerFilters)})`);
    ok(audit.ledgerFilters.some(filters=>filters.includes(`programme_id=${STAMP_POT}`)),
      'and it is the LIVE stamp pot, not the retired points pot');
    ok(!audit.ledgerFilters.some(filters=>filters.includes(`programme_id=${POINT_POT}`)),
      'the retired pot is never asked for');
    const text=await textOf(page);
    /* The live row earned 30; the retired pot's row is 900. If the scope failed, 900 shows up in
       the Earned column under the live unit — the exact "+3 stamps for a points earn" bug. */
    ok(/\+\s*30\s*stamps/i.test(text),`the live pot's earn shows under the live unit (${text.match(/\+\s*\d+\s*\w+/g)})`);
    ok(!/\+\s*900/.test(text),'and the retired pot’s 900 never appears in the Earned column');
    await context.close();
  }

  /* ---------------- 5. nothing accruing ---------------- */
  say('5. a firm with nothing accruing reads no ledger at all');
  {
    const {context,page}=await open({spine:NOTHING_LIVE,unit:null,hash:`#/client/${CLIENT}`});
    const audit=await page.evaluate(()=>window.__V461);
    ok(audit.ledgerReads===0,
      `no points_ledger read is issued when no pot is live (${audit.ledgerReads})`);
    const text=await textOf(page);
    ok(!/\+\s*900/.test(text),'and the retired pot’s history is not shown under any unit');
    ok(!/\+\s*30/.test(text),'nor the paused pot’s');
    await context.close();
  }

  ok(pageErrors.length===0,`no uncaught page errors (${pageErrors.length}${pageErrors.length?': '+pageErrors.join(' | '):''})`);
  process.stdout.write('\nV461 loyalty unit labels: all steps passed\n');
}catch(error){
  process.stdout.write(`\nFAILED: ${error.message}\n`);
  if(pageErrors.length)process.stdout.write(`page errors:\n  ${pageErrors.join('\n  ')}\n`);
  process.exitCode=1;
}finally{
  await browser.close();
  if(server)server.kill();
}
