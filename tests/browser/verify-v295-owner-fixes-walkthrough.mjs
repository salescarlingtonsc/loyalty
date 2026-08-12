/* V295 owner-fixes walkthrough — the owner's three defects of 2026-08-12/13, scripted.
 *
 * Drives the REAL production bundles (app/index.html + the stamped chunks — run
 * `npm run bundle-stamp` first) through the real router, with the Supabase client replaced by an
 * in-page fixture (same pattern as verify-v294-owner-batch-walkthrough.mjs).
 *
 * Steps (each asserts; the script exits non-zero naming the failing step):
 *   1. Dashboard — ONE date everywhere. Owner: "for date selected should reflect schedule &
 *      Performance … should not be static, must follow selected date".
 *      Tomorrow -> heading "Tomorrow's schedule" AND the Performance subtitle is that single day.
 *      An arbitrary date -> heading names that date. Then the 7d pill -> the schedule card moves
 *      to the range END day and its heading follows; Performance and the KPI tiles agree.
 *   2. Customer 360 on a brand-new customer (zero everything). Owner: "there's an empty box and
 *      UI UX not aligned". No empty cell in the content grid, no points markup orphaned outside
 *      the summary card, the summary card still carries every V294 figure, and the chip row does
 *      not overlap the explainer sentence — asserted by rect intersection, at 1440 and at 390.
 *   3. Publish confirmation. Owner: "this draft is so confusing, i do not know what changed -
 *      just be straight forward without all unnecessary details".
 *      No-change draft -> exactly one sentence and none of the deleted machinery.
 *      Changed draft (reward cost) -> the change is a plain line.
 *      Paused draft -> the PAUSED banner survives; Publish stays disabled until the box is ticked.
 *
 * Run:
 *   PLAYWRIGHT_MODULE=".../playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v295-owner-fixes-walkthrough.mjs
 */
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const APP_DIR=fileURLToPath(new URL('../../app/',import.meta.url));
const PORT=Number(process.env.V295_PORT||4173);
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

/* ---- in-page Supabase fixture ----
   The publish scenario is read from window.__V295SCENARIO at CALL time, so one page can be
   re-navigated through the no-change / changed / paused drafts without a new browser context. */
