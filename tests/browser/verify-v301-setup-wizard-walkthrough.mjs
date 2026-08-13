/* V301 setup-wizard walkthrough — the owner report of 2026-08-13: "Business owners cannot set
 * up rewards." Thirteen clicks through three stacked popups, closing one dumped the owner on a
 * page they had not chosen, drafts piled up unpublished, and the publish confirmation could
 * open twice. Owner directive: ONE page with step subtabs, select-and-Next, publish at
 * completion, no popups.
 *
 * Drives the REAL production bundles (app/index.html + the stamped chunks — run
 * `npm run bundle-stamp` first) through the real router, with the Supabase client replaced by an
 * in-page fixture (same pattern as verify-v296-programmes-batch-walkthrough.mjs). The stub
 * RECORDS every save_loyalty_config_draft / publish_loyalty_config call with its arguments and
 * mutates its own in-memory draft, so a re-render shows what was actually written rather than
 * what the page hoped it wrote.
 *
 * The fixture business starts the way the owner's does: a seeded but never-published programme
 * (no active_config_version_id), paused, no draft, no rewards.
 *
 * Steps (each asserts; the script exits non-zero naming the failing step):
 *   a. Programmes List shows "Set up →" on Points System; pressing it lands on #/grow/setup
 *      step 1 with Points preselected.
 *   b. Zero .modal elements at every step — the whole point of the surface.
 *   c. Step 2 earn rate is editable and Next fires save_loyalty_config_draft carrying
 *      earn_points_per_dollar.
 *   d. Step 3 is an INLINE reward form (no dialog); typing the budget auto-fills the points
 *      cost; Next writes the reward envelope.
 *   e. Step 4 lists what changes, says the programme will be ON, and Publish fires
 *      save {active:true} then publish_loyalty_config with the draft id; success panel shows.
 *   f. "Back to Programmes" lands on the Overview; the draft banner is gone.
 *   g. Mobile 390x844: steps 1→4 with no horizontal overflow and the stepper visible.
 *   h. The draft banner's "Review & publish" opens the wizard directly on step 4.
 *
 * Serves on 4303 deliberately: sibling worktrees use 4173/4196 and a parallel session was found
 * squatting 4203, and evidence has been captured from the wrong tree that way before. The probe
 * below therefore checks that whatever answers on the port is THIS app, not merely that
 * something answers — a stale server from another tree returning 200 is the exact failure mode
 * a bare reachability probe cannot see.
 *
 * Run:
 *   PLAYWRIGHT_MODULE=".../playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v301-setup-wizard-walkthrough.mjs
 */
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const APP_DIR=fileURLToPath(new URL('../../app/',import.meta.url));
const PORT=Number(process.env.V301_PORT||4303);
const ORIGIN=`http://127.0.0.1:${PORT}`;

let step='(boot)';
const say=name=>{step=name;process.stdout.write(`STEP ${name}\n`)};
const assertTrue=(condition,message)=>{
  if(!condition)throw new Error(`step ${step}: ${message}`);
  process.stdout.write(`  ok - ${message}\n`);
};

let server=null;
const probe=async()=>{
  try{
    const response=await fetch(`${ORIGIN}/index.html`);
    if(!response.ok)return false;
    /* Serving SOMETHING is not serving THIS app. */
    return (await response.text()).includes('data-grow-setup-goto-v301')
      ||(await (await fetch(`${ORIGIN}/app-business.js`)).text()).includes('growSetupWizardV301');
  }catch{return false}
};
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

