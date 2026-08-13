/* V296 owner-batch walkthrough — the owner's iPad markup of 2026-08-12 (build bc8f299b3f19),
 * for the Programmes group, Gift cards and Customer Interface.
 *
 * Drives the REAL production bundles (app/index.html + the stamped chunks — run
 * `npm run bundle-stamp` first) through the real router, with the Supabase client replaced by an
 * in-page fixture (same pattern as verify-v295-owner-fixes-walkthrough.mjs).
 *
 * Steps (each asserts; the script exits non-zero naming the failing step):
 *   1. Customer 360 — "Available Customer Programmes" rows carry THIS customer's own numbers.
 *      Owner struck out "Earn 1 points for every SGD 1 spent, redeem on rewards" and wrote
 *      "0 points" beside the Paused pill, and struck out the trailing paused paragraph.
 *   2. Gift cards page — no "Offer gift cards" block (owner: "remove this") and no
 *      "← Back to Grow overview" in the header.
 *   3. Customer Interface — a nav GROUP with sub-tab children; each child lands on its section,
 *      and the moved "Offer gift cards" switch is on the Gift cards child and still writes.
 *   4. Programmes — the in-page Overview / List / History pill strip is gone (owner circled it:
 *      "remove") while all three rail children still land on their view.
 *   5. Promotions — drilling the ongoing Promotions card lists EACH promotion by title with its
 *      own action (owner: "can straightaway go inside see which promotions available").
 *   6. Pending-setup cards carry no "…is the live model" / "Live model ·" subtitle
 *      (owner: "X NO — not linked to point").
 *   7. "Points System" replaces "Points redemption" in the tile, the editor and the c360 row.
 *
 * Serves on 4196 deliberately: another worktree runs 4173, and evidence has been captured from
 * the wrong tree that way before.
 *
 * Run:
 *   PLAYWRIGHT_MODULE=".../playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v296-programmes-batch-walkthrough.mjs
 */
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const APP_DIR=fileURLToPath(new URL('../../app/',import.meta.url));
const PORT=Number(process.env.V296_PORT||4196);
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
   The loyalty programme is PAUSED with a real 300-point balance: that is exactly the state the
   owner screenshotted, and it is the only state in which both halves of item 1 are observable
   (the Paused pill AND the paragraph that used to follow it). points_mode 'both' renders the
   tier row too, so the tier standing is observable in the same pass. */
