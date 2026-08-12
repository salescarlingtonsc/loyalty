/* V293 reward-editor walkthrough — the owner's own path, scripted (owner report 2026-08-12:
 * "did you even test all buttons?").
 *
 * This drives the REAL production bundles (app/index.html + the stamped app-core/app-business
 * chunks — run `npm run bundle-stamp` first) through the real router, with the Supabase client
 * replaced by an in-page fixture that records every write and echoes saved rewards back, the way
 * get_loyalty_reward_draft does (including its habit of omitting `active` on draft rows — the
 * exact shape behind the false "Retired" icon).
 *
 * Steps (each asserts, script exits non-zero naming the failing step):
 *   a. #/loyalty/<draft> on a paused points+tiers programme with one existing reward
 *      -> full catalogue: list + "+ Add reward" + paused helper; fresh reward is NOT retired.
 *   b. + Add reward -> budget 1.00 at $0.010/point -> points auto-fill 100 with the derived
 *      helper; typing points 150 sticks (no silent overwrite); budget 2.00 resumes sync -> 200.
 *   c. Create reward -> dialog closed, FULL catalogue with the new reward, no blank re-open,
 *      pill "Programme paused" (never "Retired").
 *   d. Edit -> rename -> Save changes -> list shows the new name.
 *   e. Edit -> Archive -> deliberate confirm -> pill "Retired".
 *   f. Arrive via the intent URL (#/loyalty/<draft>/add) -> dialog auto-opens -> Done WITHOUT
 *      saving -> lands on the full catalogue (the pruned dead end is gone).
 *   g. Minimal path (owner: "dont need so many steps"): catalogue autofill reaches fields inside
 *      the collapsed More options; every demoted control is present and functional; then a
 *      create with ONLY name + budget ships manual fulfilment / no expiry / unlimited uses /
 *      everyone / active, with auto-priced points.
 *
 * Run:
 *   PLAYWRIGHT_MODULE=".../playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v293-reward-editor-walkthrough.mjs
 */
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const APP_DIR=fileURLToPath(new URL('../../app/',import.meta.url));
const PORT=Number(process.env.V293_PORT||4173);
const ORIGIN=`http://127.0.0.1:${PORT}`;

let step='(boot)';
const say=name=>{step=name;process.stdout.write(`STEP ${name}\n`)};
const assertTrue=(condition,message)=>{
  if(!condition)throw new Error(`step ${step}: ${message}`);
  process.stdout.write(`  ok - ${message}\n`);
};

/* ---- static server over app/ (index.html references /app-core.js by absolute path) ----
   Reuses a server already listening on the port (the documented manual invocation is
   `cd app && python3 -m http.server 4173`); otherwise starts its own and stops it at exit. */
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