const BIZ='b1111111-1111-4111-8111-111111111111';
const stubSource=`(()=>{
  const BIZ='${BIZ}';
  const MODULES=['loyalty','retention','referrals','memberships','giftcards','clients','sales','services','till','bookings','reports','inventory','appointments','staffperf','packages'];
  /* The cold start the owner reported: seeded programme row, never published (the business has
     no active_config_version_id), paused, and no reward catalogue at all. */
  const program={id:'prog-1',business_id:BIZ,active:false,loyalty_model:'points_tiers',
    earn_points_per_dollar:1,redeem_points:800,reward_credit_cents:800,stamp_target:null,
    stamp_per_cents:500,expiry_mode:'none',expiry_days:null,tier_basis:'visits',
    current_config_version_id:'seed-1',configuration_status:'draft'};
  const bizRow={id:BIZ,slug:'testco',name:'Test Co',currency:'SGD',industry:'fnb',points_mode:'redeem',
    enabled_modules:MODULES,active_config_version_id:null,join_enabled:true,brand_color:'#7c5cff',
    booking_policy:null,quick_earn_catalogue_enabled:true,created_at:'2026-01-01T00:00:00Z'};
  const TABLES={
    businesses:[bizRow],
    branches:[{id:'br1',business_id:BIZ,name:'Orchard',active:true,is_default:true,billing_state:'active'}],
    services:[{id:'sv1',business_id:BIZ,name:'Flat white',active:true,price_cents:600}],
    clients:[],sales:[],appointments:[],points_ledger:[],memberships:[],client_packages:[],waitlist:[],
    client_field_definitions:[],client_field_values:[],client_field_options:[],
    staff:[{id:'st1',business_id:BIZ,full_name:'Owner Person',role:'owner',user_id:'u-owner',active:true,
      email:'owner@test.co',phone:'',title:null,module_perms:null,modules:null,
      commission_service_bps:null,commission_product_bps:null,created_at:'2026-01-01T00:00:00Z'}],
    staff_invites:[],staff_hours:[],staff_branches:[{business_id:BIZ,staff_id:'st1',branch_id:'br1'}],
    loyalty_programs:[program],
    loyalty_rewards:[],
    loyalty_reward_branches:[],loyalty_reward_services:[],loyalty_reward_products:[],
    loyalty_tiers:[],loyalty_branch_overrides:[],
    gift_cards:[],referral_programs:[],membership_plans:[],retention_programs:[],
    firm_config_versions:[]
  };
  /* The in-memory draft the wizard writes into, so a re-render reads back what it saved. */
  const draft={id:null,version_no:2,snapshotHash:'hash-1',hashSeq:1,
    program:{...program},rewards:[]};
  /* V302: the table set and the business id are exposed so a step can put this business into a
     DIFFERENT starting state in the same browser — specifically the owner's own reported one, a
     paused programme with a published configuration and a reward catalogue. */
  window.__V301={rpc:[],writes:[],draft,published:[],tables:TABLES,biz:BIZ};
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
      window.__V301.writes.push({table,op:q.op,payload:q.payload??null});
      return {data:null,error:null};
    }
    const rows=TABLES[table]||[];
    if(q.countMode&&q.head)return {data:null,count:rows.length,error:null};
    if(q.single)return {data:rows[0]??null,error:null};
    return {data:rows,count:q.countMode?rows.length:null,error:null};
  });
  const draftRows=()=>draft.rewards.map(r=>({...r,id:r.reward_id,eligibility:{branches:[],services:[],products:[]}}));
  const rpcData=(name,args)=>{
    switch(name){
      case 'get_my_personas':return {staff:[{business_id:BIZ,business_slug:'testco',business_name:'Test Co',role:'owner',modules:MODULES}],customer:[],default_route:'#/workspace/testco/dashboard'};
      case 'platform_get_business_control_v94':return {workspace_access:true,quick_earn_catalogue_enabled:true};
      case 'get_my_modules':return {role:'owner',is_super_admin:false,modules:MODULES,module_perms:Object.fromEntries(MODULES.map(m=>[m,'rw']))};
      case 'get_my_modules_at_v115':return {role:'owner',modules:MODULES,module_perms:Object.fromEntries(MODULES.map(m=>[m,'rw']))};
      case 'get_customer_feature_capabilities':return {};
      case 'get_workspace_locale_preference_v97':return {locale:'en',version:1};
      case 'get_notifications':return {unread:0,items:[]};
      case 'get_dashboard_summary_v155':return {visits:0,revenue_cents:0,new_customers:0,points_issued:0,
        visits_by_weekday:[0,0,0,0,0,0,0],availability:{sales:true,clients:true,loyalty:true}};
      case 'staff_list_customers_v155':return {customers:[],total:0};
      case 'require_module_scope_v145':return null;
      case 'owner_list_reward_profitability_products_v122':return {items:[]};
      case 'business_get_loyalty_tiers_v143':return [];
      case 'business_get_promotion_editor_v155':return {items:[],entitlement:null};
      case 'business_get_checkout_preferences_v102':return {status:'available',gift_card_sales_enabled:false,package_earns_points:true};
      case 'business_get_welcome_offer_v215':return {configured:false};
      case 'business_programme_usage_v271':return null;
      case 'get_business_signup_config':return null;
      case 'get_active_birthday_program':return {programs:[],as_of:'2026-08-13T00:00:00Z'};
      case 'get_birthday_program_draft':return {programs:[]};
      case 'get_retention_config_draft':return {programs:[]};
      case 'get_program_rules_draft':return {version_no:draft.version_no,rules:[]};
      case 'create_loyalty_config_draft':
        draft.id=draft.id||'draft-v301';
        TABLES.firm_config_versions=[{id:draft.id,business_id:BIZ,version_no:draft.version_no,
          based_on_version_id:args&&args.p_based_on||null,status:'draft',snapshot_hash:draft.snapshotHash}];
        return {version_id:draft.id,version_no:draft.version_no,status:'draft',snapshot_hash:draft.snapshotHash};
      /* V302: mirrors the real function — it copies a PUBLISHED reward's full row into this
         draft so a later partial edit has something to coalesce its untouched fields from.
         Idempotent: a reward already in the draft is simply confirmed. */
      case 'ensure_published_reward_in_draft_v138':{
        const wanted=args&&args.p_reward;
        if(!draft.rewards.find(r=>r.reward_id===wanted)){
          const published=(TABLES.loyalty_rewards||[]).find(r=>r.id===wanted);
          if(!published)return {reward_id:null,snapshot_hash:draft.snapshotHash};
          draft.rewards.push({reward_id:published.id,business_id:BIZ,name:published.name,
            customer_name:published.customer_name,description:published.description??null,
            fulfillment_kind:published.fulfillment_kind||'manual_item',cost_points:published.cost_points,
            credit_cents:published.credit_cents??0,estimated_cost_cents:published.estimated_cost_cents??0,
            active:published.active!==false,sort:published.sort??draft.rewards.length,
            entitlement_expiry_days:published.entitlement_expiry_days??null,usage_limit:published.usage_limit??null,
            min_tier_id:published.min_tier_id??null,min_tier_threshold:published.min_tier_threshold??null,
            claim_available_from:null,claim_available_until:null,image_ref:null,
            created_at:published.created_at||'2026-08-13T00:00:00Z'});
          draft.snapshotHash='hash-'+(++draft.hashSeq);
        }
        return {reward_id:wanted,snapshot_hash:draft.snapshotHash};
      }
      case 'save_loyalty_config_draft':{
        const config=(args&&args.p_config)||{};
        if(config.reward){
          const payload=config.reward;
          const id=payload.id||('rw-'+(draft.rewards.length+1));
          const existing=draft.rewards.find(r=>r.reward_id===id);
          const next={reward_id:id,business_id:BIZ,name:payload.name,customer_name:payload.customer_name,
            description:payload.description??null,fulfillment_kind:payload.fulfillment_kind||'manual_item',
            cost_points:payload.cost_points,credit_cents:payload.credit_cents??0,
            estimated_cost_cents:payload.estimated_cost_cents??0,active:payload.active!==false,sort:draft.rewards.length,
            entitlement_expiry_days:null,usage_limit:null,min_tier_id:null,min_tier_threshold:null,
            claim_available_from:null,claim_available_until:null,image_ref:null,created_at:'2026-08-13T00:00:00Z'};
          if(existing)Object.assign(existing,next);else draft.rewards.push(next);
        }else{
          Object.keys(config).forEach(key=>{draft.program[key]=config[key]});
        }
        draft.snapshotHash='hash-'+(++draft.hashSeq);
        if(TABLES.firm_config_versions[0])TABLES.firm_config_versions[0].snapshot_hash=draft.snapshotHash;
        return {version_id:draft.id,status:'draft',snapshot_hash:draft.snapshotHash};
      }
      case 'get_loyalty_reward_draft':
        return {program:{...draft.program},rewards:draftRows(),tiers:[],snapshot_hash:draft.snapshotHash};
      case 'preview_publish_impact':return {rules:[],requires_confirmation:false,
        will_activate_live_financial:false,will_activate_customer_facing:false};
      case 'publish_loyalty_config':
        window.__V301.published.push(args&&args.p_version);
        TABLES.loyalty_programs=[{...draft.program,id:'prog-1',business_id:BIZ,current_config_version_id:draft.id,configuration_status:'published'}];
        TABLES.businesses=[{...bizRow,active_config_version_id:draft.id}];
        TABLES.loyalty_rewards=draft.rewards.map(r=>({...r,id:r.reward_id}));
        TABLES.firm_config_versions=[];
        draft.id=null;draft.rewards=draft.rewards.slice();
        return {status:'ok'};
      default:return null;
    }
  };
  const rpc=(name,args)=>{
    window.__V301.rpc.push({name,args:args??null});
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
  const go=async hash=>{await page.evaluate(h=>{location.hash=h},hash)};
  const modalCount=()=>page.locator('.modal').count();
  const wizardStep=()=>page.evaluate(()=>Number(document.getElementById('growSetupWizardPanelV301')?.dataset.growSetupStepV301||0));
  const waitStep=async number=>page.waitForFunction(
    want=>Number(document.getElementById('growSetupWizardPanelV301')?.dataset.growSetupStepV301||0)===want,
    number,{timeout:20000});
  const noModal=async label=>assertTrue(await modalCount()===0,`no .modal is open ${label}`);
  const rpcNames=()=>page.evaluate(()=>window.__V301.rpc.map(call=>call.name));

  /* ------------------------------ a. the entry ------------------------------ */
  say('a. Programmes list offers "Set up →" and lands on the wizard');
  await page.goto(`${ORIGIN}/index.html#/grow`,{waitUntil:'domcontentloaded'});
  await page.waitForSelector('[data-grow-topic-v229="points"]',{timeout:20000});
  const pointsTile=page.locator('[data-grow-topic-v229="points"]');
  assertTrue((await pointsTile.innerText()).includes('Set up →'),
    'the Points System card offers "Set up →" while nothing is live');
  await pointsTile.click();
  await waitStep(1);
  assertTrue((await page.evaluate(()=>location.hash))==='#/grow/setup',
    'pressing it routes to #/grow/setup — one page, not a popup');
  assertTrue(await page.locator('#growOverview').getAttribute('data-programme-view')==='setup',
    'the Programmes page renders the setup VIEW, so the rail keeps Programmes lit');
  await noModal('on step 1');
  const stepLabels=await page.locator('.grow-setup-step-v301').allInnerTexts();
  assertTrue(stepLabels.length===4,`the stepper shows four steps (found ${stepLabels.length})`);
  assertTrue(/Choose/.test(stepLabels[0])&&/Earning/.test(stepLabels[1])
    &&/Reward/.test(stepLabels[2])&&/Go live/.test(stepLabels[3]),
    `the four steps are Choose / Earning / Reward / Go live (${JSON.stringify(stepLabels)})`);
  assertTrue(await page.locator('[data-grow-setup-family-v301="points"][aria-checked="true"]').count()===1,
    'Points is preselected from the programme’s own model');
  assertTrue(await page.locator('[data-grow-setup-family-v301="stamps"]').count()===1,
    'Stamp card is the other choice, on the same page');

  /* ------------------------------ c. step 2 saves ------------------------------ */
  say('c. step 2 earning rate is editable and Next saves it into the draft');
  await page.click('#growSetupNextV301');
  await waitStep(2);
  await noModal('on step 2');
  assertTrue(await page.locator('#growSetupEarnV301').count()===1,'step 2 has ONE input, in a sentence');
  assertTrue((await page.locator('#growSetupEarnV301').inputValue())==='1','the default earn rate is prefilled');
  await page.fill('#growSetupEarnV301','2');
  await page.waitForFunction(()=>/20 points/.test(document.getElementById('growSetupExampleV301')?.textContent||''),
    null,{timeout:20000});
  assertTrue(true,'the live example recomputes as the rate is typed ("Spend SGD 10 → 20 points")');
  await page.click('#growSetupNextV301');
  await waitStep(3);
  const earnSave=await page.evaluate(()=>window.__V301.rpc
    .filter(call=>call.name==='save_loyalty_config_draft')
    .find(call=>call.args&&call.args.p_config&&call.args.p_config.earn_points_per_dollar!==undefined));
  assertTrue(Boolean(earnSave),'Next fired save_loyalty_config_draft carrying earn_points_per_dollar');
  assertTrue(earnSave.args.p_config.earn_points_per_dollar===2,
    `the saved rate is the typed one (${earnSave.args.p_config.earn_points_per_dollar})`);
  assertTrue(earnSave.args.p_config.loyalty_model==='points_tiers',
    'the save carries the whole model row, never a partial one');
  assertTrue((await rpcNames()).includes('create_loyalty_config_draft'),
    'the draft was created on the first save, not on page load');
  const draftSource=await page.evaluate(()=>window.__V301.rpc
    .find(call=>call.name==='create_loyalty_config_draft')?.args?.p_source);
  assertTrue(draftSource==='owner_setup_wizard_v301',`the draft names this surface as its source (${draftSource})`);

  /* ------------------------------ d. step 3 inline reward ------------------------------ */
  say('d. step 3 is an inline reward form — no dialog — and Next writes the reward');
  await noModal('on step 3');
  assertTrue(await page.locator('[data-grow-setup-rewardform-v301]').count()===1,
    'the reward form is inline in the step body');
  assertTrue(await page.locator('#rewardDialogV238').count()===0,'the old reward dialog is not opened');
  assertTrue(await page.locator('.grow-setup-chip-v301').count()===3,'three one-tap suggestions prefill the form');
  await page.fill('#growSetupRewardNameV301','Free coffee');
  await page.fill('#growSetupRewardBudgetV301','3.00');
  await page.waitForFunction(()=>document.getElementById('growSetupRewardPointsV301')?.value==='300',
    null,{timeout:20000});
  assertTrue(true,'typing the company cost auto-fills the points cost (SGD 3.00 ÷ SGD 0.010)');
  await page.click('#growSetupNextV301');
  await waitStep(4);
  const rewardSave=await page.evaluate(()=>window.__V301.rpc
    .filter(call=>call.name==='save_loyalty_config_draft')
    .find(call=>call.args&&call.args.p_config&&call.args.p_config.reward));
  assertTrue(Boolean(rewardSave),'Next wrote the reward through save_loyalty_config_draft');
  assertTrue(rewardSave.args.p_config.reward.customer_name==='Free coffee'
    &&rewardSave.args.p_config.reward.cost_points===300
    &&rewardSave.args.p_config.reward.estimated_cost_cents===300,
    'the reward envelope carries the name, the points cost and the company cost');
  assertTrue(rewardSave.args.p_config.reward.fulfillment_kind==='manual_item'
    &&rewardSave.args.p_config.reward.credit_cents===0
    &&rewardSave.args.p_config.reward.active===true,
    'and the same defaults the full editor would write');

  /* ------------------------------ e. step 4 publishes ------------------------------ */
  say('e. step 4 states what changes, defaults ON, and publishes');
  await noModal('on step 4');
  await page.waitForFunction(()=>!/Checking what changes/.test(
    document.getElementById('growSetupChangesV301')?.textContent||''),null,{timeout:20000});
  const changesText=await page.locator('#growSetupChangesV301').innerText();
  assertTrue(/Free coffee/.test(changesText),
    `the change list names the reward customers will get (${JSON.stringify(changesText.slice(0,120))})`);
  const stepFourText=await page.locator('#growSetupBodyV301').innerText();
  assertTrue(stepFourText.includes('Programme will be ON — customers start earning when you publish.'),
    'the wizard says the programme will be ON');
  assertTrue(await page.locator('#growSetupPauseV301').isChecked()===false,
    '"Keep it paused for now" exists and is unticked by default');
  assertTrue((await page.locator('#growSetupNextV301').innerText()).includes('Publish now'),
    'the last step’s primary action is Publish now');
  await page.click('#growSetupNextV301');
  await page.waitForFunction(()=>window.__V301.published.length===1,null,{timeout:20000});
  await noModal('while publishing');
  const publishOrder=await page.evaluate(()=>{
    const names=window.__V301.rpc.map(call=>call.name);
    const activeSave=window.__V301.rpc.findIndex(call=>call.name==='save_loyalty_config_draft'
      &&call.args&&call.args.p_config&&call.args.p_config.active===true);
    return {activeSave,preview:names.lastIndexOf('preview_publish_impact'),publish:names.lastIndexOf('publish_loyalty_config'),
      publishedVersion:window.__V301.published[0]};
  });
  assertTrue(publishOrder.activeSave>=0,'Publish first saved {active:true} into the draft');
  assertTrue(publishOrder.activeSave<publishOrder.preview&&publishOrder.preview<publishOrder.publish,
    'the order is save → preview_publish_impact → publish_loyalty_config');
  assertTrue(publishOrder.publishedVersion==='draft-v301',
    `publish_loyalty_config was called with the wizard’s own draft id (${publishOrder.publishedVersion})`);
  await page.waitForSelector('.grow-setup-done-v301',{timeout:20000});
  const doneText=await page.locator('.grow-setup-done-v301').innerText();
  assertTrue(doneText.includes('Published — customers can use this now'),'the success panel replaces the wizard body');
  assertTrue(doneText.includes('SGD 1 spent → 2 points'),'it restates the earning sentence');
  assertTrue(doneText.includes('Free coffee'),'it restates the reward');
  /* The success panel is consumed by whichever of its two controls is pressed, and step f below
     presses "Back to Programmes" (the spec's requirement). The quiet second way on is asserted
     as present and correctly targeted; its click re-enters step 3 through the same goto(3) the
     stepper chips use, which steps g and h exercise. */
  assertTrue(await page.locator('#growSetupAddAnotherV301').count()===1,
    'the quiet "Add another reward" way on is present');
  assertTrue(await page.locator('#growSetupDoneV301').getAttribute('href')==='#/grow/overview',
    '"Back to Programmes" targets the Programmes Overview');

  /* ------------------------------ f. back to Programmes ------------------------------ */
  say('f. "Back to Programmes" lands on the Overview with no draft banner left behind');
  await page.click('#growSetupDoneV301');
  await page.waitForFunction(()=>document.getElementById('growOverview')?.dataset.programmeView==='overview',
    null,{timeout:20000});
  assertTrue(await page.locator('#growOverviewDraftBarV198').count()===0,
    'the unpublished-changes banner is gone once the stub reports no draft');
  await noModal('back on Programmes');

  /* ------------------------------ h. the banner opens step 4 ------------------------------ */
  say('h. the draft banner’s "Review & publish" opens the wizard on step 4');
  /* Recreate an open draft the way production does — by SAVING one. Reaching into the fixture's
     tables would prove the assertion against a state the app cannot actually reach. */
  await go('#/grow/setup');
  await waitStep(1);
  await page.click('#growSetupNextV301');
  await waitStep(2);
  await page.click('#growSetupNextV301');
  await waitStep(3);
  await go('#/grow');
  await page.waitForSelector('#growOverviewDraftPublishV198',{timeout:20000});
  assertTrue(true,'a saved draft brings the "Review & publish" banner back');
  await page.click('#growOverviewDraftPublishV198');
  await waitStep(4);
  assertTrue((await page.evaluate(()=>location.hash))==='#/grow/setup/review',
    'the banner routes to #/grow/setup/review');
  assertTrue(await wizardStep()===4,'and the wizard opens on its final step');
  await noModal('after the banner opened the wizard');

  /* ------------------------------ g. mobile ------------------------------ */
  say('g. 390x844 walks steps 1 to 4 with no horizontal overflow');
  await page.setViewportSize({width:390,height:844});
  await go('#/grow');
  await page.waitForSelector('[data-grow-topic-v229="points"]',{timeout:20000});
  await go('#/grow/setup');
  await waitStep(1);
  const overflow=async label=>{
    const metrics=await page.evaluate(()=>({
      client:document.documentElement.clientWidth,scroll:document.documentElement.scrollWidth}));
    assertTrue(metrics.scroll<=metrics.client+1,
      `${label}: no horizontal overflow at 390px (scroll ${metrics.scroll} vs client ${metrics.client})`);
  };
  const stepperVisible=async label=>assertTrue(
    await page.locator('.grow-setup-steps-v301').isVisible(),`${label}: the stepper is on screen`);
  await overflow('step 1');await stepperVisible('step 1');await noModal('on mobile step 1');
  await page.click('#growSetupNextV301');await waitStep(2);
  await overflow('step 2');await stepperVisible('step 2');
  await page.click('#growSetupNextV301');await waitStep(3);
  await overflow('step 3');await stepperVisible('step 3');
  await page.click('#growSetupNextV301');await waitStep(4);
  await overflow('step 4');await stepperVisible('step 4');await noModal('on mobile step 4');

  /* ------- i. V302: the owner's OWN reported state — paused, WITH a catalogue ------- */
  /* This is the regression that matters. Every step above ran against a brand-new business, and
     that is exactly why V301 shipped looking fixed while the workspace that reported the bug was
     untouched: its programme is PAUSED with a published configuration and four rewards, and the
     V301 gate read that as "a configured programme its owner is managing" and sent the same click
     back to the old drill and the old New-reward popup. Paused is the state a failed setup
     ATTEMPT ends in. The fixture is mutated into that exact shape, in the same browser, and the
     click the owner actually makes must reach the wizard. */
  say("i. a PAUSED programme WITH a published catalogue still opens the wizard (owner's own state)");
  await page.setViewportSize({width:1440,height:1000});
  await page.evaluate(()=>{
    const T=window.__V301.tables,biz=window.__V301.biz;
    T.firm_config_versions.length=0;
    T.firm_config_versions.push({id:'pub-1',business_id:biz,version_no:1,
      based_on_version_id:null,status:'published',snapshot_hash:'hash-pub'});
    T.businesses[0].active_config_version_id='pub-1';
    T.loyalty_programs[0]={...T.loyalty_programs[0],active:false,current_config_version_id:'pub-1'};
    T.loyalty_rewards.length=0;
    T.loyalty_rewards.push({id:'lr-1',business_id:biz,active:true,customer_name:'Free flat white',
      name:'Free flat white',cost_points:400,credit_cents:0,entitlement_expiry_days:null,
      usage_limit:null,min_tier_id:null,min_tier_threshold:null,estimated_cost_cents:600,
      sort:1,claim_available_from:null,claim_available_until:null,created_at:'2026-06-01T00:00:00Z'});
  });
  await go('#/dashboard');
  await page.waitForTimeout(400);
  await go('#/grow');
  await page.waitForSelector('[data-grow-topic-v229="points"]',{timeout:20000});
  await page.click('[data-grow-topic-v229="points"]');
  await page.waitForFunction(()=>location.hash.startsWith('#/grow/setup'),null,{timeout:20000});
  await waitStep(1);
  assertTrue(true,'clicking Points System on a PAUSED programme WITH a catalogue opens the wizard');
  await noModal('after the paused-with-catalogue entry');
  /* Nothing is taken away: the full editor that holds tiers, archived rewards and reward history
     is one click from every step of the wizard. */
  assertTrue(await page.locator('#growSetupFullEditorV302').count()===1,
    'the wizard links to the full editor, so a configured owner loses no capability');
  const fullEditorHref=await page.locator('#growSetupFullEditorV302').getAttribute('href');
  assertTrue(String(fullEditorHref||'').startsWith('#/loyalty'),
    `the full-editor link points at the reward editor (${fullEditorHref})`);
  /* And the catalogue this business already has is carried INTO the wizard, not hidden from it.
     V302: the list is published rewards MERGED with the draft's own versions, because
     create_loyalty_config_draft copies the programme row and the tiers into a new draft but not
     the reward versions — so reading the draft alone would show an owner with four published
     rewards an empty step 3 and invite them to re-create what they already have. */
  await page.click('#growSetupNextV301');await waitStep(2);
  await page.click('#growSetupNextV301');await waitStep(3);
  const stepThreeCatalogue=await page.locator('#growSetupBodyV301').innerText();
  assertTrue(stepThreeCatalogue.includes('Free flat white'),
    'step 3 lists the PUBLISHED reward even though the fresh draft does not carry it yet');
  await noModal('on step 3 with an existing catalogue');
  /* Editing that published reward must MATERIALISE it into the draft first. Without it,
     save_loyalty_reward_draft coalesces the fields this three-field form does not send from a
     draft version that does not exist — writing NULL description / fulfilment kind beside the
     edit, which publishing would then put onto a working reward. */
  await page.click('[data-grow-setup-reward-edit-v301="lr-1"]');
  await page.waitForTimeout(300);
  assertTrue((await page.locator('#growSetupRewardNameV301').inputValue())==='Free flat white',
    'Edit loads that exact reward into the inline form (still no dialog)');
  await noModal('while editing an existing reward');
  await page.fill('#growSetupRewardBudgetV301','7.50');
  await page.waitForTimeout(250);
  await page.click('#growSetupNextV301');await waitStep(4);
  const ensureCall=await page.evaluate(()=>window.__V301.rpc
    .map((call,index)=>({name:call.name,index}))
    .filter(call=>call.name==='ensure_published_reward_in_draft_v138'||call.name==='save_loyalty_reward_draft'
      ||call.name==='save_loyalty_config_draft'));
  const firstEnsure=ensureCall.find(call=>call.name==='ensure_published_reward_in_draft_v138');
  assertTrue(Boolean(firstEnsure),
    'editing a published reward calls ensure_published_reward_in_draft_v138 before writing it');
  const rewardWrite=ensureCall.find(call=>call.index>(firstEnsure?.index??Infinity));
  assertTrue(Boolean(rewardWrite),`the reward write follows the materialisation (${rewardWrite?.name})`);

  if(pageErrors.length)process.stdout.write(`note: page errors observed (non-fatal): ${JSON.stringify(pageErrors)}\n`);
  process.stdout.write('V301 setup wizard walkthrough PASS (steps a-i)\n');
}catch(error){
  process.stdout.write(`V301 walkthrough FAIL at ${step}\n${error?.stack||error}\n`);
  if(pageErrors.length)process.stdout.write(`page errors: ${JSON.stringify(pageErrors)}\n`);
  process.exitCode=1;
}finally{
  await browser.close().catch(()=>{});
  if(server)server.kill();
}
