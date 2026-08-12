/* V297 Business Insights walkthrough — the owner's iPad markup of 2026-08-12, scripted.
 *
 *   "please make business insights more interesting & easier to understand"
 *   "— i want to know if my business is improving?"
 *
 * Drives the REAL production bundles (app/index.html + the stamped chunks — run
 * `npm run bundle-stamp` first) through the real router, with the Supabase client replaced by an
 * in-page fixture (same pattern as verify-v295-owner-fixes-walkthrough.mjs). Unlike the earlier
 * fixtures this one HONOURS range filters and RECORDS every call, because the whole point of
 * V297 is a second read of the same report over the window shifted back one period-length: the
 * test has to be able to prove which two windows were asked for.
 *
 * Steps (each asserts; the script exits non-zero naming the failing step):
 *   1. Sales & Revenue — verdict band; both report reads issued; the shifted window is exactly
 *      the preceding equal-length period; the printed % is the arithmetic on the fixture's own
 *      numbers; the proportional bar and the plain-words explanations are there; every scope,
 *      liability, gift-card and "sale ledger amounts" caveat survives verbatim.
 *   2. Efficiency — booked-hours verdict against the previous period.
 *   3. Customer Retention — returning-customer verdict against the previous period.
 *   4. Team Performance — the tab opens #/staffperf and that page now opens with its own verdict.
 *      From/To survives every tab switch, and Export sales CSV stays available from each tab.
 *   5. No earlier history (a business whose own record starts inside the previous window) —
 *      "No comparable earlier period" and NO percentage anywhere in the band.
 *   6. Zero baseline (the business traded, the previous window was empty) — no infinity, no
 *      fabricated 100%, and the reason stated in words.
 *   7. Brand-new business with no data at all — every tab still reads sensibly.
 *
 * Run:
 *   PLAYWRIGHT_MODULE=".../playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v297-insights-walkthrough.mjs
 */
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const APP_DIR=fileURLToPath(new URL('../../app/',import.meta.url));
/* 4173 belongs to another worktree's walkthrough; evidence captured from it would be evidence
   about somebody else's tree. This suite owns 4197. */
const PORT=Number(process.env.V297_PORT||4197);
const ORIGIN=`http://127.0.0.1:${PORT}`;

let step='(boot)';
const say=name=>{step=name;process.stdout.write(`STEP ${name}\n`)};
const assertTrue=(condition,message)=>{
  if(!condition)throw new Error(`step ${step}: ${message}`);
  process.stdout.write(`  ok - ${message}\n`);
};

let server=null;
const probe=async()=>{try{const r=await fetch(`${ORIGIN}/index.html`);return r.ok}catch{return false}};
const serverReady=async()=>{
  if(await probe())return;
  server=spawn('python3',['-m','http.server',String(PORT),'--bind','127.0.0.1'],{cwd:APP_DIR,stdio:'ignore'});
  server.on('error',error=>process.stdout.write(`server spawn error: ${error}\n`));
  for(let i=0;i<50;i++){
    if(await probe())return;
    await new Promise(resolve=>setTimeout(resolve,100));
  }
  throw new Error('static server did not start');
};

/* ---- the fixture's own arithmetic, duplicated here on purpose ----
   The expected percentages below are computed from these constants in the TEST, and the page
   computes them independently from the same constants served through the stub. If either side
   drifts the assertion fails, which is the only way a "12.0%" in a walkthrough means anything. */
const CURRENT_REVENUE={package:180000,service:0,quick_sale:54730};      // SGD 2347.30
const PRIOR_REVENUE={package:150000,quick_sale:59540};                  // SGD 2095.40
const CURRENT_HOURS=6,PRIOR_HOURS=4;
const CURRENT_RETURNING=18,PRIOR_RETURNING=15;
const CURRENT_ATTRIBUTED=210000,PRIOR_ATTRIBUTED=175000;                // sale_commission revenue
const sum=values=>Object.values(values).reduce((total,value)=>total+value,0);
const changePct=(current,previous)=>(current-previous)/Math.abs(previous)*100;
const expected=(current,previous)=>`${changePct(current,previous)>0?'Up':'Down'} ${Math.abs(changePct(current,previous)).toFixed(1)}%`;

