/* V294 owner-batch walkthrough — the owner's 9 iPad markups of 2026-08-12, scripted.
 *
 * Drives the REAL production bundles (app/index.html + the stamped chunks — run
 * `npm run bundle-stamp` first) through the real router, with the Supabase client replaced by an
 * in-page fixture (same pattern as verify-v293-reward-editor-walkthrough.mjs).
 *
 * Steps (each asserts; the script exits non-zero naming the failing step):
 *   1. Dashboard: picking a schedule day ALSO sets the Performance figures to that day, and the
 *      helper copy states it (V295: "Linked both ways with the figures below.").
 *   2. Customers: exactly ONE "Show customers by last visit" control (duplicate bar removed),
 *      and the kept control carries the all_inactive bucket.
 *   3. Customer 360: upper-right summary card holds visits / lifetime spend / PDPA / points /
 *      credit; the two big POINTS / SPENDABLE CREDIT tiles are gone; Available Customer
 *      Programmes lists programme rows including a Paused pill for the paused loyalty programme.
 *   4. Nav: Programmes is a group with Overview / List / History children; each lands on the
 *      matching #/grow view.
 *   5. Catalogue: a retired reward is absent from the offer grid/list and lives in the collapsed
 *      Reward history; Edit from history still opens.
 *   6. Loyalty editor: entered from the Points redemption card -> no "Your tiers"; entered from
 *      the Tiered membership card -> tiers present; no "Back to Grow overview" button anywhere.
 *   7. Programmes overview: "1 LIVE" promotions copy; no "Memberships & gift cards" card; the
 *      owner's new blurbs present; Gift cards reachable from the Serve & sell nav group.
 *   8. Business Insights: 4 tabs incl. "Efficiency"; switching tabs swaps the panel; From/To
 *      persists across the switch.
 *   9. Staff Members: the roster group heading reads "Team members" (never "Roster only").
 *
 * Run:
 *   PLAYWRIGHT_MODULE=".../playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v294-owner-batch-walkthrough.mjs
 */
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const APP_DIR=fileURLToPath(new URL('../../app/',import.meta.url));
const PORT=Number(process.env.V294_PORT||4173);
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

