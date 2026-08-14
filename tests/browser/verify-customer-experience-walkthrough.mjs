/* Customer-experience walkthrough — a CUSTOMER's end-to-end review, not an engineer's regression.
 *
 * Everything here is driven in a real Chrome against the REAL production bundles (app/index.html
 * plus the stamped chunks) served from a static directory, with the Supabase client replaced by an
 * in-page fixture — the same pattern as tests/browser/verify-v295-owner-fixes-walkthrough.mjs and
 * verify-v310-customer-stack-walkthrough.mjs.
 *
 * WHY THIS FILE EXISTS SEPARATELY FROM verify-v310-customer-stack-walkthrough.mjs
 * The v310 walkthrough's four-programme fixture is, by its own comment, "a FIXTURE of the
 * DESTINATION": it sets unit:'stamps', balance:6 and a 10-unit reward so that the two accruing
 * cards happen to agree. That dodges the exact question a customer asks at a firm that really does
 * run points AND stamps at once — what do the two cards say when the pot is a POINTS pot and the
 * gift costs 300? This file asks it with realistic numbers, and measures the answer.
 *
 * It reports rather than asserts. Every observation is printed as a MEASUREMENT with the number
 * behind it; a handful of hard invariants (no horizontal page scroll, no page errors) are asserted
 * because a customer would call those broken. Exit code is 0 when the hard invariants hold, so this
 * can run in a suite; the findings are the output.
 *
 * Journeys covered, in the order a customer lives them:
 *   J1  join a shop and land on the card                (scenario: newjoin)
 *   J2  see a balance without tapping anything          (time-to-first-number, all scenarios)
 *   J3  understand what you are earning toward          (multi / multi9 card legibility)
 *   J4  find and redeem a reward                        (multi, rewards host)
 *   J5  get and share a referral                        (multi)
 *   J6  come back after a gap and find the offer        (comeback)
 *   J7  open the app on a slow connection               (slow)
 *   J8  the page refreshes itself while you hold it     (refresh: silent-paint probe)
 *
 * Viewports: 390x844 FIRST (light, then dark), then 1440x900 (light, then dark).
 *
 * Prepare a stamped tree (the working tree is never written to), then run:
 *   node -e "…build…"                       # or point CUX_APP_DIR at app/ if it is already current
 *   PLAYWRIGHT_MODULE="…/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   CUX_APP_DIR="<scratch>/app" CUX_SHOTS="<scratch>/shots" \
 *   node tests/browser/verify-customer-experience-walkthrough.mjs
 */