const BIZ='b1111111-1111-4111-8111-111111111111';
const stubSource=`(()=>{
  const BIZ='${BIZ}';
  const CURRENT_REVENUE=${JSON.stringify(CURRENT_REVENUE)};
  const PRIOR_REVENUE=${JSON.stringify(PRIOR_REVENUE)};
  const CURRENT_HOURS=${CURRENT_HOURS},PRIOR_HOURS=${PRIOR_HOURS};
  const CURRENT_RETURNING=${CURRENT_RETURNING},PRIOR_RETURNING=${PRIOR_RETURNING};
  const CURRENT_ATTRIBUTED=${CURRENT_ATTRIBUTED},PRIOR_ATTRIBUTED=${PRIOR_ATTRIBUTED};
  /* The scenario rides in the query string and is read FRESH on every use. It cannot be poked in
     after load: the row it changes (the business's own start date) is read during boot, before any
     post-load evaluate could reach it. The query string also guarantees each scenario is a real
     document load — a goto that differs only in the hash is a fragment navigation, not a reload. */
  const scenario=()=>{try{return new URLSearchParams(location.search).get('v297')||'normal'}catch{return 'normal'}};
  const MODULES=['loyalty','retention','referrals','memberships','giftcards','clients','sales','services','till','bookings','reports','inventory','appointments','staffperf','packages'];

  /* Singapore calendar arithmetic, matching the app's own helpers, so the fixture's windows are
     the very windows the page asks for. */
  const sgToday=()=>new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Singapore',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
  const dayShift=(day,offset)=>{const m=String(day).match(/^(\\d{4})-(\\d{2})-(\\d{2})$/);
    return new Date(Date.UTC(Number(m[1]),Number(m[2])-1,Number(m[3])+offset)).toISOString().slice(0,10)};
  const at=(day,hour)=>new Date(day+'T'+String(hour).padStart(2,'0')+':00:00+08:00').toISOString();
  const TODAY=sgToday();
  const CUR_FROM=dayShift(TODAY,-29),CUR_TO=TODAY;
  const PRIOR_FROM=dayShift(TODAY,-59),PRIOR_TO=dayShift(TODAY,-30);
  window.__V297WINDOWS={today:TODAY,curFrom:CUR_FROM,curTo:CUR_TO,priorFrom:PRIOR_FROM,priorTo:PRIOR_TO};

  /* The business's own start date is what decides whether an earlier window is comparable at
     all — scenario 'nohistory' moves it INSIDE the previous window, 'empty' to today. */
  const startedOn=()=>scenario()==='nohistory'?dayShift(TODAY,-40):scenario()==='empty'?TODAY:'2024-01-01';
  const bizRow=()=>({id:BIZ,slug:'testco',name:'Test Co',currency:'SGD',industry:'facial',points_mode:'both',
    enabled_modules:MODULES,active_config_version_id:'pub-1',join_enabled:true,brand_color:'#7c5cff',
    booking_policy:null,quick_earn_catalogue_enabled:true,created_at:at(startedOn(),9)});
  const blank=()=>scenario()==='empty';

  const appointmentRows=()=>blank()?[]:[
    {id:'ap1',business_id:BIZ,status:'completed',branch_id:'br1',staff_id:'st1',
      starts_at:at(dayShift(TODAY,-5),10),ends_at:at(dayShift(TODAY,-5),13)},
    {id:'ap2',business_id:BIZ,status:'booked',branch_id:'br1',staff_id:'st1',
      starts_at:at(dayShift(TODAY,-4),10),ends_at:at(dayShift(TODAY,-4),12)},
    {id:'ap3',business_id:BIZ,status:'no_show',branch_id:'br1',staff_id:'st1',
      starts_at:at(dayShift(TODAY,-3),10),ends_at:at(dayShift(TODAY,-3),11)},
    /* the no-show is excluded from booked hours by appointmentSummary, so current = 3 + 2 + 1
       active hour... it is: ap1 3h + ap2 2h + ap4 1h = CURRENT_HOURS */
    {id:'ap4',business_id:BIZ,status:'completed',branch_id:'br1',staff_id:'st1',
      starts_at:at(dayShift(TODAY,-2),10),ends_at:at(dayShift(TODAY,-2),11)},
    {id:'ap5',business_id:BIZ,status:'completed',branch_id:'br1',staff_id:'st1',
      starts_at:at(dayShift(TODAY,-45),10),ends_at:at(dayShift(TODAY,-45),13)},
    {id:'ap6',business_id:BIZ,status:'booked',branch_id:'br1',staff_id:'st1',
      starts_at:at(dayShift(TODAY,-40),10),ends_at:at(dayShift(TODAY,-40),11)}
  ];
  /* sale_commission drives Team Performance; the same two windows, the same branch column. */
  const commissionRows=()=>blank()?[]:[
    {sale_id:'s1',business_id:BIZ,branch_id:'br1',staff_id:'st1',kind:'service',
      occurred_at:at(dayShift(TODAY,-6),12),amount_cents:CURRENT_ATTRIBUTED,commission_cents:21000,counts_as_revenue:true},
    {sale_id:'s2',business_id:BIZ,branch_id:'br1',staff_id:'st1',kind:'gift_card',
      occurred_at:at(dayShift(TODAY,-6),13),amount_cents:5000,commission_cents:0,counts_as_revenue:false},
    {sale_id:'s3',business_id:BIZ,branch_id:'br1',staff_id:'st1',kind:'service',
      occurred_at:at(dayShift(TODAY,-45),12),amount_cents:PRIOR_ATTRIBUTED,commission_cents:17500,counts_as_revenue:true}
  ];

  const TABLES=()=>({
    businesses:[bizRow()],
    branches:[{id:'br1',business_id:BIZ,name:'Orchard',active:true,billing_state:'active'}],
    services:[{id:'sv1',business_id:BIZ,name:'Signature facial',active:true,price_cents:8800}],
    clients:[{id:'c1',business_id:BIZ,full_name:'Steven Lim',phone:'+65 81234567',email:'',
      referral_code:'STEVEN1',marketing_consent:false}],
    appointments:appointmentRows(),
    sale_commission:commissionRows(),
    sales:[],points_ledger:[],memberships:[],client_packages:[],waitlist:[],
    staff:[{id:'st1',business_id:BIZ,full_name:'Owner Person',role:'owner',user_id:'u-owner',
      active:true,email:'owner@test.co',phone:'',title:null,module_perms:null,modules:null,
      commission_service_bps:null,commission_product_bps:null,created_at:'2024-01-01T00:00:00Z'}],
    staff_invites:[],staff_hours:[],staff_branches:[],staff_off_days:[],branch_hours:[],branch_breaks:[],
    loyalty_programs:[],loyalty_rewards:[],membership_plans:[],retention_programs:[]
  });

  window.__V297={rpc:[]};
  /* Filter-aware chain: eq/gte/lt/lte/gt are RECORDED and APPLIED, because the two report
     windows differ only by their range predicates. Unknown columns are ignored rather than
     dropping the row, so unrelated pages still render. */
  const chainable=resolveOut=>{
    const q={single:false,head:false,countMode:null,op:'select',filters:[]};
    const chain={};
    for(const m of ['neq','is','in','not','or','ilike','contains','overlaps','order','limit','range'])
      chain[m]=()=>chain;
    for(const m of ['eq','gte','lte','lt','gt'])
      chain[m]=(column,value)=>{q.filters.push([m,column,value]);return chain};
    chain.select=(cols,opts)=>{if(opts&&opts.count){q.countMode=opts.count;q.head=!!opts.head}return chain};
    chain.single=()=>{q.single=true;return chain};
    chain.maybeSingle=()=>{q.single=true;return chain};
    chain.update=payload=>{q.op='update';q.payload=payload;return chain};
    chain.insert=payload=>{q.op='insert';q.payload=payload;return chain};
    chain.upsert=payload=>{q.op='upsert';q.payload=payload;return chain};
    chain.delete=()=>{q.op='delete';return chain};
    chain.then=(resolve,reject)=>Promise.resolve(resolveOut(q)).then(resolve,reject);
    return chain;
  };
  const keep=(row,filters)=>filters.every(([op,column,value])=>{
    if(value===null||value===undefined||!(column in row))return true;
    const a=String(row[column]),b=String(value);
    if(op==='eq')return String(row[column])===String(value)||row[column]===value;
    if(op==='gte')return a>=b;
    if(op==='lte')return a<=b;
    if(op==='lt')return a<b;
    if(op==='gt')return a>b;
    return true;
  });
  const query=table=>chainable(q=>{
    if(q.op!=='select')return {data:null,error:null};
    const rows=(TABLES()[table]||[]).filter(row=>keep(row,q.filters));
    if(q.countMode&&q.head)return {data:null,count:rows.length,error:null};
    if(q.single)return {data:rows[0]??null,error:null};
    return {data:rows,count:q.countMode?rows.length:null,error:null};
  });

  const availability={sales:true,clients:true,loyalty:true,gift_cards:true,memberships:true,
    credit_liability:true,sales_export:true,clients_export:true};
  const reportsSummary=(from,to)=>{
    const current=from===CUR_FROM&&to===CUR_TO;
    const prior=from===PRIOR_FROM&&to===PRIOR_TO;
    if(!current&&!prior)return null;
    const empty={revenue_by_kind:{},non_revenue_by_kind:{},points_by_type:{},availability,
      credit_liability_cents:0,gift_card_liability_cents:0,active_memberships:0,
      reversal_reconciliation:{compensating_rows:0,reversed_revenue_cents:0,net_revenue_cents:0}};
    if(blank())return empty;
    /* 'zerobaseline': the business traded through the current window and recorded nothing at all
       in the previous one — the case a naive percentage turns into an infinity. */
    if(prior&&scenario()==='zerobaseline')return empty;
    const byKind=current?CURRENT_REVENUE:PRIOR_REVENUE;
    return {revenue_by_kind:byKind,
      non_revenue_by_kind:current?{gift_card:12000}:{},
      points_by_type:{earn:78232,redeem:-4100,expire:-900,adjust:0},
      availability,
      credit_liability_cents:current?45000:0,
      gift_card_liability_cents:current?12000:0,
      active_memberships:current?6:0,
      reversal_reconciliation:{compensating_rows:4,reversed_revenue_cents:8800,
        net_revenue_cents:Object.values(byKind).reduce((a,b)=>a+b,0)-8800}};
  };
  const lifecycle=from=>{
    if(blank())return {status:'no_data',metrics:{},coverage:{eligible_transactions:0,identified_transactions:0}};
    const current=from===CUR_FROM,prior=from===PRIOR_FROM;
    if(!current&&!prior)return {status:'no_data',metrics:{},coverage:{eligible_transactions:0,identified_transactions:0}};
    if(prior&&scenario()==='zerobaseline')
      return {status:'ok',metrics:{existing_returning_customers:0,existing_customer_share_pct:0,
        new_customers:0,reactivated_customers:0,transacting_identified_customers:1,
        repeat_purchasers_in_period:0,repeat_in_period_rate_pct:0},
        coverage:{eligible_transactions:1,identified_transactions:1,identified_transaction_pct:100}};
    return {status:'ok',
      metrics:{existing_returning_customers:current?CURRENT_RETURNING:PRIOR_RETURNING,
        existing_customer_share_pct:current?60:55,new_customers:current?7:5,
        reactivated_customers:current?2:1,transacting_identified_customers:current?30:27,
        repeat_purchasers_in_period:current?9:7,repeat_in_period_rate_pct:current?30:26},
      coverage:{eligible_transactions:current?40:36,identified_transactions:current?30:27,
        identified_transaction_pct:75}};
  };
  const rpcData=(name,args)=>{
    switch(name){
      case 'get_my_personas':return {staff:[{business_id:BIZ,business_slug:'testco',business_name:'Test Co',role:'owner',modules:MODULES}],customer:[],default_route:'#/workspace/testco/dashboard'};
      case 'platform_get_business_control_v94':return {workspace_access:true,quick_earn_catalogue_enabled:true};
      case 'get_my_modules':return {role:'owner',is_super_admin:false,modules:MODULES,module_perms:Object.fromEntries(MODULES.map(m=>[m,'rw']))};
      case 'get_customer_feature_capabilities':return {};
      case 'get_workspace_locale_preference_v97':return {locale:'en',version:1};
      case 'get_notifications':return {unread:0,items:[]};
      case 'get_dashboard_summary_v155':return {visits:2,revenue_cents:6000,new_customers:1,points_issued:0,
        visits_by_weekday:[0,1,0,1,0,0,0],availability:{sales:true,clients:true,loyalty:true}};
      case 'require_module_scope_v145':return null;
      case 'list_staff_blocked_times_v120':return [];
      case 'get_reports_summary':return reportsSummary(args?.p_from,args?.p_to);
      case 'get_customer_lifecycle_v107':return lifecycle(args?.p_from);
      case 'business_get_promotion_editor_v155':return {items:[],entitlement:null};
      case 'business_get_welcome_offer_v215':return {configured:false};
      case 'get_active_birthday_program':return {programs:[]};
      default:return null;
    }
  };
  const rpc=(name,args)=>{
    window.__V297.rpc.push({name,args:args??null});
    return chainable(()=>({data:rpcData(name,args),error:null}));
  };
  const channel=()=>{const c={on:()=>c,subscribe:()=>c,unsubscribe:()=>{}};return c};
  const auth=new Proxy({
    getSession:async()=>({data:{session:{user:{id:'u-owner',email:'owner@test.co'}}},error:null}),
    getUser:async()=>({data:{user:{id:'u-owner',email:'owner@test.co'}},error:null}),
    onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
    signOut:async()=>({error:null})
  },{get:(target,key)=>key in target?target[key]:async()=>({data:null,error:null})});
  const client={from:query,rpc,auth,channel,removeChannel(){},functions:{invoke:async()=>({data:null,error:null})},
    storage:{from:()=>({getPublicUrl:()=>({data:{publicUrl:''}})})}};
  Object.defineProperty(window,'supabase',{value:{createClient:()=>client},writable:false,configurable:false});
})();`;

