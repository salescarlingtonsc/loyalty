/* V441 — the customer bottom dock stays inside the Live-preview phone frame.
 *
 * THE BUG (owner screenshot of Customer Interface -> Business Profile, build 1039401). The Live
 * preview renders the REAL customer wallet markup inline inside a phone frame — deliberately: the
 * site sends `frame-ancestors 'none'`, so an iframe of ourselves can never render (V326). "Real
 * markup" carries the customer surface's viewport-anchored furniture with it, and
 * `.customer-primary-nav` is position:fixed with left:50% + transform:translateX(-50%) and a
 * 100vw-relative width. V326 overrode only `position` and `bottom`, so the dock (and the red scan
 * FAB with it) landed 179px to the LEFT of the frame and, because `.customer-surface`'s
 * min-height:100dvh made the preview scrollport taller than the 507px screen, well BELOW it too.
 * Measured on the pre-fix tree at 1180x724: screen x 754..1113 y 229..736, dock x 591..949
 * y 793..865 — outside on both axes.
 *
 * WHAT THIS FILE PROVES, BY MEASURING A REAL BROWSER — never by reading source:
 *   1. brand step (the screen the owner marked up), at 390 / 834 / 1180 / 1440: the dock's
 *      bounding box is fully inside the phone-screen box, and pinned to its bottom.
 *   2. the SECOND preview instance (step 3, `#/customer-interface`) — same assertion. Two frames
 *      exist in the DOM; a fix that only reached the one the owner was looking at is half a fix.
 *   3. the generic sweep: EVERY descendant of the frame whose computed position is fixed or
 *      sticky — whatever it is, named or not — is inside the frame. Plus a synthetic
 *      position:fixed;inset:0 probe injected into the frame, which lands on the phone screen
 *      rather than the browser window. That is the mechanism itself under test, so a customer
 *      element added later (a toast, a sheet, a FAB) is contained without a new rule.
 *   4. scrolled states: after scrolling the business page, and after scrolling the frame's own
 *      scrollport to its end, the dock is still inside the frame.
 *   5. THE REGRESSION GUARD: the real customer wallet, booted through the real router on
 *      `#/wallet/<slug>` with a customer persona, still has a position:fixed dock anchored to the
 *      bottom of the BROWSER viewport and still centred by translateX(-50%). The preview overrides
 *      must not reach a customer.
 *
 * Serves on 4441 (sibling worktrees run 4173/4196/4203/4303/4310). The readiness probe checks the
 * served index.html carries the V441 rule, so a stale server from another tree answering 200
 * cannot be mistaken for this build.
 *
 * Run:
 *   PLAYWRIGHT_MODULE="<somewhere>/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v441-preview-dock-scope.mjs
 */
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;
const APP_DIR=process.env.V441_APP_DIR||fileURLToPath(new URL('../../app/',import.meta.url));
const PORT=Number(process.env.V441_PORT||4441);
const ORIGIN=`http://127.0.0.1:${PORT}`;

let step='(boot)';
const say=name=>{step=name;process.stdout.write(`STEP ${name}\n`)};
const assertTrue=(condition,message)=>{
  if(!condition)throw new Error(`step ${step}: ${message}`);
  process.stdout.write(`  ok - ${message}\n`);
};

let server=null;
/* Serving SOMETHING is not serving THIS build: another worktree's server answering on this port
   would silently prove the wrong tree. The V441 rule is the marker. */
const probe=async()=>{
  try{
    const response=await fetch(`${ORIGIN}/index.html`);
    if(!response.ok)return false;
    return (await response.text()).includes('.customer-preview-screen-v243{position:relative');
  }catch{return false}
};
const serverReady=async()=>{
  if(await probe())return;
  server=spawn('python3',['-m','http.server',String(PORT),'--bind','127.0.0.1'],{cwd:APP_DIR,stdio:'ignore'});
  server.on('error',error=>process.stdout.write(`server spawn error: ${error}\n`));
  for(let i=0;i<60;i++){
    if(await probe())return;
    await new Promise(resolve=>setTimeout(resolve,100));
  }
  throw new Error(`static server did not start on ${ORIGIN}, or it is not serving this build`);
};

const BIZ='b1111111-1111-4111-8111-111111111111';
const SLUG='testco';

