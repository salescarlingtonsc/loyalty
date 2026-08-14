/* W6 INCREMENT 2 switchboard walkthrough — the four-switch Programmes home, driven in a REAL browser.
 *
 * Why this file exists: the increment's first source-only review passed 74/74 while every one of the
 * four switchboard toggles and all three expiry chips were INERT in a browser — the handlers read
 * `button.dataset.growSetupSwitchW6I2` but the HTML dataset rule delivers `growSetupSwitchW6i2`
 * (lowercase i, because only a letter directly following a hyphen is uppercased). No source regex can
 * see that. Every assertion below therefore reads RENDERED state (aria-checked, the ON/OFF pill, the
 * select's value, the stepper's labels) or the RPC arguments that actually left the page.
 *
 * Drives the REAL production bundles (app/index.html + the stamped chunks — run `npm run bundle-stamp`
 * first) through the real router, with the Supabase client replaced by an in-page fixture (same
 * pattern as verify-v295-owner-fixes-walkthrough.mjs and verify-v294-owner-batch-walkthrough.mjs).
 *
 * What it asserts, at 1440 AND at 390 (the whole suite runs twice):
 *   a. zero switches on -> the rail is screen 0 + Go live, and Publish is refused IN WORDS beside a
 *      button that is also disabled — not a dead button.
 *   b. each of the four toggles actually flips, and flipping one leaves the other three exactly as
 *      they were (the defect-6 class, asserted on the rendered ON/OFF pill and aria-checked).
 *   c. all four on -> the rail composes in the customer-facing order (stamps -> points -> tiers ->
 *      referral) with exactly ONE running percentage that advances.
 *   d. a points-earned basis with Points & gifts OFF shows the requirement, the one-tap
 *      "Turn on Points & gifts" works and keeps the owner on Climbing, and Next AND Publish refuse
 *      until it is satisfied.
 *   e. the three one-tap expiry chips actually set the mode (read back off the <select>).
 *   f. a stored VISITS ladder opens on Visits (defect 1), a threshold raise renders the D3 movement
 *      block with its tick, Publish stays refused until ticked, AND the tick is re-checked inside the
 *      publish flow (untick after a failed publish, press Retry -> refused, nothing published).
 *   g. exactly ONE set_programmes_v314 call leaves the browser per publish, carrying all four keys;
 *      a keep-it-paused publish carries all four false.
 *
 * Run:
 *   PLAYWRIGHT_MODULE="/Users/cs/Downloads/home-reno-magic-7e323de4-main/node_modules/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-w6i2-switchboard-walkthrough.mjs
 */
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const APP_DIR=fileURLToPath(new URL('../../app/',import.meta.url));
const PORT=Number(process.env.W6I2_PORT||4179);
const ORIGIN=`http://127.0.0.1:${PORT}`;

let step='(boot)';
const say=name=>{step=name;process.stdout.write(`STEP ${name}\n`)};
const assertTrue=(condition,message)=>{
  if(!condition)throw new Error(`step ${step}: ${message}`);
  process.stdout.write(`  ok - ${message}\n`);
};
const same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);

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
   The scenario is read from window.__W6I2SCENARIO at CALL time. Because addInitScript re-runs on
   every navigation, a page.goto() rebuilds the whole fixture — that is how each part of the
   walkthrough starts from a clean spine after a publish has mutated it. */