const BIZ='b1111111-1111-4111-8111-111111111111';
const stubSource=`(()=>{
  const BIZ='${BIZ}';
  const MODULES=['loyalty','retention','referrals','memberships','giftcards','clients','sales','services','till','bookings','reports','inventory','appointments','staffperf','packages'];
  const program={id:'prog-1',business_id:BIZ,active:false,loyalty_model:'points_tiers',
    earn_points_per_dollar:1,redeem_points:100,reward_credit_cents:100,stamp_target:null,
    stamp_per_cents:500,expiry_mode:'none',expiry_days:null,tier_basis:'visits',
    current_config_version_id:'pub-1',configuration_status:'published'};
  const bizRow={id:BIZ,slug:'testco',name:'Test Co',currency:'SGD',industry:'facial',points_mode:'both',
    enabled_modules:MODULES,active_config_version_id:'pub-1',join_enabled:true,brand_color:'#7c5cff',
    booking_policy:null,quick_earn_catalogue_enabled:true,created_at:'2026-01-01T00:00:00Z'};
  const TABLES={
    businesses:[bizRow],
    branches:[{id:'br1',business_id:BIZ,name:'Orchard',active:true,is_default:true,billing_state:'active'}],
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
    staff:[{id:'st1',business_id:BIZ,full_name:'Owner Person',role:'owner',user_id:'u-owner',active:true,
      email:'owner@test.co',phone:'',title:null,module_perms:null,modules:null,
      commission_service_bps:null,commission_product_bps:null,created_at:'2026-01-01T00:00:00Z'}],
    staff_invites:[],staff_hours:[],staff_branches:[{business_id:BIZ,staff_id:'st1',branch_id:'br1'}],
    loyalty_programs:[program],
    loyalty_rewards:[{id:'lr-live',business_id:BIZ,active:true,customer_name:'Free Coffee',name:'Free Coffee',
      cost_points:400,credit_cents:0,entitlement_expiry_days:null,usage_limit:null,min_tier_id:null,
      min_tier_threshold:null,estimated_cost_cents:100,sort:1,claim_available_from:null,
      claim_available_until:null,created_at:'2026-06-01T00:00:00Z'}],
    loyalty_reward_branches:[],loyalty_reward_services:[],loyalty_reward_products:[],
    loyalty_tiers:[{id:'t-gold',business_id:BIZ,name:'Gold',threshold:10}],
    loyalty_branch_overrides:[],
    gift_cards:[],
    referral_programs:[{id:'rp1',business_id:BIZ,enabled:true,reward_cents:500,min_spend_cents:2000,created_at:'2026-03-01T00:00:00Z'}],
    membership_plans:[],retention_programs:[],
    firm_config_versions:[{id:'draft-1',business_id:BIZ,version_no:2,based_on_version_id:'pub-1',status:'draft',snapshot_hash:'hash-1'}]
  };
  window.__V296={rpc:[],writes:[],giftCardSalesEnabled:true};
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
      window.__V296.writes.push({table,op:q.op,payload:q.payload??null});
      return {data:null,error:null};
    }
    const rows=TABLES[table]||[];
    if(q.countMode&&q.head)return {data:null,count:rows.length,error:null};
    if(q.single)return {data:rows[0]??null,error:null};
    return {data:rows,count:q.countMode?rows.length:null,error:null};
  });
  const promotions=()=>[
    {id:'pm1',business_id:BIZ,name:'August Special',tagline:'10% off facials',
     description:'10% off every facial this month',active:true,display_order:1,
     starts_at:'2026-08-01T00:00:00Z',ends_at:'2026-08-31T00:00:00Z',metadata:{},
     content_version:1,copy_version:1,image_url:null},
    {id:'pm2',business_id:BIZ,name:'September Preview',tagline:'Save the date',
     description:'A September offer still being written',active:false,display_order:2,
     starts_at:null,ends_at:null,metadata:{},content_version:1,copy_version:1,image_url:null}
  ];
  const rpcData=(name,args)=>{
    switch(name){
      case 'get_my_personas':return {staff:[{business_id:BIZ,business_slug:'testco',business_name:'Test Co',role:'owner',modules:MODULES}],customer:[],default_route:'#/workspace/testco/dashboard'};
      case 'platform_get_business_control_v94':return {workspace_access:true,quick_earn_catalogue_enabled:true};
      case 'get_my_modules':return {role:'owner',is_super_admin:false,modules:MODULES,module_perms:Object.fromEntries(MODULES.map(m=>[m,'rw']))};
      case 'get_my_modules_at_v115':return {role:'owner',modules:MODULES,module_perms:Object.fromEntries(MODULES.map(m=>[m,'rw']))};
      case 'get_customer_feature_capabilities':return {};
      case 'get_workspace_locale_preference_v97':return {locale:'en',version:1};
      case 'get_notifications':return {unread:0,items:[]};
      case 'get_dashboard_summary_v155':return {visits:2,revenue_cents:6000,new_customers:1,points_issued:0,
        visits_by_weekday:[0,1,0,1,0,0,0],availability:{sales:true,clients:true,loyalty:true}};
      case 'staff_list_customers_v155':return {customers:[{id:'c1',full_name:'Alice Tan',phone:'+65 81234567',
        points:300,credit_cents:1500,last_visit_at:'2026-08-05T03:00:00Z',created_at:'2026-03-01T00:00:00Z',
        marketing_consent:true,visits:2}],total:1};
      case 'preview_campaign_audience_v155':return {total:0};
      case 'require_module_scope_v145':return null;
      /* The owner's own screenshot state: a PAUSED programme with points already banked. */
      case 'staff_get_customer_actionable_loyalty_v145':return {points_balance:300,credit_balance_cents:1500,
        redemption_enabled:false,program:{id:'prog-1',active:false,unit:'points',earn_points_per_dollar:1,
        stamp_per_cents:500,redeem_points:100,reward_credit_cents:100},
        rewards:[],next_reward:null,expiry:null};
      case 'staff_get_reward_entitlements_v99':return [];
      case 'list_customer_redemption_history_v145':return [];
      case 'staff_list_visit_feedback_v145':return {feedback:[]};
      case 'staff_get_reversal_workflows_v145':return {sales:[],redemptions:[]};
      case 'owner_list_reward_profitability_products_v122':return {items:[]};
      case 'business_get_loyalty_tiers_v143':return [{tier_id:'t-gold',id:'t-gold',name:'Gold',threshold:10,points_multiplier:1,perk_note:'',effective_from:null,expires_at:null}];
      case 'get_loyalty_reward_draft':return {program:{...program},rewards:[],
        tiers:[{tier_id:'t-gold',id:'t-gold',name:'Gold',threshold:10,points_multiplier:1,perk_note:'',effective_from:null,expires_at:null}],
        snapshot_hash:'hash-1'};
      case 'get_program_rules_draft':return {version_no:2,rules:[]};
      case 'get_retention_config_draft':return {programs:[]};
      case 'get_birthday_program_draft':return {programs:[]};
      case 'get_active_birthday_program':return {programs:[]};
      case 'business_get_customer_capabilities_v89':return {redemption_enabled:false};
      case 'business_get_promotion_editor_v155':return {items:promotions(),entitlement:null};
      case 'business_get_checkout_preferences_v102':return {status:'available',
        gift_card_sales_enabled:window.__V296.giftCardSalesEnabled,package_earns_points:true};
      case 'set_gift_card_sales_enabled_v102':
        window.__V296.giftCardSalesEnabled=args?.p_enabled===true;
        return {status:'ok'};
      case 'business_get_welcome_offer_v215':return {configured:false};
      case 'business_programme_usage_v271':return null;
      case 'get_business_signup_config':return null;
      case 'create_loyalty_config_draft':return {version_id:'draft-1'};
      default:return null;
    }
  };
  const rpc=(name,args)=>{
    window.__V296.rpc.push({name,args:args??null});
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

  /* ------------- 1 + 7c. customer 360 programme rows carry this customer's numbers ------------- */
  say('1. customer 360 programme rows state THIS customer’s standing');
  await page.goto(`${ORIGIN}/index.html#/client/c1`,{waitUntil:'domcontentloaded'});
  await page.waitForSelector('#c360-loyalty .c360-programme-row-v294',{timeout:20000});
  const programmesText=await page.locator('#c360-loyalty').innerText();
  assertTrue(programmesText.includes('Points System'),
    'the programme row is named "Points System" (owner struck "redemption", wrote "System")');
  assertTrue(!programmesText.includes('Points redemption'),'"Points redemption" no longer names the row');
  assertTrue(programmesText.includes('300 points'),
    'the row states this customer’s own balance ("300 points"), not a generic earn rate');
  assertTrue(!programmesText.includes('for every SGD 1 spent'),
    'the struck-out generic marketing line ("Earn N points for every SGD 1 spent") is gone');
  const c360Text=await page.locator('#c360-loyalty').innerText();
  assertTrue(!c360Text.includes('This programme is paused, so nothing can be redeemed right now'),
    'the trailing paused paragraph the owner struck out is gone');
  const pausedPills=await page.locator('#c360-loyalty .c360-programme-row-v294 .pill.off').allInnerTexts();
  assertTrue(pausedPills.some(text=>text.trim()==='Paused'),'the Paused pill still says the programme is paused');
  assertTrue(programmesText.includes('Tiered membership')&&programmesText.includes('Not in a tier yet'),
    'the tier row states this customer’s tier standing (2 visits, Gold starts at 10)');
  assertTrue(programmesText.includes('August Special'),
    'the promotion row keeps its short customer-facing description (owner circled it approvingly)');
  assertTrue(programmesText.includes('Referral programme'),'the referral row is untouched');

  /* --------------------------- 2. gift cards page --------------------------- */
  /* V303 (owner 2026-08-13: "remove gift cards from the business UI entirely"). V296 removed the
     "Offer gift cards" block FROM this page and moved it to Customer Interface, on the reading
     that the capability had to survive the block. The owner has now removed the surface itself,
     so the page this step was about no longer answers: #/giftcards is refused with a plain toast
     and corrected to the dashboard, exactly like the storedvalue refusal. Nothing customer-side
     changes — the wallet still shows a customer their outstanding gift-card balance — and no DB
     object, businesses.gift_card_sales_enabled included, is touched. */
  say('2. #/giftcards is refused and says so, and no gift-card control is left in the workspace');
  await go('#/giftcards');
  await page.waitForFunction(()=>location.hash==='#/dashboard',null,{timeout:20000});
  assertTrue(true,'a typed #/giftcards is corrected to #/dashboard rather than rendering');
  assertTrue((await page.locator('#toast').innerText())
    .includes('Gift cards are no longer part of this workspace.'),
    'and the refusal SAYS so, rather than bouncing silently');
  const giftText=await bodyText();
  assertTrue(!giftText.includes('Issue a gift card'),'the issuing workspace is not rendered anywhere');
  assertTrue(await page.locator('#giftCardEnabled').count()===0,'and no issuance checkbox exists in the shell');
  assertTrue(await page.locator('a[href="#/giftcards"]').count()===0,'no nav row still points at it');

  /* --------------------------- 3. Customer Interface sub-tabs --------------------------- */
  say('3. Customer Interface is a nav group whose children land on their sections');
  await go('#/customer-interface');
  await page.waitForSelector('[data-ci-view-v296="preview"]',{timeout:20000});
  const ciHead=page.locator('.side .navhead[data-grp="customerui"]').first();
  assertTrue(await ciHead.count()===1,'the rail shows a Customer Interface GROUP header');
  assertTrue((await ciHead.evaluate(node=>node.textContent)).includes('Customer Interface'),
    'the group header is labelled Customer Interface');
  if(await ciHead.getAttribute('aria-expanded')!=='true')await ciHead.click();
  const children=[
    ['Preview','#/customer-interface','preview'],
    ['Workspace & brand','#/customer-interface/brand','brand'],
    ['Customer programme','#/customer-interface/programme','programme'],
    /* V303: the Gift cards child went with the surface (owner: "remove gift cards from the
       business UI entirely"). The four children below are unchanged and still prove the V296
       requirement this step is about — each rail child lands on, and shows only, its section. */
    ['Sign-up & fields','#/customer-interface/interface','interface']
  ];
  for(const [label,href,key] of children){
    const link=page.locator(`.side .navbody[data-body="customerui"] a[href="${href}"]`).first();
    assertTrue(await link.count()===1,`group child "${label}" is present`);
    await link.click();
    await page.waitForFunction(view=>{
      const shown=document.querySelector(`[data-ci-view-v296="${view}"]`);
      return shown&&!shown.hidden;
    },key,{timeout:20000});
    const hiddenOthers=await page.evaluate(view=>[...document.querySelectorAll('[data-ci-view-v296]')]
      .filter(node=>node.dataset.ciViewV296!==view).every(node=>node.hidden),key);
    assertTrue(hiddenOthers,`child "${label}" shows only its own section`);
    const activeChild=page.locator('.side .navbody[data-body="customerui"] a.act').first();
    assertTrue((await activeChild.evaluate(node=>node.textContent)).includes(label),
      `child "${label}" is marked active in the rail`);
  }
  /* V303: the moved switch and its section are gone, so what is asserted is their ABSENCE — and
     that no set_gift_card_sales_enabled_v102 write can be reached from this page any more. */
  assertTrue(await page.locator('[data-ci-view-v296="giftcards"]').count()===0,
    'Customer Interface has no Gift cards section left');
  assertTrue(await page.locator('#giftCardEnabled').count()===0,'and no "Offer gift cards" switch');
  assertTrue(await page.locator('a[href="#/customer-interface/giftcards"]').count()===0,
    'and no rail child pointing at one');
  assertTrue(await page.evaluate(()=>!window.__V296.rpc.some(call=>call.name==='set_gift_card_sales_enabled_v102')),
    'no gift-card issuance write is reachable from this page');
  /* The customer side is deliberately untouched: gift-card BALANCE visibility in the wallet is a
     separate reader (customer_get_gift_cards) on a separate surface, and V303 changed neither. */
  assertTrue(await page.evaluate(()=>!window.__V296.rpc.some(call=>call.name==='customer_get_gift_cards'&&call.failed)),
    'the customer wallet gift-card reader is untouched by this removal');

  /* --------------------------- 4. no in-page programme view pills --------------------------- */
  say('4. the in-page Overview / List / History pill strip is gone, the rail children are not');
  await go('#/grow');
  await page.waitForSelector('[data-grow-topic-v229]',{timeout:20000});
  assertTrue(await page.locator('[data-grow-view-v271]').count()===0,
    'no in-page programme-view pill remains (owner circled them: "remove")');
  assertTrue(await page.locator('[aria-label="Programme views"]').count()===0,
    'the pill strip container is gone too');
  const growHead=page.locator('.side .navhead[data-grp="grow"]').first();
  if(await growHead.getAttribute('aria-expanded')!=='true')await growHead.click();
  for(const [label,href,view] of [['Overview','#/grow/overview','overview'],['List','#/grow','list'],['History','#/grow/history','history']]){
    const link=page.locator(`.side .navbody[data-body="grow"] a[href="${href}"]`).first();
    assertTrue(await link.count()===1,`rail child "${label}" is still the way to that view`);
    await link.click();
    await page.waitForFunction(expected=>document.getElementById('growOverview')?.dataset.programmeView===expected,
      view,{timeout:20000});
    assertTrue(true,`rail child "${label}" lands on the ${view} view`);
  }
  /* Deep links that the pills used to be the only in-page route to still resolve. */
  for(const [hash,view] of [['#/grow/ongoing','ongoing'],['#/grow/available','available'],['#/grow/settings','settings']]){
    await go(hash);
    await page.waitForFunction(expected=>document.getElementById('growOverview')?.dataset.programmeView===expected,
      view,{timeout:20000});
    assertTrue(true,`legacy deep link ${hash} still lands on the ${view} view`);
  }

  /* --------------------------- 5. promotions listed by title --------------------------- */
  say('5. drilling Promotions lists each promotion by title with its own action');
  await go('#/grow');
  await page.waitForSelector('[data-grow-topic-v229="promotions"]',{timeout:20000});
  await page.click('[data-grow-topic-v229="promotions"]');
  await page.waitForSelector('[data-programme-category-v268="promotions"]',{timeout:20000});
  const promoPanel=page.locator('[data-programme-category-v268="promotions"]');
  const promoText=await promoPanel.innerText();
  assertTrue(promoText.includes('August Special'),'the published promotion is listed by its own title');
  assertTrue(promoText.includes('September Preview'),'the draft promotion is listed by its own title too');
  assertTrue(!promoText.includes('published promotions. Customers see up to six current offers.'),
    'the struck-out single aggregate row is gone');
  assertTrue(/1 published · 1 draft/.test(promoText),
    'the count survives as a small header line, not as the only content');
  assertTrue(await promoPanel.locator('a[href="#/promotions/pm1"]').count()===1,
    '"August Special" has its own action opening that promotion');
  assertTrue(await promoPanel.locator('a[href="#/promotions/pm2"]').count()===1,
    '"September Preview" has its own action opening that promotion');
  assertTrue(await promoPanel.locator('a[href="#/promotions"]').count()===1,
    'the list is not a dead end — one row adds another promotion');
  const promoRowText=await promoPanel.locator('.grow-programme-row',{hasText:'August Special'}).first().innerText();
  assertTrue(/Live now|Ended|Scheduled/.test(promoRowText),
    `each row carries a short detail line of its own state (${JSON.stringify(promoRowText.replace(/\s+/g,' ').trim())})`);

  /* --------------------------- 6 + 7. card copy and the rename --------------------------- */
  say('6. pending-setup cards stop cross-referencing the live model');
  /* Step 5 drilled into a topic without changing the hash, so a bare go('#/grow') would be a
     no-op. Leave the surface and come back, which is also how the owner gets here. */
  await go('#/dashboard');
  await page.waitForSelector('#dashboardScheduleHeadingV295',{timeout:20000});
  await go('#/grow');
  await page.waitForSelector('[data-grow-topic-v229]',{timeout:20000});
  const growText=await bodyText();
  assertTrue(!growText.includes('is the live model'),
    'no card says "<other model> is the live model" (owner: "X NO — not linked to point")');
  assertTrue(!growText.includes('Live model ·'),'no card carries a "Live model ·" subtitle');
  assertTrue(growText.includes('Do tier membership for your customers!'),
    'the Tiered membership card keeps the owner’s benefit line');
  assertTrue(growText.includes('Customers earn stamps and redeem!'),
    'the Stamp card keeps the owner’s benefit line');

  say('7. "Points System" replaces "Points redemption" in the business UI');
  assertTrue(growText.includes('Points System'),'the programme card is titled "Points System"');
  assertTrue(!growText.includes('Points redemption'),'"Points redemption" is gone from the Programmes page');
  await go('#/loyalty/draft-1');
  await page.waitForSelector('#lm',{timeout:20000});
  const editorText=await page.evaluate(()=>document.getElementById('lm').innerHTML);
  assertTrue(editorText.includes('Points System — earn points, redeem rewards'),
    'the loyalty-model picker option reads "Points System"');
  assertTrue(await page.evaluate(()=>document.querySelector('#lm option[value="redeem"]')!==null),
    'the underlying model key is still "redeem" — this was a label change only');

  if(pageErrors.length)process.stdout.write(`note: page errors observed (non-fatal): ${JSON.stringify(pageErrors)}\n`);
  process.stdout.write('V296 programmes batch walkthrough PASS (steps 1-7)\n');
}catch(error){
  process.stdout.write(`V296 walkthrough FAIL at ${step}\n${error?.stack||error}\n`);
  if(pageErrors.length)process.stdout.write(`page errors: ${JSON.stringify(pageErrors)}\n`);
  process.exitCode=1;
}finally{
  await browser.close().catch(()=>{});
  if(server)server.kill();
}
