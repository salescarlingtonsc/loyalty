/* V310 W4b customer programme stack — walkthrough.
 *
 * The wallet used to show a customer's programmes as TABS, and which tab existed came from a MODE
 * rather than from the firm's actual programmes. A stamps firm carries points_mode='redeem' after
 * the v306 hotfix, so it fell through the redeem branch and was drawn as a card headed, hard-coded,
 * "Reward points", printing "8 stamps" underneath, with no rings anywhere in the file. A firm
 * running three or four programmes had nowhere to put the rest.
 *
 * W4b replaces that with a STACK: one card per programme the firm actually runs, fixed order
 * stamps → points & gifts → tier → referral, each card one figure, one sentence, one action. It is
 * gated on capabilities.programmes + programmes_contract==='v310', which only a v310 server sends.
 *
 * This drives the REAL stamped production bundles through the real router with the Supabase client
 * replaced by an in-page fixture, exactly as verify-v301-setup-wizard-walkthrough.mjs does. It
 * NEVER runs `npm run bundle-stamp` against the repo: the stamped trees are built into a scratch
 * directory by calling the exported build() (W0 precedent) and served from there, so the working
 * tree is untouched by the evidence run.
 *
 * Steps (each asserts; the script exits non-zero naming the failing step):
 *   a. four-programme fixture → four cards in the fixed order, at 390 in about one and a half
 *      thumb-scrolls.
 *   b. one-programme fixture → exactly one card. No filler.
 *   c. paused points programme → the paused sentence and its retained figure, card still present,
 *      and the other cards untouched.
 *   d. PRE-V310 PAYLOAD (`programmes` absent) → the v194 tabs render and the programme region's
 *      DOM is BYTE-IDENTICAL to the same fixture rendered by the pre-change bundle. This is the
 *      four-hour Cloudflare window proof and the rollback proof, and it is the most important
 *      step in the file: an old bundle against a new server and a new bundle against an old server
 *      must both be correct, and only one of those can be proven by reading code.
 *   e. exactly one .customer-programme-balance in the rendered stack.
 *   f. stamps fixture → the ring row is present and the string "Reward points" is absent from the
 *      stamps card.
 *   g. referral card at stack position 4 on {enabled:true}; absent on {enabled:false}.
 *
 * Ports: 4310 (the change) and 4311 (the HEAD baseline). Sibling worktrees use 4173/4196/4203/4303;
 * the probe checks that whatever answers is THIS build, not merely that something answers — a
 * stale server from another tree returning 200 is the exact failure a bare reachability probe
 * cannot see.
 *
 * Prepare the trees, then run:
 *   node <scratch>/build-v310-app.mjs <scratch>
 *   PLAYWRIGHT_MODULE=".../playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   V310_APP_DIR="<scratch>/app-v310" V310_BASELINE_DIR="<scratch>/app-head" \
 *   V310_SHOTS="<scratch>/shots" \
 *   node tests/browser/verify-v310-customer-stack-walkthrough.mjs
 */
import {spawn} from 'node:child_process';
import {mkdirSync} from 'node:fs';
import {fileURLToPath} from 'node:url';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;

const APP_DIR=process.env.V310_APP_DIR||fileURLToPath(new URL('../../app/',import.meta.url));
const BASELINE_DIR=process.env.V310_BASELINE_DIR||'';
const SHOTS=process.env.V310_SHOTS||fileURLToPath(new URL('../../docs/qa/evidence/',import.meta.url));
const PORT=Number(process.env.V310_PORT||4310);
const BASELINE_PORT=Number(process.env.V310_BASELINE_PORT||4311);
const ORIGIN=`http://127.0.0.1:${PORT}`;
const BASELINE_ORIGIN=`http://127.0.0.1:${BASELINE_PORT}`;
mkdirSync(SHOTS,{recursive:true});

let step='(boot)';
const say=name=>{step=name;process.stdout.write(`STEP ${name}\n`)};
const assertTrue=(condition,message)=>{
  if(!condition)throw new Error(`step ${step}: ${message}`);
  process.stdout.write(`  ok - ${message}\n`);
};