/* ---------------- the owner (business) fixture: enough tenant to render Customer Interface ---- */
const ownerStub=`(()=>{
  const BIZ='${BIZ}';
  const MODULES=['loyalty','retention','referrals','memberships','clients','sales','services','till',
    'bookings','reports','inventory','appointments','staffperf','packages'];
  const program={id:'prog-1',business_id:BIZ,active:true,loyalty_model:'points_tiers',
    earn_points_per_dollar:1,redeem_points:100,reward_credit_cents:100,stamp_target:null,
    stamp_per_cents:500,expiry_mode:'none',expiry_days:null,tier_basis:'visits',
    current_config_version_id:'pub-1',configuration_status:'published'};
  const bizRow={id:BIZ,slug:'${SLUG}',name:'Test Co',currency:'SGD',industry:'facial',points_mode:'both',
    enabled_modules:MODULES,active_config_version_id:'pub-1',join_enabled:true,brand_color:'#7c5cff',
    booking_policy:'Please arrive 10 minutes early.',bio:'A small neighbourhood facial bar.',
    quick_earn_catalogue_enabled:true,created_at:'2026-01-01T00:00:00Z'};
  const TABLES={
    businesses:[bizRow],
    branches:[{id:'br1',business_id:BIZ,name:'Orchard',active:true,is_default:true,billing_state:'active'}],
    services:[{id:'sv1',business_id:BIZ,name:'Signature facial',active:true,price_cents:8800}],
    clients:[],sales:[],appointments:[],points_ledger:[],memberships:[],client_packages:[],waitlist:[],
    client_field_definitions:[],client_field_values:[],client_field_options:[],branch_hours:[],
    staff:[{id:'st1',business_id:BIZ,full_name:'Owner Person',role:'owner',user_id:'u-owner',active:true,
      email:'owner@test.co',phone:'',title:null,module_perms:null,modules:null,
      commission_service_bps:null,commission_product_bps:null,created_at:'2026-01-01T00:00:00Z'}],
    staff_invites:[],staff_hours:[],staff_branches:[{business_id:BIZ,staff_id:'st1',branch_id:'br1'}],
    loyalty_programs:[program],loyalty_rewards:[],loyalty_reward_branches:[],
    loyalty_reward_services:[],loyalty_reward_products:[],
    loyalty_tiers:[{id:'t-gold',business_id:BIZ,name:'Gold',threshold:10}],
    loyalty_branch_overrides:[],gift_cards:[],referral_programs:[],membership_plans:[],
    retention_programs:[],firm_config_versions:[]
  };
  const chainable=resolveOut=>{
    const q={single:false,head:false,countMode:null,op:'select'};
    const chain={};
    for(const m of ['eq','neq','is','in','not','gte','lte','lt','gt','or','ilike','contains',
      'overlaps','order','limit','range','abortSignal'])chain[m]=()=>chain;
    chain.select=(cols,opts)=>{if(opts&&opts.count){q.countMode=opts.count;q.head=!!opts.head}return chain};
    chain.single=()=>{q.single=true;return chain};
    chain.maybeSingle=()=>{q.single=true;return chain};
    chain.update=p=>{q.op='update';q.payload=p;return chain};
    chain.insert=p=>{q.op='insert';q.payload=p;return chain};
    chain.upsert=p=>{q.op='upsert';q.payload=p;return chain};
    chain.delete=()=>{q.op='delete';return chain};
    chain.then=(res,rej)=>Promise.resolve(resolveOut(q)).then(res,rej);
    return chain;
  };
  const query=table=>chainable(q=>{
    if(q.op!=='select')return {data:null,error:null};
    const rows=TABLES[table]||[];
    if(q.countMode&&q.head)return {data:null,count:rows.length,error:null};
    if(q.single)return {data:rows[0]??null,error:null};
    return {data:rows,count:q.countMode?rows.length:null,error:null};
  });
  /* A points + tiers spine, so the preview draws the balance hero, the tier row and the sample
     reward list — i.e. a frame with enough content in it to scroll, which is the state the dock
     has to survive. */
  const SPINE=[
    {kind:'points',active:true,customer_visible:true,running_since:'2026-02-01T00:00:00Z',
     paused_since:null,balance_scope:'business_pot'},
    {kind:'tiers',active:true,customer_visible:true,running_since:'2026-02-01T00:00:00Z',
     paused_since:null,balance_scope:'business_pot'}];
  const rpcData=name=>{
    switch(name){
      case 'get_my_personas':return {staff:[{business_id:BIZ,business_slug:'${SLUG}',
        business_name:'Test Co',role:'owner',modules:MODULES}],customer:[],
        default_route:'#/workspace/${SLUG}/dashboard'};
      case 'platform_get_business_control_v94':return {workspace_access:true,quick_earn_catalogue_enabled:true};
      case 'get_my_modules':return {role:'owner',is_super_admin:false,modules:MODULES,
        module_perms:Object.fromEntries(MODULES.map(m=>[m,'rw']))};
      case 'get_my_modules_at_v115':return {role:'owner',modules:MODULES,
        module_perms:Object.fromEntries(MODULES.map(m=>[m,'rw']))};
      case 'get_customer_feature_capabilities':return {};
      case 'get_workspace_locale_preference_v97':return {locale:'en',version:1};
      case 'get_notifications':return {unread:0,items:[]};
      case 'require_module_scope_v145':return null;
      case 'get_business_signup_config':return null;
      case 'business_get_customer_capabilities_v89':return {redemption_enabled:true};
      case 'business_programme_usage_v271':return null;
      case 'business_get_welcome_offer_v215':return {configured:false};
      case 'get_programmes_v314':case 'business_get_programmes_v314':
        return {programmes:SPINE,programmes_contract:'v391'};
      default:return null;
    }
  };
  const rpc=name=>chainable(()=>({data:rpcData(name),error:null}));
  const channel=()=>{const c={on:()=>c,subscribe:()=>c,unsubscribe:()=>{}};return c};
  const auth=new Proxy({
    getSession:async()=>({data:{session:{user:{id:'u-owner',email:'owner@test.co'}}},error:null}),
    getUser:async()=>({data:{user:{id:'u-owner',email:'owner@test.co'}},error:null}),
    onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
    signOut:async()=>({error:null})
  },{get:(t,k)=>k in t?t[k]:async()=>({data:null,error:null})});
  const client={from:query,rpc,auth,channel,removeChannel(){},
    functions:{invoke:async()=>({data:null,error:null})},
    storage:{from:()=>({getPublicUrl:()=>({data:{publicUrl:''}})})}};
  Object.defineProperty(window,'supabase',{value:{createClient:()=>client},writable:false,configurable:false});
})();`;