const BIZ='b1111111-1111-4111-8111-111111111111';
const stubSource=`(()=>{
  const BIZ='${BIZ}';
  window.__V295SCENARIO=window.__V295SCENARIO||'nochange';
  const scenario=()=>String(window.__V295SCENARIO||'nochange');
  const MODULES=['loyalty','retention','referrals','memberships','giftcards','clients','sales','services','till','bookings','reports','inventory','appointments','staffperf','packages'];
  const bizRow={id:BIZ,slug:'testco',name:'Test Co',currency:'SGD',industry:'facial',points_mode:'both',
    enabled_modules:MODULES,active_config_version_id:'pub-1',join_enabled:true,brand_color:'#7c5cff',
    booking_policy:null,quick_earn_catalogue_enabled:true,created_at:'2026-01-01T00:00:00Z'};
  /* The LIVE programme and its one LIVE reward. The draft below mirrors them exactly unless the
     scenario says otherwise — that is what makes "nothing changes" a real no-change draft rather
     than an empty read. */
  const liveProgram={id:'prog-1',business_id:BIZ,active:true,loyalty_model:'points_tiers',
    earn_points_per_dollar:10,redeem_points:100,reward_credit_cents:100,stamp_target:null,
    stamp_per_cents:null,expiry_mode:'none',expiry_days:null,tier_basis:'visits',
    current_config_version_id:'pub-1',configuration_status:'published'};
  const liveReward={id:'lr-live',business_id:BIZ,active:true,customer_name:'Free Moisturiser',
    name:'Free Moisturiser',cost_points:150,credit_cents:0,entitlement_expiry_days:null,
    usage_limit:null,min_tier_id:null,min_tier_threshold:null,estimated_cost_cents:150,sort:1,
    claim_available_from:null,claim_available_until:null,created_at:'2026-06-01T00:00:00Z'};
  const draftProgram=()=>({...liveProgram,active:scenario()==='paused'?false:true});
  const draftRewards=()=>{
    const mirrored={reward_id:'lr-live',name:'Free Moisturiser',customer_name:'Free Moisturiser',
      description:'',cost_points:scenario()==='changed'?1500:150,credit_cents:0,
      estimated_cost_cents:150,entitlement_expiry_days:null,usage_limit:null,min_tier_id:null,
      min_tier_threshold:null,claim_available_from:null,claim_available_until:null,
      fulfillment_kind:'manual_item',sort:1,created_at:'2026-06-01T00:00:00Z',active:true,
      eligibility:{branches:[],services:[]}};
    if(scenario()!=='changed')return [mirrored];
    return [mirrored,{reward_id:'lr-new',name:'Free Lolipop',customer_name:'Free Lolipop',
      description:'',cost_points:50,credit_cents:0,estimated_cost_cents:50,
      entitlement_expiry_days:null,usage_limit:null,min_tier_id:null,min_tier_threshold:null,
      claim_available_from:null,claim_available_until:null,fulfillment_kind:'manual_item',sort:2,
      created_at:'2026-08-01T00:00:00Z',active:true,eligibility:{branches:[],services:[]}}];
  };
  const TABLES={
    businesses:[bizRow],
    branches:[{id:'br1',business_id:BIZ,name:'Orchard',active:true,billing_state:'active'}],
    services:[{id:'sv1',business_id:BIZ,name:'Signature facial',active:true,price_cents:8800}],
    /* Brand-new customer: no sales, no points, no credit, no consent — the profile the owner
       screenshotted. Every zero on this page is a real zero. */
    clients:[{id:'c1',business_id:BIZ,full_name:'Steven Lim',phone:'+65 81234567',email:'',
      referral_code:'STEVEN1',marketing_consent:false}],
    sales:[],appointments:[],points_ledger:[],memberships:[],client_packages:[],waitlist:[],
    client_field_definitions:[],client_field_values:[],client_field_options:[],
    staff:[{id:'st1',business_id:BIZ,full_name:'Owner Person',role:'owner',user_id:'u-owner',
      active:true,email:'owner@test.co',phone:'',title:null,module_perms:null,modules:null,
      commission_service_bps:null,commission_product_bps:null,created_at:'2026-01-01T00:00:00Z'}],
    staff_invites:[],staff_hours:[],staff_branches:[],
    loyalty_programs:[liveProgram],
    loyalty_rewards:[liveReward],
    loyalty_reward_branches:[],loyalty_reward_services:[],loyalty_reward_products:[],
    loyalty_tiers:[{id:'t-gold',business_id:BIZ,name:'Gold',threshold:10}],
    loyalty_branch_overrides:[],
    referral_programs:[{id:'rp1',business_id:BIZ,enabled:true,reward_cents:500,min_spend_cents:2000,created_at:'2026-03-01T00:00:00Z'}],
    membership_plans:[],retention_programs:[],
    firm_config_versions:[{id:'draft-1',business_id:BIZ,version_no:2,based_on_version_id:'pub-1',status:'draft',snapshot_hash:'hash-1'}]
  };
  window.__V295={rpc:[],writes:[]};
  const chainable=resolveOut=>{
    const q={single:false,head:false,countMode:null,op:'select'};
    const chain={};
    for(const m of ['eq','neq','is','in','not','gte','lte','lt','gt','or','ilike','contains','overlaps','order','limit','range'])
      chain[m]=()=>chain;
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
  const query=table=>chainable(q=>{
    if(q.op!=='select'){
      window.__V295.writes.push({table,op:q.op,payload:q.payload??null});
      return {data:null,error:null};
    }
    const rows=TABLES[table]||[];
    if(q.countMode&&q.head)return {data:null,count:rows.length,error:null};
    if(q.single)return {data:rows[0]??null,error:null};
    return {data:rows,count:q.countMode?rows.length:null,error:null};
  });
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
      case 'staff_list_customers_v155':return {customers:[{id:'c1',full_name:'Steven Lim',phone:'+65 81234567',
        points:0,credit_cents:0,last_visit_at:null,created_at:'2026-08-01T00:00:00Z',
        marketing_consent:false,visits:0}],total:1};
      case 'preview_campaign_audience_v155':return {total:0};
      case 'require_module_scope_v145':return null;
      case 'staff_get_customer_actionable_loyalty_v145':return {points_balance:0,credit_balance_cents:0,
        redemption_enabled:false,program:{active:true,unit:'points',earn_points_per_dollar:10,stamp_per_cents:500},
        rewards:[],next_reward:null,expiry:null};
      case 'staff_get_reward_entitlements_v99':return [];
      case 'list_customer_redemption_history_v145':return [];
      case 'staff_list_visit_feedback_v145':return {feedback:[]};
      case 'staff_get_reversal_workflows_v145':return {sales:[],redemptions:[]};
      case 'owner_list_reward_profitability_products_v122':return {items:[]};
      case 'business_get_loyalty_tiers_v143':return [{tier_id:'t-gold',id:'t-gold',name:'Gold',threshold:10,points_multiplier:1,perk_note:'',effective_from:null,expires_at:null}];
      case 'get_loyalty_reward_draft':return {program:draftProgram(),rewards:draftRewards(),
        tiers:[{tier_id:'t-gold',id:'t-gold',name:'Gold',threshold:10,points_multiplier:1,perk_note:'',effective_from:null,expires_at:null}],
        snapshot_hash:'hash-1'};
      case 'get_program_rules_draft':return {version_no:2,rules:[]};
      case 'get_retention_config_draft':return {programs:[]};
      case 'get_birthday_program_draft':return {programs:[]};
      case 'get_active_birthday_program':return {programs:[]};
      /* No advanced rules and no forced confirmation: the case the owner screenshotted, where the
         deleted safety boxes had nothing at all to report. */
      case 'preview_publish_impact':return {rules:[],requires_confirmation:false};
      case 'business_get_customer_capabilities_v89':return {redemption_enabled:false};
      case 'business_get_promotion_editor_v155':return {items:[],entitlement:null};
      case 'business_get_checkout_preferences_v102':return null;
      case 'business_get_welcome_offer_v215':return {configured:false};
      case 'business_programme_usage_v271':return null;
      default:return null;
    }
  };
  const rpc=(name,args)=>{
    window.__V295.rpc.push({name,args:args??null});
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
  const bodyText=()=>page.evaluate(()=>document.body.innerText);
  const go=async hash=>{await page.evaluate(h=>{location.hash=h},hash)};
  const sgDay=offset=>page.evaluate(o=>{
    const parts=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Singapore',year:'numeric',month:'2-digit',day:'2-digit'})
      .format(new Date(Date.now()+o*864e5));
    return parts;
  },offset);
  const sgLabel=input=>page.evaluate(value=>new Intl.DateTimeFormat('en-SG',
    {day:'numeric',month:'short',year:'numeric',timeZone:'Asia/Singapore'})
    .format(new Date(`${value}T00:00:00+08:00`)),input);

  /* ---------------- 1. one date everywhere ---------------- */
  say('1a. schedule heading follows the chosen day (Tomorrow)');
  await page.goto(`${ORIGIN}/index.html#/dashboard`,{waitUntil:'domcontentloaded'});
  await page.waitForSelector('#dashboardScheduleHeadingV295',{timeout:20000});
  assertTrue((await page.locator('#dashboardScheduleHeadingV295').innerText()).trim()==='Today schedule',
    'first paint heading reads "Today schedule"');
  const tomorrow=await sgDay(1);
  const tomorrowLabel=await sgLabel(tomorrow);
  await page.click('[data-schedule-day-v252="1"]');
  await page.waitForFunction(()=>document.getElementById('dashboardScheduleHeadingV295')?.textContent.trim()==='Tomorrow’s schedule',
    null,{timeout:20000});
  assertTrue(true,'heading reads "Tomorrow’s schedule" after the Tomorrow tab');
  await page.waitForFunction(label=>document.getElementById('dashboardPerformancePeriod')?.textContent.trim()===`${label} to ${label}`,
    tomorrowLabel,{timeout:20000});
  assertTrue(true,`Performance subtitle is the single day "${tomorrowLabel} to ${tomorrowLabel}"`);

  say('1b. an arbitrary date names itself in the heading');
  const arbitrary=await sgDay(9);
  const arbitraryLabel=await sgLabel(arbitrary);
  await page.fill('#dashboardScheduleDate',arbitrary);
  await page.waitForFunction(label=>document.getElementById('dashboardScheduleHeadingV295')?.textContent.trim()===`Schedule · ${label}`,
    arbitraryLabel,{timeout:20000});
  assertTrue(true,`heading reads "Schedule · ${arbitraryLabel}"`);
  await page.waitForFunction(label=>document.getElementById('dashboardPerformancePeriod')?.textContent.trim()===`${label} to ${label}`,
    arbitraryLabel,{timeout:20000});
  assertTrue(true,'Performance subtitle followed the picked date');

  say('1c. the top range moves the schedule card to the range END day');
  const today=await sgDay(0);
  const todayLabel=await sgLabel(today);
  const rangeStart=await sgDay(-6);
  const rangeStartLabel=await sgLabel(rangeStart);
  await page.click('.qbtn[data-d="7"]');
  await page.waitForFunction(()=>document.getElementById('dashboardScheduleHeadingV295')?.textContent.trim()==='Today schedule',
    null,{timeout:20000});
  assertTrue(true,'the 7d pill moved the schedule card to the range end day and the heading followed');
  assertTrue(await page.inputValue('#dashboardScheduleDate')===today,
    'the schedule date input holds that same day');
  assertTrue(await page.getAttribute('[data-schedule-day-v252="0"]','aria-pressed')==='true'
    &&await page.getAttribute('[data-schedule-day-v252="1"]','aria-pressed')==='false',
    'the Today tab is re-lit and Tomorrow is not');
  await page.waitForFunction(labels=>document.getElementById('dashboardPerformancePeriod')?.textContent.trim()===`${labels[0]} to ${labels[1]}`,
    [rangeStartLabel,todayLabel],{timeout:20000});
  assertTrue(true,`Performance subtitle reads the 7-day range "${rangeStartLabel} to ${todayLabel}"`);
  const rangeInputs=await page.evaluate(()=>({from:document.getElementById('df').value,to:document.getElementById('dt').value}));
  assertTrue(rangeInputs.from===rangeStart&&rangeInputs.to===today,
    'the From/To pair is the same resolved range the subtitle prints');
  await page.waitForSelector('[data-dashboard-metric]',{timeout:20000});
  const metricKeys=await page.evaluate(()=>[...document.querySelectorAll('[data-dashboard-metric]')].map(n=>n.dataset.dashboardMetric));
  assertTrue(metricKeys.includes('visits')&&metricKeys.includes('revenue')&&metricKeys.includes('new')&&metricKeys.includes('inactive'),
    'the four KPI drill-through tiles rendered against that same applied range');
  assertTrue(!(await bodyText()).includes('Apply the new range to refresh these figures'),
    'no KPI tile is left showing a stale-range placeholder');

  /* ---------------- 2. customer 360 layout ---------------- */
  const c360Checks=async width=>{
    await page.waitForSelector('#c360SummaryV294',{timeout:20000});
    await page.waitForSelector('.c360-content-split-v295',{timeout:20000});
    const report=await page.evaluate(()=>{
      const split=document.querySelector('.c360-content-split-v295');
      const cells=[...split.children].map(cell=>({cls:cell.className,text:cell.innerText.trim().length}));
      const summary=document.getElementById('c360SummaryV294');
      const pointsNodes=[...document.querySelectorAll('.customer360-points-open-v259,.c360-points-expiry,.customer360-points-paused-v259')];
      const orphaned=pointsNodes.filter(node=>!summary.contains(node)).length;
      const chips=document.querySelector('.c360-badges');
      const explainer=[...document.querySelectorAll('p.muted.small')]
        .find(p=>p.innerText.startsWith('Record an eligible first purchase'));
      const overlap=(a,b)=>{
        const r1=a.getBoundingClientRect(),r2=b.getBoundingClientRect();
        return !(r1.bottom<=r2.top||r2.bottom<=r1.top||r1.right<=r2.left||r2.right<=r1.left);
      };
      return {cells,orphaned,pointsNodes:pointsNodes.length,
        summaryText:summary.innerText,
        summaryTop:Math.round(summary.getBoundingClientRect().top),
        splitTop:Math.round(split.getBoundingClientRect().top),
        hasExplainer:Boolean(explainer),
        overlaps:Boolean(chips&&explainer&&overlap(chips,explainer))};
    });
    assertTrue(report.cells.length>0,`[${width}px] the content grid rendered ${report.cells.length} cells`);
    const empty=report.cells.filter(cell=>cell.text===0);
    assertTrue(empty.length===0,`[${width}px] no empty card in the content grid (empty: ${JSON.stringify(empty)})`);
    assertTrue(report.pointsNodes>0&&report.orphaned===0,
      `[${width}px] all ${report.pointsNodes} points elements live inside the summary card, none orphaned`);
    for(const needle of ['Visits','Lifetime spend','Points','Spendable credit','PDPA consent'])
      assertTrue(report.summaryText.includes(needle),`[${width}px] summary card still carries "${needle}"`);
    assertTrue(report.hasExplainer,`[${width}px] the first-purchase explainer is on the page`);
    assertTrue(!report.overlaps,`[${width}px] the status chip row does not overlap the explainer sentence`);
    return report;
  };
  say('2a. customer 360 at desktop 1440');
  await go('#/client/c1');
  const desktop=await c360Checks(1440);
  assertTrue(desktop.summaryTop>=desktop.splitTop-2,
    '[1440px] the summary card sits inside the content grid, not above an empty left column');

  say('2b. customer 360 at mobile 390');
  await page.setViewportSize({width:390,height:900});
  await page.waitForTimeout(400);
  const mobile=await c360Checks(390);
  assertTrue(mobile.summaryTop<=mobile.splitTop+8,
    '[390px] the summary card stacks at the top of the content, it does not float between cards');
  await page.setViewportSize({width:1440,height:1000});
  await page.waitForTimeout(300);

  /* ---------------- 3. publish confirmation ---------------- */
  const openPublishDialog=async scenario=>{
    await page.evaluate(s=>{window.__V295SCENARIO=s;sessionStorage.setItem('nestly:grow-publish-review:draft-1','1')},scenario);
    await go('#/dashboard');
    await page.waitForSelector('#dashboardScheduleHeadingV295',{timeout:20000});
    await go('#/studio/draft-1');
    await page.waitForSelector('#growPublishReview',{timeout:20000});
    await page.waitForFunction(()=>{
      const body=document.getElementById('growPublishDiffBody');
      return body&&!body.innerText.includes('Loading what changes for customers');
    },null,{timeout:20000});
    /* The gate auto-opens the confirmation once the comparison read settles (queueMicrotask
       after comparisonReadyV258), so this waits for it rather than pressing a button that the
       already-open dialog is covering. */
    await page.waitForSelector('#growPubModal',{timeout:20000});
    return page.locator('#growPubModal').innerText();
  };

  say('3a. a no-change draft says it once and drops the ceremony');
  const noChangeText=await openPublishDialog('nochange');
  const sentence='Nothing changes for customers in this draft.';
  const occurrences=noChangeText.split(sentence).length-1;
  assertTrue(occurrences===1,`the dialog says "${sentence}" exactly once (found ${occurrences})`);
  assertTrue(!noChangeText.includes('Server-confirmed advanced-action safety'),
    '"Server-confirmed advanced-action safety" is absent');
  assertTrue(!noChangeText.includes('Safety check complete'),'"Safety check complete" is absent');
  assertTrue(!noChangeText.includes('advanced-rule changes'),
    'no box announces the absence of advanced-rule changes');
  const reviewPageText=await page.evaluate(()=>document.getElementById('growPublishDiffCard').innerText);
  assertTrue((reviewPageText.split(sentence).length-1)===1,'the review page behind it says it once too');
  assertTrue(await page.locator('#growPublishTechnicalV295').count()===1,
    'the review page machinery lives in a Technical detail disclosure');
  assertTrue(!await page.locator('#growPublishTechnicalV295[open]').count(),
    'that disclosure starts collapsed');
  /* textContent, not innerText — a collapsed <details> reports no text for its hidden body. */
  const technicalText=await page.evaluate(()=>document.getElementById('growPublishTechnicalV295').textContent);
  for(const kept of ['welcome offer is not part of this draft',
    'compared with the programme customers earn on today',
    'lists every programme, reward, birthday and bring-back value this draft changes'])
    assertTrue(technicalText.includes(kept),`Technical detail keeps "${kept}"`);
  await page.click('#growPubCancel');
  await page.waitForFunction(()=>!document.getElementById('growPubModal'),null,{timeout:20000});

  say('3b. a changed draft leads with the concrete change');
  const changedText=await openPublishDialog('changed');
  assertTrue(!changedText.includes(sentence),'the no-change sentence is NOT shown when something changed');
  const changeLine=await page.evaluate(()=>[...document.querySelectorAll('#growPubModal .studio-change-list-v295 li')].map(li=>li.innerText.replace(/\s+/g,' ').trim()));
  assertTrue(changeLine.length>0,`the change list rendered ${changeLine.length} plain lines`);
  assertTrue(changeLine.some(line=>line.includes('Free Moisturiser')&&line.includes('150')&&line.includes('1500')),
    `the reward cost change is one plain line (${JSON.stringify(changeLine)})`);
  assertTrue(changeLine.some(line=>line.includes('Free Lolipop')&&line.includes('now offered')),
    'the added reward is one plain line');
  assertTrue(!changedText.includes('Server-confirmed advanced-action safety')&&!changedText.includes('Safety check complete'),
    'the deleted machinery stays deleted on a changed draft too');
  await page.click('#growPubCancel');
  await page.waitForFunction(()=>!document.getElementById('growPubModal'),null,{timeout:20000});

  say('3c. paused draft keeps its warning; Publish stays gated on the checkbox');
  const pausedText=await openPublishDialog('paused');
  assertTrue(pausedText.includes('This will publish PAUSED'),'the PAUSED warning banner is still present');
  assertTrue(await page.locator('#growPubConfirm').isDisabled(),'Publish now starts disabled');
  await page.check('#growPubType');
  await page.waitForFunction(()=>!document.getElementById('growPubConfirm').disabled,null,{timeout:20000});
  assertTrue(true,'Publish now enables only after the acknowledgement is ticked');

  if(pageErrors.length)process.stdout.write(`note: page errors observed (non-fatal): ${JSON.stringify(pageErrors)}\n`);
  process.stdout.write('V295 owner fixes walkthrough PASS (steps 1-3)\n');
}catch(error){
  process.stdout.write(`V295 walkthrough FAIL at ${step}\n${error?.stack||error}\n`);
  if(pageErrors.length)process.stdout.write(`page errors: ${JSON.stringify(pageErrors)}\n`);
  process.exitCode=1;
}finally{
  await browser.close().catch(()=>{});
  if(server)server.kill();
}
