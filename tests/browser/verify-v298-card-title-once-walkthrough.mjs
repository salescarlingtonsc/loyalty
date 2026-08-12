/* V298 card-title-once walkthrough — owner report 2026-08-13, from a live Business Insights
 * screenshot: every table card printed its title TWICE, the card heading followed by a smaller
 * grey line repeating the same words ("Revenue by type", "Reversal reconciliation", "Loyalty
 * flow (business-wide, selected period)", "Liabilities (business-wide, now)").
 *
 * Mechanism (fixed in app/customer-ui.js): a workspace card is written as
 * `<div class="card"><b>Revenue by type</b><table>…`, and CUI.enhanceTables synthesised a
 * <caption> whose text tableCaption() had just copied off that very <b>. The duplication was
 * structural, so this walkthrough is structural too: it does not pin the four strings from the
 * screenshot, it walks EVERY table card on several surfaces and proves the shape.
 *
 * Drives the REAL production bundles (app/index.html + the stamped chunks — run
 * `npm run bundle-stamp` first) through the real router, with the Supabase client replaced by the
 * in-page fixture from verify-v297-insights-walkthrough.mjs.
 *
 * On each surface, for every card that contains a table:
 *   (a) the card's own title appears exactly ONCE in the card's VISIBLE text. Visibility is
 *       computed, not assumed: an .sr-only caption is clipped to 1x1 and does not count.
 *   (b) every rendered <table> still has a non-empty accessible name — caption text, or
 *       aria-label, or aria-labelledby resolving to text. Deleting the duplicate must never
 *       leave a screen-reader user in front of an unnamed grid.
 *   (c) no table renders an empty <caption> element, and none renders two.
 *
 * Surfaces: Business Insights (all four tabs: Sales & Revenue, Efficiency, Customer Retention,
 * Team Performance), the Dashboard, Customers, and Services.
 *
 * Run:
 *   PLAYWRIGHT_MODULE=".../playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v298-card-title-once-walkthrough.mjs
 */
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const APP_DIR=fileURLToPath(new URL('../../app/',import.meta.url));
/* 4173/4196/4197 belong to other worktrees' walkthroughs; evidence captured from one of those
   would be evidence about somebody else's tree. This suite owns 4201. */