/* ---------------- the customer fixture: the real wallet, for the regression guard ------------- */
const customerStub=`(()=>{
  const BIZ='${BIZ}',SLUG='${SLUG}';
  const BUSINESS={id:BIZ,slug:SLUG,name:'Test Co',currency:'SGD'};
  const TIER={current:{label:'Gold'},name:'Gold',threshold:10,basis:'points_earned',metric:300,
    points_multiplier:1,perk_note:null,next:null};
  const LOYALTY={balance:300,unit:'points',enabled:true,tier:TIER};
  const CARD={business:BUSINESS,loyalty:LOYALTY,credit:{},packages:{},
    next_eligible_reward:{name:'Free Facial',cost_units:100,available_now:true,remaining_units:0},
    visit_progress:{},birthday_benefit:null};
  const CAPS={wallet:true,rewards:true,tiers:true,points_mode:'both',activity:true,
    appointments:false,booking_request:false,packages:false,membership:false,
    programmes_contract:'v310',
    programmes:[{kind:'points',active:true,customer_visible:true},
      {kind:'tiers',active:true,customer_visible:true}]};
  const PRESENTATION={locale:'en',brand:{hero_color:'#7c5cff'},
    programme:{name:'Test Co Rewards',tagline:'',unit:'points',balance:300,tier:TIER,
      benefits:[],offers:[]},
    catalogue:{rewards:[],products:[],services:[]},capabilities:{booking_enabled:false}};
  const chainable=resolveOut=>{
    const q={single:false,head:false,countMode:null,op:'select'};
    const chain={};
    for(const m of ['eq','neq','is','in','not','gte','lte','lt','gt','or','ilike','contains',
      'overlaps','order','limit','range','abortSignal'])chain[m]=()=>chain;
    chain.select=(cols,opts)=>{if(opts&&opts.count){q.countMode=opts.count;q.head=!!opts.head}return chain};
    chain.single=()=>{q.single=true;return chain};
    chain.maybeSingle=()=>{q.single=true;return chain};
    chain.update=()=>chain;chain.insert=()=>chain;chain.upsert=()=>chain;chain.delete=()=>chain;
    chain.then=(res,rej)=>Promise.resolve(resolveOut(q)).then(res,rej);
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
      case 'customer_get_reward_catalog':return {points_mode:'both',rewards:[]};
      case 'customer_get_referral_card_v300':return {enabled:false};
      case 'customer_get_growth_offers_v108':return {offers:[]};
      case 'customer_get_transaction_history_v81':return {items:[]};
      case 'customer_get_loyalty_details':return {loyalty:{balance:300,unit:'points'},activity:[],
        expiry:{expiring_next_30_days:0,next_expiry_at:null}};
      case 'customer_record_account_open_v175':return {status:'ok'};
      default:return null;
    }
  };
  const SILENT=new Set(['customer_get_gift_cards','customer_get_packages','customer_get_memberships',
    'customer_get_appointments','customer_get_pending_promotion_prompt_v122']);
  const rpc=name=>SILENT.has(name)
    ?chainable(()=>({data:null,error:DENIED}))
    :chainable(()=>({data:rpcData(name),error:null}));
  const channel=()=>{const c={on:()=>c,subscribe:()=>c,unsubscribe:()=>{}};return c};
  const auth=new Proxy({
    getSession:async()=>({data:{session:{user:{id:'u-cust',email:'mei@example.sg'}}},error:null}),
    getUser:async()=>({data:{user:{id:'u-cust',email:'mei@example.sg'}},error:null}),
    onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
    signOut:async()=>({error:null})
  },{get:(t,k)=>k in t?t[k]:async()=>({data:null,error:null})});
  const client={from:query,rpc,auth,channel,removeChannel(){},
    functions:{invoke:async()=>({data:null,error:null})},
    storage:{from:()=>({getPublicUrl:()=>({data:{publicUrl:''}})})}};
  Object.defineProperty(window,'supabase',{value:{createClient:()=>client},writable:false,configurable:false});
})();`;