const servers=[];
const probe=async origin=>{
  try{
    const response=await fetch(`${origin}/index.html`);
    if(!response.ok)return false;
    /* Serving SOMETHING is not serving THIS app. */
    return (await (await fetch(`${origin}/app-customer.js`)).text()).includes('customerProgrammeSummaryTabsV194');
  }catch{return false}
};
const serverReady=async(dir,port,origin)=>{
  if(await probe(origin))return;
  const server=spawn('python3',['-m','http.server',String(port),'--bind','127.0.0.1'],{cwd:dir,stdio:'ignore'});
  server.on('error',error=>process.stdout.write(`server spawn error: ${error}\n`));
  servers.push(server);
  for(let i=0;i<60;i++){
    if(await probe(origin))return;
    await new Promise(resolve=>setTimeout(resolve,100));
  }
  throw new Error(`static server did not start on ${origin}`);
};

const BIZ='c1111111-1111-4111-8111-111111111111';
const SLUG='hougang-abc';

/* The stub. One fixture generator, parameterised by a SCENARIO name baked into the page before
   boot, so each scenario is a clean context rather than a re-render of a mutated one. */
const stubSource=scenario=>`(()=>{
  const SCENARIO=${JSON.stringify(scenario)};
  const BIZ='${BIZ}',SLUG='${SLUG}';
  const spine=on=>['points','tiers','stamps','referral'].map(kind=>({
    kind,active:false,customer_visible:false,running_since:null,paused_since:null,
    balance_scope:'business_pot',...(on[kind]||{})}));
  const RUN={active:true,customer_visible:true,running_since:'2026-02-01T00:00:00Z'};
  const PAUSED={active:false,customer_visible:false,running_since:'2026-02-01T00:00:00Z',
    paused_since:'2026-07-01T00:00:00Z'};
  /* Every scenario is a real tenant shape. The four-programme one is the world W5/W6 build
     toward; today the v308 tripwire refuses points.active AND stamps.active on one business, so
     it is a FIXTURE of the destination, not a state production can currently be in. */
  const SHAPES={
    /* The four-programme shape is a fixture of the DESTINATION, and its unit is 'stamps' on
       purpose. W4's currentness policy keeps every balance single-pot (balance_scope
       'business_pot'), so both accruing cards read the same pot and the server's own unit word
       names it — which at a firm running a stamp card is 'stamps'. A fixture that said 'points'
       here would have the Stamp card printing "180 points" under a sentence counting stamps, and
       that mismatch is a property of the FIXTURE, not of production: the v308 tripwire refuses
       points.active AND stamps.active on one business, and W5's pot split is what makes two
       independent figures possible. */
    four:{programmes:spine({points:RUN,tiers:RUN,stamps:RUN,referral:RUN}),balance:6,unit:'stamps',
      reward:{name:'Free pastry',cost_units:10,remaining_units:4,available_now:false}},
    one:{programmes:spine({points:RUN}),balance:180,unit:'points',
      reward:{name:'Free flat white',cost_units:300,remaining_units:120,available_now:false}},
    typical:{programmes:spine({points:RUN,tiers:RUN,referral:RUN}),balance:180,unit:'points',
      reward:{name:'Free flat white',cost_units:300,remaining_units:120,available_now:false}},
    paused:{programmes:spine({points:PAUSED,tiers:RUN}),balance:180,unit:'points',
      reward:{name:'Free flat white',cost_units:300,remaining_units:120,available_now:false}},
    stamps:{programmes:spine({stamps:RUN,referral:RUN}),balance:6,unit:'stamps',
      reward:{name:'Free pastry',cost_units:10,remaining_units:4,available_now:false}},
    referral_off:{programmes:spine({points:RUN,tiers:RUN,referral:RUN}),balance:180,unit:'points',
      referral:false,reward:{name:'Free flat white',cost_units:300,remaining_units:120,available_now:false}},
    /* The pre-v310 server: no programmes, no contract version. Nothing else differs. */
    pre310:{programmes:null,balance:180,unit:'points',
      reward:{name:'Free flat white',cost_units:300,remaining_units:120,available_now:false}}
  };
  const SHAPE=SHAPES[SCENARIO];
  const stampsFirm=SCENARIO==='stamps';
  const TIER={basis:'visits',metric:7,progress_percent:70,points_mode:SHAPE.programmes?'both':'both',
    current:{label:'Explorer',threshold:0,benefits:['A warm welcome','Birthday treat']},
    next:{label:'Pioneer',threshold:10,benefits:['10% off every visit','Priority booking']},
    tiers:[{label:'Explorer',threshold:0,current:true,achieved:true,benefits:['A warm welcome','Birthday treat']},
      {label:'Pioneer',threshold:10,benefits:['10% off every visit','Priority booking']},
      {label:'Voyager',threshold:30,benefits:['15% off','A free treatment each year']}]};
  const LOYALTY={enabled:true,balance:SHAPE.balance,unit:SHAPE.unit,credit_balance_cents:0};
  const BUSINESS={id:BIZ,slug:SLUG,name:'Hougang ABC Cafe',currency:'SGD',industry:'Cafe',
    brand_color:'#7c5cff',review_url:null};
  const CARD={business:BUSINESS,loyalty:LOYALTY,credit:{},packages:{},
    next_eligible_reward:SHAPE.reward,visit_progress:{},birthday_benefit:null};
  const CAPS=(()=>{
    const base={wallet:true,rewards:!stampsFirm,tiers:true,points_mode:stampsFirm?'redeem':'both',
      activity:true,appointments:false,booking_request:false,packages:false,membership:false};
    if(!SHAPE.programmes)return base;           // pre-v310 server: the two new keys never arrive
    return {...base,programmes_contract:'v310',programmes:SHAPE.programmes};
  })();
  const PRESENTATION={locale:'en',brand:{hero_color:'#7c5cff'},
    programme:{name:'Hougang ABC Rewards',tagline:'Kopi that remembers you',unit:SHAPE.unit,
      balance:SHAPE.balance,tier:TIER,benefits:[],offers:[]},
    catalogue:{rewards:[],products:[],services:[]},capabilities:{booking_enabled:false}};
  window.__V310={rpc:[]};
  const chainable=resolveOut=>{
    const q={single:false,head:false,countMode:null,op:'select'};
    const chain={};
    for(const m of ['eq','neq','is','in','not','gte','lte','lt','gt','or','ilike','contains',
      'overlaps','order','limit','range','abortSignal'])chain[m]=()=>chain;
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
  const query=()=>chainable(q=>q.single?{data:null,error:null}:{data:[],count:0,error:null});
  const DENIED={code:'42501',message:'not available'};
  const rpcData=name=>{
    switch(name){
      case 'get_customer_feature_capabilities':return {customer_identity:true,customer_wallet:true,
        customer_actions:true,customer_actionable_wallet:true,customer_phone_registration:true,
        customer_birthday_benefits:false,customer_in_app_inbox:false,customer_notifications:false};
      case 'customer_get_profile':return {profile:{full_name:'Mei Ling',birth_date:null,gender:null,
        preferred_language:'en'}};
      case 'get_my_personas':return {staff:[],customer:[{business_id:BIZ,business_slug:SLUG,
        business_name:BUSINESS.name}],default_route:'#/customer/programmes'};
      case 'customer_get_actionable_business':return {card:CARD};
      case 'customer_get_actionable_wallet':return {cards:[CARD]};
      case 'customer_get_wallet':return [CARD];
      case 'customer_get_business_summary':return {business:BUSINESS,loyalty:LOYALTY,
        packages:{},membership:{}};
      case 'customer_portal_capabilities':return CAPS;
      case 'customer_get_business_actions_v89':return {booking:{enabled:false},
        appointment_changes:{enabled:false},redemption:{enabled:true,classic:null},rewards:[]};
      case 'customer_get_business_presentation_v95':return PRESENTATION;
      case 'customer_get_effective_tier_v143':return {tier:TIER};
      case 'customer_get_promotions_v155':return {items:[]};
      case 'customer_get_reward_catalog':return {points_mode:CAPS.points_mode,rewards:[
        {id:'rw1',customer_name:SHAPE.reward.name,cost_points:SHAPE.reward.cost_units,
         description:'Any size, any day.',availability:'available_at_counter'}]};
      case 'customer_get_referral_card_v300':
        return SHAPE.referral===false?{enabled:false}
          :{enabled:true,code:'MEILING7',currency:'SGD',reward_cents:800,min_spend_cents:2000,
            referred_count:2};
      case 'customer_get_growth_offers_v108':return {offers:[]};
      case 'customer_get_transaction_history_v81':return {items:[]};
      case 'customer_get_loyalty_details':return {loyalty:{balance:SHAPE.balance,unit:SHAPE.unit},
        activity:[],expiry:{expiring_next_30_days:0,next_expiry_at:null}};
      case 'customer_record_account_open_v175':return {status:'ok'};
      default:return null;
    }
  };
  const SILENT=new Set(['customer_get_gift_cards','customer_get_packages','customer_get_memberships',
    'customer_get_appointments','customer_get_pending_promotion_prompt_v122']);
  const rpc=(name,args)=>{
    window.__V310.rpc.push({name,args:args??null});
    if(SILENT.has(name))return chainable(()=>({data:null,error:DENIED}));
    return chainable(()=>({data:rpcData(name),error:null}));
  };
  const channel=()=>{const c={on:()=>c,subscribe:()=>c,unsubscribe:()=>{}};return c};
  const auth=new Proxy({
    getSession:async()=>({data:{session:{user:{id:'u-cust',email:'mei@example.sg'}}},error:null}),
    getUser:async()=>({data:{user:{id:'u-cust',email:'mei@example.sg'}},error:null}),
    onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
    signOut:async()=>({error:null})
  },{get:(target,key)=>key in target?target[key]:async()=>({data:null,error:null})});
  const client={from:query,rpc,auth,channel,removeChannel(){},
    functions:{invoke:async()=>({data:null,error:null})},
    storage:{from:()=>({getPublicUrl:()=>({data:{publicUrl:''}})})}};
  Object.defineProperty(window,'supabase',{value:{createClient:()=>client},writable:false,configurable:false});
})();`;