/* ---- in-page Supabase fixture (v293 pattern, widened for the 9 surfaces) ---- */
const BIZ='b1111111-1111-4111-8111-111111111111';
const stubSource=`(()=>{
  const BIZ='${BIZ}';
  const state={
    snapshotHash:'hash-1',nextId:1,
    program:{id:'prog-1',business_id:BIZ,active:false,loyalty_model:'points_tiers',
      earn_points_per_dollar:10,redeem_points:100,reward_credit_cents:100,expiry_mode:'none',
      expiry_days:null,tier_basis:'visits',current_config_version_id:'pub-1',configuration_status:'published'},
    /* Draft rewards MIRROR the live catalogue (same ids), so the pending-diff marks nothing:
       one offerable reward and one RETIRED one — the pair item 5 is about. */
    draftRewards:[
      {reward_id:'lr-live',name:'Free Coffee',customer_name:'Free Coffee',description:'',
       cost_points:100,credit_cents:0,estimated_cost_cents:100,entitlement_expiry_days:null,
       usage_limit:null,min_tier_id:null,min_tier_threshold:null,claim_available_from:null,
       claim_available_until:null,fulfillment_kind:'manual_item',sort:1,created_at:'2026-06-01T00:00:00Z',
       eligibility:{branches:[],services:[],products:[]}},
      {reward_id:'lr-retired',name:'Free Lolipop',customer_name:'Free Lolipop',description:'',
       cost_points:50,credit_cents:0,estimated_cost_cents:50,entitlement_expiry_days:null,
       usage_limit:null,min_tier_id:null,min_tier_threshold:null,claim_available_from:null,
       claim_available_until:null,fulfillment_kind:'manual_item',sort:2,created_at:'2026-05-01T00:00:00Z',
       active:false,eligibility:{branches:[],services:[],products:[]}}
    ],
    tiers:[{tier_id:'t-gold',id:'t-gold',name:'Gold',threshold:10,points_multiplier:1,perk_note:'',effective_from:null,expires_at:null}]
  };
  window.__V294={rpc:[],writes:[],state};
  const MODULES=['loyalty','retention','referrals','memberships','giftcards','clients','sales','services','till','bookings','reports','inventory','appointments','staffperf','packages'];
  const bizRow={id:BIZ,slug:'testco',name:'Test Co',currency:'SGD',industry:'facial',points_mode:'both',
    enabled_modules:MODULES,active_config_version_id:'pub-1',join_enabled:true,brand_color:'#7c5cff',
    booking_policy:null,quick_earn_catalogue_enabled:true,created_at:'2026-01-01T00:00:00Z'};
  const TABLES={
    businesses:[bizRow],
    branches:[{id:'br1',business_id:BIZ,name:'Orchard',active:true,billing_state:'active'}],
    services:[{id:'sv1',business_id:BIZ,name:'Signature facial',active:true,price_cents:8800}],
    clients:[{id:'c1',business_id:BIZ,full_name:'Alice Tan',phone:'+65 81234567',email:'alice@test.co',
      referral_code:'ALICE1',marketing_consent:true}],
    sales:[
      {id:'s1',business_id:BIZ,client_id:'c1',branch_id:'br1',amount_cents:3000,kind:'service',
       counts_as_visit:true,counts_as_revenue:true,reversal_of:null,reversal_reason:null,
       occurred_at:'2026-08-01T03:00:00Z',note:null,staff_id:null},
      {id:'s2',business_id:BIZ,client_id:'c1',branch_id:'br1',amount_cents:3000,kind:'service',
       counts_as_visit:true,counts_as_revenue:true,reversal_of:null,reversal_reason:null,
       occurred_at:'2026-08-05T03:00:00Z',note:null,staff_id:null}
    ],
    appointments:[],points_ledger:[],memberships:[],client_packages:[],waitlist:[],
    client_field_definitions:[],client_field_values:[],client_field_options:[],
    staff:[
      {id:'st1',business_id:BIZ,full_name:'Owner Person',role:'owner',user_id:'u-owner',active:true,
       email:'owner@test.co',phone:'',title:null,module_perms:null,modules:null,
       commission_service_bps:null,commission_product_bps:null,created_at:'2026-01-01T00:00:00Z'},
      {id:'st2',business_id:BIZ,full_name:'Mei Lin',role:'staff',user_id:null,active:true,
       email:'',phone:'',title:null,module_perms:null,modules:null,
       commission_service_bps:null,commission_product_bps:null,created_at:'2026-02-01T00:00:00Z'}
    ],
    staff_invites:[],staff_hours:[],staff_branches:[],
    loyalty_programs:[state.program],
    loyalty_rewards:[
      {id:'lr-live',business_id:BIZ,active:true,customer_name:'Free Coffee',name:'Free Coffee',
       cost_points:100,credit_cents:0,entitlement_expiry_days:null,usage_limit:null,min_tier_id:null,
       min_tier_threshold:null,estimated_cost_cents:100,sort:1,claim_available_from:null,
       claim_available_until:null,created_at:'2026-06-01T00:00:00Z'},
      {id:'lr-retired',business_id:BIZ,active:false,customer_name:'Free Lolipop',name:'Free Lolipop',
       cost_points:50,credit_cents:0,entitlement_expiry_days:null,usage_limit:null,min_tier_id:null,
       min_tier_threshold:null,estimated_cost_cents:50,sort:2,claim_available_from:null,
       claim_available_until:null,created_at:'2026-05-01T00:00:00Z'}
    ],
    loyalty_reward_branches:[],loyalty_reward_services:[],loyalty_reward_products:[],
    loyalty_tiers:[{id:'t-gold',business_id:BIZ,name:'Gold',threshold:10}],
    loyalty_branch_overrides:[],
    referral_programs:[{id:'rp1',business_id:BIZ,enabled:true,reward_cents:500,min_spend_cents:2000,created_at:'2026-03-01T00:00:00Z'}],
    membership_plans:[],retention_programs:[],
    firm_config_versions:[{id:'draft-1',business_id:BIZ,version_no:2,based_on_version_id:'pub-1',status:'draft',snapshot_hash:'hash-1'}]
  };
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
      window.__V294.writes.push({table,op:q.op,payload:q.payload??null});
      return {data:null,error:null};
    }
    const rows=TABLES[table]||[];
    if(q.countMode&&q.head)return {data:null,count:rows.length,error:null};
    if(q.single)return {data:rows[0]??null,error:null};
    return {data:rows,count:q.countMode?rows.length:null,error:null};
  });
  const draftPayload=()=>({program:{...state.program},rewards:state.draftRewards.map(r=>({...r})),
    tiers:state.tiers.map(t=>({...t})),snapshot_hash:state.snapshotHash});
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
      case 'staff_list_customers_v155':return {customers:[{id:'c1',full_name:'Alice Tan',phone:'+65 81234567',
        points:120,credit_cents:1500,last_visit_at:'2026-08-05T03:00:00Z',created_at:'2026-03-01T00:00:00Z',
        marketing_consent:true,visits:2}],total:1};
      case 'preview_campaign_audience_v155':return {total:0};
      case 'require_module_scope_v145':return null;
      case 'staff_get_customer_actionable_loyalty_v145':return {points_balance:120,credit_balance_cents:1500,
        redemption_enabled:false,program:{active:false,unit:'points',earn_points_per_dollar:10,stamp_per_cents:500},
        rewards:[],next_reward:null,expiry:null};
      case 'staff_get_reward_entitlements_v99':return [];
      case 'list_customer_redemption_history_v145':return [];
      case 'staff_list_visit_feedback_v145':return {feedback:[]};
      case 'staff_get_reversal_workflows_v145':return {sales:[],redemptions:[]};
      case 'owner_list_reward_profitability_products_v122':return {items:[{id:'pr1',name:'Herbal tea pack',active:true,retail_price_cents:1200,price_cents:1200,cost_cents:300}]};
      case 'business_get_loyalty_tiers_v143':return state.tiers.map(t=>({...t}));
      case 'get_loyalty_reward_draft':return draftPayload();
      case 'get_birthday_program_draft':return {programs:[]};
      case 'get_active_birthday_program':return {programs:[]};
      case 'business_get_customer_capabilities_v89':return {redemption_enabled:false};
      case 'business_get_promotion_editor_v155':return {items:[{id:'pm1',name:'August Special',
        description:'10% off facials all month',active:true,imageUrl:null}],entitlement:null};
      case 'business_get_checkout_preferences_v102':return null;
      case 'business_get_welcome_offer_v215':return {configured:true,active:true,reward_label:'Herbal tea',
        min_spend_cents:0,item_available:true,granted_count:0,redeemed_count:0};
      case 'business_programme_usage_v271':return null;
      case 'create_loyalty_config_draft':return {version_id:'draft-1'};
      case 'save_loyalty_config_draft':{
        state.snapshotHash='hash-'+(window.__V294.writes.length+2);
        return {snapshot_hash:state.snapshotHash};
      }
      default:return null;
    }
  };
  /* rpc returns a CHAINABLE thenable: several readers call sb.rpc(...).order(...) before await. */
  const rpc=(name,args)=>{
    window.__V294.rpc.push({name,args:args??null});
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

  /* ---------------- 1. dashboard schedule day drives the figures ---------------- */
  say('1. dashboard schedule day sets the Performance figures');
  await page.goto(`${ORIGIN}/index.html#/dashboard`,{waitUntil:'domcontentloaded'});
  await page.waitForSelector('#dashboardPerformancePeriod',{timeout:20000});
  /* V295 retarget (not a weakening): the link runs BOTH ways now — the period pills move this
     day too — so the helper says so. The V294 behaviour asserted below is unchanged. */
  assertTrue((await page.locator('.dashboard-schedule-scope-v266').innerText()).trim()==='Linked both ways with the figures below.',
    'helper copy states the schedule day and the figures below are linked');
  const tomorrowLabel=await page.evaluate(()=>new Intl.DateTimeFormat('en-SG',
    {day:'numeric',month:'short',year:'numeric',timeZone:'Asia/Singapore'}).format(new Date(Date.now()+864e5)));
  await page.click('[data-schedule-day-v252="1"]');
  await page.waitForFunction(label=>{
    const node=document.getElementById('dashboardPerformancePeriod');
    return node&&node.textContent.trim()===`${label} to ${label}`;
  },tomorrowLabel,{timeout:20000});
  assertTrue(true,`Performance period reads "${tomorrowLabel} to ${tomorrowLabel}" after picking Tomorrow`);
  assertTrue(await page.locator('.qbtn[data-d].act').count()===0,
    'no global range pill claims a range it no longer drives');

  /* ---------------- 2. customers: exactly one filter bar ---------------- */
  say('2. customers page has exactly one filter bar');
  await go('#/clients');
  await page.waitForSelector('#clientInactivity',{timeout:20000});
  assertTrue(await page.locator('select#clientInactivity').count()===1,'exactly one #clientInactivity select');
  const filterLabelCount=await page.evaluate(()=>document.body.innerHTML.split('Show customers by last visit').length-1);
  assertTrue(filterLabelCount===1,`exactly one "Show customers by last visit" control (found ${filterLabelCount})`);
  assertTrue(await page.locator('#clientInactivity option[value="all_inactive"]').count()===1,
    'the kept bar carries the all_inactive bucket the dashboard drill targets');

  /* ---------------- 3. customer 360 summary card + programme rows ---------------- */
  say('3. customer 360 restructure');
  await go('#/client/c1');
  await page.waitForSelector('#c360SummaryV294',{timeout:20000});
  const summaryText=await page.locator('#c360SummaryV294').innerText();
  for(const needle of ['Visits','Lifetime spend','PDPA consent','Points','Spendable credit','SGD 60.00','SGD 15.00','120'])
    assertTrue(summaryText.includes(needle),`summary card carries "${needle}"`);
  assertTrue(await page.locator('.customer360-kpis-v249').count()===0,'the V249 KPI tile row is gone');
  assertTrue(await page.locator('.customer360-points-card-v249').count()===0,'the big POINTS tile is gone');
  assertTrue(await page.locator('#c360SummaryV294 #c360PointsHistoryV259').count()===1,
    'the points value keeps its history button inside the summary card');
  await page.waitForSelector('#c360-loyalty .c360-programme-row-v294',{timeout:20000});
  const programmesText=await page.locator('#c360-loyalty').innerText();
  for(const needle of ['Points redemption','Tiered membership','August Special','Referral programme','Welcome offer'])
    assertTrue(programmesText.includes(needle),`programmes section lists "${needle}"`);
  const pausedPills=await page.locator('#c360-loyalty .c360-programme-row-v294 .pill.off').allInnerTexts();
  assertTrue(pausedPills.some(text=>text.trim()==='Paused'),'the paused loyalty programme shows a Paused pill, not a bare message');

  /* ---------------- 4. nav: Programmes group with three children ---------------- */
  say('4. Programmes nav group');
  const growHead=page.locator('.side .navhead[data-grp="grow"]').first();
  assertTrue(await growHead.count()===1,'rail shows a Programmes group header');
  /* textContent, not innerText — a collapsed rail section reports '' for innerText. */
  assertTrue((await growHead.evaluate(node=>node.textContent)).includes('Programmes'),'group header is labelled Programmes');
  if(await growHead.getAttribute('aria-expanded')!=='true')await growHead.click();
  for(const [label,href,view] of [['Overview','#/grow/overview','overview'],['List','#/grow','list'],['History','#/grow/history','history']]){
    const link=page.locator(`.side .navbody[data-body="grow"] a[href="${href}"]`).first();
    assertTrue(await link.count()===1,`group child "${label}" is present`);
    await link.click();
    await page.waitForFunction(expected=>document.getElementById('growOverview')?.dataset.programmeView===expected,view,{timeout:20000});
    assertTrue(true,`child "${label}" lands on the ${view} view`);
    const activeChild=page.locator('.side .navbody[data-body="grow"] a.act').first();
    assertTrue((await activeChild.evaluate(node=>node.textContent)).includes(label),`child "${label}" is marked active`);
  }

  /* ---------------- 7. programmes overview copy + cards (asserted while on #/grow) ---------------- */
  say('7. programmes overview copy and cards');
  await go('#/grow');
  await page.waitForSelector('[data-grow-topic-v229]',{timeout:20000});
  const growText=await bodyText();
  assertTrue(growText.includes('1 LIVE'),'promotions ongoing card reads "1 LIVE"');
  assertTrue(!growText.includes('published promotion'),'the old "published promotions" copy is gone');
  assertTrue(!growText.includes('Memberships & gift cards'),'the combined Memberships & gift cards card is gone');
  for(const blurb of ['Let customers come back with points!','Do tier membership for your customers!',
    'Customers earn stamps and redeem!','Let customers subscribe and save'])
    assertTrue(growText.includes(blurb),`owner blurb present: "${blurb}"`);
  assertTrue(await page.locator('.side .navbody[data-body="serve"] a[href="#/giftcards"]').count()===1,
    'Gift cards is reachable from the Serve & sell nav group');

  /* ---------------- 5. reward history on the grid and in the editor ---------------- */
  say('5a. grow catalogue grid: retired reward lives in history');
  await page.click('[data-grow-topic-v229="points"]');
  await page.waitForSelector('[data-reward-card-grid-v250]',{timeout:20000});
  const gridText=await page.locator('[data-reward-card-grid-v250]').first().innerText();
  assertTrue(gridText.includes('Free Coffee'),'offerable reward stays on the grid');
  assertTrue(!gridText.includes('Free Lolipop'),'retired reward is absent from the offer grid');
  assertTrue(await page.locator('[data-reward-history-v294]').count()===1,'grid has a Reward history disclosure');
  assertTrue(!await page.locator('[data-reward-history-v294][open]').count(),'grid history starts collapsed');
  assertTrue((await page.locator('[data-reward-history-v294] summary').innerText()).includes('Reward history · 1'),
    'history summary carries the count');
  await page.click('[data-reward-history-v294] summary');
  assertTrue((await page.locator('[data-reward-history-v294]').innerText()).includes('Free Lolipop'),
    'retired reward is inside the history disclosure');

  say('5b. editor catalogue: history row still opens Edit');
  await go('#/loyalty/draft-1');
  await page.waitForSelector('#rwList',{timeout:20000});
  assertTrue((await page.locator('#rwList').innerText()).includes('Free Coffee'),'editor list keeps the offerable reward');
  assertTrue(!(await page.locator('#rwList').innerText()).includes('Free Lolipop'),'editor list dropped the retired reward');
  assertTrue(await page.locator('#rwHistoryV294').count()===1,'editor has the Reward history disclosure');
  /* Direct #/loyalty entry (no card context) keeps the combined behaviour — tiers visible. */
  assertTrue((await bodyText()).includes('Your tiers'),'direct editor entry keeps the combined tiers block');
  await page.click('#rwHistoryV294 > summary');
  const editorHistoryRow=page.locator('#rwHistoryListV294 .reward-item',{hasText:'Free Lolipop'});
  assertTrue((await editorHistoryRow.locator('.pill').innerText()).trim()==='Retired','history row pill reads Retired');
  await editorHistoryRow.locator('.rwEdit').click();
  await page.waitForSelector('#rewardDialogV238 #rwCustomerName',{timeout:20000});
  assertTrue((await page.locator('#rewardDialogTitleV238').innerText()).includes('Free Lolipop'),
    'Edit from history opens the retired reward');
  await page.click('#rewardDialogV238 #rwClose');
  await page.waitForFunction(()=>!document.getElementById('rewardDialogV238'));

  /* ---------------- 6. loyalty editor entry contexts + no back button ---------------- */
  say('6. entry context: points card hides tiers, tiers card shows them');
  await go('#/grow');
  await page.waitForSelector('[data-grow-topic-v229="points"]',{timeout:20000});
  await page.click('[data-grow-topic-v229="points"]');
  await page.waitForSelector('[data-reward-card-grid-v250]',{timeout:20000});
  await page.click('[data-rewards-overview-edit="catalogue"][data-reward-id="lr-live"]');
  await page.waitForSelector('#rewardDialogV238 #rwCustomerName',{timeout:20000});
  assertTrue((await page.evaluate(()=>location.hash)).includes('ctx-points'),'points-card entry carries ctx-points on the hash');
  const pointsEntryText=await bodyText();
  assertTrue(!pointsEntryText.includes('Your tiers'),'points-card entry renders NO "Your tiers" block');
  assertTrue(!pointsEntryText.includes('Customers cannot see these tiers'),'and no paused-tiers banner');
  assertTrue(!pointsEntryText.includes('Back to Grow overview'),'no "Back to Grow overview" button in the editor');
  await page.click('#rewardDialogV238 #rwClose');
  await page.waitForFunction(()=>!document.getElementById('rewardDialogV238'));

  await go('#/grow');
  await page.waitForSelector('[data-grow-topic-v229="tiers"]',{timeout:20000});
  await page.click('[data-grow-topic-v229="tiers"]');
  await page.waitForSelector('[data-grow-open="rewards"][data-grow-focus="ltb"]',{timeout:20000});
  await page.click('[data-grow-open="rewards"][data-grow-focus="ltb"]');
  await page.waitForFunction(()=>document.body.innerText.includes('Your tiers'),{timeout:20000});
  assertTrue((await page.evaluate(()=>location.hash)).includes('ctx-tiers'),'tiers-card entry carries ctx-tiers on the hash');
  assertTrue((await bodyText()).includes('Your tiers'),'tiers-card entry renders the tiers block');
  assertTrue(!(await bodyText()).includes('Back to Grow overview'),'still no back button on the tiers entry');

  /* ---------------- 8. Business Insights tabs ---------------- */
  say('8. insights cards became tabs');
  await go('#/reports');
  await page.waitForSelector('.report-tabbar-v294',{timeout:20000});
  const tabTexts=(await page.locator('.report-tabbar-v294 button').allInnerTexts()).map(t=>t.trim());
  assertTrue(tabTexts.length===4,`four tabs render (got ${tabTexts.length}: ${tabTexts.join(' · ')})`);
  for(const title of ['Sales & Revenue','Efficiency','Customer Retention','Team Performance'])
    assertTrue(tabTexts.some(t=>t.includes(title)),`tab "${title}" present`);
  await page.waitForFunction(()=>{
    const money=document.getElementById('reportPanelMoneyV294');
    return money&&!money.hidden;
  },{timeout:20000});
  assertTrue(true,'default tab is Sales & Revenue (its panel is visible)');
  await page.fill('#rf','2026-08-01');
  await page.click('[data-report-tab-v294="busy"]');
  await page.waitForFunction(()=>{
    const busy=document.getElementById('reportPanelBusyV294'),money=document.getElementById('reportPanelMoneyV294');
    return busy&&!busy.hidden&&money&&money.hidden;
  },{timeout:20000});
  assertTrue(true,'selecting Efficiency swaps the visible panel');
  assertTrue(await page.inputValue('#rf')==='2026-08-01','From date persists across the tab switch');

  /* ---------------- 9. staff members: Team members group ---------------- */
  say('9. staff groups renamed');
  await go('#/staffmembers');
  await page.waitForFunction(()=>document.body.innerText.includes('Team members'),{timeout:20000});
  const staffText=await bodyText();
  assertTrue(staffText.includes('Team members'),'the roster group heading reads "Team members"');
  assertTrue(!staffText.includes('Roster only'),'"Roster only" no longer appears');
  assertTrue(staffText.includes('Owner & managers'),'"Owner & managers" group is untouched');

  if(pageErrors.length)process.stdout.write(`note: page errors observed (non-fatal): ${JSON.stringify(pageErrors)}\n`);
  process.stdout.write('V294 owner batch walkthrough PASS (steps 1-9)\n');
}catch(error){
  process.stdout.write(`V294 walkthrough FAIL at ${step}\n${error?.stack||error}\n`);
  if(pageErrors.length)process.stdout.write(`page errors: ${JSON.stringify(pageErrors)}\n`);
  process.exitCode=1;
}finally{
  await browser.close().catch(()=>{});
  if(server)server.kill();
}