/* Measured in the page: for one preview host, the phone-screen box, the dock box, and EVERY
   fixed/sticky descendant of the frame with its own box. Sub-pixel layout is real, so the caller
   compares with a 0.5px tolerance rather than on rounded integers. */
const measureSource=`(scope=>{
  const host=document.querySelector(scope);
  if(!host)return {missing:'host'};
  const screen=host.querySelector('.customer-preview-screen-v243');
  const inner=host.querySelector('.ci-live-preview-inner-v326');
  const nav=host.querySelector('.customer-primary-nav');
  if(!screen||!inner||!nav)return {missing:'frame parts'};
  const box=el=>{const b=el.getBoundingClientRect();
    return {left:b.left,top:b.top,right:b.right,bottom:b.bottom,width:b.width,height:b.height}};
  /* The generic sweep. Not a list of known class names — every element in the frame is asked
     what it computed to, so an element nobody thought of is covered by the same assertion. */
  const escapers=[];
  for(const el of inner.querySelectorAll('*')){
    const position=getComputedStyle(el).position;
    if(position!=='fixed'&&position!=='sticky')continue;
    escapers.push({position,box:box(el),
      selector:el.tagName.toLowerCase()+(el.className?'.'+String(el.className).trim().split(/\\s+/).join('.'):'')});
  }
  /* And the mechanism itself: a synthetic position:fixed;inset:0 probe. In an unscoped frame it
     fills the browser window; when the phone screen is the containing block it fills the screen. */
  const probe=document.createElement('div');
  probe.setAttribute('data-v441-probe','1');
  probe.style.cssText='position:fixed;inset:0;pointer-events:none';
  inner.appendChild(probe);
  const probeBox=box(probe);
  probe.remove();
  return {screen:box(screen),inner:box(inner),nav:box(nav),probe:probeBox,escapers,
    navPosition:getComputedStyle(nav).position,
    navTransform:getComputedStyle(nav).transform,
    innerScrollHeight:inner.scrollHeight,innerClientHeight:inner.clientHeight,
    viewport:{width:innerWidth,height:innerHeight}};
})`;

const T=0.5;
const inside=(child,parent)=>child.left>=parent.left-T&&child.right<=parent.right+T
  &&child.top>=parent.top-T&&child.bottom<=parent.bottom+T;
const fmt=b=>`x ${b.left.toFixed(0)}..${b.right.toFixed(0)} y ${b.top.toFixed(0)}..${b.bottom.toFixed(0)}`;