import {spawn} from 'node:child_process';
import {mkdirSync, writeFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';

const playwright = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const chromium = playwright.chromium || playwright.default?.chromium;

const APP_DIR = process.env.CUX_APP_DIR || fileURLToPath(new URL('../../app/', import.meta.url));
const SHOTS = process.env.CUX_SHOTS || fileURLToPath(new URL('../../docs/qa/evidence/cux/', import.meta.url));
const PORT = Number(process.env.CUX_PORT || 4390);
const ORIGIN = `http://127.0.0.1:${PORT}`;
mkdirSync(SHOTS, {recursive: true});

const findings = [];
const measurements = [];
let step = '(boot)';
const say = name => {step = name; process.stdout.write(`\n=== ${name}\n`)};
const note = (label, value) => {
  measurements.push({step, label, value});
  process.stdout.write(`  · ${label}: ${typeof value === 'object' ? JSON.stringify(value) : value}\n`);
};
const flag = (severity, title, detail) => {
  findings.push({step, severity, title, detail});
  process.stdout.write(`  ${severity === 'BROKEN' ? '!!' : severity === 'HIGH' ? '! ' : '~ '} ${severity} — ${title}\n      ${detail}\n`);
};
const hard = [];
const mustHold = (condition, message) => {
  if (condition) {process.stdout.write(`  ok — ${message}\n`); return}
  hard.push(`${step}: ${message}`);
  process.stdout.write(`  FAIL — ${message}\n`);
};

/* ------------------------------------------------------------------ the Part D gate table
   Every row of the brief's acceptance table is recorded here with the value MEASURED in this run,
   and a failed row fails the walkthrough. `blocked` is for a row that cannot be closed without a
   server field that does not exist: it is reported with the contract needed, never as a pass. */
const gates = [];
const gate = (name, measured, must, ok, {blocked = false} = {}) => {
  gates.push({gate: name, now: measured, must, pass: ok === true, blocked, step});
  const mark = blocked ? 'BLOCKED' : ok ? 'GATE ok' : 'GATE FAIL';
  process.stdout.write(`  ${mark} — ${name}: measured ${typeof measured === 'object' ? JSON.stringify(measured) : measured} (must be ${must})\n`);
  if (!ok && !blocked) hard.push(`${step}: gate "${name}" measured ${JSON.stringify(measured)}, must be ${must}`);
};

/* ------------------------------------------------------------------ static server */
const servers = [];
const probe = async () => {
  try {
    const response = await fetch(`${ORIGIN}/index.html`);
    if (!response.ok) return false;
    /* Serving SOMETHING is not serving THIS app: sibling worktrees hold ports in this range. */
    return (await (await fetch(`${ORIGIN}/app-customer.js`)).text()).includes('customerProgrammeStackV310');
  } catch {return false}
};
const serverReady = async () => {
  if (await probe()) return;
  const server = spawn('python3', ['-m', 'http.server', String(PORT), '--bind', '127.0.0.1'], {cwd: APP_DIR, stdio: 'ignore'});
  server.on('error', error => process.stdout.write(`server spawn error: ${error}\n`));
  servers.push(server);
  for (let i = 0; i < 80; i++) {
    if (await probe()) return;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error(`static server did not start on ${ORIGIN}`);
};

/* ------------------------------------------------------------------ the fixture
   One generator, parameterised by scenario name baked in before boot. The shapes are written as a
   CUSTOMER would meet them, with the numbers a Singapore cafe or salon would actually set. */
const BIZ = 'c1111111-1111-4111-8111-111111111111';
const SLUG = 'hougang-abc';

const stubSource = (scenario, options = {}) => `(()=>{
  const SCENARIO=${JSON.stringify(scenario)};
  const OPTS=${JSON.stringify(options)};
  const BIZ='${BIZ}',SLUG='${SLUG}';
  const spine=on=>['points','tiers','stamps','referral'].map(kind=>({
    kind,active:false,customer_visible:false,running_since:null,paused_since:null,
    balance_scope:'business_pot',...(on[kind]||{})}));
  const RUN={active:true,customer_visible:true,running_since:'2026-02-01T00:00:00Z'};

  /* A four-rung ladder a cafe would really set, and the nine-rung one from the owner's screenshot. */
  const ladder=(labels,thresholds,currentIndex)=>labels.map((label,index)=>({
    label,threshold:thresholds[index],
    current:index===currentIndex,achieved:index<=currentIndex,
    benefits:index===0?['A warm welcome','Birthday treat']
      :index===1?['10% off every visit','Priority booking']
      :index===2?['15% off','A free treatment each year']:['20% off','Free monthly add-on']}));
  const tierOf=(labels,thresholds,currentIndex,metric,progress,basis='visits')=>({
    basis,metric,progress_percent:progress,points_mode:'both',
    current:currentIndex>=0?{label:labels[currentIndex],threshold:thresholds[currentIndex],
      benefits:['10% off every visit','Priority booking']}:null,
    next:currentIndex+1<labels.length?{label:labels[currentIndex+1],threshold:thresholds[currentIndex+1],
      benefits:['15% off','A free treatment each year']}:null,
    tiers:ladder(labels,thresholds,currentIndex)});

  /* The first rung costs 3 visits, not 0 — otherwise a zero-visit customer is already ON rung 1 and
     the "no tier yet" runway the v319 rail was built for never renders. A cafe that gives its
     opening tier away for free is not the interesting case. */
  const FOUR=['Explorer','Pioneer','Voyager','Legend'];
  const FOUR_AT=[3,10,30,60];
  const NINE=['Essentia','Bronze','Silver','Gold','Platinum','Diamond','Obsidian','Meridian','Founder'];
  const NINE_AT=[0,5,12,25,45,75,120,200,320];

  /* The heart of this review. A firm running points+gifts AND a stamp card AND a tier ladder AND
     referral, all at once — newly possible after the four-programme change. The pot is a POINTS
     pot (balance_scope 'business_pot', unit 'points'), which is what a cafe with a 10-pts-per-$
     earn rate and a 300-point flat white actually holds. */
  const SHAPES={
    multi:{
      programmes:spine({points:RUN,tiers:RUN,stamps:RUN,referral:RUN}),
      balance:240,unit:'points',
      reward:{name:'Free flat white',cost_units:300,remaining_units:60,available_now:false},
      tier:tierOf(FOUR,FOUR_AT,1,17,70)},
    multi9:{
      programmes:spine({points:RUN,tiers:RUN,stamps:RUN,referral:RUN}),
      balance:240,unit:'points',
      reward:{name:'Free flat white',cost_units:300,remaining_units:60,available_now:false},
      tier:tierOf(NINE,NINE_AT,3,31,42.8)},
    /* Two programmes whose figures could plausibly be independent once W5's pot split lands. */
    stampsonly:{
      programmes:spine({stamps:RUN,tiers:RUN,referral:RUN}),
      balance:6,unit:'stamps',
      reward:{name:'Free pastry',cost_units:10,remaining_units:4,available_now:false},
      tier:tierOf(FOUR,FOUR_AT,0,6,60)},
    newjoin:{
      programmes:spine({points:RUN,tiers:RUN,referral:RUN}),
      balance:0,unit:'points',
      reward:{name:'Free flat white',cost_units:300,remaining_units:300,available_now:false},
      tier:tierOf(FOUR,FOUR_AT,-1,0,0),brandNew:true},
    ready:{
      programmes:spine({points:RUN,tiers:RUN,referral:RUN}),
      balance:320,unit:'points',
      reward:{name:'Free flat white',cost_units:300,remaining_units:0,available_now:true},
      tier:tierOf(FOUR,FOUR_AT,1,17,70)},
    comeback:{
      programmes:spine({points:RUN,tiers:RUN,referral:RUN}),
      balance:240,unit:'points',
      reward:{name:'Free flat white',cost_units:300,remaining_units:60,available_now:false},
      tier:tierOf(FOUR,FOUR_AT,1,17,70),comeback:true},
    slow:{
      programmes:spine({points:RUN,tiers:RUN,stamps:RUN,referral:RUN}),
      balance:240,unit:'points',
      reward:{name:'Free flat white',cost_units:300,remaining_units:60,available_now:false},
      tier:tierOf(FOUR,FOUR_AT,1,17,70),delayMs:2600},
    refresh:{
      programmes:spine({points:RUN,tiers:RUN,referral:RUN}),
      balance:240,unit:'points',
      reward:{name:'Free flat white',cost_units:300,remaining_units:60,available_now:false},
      tier:tierOf(FOUR,FOUR_AT,1,17,70)},
    /* A firm that runs points and has published no reward at all: the honest arm of the
       first-visit moment ("nothing is in reach"), which must never be filled with an invented one. */
    noreward:{
      programmes:spine({points:RUN,tiers:RUN,referral:RUN}),
      balance:0,unit:'points',reward:null,
      tier:tierOf(FOUR,FOUR_AT,-1,0,0),brandNew:true}
  };
  const SHAPE=JSON.parse(JSON.stringify(SHAPES[SCENARIO]));
  /* The refresh probe mutates this from the test, exactly as the counter would. */
  window.__CUX={rpc:[],rpcAt:[],mutations:0,paints:0,live:SHAPE,delayMs:Number(OPTS.delayMs||SHAPE.delayMs||0)};

  const BUSINESS={id:BIZ,slug:SLUG,name:'Hougang ABC Cafe',currency:'SGD',industry:'Cafe',
    brand_color:'#7c5cff',review_url:null,
    address:'12 Hougang Ave 3, #01-14, Singapore 530012',phone:'+65 6555 0123'};
  /* OPTS.earn is the SERVER FIELD THAT DOES NOT EXIST YET — the earn-rate contract in the build
     report. The page must print nothing without it (no invented rate) and the honest line with it,
     so both arms are driven here rather than asserted from source. */
  const card=()=>({business:BUSINESS,
    loyalty:{enabled:true,balance:SHAPE.balance,unit:SHAPE.unit,credit_balance_cents:0,
      ...(OPTS.earn?{earn:OPTS.earn}:{})},
    credit:{},packages:{},next_eligible_reward:SHAPE.reward,visit_progress:{},birthday_benefit:null,
    expiry:SHAPE.brandNew?{}:{expiring_units:60,next_expiry_at:'2026-09-30T00:00:00Z',expiring_within_7_days:0},
    upcoming_appointments:{count:0}});
  const CAPS=()=>({wallet:true,rewards:true,tiers:true,points_mode:'both',activity:true,
    appointments:false,booking_request:false,packages:false,membership:false,
    programmes_contract:'v310',programmes:SHAPE.programmes});
  const PRESENTATION=()=>({locale:'en',brand:{hero_color:'#7c5cff'},
    programme:{name:'Hougang ABC Rewards',tagline:'Kopi that remembers you',unit:SHAPE.unit,
      balance:SHAPE.balance,tier:SHAPE.tier,benefits:[],offers:PROMOS()},
    catalogue:{rewards:[],products:[],services:[]},capabilities:{booking_enabled:false}});
  const PROMOS=()=>SHAPE.comeback?[{id:'11111111-2222-4333-8444-555555555555',
    name:'We miss you — 20% off your next cup',description:'Been a while. Here is 20% off anything on the menu.',
    terms:'One use. Dine-in or takeaway.',starts_at:'2026-08-01T00:00:00Z',ends_at:'2026-08-31T00:00:00Z',
    image_url:null,metadata:{offer_facts:'20% off · until 31 Aug'}}]:[];
  const GROWTH=()=>SHAPE.comeback?{offers:[{entitlement_id:'ent-1',status:'issued',
    label:'Welcome-back credit',type:'credit_cents',value_cents:500,currency:'SGD',
    issued_at:'2026-08-10T00:00:00Z',expires_at:'2026-09-10T00:00:00Z'}]}:{offers:[]};

  /* The two reward reads have DIFFERENT shapes in production, and the difference matters:
     customer_get_business_actions_v89 returns 'name' (coalesce(customer_name,name)) while
     customer_get_reward_catalog returns 'customer_name'. The v322 review found this fixture
     handing BOTH reads customer_name, so the merged row had no name at all and every reward
     rendered as the fallback word — which is exactly what the first measured run printed
     ("300 points → Reward"), a fixture artefact standing in for a real reward name.
     Availability is computed from the balance here too, so a 300-point gift at 240 points is
     "insufficient_balance" as the server would really answer. */
  /* A real cafe's shelf, not two rows: reward DENSITY is a gate ("≥4 visible per screen at 390"),
     and two rewards cannot measure it however tall each one is. */
  const CATALOG=()=>SHAPE.reward?[{name:SHAPE.reward.name,cost:SHAPE.reward.cost_units,description:'Any size, any day.'},
    {name:'Free croissant',cost:180,description:'Baked each morning.'},
    {name:'Free kaya toast',cost:150,description:'Charcoal grilled.'},
    {name:'Iced milo upsize',cost:120,description:'Any afternoon.'},
    {name:'Free cold brew',cost:360,description:'Steeped overnight.'},
    {name:'Tote bag',cost:900,description:'Canvas, printed here.'}]:[];
  const availabilityOf=cost=>SHAPE.balance>=cost?'available_at_counter':'insufficient_balance';
  const REWARD_ACTIONS=()=>CATALOG().map((item,index)=>({id:'rw'+(index+1),name:item.name,
    redemption_kind:'catalog_reward',cost_points:item.cost,availability:availabilityOf(item.cost)}));
  /* Everything a published reward really carries — terms, instructions, a claim window, an
     eligibility scope. Without them a reward CARD is two lines tall and the density this brief
     measures ("about two per screen") cannot be reproduced. */
  const REWARD_CATALOG=()=>CATALOG().map(item=>({customer_name:item.name,cost_points:item.cost,
    description:item.description,claim_method:'counter',availability:availabilityOf(item.cost),
    terms:'One per visit. Dine-in or takeaway. Not valid with other offers.',
    instructions:'Show this code at the counter before you order.',
    entitlement_expiry_days:30,
    eligibility:{branches:{scope:'all',count:0},services:{scope:'all',count:0},products:{scope:'all',count:0}}}));

  const DENIED={code:'42501',message:'not available'};
  const rpcData=name=>{
    switch(name){
      case 'get_customer_feature_capabilities':return {customer_identity:true,customer_wallet:true,
        customer_actions:true,customer_actionable_wallet:true,customer_phone_registration:true,
        customer_birthday_benefits:false,customer_in_app_inbox:false,customer_notifications:false};
      /* The surface reads its language from the PROFILE, not from a storage key — customerLocale is
         assigned from profile.preferred_language on boot. Driving it any other way would test
         nothing. */
      case 'customer_get_profile':return {profile:{full_name:'Mei Ling',birth_date:null,gender:null,
        preferred_language:String(OPTS.locale||'en')}};
      case 'get_my_personas':return {staff:[],customer:[{business_id:BIZ,business_slug:SLUG,
        business_name:BUSINESS.name}],default_route:'#/customer/programmes'};
      case 'customer_get_actionable_business':return {card:card()};
      case 'customer_get_actionable_wallet':return {cards:[card()]};
      case 'customer_get_wallet':return [card()];
      case 'customer_get_business_summary':return {business:BUSINESS,
        loyalty:{enabled:true,balance:SHAPE.balance,unit:SHAPE.unit,credit_balance_cents:0},
        packages:{},membership:{}};
      case 'customer_portal_capabilities':return CAPS();
      case 'customer_get_business_actions_v89':return {booking:{enabled:false},
        appointment_changes:{enabled:false},redemption:{enabled:true,classic:null},rewards:REWARD_ACTIONS()};
      case 'customer_get_business_presentation_v95':return PRESENTATION();
      case 'customer_get_effective_tier_v143':return {tier:SHAPE.tier};
      case 'customer_get_promotions_v155':return {items:PROMOS()};
      case 'customer_get_home_offers_v167':return {items:PROMOS().map(item=>({...item,
        business:{id:BIZ,slug:SLUG,name:BUSINESS.name}})),pending_redemption:null};
      case 'customer_get_reward_catalog':return {points_mode:'both',rewards:REWARD_CATALOG(),
        programmes_contract:'v310',balance_scope:'business_pot'};
      /* The redemption intent the counter really issues, so "one tap to QR" can be MEASURED as a
         QR on the screen rather than as a click that goes somewhere. */
      case 'customer_create_redemption_intent_v89':return {status:'pending',
        qr_token:'nestly:redemption:cux-token-1',expires_at:'2026-08-14T12:00:00Z'};
      case 'customer_get_referral_card_v300':
        return {enabled:true,code:'MEILING7',currency:'SGD',reward_cents:800,min_spend_cents:2000,
          referred_count:SHAPE.brandNew?0:2};
      case 'customer_get_growth_offers_v108':return GROWTH();
      case 'customer_get_transaction_history_v81':return {items:[]};
      case 'customer_get_booking_requests':return {items:[],truncated:false,next_cursor:null};
      case 'customer_get_programme_selector_media_v96':return {items:[]};
      case 'customer_get_loyalty_details':return {loyalty:{balance:SHAPE.balance,unit:SHAPE.unit},
        activity:[],expiry:{expiring_next_30_days:0,next_expiry_at:null}};
      case 'customer_record_account_open_v175':return {status:'ok'};
      default:return null;
    }
  };
  const SILENT=new Set(['customer_get_gift_cards','customer_get_packages','customer_get_memberships',
    'customer_get_appointments','customer_get_pending_promotion_prompt_v122','customer_get_member_code_v310']);

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
  const settle=value=>{
    const wait=Number(window.__CUX.delayMs||0);
    if(!wait)return value;
    return new Promise(resolve=>setTimeout(()=>resolve(value),wait));
  };
  const rpc=(name,args)=>{
    window.__CUX.rpc.push(name);
    window.__CUX.rpcAt.push({name,t:Math.round(performance.now())});
    if(SILENT.has(name))return chainable(()=>settle({data:null,error:DENIED}));
    return chainable(()=>settle({data:rpcData(name),error:null}));
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

  /* Hand the test a lever on the counter: bump the balance the way a sale would. */
  window.__cuxEarn=points=>{SHAPE.balance+=points;SHAPE.reward.remaining_units=
    Math.max(0,SHAPE.reward.cost_units-SHAPE.balance);
    SHAPE.reward.available_now=SHAPE.balance>=SHAPE.reward.cost_units;};
})();`;

/* ------------------------------------------------------------------ page helpers */
const browser = await chromium.launch({
  headless: true,
  executablePath: process.env.PLAYWRIGHT_EXECUTABLE_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
});
const pageErrors = [];

const open = async (scenario, {width = 390, height = 844, theme = null, hash = `#/wallet/${SLUG}`, wait = '.customer-programme-compact-head', options = {}} = {}) => {
  const context = await browser.newContext({viewport: {width, height}, bypassCSP: true, deviceScaleFactor: 2});
  await context.route('**/*', route => {
    const url = route.request().url();
    if (url.startsWith(ORIGIN) && !url.includes('/sw.js')) return route.continue();
    return route.abort();
  });
  /* Dark is the STORED customer preference; emulating prefers-color-scheme would prove something
     the surface does not read. */
  if (theme) await context.addInitScript(`try{localStorage.setItem('peekaa.customer.theme',${JSON.stringify(theme)})}catch{}`);
  await context.addInitScript(stubSource(scenario, options));
  const page = await context.newPage();
  page.on('pageerror', error => pageErrors.push(`${scenario}@${width}: ${error}`));
  const startedAt = Date.now();
  await page.goto(`${ORIGIN}/index.html${hash}`, {waitUntil: 'domcontentloaded'});
  if (wait) await page.waitForSelector(wait, {timeout: 30000});
  return {context, page, startedAt};
};

/* The one thing a customer looks for on opening: a number that is theirs. */
const firstNumberMs = page => page.evaluate(() => {
  const nav = performance.getEntriesByType('navigation')[0];
  const started = nav ? nav.startTime : 0;
  return Math.round(performance.now() - started);
});

const cardReport = page => page.evaluate(() => {
  const stack = document.querySelector('[data-programme-stack]');
  const cards = stack ? [...stack.children] : [];
  const px = node => {const r = node.getBoundingClientRect(); return {top: Math.round(r.top + window.scrollY), h: Math.round(r.height)}};
  return cards.map(node => {
    const kind = node.dataset.programmeCard || node.id || node.className;
    const text = (node.innerText || '').replace(/\s+/g, ' ').trim();
    const heading = node.querySelector('h2')?.innerText?.trim() || '';
    /* The WHOLE glyph, not a prefix: two different icons can share a long <svg …> opening tag. */
    const icon = (node.querySelector('h2 svg')?.outerHTML || '').replace(/\s+/g, '');
    const numbers = [...text.matchAll(/\b\d[\d,]*\b/g)].map(m => m[0]);
    return {kind, heading, iconSig: icon, iconLen: icon.length, text, numbers, ...px(node)};
  });
});

const overflowReport = page => page.evaluate(() => {
  const doc = document.documentElement;
  const spills = [];
  const vw = doc.clientWidth;
  for (const node of document.querySelectorAll('body *')) {
    const r = node.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    if (r.right > vw + 1 || r.left < -1) {
      const tag = `${node.tagName.toLowerCase()}${node.id ? '#' + node.id : ''}.${(node.className || '').toString().split(' ').filter(Boolean).slice(0, 2).join('.')}`;
      spills.push({node: tag, left: Math.round(r.left), right: Math.round(r.right), text: (node.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 40)});
    }
  }
  return {
    pageScrollsSideways: doc.scrollWidth > doc.clientWidth + 1,
    scrollWidth: doc.scrollWidth, clientWidth: doc.clientWidth,
    spills: spills.slice(0, 12)
  };
});

/* Anything the eye reads as clipped: a box whose content is wider/taller than its own frame. */
const clipReport = page => page.evaluate(() => {
  const out = [];
  for (const node of document.querySelectorAll('.customer-programme-stack *, .customer-tier-milestone, .customer-referral-card-v300 *')) {
    if (!node.childElementCount && node.scrollWidth > node.clientWidth + 1 && node.clientWidth > 0) {
      out.push({node: node.tagName.toLowerCase() + '.' + (node.className || '').toString().split(' ')[0],
        text: (node.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 48),
        scrollW: node.scrollWidth, clientW: node.clientWidth});
    }
  }
  return out.slice(0, 12);
});

const tapTargets = page => page.evaluate(() => {
  const small = [];
  for (const node of document.querySelectorAll('button, a[href], [role="button"], summary')) {
    const r = node.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    if (r.height < 44 || r.width < 44) small.push({
      node: node.tagName.toLowerCase() + (node.id ? '#' + node.id : ''),
      label: (node.innerText || node.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim().slice(0, 34),
      w: Math.round(r.width), h: Math.round(r.height)});
  }
  return small.slice(0, 14);
});

const shoot = async (page, name) => {
  await page.screenshot({path: `${SHOTS}/${name}.png`, fullPage: true});
  return `${SHOTS}/${name}.png`;
};

/* The acceptance captures: the FIRST SCREEN, which is the thing under review — a full-page image
   of a three-screen page shows nothing about what a customer meets at a counter. Written into the
   repo's evidence folder only when CUX_EVIDENCE points at one. */
const EVIDENCE = process.env.CUX_EVIDENCE || '';
const shootEvidence = async (page, name) => {
  if (!EVIDENCE) return '';
  await page.screenshot({path: `${EVIDENCE}/cux2-${name}.png`, fullPage: false});
  process.stdout.write(`  · capture: cux2-${name}.png\n`);
  return `${EVIDENCE}/cux2-${name}.png`;
};

/* How many reward rows a customer can read without scrolling, measured from the top of the list
   rather than from the top of the page — the question is the DENSITY of the list, and the list is
   never the first thing on the screen. */
const rewardsPerScreen = page => page.evaluate(() => {
  const rows = [...document.querySelectorAll('[data-reward-row-v322], .wallet-reward')];
  if (!rows.length) return {rows: 0, perScreen: 0, rowHeight: 0};
  const tops = rows.map(node => node.getBoundingClientRect().top + window.scrollY);
  const listTop = Math.min(...tops);
  const fits = rows.filter(node => {
    const r = node.getBoundingClientRect();
    return (r.top + window.scrollY) + r.height <= listTop + window.innerHeight;
  }).length;
  return {rows: rows.length, perScreen: fits,
    rowHeight: Math.round(rows[0].getBoundingClientRect().height)};
});

/* The SOLID red actions a customer can see right now. Red is the next action; everything else on
   this surface is text. Counted by what actually paints: a filled background, in the first screen. */
const primaryActionsOnScreen = page => page.evaluate(() => {
  /* The app's primary control paints `background:var(--grad)` — a coral GRADIENT — so a flat
     backgroundColor test finds nothing. Count anything that fills itself in the coral family,
     whether it does it with a colour or with a gradient; a ghost button has neither. */
  const coralish = value => {
    const groups = String(value || '').match(/rgba?\([^)]*\)/g) || [];
    return groups.some(group => {
      const parts = group.match(/[\d.]+/g) || [];
      const alpha = parts.length > 3 ? Number(parts[3]) : 1;
      const [r, g, b] = parts.map(Number);
      return alpha >= 0.6 && r > 120 && r > g + 40 && r > b + 40;
    });
  };
  const solid = node => {
    const style = getComputedStyle(node);
    return coralish(style.backgroundColor) || (style.backgroundImage !== 'none' && coralish(style.backgroundImage));
  };
  const out = [];
  for (const node of document.querySelectorAll('button, a[href], [role="button"]')) {
    const r = node.getBoundingClientRect();
    if (r.width < 8 || r.height < 8) continue;
    if (r.bottom <= 0 || r.top >= window.innerHeight) continue;
    if (!solid(node)) continue;
    out.push({label: (node.innerText || node.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim().slice(0, 30),
      top: Math.round(r.top), bg: getComputedStyle(node).backgroundColor});
  }
  return out;
});

/* A4: is the top of the scrolling surface protected from the status bar? Three facts, all read from
   the live page — the strip is sticky at the top, its backdrop is fully opaque, and its own rule
   asks for env(safe-area-inset-top). The last one is read out of the CSSOM (the rule the browser
   applied), not out of the source file. */
const statusBarGuard = page => page.evaluate(() => {
  const strip = document.querySelector('[data-wallet-strip-v322]');
  if (!strip) return {present: false};
  const style = getComputedStyle(strip);
  const bg = (style.backgroundColor || '').match(/[\d.]+/g) || [];
  const alpha = bg.length > 3 ? Number(bg[3]) : 1;
  let inset = '';
  for (const sheet of [...document.styleSheets]) {
    let rules = [];
    try {rules = [...sheet.cssRules]} catch {continue}
    for (const rule of rules) {
      if (!rule.selectorText || !rule.selectorText.includes('customer-wallet-strip-v322')) continue;
      const declared = rule.style.getPropertyValue('padding') || rule.style.getPropertyValue('padding-top');
      if (declared) inset = declared;
    }
  }
  window.scrollTo(0, 600);
  const stuck = strip.getBoundingClientRect();
  const atTop = document.elementFromPoint(Math.round(window.innerWidth / 2), 6);
  window.scrollTo(0, 0);
  return {present: true, position: style.position, top: style.top, alpha,
    inset, computedPaddingTop: style.paddingTop, stickyTop: Math.round(stuck.top),
    coveredWhenScrolled: !!atTop && (atTop === strip || strip.contains(atTop))};
});

try {
  await serverReady();

  /* ============================================================ J1/J2/J3 — the multi-programme shop */
  say('J3 · a shop running points+gifts AND stamps AND a tier ladder AND referral, at 390px');
  {
    const {context, page} = await open('multi');
    await page.waitForSelector('[data-programme-stack="v310"]', {timeout: 20000});
    await page.waitForSelector('#walletReferral', {timeout: 20000});
    const t = await firstNumberMs(page);
    note('time to a rendered card stack (ms, local, no network latency)', t);

    const cards = await cardReport(page);
    note('card order', cards.map(c => c.kind));
    note('card headings', cards.map(c => c.heading));
    for (const c of cards) note(`card "${c.kind}" height / numbers printed`, {h: c.h, numbers: c.numbers});

    /* Do two cards print the same number? */
    const accruing = cards.filter(c => c.kind === 'points' || c.kind === 'stamps');
    if (accruing.length === 2) {
      const shared = accruing[0].numbers.filter(n => accruing[1].numbers.includes(n));
      note('numbers printed by BOTH the stamps card and the points card', shared);
      if (shared.length) flag('BROKEN', 'Two cards print the same figure at a multi-programme shop',
        `stamps card numbers ${JSON.stringify(accruing[0].numbers)} vs points card ${JSON.stringify(accruing[1].numbers)}; overlap ${JSON.stringify(shared)}. `
        + `Both cards are handed the SAME loyalty.balance and the SAME next_eligible_reward by customerProgrammeStackV310.`);
      const stampText = accruing.find(c => c.kind === 'stamps')?.text || '';
      const pointsText = accruing.find(c => c.kind === 'points')?.text || '';
      note('stamps card text', stampText.slice(0, 220));
      note('points card text', pointsText.slice(0, 220));
      gate('duplicate figures across cards', shared.length ? shared : 'none', 'none', shared.length === 0);
      gate('stamp card unit', /\bpoints?\b/i.test(stampText) ? 'points' : 'stamps only',
        'stamps only', !/\bpoints?\b/i.test(stampText));
      if (/\bpoints\b/i.test(stampText)) flag('BROKEN', 'The Stamp card prints a POINTS figure',
        `Stamp card reads: "${stampText.slice(0, 160)}". customerStampTargetV310 returns 0 when the reward costs more than 24 units, so the ring row disappears and the card falls back to the raw pot balance labelled with the pot's unit — "points" — under a heading that says Stamp card.`);
      const stampsMentionsSameGift = /Free flat white/.test(stampText) && /Free flat white/.test(pointsText);
      if (stampsMentionsSameGift) flag('HIGH', 'Both accruing cards name the same reward as the target',
        `"Free flat white" is the goal on the Stamp card and on the Points & gifts card. A customer reads two ways to earn one coffee.`);
    }

    /* Icons: pictogram-first means two cards must not wear the same glyph. */
    const iconGroups = {};
    for (const c of cards) if (c.iconSig) (iconGroups[c.iconSig] ||= []).push(c.kind);
    const dupIcons = Object.values(iconGroups).filter(g => g.length > 1);
    note('pictogram byte-length per card', cards.map(c => ({kind: c.kind, len: c.iconLen})));
    note('cards sharing one pictogram (full svg compared)', dupIcons);
    gate('distinct pictograms per programme', dupIcons.length ? JSON.stringify(dupIcons) : 'all distinct',
      'all distinct', dupIcons.length === 0);
    if (dupIcons.length) flag('HIGH', 'Two programme cards wear the same pictogram',
      `${JSON.stringify(dupIcons)} carry a byte-identical <svg> in their heading. The house rule is pictogram-first for low-literacy customers; identical glyphs make the stack read as one repeated card.`);

    /* The card named "Points & gifts" — does it actually contain the gifts? */
    const giftsHost = await page.evaluate(() => {
      const host = document.getElementById('walletRewards');
      if (!host) return null;
      return {insideCard: host.closest('[data-programme-card]')?.dataset.programmeCard || '(outside the stack)',
        headingOfThatCard: host.closest('[data-programme-card]')?.querySelector('h2')?.innerText?.trim() || ''};
    });
    note('which card hosts the gift catalogue', giftsHost);
    gate('gifts host card', giftsHost?.insideCard || '(none)', 'points', giftsHost?.insideCard === 'points');
    if (giftsHost && giftsHost.insideCard !== 'points') flag('BROKEN',
      'The card headed "Points & gifts" contains no gifts — they are under the Stamp card',
      `#walletRewards renders inside data-programme-card="${giftsHost.insideCard}" (heading "${giftsHost.headingOfThatCard}"). `
      + `customerProgrammeStackV310 gives the gifts host to stamps whenever a stamps programme is active, on the assumption (from the v308 tripwire) that points and stamps can never both be live — which is precisely what the four-programme change now allows.`);

    const over = await overflowReport(page);
    note('390px horizontal overflow', over);
    mustHold(!over.pageScrollsSideways, 'the page does not scroll sideways at 390px');
    gate('horizontal scroll @390', over.pageScrollsSideways ? `${over.scrollWidth}px > ${over.clientWidth}px` : 'none',
      'none', !over.pageScrollsSideways);
    if (over.spills.length) flag('HIGH', 'Elements extend past the right edge at 390px',
      JSON.stringify(over.spills));

    /* A4 — the status bar. */
    const guard = await statusBarGuard(page);
    note('the top of the scrolling surface', guard);
    const insetOk = guard.present && /env\(safe-area-inset-top\)/.test(String(guard.inset || ''))
      && guard.alpha === 1 && guard.position === 'sticky' && guard.coveredWhenScrolled;
    gate('status-bar collision @390', insetOk ? 'none (opaque sticky strip, inset ≥ safe-area)'
      : JSON.stringify(guard), 'none (inset ≥ safe-area)', insetOk);

    /* C2 — reward density and the one-red-action rule. */
    const density = await rewardsPerScreen(page);
    note('reward rows, and how many fit one screen', density);
    gate('rewards visible per screen @390', density.perScreen, '≥4', density.perScreen >= 4);
    const primaries = await primaryActionsOnScreen(page);
    note('solid red actions in the first screen', primaries);
    gate('primary (solid red) actions on screen @390', primaries.length, 'exactly 1', primaries.length === 1);

    /* A5/C3 — the rail is gone from the phone card. */
    const markers = await page.evaluate(() =>
      document.querySelectorAll('[data-programme-card="tiers"] .customer-tier-milestone').length);
    note('tier markers on the phone card', markers);
    gate('tier markers on the phone card', markers, '0 (badge+bar+sentence)', markers === 0);

    const clipped = await clipReport(page);
    note('clipped text inside the stack', clipped);
    if (clipped.length) flag('MEDIUM', 'Text is clipped inside the programme cards at 390px', JSON.stringify(clipped));

    const scrolls = await page.evaluate(() => {
      const stack = document.querySelector('[data-programme-stack]');
      const doc = document.documentElement;
      return {stackScreens: +(stack.getBoundingClientRect().height / window.innerHeight).toFixed(2),
        pageScreens: +(doc.scrollHeight / window.innerHeight).toFixed(2)};
    });
    note('thumb-scrolls', scrolls);
    if (scrolls.pageScreens > 4) flag('MEDIUM', 'The programme page is long on a phone',
      `${scrolls.pageScreens} screens of scroll at 390x844 before anything is expanded.`);

    const small = await tapTargets(page);
    note('controls under 44px', small);

    await shoot(page, 'cux-multi-390-light');
    await shootEvidence(page, 'shop-390');
    await context.close();
  }

  say('J3b · the same shop in the customer’s stored dark theme, 390px');
  {
    const {context, page} = await open('multi', {theme: 'dark'});
    await page.waitForSelector('[data-programme-stack="v310"]', {timeout: 20000});
    await page.waitForSelector('#walletReferral', {timeout: 20000});
    const themed = await page.evaluate(() => document.documentElement.getAttribute('data-customer-theme'));
    mustHold(themed === 'dark', 'the stored peekaa.customer.theme drives the dark surface');
    const contrast = await page.evaluate(() => {
      const lum = rgb => {
        const [r, g, b] = rgb.match(/[\d.]+/g).slice(0, 3).map(Number).map(v => {
          const s = v / 255; return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
        });
        return 0.2126 * r + 0.7152 * g + 0.0722 * b;
      };
      const bgOf = node => {
        let el = node;
        while (el) {
          const bg = getComputedStyle(el).backgroundColor;
          if (bg && !/rgba\(0, 0, 0, 0\)|transparent/.test(bg)) return bg;
          el = el.parentElement;
        }
        return 'rgb(255,255,255)';
      };
      const out = [];
      for (const sel of ['.customer-programme-card-line-v310', '.customer-tier-remaining', '.customer-referral-code', '.customer-tier-now', '.customer-programme-balance']) {
        const node = document.querySelector(sel);
        if (!node) continue;
        const fg = getComputedStyle(node).color, bg = bgOf(node);
        const l1 = lum(fg), l2 = lum(bg);
        out.push({sel, ratio: +(((Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05))).toFixed(2), fg, bg});
      }
      return out;
    });
    note('dark-theme contrast ratios', contrast);
    for (const c of contrast) if (c.ratio < 4.5) flag('MEDIUM', `Low contrast in dark theme: ${c.sel}`,
      `${c.ratio}:1 (${c.fg} on ${c.bg}); WCAG AA body text wants 4.5:1.`);
    const over = await overflowReport(page);
    mustHold(!over.pageScrollsSideways, 'dark 390px does not scroll sideways');
    await shoot(page, 'cux-multi-390-dark');
    await shootEvidence(page, 'shop-390-dark');
    await context.close();
  }

  say('J3c · the same shop at 1440, light and dark');
  {
    const {context, page} = await open('multi', {width: 1440, height: 900});
    await page.waitForSelector('#walletReferral', {timeout: 20000});
    const layout = await page.evaluate(() => {
      const stack = document.querySelector('[data-programme-stack]');
      const cs = getComputedStyle(stack);
      const r = stack.getBoundingClientRect();
      const shell = document.querySelector('main')?.getBoundingClientRect();
      return {columns: cs.gridTemplateColumns, stackWidth: Math.round(r.width),
        mainWidth: shell ? Math.round(shell.width) : null, viewport: window.innerWidth,
        cardHeights: [...stack.children].map(n => Math.round(n.getBoundingClientRect().height))};
    });
    note('1440 layout of the stack', layout);
    const columns = String(layout.columns || '').trim().split(/\s+/).filter(Boolean).length;
    gate('1440 layout', `${columns} column${columns === 1 ? '' : 's'} (${layout.columns})`,
      '2 columns \u22651024px', columns === 2);
    if (/^\s*[\d.]+px\s*$/.test(layout.columns)) flag('MEDIUM', 'The card stack stays a single narrow column at 1440',
      `grid-template-columns is "${layout.columns}" — the same one-up phone stack, ${layout.stackWidth}px wide inside a ${layout.viewport}px window. Four cards become four screens of scrolling on a desktop that could show them side by side.`);
    const over = await overflowReport(page);
    mustHold(!over.pageScrollsSideways, '1440 does not scroll sideways');
    gate('horizontal scroll @1440', over.pageScrollsSideways ? 'yes' : 'none', 'none', !over.pageScrollsSideways);
    const wideDensity = await rewardsPerScreen(page);
    note('reward rows stay one per line inside their card at 1440', wideDensity);
    await shoot(page, 'cux-multi-1440-light');
    await shootEvidence(page, 'shop-1440');
    await context.close();
  }
  {
    const {context, page} = await open('multi', {width: 1440, height: 900, theme: 'dark'});
    await page.waitForSelector('#walletReferral', {timeout: 20000});
    await shoot(page, 'cux-multi-1440-dark');
    await context.close();
  }

  /* ============================================================ the owner's squeeze: nine rungs */
  say('J3d · the owner’s nine-rung ladder (the "UI UX is being squeezed" screenshot), 390px');
  {
    const {context, page} = await open('multi9');
    await page.waitForSelector('[data-programme-stack="v310"]', {timeout: 20000});
    const rail = await page.evaluate(() => {
      const bar = document.querySelector('.customer-tier-bar');
      if (!bar) return null;
      const barRect = bar.getBoundingClientRect();
      const markers = [...bar.querySelectorAll('.customer-tier-milestone')].map(node => {
        const r = node.getBoundingClientRect();
        return {left: +(r.left - barRect.left).toFixed(1), right: +(r.right - barRect.left).toFixed(1),
          w: Math.round(r.width), label: node.querySelector('b')?.innerText || '(icon only)'};
      });
      const fillWidth = bar.querySelector('.customer-tier-bar-track span')?.style.width || '';
      let overlaps = 0;
      for (let i = 1; i < markers.length; i++) if (markers[i].left < markers[i - 1].right - 0.5) overlaps++;
      return {compact: bar.classList.contains('is-compact'), barWidth: Math.round(barRect.width),
        fillWidth, markers, overlaps,
        spillRight: +(markers.length ? markers[markers.length - 1].right - barRect.width : 0).toFixed(1),
        spillLeft: +(markers.length ? -markers[0].left : 0).toFixed(1)};
    });
    note('nine-rung tier rail', rail);
    if (rail?.overlaps) flag('HIGH', 'Tier rail markers still overlap at nine rungs',
      `${rail.overlaps} of ${rail.markers.length} markers overlap the one before it inside a ${rail.barWidth}px bar.`);
    if (rail && rail.spillRight > 2) flag('MEDIUM', 'The last tier marker hangs off the right end of the rail',
      `it ends ${rail.spillRight}px past the track. Each marker is translateX(-50%) at left:(i+1)/count, so the final one is centred on 100% and half of it sits outside the bar.`);
    const over = await overflowReport(page);
    note('390px overflow with nine rungs', over);
    mustHold(!over.pageScrollsSideways, 'nine rungs do not push the page sideways');
    await shoot(page, 'cux-nine-rungs-390-light');
    await shootEvidence(page, 'nine-tiers-390');
    await context.close();
  }

  /* ============================================================ J1 — brand-new joiner */
  say('J1/J2 · a customer who joined today and has earned nothing');
  {
    const {context, page} = await open('newjoin');
    await page.waitForSelector('[data-programme-stack="v310"]', {timeout: 20000});
    const cards = await cardReport(page);
    note('what the brand-new customer is shown', cards.map(c => ({kind: c.kind, text: c.text.slice(0, 170)})));
    const pointsCard = cards.find(c => c.kind === 'points');
    if (pointsCard && /^\s*Points & gifts 0\b/.test(pointsCard.text)) note('opening figure', '0 points, printed large');
    const tierCard = cards.find(c => c.kind === 'tiers');
    note('tier card on day one', tierCard?.text.slice(0, 200));
    const earnRateShown = await page.evaluate(() =>
      /\b(per|every|each)\b[^.]{0,40}\$|\bearn\b[^.]{0,40}\bpoints?\b/i.test(document.body.innerText));
    note('does the page say HOW you earn (a rate, not just a target)?', earnRateShown);
    if (!earnRateShown) flag('HIGH', 'A new customer is never told how earning works',
      'The stack shows a balance and a distance to a gift, but nothing states the earn rate ("10 points per $1"), so a customer at 0 cannot tell whether the gift is one visit away or twenty.');
    await shoot(page, 'cux-newjoin-390-light');
    await context.close();
  }

  /* ============================================================ J4 — find and redeem */
  say('J4 · finding and redeeming a reward');
  {
    const {context, page} = await open('multi');
    await page.waitForSelector('[data-programme-stack="v310"]', {timeout: 20000});
    const rewardsHost = await page.evaluate(() => {
      const host = document.getElementById('walletRewards');
      if (!host) return null;
      const card = host.closest('[data-programme-card]');
      return {insideCard: card?.dataset.programmeCard || null,
        text: (host.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 240)};
    });
    note('where the gift catalogue lives, and what it says', rewardsHost);
    await page.waitForTimeout(1200);
    const afterLoad = await page.evaluate(() => {
      const host = document.getElementById('walletRewards');
      return host ? {busy: host.getAttribute('aria-busy'), text: (host.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 300),
        buttons: [...host.querySelectorAll('button,a')].map(b => (b.innerText || '').trim()).slice(0, 6)} : null;
    });
    note('gift catalogue after hydration', afterLoad);
    if (afterLoad && /Loading/.test(afterLoad.text)) flag('HIGH', 'The gift catalogue never finishes loading',
      `#walletRewards still reads "${afterLoad.text.slice(0, 80)}" after hydration.`);
    await context.close();
  }
  {
    const {context, page} = await open('ready');
    await page.waitForSelector('[data-programme-stack="v310"]', {timeout: 20000});
    const strip = await page.evaluate(() => {
      const node = document.getElementById('customerClaimableStripV310');
      const stack = document.querySelector('[data-programme-stack]');
      return node ? {text: node.innerText.replace(/\s+/g, ' ').trim(),
        aboveStack: node.getBoundingClientRect().top < stack.getBoundingClientRect().top,
        isButton: node.tagName === 'BUTTON' || !!node.querySelector('button,a')} : null;
    });
    note('"Ready now" strip when a gift is claimable', strip);
    if (strip && !strip.isButton) flag('HIGH', 'The "Ready now" strip announces a claimable gift but cannot be tapped',
      `It renders "${strip.text}" as a static role="status" band with no button or link. The one moment the customer wants an action, the banner is a label.`);

    /* ONE TAP. Not "is it a button" — press the row a customer would press and see whether a QR
       the counter could scan is on the screen afterwards. */
    await page.waitForTimeout(1200);                       // the catalogue the row points into
    const tapped = await page.evaluate(() => {
      const row = document.querySelector('#customerClaimableStripV310 [data-cux-claim-v322]');
      if (!row) return {tapped: false};
      row.click();
      return {tapped: true, label: (row.innerText || '').replace(/\s+/g, ' ').trim()};
    });
    await page.waitForTimeout(900);
    const qr = await page.evaluate(() => {
      const modal = document.querySelector('.modal');
      if (!modal) return {open: false};
      return {open: true, text: (modal.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 160),
        hasQrHost: !!modal.querySelector('canvas, img, [id*="Qr"], [id*="qr"]')};
    });
    note('one tap on the Ready row', {tapped, qr});
    gate('"Ready now" tappable', qr.open ? 'one tap to QR' : 'no', 'one tap to QR', qr.open === true);
    await shoot(page, 'cux-ready-390-light');
    await shootEvidence(page, 'ready-qr-390');
    await context.close();
  }

  /* ============================================================ J5 — referral */
  say('J5 · getting and sharing a referral code');
  {
    const {context, page} = await open('multi');
    await page.waitForSelector('#walletReferral', {timeout: 20000});
    const referral = await page.evaluate(() => {
      const node = document.getElementById('walletReferral');
      const stack = document.querySelector('[data-programme-stack]');
      const r = node.getBoundingClientRect();
      return {text: node.innerText.replace(/\s+/g, ' ').trim(),
        topPx: Math.round(r.top + window.scrollY),
        screensDown: +((r.top + window.scrollY) / window.innerHeight).toFixed(2),
        buttons: [...node.querySelectorAll('button')].map(b => ({label: b.innerText.trim(),
          w: Math.round(b.getBoundingClientRect().width), h: Math.round(b.getBoundingClientRect().height)})),
        insideStack: stack.contains(node),
        looksLikeOtherCards: node.classList.contains('customer-programme-card-v310')};
    });
    note('referral card', referral);
    if (referral.screensDown > 1.5) flag('MEDIUM', 'The referral invitation is far below the fold',
      `It starts ${referral.screensDown} screens down at 390px. The single highest-leverage growth action on the customer surface is the one thing a customer has to scroll past three cards to find.`);
    if (!referral.looksLikeOtherCards) note('referral card uses a different card class from the three programme cards',
      'wallet-section + customer-referral-card-v300 rather than customer-programme-card-v310');
    const money = /SGD\s*8\.00/.test(referral.text);
    note('does the referral card state the reward in money?', money);
    const whoGetsWhat = /you\b[^.]*\bthey\b|friend/i.test(referral.text);
    note('does it say who gets what?', whoGetsWhat);
    if (!whoGetsWhat) flag('MEDIUM', 'The referral card does not say who gets the reward',
      `It reads "${referral.text.slice(0, 150)}" — a customer cannot tell whether the SGD 8.00 lands with them, their friend, or both.`);
    await context.close();
  }

  /* ============================================================ J6 — the bring-back offer */
  say('J6 · coming back after a gap — is the bring-back offer findable?');
  {
    const {context, page} = await open('comeback');
    await page.waitForSelector('[data-programme-stack="v310"]', {timeout: 20000});
    await page.waitForTimeout(1500);
    const offers = await page.evaluate(() => {
      const promo = document.querySelector('[data-promotion-id]');
      const growth = document.getElementById('walletGrowthOffers');
      const pos = node => node ? +((node.getBoundingClientRect().top + window.scrollY) / window.innerHeight).toFixed(2) : null;
      return {
        promoText: promo ? promo.innerText.replace(/\s+/g, ' ').trim().slice(0, 180) : null,
        promoScreensDown: pos(promo),
        growthText: growth ? growth.innerText.replace(/\s+/g, ' ').trim().slice(0, 200) : null,
        growthScreensDown: pos(growth),
        pageScreens: +(document.documentElement.scrollHeight / window.innerHeight).toFixed(2)};
    });
    note('bring-back surfaces on the programme page', offers);
    const stripOffer = await page.evaluate(() => {
      const slot = document.getElementById('customerWalletStripSlotV322');
      const button = slot?.querySelector('[data-cux-strip-offer-v322]');
      const strip = document.querySelector('[data-wallet-strip-v322]');
      return {inStrip: !!button, label: (button?.innerText || '').replace(/\s+/g, ' ').trim(),
        screensDown: strip ? +((strip.getBoundingClientRect().top + window.scrollY) / window.innerHeight).toFixed(2) : null};
    });
    note('the welcome-back credit in the top strip', stripOffer);
    gate('bring-back credit on the first screen', stripOffer.inStrip ? `in the strip: "${stripOffer.label}"` : 'buried',
      'in the wallet strip', stripOffer.inStrip === true && stripOffer.screensDown !== null && stripOffer.screensDown < 1);
    if (offers.growthScreensDown !== null && offers.growthScreensDown > 2)
      flag('HIGH', 'The welcome-back credit is buried below every programme card',
        `The SGD 5.00 credit the business paid to bring this customer back sits ${offers.growthScreensDown} screens down, under the tier ladder, the points card and the referral card. On a ${offers.pageScreens}-screen page a returning customer will not see it.`);
    if (offers.promoScreensDown !== null && offers.promoScreensDown > 1.6)
      flag('MEDIUM', 'The "We miss you" promotion is below the fold on the shop page',
        `starts ${offers.promoScreensDown} screens down.`);
    await shoot(page, 'cux-comeback-390-light');
    await shootEvidence(page, 'bring-back-390');

    /* Home is the other place a returning customer lands. */
    await context.close();
  }
  {
    const {context, page} = await open('comeback', {hash: '#/wallet', wait: '#walletBody'});
    await page.waitForTimeout(1800);
    const home = await page.evaluate(() => ({
      text: (document.getElementById('walletBody')?.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 400),
      offerCards: document.querySelectorAll('[data-promotion-id]').length,
      screens: +(document.documentElement.scrollHeight / window.innerHeight).toFixed(2)}));
    note('customer Home on return', home);
    await shoot(page, 'cux-comeback-home-390-light');
    await context.close();
  }

  /* ============================================================ J7 — slow connection */
  say('J7 · opening the app on a slow connection (every read 2.6s)');
  {
    const {context, page, startedAt} = await open('slow', {wait: null});
    const frames = [];
    for (const at of [400, 900, 1600, 2600, 4000, 6000]) {
      const elapsed = Date.now() - startedAt;
      if (elapsed < at) await page.waitForTimeout(at - elapsed);
      frames.push({at, text: (await page.evaluate(() => (document.body.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 120)))});
    }
    note('what the screen says over the first six seconds', frames);
    const stillBlank = frames.filter(f => f.at <= 2600 && (!f.text || /^\s*$/.test(f.text)));
    if (stillBlank.length) flag('HIGH', 'The screen is blank for the first seconds on a slow connection',
      JSON.stringify(stillBlank));
    const loadingCopy = frames.map(f => f.text).join(' | ');
    if (/Loading Peekaa/.test(loadingCopy)) note('the interim state says', '"Loading Peekaa…" — a brand name, not a skeleton of the card that is coming');
    await shoot(page, 'cux-slow-390-light');
    /* Then let it land, and check nothing broke. */
    await page.waitForSelector('[data-programme-stack="v310"]', {timeout: 30000});
    const rpcCount = await page.evaluate(() => window.__CUX.rpc.length);
    note('reads issued to render one shop page', rpcCount);
    const rpcNames = await page.evaluate(() => window.__CUX.rpc);
    note('the read list', rpcNames);
    const dupes = Object.entries(rpcNames.reduce((acc, n) => (acc[n] = (acc[n] || 0) + 1, acc), {})).filter(([, n]) => n > 1);
    note('reads issued more than once for one page', dupes);
    const actionsCalls = rpcNames.filter(name => name === 'customer_get_business_actions_v89').length;
    gate('duplicate RPC per page load', `actions_v89 \u00d7${actionsCalls}`, 'actions_v89 \u00d71', actionsCalls === 1);
    if (dupes.length) flag('MEDIUM', 'The shop page asks the server for the same thing more than once',
      JSON.stringify(dupes));
    await context.close();
  }

  /* ============================================================ J8 — the silent refresh */
  say('J8 · the refresh that is supposed to be seamless');
  {
    const {context, page} = await open('refresh');
    await page.waitForSelector('[data-programme-stack="v310"]', {timeout: 20000});
    await page.waitForTimeout(1500);           // let every section hydrate

    /* Instrument the body exactly as a customer experiences it: how often does the thing under my
       thumb get replaced, and does what I was reading survive? */
    await page.evaluate(() => {
      window.__probe = {bodyReplacements: 0, skeletonReturns: 0, log: []};
      const host = document.getElementById('walletBody');
      const observer = new MutationObserver(records => {
        for (const record of records) {
          if (record.target === host && record.type === 'childList' && record.removedNodes.length > 2) {
            window.__probe.bodyReplacements++;
            window.__probe.log.push({at: Math.round(performance.now()), removed: record.removedNodes.length, added: record.addedNodes.length});
          }
        }
        if (document.querySelector('.wallet-skeleton') || /Loading/.test(document.getElementById('walletBody')?.innerText || ''))
          window.__probe.skeletonReturns++;
      });
      observer.observe(host, {childList: true, subtree: true});
      window.__probeStop = () => observer.disconnect();
    });

    /* Scroll to where a customer would be reading, and open the History disclosure. */
    await page.evaluate(() => {
      const details = document.getElementById('walletHistoryDisclosure');
      if (details) details.open = true;
    });
    await page.evaluate(() => window.scrollTo(0, 700));
    await page.waitForTimeout(200);
    const before = await page.evaluate(() => ({
      scroll: Math.round(window.scrollY),
      historyOpen: document.getElementById('walletHistoryDisclosure')?.open === true,
      balance: document.querySelector('.customer-programme-balance')?.innerText.replace(/\s+/g, ' ').trim(),
      rpc: window.__CUX.rpc.length}));
    note('before the tick', before);

    /* (a) NOTHING CHANGED. The foreground listener is the real code path; firing visibilitychange
           runs exactly what returning to the app runs. */
    await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
    await page.waitForTimeout(900);
    const quiet = await page.evaluate(() => ({
      bodyReplacements: window.__probe.bodyReplacements,
      scroll: Math.round(window.scrollY),
      historyOpen: document.getElementById('walletHistoryDisclosure')?.open === true,
      rpcSinceRender: window.__CUX.rpc.length}));
    note('after a tick with NOTHING changed', quiet);
    const idleReads = quiet.rpcSinceRender - before.rpc;
    note('reads spent on a tick that changed nothing', idleReads);
    gate('RPCs per idle 20s tick', idleReads, '\u22642 until the signature moves', idleReads <= 2);
    mustHold(quiet.bodyReplacements === 0, 'a no-change refresh does not touch the DOM');
    mustHold(quiet.scroll === before.scroll, 'a no-change refresh holds the scroll position');
    mustHold(quiet.historyOpen === true, 'a no-change refresh leaves the History disclosure open');
    if (quiet.rpcSinceRender - before.rpc > 6) flag('MEDIUM', 'A background tick costs a full page of reads',
      `${quiet.rpcSinceRender - before.rpc} RPCs every 20 seconds for up to nine ticks, plus one on every return to the foreground, on a customer's mobile data — to change nothing at all in the common case.`);

    /* (b) THE COUNTER MOMENT. Points land while the customer is holding the phone. */
    await page.evaluate(() => window.__cuxEarn(30));
    const changedAt = await page.evaluate(() => {
      window.__probe.bodyReplacements = 0; window.__probe.skeletonReturns = 0; window.__probe.log = [];
      return performance.now();
    });
    await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
    /* Watch frame by frame for the flash. */
    const flashFrames = [];
    for (let i = 0; i < 14; i++) {
      await page.waitForTimeout(120);
      flashFrames.push(await page.evaluate(() => ({
        skeletons: document.querySelectorAll('.wallet-skeleton').length,
        loadingText: /Loading/.test(document.getElementById('walletBody')?.innerText || ''),
        balance: document.querySelector('.customer-programme-balance')?.innerText.replace(/\s+/g, ' ').trim(),
        scroll: Math.round(window.scrollY),
        historyOpen: document.getElementById('walletHistoryDisclosure')?.open === true,
        height: document.documentElement.scrollHeight})));
    }
    const after = await page.evaluate(() => ({
      bodyReplacements: window.__probe.bodyReplacements,
      log: window.__probe.log,
      scroll: Math.round(window.scrollY),
      historyOpen: document.getElementById('walletHistoryDisclosure')?.open === true,
      balance: document.querySelector('.customer-programme-balance')?.innerText.replace(/\s+/g, ' ').trim()}));
    note('after the balance really moved', after);
    note('frames during the repaint (skeletons / scroll / height)',
      flashFrames.map(f => ({sk: f.skeletons, ld: f.loadingText ? 1 : 0, bal: f.balance, y: f.scroll, h: f.height})));

    const peakSkeletons = Math.max(...flashFrames.map(f => f.skeletons));
    note('peak skeletons visible during a "seamless" repaint', peakSkeletons);
    const heights = flashFrames.map(f => f.height);
    const collapse = Math.max(...heights) - Math.min(...heights);
    note('document height range during the repaint', {min: Math.min(...heights), max: Math.max(...heights), collapse});
    gate('change-tick skeleton flash', `${peakSkeletons} shells, ${collapse}px collapse`, '0 shells, 0 collapse',
      peakSkeletons === 0 && collapse === 0);
    if (peakSkeletons > 0) flag('HIGH', 'The one refresh that matters DOES flash the page back to skeletons',
      `When the signature changes — the exact moment the feature exists for — customerWalletSilentPaintV319 replaces the whole wallet body with markup that still contains walletSectionShell() placeholders, so ${peakSkeletons} skeleton blocks reappear and every section re-hydrates. The no-change tick is invisible; the change tick is the old flicker.`);

    const historyDropped = flashFrames.some(f => f.historyOpen === false);
    if (historyDropped) flag('HIGH', 'The open History disclosure closes on a repaint',
      'openDisclosures are restored by index, but the re-emitted markup can differ in <details> count/order.');
    const scrollMoved = flashFrames.filter(f => Math.abs(f.scroll - before.scroll) > 8);
    note('frames whose scroll moved more than 8px', scrollMoved.map(f => ({y: f.scroll, h: f.height})));
    if (scrollMoved.length) flag('HIGH', 'The customer’s scroll position is lost during the repaint',
      `scrollTop is restored synchronously right after innerHTML, but the sections re-hydrate afterwards and the page is shorter in between, so the browser clamps the restored offset. Observed: ${JSON.stringify(scrollMoved.slice(0, 4))}`);

    const sawNewBalance = flashFrames.some(f => f.balance && f.balance !== before.balance);
    mustHold(sawNewBalance, 'the new balance does appear without the customer doing anything');
    const firstNew = flashFrames.findIndex(f => f.balance && f.balance !== before.balance);
    note('frames (120ms each) until the new balance was on screen', firstNew >= 0 ? firstNew + 1 : 'never');

    await page.evaluate(() => window.__probeStop && window.__probeStop());
    await shoot(page, 'cux-refresh-390-light');
    await context.close();
  }

  /* ============================================================ the tier rail, read as designed? */
  say('J3e · does the tier rail read as designed, or as a moved div?');
  {
    const {context, page} = await open('multi');
    await page.waitForSelector('[data-programme-card="tiers"]', {timeout: 20000});
    const rail = await page.evaluate(() => {
      const bar = document.querySelector('.customer-tier-bar');
      const barRect = bar.getBoundingClientRect();
      const fill = bar.querySelector('.customer-tier-bar-track span');
      const fillRect = fill.getBoundingClientRect();
      const markers = [...bar.querySelectorAll('.customer-tier-milestone')].map(node => {
        const r = node.getBoundingClientRect();
        return {label: node.querySelector('b')?.innerText || '(icon)', centre: +(r.left + r.width / 2 - barRect.left).toFixed(1),
          current: node.classList.contains('is-current'), achieved: node.classList.contains('is-achieved')};
      });
      const card = document.querySelector('[data-programme-card="tiers"]');
      return {barWidth: Math.round(barRect.width), fillEndsAt: Math.round(fillRect.width),
        fillPercent: +((fillRect.width / barRect.width) * 100).toFixed(1),
        markers, cardText: card.innerText.replace(/\s+/g, ' ').trim().slice(0, 260),
        cardTop: Math.round(card.getBoundingClientRect().top + window.scrollY),
        firstScreen: card.getBoundingClientRect().top < window.innerHeight};
    });
    note('tier rail geometry', rail);
    const currentMarker = rail.markers.find(m => m.current);
    if (currentMarker) {
      const ahead = rail.fillEndsAt - currentMarker.centre;
      note('fill end relative to the marker the customer is standing on (px)', Math.round(ahead));
      if (ahead < 0) flag('HIGH', 'The tier bar fill stops short of the rung the customer is on',
        `fill ends at ${rail.fillEndsAt}px, "${currentMarker.label}" marker sits at ${currentMarker.centre}px.`);
    }
    /* Is the bar honest about quantity? Rung-index spacing makes 17 of 60 visits look like 57%. */
    note('card sentence', rail.cardText.slice(0, 200));
    mustHold(rail.firstScreen, 'the tier card is on the first screen at 390px (the owner asked for it at the top)');
    /* A distance-only tier card that repeats no balance is the design; check it holds. */
    const repeats = /\b240\b/.test(rail.cardText);
    note('does the tier card repeat the spendable balance?', repeats);
    if (repeats) flag('HIGH', 'The tier card repeats the points balance', rail.cardText.slice(0, 200));
    await context.close();
  }

  /* ================================================= J8b — the same refresh on a real connection */
  say('J8b · the counter moment when the network is not instant (600ms per read)');
  {
    const {context, page} = await open('refresh', {options: {delayMs: 600}});
    await page.waitForSelector('[data-programme-stack="v310"]', {timeout: 30000});
    await page.waitForTimeout(3000);          // let every section hydrate for real
    /* Sample every animation frame from inside the page: a 120ms poll from the test can step
       straight over a flash that a customer's eye would still catch. */
    await page.evaluate(() => {
      window.__frames = [];
      const tick = () => {
        window.__frames.push({t: Math.round(performance.now()),
          sk: document.querySelectorAll('.wallet-skeleton').length,
          busy: document.querySelectorAll('[aria-busy="true"]').length,
          y: Math.round(window.scrollY), h: document.documentElement.scrollHeight,
          bal: document.querySelector('.customer-programme-balance')?.innerText.replace(/\s+/g, ' ').trim() || ''});
        window.__raf = requestAnimationFrame(tick);
      };
      tick();
    });
    await page.evaluate(() => {
      const details = document.getElementById('walletHistoryDisclosure');
      if (details) details.open = true;
      window.scrollTo(0, 700);
    });
    await page.waitForTimeout(300);
    const baseline = await page.evaluate(() => ({y: Math.round(window.scrollY), h: document.documentElement.scrollHeight,
      bal: document.querySelector('.customer-programme-balance')?.innerText.trim(),
      sk: document.querySelectorAll('.wallet-skeleton').length}));
    note('steady state before the sale lands', baseline);
    await page.evaluate(() => {window.__mark = performance.now(); window.__cuxEarn(30);});
    await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
    await page.waitForTimeout(4500);
    const trace = await page.evaluate(() => {
      cancelAnimationFrame(window.__raf);
      const mark = window.__mark;
      const frames = window.__frames.filter(f => f.t >= mark - 100);
      return {mark: Math.round(mark), sampled: frames.length,
        peakSkeletons: Math.max(0, ...frames.map(f => f.sk)),
        peakBusy: Math.max(0, ...frames.map(f => f.busy)),
        skeletonMs: frames.filter(f => f.sk > 0).length && (() => {
          const on = frames.filter(f => f.sk > 0);
          return Math.round(on[on.length - 1].t - on[0].t);
        })(),
        minHeight: Math.min(...frames.map(f => f.h)), maxHeight: Math.max(...frames.map(f => f.h)),
        scrollRange: [Math.min(...frames.map(f => f.y)), Math.max(...frames.map(f => f.y))],
        firstNewBalanceMs: (() => {
          const hit = frames.find(f => f.bal && f.bal !== '240 points');
          return hit ? Math.round(hit.t - mark) : null;
        })()};
    });
    note('frame-accurate trace of the "seamless" repaint', trace);
    if (trace.peakSkeletons > 0) flag('HIGH',
      'On a real connection the "seamless" refresh DOES flash the page back to skeletons',
      `${trace.peakSkeletons} skeleton blocks reappear for ~${trace.skeletonMs}ms and the page collapses from ${trace.maxHeight}px to ${trace.minHeight}px. `
      + `customerWalletSilentPaintV319 repaints the whole wallet body with markup that still contains walletSectionShell() placeholders, then re-fetches every section. The no-change tick is genuinely invisible; the change tick — the one moment the feature exists for — is the old flicker with the scroll restored.`);
    const scrollDrift = trace.scrollRange[1] - trace.scrollRange[0];
    note('scroll drift across the repaint (px)', scrollDrift);
    if (scrollDrift > 8) flag('HIGH', 'The scroll position moves during the repaint on a real connection',
      `scrollY ranged ${JSON.stringify(trace.scrollRange)} because the page shrinks to ${trace.minHeight}px while the sections re-hydrate; scrollTop is restored synchronously, before that shrink.`);
    note('ms from the sale landing to the new balance being on screen', trace.firstNewBalanceMs);
    await shoot(page, 'cux-refresh-latency-390-light');

    /* The scroll held above only because 700px still fits inside the shrunken page. Read from the
       BOTTOM — where History and the offers live — and the same 370px collapse has to clamp. */
    await page.waitForTimeout(2500);
    await page.evaluate(() => {
      window.__frames2 = [];
      const tick = () => {
        window.__frames2.push({y: Math.round(window.scrollY), h: document.documentElement.scrollHeight});
        window.__raf2 = requestAnimationFrame(tick);
      };
      window.scrollTo(0, document.documentElement.scrollHeight);
      tick();
    });
    await page.waitForTimeout(300);
    const bottomBefore = await page.evaluate(() => ({y: Math.round(window.scrollY), h: document.documentElement.scrollHeight}));
    await page.evaluate(() => {window.__cuxEarn(30); document.dispatchEvent(new Event('visibilitychange'));});
    await page.waitForTimeout(4000);
    const bottomTrace = await page.evaluate(() => {
      cancelAnimationFrame(window.__raf2);
      const frames = window.__frames2;
      return {start: frames[0], end: frames[frames.length - 1],
        minY: Math.min(...frames.map(f => f.y)), maxY: Math.max(...frames.map(f => f.y))};
    });
    note('reading from the bottom of the page when the sale lands', {bottomBefore, bottomTrace});
    const jump = bottomBefore.y - bottomTrace.minY;
    note('how far the page yanked the reader (px)', jump);
    gate('scroll jump on refresh while reading', `${jump}px`, '0px', jump <= 2);
    if (jump > 40) flag('HIGH', 'A customer reading the bottom of the page is thrown upward by the refresh',
      `Scrolled to ${bottomBefore.y}px, the repaint collapses the document while the sections re-fetch and the browser clamps the restored offset to ${bottomTrace.minY}px — a ${jump}px jump. `
      + `customerWalletSilentPaintV319 restores scrollTop synchronously, immediately after innerHTML and BEFORE the sections re-hydrate, so the restore lands against a page that is temporarily 370px shorter.`);
    await context.close();
  }

  /* ============================================================ language coverage, as a customer */
  say('L · the same shop for a customer whose phone is in Chinese / Malay / Tamil');
  for (const locale of ['zh-CN', 'ms', 'ta']) {
    const {context, page} = await open('multi', {options: {locale}, wait: '[data-programme-stack="v310"]'});
    const sample = await page.evaluate(() => {
      const stack = document.querySelector('[data-programme-stack]');
      const text = stack.innerText.replace(/\s+/g, ' ').trim();
      /* Sentences the surface writes itself, as opposed to names the business typed. */
      const english = text.match(/\b(You're now at|All tiers and what they unlock|tiers|Visits move you up|Points stay yours to spend|Pick a reward|show its QR at the counter|Available at counter|Show QR at counter|Not yet yours|Reached|Your tier|From \d|visit|Benefits not published yet)\b/g) || [];
      const latinShare = (() => {
        const letters = text.replace(/[^\p{L}]/gu, '');
        const latin = text.replace(/[^A-Za-z]/g, '');
        return letters.length ? +(latin.length / letters.length).toFixed(2) : 0;
      })();
      return {domLang: document.documentElement.lang || '(unset)', latinShare,
        text: text.slice(0, 300), untranslated: [...new Set(english)]};
    });
    note(`stack in ${locale}`, sample);
    gate(`non-ct() English in ${locale} cards`, sample.untranslated.length ? JSON.stringify(sample.untranslated) : 0,
      '0', sample.untranslated.length === 0);
    if (sample.untranslated.length) flag('MEDIUM', `English survives inside the ${locale} programme cards`,
      `Still English: ${JSON.stringify(sample.untranslated)}. ${Math.round(sample.latinShare * 100)}% of the letters in the card stack are Latin. `
      + `The card headings and the one-line sentences went through ct(); customerTierPanelMarkupV194's "You're now at", the V258 reassurance, customerTierLadderMarkupV186 and customerTierRequirementTextV189 did not, so the tallest card on the page is half-translated.`);
    if (locale === 'ta') {await shoot(page, 'cux-multi-390-tamil'); await shootEvidence(page, 'shop-390-tamil')}
    await context.close();
  }

  /* ============================================================ does the shop page warn about expiry? */
  say('X · does the shop page tell the customer their points expire?');
  {
    const {context, page} = await open('multi');
    await page.waitForSelector('[data-programme-stack="v310"]', {timeout: 20000});
    await page.waitForTimeout(1200);
    const expiry = await page.evaluate(() => {
      const body = document.getElementById('walletBody')?.innerText || '';
      const line = document.querySelector('.customer-next-up-expiry-v322');
      const rect = line?.getBoundingClientRect();
      return {mentionsExpiry: /expir/i.test(body),
        stackMentionsExpiry: /expir/i.test(document.querySelector('[data-programme-stack]')?.innerText || ''),
        onFirstScreen: !!rect && rect.top < window.innerHeight,
        line: (line?.innerText || '').replace(/\s+/g, ' ').trim(),
        date: (body.match(/expir[^.]{0,60}/i) || [])[0] || null};
    });
    note('expiry on the shop page', expiry);
    gate('expiry stated on shop page', expiry.line || 'no', 'yes when present',
      expiry.mentionsExpiry === true && !!expiry.line && expiry.onFirstScreen === true);
    if (!expiry.mentionsExpiry) flag('HIGH', 'The shop page never says the points expire',
      'Home carries an "Expiring rewards · 1 to use · 60 points · 30 Sept 2026" card built from the same payload, but the shop page — the surface the customer actually opens at the counter — prints a balance with no expiry anywhere on it. The customer learns their points died only by going back to Home.');
    await context.close();
  }

  /* ============================================================ the narrowest phone still sold */
  say('W · 320px — the smallest screen the surface has to hold');
  {
    const {context, page} = await open('multi', {width: 320, height: 720});
    await page.waitForSelector('[data-programme-stack="v310"]', {timeout: 20000});
    const over = await overflowReport(page);
    note('320px horizontal overflow', over);
    gate('horizontal scroll @320', over.pageScrollsSideways ? `${over.scrollWidth}px > ${over.clientWidth}px` : 'none',
      'none', !over.pageScrollsSideways);
    const clipped = await clipReport(page);
    note('clipped text at 320px', clipped);
    const small = await tapTargets(page);
    note('controls under 44px at 320', small);
    await shoot(page, 'cux-multi-320-light');
    await context.close();
  }

  /* ================================================= the first-visit moment, all four arms */
  say('F · the first visit to a shop — does the page say what any of this is for?');
  {
    /* (a) a customer who has just joined, in English: the moment names the shop's real cheapest
           reward and the true distance to it. */
    const {context, page} = await open('newjoin');
    await page.waitForSelector('[data-programme-stack="v310"]', {timeout: 20000});
    const moment = await page.evaluate(() => {
      const node = document.querySelector('[data-first-visit-v322]');
      if (!node) return null;
      const r = node.getBoundingClientRect();
      return {text: node.innerText.replace(/\s+/g, ' ').trim(),
        onFirstScreen: r.top < window.innerHeight, top: Math.round(r.top + window.scrollY)};
    });
    note('the first-visit moment', moment);
    await shootEvidence(page, 'first-visit-390');
    const namesRealReward = !!moment && /Free flat white/.test(moment.text);
    const trueDistance = !!moment && /\b300\b/.test(moment.text);   // 0 points, a 300-point gift
    gate('first-visit moment · real reward name + true distance',
      moment ? moment.text.slice(0, 90) : 'absent', 'names the reward and the true distance',
      namesRealReward && trueDistance && moment.onFirstScreen);

    /* (b) it fires ONCE. A second open of the same shop, same browser storage. */
    const second = await page.evaluate(async () => {
      location.hash = '#/wallet';
      await new Promise(resolve => setTimeout(resolve, 900));
      location.hash = '#/wallet/hougang-abc';
      await new Promise(resolve => setTimeout(resolve, 1800));
      return {present: !!document.querySelector('[data-first-visit-v322]'),
        stack: !!document.querySelector('[data-programme-stack="v310"]')};
    });
    note('the same shop, opened again in the same browser', second);
    gate('first-visit moment · fires exactly once', second.present ? 'again' : 'once',
      'exactly once', second.stack === true && second.present === false);
    await shoot(page, 'cux-firstvisit-390-light');
    await context.close();
  }
  {
    /* (c) honest when nothing is in reach: a shop that has published no reward at all. */
    const {context, page} = await open('noreward');
    await page.waitForSelector('[data-programme-stack="v310"]', {timeout: 20000});
    const honest = await page.evaluate(() => {
      const node = document.querySelector('[data-first-visit-v322]');
      const body = document.getElementById('walletBody')?.innerText || '';
      return {text: (node?.innerText || '').replace(/\s+/g, ' ').trim(),
        inventsAReward: /\b\d+\s*(points|stamps)\b[^.]{0,30}\b(and|is yours)\b/i.test(node?.innerText || ''),
        bodyClaimsATarget: /more for /i.test(body)};
    });
    note('a shop with no reward published', honest);
    gate('first-visit moment · honest when nothing is in reach', honest.text.slice(0, 90) || 'absent',
      'says so, invents nothing',
      /not set a reward|kept for you/i.test(honest.text) && !honest.inventsAReward && !honest.bodyClaimsATarget);
    await context.close();
  }
  for (const locale of ['zh-CN', 'ms', 'ta']) {
    const {context, page} = await open('newjoin', {options: {locale}});
    await page.waitForSelector('[data-programme-stack="v310"]', {timeout: 20000});
    const localized = await page.evaluate(() => {
      const node = document.querySelector('[data-first-visit-v322]');
      const text = (node?.innerText || '').replace(/\s+/g, ' ').trim();
      /* The business's own reward name stays as the business typed it; everything the SURFACE
         writes must be in the customer's language. */
      const surface = text.replace(/Free flat white/g, '');
      return {text, englishLeft: (surface.match(/\b(How rewards work here|Collect|is yours|Got it|has not set a reward)\b/g) || [])};
    });
    note(`the first-visit moment in ${locale}`, localized);
    gate(`first-visit moment · ${locale}`, localized.englishLeft.length ? JSON.stringify(localized.englishLeft) : localized.text.slice(0, 60),
      'no surface English', !!localized.text && localized.englishLeft.length === 0);
    await context.close();
  }

  /* ================================================= B3 — the earn rate, and the field it needs */
  say('E · how earning works — the one gate that needs a server field');
  {
    /* Arm 1: today's production payload. Nothing about a rate exists on it, so the page must say
       NOTHING about a rate — an invented "10 points per $1" would be worse than silence. */
    const {context, page} = await open('newjoin');
    await page.waitForSelector('[data-programme-stack="v310"]', {timeout: 20000});
    const today = await page.evaluate(() => {
      const body = document.getElementById('walletBody')?.innerText || '';
      return {earnLine: (document.querySelector('.customer-next-up-earn-v322')?.innerText || '').trim(),
        claimsARate: /\b(per|every|each)\b[^.]{0,20}\$|\bper\s+dollar\b/i.test(body)};
    });
    note('the earn rate on today’s payload', today);
    gate('earn rate stated', today.earnLine || 'not stated (server field absent)', 'yes, from real config',
      false, {blocked: true});
    mustHold(!today.claimsARate && !today.earnLine,
      'with no earn field on the payload the page invents no rate at all');
    await context.close();
  }
  for (const locale of ['en', 'zh-CN', 'ms', 'ta']) {
    /* Arm 2: the SAME page against the payload the contract in the build report asks for. This is
       the client half, proven ready, in all four languages. */
    const {context, page} = await open('newjoin', {options: {locale, earn: {points_per_dollar: 10}}});
    await page.waitForSelector('[data-programme-stack="v310"]', {timeout: 20000});
    const line = await page.evaluate(() =>
      (document.querySelector('.customer-next-up-earn-v322')?.innerText || '').replace(/\s+/g, ' ').trim());
    note(`the earn line when the server carries loyalty.earn (${locale})`, line);
    gate(`earn rate stated · with the contracted field (${locale})`, line || 'absent',
      'the real rate, in this language', /10/.test(line) && line.length > 6);
    await context.close();
  }

  /* ============================================================ */
  say('Summary');
  note('hard invariants failed', hard.length);
  note('findings raised', findings.length);
  /* THE PART D TABLE, with the value measured in THIS run in the middle column. */
  process.stdout.write('\n  gate | measured now | must be | verdict\n');
  process.stdout.write('  ---|---|---|---\n');
  for (const row of gates) {
    const measured = typeof row.now === 'object' ? JSON.stringify(row.now) : String(row.now);
    process.stdout.write(`  ${row.gate} | ${measured} | ${row.must} | ${row.blocked ? 'BLOCKED (server field)' : row.pass ? 'PASS' : 'FAIL'}\n`);
  }
  const failedGates = gates.filter(row => !row.pass && !row.blocked);
  const blockedGates = gates.filter(row => row.blocked);
  note('gates measured', gates.length);
  note('gates failed', failedGates.length);
  note('gates blocked on a server field', blockedGates.map(row => row.gate));
  writeFileSync(`${SHOTS}/measurements.json`, JSON.stringify({gates, measurements, findings, pageErrors}, null, 2));
  process.stdout.write(`\nmeasurements written to ${SHOTS}/measurements.json\n`);
  if (pageErrors.length) {
    process.stdout.write(`page errors: ${pageErrors.join(' | ')}\n`);
    flag('BROKEN', 'The page threw JavaScript errors while a customer used it', pageErrors.join(' | '));
  }
  mustHold(pageErrors.length === 0, 'no uncaught page errors across every journey');
  if (hard.length) {
    process.stdout.write(`\nHARD INVARIANTS FAILED:\n${hard.map(h => ' - ' + h).join('\n')}\n`);
    process.exitCode = 1;
  } else {
    process.stdout.write('\nHARD INVARIANTS HELD\n');
  }
} catch (error) {
  process.stdout.write(`\nFAILED at ${step}: ${error?.stack || error}\n`);
  if (pageErrors.length) process.stdout.write(`page errors: ${pageErrors.join(' | ')}\n`);
  process.exitCode = 1;
} finally {
  await browser.close();
  for (const server of servers) server.kill();
}