const browser=await chromium.launch({
  headless:true,
  executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
});
const pageErrors=[];
try{
  await serverReady(APP_DIR,PORT,ORIGIN);
  if(BASELINE_DIR)await serverReady(BASELINE_DIR,BASELINE_PORT,BASELINE_ORIGIN);

  const openWallet=async(scenario,{width=390,height=844,theme=null,origin=ORIGIN}={})=>{
    const context=await browser.newContext({viewport:{width,height},bypassCSP:true,
      deviceScaleFactor:2});
    await context.route('**/*',route=>{
      const url=route.request().url();
      if(url.startsWith(origin)&&!url.includes('/sw.js'))return route.continue();
      return route.abort();
    });
    /* Dark is the STORED customer preference, not the OS one: peekaa.customer.theme is what the
       surface actually reads, and emulating prefers-color-scheme would prove a different thing. */
    if(theme)await context.addInitScript(`try{localStorage.setItem('peekaa.customer.theme',${JSON.stringify(theme)})}catch{}`);
    await context.addInitScript(stubSource(scenario));
    const page=await context.newPage();
    page.on('pageerror',error=>pageErrors.push(`${scenario}: ${error}`));
    await page.goto(`${origin}/index.html#/wallet/${SLUG}`,{waitUntil:'domcontentloaded'});
    await page.waitForSelector('.customer-programme-compact-head',{timeout:25000});
    return {context,page};
  };
  const cardOrder=page=>page.evaluate(()=>[...document.querySelectorAll('[data-programme-card]')]
    .map(node=>node.dataset.programmeCard));
  /* The programme region only, normalised for nothing: this is a BYTE comparison, so the only
     thing removed is the region's own container attribute, which does not exist on the baseline. */
  const programmeRegionHtml=(page,{blankRewardsV322=false}={})=>page.evaluate(blank=>{
    const region=document.querySelector('.customer-programme-tabs,[data-programme-stack]');
    if(!region)return '(absent)';
    /* v322: the reward CATALOGUE is hydrated into this region by loadRewards on both paths and was
       deliberately redesigned this wave (cards → rows, every label ct()-routed), so step d blanks
       it on BOTH sides rather than pinning the card the owner's review measured at two per screen.
       Done in the DOM, where the host's boundaries are exact, instead of by regex over serialised
       markup. Everything else in the region is still compared byte for byte. */
    if(blank){
      const host=region.querySelector('#walletRewards');
      if(host)host.textContent='REWARDS';
    }
    return region.outerHTML;
  },blankRewardsV322);

  /* ------------------------------ a. four programmes, fixed order ------------------------------ */
  say('a. a four-programme firm renders four cards in the fixed order');
  {
    const {context,page}=await openWallet('four');
    await page.waitForSelector('[data-programme-stack="v310"]',{timeout:20000});
    const order=await cardOrder(page);
    /* v319 (owner: "shift the tier up — to the top of the screen, instead of points & gift"). */
    assertTrue(JSON.stringify(order)===JSON.stringify(['tiers','stamps','points']),
      `the three programme cards render in the fixed order (${order.join(' → ')})`);
    await page.waitForSelector('#walletReferral',{timeout:20000});
    const positions=await page.evaluate(()=>{
      const stack=document.querySelector('[data-programme-stack]');
      return [...stack.children].map(node=>node.dataset.programmeCard||node.id||node.className);
    });
    assertTrue(positions[3]==='walletReferral',
      `the referral card is stack position 4 (${JSON.stringify(positions)})`);
    const scroll=await page.evaluate(()=>{
      const stack=document.querySelector('[data-programme-stack]');
      return stack.getBoundingClientRect().height/window.innerHeight;
    });
    assertTrue(scroll<2.2,`four programmes fit about one and a half thumb-scrolls at 390 (${scroll.toFixed(2)} screens)`);
    await page.screenshot({path:`${SHOTS}/v310-customer-stack-four-390.png`,fullPage:true});
    await context.close();
  }
  {
    const {context,page}=await openWallet('four',{width:1440,height:1000});
    await page.waitForSelector('#walletReferral',{timeout:20000});
    await page.screenshot({path:`${SHOTS}/v310-customer-stack-desktop-1440.png`,fullPage:true});
    await context.close();
  }

  /* ------------------------------ b. one programme, one card ------------------------------ */
  say('b. a one-programme firm renders exactly one card and no filler');
  {
    const {context,page}=await openWallet('one');
    await page.waitForSelector('[data-programme-stack="v310"]',{timeout:20000});
    const order=await cardOrder(page);
    assertTrue(JSON.stringify(order)===JSON.stringify(['points']),
      `one live programme, one card (${JSON.stringify(order)})`);
    assertTrue(await page.locator('[data-programme-card="stamps"]').count()===0,
      'a stamps programme this firm never ran renders nothing at all');
    assertTrue(await page.locator('[data-programme-card="tiers"]').count()===0,
      'nor does a tier programme it never ran');
    await context.close();
  }

  /* ------------------------------ c. paused keeps its card ------------------------------ */
  say('c. a paused programme keeps its card, says so, and does not blank the others');
  {
    const {context,page}=await openWallet('paused');
    await page.waitForSelector('[data-programme-card="points"]',{timeout:20000});
    const points=await page.locator('[data-programme-card="points"]').innerText();
    assertTrue(/Programme paused/.test(points),'the paused points card says it is paused');
    assertTrue(/Anything you already earned is kept/.test(points),
      'and that what the customer holds is retained, not lost');
    assertTrue(/1 Jul 2026/.test(points),'and since when, from the server’s own breadcrumb');
    assertTrue(await page.locator('[data-programme-card="tiers"]').count()===1,
      'the tier card is untouched — one programme pausing never blanks another');
    const tiers=await page.locator('[data-programme-card="tiers"]').innerText();
    assertTrue(/Explorer/.test(tiers),'and still shows the rung the customer is on');
    await context.close();
  }

  /* -------------------- d. THE CDN-WINDOW PROOF: pre-v310 payload, byte-identical -------------------- */
  say('d. a pre-v310 payload falls back to the v194 tabs, byte-identical to the pre-change bundle');
  {
    const {context,page}=await openWallet('pre310');
    await page.waitForSelector('.customer-programme-tabs',{timeout:20000});
    assertTrue(await page.locator('[data-programme-stack]').count()===0,
      'no stack: `programmes` is absent, so the gate is closed');
    assertTrue(await page.locator('[data-programme-tab="tier"]').count()===1,'the Tier tab renders');
    assertTrue(await page.locator('[data-programme-tab="points"]').count()===1,'the Reward points tab renders');
    const afterRaw=await programmeRegionHtml(page);
    const after=await programmeRegionHtml(page,{blankRewardsV322:true});
    await page.locator('[data-programme-tab="points"]').click();
    assertTrue(await page.locator('[data-programme-panel="points"]').isVisible(),
      'the tab wiring still works — wireCustomerProgrammeTabsV194 is reachable and not dead code');
    await context.close();

    if(!BASELINE_DIR)throw new Error('step d needs V310_BASELINE_DIR: the byte comparison is the point');
    const baseline=await openWallet('pre310',{origin:BASELINE_ORIGIN});
    await baseline.page.waitForSelector('.customer-programme-tabs',{timeout:20000});
    const beforeRaw=await programmeRegionHtml(baseline.page);
    const before=await programmeRegionHtml(baseline.page,{blankRewardsV322:true});
    await baseline.context.close();

    /* v319 (owner: "the UI UX is being squeezed") re-based the tier rail on the RUNG INDEX — the
       fill and the markers were previously on two different scales, so the bar's filled end agreed
       with no marker on it. That fix is deliberately on BOTH paths, the stack and this v194
       fallback, so the two bundles' geometry numbers are now expected to differ and pinning them
       byte-for-byte would be pinning the bug.
       Everything else must still match exactly, which is what makes this the rollback proof: the
       comparison blanks ONLY the geometry (the bar's width and each marker's left offset) and
       asserts byte identity over all the remaining markup — every element, class, attribute,
       sentence and rung label. The geometry itself is asserted on its own terms in
       tests/customer-modules/v174-customer-tier-card.test.mjs. */
    const withoutRailGeometryV319=html=>html
      .replace(/(<span style="width:)[\d.]+(%">)/g,'$1RAIL$2')
      .replace(/(style="left:)[\d.]+(%")/g,'$1RAIL$2');
    /* v322 does the same thing for the REWARD CATALOGUE, and for the same reason. The gate this
       step protects is which SURFACE renders — stack or tabs — not what a reward row looks like:
       the catalogue is hydrated by loadRewards on BOTH paths, and v322 deliberately changed it on
       both (cards became rows a thumb opens, and every label went through ct()). Pinning it
       byte-for-byte here would pin the two-per-screen card the owner's review measured. So the
       hydrated section is replaced by a marker on both sides — its OWN behaviour is measured in
       tests/browser/verify-customer-experience-walkthrough.mjs (density, one red action, four
       locales) and in tests/customer-wallet/v322-customer-experience-redesign.test.mjs — and every
       other byte of the fallback region is still compared exactly. */
    const afterShape=withoutRailGeometryV319(after),beforeShape=withoutRailGeometryV319(before);
    if(afterShape!==beforeShape){
      const at=[...afterShape].findIndex((ch,i)=>ch!==beforeShape[i]);
      throw new Error(`step d: the fallback DOM is NOT byte-identical to the pre-change bundle.\n`
        +`  first difference at byte ${at}\n  before: ${JSON.stringify(beforeShape.slice(Math.max(0,at-90),at+90))}\n`
        +`  after:  ${JSON.stringify(afterShape.slice(Math.max(0,at-90),at+90))}`);
    }
    assertTrue(afterShape.includes('width:RAIL%')&&afterShape!==after,
      'the geometry really was blanked — a comparison that normalised nothing would prove nothing');
    assertTrue(afterShape.includes('>REWARDS<')&&beforeShape.includes('>REWARDS<')
      &&afterRaw.includes('wallet-reward')&&beforeRaw.includes('wallet-reward'),
      'and both sides really did carry a hydrated reward catalogue that was normalised away');
    assertTrue(true,`the programme region is byte-identical to the pre-change bundle outside the `
      +`v319 rail geometry (${after.length} bytes)`);
    assertTrue(before.includes('customer-programme-tablist'),
      'and it really is the v194 tab markup that was compared, not two empty strings');
  }

  /* ------------------------------ e. one hero ------------------------------ */
  say('e. exactly one .customer-programme-balance in the rendered stack');
  {
    const {context,page}=await openWallet('four');
    await page.waitForSelector('[data-programme-stack="v310"]',{timeout:20000});
    const heroes=await page.evaluate(()=>document.querySelectorAll('.customer-programme-balance').length);
    assertTrue(heroes===1,`one number, one owner — the Points card (found ${heroes})`);
    const tierText=await page.locator('[data-programme-card="tiers"]').innerText();
    assertTrue(!/\b6 stamps\b/.test(tierText),
      'and the tier card does not repeat the spendable balance beside the words "earned"');
    await context.close();
  }

  /* ------------------------------ f. the stamps card ------------------------------ */
  say('f. a stamps firm gets rings, and never the words "Reward points"');
  {
    const {context,page}=await openWallet('stamps');
    await page.waitForSelector('[data-programme-card="stamps"]',{timeout:20000});
    const rings=await page.evaluate(()=>document.querySelectorAll('.customer-programme-stamp-ring').length);
    assertTrue(rings===10,`the ring row draws the reward's own cost, ten rings (found ${rings})`);
    const filled=await page.evaluate(()=>document.querySelectorAll('.customer-programme-stamp-ring.is-filled').length);
    assertTrue(filled===6,`six of them filled, from the balance the server sent (found ${filled})`);
    const stamps=await page.locator('[data-programme-card="stamps"]').innerText();
    assertTrue(!/Reward points/.test(stamps),
      'the stamps card never says "Reward points" — the exact defect this replaces');
    assertTrue(/Stamp card/.test(stamps),'it says Stamp card');
    assertTrue(/4 more stamps and your next Free pastry is on us\./.test(stamps),
      'and one sentence saying what is left and what it buys');
    const greyscale=await page.evaluate(()=>{
      const empty=document.querySelector('.customer-programme-stamp-ring:not(.is-filled)');
      const full=document.querySelector('.customer-programme-stamp-ring.is-filled');
      return {emptyStyle:getComputedStyle(empty).borderStyle,fullStyle:getComputedStyle(full).borderStyle,
        tick:full.querySelector('svg')!==null};
    });
    assertTrue(greyscale.emptyStyle==='dashed'&&greyscale.fullStyle==='solid'&&greyscale.tick,
      'filled and empty differ by border style and a tick glyph, so the row reads in greyscale');
    await context.close();
  }

  /* ------------------------------ g. referral position and gate ------------------------------ */
  say('g. the referral card is stack position 4, and only a server yes puts it there');
  {
    const {context,page}=await openWallet('typical');
    await page.waitForSelector('#walletReferral',{timeout:20000});
    const index=await page.evaluate(()=>{
      const stack=document.querySelector('[data-programme-stack]');
      return [...stack.children].findIndex(node=>node.id==='walletReferral');
    });
    assertTrue(index===2,`the referral card is the last child of the stack (index ${index} of 3)`);
    assertTrue(/MEILING7/.test(await page.locator('#walletReferral').innerText()),
      'and carries the code the server issued');
    await page.screenshot({path:`${SHOTS}/v310-customer-stack-390.png`,fullPage:true});
    await context.close();
  }
  {
    const {context,page}=await openWallet('referral_off');
    await page.waitForSelector('[data-programme-stack="v310"]',{timeout:20000});
    await page.waitForFunction(()=>!document.getElementById('walletReferralSlot'),null,{timeout:20000});
    assertTrue(await page.locator('#walletReferral').count()===0,
      '{enabled:false} removes the slot entirely — a growth invitation is never advertised when off');
    await context.close();
  }

  /* ------------------------------ dark, the stored preference ------------------------------ */
  say('h. the stack in the customer’s stored dark theme');
  {
    const {context,page}=await openWallet('typical',{theme:'dark'});
    await page.waitForSelector('[data-programme-stack="v310"]',{timeout:20000});
    const dark=await page.evaluate(()=>document.documentElement.getAttribute('data-customer-theme'));
    assertTrue(dark==='dark','the stored peekaa.customer.theme drives it, not prefers-color-scheme');
    await page.waitForSelector('#walletReferral',{timeout:20000});
    await page.screenshot({path:`${SHOTS}/v310-customer-stack-dark-390.png`,fullPage:true});
    await context.close();
  }

  if(pageErrors.length)throw new Error(`page errors: ${pageErrors.join(' | ')}`);
  process.stdout.write(`\nALL STEPS PASSED\nscreenshots in ${SHOTS}\n`);
}catch(error){
  process.stdout.write(`\nFAILED at ${step}: ${error?.stack||error}\n`);
  if(pageErrors.length)process.stdout.write(`page errors: ${pageErrors.join(' | ')}\n`);
  process.exitCode=1;
}finally{
  await browser.close();
  for(const server of servers)server.kill();
}