const browser=await chromium.launch({
  headless:true,
  executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
});
const pageErrors=[];
try{
  await serverReady();

  const openOwner=async(width,height)=>{
    const context=await browser.newContext({viewport:{width,height},bypassCSP:true});
    await context.route('**/*',route=>{
      const url=route.request().url();
      if(url.startsWith(ORIGIN)&&!url.includes('/sw.js'))return route.continue();
      return route.abort();
    });
    await context.addInitScript(ownerStub);
    const page=await context.newPage();
    page.on('pageerror',error=>pageErrors.push(`owner ${width}x${height}: ${error}`));
    await page.goto(`${ORIGIN}/index.html#/customer-interface/brand`,{waitUntil:'domcontentloaded'});
    await page.waitForSelector('[data-ci-view-v296="brand"] .customer-primary-nav',{timeout:25000});
    return {context,page};
  };

  const checkFrame=(measured,label)=>{
    assertTrue(!measured.missing,`${label}: the preview frame and its dock are rendered`);
    assertTrue(measured.screen.width>0&&measured.screen.height>0,
      `${label}: the phone screen has a real box (${fmt(measured.screen)})`);
    assertTrue(inside(measured.nav,measured.screen),
      `${label}: the dock ${fmt(measured.nav)} is inside the phone screen ${fmt(measured.screen)}`);
    /* "Inside" alone would be satisfied by a dock parked at the top of the frame. The owner's
       complaint is that it is not where a bottom bar belongs, so pin the bottom too. */
    assertTrue(Math.abs(measured.nav.bottom-measured.screen.bottom)<=24,
      `${label}: and it is pinned to the BOTTOM of the screen `
      +`(${(measured.screen.bottom-measured.nav.bottom).toFixed(0)}px clear of the frame edge)`);
    assertTrue(measured.navTransform==='none',
      `${label}: the viewport-centring transform is cancelled inside the frame (${measured.navTransform})`);
    /* The sweep runs whether or not it finds anything: an empty result is itself the finding —
       the frame currently holds no other fixed/sticky element — and the loop is what catches the
       one added next month. It is reported either way so a silently-empty sweep cannot pass for
       a passing sweep. */
    process.stdout.write(`  .. ${label}: swept ${measured.escapers.length} fixed/sticky `
      +`descendant(s) of the frame\n`);
    for(const escaper of measured.escapers){
      assertTrue(inside(escaper.box,measured.screen),
        `${label}: ${escaper.position} element ${escaper.selector} ${fmt(escaper.box)} stays in the frame`);
    }
    assertTrue(inside(measured.probe,measured.screen),
      `${label}: a synthetic position:fixed;inset:0 probe fills the phone screen ${fmt(measured.probe)}, `
      +`not the ${measured.viewport.width}x${measured.viewport.height} browser window`);
  };

  /* --------------- 1. the screen the owner marked up, across four viewports --------------- */
  for(const [width,height] of [[1440,900],[1180,724],[834,1112],[390,844]]){
    say(`1. Business Profile live preview at ${width}x${height}`);
    const {context,page}=await openOwner(width,height);
    const measured=await page.evaluate(`(${measureSource})('[data-ci-view-v296="brand"]')`);
    checkFrame(measured,`${width}x${height} brand`);
    assertTrue(measured.innerScrollHeight>measured.innerClientHeight,
      `${width}x${height} brand: the frame scrolls its own content `
      +`(${measured.innerScrollHeight} into ${measured.innerClientHeight}) rather than overflowing the frame`);

    /* ------- 4. scrolled states, at this same viewport ------- */
    say(`4. scrolled states at ${width}x${height}`);
    await page.evaluate(()=>{
      const scroller=document.scrollingElement||document.documentElement;
      scroller.scrollTop=Math.max(0,scroller.scrollHeight-scroller.clientHeight);
      const main=document.querySelector('main')||document.querySelector('#main');
      if(main)main.scrollTop=main.scrollHeight;
    });
    const afterPageScroll=await page.evaluate(`(${measureSource})('[data-ci-view-v296="brand"]')`);
    checkFrame(afterPageScroll,`${width}x${height} brand, business page scrolled`);
    await page.evaluate(()=>{
      const inner=document.querySelector('[data-ci-view-v296="brand"] .ci-live-preview-inner-v326');
      inner.scrollTop=inner.scrollHeight;
    });
    const afterFrameScroll=await page.evaluate(`(${measureSource})('[data-ci-view-v296="brand"]')`);
    checkFrame(afterFrameScroll,`${width}x${height} brand, frame scrolled to its end`);
    await context.close();
  }

  /* --------------- 2. the OTHER preview instance (step 3, #/customer-interface) --------------- */
  say('2. the step-3 preview card is the same frame and holds its dock the same way');
  {
    const {context,page}=await openOwner(1180,724);
    await page.evaluate(()=>{location.hash='#/customer-interface'});
    await page.waitForFunction(()=>{
      const section=document.querySelector('[data-ci-view-v296="preview"]');
      return !!section&&!section.hasAttribute('hidden')
        &&!!section.querySelector('.customer-primary-nav');
    },null,{timeout:25000});
    const measured=await page.evaluate(`(${measureSource})('[data-ci-view-v296="preview"]')`);
    checkFrame(measured,'1180x724 step-3 preview');
    /* And it really is the second instance, not the first one re-measured. */
    const instances=await page.evaluate(()=>document.querySelectorAll('.customer-preview-screen-v243').length);
    assertTrue(instances>=2,`both preview instances exist in the DOM (${instances} frames), and both were measured`);
    await context.close();
  }

  /* --------------- 5. REGRESSION GUARD: the real customer wallet is untouched --------------- */
  say('5. a NON-preview customer render still docks to the browser viewport');
  {
    const context=await browser.newContext({viewport:{width:390,height:844},bypassCSP:true});
    await context.route('**/*',route=>{
      const url=route.request().url();
      if(url.startsWith(ORIGIN)&&!url.includes('/sw.js'))return route.continue();
      return route.abort();
    });
    await context.addInitScript(customerStub);
    const page=await context.newPage();
    page.on('pageerror',error=>pageErrors.push(`customer: ${error}`));
    await page.goto(`${ORIGIN}/index.html#/wallet/${SLUG}`,{waitUntil:'domcontentloaded'});
    await page.waitForSelector('.customer-shell .customer-primary-nav',{timeout:25000});
    const wallet=await page.evaluate(()=>{
      const shell=document.querySelector('.wallet-shell.customer-shell.customer-surface');
      const nav=document.querySelector('.customer-shell .customer-primary-nav');
      const style=getComputedStyle(nav);
      const b=nav.getBoundingClientRect();
      return {
        previewClassPresent:!!document.querySelector('.customer-preview-screen-v243,.ci-live-preview-inner-v326'),
        shellClasses:shell?shell.className:'(no shell)',
        position:style.position,transform:style.transform,
        bottom:style.bottom,left:style.left,zIndex:style.zIndex,
        box:{left:b.left,right:b.right,top:b.top,bottom:b.bottom,width:b.width,height:b.height},
        viewport:{width:innerWidth,height:innerHeight}
      };
    });
    assertTrue(!wallet.previewClassPresent,
      'no preview class exists anywhere on the customer surface, so no V441 selector can match it');
    assertTrue(wallet.shellClasses==='wallet-shell customer-shell customer-surface',
      `the real wallet root is exactly "${wallet.shellClasses}"`);
    assertTrue(wallet.position==='fixed',
      `the real dock is still position:fixed (got ${wallet.position})`);
    assertTrue(/matrix\(1, 0, 0, 1, -\d/.test(wallet.transform),
      `the real dock is still viewport-centred by translateX(-50%) (${wallet.transform})`);
    assertTrue(Math.abs(wallet.box.bottom-wallet.viewport.height)<=40,
      `the real dock is still anchored to the bottom of the BROWSER viewport `
      +`(${(wallet.viewport.height-wallet.box.bottom).toFixed(0)}px up from ${wallet.viewport.height})`);
    const centreOffset=Math.abs((wallet.box.left+wallet.box.right)/2-wallet.viewport.width/2);
    assertTrue(centreOffset<=1,
      `and still horizontally centred in the viewport (${centreOffset.toFixed(1)}px off centre)`);
    /* Scrolling a customer's wallet must not move the dock: that is what position:fixed buys, and
       the preview override must not have converted it to something that scrolls away. */
    await page.evaluate(()=>{
      const scroller=document.scrollingElement||document.documentElement;
      scroller.scrollTop=Math.max(0,scroller.scrollHeight-scroller.clientHeight);
    });
    const afterScroll=await page.evaluate(()=>{
      const b=document.querySelector('.customer-shell .customer-primary-nav').getBoundingClientRect();
      return {bottom:b.bottom,height:innerHeight};
    });
    assertTrue(Math.abs(afterScroll.bottom-afterScroll.height)<=40,
      'and it stays there after the customer scrolls the wallet');
    await context.close();
  }

  assertTrue(pageErrors.length===0,`no uncaught page errors (${pageErrors.length})`);
  process.stdout.write('\nV441 preview dock scoping: all steps passed\n');
}catch(error){
  process.stdout.write(`\nFAILED: ${error.message}\n`);
  if(pageErrors.length)process.stdout.write(`page errors:\n  ${pageErrors.join('\n  ')}\n`);
  process.exitCode=1;
}finally{
  await browser.close();
  if(server)server.kill();
}