const browser=await chromium.launch({
  headless:true,
  executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
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
  await context.addInitScript(stubSource);
  const page=await context.newPage();
  page.on('pageerror',error=>pageErrors.push(String(error)));

  let loadCountV297=0;
  const openReports=async scenario=>{
    await page.goto(`${ORIGIN}/index.html?v297=${scenario}&n=${++loadCountV297}#/dashboard`,{waitUntil:'domcontentloaded'});
    await page.waitForSelector('#dashboardScheduleHeadingV295',{timeout:20000});
    await page.evaluate(()=>{window.__V297.rpc.length=0});
    await page.evaluate(()=>{location.hash='#/reports'});
    await page.waitForSelector('.report-tabbar-v294',{timeout:20000});
    return page.waitForSelector('#reportPanelMoneyV294 .report-verdict-v297,#reportPanelMoneyV294 .empty,#reportPanelMoneyV294 .err',{timeout:20000});
  };
  const bandText=async panelId=>page.evaluate(id=>{
    const band=document.querySelector(`#${id} .report-verdict-v297`);
    return band?band.innerText.replace(/\s+/g,' ').trim():null;
  },panelId);
  const summaryCalls=()=>page.evaluate(()=>window.__V297.rpc.filter(call=>call.name==='get_reports_summary')
    .map(call=>({from:call.args.p_from,to:call.args.p_to,branch:call.args.p_branch??null})));

  /* ---------------- 1. Sales & Revenue ---------------- */
  say('1a. the Sales & Revenue tab opens with a verdict, not a wall of figures');
  await openReports('normal');
  const windows=await page.evaluate(()=>window.__V297WINDOWS);
  const moneyBand=await bandText('reportPanelMoneyV294');
  assertTrue(Boolean(moneyBand),'a verdict band rendered at the top of the Sales & Revenue panel');
  assertTrue(moneyBand.includes(`SGD ${(sum(CURRENT_REVENUE)/100).toFixed(2)}`),
    `the headline is the period's net total SGD ${(sum(CURRENT_REVENUE)/100).toFixed(2)} (band: ${moneyBand})`);
  const moneyExpected=expected(sum(CURRENT_REVENUE),sum(PRIOR_REVENUE));
  assertTrue(moneyBand.includes(moneyExpected),
    `the change is stated in words and per cent as "${moneyExpected}" — the arithmetic on the fixture's own numbers`);
  assertTrue(moneyBand.includes(`SGD ${(sum(PRIOR_REVENUE)/100).toFixed(2)}`),
    'the previous period figure it compared against is printed too');
  assertTrue(await page.locator('#reportPanelMoneyV294 .report-verdict-v297[data-report-verdict-v297="up"]').count()===1,
    'the band carries a machine-readable direction (up) that the colour and arrow follow');

  say('1b. the comparison came from the SAME report read, one period-length earlier');
  const calls=await summaryCalls();
  assertTrue(calls.length===2,`get_reports_summary was called exactly twice (got ${calls.length}: ${JSON.stringify(calls)})`);
  const currentCall=calls.find(call=>call.from===windows.curFrom&&call.to===windows.curTo);
  const priorCall=calls.find(call=>call.from===windows.priorFrom&&call.to===windows.priorTo);
  assertTrue(Boolean(currentCall),`one call is the selected window ${windows.curFrom}..${windows.curTo}`);
  assertTrue(Boolean(priorCall),`one call is the shifted window ${windows.priorFrom}..${windows.priorTo}`);
  const dayCount=(from,to)=>Math.round((Date.parse(`${to}T00:00:00Z`)-Date.parse(`${from}T00:00:00Z`))/864e5)+1;
  assertTrue(dayCount(priorCall.from,priorCall.to)===dayCount(currentCall.from,currentCall.to),
    `both windows are the same length (${dayCount(currentCall.from,currentCall.to)} days)`);
  assertTrue(dayCount(priorCall.to,currentCall.from)===2,
    'the shifted window ends the day before the selected one begins — no overlap, no gap');
  assertTrue(String(priorCall.branch)===String(currentCall.branch),
    'both reads carry the same branch scope, so the two figures are comparable');

  say('1c. the jargon cards now explain themselves and the mix is readable');
  const moneyPanel=await page.locator('#reportPanelMoneyV294').innerText();
  const segments=await page.locator('#reportPanelMoneyV294 .report-share-bar-v297 > span').count();
  assertTrue(segments>=2,`Revenue by type carries a proportional bar with ${segments} segments`);
  assertTrue(await page.locator('#reportPanelMoneyV294 .report-share-legend-v297 li').count()>=2,
    'the bar has a legend naming each part');
  for(const line of [
    'a compensating row is a correction that cancels an earlier sale',
    'this is money you still owe customers',
    'Earned is what customers built up this period'])
    assertTrue(moneyPanel.includes(line),`a plain-words explanation is present: "${line}"`);

  say('1d. every existing figure and every scope caveat survives verbatim');
  for(const figure of ['Revenue by type','Net total','Reversal reconciliation','Compensating rows',
    'Loyalty flow','Points earned','Liabilities','Customer credit outstanding','Gift cards unredeemed','Memberships'])
    assertTrue(moneyPanel.includes(figure),`the existing figure "${figure}" is still on the page`);
  for(const caveat of [
    'Available balances are current business-wide obligations and do not change when a historical period or branch is selected.',
    'These are sale ledger amounts, not verified payment or cash-collection totals.',
    'Originals remain on record. Negative reversal rows link back to them and reduce the net.'])
    assertTrue(moneyPanel.includes(caveat),`the disclosure survives verbatim: "${caveat.slice(0,58)}…"`);
  const scopeNote=await page.locator('#reportScopeNoteV272').innerText();
  assertTrue(scopeNote.startsWith('Figures below cover '),
    `the branch-scope disclosure is still stated ("${scopeNote.trim()}")`);
  assertTrue(moneyPanel.includes('Non-revenue sale amounts recorded'),
    'the non-revenue (gift card) note is still shown outside the revenue total');

  /* ---------------- 2. Efficiency ---------------- */
  say('2. Efficiency opens with booked hours against the previous period');
  await page.click('[data-report-tab-v294="busy"]');
  await page.waitForSelector('#reportPanelBusyV294 .report-verdict-v297',{timeout:20000});
  const busyBand=await bandText('reportPanelBusyV294');
  assertTrue(busyBand.includes(`${CURRENT_HOURS.toFixed(1)} booked hours`),
    `the headline is ${CURRENT_HOURS.toFixed(1)} booked hours (band: ${busyBand})`);
  const busyExpected=expected(CURRENT_HOURS,PRIOR_HOURS);
  assertTrue(busyBand.includes(busyExpected),`the change reads "${busyExpected}"`);
  assertTrue(busyBand.includes(`${PRIOR_HOURS.toFixed(1)} hours`),'the previous period figure is printed');
  assertTrue(await page.inputValue('#rf')===windows.curFrom&&await page.inputValue('#rt2')===windows.curTo,
    'From/To survived the tab switch');

  /* ---------------- 3. Customer Retention ---------------- */
  say('3. Customer Retention opens with returning customers against the previous period');
  await page.click('[data-report-tab-v294="returning"]');
  await page.waitForSelector('#reportPanelReturningV294 .report-verdict-v297',{timeout:20000});
  const returningBand=await bandText('reportPanelReturningV294');
  assertTrue(returningBand.includes(`${CURRENT_RETURNING} returning customers`),
    `the headline is ${CURRENT_RETURNING} returning customers (band: ${returningBand})`);
  const returningExpected=expected(CURRENT_RETURNING,PRIOR_RETURNING);
  assertTrue(returningBand.includes(returningExpected),`the change reads "${returningExpected}"`);

  say('3b. Export sales CSV is available from every tab, not only from Sales & Revenue');
  for(const key of ['money','busy','returning']){
    await page.click(`[data-report-tab-v294="${key}"]`);
    await page.waitForFunction(()=>{const b=document.getElementById('rcsv');return b&&!b.hidden&&!b.disabled},null,{timeout:20000});
    assertTrue(true,`the export button is offered while the "${key}" tab is open`);
  }
  /* The gap this closes: pressing Run report from any tab used to leave the export hidden,
     because only the Sales & Revenue read supplies its scope. */
  await page.click('[data-report-tab-v294="busy"]');
  await page.click('#rgo');
  await page.waitForFunction(()=>{const b=document.getElementById('rcsv');return b&&!b.hidden&&!b.disabled},null,{timeout:20000});
  assertTrue(true,'Run report pressed from the Efficiency tab still leaves Export sales CSV available');
  assertTrue(await page.inputValue('#rf')===windows.curFrom,'From/To unchanged by Run report');

  /* ---------------- 4. Team Performance ---------------- */
  say('4. the Team Performance tab opens a page that also leads with a verdict');
  await page.click('[data-report-tab-href-v294="#/staffperf"]');
  await page.waitForSelector('#staffPerfVerdictV297 .report-verdict-v297',{timeout:20000});
  const staffBand=await page.evaluate(()=>document.querySelector('#staffPerfVerdictV297 .report-verdict-v297').innerText.replace(/\s+/g,' ').trim());
  assertTrue(staffBand.includes(`SGD ${(CURRENT_ATTRIBUTED/100).toFixed(2)}`),
    `the headline is the attributed revenue SGD ${(CURRENT_ATTRIBUTED/100).toFixed(2)} (band: ${staffBand})`);
  const staffExpected=expected(CURRENT_ATTRIBUTED,PRIOR_ATTRIBUTED);
  assertTrue(staffBand.includes(staffExpected),`the change reads "${staffExpected}"`);

  /* ---------------- 5. no comparable earlier period ---------------- */
  say('5. a business with no earlier history is told so, and no percentage is invented');
  await openReports('nohistory');
  const noHistoryMoney=await bandText('reportPanelMoneyV294');
  assertTrue(noHistoryMoney.includes('No comparable earlier period'),
    `Sales & Revenue says "No comparable earlier period" (band: ${noHistoryMoney})`);
  assertTrue(!noHistoryMoney.includes('%'),'no percentage appears anywhere in that band');
  assertTrue(noHistoryMoney.includes(`SGD ${(sum(CURRENT_REVENUE)/100).toFixed(2)}`),
    'the current figure still stands on its own');
  const noHistoryCalls=await summaryCalls();
  assertTrue(noHistoryCalls.length===1,
    `the earlier window is not even requested when it predates the business (calls: ${JSON.stringify(noHistoryCalls)})`);
  await page.click('[data-report-tab-v294="busy"]');
  await page.waitForSelector('#reportPanelBusyV294 .report-verdict-v297',{timeout:20000});
  const noHistoryBusy=await bandText('reportPanelBusyV294');
  assertTrue(noHistoryBusy.includes('No comparable earlier period')&&!noHistoryBusy.includes('%'),
    `Efficiency says the same and prints no percentage (band: ${noHistoryBusy})`);
  await page.click('[data-report-tab-v294="returning"]');
  await page.waitForSelector('#reportPanelReturningV294 .report-verdict-v297',{timeout:20000});
  const noHistoryReturning=await bandText('reportPanelReturningV294');
  assertTrue(noHistoryReturning.includes('No comparable earlier period')&&!noHistoryReturning.includes('%'),
    `Customer Retention says the same and prints no percentage (band: ${noHistoryReturning})`);

  /* ---------------- 6. zero baseline ---------------- */
  say('6. a zero previous period is explained in words, never as infinity or a fake 100%');
  await openReports('zerobaseline');
  const zeroMoney=await bandText('reportPanelMoneyV294');
  assertTrue(zeroMoney.includes('there was no revenue in the previous period'),
    `the reason is stated plainly (band: ${zeroMoney})`);
  assertTrue(!zeroMoney.includes('%'),'no percentage is printed from a zero baseline');
  assertTrue(!/∞|Infinity|NaN/.test(zeroMoney),'no infinity and no NaN');
  assertTrue(!zeroMoney.includes('100'),'no fabricated 100 per cent');
  assertTrue(zeroMoney.includes('Up on the previous'),'the direction is still stated in words');
  const zeroCalls=await summaryCalls();
  assertTrue(zeroCalls.length===2,'both windows were still read — the baseline is a real, empty answer');

  /* ---------------- 7. brand-new business, nothing at all ---------------- */
  say('7. a brand-new business with no data at all still reads sensibly on every tab');
  await openReports('empty');
  const emptyMoney=await bandText('reportPanelMoneyV294');
  assertTrue(emptyMoney.includes('SGD 0.00'),`the headline is an honest zero (band: ${emptyMoney})`);
  assertTrue(emptyMoney.includes('No comparable earlier period'),'and it says there is nothing to compare with');
  const emptyPanel=await page.locator('#reportPanelMoneyV294').innerText();
  assertTrue(emptyPanel.includes('No sales in range'),'the Revenue by type card says there were no sales');
  assertTrue(await page.locator('#reportPanelMoneyV294 .report-share-bar-v297').count()===0,
    'no proportional bar is drawn for a business with nothing to proportion');
  assertTrue(emptyPanel.includes('Available balances are current business-wide obligations'),
    'the liability disclosure is still shown to a brand-new business');
  await page.click('[data-report-tab-v294="busy"]');
  await page.waitForSelector('#reportPanelBusyV294 .report-verdict-v297',{timeout:20000});
  const emptyBusy=await bandText('reportPanelBusyV294');
  assertTrue(emptyBusy.includes('0.0 booked hours'),`Efficiency reads sensibly with nothing booked (band: ${emptyBusy})`);
  await page.click('[data-report-tab-v294="returning"]');
  await page.waitForFunction(()=>{
    const panel=document.getElementById('reportPanelReturningV294');
    return panel&&panel.innerText.trim().length>0&&!panel.innerText.includes('Run the report for this period');
  },null,{timeout:20000});
  const emptyReturning=await page.locator('#reportPanelReturningV294').innerText();
  assertTrue(emptyReturning.includes('No eligible recorded purchases exist in this answer period.')
    &&emptyReturning.includes('No zero is inferred.'),
    `Customer Retention explains the absence rather than showing an invented zero ("${emptyReturning.trim().slice(0,90)}…")`);

  if(pageErrors.length)process.stdout.write(`note: page errors observed (non-fatal): ${JSON.stringify(pageErrors)}\n`);
  process.stdout.write('V297 Business Insights walkthrough PASS (steps 1-7)\n');
}catch(error){
  process.stdout.write(`V297 walkthrough FAIL at ${step}\n${error?.stack||error}\n`);
  if(pageErrors.length)process.stdout.write(`page errors: ${JSON.stringify(pageErrors)}\n`);
  process.exitCode=1;
}finally{
  await browser.close().catch(()=>{});
  if(server)server.kill();
}