const PORT=Number(process.env.V298_PORT||4201);
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
  const scenario=()=>{try{return new URLSearchParams(location.search).get('v298')||'normal'}catch{return 'normal'}};
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
  window.__V298WINDOWS={today:TODAY,curFrom:CUR_FROM,curTo:CUR_TO,priorFrom:PRIOR_FROM,priorTo:PRIOR_TO};

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
    /* V298: one recorded sale, which is all the Sales ledger needs to render its table — the
       surface exists in this walkthrough to prove the fix is in the shared helper, not in the
       report page. get_reports_summary is stubbed as an RPC, so this row changes no figure. */
    sales:[{id:'sale1',business_id:BIZ,branch_id:'br1',client_id:'c1',kind:'service',amount_cents:8800,
      occurred_at:at(dayShift(TODAY,-3),12),note:'Signature facial',status:'recorded',reversal_of:null,
      staff_id:'st1',created_at:at(dayShift(TODAY,-3),12)}],points_ledger:[],memberships:[],client_packages:[],waitlist:[],
    staff:[{id:'st1',business_id:BIZ,full_name:'Owner Person',role:'owner',user_id:'u-owner',
      active:true,email:'owner@test.co',phone:'',title:null,module_perms:null,modules:null,
      commission_service_bps:null,commission_product_bps:null,created_at:'2024-01-01T00:00:00Z'}],
    staff_invites:[],staff_hours:[],staff_branches:[],staff_off_days:[],branch_hours:[],branch_breaks:[],
    loyalty_programs:[],loyalty_rewards:[],membership_plans:[],retention_programs:[]
  });

  window.__V298={rpc:[]};
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
    window.__V298.rpc.push({name,args:args??null});
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

  /* The audit runs IN THE PAGE against real layout, because the whole question is what a sighted
     visitor can see. innerText is not enough: an .sr-only caption is still rendered, so it lands
     in innerText — the visibility test below has to look at the geometry the clip produces. */
  const auditV298=()=>page.evaluate(()=>{
    const visible=node=>{
      for(let el=node.nodeType===3?node.parentElement:node;el&&el.nodeType===1;el=el.parentElement){
        const cs=getComputedStyle(el);
        if(cs.display==='none'||cs.visibility==='hidden'||Number(cs.opacity)===0)return false;
        if(el.getAttribute('aria-hidden')==='true')return false;
        const rect=el.getBoundingClientRect();
        /* .sr-only clips to a 1x1 box; anything that small carries no readable text. */
        if(rect.width<2&&rect.height<2)return false;
      }
      return true;
    };
    const visibleText=root=>{
      const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
      const parts=[];
      for(let node=walker.nextNode();node;node=walker.nextNode())
        if(node.nodeValue.trim()&&visible(node))parts.push(node.nodeValue.trim());
      return parts.join(' ').replace(/\s+/g,' ').trim();
    };
    const main=document.querySelector('main')||document.body;
    const accessibleName=table=>{
      const caption=table.querySelector(':scope > caption');
      if(caption&&caption.textContent.trim())return caption.textContent.trim();
      const label=(table.getAttribute('aria-label')||'').trim();
      if(label)return label;
      return (table.getAttribute('aria-labelledby')||'').split(/\s+/).filter(Boolean)
        .map(id=>document.getElementById(id)?.textContent.trim()||'').join(' ').trim();
    };
    const tables=[...main.querySelectorAll('table')].filter(visible).map(table=>({
      name:accessibleName(table),
      captions:table.querySelectorAll(':scope > caption').length,
      emptyCaption:[...table.querySelectorAll(':scope > caption')].some(caption=>!caption.textContent.trim()),
      captionVisible:(()=>{const caption=table.querySelector(':scope > caption');return caption?visible(caption):null})(),
      headers:[...table.querySelectorAll('th')].slice(0,3).map(th=>th.textContent.trim())
    }));
    const cards=[];
    for(const card of main.querySelectorAll('.card,.platform-detail-section')){
      if(!card.querySelector('table'))continue;
      const heading=[...card.querySelectorAll('h1,h2,h3,h4,.cui-card-head,b,strong')]
        .find(node=>!node.closest('table')&&node.textContent.trim()&&visible(node));
      if(!heading)continue;
      const title=heading.textContent.trim();
      const text=visibleText(card);
      let count=0;
      for(let index=text.indexOf(title);index!==-1;index=text.indexOf(title,index+title.length))count++;
      cards.push({title,count});
    }
    return {cards,tables};
  });

  /* One surface, one verdict — every assertion names the offending card or table so a failure is
     actionable without re-running with a debugger. */
  const checkSurfaceV298=async(surface,{minCards=1,minTables=1}={})=>{
    const {cards,tables}=await auditV298();
    assertTrue(tables.length>=minTables,
      `${surface}: ${tables.length} rendered table(s) found (expected at least ${minTables})`);
    assertTrue(cards.length>=minCards,
      `${surface}: ${cards.length} headed table card(s) audited (expected at least ${minCards})`);
    const doubled=cards.filter(card=>card.count!==1);
    assertTrue(doubled.length===0,doubled.length
      ?`${surface}: these card titles are NOT printed exactly once — ${JSON.stringify(doubled)}`
      :`${surface}: every card title is printed exactly once — ${cards.map(card=>`"${card.title}"`).join(', ')||'no headed cards here'}`);
    const unnamed=tables.filter(table=>!table.name);
    assertTrue(unnamed.length===0,unnamed.length
      ?`${surface}: table(s) with no accessible name — ${JSON.stringify(unnamed)}`
      :`${surface}: all ${tables.length} rendered table(s) keep a non-empty accessible name (${tables.map(table=>`"${table.name}"`).join(', ')})`);
    const empties=tables.filter(table=>table.emptyCaption||table.captions>1);
    assertTrue(empties.length===0,empties.length
      ?`${surface}: empty or duplicated <caption> — ${JSON.stringify(empties)}`
      :`${surface}: no empty and no duplicated <caption> element`);
    return {cards,tables};
  };

  const openV298=async hash=>{
    await page.goto(`${ORIGIN}/index.html#/dashboard`,{waitUntil:'domcontentloaded'});
    await page.waitForSelector('#dashboardScheduleHeadingV295',{timeout:20000});
    if(hash==='#/dashboard')return;
    await page.evaluate(target=>{location.hash=target},hash);
  };

  /* ---------------- 1. Business Insights, the surface in the owner's screenshot ---------------- */
  say('1a. Business Insights — Sales & Revenue');
  await openV298('#/reports');
  await page.waitForSelector('#reportPanelMoneyV294 .report-verdict-v297,#reportPanelMoneyV294 .empty,#reportPanelMoneyV294 .err',{timeout:20000});
  const money=await checkSurfaceV298('Insights · Sales & Revenue',{minCards:3});
  /* The four cards the owner photographed, by name, so this walkthrough still speaks to the
     report it came from even though the assertions above are structural. */
  for(const title of ['Revenue by type','Reversal reconciliation'])
    assertTrue(money.cards.some(card=>card.title===title),`the owner's card "${title}" was audited`);

  say('1b. Business Insights — Efficiency');
  await page.click('[data-report-tab-v294="busy"]');
  await page.waitForSelector('#reportPanelBusyV294 .report-verdict-v297',{timeout:20000});
  await checkSurfaceV298('Insights · Efficiency');

  say('1c. Business Insights — Customer Retention');
  await page.click('[data-report-tab-v294="returning"]');
  await page.waitForSelector('#reportPanelReturningV294 .report-verdict-v297',{timeout:20000});
  await checkSurfaceV298('Insights · Customer Retention');

  say('1d. Business Insights — Team Performance');
  await page.click('[data-report-tab-href-v294="#/staffperf"]');
  await page.waitForSelector('#staffPerfVerdictV297 .report-verdict-v297',{timeout:20000});
  /* Staff performance writes its heading outside the card that holds the table, so there is no
     headed card to audit here — but the table itself must still carry a name. */
  const staff=await checkSurfaceV298('Insights · Team Performance',{minCards:0});
  /* V298 gap sweep: this table used to be named after its own first cell ("Owner Person") because
     tableCaption took the first <b> in the card, and a staff name is a <b> in a row. A name that
     is a copy of a cell is no name at all — it now falls through to the page heading. */
  assertTrue(staff.tables.every(table=>table.name==='Staff performance'),
    `the Team Performance table is named after the page, not after its first cell (${staff.tables.map(table=>`"${table.name}"`).join(', ')})`);

  /* ---------------- 2-3. the rest of the workspace shares the same helper ---------------- */
  say('2. Services');
  await openV298('#/services');
  await page.waitForSelector('main table',{timeout:20000});
  await checkSurfaceV298('Services',{minCards:2,minTables:2});

  say('3. Sales ledger');
  await openV298('#/sales');
  await page.waitForSelector('main table',{timeout:20000});
  await checkSurfaceV298('Sales ledger');

  /* ---------------- 5. the hidden name is a REAL name, not a deleted one ---------------- */
  say('5. the surviving caption is hidden from sight but not from assistive technology');
  await openV298('#/reports');
  await page.waitForSelector('#reportPanelMoneyV294 .report-verdict-v297,#reportPanelMoneyV294 .empty',{timeout:20000});
  const captionShape=await page.evaluate(()=>{
    const table=[...document.querySelectorAll('main .card')]
      .filter(card=>card.querySelector('table'))
      .map(card=>card.querySelector('table'))[0];
    const caption=table?.querySelector(':scope > caption');
    if(!caption)return null;
    const rect=caption.getBoundingClientRect();
    return {text:caption.textContent.trim(),srOnly:caption.classList.contains('sr-only'),
      inDom:document.contains(caption),width:Math.round(rect.width),height:Math.round(rect.height)};
  });
  assertTrue(Boolean(captionShape),'the first Insights table still carries a <caption> element');
  assertTrue(captionShape.text.length>0,`the caption still reads "${captionShape.text}" — the table has a name`);
  assertTrue(captionShape.srOnly,'the caption is carried by the document\'s existing .sr-only utility');
  assertTrue(captionShape.width<2&&captionShape.height<2,
    `the caption occupies no visible space (${captionShape.width}x${captionShape.height})`);

  /* ---------------- 6. the platform console, which never runs the workspace enhancer -------- */
  say('6. the platform console gets the caption rule on its own, and only the caption rule');
  const consoleShape=await page.evaluate(()=>{
    /* Console markup, reproduced exactly as platform-console.js emits it: a CUI.card title and a
       CUI.table caption that are the same words ("Loss reasons"), next to a hand-written caption
       that states a fact the heading does not ("42 archived"). */
    const host=document.createElement('div');
    host.innerHTML=`
      <div class="card"><h3>Loss reasons</h3>
        <div class="cui-table-wrap" role="region" aria-label="Loss reasons" tabindex="0">
          <table class="cui-table"><caption>Loss reasons</caption>
          <thead><tr><th scope="col">Reason</th></tr></thead><tbody><tr><td>Price</td></tr></tbody></table>
        </div>
      </div>
      <div class="card"><h3>Archived firms</h3>
        <table class="cui-table"><caption>42 archived</caption>
        <thead><tr><th scope="col">Firm</th></tr></thead><tbody><tr><td>Test Co</td></tr></tbody></table>
      </div>`;
    (document.querySelector('main')||document.body).append(host);
    const observer=window.FrenlyCustomerUI.observeTableCaptionsV298(host);
    const read=index=>{
      const caption=host.querySelectorAll('caption')[index];
      const rect=caption.getBoundingClientRect();
      return {text:caption.textContent.trim(),srOnly:caption.classList.contains('sr-only'),
        width:Math.round(rect.width),height:Math.round(rect.height)};
    };
    const shape={duplicate:read(0),informative:read(1),
      /* the console tables must come out of this untouched apart from the caption */
      dataLabels:host.querySelectorAll('td[data-label]').length,
      responsiveFlags:host.querySelectorAll('table[data-responsive]').length};
    observer.disconnect();host.remove();
    return shape;
  });
  assertTrue(consoleShape.duplicate.srOnly&&consoleShape.duplicate.width<2,
    `a console caption that repeats its card heading is hidden ("${consoleShape.duplicate.text}")`);
  assertTrue(consoleShape.duplicate.text==='Loss reasons',
    'and the hidden caption still names the table for assistive technology');
  assertTrue(!consoleShape.informative.srOnly&&consoleShape.informative.width>2,
    `a caption that says something the heading does not stays visible ("${consoleShape.informative.text}")`);
  assertTrue(consoleShape.dataLabels===0&&consoleShape.responsiveFlags===0,
    'the console observer changed captions only — no data-label, no responsive flag, no rewrapping');

  if(pageErrors.length)process.stdout.write(`note: page errors observed (non-fatal): ${JSON.stringify(pageErrors)}\n`);
  process.stdout.write('V298 card-title-once walkthrough PASS (steps 1-6)\n');
}catch(error){
  process.stdout.write(`V298 walkthrough FAIL at ${step}\n${error?.stack||error}\n`);
  if(pageErrors.length)process.stdout.write(`page errors: ${JSON.stringify(pageErrors)}\n`);
  process.exitCode=1;
}finally{
  await browser.close().catch(()=>{});
  if(server)server.kill();
}