const BIZ='b1111111-1111-4111-8111-111111111111';
const stubSource=`(()=>{
  const BIZ='${BIZ}';
  /* The scenario rides in the QUERY STRING, not in an init script: the fixture is built the moment
     this stub evaluates, and a second addInitScript would not have run yet. It also guarantees each
     openWizard() is a genuine document load rather than a same-URL no-op. */
  const scenario=()=>String(new URLSearchParams(location.search).get('w6i2')||'visits');
  window.__W6I2FAILPUBLISH=window.__W6I2FAILPUBLISH||false;
  const MODULES=['loyalty','retention','referrals','memberships','giftcards','clients','sales','services','till','bookings','reports','inventory','appointments','staffperf','packages'];
  const bizRow={id:BIZ,slug:'testco',name:'Test Co',currency:'SGD',industry:'facial',points_mode:'both',
    enabled_modules:MODULES,active_config_version_id:'pub-1',join_enabled:true,brand_color:'#7c5cff',
    booking_policy:null,quick_earn_catalogue_enabled:true,created_at:'2026-01-01T00:00:00Z'};
  /* The two scenarios, and what each one is FOR.
     'visits'      — a real, published points+tiers firm whose ladder has always climbed on VISITS,
                     with NO open draft. That is the exact population defect 1 was silently re-basing:
                     with tier_basis missing from growOverviewSnapshot's select the wizard read
                     undefined, decided the firm had never chosen, and pre-picked points-earned.
     'tiersPoints' — tiers running ALONE with a stored points_earned basis. The defect-5 shape: a
                     ladder that can never climb, because nothing writes points-programme earn rows. */
  const SPINE={
    visits:[{kind:'points',active:true},{kind:'tiers',active:true},
            {kind:'stamps',active:false},{kind:'referral',active:false}],
    tiersPoints:[{kind:'points',active:false},{kind:'tiers',active:true},
            {kind:'stamps',active:false},{kind:'referral',active:false}]
  };
  const PROGRAM={
    visits:{id:'prog-1',business_id:BIZ,active:true,loyalty_model:'points_tiers',
      current_config_version_id:'pub-1',earn_points_per_dollar:10,redeem_points:800,
      reward_credit_cents:800,stamp_target:null,stamp_per_cents:null,tier_basis:'visits',
      expiry_mode:'none',expiry_days:null,configuration_status:'published'},
    tiersPoints:{id:'prog-1',business_id:BIZ,active:true,loyalty_model:'points_tiers',
      current_config_version_id:'pub-1',earn_points_per_dollar:10,redeem_points:800,
      reward_credit_cents:800,stamp_target:null,stamp_per_cents:null,tier_basis:'points_earned',
      expiry_mode:'none',expiry_days:null,configuration_status:'published'}
  };
  const TIERS=[{id:'t-silver',business_id:BIZ,name:'Silver',threshold:0,points_multiplier:1,
      perk_note:null,sort:0,active:true,effective_from:null,expires_at:null},
    {id:'t-gold',business_id:BIZ,name:'Gold',threshold:10,points_multiplier:1,
      perk_note:null,sort:1,active:true,effective_from:null,expires_at:null}];
  const liveReward={id:'lr-live',business_id:BIZ,active:true,customer_name:'Free Moisturiser',
    name:'Free Moisturiser',cost_points:150,credit_cents:0,entitlement_expiry_days:null,
    usage_limit:null,min_tier_id:null,min_tier_threshold:null,estimated_cost_cents:150,sort:1,
    claim_available_from:null,claim_available_until:null,created_at:'2026-06-01T00:00:00Z'};
  /* referral_programs.enabled is deliberately TRUE while the referral spine row is OFF. That is the
     desync SA-4 exists to close, and it makes both directions of the referral double-write testable:
     a keep-it-paused publish (and a plain publish with the switch off) must call save_referral_program
     with p_enabled:false, because the engine's referral block reads this column and not the spine. */
  const state={
    spine:SPINE[scenario()]?SPINE[scenario()].map(r=>({...r})):SPINE.visits.map(r=>({...r})),
    program:{...(PROGRAM[scenario()]||PROGRAM.visits)},
    tiers:TIERS.map(t=>({...t})),
    draftTiers:TIERS.map(t=>({tier_id:t.id,id:t.id,name:t.name,threshold:t.threshold,
      points_multiplier:1,perk_note:null,sort:t.sort,active:true,effective_from:null,expires_at:null})),
    draftProgram:null,
    versions:[]
  };
  const TABLES={
    businesses:[bizRow],
    branches:[{id:'br1',business_id:BIZ,name:'Orchard',active:true,billing_state:'active'}],
    services:[{id:'sv1',business_id:BIZ,name:'Signature facial',active:true,price_cents:8800}],
    clients:[],sales:[],appointments:[],points_ledger:[],memberships:[],client_packages:[],waitlist:[],
    client_field_definitions:[],client_field_values:[],client_field_options:[],
    staff:[{id:'st1',business_id:BIZ,full_name:'Owner Person',role:'owner',user_id:'u-owner',
      active:true,email:'owner@test.co',phone:'',title:null,module_perms:null,modules:null,
      commission_service_bps:null,commission_product_bps:null,created_at:'2026-01-01T00:00:00Z'}],
    staff_invites:[],staff_hours:[],staff_branches:[],
    loyalty_rewards:[liveReward],
    loyalty_reward_branches:[],loyalty_reward_services:[],loyalty_reward_products:[],
    loyalty_branch_overrides:[],
    referral_programs:[{id:'rp1',business_id:BIZ,enabled:true,reward_cents:1000,
      min_spend_cents:0,created_at:'2026-03-01T00:00:00Z'}],
    membership_plans:[],retention_programs:[],
    /* EMPTY on purpose: "no open draft" is the standard state after every publish, and it is the
       state in which the wizard's published row is the only source of tier_basis. */
    firm_config_versions:[]
  };
  const dynamic={business_programmes:()=>state.spine,
    loyalty_programs:()=>[state.program],
    loyalty_tiers:()=>state.tiers};
  window.__W6I2={rpc:[],writes:[],state};
  const chainable=resolveOut=>{
    const q={single:false,head:false,countMode:null,op:'select'};
    const chain={};
    for(const m of ['eq','neq','is','in','not','gte','lte','lt','gt','or','ilike','contains','overlaps','order','limit','range'])
      chain[m]=()=>chain;
    chain.select=(cols,opts)=>{q.cols=cols;if(opts&&opts.count){q.countMode=opts.count;q.head=!!opts.head}return chain};
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
      window.__W6I2.writes.push({table,op:q.op,payload:q.payload??null});
      return {data:null,error:null};
    }
    /* The select LIST is recorded for every loyalty_programs read. Defect 1 was a missing column in
       exactly this list, so the walkthrough can assert on what production actually asked for. */
    if(table==='loyalty_programs')window.__W6I2.rpc.push({name:'select:loyalty_programs',args:{columns:String(q.cols||'')}});
    const rows=dynamic[table]?dynamic[table]():(TABLES[table]||[]);
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
      case 'get_dashboard_summary_v155':return {visits:0,revenue_cents:0,new_customers:0,points_issued:0,
        visits_by_weekday:[0,0,0,0,0,0,0],availability:{sales:true,clients:true,loyalty:true}};
      case 'owner_list_reward_profitability_products_v122':return {items:[]};
      case 'business_get_promotion_editor_v155':return {items:[],entitlement:null};
      case 'business_get_welcome_offer_v215':return {configured:false};
      case 'business_programme_usage_v271':return null;
      case 'business_get_loyalty_tiers_v143':return state.tiers.map(t=>({tier_id:t.id,id:t.id,name:t.name,
        threshold:t.threshold,points_multiplier:1,perk_note:'',effective_from:null,expires_at:null}));
      case 'get_active_birthday_program':return {programs:[]};
      case 'get_birthday_program_draft':return {programs:[]};
      case 'get_retention_config_draft':return {programs:[]};
      case 'get_program_rules_draft':return {version_no:2,rules:[]};
      case 'business_get_customer_capabilities_v89':return {redemption_enabled:false};
      case 'business_get_checkout_preferences_v102':return null;
      case 'require_module_scope_v145':return null;
      case 'create_loyalty_config_draft':
        state.draftProgram={...state.program};
        return {version_id:'draft-1',snapshot_hash:'hash-1'};
      case 'save_loyalty_config_draft':
        state.draftProgram={...(state.draftProgram||state.program),...(args?.p_config||{})};
        return {snapshot_hash:'hash-'+(window.__W6I2.writes.length+window.__W6I2.rpc.length)};
      case 'save_loyalty_tier_draft_v143':{
        const tier=args?.p_tier||{};
        const row=state.draftTiers.find(t=>t.id===tier.id);
        if(row)Object.assign(row,{name:tier.name,threshold:tier.threshold,active:tier.active!==false});
        else state.draftTiers.push({tier_id:tier.id,id:tier.id,name:tier.name,threshold:tier.threshold,
          points_multiplier:tier.points_multiplier||1,perk_note:tier.perk_note??null,sort:tier.sort||0,
          active:tier.active!==false,effective_from:null,expires_at:null});
        return {snapshot_hash:'hash-t'+state.draftTiers.length};
      }
      case 'get_loyalty_reward_draft':return {program:state.draftProgram||state.program,
        rewards:[{reward_id:'lr-live',name:'Free Moisturiser',customer_name:'Free Moisturiser',
          description:'',cost_points:150,credit_cents:0,estimated_cost_cents:150,
          entitlement_expiry_days:null,usage_limit:null,min_tier_id:null,min_tier_threshold:null,
          claim_available_from:null,claim_available_until:null,fulfillment_kind:'manual_item',
          sort:1,created_at:'2026-06-01T00:00:00Z',active:true,eligibility:{branches:[],services:[]}}],
        tiers:state.draftTiers,snapshot_hash:'hash-1'};
      case 'preview_publish_impact':return {rules:[],requires_confirmation:false};
      case 'publish_loyalty_config':return {published:true};
      case 'save_referral_program':return {ok:true};
      case 'set_programmes_v314':{
        const set=args?.p_switches||{};
        Object.keys(set).forEach(kind=>{
          const row=state.spine.find(r=>r.kind===kind);
          if(row)row.active=set[kind]===true;else state.spine.push({kind,active:set[kind]===true});
        });
        return {programmes:state.spine.map(r=>({kind:r.kind,active:r.active===true}))};
      }
      default:return null;
    }
  };
  const rpc=(name,args)=>{
    window.__W6I2.rpc.push({name,args:args??null});
    if(name==='publish_loyalty_config'&&window.__W6I2FAILPUBLISH===true)
      return chainable(()=>({data:null,error:{code:'XX000',message:'transient publish failure'}}));
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

  const PANEL='#growSetupWizardPanelV301';
  let visitNonce=0;
  const openWizard=async scenario=>{
    await page.goto(`${ORIGIN}/index.html?w6i2=${scenario}&n=${++visitNonce}#/grow/setup`,{waitUntil:'domcontentloaded'});
    await page.waitForSelector(PANEL,{timeout:30000});
    await page.waitForSelector('[data-grow-setup-switch-w6i2]',{timeout:30000});
  };
  /* Every reader below reads RENDERED state. Nothing here consults app source or wizard closure
     variables — that is the entire point of this file. */
  const switchState=()=>page.evaluate(()=>Object.fromEntries(
    [...document.querySelectorAll('[data-grow-setup-switch-w6i2]')].map(button=>[
      button.dataset.growSetupSwitchW6i2||button.getAttribute('data-grow-setup-switch-w6i2'),
      `${button.getAttribute('aria-checked')}/${button.querySelector('[data-grow-setup-switch-state-w6i2]')?.textContent.trim()}`])));
  const railLabels=()=>page.evaluate(()=>[...document.querySelectorAll('.grow-setup-steps-v301 .grow-setup-step-label-v301')]
    .map(node=>node.textContent.trim()));
  const stepNumber=()=>page.evaluate(sel=>Number(document.querySelector(sel)?.dataset.growSetupStepV301||0),PANEL);
  const stepTitle=()=>page.evaluate(()=>document.querySelector('.grow-setup-title-v301')?.textContent.trim()||'');
  const percentNodes=()=>page.evaluate(()=>[...document.querySelectorAll('[data-grow-setup-percent-w6i2]')]
    .map(node=>({attr:node.getAttribute('data-grow-setup-percent-w6i2'),text:node.textContent.trim()})));
  const errText=()=>page.evaluate(sel=>document.querySelector(`${sel} .err`)?.textContent.trim()||'',PANEL);
  const rpcNames=()=>page.evaluate(()=>window.__W6I2.rpc.map(entry=>entry.name));
  const rpcCalls=name=>page.evaluate(n=>window.__W6I2.rpc.filter(entry=>entry.name===n),name);
  const clearRpc=()=>page.evaluate(()=>{window.__W6I2.rpc.length=0});
  const nextEnabled=()=>page.evaluate(()=>{
    const button=document.getElementById('growSetupNextV301');
    return button?{label:button.textContent.trim(),disabled:button.disabled}:null;
  });
  const clickSwitch=async kind=>{
    await page.click(`[data-grow-setup-switch-w6i2="${kind}"]`);
    await page.waitForTimeout(80);
  };
  /* Next is asynchronous (it saves the draft). Wait for the step attribute to actually move rather
     than sleeping — a step that refuses to advance is a finding, not a flake. */
  const pressNext=async({expectStep=null}={})=>{
    const before=await stepNumber();
    await page.click('#growSetupNextV301');
    if(expectStep===null){await page.waitForTimeout(400);return}
    await page.waitForFunction(([sel,target])=>Number(document.querySelector(sel)?.dataset.growSetupStepV301||0)===target,
      [PANEL,expectStep===undefined?before+1:expectStep],{timeout:20000});
  };
  const gotoStep=async number=>{
    await page.click(`[data-grow-setup-goto-v301="${number}"]`);
    await page.waitForFunction(([sel,target])=>Number(document.querySelector(sel)?.dataset.growSetupStepV301||0)===target,
      [PANEL,number],{timeout:20000});
  };

  const runSuite=async width=>{
    const tag=`[${width}px]`;
    await page.setViewportSize({width,height:width<768?900:1000});

    /* ============ (b) the four toggles actually flip, and only the pressed one ============ */
    say(`${tag} b. each switch flips, and flipping one leaves the other three exactly as they were`);
    await openWizard('visits');
    const seeded=await switchState();
    assertTrue(same(seeded,{points:'true/ON',tiers:'true/ON',stamps:'false/OFF',referral:'false/OFF'}),
      `${tag} screen 0 opens from the SPINE: ${JSON.stringify(seeded)}`);
    for(const kind of ['points','tiers','stamps','referral']){
      const before=await switchState();
      await clickSwitch(kind);
      const after=await switchState();
      const flipped=before[kind]!==after[kind];
      const others=['points','tiers','stamps','referral'].filter(k=>k!==kind);
      const untouched=others.every(k=>before[k]===after[k]);
      assertTrue(flipped,`${tag} pressing "${kind}" flipped it (${before[kind]} -> ${after[kind]})`);
      assertTrue(untouched,`${tag} pressing "${kind}" left the other three exactly as they were (${JSON.stringify(others.map(k=>`${k}:${after[k]}`))})`);
    }
    const afterFour=await switchState();
    assertTrue(same(afterFour,{points:'false/OFF',tiers:'false/OFF',stamps:'true/ON',referral:'true/ON'}),
      `${tag} four presses produced exactly the four flips, no more: ${JSON.stringify(afterFour)}`);
    await clickSwitch('stamps');await clickSwitch('referral');
    const allOff=await switchState();
    assertTrue(same(allOff,{points:'false/OFF',tiers:'false/OFF',stamps:'false/OFF',referral:'false/OFF'}),
      `${tag} every switch is now OFF on screen (${JSON.stringify(allOff)})`);
    assertTrue((await page.locator(`${PANEL} .grow-setup-integrity-v305`).innerText()).includes('Turn on at least one programme to publish'),
      `${tag} screen 0 says so in words while nothing is on`);

    /* ============ (a) zero on -> rail is screen 0 + Go live, publish refused IN WORDS ============ */
    say(`${tag} a. zero switches on -> two-step rail, and Publish is refused in words`);
    const zeroRail=await railLabels();
    assertTrue(same(zeroRail,['Programmes','Go live']),
      `${tag} the rail is exactly Programmes + Go live (${JSON.stringify(zeroRail)})`);
    await clearRpc();
    await pressNext({expectStep:2});
    assertTrue((await stepTitle()).startsWith('Step 2 of 2'),`${tag} Go live is step 2 of 2 (${await stepTitle()})`);
    const refusal=await page.locator('[data-grow-setup-nopublish-w6i2]').innerText();
    assertTrue(refusal.includes('Nothing is turned on, so there is nothing to publish'),
      `${tag} the refusal is on screen in the owner's words: "${refusal.trim()}"`);
    const publishButton=await nextEnabled();
    assertTrue(publishButton?.label==='Publish now'&&publishButton.disabled===true,
      `${tag} the button reads "Publish now" and is disabled as well as explained`);
    const zeroCalls=await rpcNames();
    assertTrue(!zeroCalls.includes('publish_loyalty_config')&&!zeroCalls.includes('set_programmes_v314'),
      `${tag} nothing was published and no spine write left the browser (${JSON.stringify(zeroCalls)})`);

    /* ============ (c) all four on -> customer-facing rail order, one running percentage ============ */
    say(`${tag} c. all four on -> the rail composes in customer-facing order with one running percentage`);
    await gotoStep(1);
    for(const kind of ['points','tiers','stamps','referral'])await clickSwitch(kind);
    const fullRail=await railLabels();
    assertTrue(same(fullRail,['Programmes','Stamps','Stamp gift','Earning','Gifts','Expiry','Climbing','Tiers','Referral','Go live']),
      `${tag} rail = stamps -> points -> tiers -> referral, ten screens: ${JSON.stringify(fullRail)}`);
    const percentAtZero=await percentNodes();
    assertTrue(percentAtZero.length===1&&percentAtZero[0].attr==='0'&&percentAtZero[0].text==='0% done',
      `${tag} exactly ONE running percentage, reading 0% on screen 0 (${JSON.stringify(percentAtZero)})`);
    await pressNext({expectStep:2});
    const percentAtOne=await percentNodes();
    assertTrue(percentAtOne.length===1&&Number(percentAtOne[0].attr)===11,
      `${tag} one percentage still, advanced to ${percentAtOne[0]?.text} on the second screen`);

    /* ============ (e) the three one-tap expiry chips actually set the mode ============ */
    say(`${tag} e. the three one-tap expiry chips actually set the mode`);
    await pressNext({expectStep:3});   /* Stamps -> Stamp gift */
    await pressNext({expectStep:4});   /* Stamp gift -> Earning */
    await pressNext({expectStep:5});   /* Earning -> Gifts */
    await pressNext({expectStep:6});   /* Gifts -> Expiry */
    assertTrue((await stepTitle()).includes('Expiry'),`${tag} standing on the Expiry screen (${await stepTitle()})`);
    const expiryRead=()=>page.evaluate(()=>({
      mode:document.getElementById('growSetupExpiryModeW6I2')?.value||null,
      days:document.getElementById('growSetupExpiryDaysW6I2')?.value||null,
      daysDisabled:document.getElementById('growSetupExpiryDaysW6I2')?.disabled??null,
      fieldHidden:document.getElementById('growSetupExpiryDaysFieldW6I2')?.hidden??null}));
    const expiryStart=await expiryRead();
    assertTrue(expiryStart.mode==='none',`${tag} the screen opens on "Never expire" (${expiryStart.mode})`);
    await page.click('[data-grow-setup-expiry-w6i2="year"]');
    await page.waitForFunction(()=>document.getElementById('growSetupExpiryModeW6I2')?.value==='fixed',null,{timeout:10000});
    const yearly=await expiryRead();
    assertTrue(yearly.mode==='fixed'&&yearly.days==='365'&&yearly.daysDisabled===false&&yearly.fieldHidden===false,
      `${tag} "One year" chip set fixed + 365 and revealed the days field (${JSON.stringify(yearly)})`);
    await page.click('[data-grow-setup-expiry-w6i2="inactive-year"]');
    await page.waitForFunction(()=>document.getElementById('growSetupExpiryModeW6I2')?.value==='inactivity',null,{timeout:10000});
    const quiet=await expiryRead();
    assertTrue(quiet.mode==='inactivity'&&quiet.days==='365',
      `${tag} "After 365 quiet days" chip set inactivity + 365 (${JSON.stringify(quiet)})`);
    await page.click('[data-grow-setup-expiry-w6i2="none"]');
    await page.waitForFunction(()=>document.getElementById('growSetupExpiryModeW6I2')?.value==='none',null,{timeout:10000});
    const never=await expiryRead();
    assertTrue(never.mode==='none'&&never.daysDisabled===true&&never.fieldHidden===true,
      `${tag} "Never" chip set none and hid/disabled the days field (${JSON.stringify(never)})`);

    /* ============ (d) points-earned basis with Points & gifts OFF ============ */
    say(`${tag} d. a points-earned ladder with Points & gifts OFF is refused, and one tap fixes it`);
    await openWizard('tiersPoints');
    const tiersOnlySwitches=await switchState();
    assertTrue(same(tiersOnlySwitches,{points:'false/OFF',tiers:'true/ON',stamps:'false/OFF',referral:'false/OFF'}),
      `${tag} tiers alone is running (${JSON.stringify(tiersOnlySwitches)})`);
    const tiersOnlyRail=await railLabels();
    assertTrue(same(tiersOnlyRail,['Programmes','Climbing','Tiers','Go live']),
      `${tag} rail = ${JSON.stringify(tiersOnlyRail)}`);
    await pressNext({expectStep:2});
    const basisState=()=>page.evaluate(()=>Object.fromEntries(
      [...document.querySelectorAll('[data-grow-setup-basis-v305]')]
        .map(node=>[node.getAttribute('data-grow-setup-basis-v305'),node.getAttribute('aria-checked')])));
    const storedPointsBasis=await basisState();
    assertTrue(storedPointsBasis.points==='true'&&storedPointsBasis.visits==='false',
      `${tag} the STORED points_earned basis opens on Points earned (${JSON.stringify(storedPointsBasis)})`);
    assertTrue(await page.locator('[data-grow-setup-climbneedspoints-w6i2]').count()===1,
      `${tag} the Climbing screen shows the "Turn on Points & gifts to use this ladder" requirement`);
    assertTrue((await page.locator('[data-grow-setup-basisneeds-w6i2]').innerText()).includes('Needs Points'),
      `${tag} the Points earned option itself carries "Needs Points & gifts running"`);
    await pressNext();
    assertTrue(await stepNumber()===2,`${tag} Next refused: the owner is still on Climbing`);
    const climbRefusal=await errText();
    assertTrue(climbRefusal.includes('Points & gifts has to be running or nobody can ever climb'),
      `${tag} Next refused in words: "${climbRefusal.replace(/\s+Retry$/,'')}"`);
    await page.click('#growSetupTurnOnPointsW6I2');
    await page.waitForFunction(()=>document.querySelector('[data-grow-setup-climbneedspoints-w6i2]')===null,null,{timeout:10000});
    const railAfterTap=await railLabels();
    assertTrue((await stepTitle()).includes('Climbing'),
      `${tag} one tap kept the owner on the Climbing screen, renumbered (${await stepTitle()})`);
    assertTrue(same(railAfterTap,['Programmes','Earning','Gifts','Expiry','Climbing','Tiers','Go live']),
      `${tag} and the points rail appeared in front of Climbing (${JSON.stringify(railAfterTap)})`);
    assertTrue(await page.locator('[data-grow-setup-basisneeds-w6i2]').count()===0,
      `${tag} the "Needs Points & gifts running" requirement is gone from the Points earned option`);
    /* Now prove the PUBLISH gate refuses the same shape. Reach Go live on Visits, then come back and
       re-pick Points earned with the points programme switched off again. */
    say(`${tag} d2. the Go-live gate refuses the same stalled ladder in words`);
    await gotoStep(1);
    const afterOneTap=await switchState();
    assertTrue(afterOneTap.points==='true/ON',
      `${tag} screen 0 confirms the one tap really flipped the Points & gifts switch (${afterOneTap.points})`);
    await clickSwitch('points');
    await pressNext({expectStep:2});
    await page.click('[data-grow-setup-basis-v305="visits"]');
    await page.waitForTimeout(120);
    await pressNext({expectStep:3});
    await pressNext({expectStep:4});
    assertTrue((await stepTitle()).includes('Go live'),`${tag} reached Go live on a visits ladder (${await stepTitle()})`);
    await gotoStep(2);
    await page.click('[data-grow-setup-basis-v305="points"]');
    await page.waitForFunction(()=>document.querySelector('[data-grow-setup-climbneedspoints-w6i2]')!==null,null,{timeout:10000});
    await gotoStep(4);
    const stalledSentence=await page.locator('[data-grow-setup-ladderstalled-w6i2]').innerText();
    assertTrue(stalledSentence.includes('Turn it on, or choose Visits'),
      `${tag} the publish gate names the refusal: "${stalledSentence.trim()}"`);
    const stalledButton=await nextEnabled();
    assertTrue(stalledButton?.disabled===true,`${tag} Publish is refused while the ladder can never climb`);

    /* ============ (f) stored VISITS ladder, D3 movement block, and the flow-level re-check ======= */
    say(`${tag} f. a stored VISITS ladder opens on Visits, and a raised threshold gates the publish`);
    await openWizard('visits');
    const selectLists=await rpcCalls('select:loyalty_programs');
    assertTrue(selectLists.length>0&&selectLists.every(entry=>entry.args.columns.includes('tier_basis')),
      `${tag} every production loyalty_programs read asked for tier_basis (${selectLists.length} reads)`);
    await pressNext({expectStep:2});   /* Programmes -> Earning */
    await pressNext({expectStep:3});   /* Earning -> Gifts */
    await pressNext({expectStep:4});   /* Gifts -> Expiry */
    await pressNext({expectStep:5});   /* Expiry -> Climbing */
    assertTrue((await stepTitle()).includes('Climbing'),`${tag} standing on Climbing (${await stepTitle()})`);
    const storedVisits=await basisState();
    assertTrue(storedVisits.visits==='true'&&storedVisits.points==='false',
      `${tag} the stored VISITS ladder opens on Visits, not on the suggestion (${JSON.stringify(storedVisits)})`);
    const climbCopy=await page.locator('.grow-setup-basis-v305').innerText();
    assertTrue(!climbCopy.includes('Suggested'),
      `${tag} nothing is labelled "Suggested" for a firm that already made this choice`);
    await pressNext({expectStep:6});   /* Climbing -> Tiers */
    assertTrue((await page.locator('[data-grow-setup-basisrow-v305]').innerText()).includes('Visits'),
      `${tag} the Tiers screen states the basis as Visits`);
    await page.click('[data-grow-setup-tier-edit-v303="t-gold"]');
    await page.waitForFunction(()=>document.getElementById('growSetupTierThresholdV303')?.value==='10',null,{timeout:10000});
    await page.fill('#growSetupTierThresholdV303','50');
    await page.click('#growSetupTierSaveV304');
    await page.waitForFunction(()=>{
      const row=document.querySelector('[data-grow-setup-tierrow-v304="t-gold"] [data-grow-setup-tierthreshold-v304]');
      return row&&row.textContent.includes('50');
    },null,{timeout:20000});
    assertTrue(true,`${tag} Gold's threshold was raised 10 -> 50 and the row re-rendered with it`);
    await pressNext({expectStep:7});   /* Tiers -> Go live */
    await page.waitForSelector('[data-grow-setup-tiermove-w6i2]',{timeout:20000});
    /* The go-live change list reads its own LIVE row. That second select omitted tier_basis too, and
       printed "Tier level is earned by: not set -> Points earned" for a firm that has always been on
       visits. Assert every loyalty_programs read this page made, not just the first. */
    await page.waitForFunction(()=>window.__W6I2.rpc.filter(e=>e.name==='select:loyalty_programs').length>=2,
      null,{timeout:20000});
    const allSelects=await rpcCalls('select:loyalty_programs');
    assertTrue(allSelects.every(entry=>entry.args.columns.includes('tier_basis')),
      `${tag} all ${allSelects.length} loyalty_programs reads (snapshot AND go-live comparison) carry tier_basis`);
    assertTrue(!(await page.locator('#growSetupChangesV301').innerText()).includes('not set'),
      `${tag} the go-live change list invents no "not set" before-value`);
    const moveBlock=await page.locator('[data-grow-setup-tiermove-w6i2]').innerText();
    assertTrue(moveBlock.includes('Members are re-sorted the moment you publish')&&moveBlock.includes('Gold')
      &&moveBlock.includes('10')&&moveBlock.includes('50'),
      `${tag} the D3 movement block names the change: ${JSON.stringify(moveBlock.replace(/\s+/g,' ').trim())}`);
    const countLine=await page.locator('[data-grow-setup-tiermove-count-w6i2]').innerText();
    assertTrue(countLine.includes('not counted yet')&&!/\b0 members\b/.test(countLine),
      `${tag} the count line is honest, never an invented zero: "${countLine.trim()}"`);
    assertTrue(await page.locator('#growSetupTierAckW6I2').isChecked()===false
      &&(await nextEnabled())?.disabled===true,
      `${tag} Publish is refused until the D3 tick is in`);
    await page.check('#growSetupTierAckW6I2');
    await page.waitForFunction(()=>document.getElementById('growSetupNextV301')?.disabled===false,null,{timeout:10000});
    assertTrue(true,`${tag} ticking the D3 box enables Publish`);

    say(`${tag} f2. the D3 tick is re-checked INSIDE the publish flow, not only as a disabled attribute`);
    await page.evaluate(()=>{window.__W6I2FAILPUBLISH=true});
    await clearRpc();
    await page.click('#growSetupNextV301');
    await page.waitForFunction(sel=>document.querySelector(`${sel} .err`)!==null,PANEL,{timeout:20000});
    assertTrue((await errText()).includes('Nothing was published'),
      `${tag} the transient publish failure is reported: "${(await errText()).replace(/\s+Retry$/,'')}"`);
    await page.evaluate(()=>{window.__W6I2FAILPUBLISH=false});
    await page.uncheck('#growSetupTierAckW6I2');
    await clearRpc();
    await page.click('#growSetupRetryV301');
    await page.waitForFunction(sel=>{
      const err=document.querySelector(`${sel} .err`);
      return err&&err.textContent.includes('Tick the box above');
    },PANEL,{timeout:20000});
    const retryRefusal=await errText();
    assertTrue(retryRefusal.includes('Tick the box above to confirm members can move down a tier before publishing'),
      `${tag} Retry was refused by the flow-level gate: "${retryRefusal.replace(/\s+Retry$/,'')}"`);
    const retryCalls=await rpcNames();
    assertTrue(!retryCalls.includes('publish_loyalty_config')&&!retryCalls.includes('set_programmes_v314'),
      `${tag} the un-ticked Retry published nothing and wrote no spine (${JSON.stringify(retryCalls)})`);

    /* ============ (g) exactly one spine write per publish, all four keys ============ */
    say(`${tag} g. one set_programmes_v314 per publish, carrying all four keys`);
    await page.check('#growSetupTierAckW6I2');
    await clearRpc();
    await page.click('#growSetupNextV301');
    await page.waitForSelector('.grow-setup-done-v301',{timeout:30000});
    assertTrue((await page.locator('.grow-setup-done-v301').innerText()).includes('Published'),
      `${tag} the publish landed and the wizard says so`);
    const spineWrites=await rpcCalls('set_programmes_v314');
    assertTrue(spineWrites.length===1,`${tag} exactly ONE set_programmes_v314 call left the browser (${spineWrites.length})`);
    const sentSet=spineWrites[0]?.args?.p_switches||{};
    assertTrue(same(Object.keys(sentSet).sort(),['points','referral','stamps','tiers']),
      `${tag} it carried all four keys (${JSON.stringify(sentSet)})`);
    assertTrue(sentSet.points===true&&sentSet.tiers===true&&sentSet.stamps===false&&sentSet.referral===false,
      `${tag} the set matches the switchboard exactly (${JSON.stringify(sentSet)})`);
    const referralWrites=await rpcCalls('save_referral_program');
    assertTrue(referralWrites.length===1&&referralWrites[0].args.p_enabled===false,
      `${tag} referral_programs.enabled was driven to false to match the OFF switch (${JSON.stringify(referralWrites.map(entry=>entry.args.p_enabled))})`);
    const publishOrder=await rpcNames();
    assertTrue(publishOrder.indexOf('publish_loyalty_config')<publishOrder.indexOf('set_programmes_v314'),
      `${tag} the spine write happened AFTER publish (${JSON.stringify(publishOrder.filter(n=>!n.startsWith('select:')))})`);

    say(`${tag} g2. a keep-it-paused publish carries all four switches false`);
    await openWizard('visits');
    await pressNext({expectStep:2});
    await pressNext({expectStep:3});
    await pressNext({expectStep:4});
    await pressNext({expectStep:5});
    await pressNext({expectStep:6});
    await pressNext({expectStep:7});
    assertTrue((await stepTitle()).includes('Go live'),`${tag} at Go live with nothing edited (${await stepTitle()})`);
    await page.check('#growSetupPauseV301');
    await page.waitForFunction(()=>{
      const items=[...document.querySelectorAll('[data-grow-setup-switchsummary-kind-w6i2]')];
      return items.length===4&&items.every(node=>/—\s*off$/.test(node.textContent.trim()));
    },null,{timeout:10000});
    assertTrue(true,`${tag} the Go-live summary shows all four programmes as off under "Keep it paused"`);
    await clearRpc();
    await page.click('#growSetupNextV301');
    await page.waitForSelector('.grow-setup-done-v301',{timeout:30000});
    const pausedWrites=await rpcCalls('set_programmes_v314');
    assertTrue(pausedWrites.length===1,`${tag} exactly ONE spine write for the paused publish (${pausedWrites.length})`);
    const pausedSet=pausedWrites[0]?.args?.p_switches||{};
    assertTrue(same(Object.keys(pausedSet).sort(),['points','referral','stamps','tiers'])
      &&Object.values(pausedSet).every(value=>value===false),
      `${tag} a keep-it-paused publish carried all four keys FALSE (${JSON.stringify(pausedSet)})`);
    const pausedReferral=await rpcCalls('save_referral_program');
    assertTrue(pausedReferral.length===1&&pausedReferral[0].args.p_enabled===false,
      `${tag} the paused publish also disabled referral_programs (${JSON.stringify(pausedReferral.map(entry=>entry.args.p_enabled))})`);
  };

  await runSuite(1440);
  await runSuite(390);

  if(pageErrors.length)process.stdout.write(`note: page errors observed (non-fatal): ${JSON.stringify(pageErrors)}\n`);
  process.stdout.write('W6I2 switchboard walkthrough PASS (a-g at 1440 and 390)\n');
}catch(error){
  process.stdout.write(`W6I2 walkthrough FAIL at ${step}\n${error?.stack||error}\n`);
  if(pageErrors.length)process.stdout.write(`page errors: ${JSON.stringify(pageErrors)}\n`);
  process.exitCode=1;
}finally{
  await browser.close().catch(()=>{});
  if(server)server.kill();
}