/* ---- in-page Supabase fixture: records writes, echoes saved rewards back ---- */
const BIZ='b1111111-1111-4111-8111-111111111111';
const stubSource=`(()=>{
  const BIZ='${BIZ}';
  const state={
    snapshotHash:'hash-1',nextId:1,
    program:{id:'prog-1',business_id:BIZ,active:false,loyalty_model:'points_tiers',
      earn_points_per_dollar:10,redeem_points:100,reward_credit_cents:100,expiry_mode:'none',
      expiry_days:null,tier_basis:'visits',current_config_version_id:'pub-1',configuration_status:'published'},
    /* One existing draft reward WITHOUT an "active" field — get_loyalty_reward_draft rows may
       omit it, which is exactly the shape that used to draw the retired glyph. */
    draftRewards:[{reward_id:'r-existing',name:'Signature facial treat',customer_name:'Signature facial treat',
      description:'A pampering add-on',cost_points:400,credit_cents:0,estimated_cost_cents:400,
      entitlement_expiry_days:null,usage_limit:null,min_tier_id:null,min_tier_threshold:null,
      claim_available_from:null,claim_available_until:null,fulfillment_kind:'manual_item',
      sort:1,created_at:'2026-06-01T00:00:00Z',eligibility:{branches:[],services:[],products:[]}}],
    tiers:[{tier_id:'t-gold',id:'t-gold',name:'Gold',threshold:10,points_multiplier:1,perk_note:'',effective_from:null,expires_at:null}]
  };
  window.__V293={rpc:[],writes:[],state};
  const MODULES=['loyalty','retention','referrals','memberships','giftcards','clients','sales','services','till','bookings','reports','inventory'];
  const bizRow={id:BIZ,slug:'testco',name:'Test Co',currency:'SGD',industry:'facial',points_mode:'both',
    enabled_modules:MODULES,active_config_version_id:'pub-1',join_enabled:true,brand_color:'#7c5cff',
    booking_policy:null,quick_earn_catalogue_enabled:true,created_at:'2026-01-01T00:00:00Z'};
  const TABLES={
    businesses:[bizRow],
    branches:[{id:'br1',business_id:BIZ,name:'Orchard',active:true}],
    services:[{id:'sv1',business_id:BIZ,name:'Signature facial',active:true,price_cents:8800}],
    loyalty_programs:[state.program],
    loyalty_rewards:[],loyalty_reward_branches:[],loyalty_reward_services:[],loyalty_reward_products:[],
    loyalty_tiers:[],loyalty_branch_overrides:[],
    referral_programs:[],membership_plans:[],retention_programs:[],
    firm_config_versions:[{id:'draft-1',version_no:2,based_on_version_id:'pub-1',status:'draft',snapshot_hash:'hash-1'}]
  };
  const query=table=>{
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
    chain.then=(resolve,reject)=>{
      if(q.op!=='select'){
        window.__V293.writes.push({table,op:q.op,payload:q.payload??null});
        return Promise.resolve({data:null,error:null}).then(resolve,reject);
      }
      const rows=TABLES[table]||[];
      const out=q.countMode?{data:null,count:rows.length,error:null}
        :q.single?{data:rows[0]??null,error:null}
        :{data:rows,error:null};
      return Promise.resolve(out).then(resolve,reject);
    };
    return chain;
  };
  const draftPayload=()=>({program:{...state.program},rewards:state.draftRewards.map(r=>({...r})),
    tiers:state.tiers.map(t=>({...t})),snapshot_hash:state.snapshotHash});
  const rpc=(name,args)=>{
    window.__V293.rpc.push({name,args:args??null});
    const respond=data=>Promise.resolve({data,error:null});
    switch(name){
      case 'get_my_personas':return respond({staff:[{business_id:BIZ,business_slug:'testco',business_name:'Test Co',role:'owner',modules:MODULES}],customer:[],default_route:'#/workspace/testco/dashboard'});
      case 'platform_get_business_control_v94':return respond({workspace_access:true,quick_earn_catalogue_enabled:true});
      case 'get_my_modules':return respond({role:'owner',is_super_admin:false,modules:MODULES,module_perms:Object.fromEntries(MODULES.map(m=>[m,'rw']))});
      case 'get_customer_feature_capabilities':return respond({});
      case 'get_workspace_locale_preference_v97':return respond({locale:'en',version:1});
      case 'get_notifications':return respond({unread:0,items:[]});
      case 'owner_list_reward_profitability_products_v122':return respond({items:[{id:'pr1',name:'Herbal tea pack',active:true,retail_price_cents:1200,price_cents:1200,cost_cents:300}]});
      case 'business_get_loyalty_tiers_v143':return respond(state.tiers.map(t=>({...t})));
      case 'get_loyalty_reward_draft':return respond(draftPayload());
      case 'get_birthday_program_draft':return respond({programs:[]});
      case 'get_active_birthday_program':return respond({programs:[]});
      case 'business_get_customer_capabilities_v89':return respond({redemption_enabled:false});
      case 'business_get_promotion_editor_v155':return respond({items:[],entitlement:null});
      case 'business_get_checkout_preferences_v102':return respond(null);
      case 'business_get_welcome_offer_v215':return respond(null);
      case 'business_programme_usage_v271':return respond(null);
      case 'create_loyalty_config_draft':return respond({version_id:'draft-1'});
      case 'save_loyalty_config_draft':{
        const config=args&&args.p_config?args.p_config:{};
        window.__V293.writes.push({rpcName:name,config});
        if(config.reward){
          const payload=config.reward;
          const id=payload.id||('new-'+(state.nextId++));
          const row={reward_id:id,name:payload.name,customer_name:payload.customer_name,
            description:payload.description,cost_points:payload.cost_points,
            credit_cents:payload.credit_cents,estimated_cost_cents:payload.estimated_cost_cents,
            entitlement_expiry_days:payload.entitlement_expiry_days,usage_limit:payload.usage_limit,
            min_tier_id:payload.min_tier_id,min_tier_threshold:payload.min_tier_threshold,
            claim_available_from:payload.claim_available_from,claim_available_until:payload.claim_available_until,
            fulfillment_kind:payload.fulfillment_kind,sort:99,created_at:new Date().toISOString(),
            eligibility:{branches:config.reward_branch_ids||[],services:config.reward_service_ids||[],products:config.reward_product_ids||[]}};
          /* Echo the production shape: active rows come back WITHOUT the field; only an
             archived reward carries active:false. */
          if(payload.active===false)row.active=false;
          const at=state.draftRewards.findIndex(r=>r.reward_id===id);
          if(at>=0)state.draftRewards[at]=row;else state.draftRewards.push(row);
        }
        state.snapshotHash='hash-'+(window.__V293.writes.length+1);
        return respond({snapshot_hash:state.snapshotHash});
      }
      default:return respond(null);
    }
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
  /* The page must be fully self-contained: the CDN supabase-js is blocked so the fixture client
     is the only client, and no request may leave the local static server. */
  await context.route('**/*',route=>{
    const url=route.request().url();
    if(url.startsWith(ORIGIN)&&!url.includes('/sw.js'))return route.continue();
    return route.abort();
  });
  await context.addInitScript(stubSource);
  const page=await context.newPage();
  page.on('pageerror',error=>pageErrors.push(String(error)));

  const rewardRow=name=>page.locator('#rwList .reward-item',{hasText:name});
  const dialog=()=>page.locator('#rewardDialogV238');
  const noRetiredIcon=async name=>{
    const html=await rewardRow(name).locator('.inline-status').first().innerHTML();
    return !html.includes('<svg');
  };

  /* ---------------- a. arrival: full catalogue, paused-but-not-retired ---------------- */
  say('a. open loyalty draft catalogue');
  await page.goto(`${ORIGIN}/index.html#/loyalty/draft-1`,{waitUntil:'domcontentloaded'});
  await page.waitForSelector('#rwList',{timeout:20000});
  assertTrue(await page.locator('#rwAdd').count()===1,'"+ Add reward" is present');
  assertTrue(await rewardRow('Signature facial treat').count()===1,'existing reward is listed');
  assertTrue((await rewardRow('Signature facial treat').locator('.pill').innerText()).trim()==='Programme paused',
    'existing reward pill reads "Programme paused" (not Retired)');
  assertTrue(await noRetiredIcon('Signature facial treat'),
    'no retired glyph on a draft row that omits `active` (defect 3 truthiness)');
  assertTrue(await page.locator('#rwPausedHelpV293').count()===1,'paused helper line above the list');
  assertTrue((await page.locator('#rwPausedHelpV293').innerText()).includes('they show to customers again when you resume'),
    'helper says rewards return on resume');

  /* ---------------- b. budget->points maths: derive, override, resume ---------------- */
  say('b. add-reward maths');
  await page.click('#rwAdd');
  await page.waitForSelector('#rewardDialogV238 #rwCustomerName');
  assertTrue((await page.locator('#rewardDialogV238 #rwPointCostV262').innerText()).includes('0.010'),
    'cost per point shows SGD 0.010');
  await page.fill('#rewardDialogV238 #rwEstimate','1.00');
  assertTrue(await page.inputValue('#rewardDialogV238 #rwCost')==='100','budget 1.00 auto-fills 100 points');
  assertTrue(await page.locator('#rewardDialogV238 #rwCostDerivedHelpV293').isVisible(),
    'derived helper is visible under Points cost');
  await page.fill('#rewardDialogV238 #rwCost','150');
  await page.waitForTimeout(150);
  assertTrue(await page.inputValue('#rewardDialogV238 #rwCost')==='150',
    'typed points 150 are NOT overwritten while the budget is untouched');
  await page.fill('#rewardDialogV238 #rwEstimate','2.00');
  assertTrue(await page.inputValue('#rewardDialogV238 #rwCost')==='200',
    'editing the budget resumes the sync (2.00 -> 200 points)');

  /* ---------------- c. create -> full catalogue with the new reward ---------------- */
  say('c. create reward lands on the full catalogue');
  await page.fill('#rewardDialogV238 #rwCustomerName','Free herbal tea');
  await page.click('#rewardDialogV238 #rwSave');
  await page.waitForFunction(()=>!document.getElementById('rewardDialogV238')&&!!document.getElementById('rwList')
    &&document.getElementById('rwList').textContent.includes('Free herbal tea'));
  assertTrue(await dialog().count()===0,'no blank New-reward dialog re-opened after save');
  assertTrue(await page.evaluate(()=>location.hash)==='#/loyalty/draft-1','hash carries no add/focus segment');
  assertTrue(await rewardRow('Free herbal tea').count()===1,'the saved reward IS in the list');
  assertTrue((await rewardRow('Free herbal tea').innerText()).includes('200 points'),'saved at 200 points');
  assertTrue(await page.locator('#rwAdd').count()===1,'"+ Add reward" still present');
  assertTrue((await rewardRow('Free herbal tea').locator('.pill').innerText()).trim()==='Programme paused',
    'fresh reward pill is "Programme paused", never "Retired"');
  assertTrue(await noRetiredIcon('Free herbal tea'),'fresh reward carries no retired glyph');

  /* ---------------- d. edit -> rename -> list shows the new name ---------------- */
  say('d. edit and rename');
  await rewardRow('Free herbal tea').locator('.rwEdit').click();
  await page.waitForSelector('#rewardDialogV238 #rwCustomerName');
  assertTrue((await page.locator('#rewardDialogTitleV238').innerText()).includes('Free herbal tea'),
    'edit dialog names the reward');
  await page.fill('#rewardDialogV238 #rwCustomerName','Free premium herbal tea');
  await page.click('#rewardDialogV238 #rwSave');
  await page.waitForFunction(()=>!document.getElementById('rewardDialogV238')&&!!document.getElementById('rwList')
    &&document.getElementById('rwList').textContent.includes('Free premium herbal tea'));
  assertTrue(await rewardRow('Free premium herbal tea').count()===1,'list shows the updated name');

  /* ---------------- e. archive via deliberate confirm -> Retired ---------------- */
  say('e. archive');
  await rewardRow('Free premium herbal tea').locator('.rwEdit').click();
  await page.waitForSelector('#rewardDialogV238 #rwArchive');
  await page.click('#rewardDialogV238 #rwArchive');
  await page.waitForSelector('#confirmDeliberateAckV288');
  await page.check('#confirmDeliberateAckV288');
  await page.click('#confirmDeliberateOkV288');
  await page.waitForFunction(()=>!document.getElementById('rewardDialogV238')&&!!document.getElementById('rwList'));
  await page.waitForFunction(()=>document.getElementById('rwList').textContent.includes('Retired'));
  assertTrue((await rewardRow('Free premium herbal tea').locator('.pill').innerText()).trim()==='Retired',
    'archived reward pill reads "Retired"');

  /* ---------------- f. intent URL close-without-save is not a dead end ---------------- */
  say('f1. intent URL dead end is gone (Done without saving)');
  await page.evaluate(()=>{location.hash='#/loyalty/draft-1/add'});
  await page.waitForSelector('#rewardDialogV238 #rwCustomerName',{timeout:20000});
  assertTrue(await page.locator('#rwList').count()===0,'intent view is pruned (the V139 isolation still applies)');
  await page.click('#rewardDialogV238 #rwClose');
  await page.waitForSelector('#rwList',{timeout:20000});
  await page.waitForFunction(()=>location.hash==='#/loyalty/draft-1');
  assertTrue(await dialog().count()===0,'dialog closed');
  assertTrue(await page.locator('#rwList').count()===1,'full catalogue list is back');
  assertTrue(await page.locator('#rwAdd').count()===1,'"+ Add reward" is back');

  /* The owner's original defect-1 reproduction: SAVING while the add-intent hash is still
     current used to re-run the intent and open a fresh blank "New reward" over the result. */
  say('f2. saving under the intent URL lands on the catalogue, not a blank dialog');
  await page.evaluate(()=>{location.hash='#/loyalty/draft-1/add'});
  await page.waitForSelector('#rewardDialogV238 #rwCustomerName',{timeout:20000});
  await page.fill('#rewardDialogV238 #rwCustomerName','Intent-saved treat');
  await page.fill('#rewardDialogV238 #rwEstimate','1.00');
  await page.click('#rewardDialogV238 #rwSave');
  await page.waitForFunction(()=>!document.getElementById('rewardDialogV238')&&!!document.getElementById('rwList')
    &&document.getElementById('rwList').textContent.includes('Intent-saved treat'),{timeout:20000});
  await page.waitForFunction(()=>location.hash==='#/loyalty/draft-1');
  await page.waitForTimeout(300); // give a mis-ordered history traversal the chance to re-arm
  assertTrue(await dialog().count()===0,'no blank New-reward dialog re-opened after the intent save');
  assertTrue(await page.evaluate(()=>location.hash)==='#/loyalty/draft-1','intent hash was spent');
  assertTrue(await rewardRow('Intent-saved treat').count()===1,'the intent-saved reward is visible in the list');
  assertTrue(await page.locator('#rwAdd').count()===1,'"+ Add reward" is present after the intent save');

  /* ------- g. minimal path + demoted controls (owner: "dont need so many steps") ------- */
  say('g1. More options holds every demoted control, and autofill reaches inside it');
  await page.click('#rwAdd');
  await page.waitForSelector('#rewardDialogV238 #rwCustomerName');
  const essentials=await page.locator('#rewardDialogV238 .field-grid').first().locator('input,select,textarea').evaluateAll(
    nodes=>nodes.map(node=>node.id));
  assertTrue(JSON.stringify(essentials)===JSON.stringify(['rwCatalogueSource','rwCustomerName','rwEstimate','rwCost']),
    `essentials are exactly source/name/budget/points (got ${JSON.stringify(essentials)})`);
  for(const id of ['rwDescription','rwKind','rwCredit','rwExpiry','rwUsage','rwMinTier','rwFrom','rwUntil','rwInternalName','rwActive'])
    assertTrue(await page.locator(`#rewardDialogV238 details #${id}`).count()===1,`demoted control #${id} lives in More options`);
  assertTrue(await page.locator('#rewardDialogV238 details[open]').count()===0,'More options starts collapsed');
  /* Autofill targets sit inside the COLLAPSED details and must still be written. */
  await page.selectOption('#rewardDialogV238 #rwCatalogueSource','product|pr1');
  assertTrue(await page.inputValue('#rewardDialogV238 #rwCustomerName')==='Herbal tea pack','autofill set the name');
  assertTrue(await page.inputValue('#rewardDialogV238 #rwDescription')==='Free Herbal tea pack','autofill reached the collapsed description');
  assertTrue(await page.inputValue('#rewardDialogV238 #rwInternalName')==='Herbal tea pack','autofill reached the collapsed internal name');
  assertTrue(await page.inputValue('#rewardDialogV238 #rwEstimate')==='3.00','autofill set the budget from product cost');
  assertTrue(await page.inputValue('#rewardDialogV238 #rwCost')==='300','autofilled budget derived the points');
  await page.click('#rewardDialogV238 details > summary');
  assertTrue(await page.locator('#rewardDialogV238 details[open]').count()===1,'More options opens');
  await page.selectOption('#rewardDialogV238 #rwKind','credit');
  assertTrue(await page.locator('#rewardDialogV238 #rwCreditWrap').isVisible(),'choosing store credit reveals the credit value');
  await page.selectOption('#rewardDialogV238 #rwKind','manual_item');
  assertTrue(!await page.locator('#rewardDialogV238 #rwCreditWrap').isVisible(),'manual fulfilment hides it again');
  assertTrue(await page.locator('#rewardDialogV238 [data-reward-elig]').count()>0,'eligibility checkboxes are present');
  assertTrue(await page.locator('#rewardDialogV238 #rwMinTier option').first().innerText()==='Everyone','tier gate defaults to Everyone');
  await page.click('#rewardDialogV238 #rwClose'); // no save; no intent -> page keeps its list
  await page.waitForFunction(()=>!document.getElementById('rewardDialogV238'));
  assertTrue(await page.locator('#rwList').count()===1,'closing a list-opened dialog keeps the full page');

  say('g2. minimal path: name + budget only');
  await page.click('#rwAdd');
  await page.waitForSelector('#rewardDialogV238 #rwCustomerName');
  await page.fill('#rewardDialogV238 #rwCustomerName','Quick treat');
  await page.fill('#rewardDialogV238 #rwEstimate','0.50');
  assertTrue(await page.inputValue('#rewardDialogV238 #rwCost')==='50','budget 0.50 auto-prices 50 points');
  await page.click('#rewardDialogV238 #rwSave');
  await page.waitForFunction(()=>!document.getElementById('rewardDialogV238')&&!!document.getElementById('rwList')
    &&document.getElementById('rwList').textContent.includes('Quick treat'));
  assertTrue(await rewardRow('Quick treat').count()===1,'minimal-path reward is in the catalogue');
  assertTrue((await rewardRow('Quick treat').innerText()).includes('50 points'),'auto-priced at 50 points');
  const minimal=await page.evaluate(()=>{
    const writes=window.__V293.writes.filter(w=>w.rpcName==='save_loyalty_config_draft'&&w.config.reward);
    return writes[writes.length-1].config.reward;
  });
  assertTrue(minimal.customer_name==='Quick treat'&&minimal.name==='Quick treat','internal name defaulted to the customer name');
  assertTrue(minimal.cost_points===50,'payload carries the auto-priced 50 points');
  assertTrue(minimal.fulfillment_kind==='manual_item','default fulfilment is manual');
  assertTrue(minimal.credit_cents===0,'no store credit by default');
  assertTrue(minimal.entitlement_expiry_days===null,'no expiry by default');
  assertTrue(minimal.usage_limit===null,'unlimited uses by default');
  assertTrue(minimal.min_tier_id===null,'everyone can redeem by default');
  assertTrue(minimal.claim_available_from===null&&minimal.claim_available_until===null,'always available by default');
  assertTrue(minimal.active===true,'active by default');
  assertTrue(minimal.description===null,'no description was demanded');

  if(pageErrors.length)process.stdout.write(`note: page errors observed (non-fatal): ${JSON.stringify(pageErrors)}\n`);
  process.stdout.write('V293 reward editor walkthrough PASS (steps a-g)\n');
}catch(error){
  process.stdout.write(`V293 walkthrough FAIL at ${step}\n${error?.stack||error}\n`);
  if(pageErrors.length)process.stdout.write(`page errors: ${JSON.stringify(pageErrors)}\n`);
  process.exitCode=1;
}finally{
  await browser.close().catch(()=>{});
  if(server)server.kill();
}
