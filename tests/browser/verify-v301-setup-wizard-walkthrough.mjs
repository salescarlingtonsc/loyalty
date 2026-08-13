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
 *   i. V302: a PAUSED programme WITH a published catalogue still opens the wizard.
 *   j. V303: a LIVE programme — all THREE point-engine cards (Points System / Tiered membership /
 *      Stamp card) open the wizard, prefilled, with zero .modal. This is the third round of the
 *      same owner report: V302 widened the gate to "not live", and the owner then re-tested from
 *      a workspace whose programme IS live and found the old drill again.
 *   k. V303: the tiers ladder is BUILDABLE here — the Tiers step lists the live tiers, the inline
 *      form adds one, Next fires save_loyalty_tier_draft_v143, and publishing writes
 *      publish_loyalty_config THEN the businesses.points_mode switch, in that order.
 *   l. V303: Add reward and per-reward Edit on the live reward grid land on the wizard's Reward
 *      step with the form armed — never the old New-reward dialog.
 *      (l runs before k: publishing a tier programme switches the workspace to points_mode
 *      'tiers', where the Programmes page shows the tier note in place of the reward grid.)
 *   m. V303: gift cards are gone from the business UI — no nav row, no Customer Interface
 *      sub-tab, and #/giftcards is refused with a plain toast instead of rendering.
 *   n. V304: the Reward and Tiers steps save themselves. "Add reward" / "Add tier" grow the list
 *      WITHOUT the step changing; editing a listed row updates that row as it is typed and
 *      auto-saves ~900ms later with no button pressed; Remove writes active:false and leaves the
 *      row in place with Undo (which writes active:true back); and removing the last tier of a
 *      tier model is refused inline. Zero dialogs throughout — the undo is the safety.
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
  /* V303: the draft carries TIERS as well as rewards, because the wizard's Tiers step writes them
     through save_loyalty_tier_draft_v143 and re-reads them from get_loyalty_reward_draft. */
  const draft={id:null,version_no:2,snapshotHash:'hash-1',hashSeq:1,
    program:{...program},rewards:[],tiers:[]};
  /* V302: the table set and the business id are exposed so a step can put this business into a
     DIFFERENT starting state in the same browser — specifically the owner's own reported one, a
     paused programme with a published configuration and a reward catalogue. */
  /* V303: one monotonic sequence across BOTH recorders, so a step can assert that the
     businesses.points_mode write happened AFTER publish_loyalty_config and not merely that both
     happened. Ordering is the whole point of that rule. */
  let seqV303=0;
  window.__V301={rpc:[],writes:[],draft,published:[],tables:TABLES,biz:BIZ,seq:()=>++seqV303};
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
      window.__V301.writes.push({table,op:q.op,payload:q.payload??null,seq:window.__V301.seq()});
      /* V303: the points_mode switch is a real live write, so the fixture APPLIES it — recording
         it only would let a re-render disagree with what the wizard just did. */
      if(table==='businesses'&&q.op==='update'&&q.payload&&q.payload.points_mode!==undefined){
        bizRow.points_mode=q.payload.points_mode;
        TABLES.businesses=TABLES.businesses.map(row=>({...row,points_mode:q.payload.points_mode}));
      }
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
        /* Mirrors the real function: a new draft COPIES the programme row and the tiers, but not
           the reward versions (that is what ensure_published_reward_in_draft_v138 is for). */
        if(!draft.tiers.length)draft.tiers=(TABLES.loyalty_tiers||[]).map(t=>({...t,tier_id:t.id}));
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
          /* V304: active is COALESCED, the way save_loyalty_reward_draft coalesces every key it is
             not given. The wizard's three-field edit omits it, and a stub that read the absent key
             as true would have silently un-archived a reward the owner had just removed — hiding
             exactly the defect step (n) exists to prove. */
          const nextActive=payload.active===undefined
            ?(existing?existing.active!==false:true):payload.active!==false;
          const next={reward_id:id,business_id:BIZ,name:payload.name,customer_name:payload.customer_name,
            description:payload.description??null,fulfillment_kind:payload.fulfillment_kind||'manual_item',
            cost_points:payload.cost_points,credit_cents:payload.credit_cents??0,
            estimated_cost_cents:payload.estimated_cost_cents??0,active:nextActive,sort:draft.rewards.length,
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
      /* V303: the SAME writer the deep editor's Add tier / Save tier button uses. Upsert on id,
         bump the hash, and hand the new hash back so consecutive tier writes are never stale. */
      case 'save_loyalty_tier_draft_v143':{
        const payload=(args&&args.p_tier)||{};
        const id=payload.id||payload.tier_id;
        const existing=draft.tiers.find(t=>(t.tier_id||t.id)===id);
        const next={tier_id:id,id,business_id:BIZ,name:payload.name,threshold:payload.threshold,
          points_multiplier:payload.points_multiplier??1,perk_note:payload.perk_note??null,
          sort:payload.sort??draft.tiers.length,active:payload.active!==false,
          effective_from:payload.effective_from??null,expires_at:payload.expires_at??null};
        if(existing)Object.assign(existing,next);else draft.tiers.push(next);
        draft.snapshotHash='hash-'+(++draft.hashSeq);
        return {tier_id:id,snapshot_hash:draft.snapshotHash};
      }
      case 'get_loyalty_reward_draft':
        return {program:{...draft.program},rewards:draftRows(),
          tiers:draft.tiers.map(t=>({...t})),snapshot_hash:draft.snapshotHash};
      case 'preview_publish_impact':return {rules:[],requires_confirmation:false,
        will_activate_live_financial:false,will_activate_customer_facing:false};
      case 'publish_loyalty_config':
        window.__V301.published.push(args&&args.p_version);
        TABLES.loyalty_programs=[{...draft.program,id:'prog-1',business_id:BIZ,current_config_version_id:draft.id,configuration_status:'published'}];
        TABLES.businesses=[{...bizRow,active_config_version_id:draft.id}];
        TABLES.loyalty_rewards=draft.rewards.map(r=>({...r,id:r.reward_id}));
        TABLES.loyalty_tiers=draft.tiers.map(t=>({...t,id:t.tier_id||t.id}));
        TABLES.firm_config_versions=[];
        draft.id=null;draft.rewards=draft.rewards.slice();draft.tiers=draft.tiers.slice();
        return {status:'ok'};
      default:return null;
    }
  };
  const rpc=(name,args)=>{
    window.__V301.rpc.push({name,args:args??null,seq:window.__V301.seq()});
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

  /* ---- j. V303: the owner's CURRENT state — the programme is LIVE ---- */
  /* Third round of the same report. V301 excluded a configured programme; V302 excluded a LIVE
     one; the owner re-tested from a workspace whose programme is now live and found the old drill
     again, and the Tiered membership card led to a drill whose first row reads "Tier membership is
     off". The standing rule is that the wizard IS this module's UX, for first set-up and for
     editing, live or not — so all THREE point-engine cards are exercised against a live fixture. */
  say('j. a LIVE programme: all three point-engine cards open the wizard, prefilled, no dialog');
  await page.evaluate(()=>{
    const T=window.__V301.tables,biz=window.__V301.biz,D=window.__V301.draft;
    /* Back to a clean slate, then into the owner's reported shape: live, published, four rewards
       and three tiers. Reaching in is legitimate HERE — this is the starting state, not an
       outcome the app is supposed to have produced. */
    D.id=null;D.rewards.length=0;D.tiers.length=0;
    T.firm_config_versions.length=0;
    T.businesses[0].active_config_version_id='pub-1';
    T.businesses[0].points_mode='redeem';
    T.loyalty_programs[0]={...T.loyalty_programs[0],active:true,current_config_version_id:'pub-1',
      configuration_status:'published',loyalty_model:'points_tiers',tier_basis:'visits'};
    T.loyalty_rewards.length=0;
    ['Free flat white','Free pastry','5 off','Free tote'].forEach((name,index)=>{
      T.loyalty_rewards.push({id:`lr-${index+1}`,business_id:biz,active:true,customer_name:name,
        name,cost_points:200*(index+1),credit_cents:0,entitlement_expiry_days:null,usage_limit:null,
        min_tier_id:null,min_tier_threshold:null,estimated_cost_cents:300*(index+1),sort:index,
        claim_available_from:null,claim_available_until:null,created_at:'2026-06-01T00:00:00Z'});
    });
    T.loyalty_tiers.length=0;
    [['Bronze',0],['Silver',10],['Gold',25]].forEach(([name,threshold],index)=>{
      T.loyalty_tiers.push({id:`tier-${index+1}`,business_id:biz,name,threshold,
        points_multiplier:1,perk_note:null,sort:index,active:true,
        effective_from:null,expires_at:null});
    });
  });
  const reloadGrowV303=async()=>{
    await go('#/dashboard');
    await page.waitForTimeout(400);
    await go('#/grow');
    await page.waitForSelector('[data-grow-topic-v229="points"]',{timeout:20000});
  };
  const cardsV303=[['points','redeem','Points System',4],['tiers','tiers','Tiered membership',5],
    ['stamps','stamps','Stamp card',4]];
  for(const [topic,model,label,stepCount] of cardsV303){
    await reloadGrowV303();
    const tile=page.locator(`[data-grow-topic-v229="${topic}"]`);
    assertTrue(await tile.count()===1,`the ${label} card is on the Programmes list`);
    await tile.click();
    await page.waitForFunction(()=>location.hash.startsWith('#/grow/setup'),null,{timeout:20000});
    await waitStep(1);
    assertTrue(await page.locator(`[data-grow-setup-model-v303="${model}"][aria-checked="true"]`).count()===1,
      `pressing ${label} opens the wizard PRESELECTED on ${model} — the choice is not asked twice`);
    assertTrue(await page.locator('[data-grow-setup-model-v303]').count()===4,
      'step 1 offers the same four models the deep editor offers');
    const labels=await page.locator('.grow-setup-step-v301').allInnerTexts();
    assertTrue(labels.length===stepCount,
      `${label} runs ${stepCount} steps (found ${labels.length}: ${JSON.stringify(labels)})`);
    await noModal(`after the LIVE ${label} card`);
    assertTrue(await page.locator('#rewardDialogV238').count()===0,
      `the old New-reward dialog is not opened by ${label}`);
  }
  await reloadGrowV303();
  assertTrue((await page.locator('[data-grow-topic-v229="points"]').innerText()).includes('Edit →'),
    'a LIVE card says "Edit →" — the word matches what pressing it does');
  assertTrue((await page.locator('[data-grow-topic-v229="tiers"]').innerText()).includes('Set up →'),
    'a card whose model is NOT reaching customers still says "Set up →"');

  /* ---- l. V303: Add reward / Edit reward never reopen the dialog ---- */
  /* Owner: "pressing add rewards - still brings me to this page", screenshotting the old
     New-reward dialog. The reward grid is reached the way an owner reaches it — the Programmes
     "Ongoing programmes" view, which renders the same cards the drill does. */
  /* Ordered before step k on purpose: publishing a tier programme switches this workspace to
     points_mode='tiers', where the Programmes page deliberately shows the tier note IN PLACE of
     the reward grid. The owner's screenshot of the New-reward dialog was taken on a points
     workspace with a live catalogue, which is the state the fixture is in right now. */
  say('l. Add reward and per-reward Edit land on the wizard Reward step, with no dialog');
  /* The reward grid renders on both Programmes views that show the category list. The dashed
     "+ Add reward" card carries no status pill, so the "Ongoing programmes" filter hides it and
     "Pending setup" is where an owner presses it; a LIVE reward card is the other way round.
     Each control is therefore exercised on the view it is actually visible in. */
  await go('#/dashboard');await page.waitForTimeout(400);
  await go('#/grow/available');
  await page.waitForSelector('[data-rewards-overview-edit="add"]',{timeout:20000});
  await noModal('on the reward grid');
  await page.click('[data-rewards-overview-edit="add"]');
  await page.waitForFunction(()=>location.hash.startsWith('#/grow/setup'),null,{timeout:20000});
  await page.waitForSelector('[data-grow-setup-rewardform-v301]',{timeout:20000});
  assertTrue(await page.locator('#rewardDialogV238').count()===0,
    'Add reward does NOT open the old New-reward dialog');
  await noModal('after Add reward');
  assertTrue((await page.locator('#growSetupRewardNameV301').inputValue())==='',
    'it lands on an empty inline form, armed and ready');
  const armedStep=await wizardStep();
  const armedLabel=await page.locator('.grow-setup-step-v301.is-current').innerText();
  assertTrue(/Reward/.test(armedLabel),`and on the Reward step (step ${armedStep}: ${armedLabel})`);
  await go('#/dashboard');await page.waitForTimeout(400);
  await go('#/grow/ongoing');
  await page.waitForSelector('[data-rewards-overview-edit="catalogue"]',{timeout:20000});
  await page.click('[data-rewards-overview-edit="catalogue"][data-reward-id="lr-2"]');
  await page.waitForFunction(()=>location.hash.startsWith('#/grow/setup'),null,{timeout:20000});
  await page.waitForSelector('#growSetupRewardNameV301',{timeout:20000});
  assertTrue((await page.locator('#growSetupRewardNameV301').inputValue())==='Free pastry',
    'per-reward Edit opens the wizard with THAT reward in the inline form');
  await noModal('while editing a reward from the grid');
  assertTrue(await page.locator('#rewardDialogV238').count()===0,
    'and the old dialog is still not opened');

  /* ---- k. V303: a tier ladder is buildable here, exactly the way points are ---- */
  say('k. Tiered membership: the Tiers step lists, adds and saves a tier, then publishes the mode');
  await reloadGrowV303();
  await page.click('[data-grow-topic-v229="tiers"]');
  await waitStep(1);
  await page.click('#growSetupNextV301');await waitStep(2);
  await page.click('#growSetupNextV301');await waitStep(3);
  const tiersBody=await page.locator('#growSetupBodyV301').innerText();
  for(const name of ['Bronze','Silver','Gold'])
    assertTrue(tiersBody.includes(name),`the Tiers step lists the LIVE tier "${name}"`);
  assertTrue(await page.locator('[data-grow-setup-tierform-v303]').count()===1,
    'the tier form is INLINE in the step body');
  await noModal('on the Tiers step');
  assertTrue((await page.locator('label[for="growSetupTierThresholdV303"]').innerText()).includes('Visits'),
    'the threshold is labelled in the unit tier_basis actually measures');
  await page.fill('#growSetupTierNameV303','Platinum');
  await page.fill('#growSetupTierThresholdV303','50');
  await page.click('#growSetupNextV301');
  await waitStep(4);
  const tierSave=await page.evaluate(()=>window.__V301.rpc
    .filter(call=>call.name==='save_loyalty_tier_draft_v143')
    .map(call=>call.args));
  assertTrue(tierSave.length===1,`exactly the ONE touched tier was written (${tierSave.length})`);
  assertTrue(tierSave[0].p_tier.name==='Platinum'&&tierSave[0].p_tier.threshold===50,
    'the p_tier envelope carries the typed name and threshold');
  assertTrue(tierSave[0].p_tier.points_multiplier===1&&tierSave[0].p_tier.active===true
    &&Object.prototype.hasOwnProperty.call(tierSave[0].p_tier,'perk_note'),
    'and the whole tier row, so an advanced-editor field is never blanked by a two-field form');
  assertTrue(typeof tierSave[0].p_expected_snapshot_hash==='string',
    'the write carries the snapshot hash it read');
  assertTrue(await page.locator('#growSetupBodyV301').innerText().then(t=>/Free flat white/.test(t)),
    'step 4 is the Reward step, carrying the live catalogue');
  await page.click('#growSetupNextV301');await waitStep(5);
  await page.waitForFunction(()=>!/Checking what changes/.test(
    document.getElementById('growSetupChangesV301')?.textContent||''),null,{timeout:20000});
  const goLiveText=await page.locator('#growSetupBodyV301').innerText();
  assertTrue(/Points will now build tier membership/.test(goLiveText),
    'the Go-live step states the mode change in plain words BEFORE Publish is pressed');
  const publishedBefore=await page.evaluate(()=>window.__V301.published.length);
  await page.click('#growSetupNextV301');
  await page.waitForSelector('.grow-setup-done-v301',{timeout:20000});
  await noModal('after publishing a tier programme');
  const modeOrder=await page.evaluate(before=>{
    const names=window.__V301.rpc.map(call=>call.name);
    return {published:window.__V301.published.length,before,
      publishAt:names.lastIndexOf('publish_loyalty_config'),
      modeWrites:window.__V301.writes.filter(w=>w.table==='businesses'&&w.payload&&w.payload.points_mode),
      publishSeq:Math.max(...window.__V301.rpc.filter(c=>c.name==='publish_loyalty_config').map(c=>c.seq))};
  },publishedBefore);
  assertTrue(modeOrder.published===publishedBefore+1,'publish_loyalty_config ran exactly once');
  assertTrue(modeOrder.modeWrites.length===1
    &&modeOrder.modeWrites[0].payload.points_mode==='tiers',
    `the points_mode switch was written once, to tiers (${JSON.stringify(modeOrder.modeWrites)})`);
  /* AFTER the publish, never before: points_mode is an instant live switch, so writing it early
     would change what customers can do before the configuration that assumes it went live. */
  assertTrue(modeOrder.modeWrites[0].seq>modeOrder.publishSeq,
    `the mode switch followed publish_loyalty_config (mode ${modeOrder.modeWrites[0].seq} vs publish ${modeOrder.publishSeq})`);
  assertTrue((await page.locator('.grow-setup-done-v301').innerText())
    .includes('Published — customers can use this now'),'the success panel replaces the wizard body');
  assertTrue(await page.locator('#growSetupModeRetryV303').count()===0,
    'and no mode-retry is shown, because the switch succeeded');

  /* ---- m. V303: gift cards are gone from the business UI ---- */
  say('m. gift cards have no nav row, no Customer Interface sub-tab, and #/giftcards is refused');
  await go('#/dashboard');
  await page.waitForTimeout(500);
  assertTrue(await page.locator('a[href="#/giftcards"]').count()===0,
    'no rail row, anywhere in the shell, leads to Gift cards');
  const serveText=await page.evaluate(()=>{
    const rows=[...document.querySelectorAll('.shell a,.shell button')];
    return rows.map(node=>node.textContent||'').join(' | ');
  });
  assertTrue(!/Gift cards/.test(serveText),'and no nav control is labelled "Gift cards"');
  await go('#/giftcards');
  await page.waitForFunction(()=>location.hash==='#/dashboard',null,{timeout:20000});
  assertTrue(true,'a typed #/giftcards is refused and corrected to #/dashboard');
  const refusalToast=await page.locator('#toast').innerText();
  assertTrue(refusalToast.includes('Gift cards are no longer part of this workspace.'),
    `and it SAYS so rather than bouncing silently (${JSON.stringify(refusalToast)})`);
  await go('#/customer-interface');
  await page.waitForSelector('[data-ci-view-v296="preview"]',{timeout:20000});
  assertTrue(await page.locator('[data-ci-view-v296="giftcards"]').count()===0,
    'Customer Interface has no Gift cards section left');
  assertTrue(await page.locator('#giftCardEnabled').count()===0,
    'and no gift-card issuance switch');
  assertTrue(await page.locator('a[href="#/customer-interface/giftcards"]').count()===0,
    'and no rail sub-tab pointing at one');

  /* ---- n. V304: the two list steps save themselves, in place ---- */
  /* Owner, on the shipped V303 build: "i typed the points or cost needed for points redemption -
     but not reflected in the system and not auto saved (it needs to reflect as i change it, so
     will not have confusion)", "i need to be able to add extra tier / delete tier", and "for
     rewards subtab - i need to be able to add or delete. because now i need to press 'next' then
     press 'back' to view changes". Everything below happens WITHOUT the step number changing —
     that is the whole report. */
  say('n. Reward and Tiers steps add, reflect, auto-save, remove and undo without leaving the step');
  await page.setViewportSize({width:1440,height:1000});
  /* A real RELOAD first. Step k's publish switched businesses.points_mode to 'tiers' and the app
     cached that on S.biz, so the Points System card would hand over the 'tiers' model and open the
     ladder where this step needs the reward catalogue. A hash bounce cannot clear a cached S.biz;
     reloading re-runs the init script, which rebuilds the fixture at its cold start — so the live
     POINTS shape is re-applied AFTER the reload, not before it. */
  await page.evaluate(()=>{location.hash='#/grow'});
  await page.reload({waitUntil:'domcontentloaded'});
  await page.waitForSelector('[data-grow-topic-v229="points"]',{timeout:20000});
  await page.evaluate(()=>{
    const T=window.__V301.tables,biz=window.__V301.biz,D=window.__V301.draft;
    D.id=null;D.rewards.length=0;D.tiers.length=0;
    T.firm_config_versions.length=0;
    T.businesses[0].active_config_version_id='pub-1';
    T.businesses[0].points_mode='redeem';
    T.loyalty_programs[0]={...T.loyalty_programs[0],active:true,current_config_version_id:'pub-1',
      configuration_status:'published',loyalty_model:'points_tiers',tier_basis:'visits'};
    T.loyalty_rewards.length=0;
    ['Free flat white','Free pastry','5 off','Free tote'].forEach((name,index)=>{
      T.loyalty_rewards.push({id:`lr-${index+1}`,business_id:biz,active:true,customer_name:name,
        name,cost_points:200*(index+1),credit_cents:0,entitlement_expiry_days:null,usage_limit:null,
        min_tier_id:null,min_tier_threshold:null,estimated_cost_cents:300*(index+1),sort:index,
        claim_available_from:null,claim_available_until:null,created_at:'2026-06-01T00:00:00Z'});
    });
    T.loyalty_tiers.length=0;
    [['Bronze',0],['Silver',10],['Gold',25]].forEach(([name,threshold],index)=>{
      T.loyalty_tiers.push({id:`tier-${index+1}`,business_id:biz,name,threshold,
        points_multiplier:1,perk_note:null,sort:index,active:true,
        effective_from:null,expires_at:null});
    });
  });
  const rewardWritesV304=()=>page.evaluate(()=>window.__V301.rpc
    .filter(call=>call.name==='save_loyalty_config_draft'
      &&call.args&&call.args.p_config&&call.args.p_config.reward)
    .map(call=>call.args.p_config.reward));
  const tierWritesV304=()=>page.evaluate(()=>window.__V301.rpc
    .filter(call=>call.name==='save_loyalty_tier_draft_v143').map(call=>call.args.p_tier));
  const rowTextV304=async(kind,id)=>page.locator(`[data-grow-setup-${kind}row-v304="${id}"]`).innerText();
  await reloadGrowV303();
  await page.click('[data-grow-topic-v229="points"]');
  await waitStep(1);
  await page.click('#growSetupNextV301');await waitStep(2);
  await page.click('#growSetupNextV301');await waitStep(3);
  const rewardStepV304=await wizardStep();
  assertTrue(await page.locator('#growSetupRewardSaveV304').count()===1,
    'the Reward form carries its own primary action, inside the form card');
  assertTrue((await page.locator('#growSetupRewardSaveV304').innerText()).includes('Add reward'),
    'an empty form offers "Add reward"');
  const formCopyV304=await page.locator('[data-grow-setup-rewardform-v301]').innerText();
  assertTrue(!/press Next to add/.test(formCopyV304)&&/saves it to the list right away/.test(formCopyV304),
    `the copy matches the button rather than telling the owner to press Next (${JSON.stringify(formCopyV304.slice(-90))})`);

  /* n1. Add, in place. */
  const rewardsBeforeAdd=await page.locator('[data-grow-setup-rewardrow-v304]').count();
  await page.fill('#growSetupRewardNameV301','Free muffin');
  await page.fill('#growSetupRewardPointsV301','450');
  await page.click('#growSetupRewardSaveV304');
  await page.waitForFunction(before=>document.querySelectorAll('[data-grow-setup-rewardrow-v304]').length===before+1,
    rewardsBeforeAdd,{timeout:20000});
  assertTrue(await wizardStep()===rewardStepV304,
    'pressing "Add reward" did NOT change the step — the list grew where the owner was standing');
  assertTrue((await page.locator('#growSetupBodyV301').innerText()).includes('Free muffin'),
    'the new reward is listed immediately, with no Next-then-Back round trip');
  const addWrite=(await rewardWritesV304()).find(reward=>reward.customer_name==='Free muffin');
  assertTrue(Boolean(addWrite)&&addWrite.cost_points===450,
    `the button wrote the reward through save_loyalty_config_draft (${JSON.stringify(addWrite&&addWrite.cost_points)})`);
  assertTrue((await page.locator('#growSetupRewardNameV301').inputValue())==='',
    'and the form cleared, ready for the next one');
  await noModal('after adding a reward in place');

  /* n2. Live reflection, then auto-save. */
  await page.click('[data-grow-setup-reward-edit-v301="lr-2"]');
  await page.waitForFunction(()=>document.getElementById('growSetupRewardNameV301')?.value==='Free pastry',
    null,{timeout:20000});
  assertTrue(/editing/.test(await rowTextV304('reward','lr-2')),
    'the row being edited says so, so the owner knows which one the fields belong to');
  const writesBeforeType=(await rewardWritesV304()).length;
  await page.fill('#growSetupRewardPointsV301','777');
  assertTrue(/777/.test(await rowTextV304('reward','lr-2')),
    'the row shows the new cost AS IT IS TYPED, before anything is saved');
  assertTrue((await rewardWritesV304()).length===writesBeforeType,
    'and nothing has been written yet — the save is debounced, not per keystroke');
  await page.waitForFunction(()=>window.__V301.rpc.some(call=>call.name==='save_loyalty_config_draft'
    &&call.args&&call.args.p_config&&call.args.p_config.reward
    &&call.args.p_config.reward.id==='lr-2'&&call.args.p_config.reward.cost_points===777),
    null,{timeout:20000});
  assertTrue(true,'~900ms after the last keystroke the change auto-saved, with no button pressed');
  assertTrue(!/editing/.test(await rowTextV304('reward','lr-2')),
    'and the "· editing" affix cleared once it was stored');
  const ensuredV304=await page.evaluate(()=>window.__V301.rpc
    .filter(call=>call.name==='ensure_published_reward_in_draft_v138'
      &&call.args&&call.args.p_reward==='lr-2').length);
  assertTrue(ensuredV304>0,
    'the auto-save materialised the published reward into the draft first, exactly as Next did');

  /* n3. Remove, with undo, and no dialog. */
  await page.click('[data-grow-setup-reward-remove-v304="lr-1"]');
  await page.waitForFunction(()=>window.__V301.rpc.some(call=>call.name==='save_loyalty_config_draft'
    &&call.args&&call.args.p_config&&call.args.p_config.reward
    &&call.args.p_config.reward.id==='lr-1'&&call.args.p_config.reward.active===false),
    null,{timeout:20000});
  assertTrue(true,'Remove wrote active:false through the same reward writer');
  await noModal('after removing a reward');
  assertTrue(await page.locator('[data-grow-setup-reward-remove-v304="lr-1"]').count()===0
    &&await page.locator('[data-grow-setup-reward-undo-v304="lr-1"]').count()===1,
    'the row stays in place and offers Undo — the undo is the safety, not a confirm dialog');
  assertTrue(/Removed/.test(await rowTextV304('reward','lr-1')),
    'and it reads "Removed"');
  await page.click('[data-grow-setup-reward-undo-v304="lr-1"]');
  await page.waitForFunction(()=>window.__V301.rpc.some(call=>call.name==='save_loyalty_config_draft'
    &&call.args&&call.args.p_config&&call.args.p_config.reward
    &&call.args.p_config.reward.id==='lr-1'&&call.args.p_config.reward.active===true),
    null,{timeout:20000});
  assertTrue(true,'Undo wrote active:true back through the same writer');
  assertTrue(await page.locator('[data-grow-setup-reward-remove-v304="lr-1"]').count()===1,
    'and the row is claimable again');
  assertTrue(await wizardStep()===rewardStepV304,
    'none of add / edit / auto-save / remove / undo moved the owner off the Reward step');

  /* n4. The Tiers step, same three abilities. */
  await reloadGrowV303();
  await page.click('[data-grow-topic-v229="tiers"]');
  await waitStep(1);
  await page.click('#growSetupNextV301');await waitStep(2);
  await page.click('#growSetupNextV301');await waitStep(3);
  const tierStepV304=await wizardStep();
  const tiersBeforeAdd=await page.locator('[data-grow-setup-tierrow-v304]').count();
  assertTrue(tiersBeforeAdd===3,`the Tiers step lists the three live tiers (${tiersBeforeAdd})`);
  const tierFormCopyV304=await page.locator('[data-grow-setup-tierform-v303]').innerText();
  assertTrue(!/press Next to add/.test(tierFormCopyV304)&&/Add tier saves it to the list right away/.test(tierFormCopyV304),
    'the tier form copy matches its button too');
  await page.fill('#growSetupTierNameV303','Diamond');
  await page.fill('#growSetupTierThresholdV303','50');
  await page.click('#growSetupTierSaveV304');
  await page.waitForFunction(before=>document.querySelectorAll('[data-grow-setup-tierrow-v304]').length===before+1,
    tiersBeforeAdd,{timeout:20000});
  assertTrue(await wizardStep()===tierStepV304,
    'pressing "Add tier" added the fourth tier without changing the step (owner: "add extra tier")');
  const diamond=(await tierWritesV304()).find(tier=>tier.name==='Diamond');
  assertTrue(Boolean(diamond)&&diamond.threshold===50,
    'the tier went through save_loyalty_tier_draft_v143 with the typed threshold');
  await noModal('after adding a tier in place');
  /* Remove down to the last one; the last one is refused, inline, in words that name the way out. */
  for(const id of ['tier-1','tier-2','tier-3']){
    await page.click(`[data-grow-setup-tier-remove-v304="${id}"]`);
    await page.waitForFunction(wanted=>window.__V301.rpc.some(call=>call.name==='save_loyalty_tier_draft_v143'
      &&call.args&&call.args.p_tier&&call.args.p_tier.id===wanted&&call.args.p_tier.active===false),
      id,{timeout:20000});
    assertTrue(await page.locator(`[data-grow-setup-tier-undo-v304="${id}"]`).count()===1,
      `removing ${id} wrote active:false and left an Undo on the row`);
  }
  await noModal('after removing tiers');
  const lastTier=await page.locator('[data-grow-setup-tier-remove-v304]').first().getAttribute('data-grow-setup-tier-remove-v304');
  const tierWritesBeforeLast=(await tierWritesV304()).length;
  await page.click(`[data-grow-setup-tier-remove-v304="${lastTier}"]`);
  await page.waitForFunction(()=>/Keep at least one tier/.test(
    document.getElementById('growSetupWizardPanelV301')?.innerText||''),null,{timeout:20000});
  assertTrue((await tierWritesV304()).length===tierWritesBeforeLast,
    'removing the LAST tier of a tier model is refused inline, and writes nothing');
  assertTrue((await page.locator('#growSetupWizardPanelV301').innerText()).includes('Keep at least one tier, or switch model in Choose.'),
    'and the refusal names the way out rather than being a dead end');
  await noModal('after the refused last-tier removal');

  if(pageErrors.length)process.stdout.write(`note: page errors observed (non-fatal): ${JSON.stringify(pageErrors)}\n`);
  process.stdout.write('V301 setup wizard walkthrough PASS (steps a-n)\n');
}catch(error){
  process.stdout.write(`V301 walkthrough FAIL at ${step}\n${error?.stack||error}\n`);
  if(pageErrors.length)process.stdout.write(`page errors: ${JSON.stringify(pageErrors)}\n`);
  process.exitCode=1;
}finally{
  await browser.close().catch(()=>{});
  if(server)server.kill();
}
