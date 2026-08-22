/* V447 — `.split` really does collapse to one column on a narrow viewport.
 *
 * THE BUG (REG-003). `.split` is the app's generic two-column form/panel grid — 37 render sites
 * across clients, Customer 360, bookings, loyalty, retention, promotions, the playbook wizard,
 * studio, referrals, memberships, appointments, bottles, inventory, packages, branches, Settings,
 * Customer Interface and the PUBLIC booking portal. app/index.html carried a phone override
 *   @media(max-width:768px){ ... .split{grid-template-columns:1fr} ... }   (line ~686)
 * but the unscoped base rule
 *   .split{display:grid;grid-template-columns:1fr 1fr;...}                 (line ~1163)
 * is declared LATER at the SAME specificity (0,0,1,0). A media query adds no specificity, so the
 * later base rule wins at every width and the collapse never happened anywhere in the app. Every
 * two-column form stayed two-column on a 390px phone; the Customer Interface brand preview's
 * 390px phone frame was squeezed to 111px.
 *
 * THE FIX is one cascade, not per-page patches: the `.split` collapse was deleted from the shared
 * 768px block and re-declared as its own `@media(max-width:768px)` rule placed IMMEDIATELY AFTER
 * the base rule. Same breakpoint, same declaration — it just now comes last.
 *
 * WHAT THIS FILE PROVES:
 *   A. (executing, no browser) parse the REAL <style> block with a brace-depth CSS walker and
 *      assert the EFFECTIVE cascade: the last `.split{grid-template-columns}` declaration in
 *      source order is media-scoped to a max-width, and no unscoped `.split` rule follows it.
 *      This is the exact invariant the bug violated, so it fails on the pre-fix tree.
 *   B. (harness geometry, real Chrome, real bundles, real router) on real routes at
 *      390/520/599/768/834/1180: every rendered `.split` computes to ONE column at <=768 and TWO
 *      columns above it; no `.split` child is narrower than 200px at <=768; the Customer
 *      Interface brand preview phone is full-width (not 111px) at 390; and no `.split` overflows
 *      its own page horizontally.
 *
 * Run:
 *   PLAYWRIGHT_MODULE="<...>/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v447-split-collapse.mjs
 * Set V447_PORT to move off 4483. Skips section B (and says so, loudly, with a non-zero exit)
 * only if PLAYWRIGHT_MODULE cannot be resolved.
 */
import {spawn} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';

const ROOT=new URL('../../',import.meta.url);
const indexHtml=readFileSync(fileURLToPath(new URL('app/index.html',ROOT)),'utf8');

let step='(boot)';
const say=name=>{step=name;process.stdout.write(`STEP ${name}\n`)};
const assertTrue=(condition,message)=>{
  if(!condition)throw new Error(`step ${step}: ${message}`);
  process.stdout.write(`  ok - ${message}\n`);
};

/* ---------------------------------------------------------------- A. the effective cascade ---- */
/* Brace-depth walker (same shape as tests/business-ui/v440-profile-menu-stacking.test.mjs), but
   this one keeps SOURCE ORDER and the media condition, because order is the whole bug. */
function parseCssRules(cssText){
  const text=cssText.replace(/\/\*[\s\S]*?\*\//g,'');
  const rules=[];
  let i=0;const n=text.length;
  function walk(mediaCtx){
    while(i<n){
      while(i<n&&/\s/.test(text[i]))i++;
      if(i>=n)return;
      if(text[i]==='}'){i++;return}
      const headerStart=i;
      while(i<n&&text[i]!=='{'){if(text[i]==='}'){i++;return}i++}
      const header=text.slice(headerStart,i).trim();
      i++;
      if(/^@media|^@supports/.test(header)){walk(header)}
      else if(/^@(-webkit-)?keyframes|^@font-face|^@page/.test(header)){
        let depth=1;
        while(i<n&&depth>0){if(text[i]==='{')depth++;else if(text[i]==='}')depth--;i++}
      }else if(header){
        const declStart=i;let depth=1;
        while(i<n&&depth>0){if(text[i]==='{')depth++;else if(text[i]==='}')depth--;if(depth>0)i++}
        const decl=text.slice(declStart,i);i++;
        rules.push({order:rules.length,selectors:header.split(',').map(s=>s.trim()).filter(Boolean),
          decl,media:mediaCtx});
      }else i++;
    }
  }
  walk(null);
  return rules;
}

const styleStart=indexHtml.indexOf('<style>');
const styleEnd=indexHtml.indexOf('</style>',styleStart);
const rules=parseCssRules(indexHtml.slice(styleStart+7,styleEnd));

/* Specificity of a compound selector, crudely but sufficiently: (#id, .class|[attr]|:pseudo-class,
   element|::pseudo-element). `.split` alone is (0,1,0); `.settings-page .split` is (0,2,0) and is
   NOT a competitor for the bare selector, so only exact `.split` matters here. */
const splitColumnRules=rules
  .filter(r=>r.selectors.includes('.split')&&/grid-template-columns\s*:/.test(r.decl))
  .map(r=>({...r,columns:/grid-template-columns\s*:\s*([^;}]+)/.exec(r.decl)[1].trim()}));

say('A1. sanity: the CSS walker is actually parsing this stylesheet');
assertTrue(rules.length>500,`walker found ${rules.length} rules in the <style> block`);
assertTrue(rules.some(r=>r.selectors.includes('.appbar')&&/z-index\s*:\s*40/.test(r.decl)),
  'it finds the documented .appbar z-index:40, so an empty parse cannot pass vacuously');

say('A2. the .split cascade');
assertTrue(splitColumnRules.length>=2,
  `.split declares grid-template-columns ${splitColumnRules.length} time(s): `
  +splitColumnRules.map(r=>`[${r.media||'base'} -> ${r.columns}]`).join(' '));
const base=splitColumnRules.filter(r=>!r.media);
assertTrue(base.length===1,`exactly one UNSCOPED .split column rule exists (found ${base.length})`);
assertTrue(/1fr\s+1fr|repeat\(\s*2/.test(base[0].columns),
  `the unscoped base is the two-column desktop form (${base[0].columns})`);

const last=splitColumnRules[splitColumnRules.length-1];
/* THE INVARIANT the bug broke: whatever collapses .split must be declared AFTER the base rule,
   because a media query buys no specificity. */
assertTrue(!!last.media&&/max-width/.test(last.media),
  `the LAST .split column declaration in source order is media-scoped (${last.media||'UNSCOPED — '
  +'the collapse can never win'}) -> ${last.columns}`);
assertTrue(/^1fr$|^minmax\(0,\s*1fr\)$/.test(last.columns),
  `and it collapses to a single column (${last.columns})`);
assertTrue(last.order>base[0].order,
  `and it comes after the base rule in source order (${base[0].order} -> ${last.order})`);
const collapseWidth=Number(/max-width\s*:\s*(\d+)px/.exec(last.media)[1]);
assertTrue(collapseWidth>=600&&collapseWidth<=960,
  `the collapse breakpoint is ${collapseWidth}px`);
/* And nothing after it re-opens two columns unscoped. */
assertTrue(!rules.some(r=>r.order>last.order&&!r.media&&r.selectors.includes('.split')
  &&/grid-template-columns/.test(r.decl)),
  'no later unscoped .split rule re-declares the columns');

/* --------------------------------------------------------------------- B. real geometry ------- */
const PORT=Number(process.env.V447_PORT||4483);
const ORIGIN=`http://127.0.0.1:${PORT}`;
const APP_DIR=fileURLToPath(new URL('app/',ROOT));

let playwright;
try{playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright')}
catch{
  process.stdout.write('\nFAILED: section B needs PLAYWRIGHT_MODULE (real-Chrome geometry is the '
    +'point of this file; the cascade parse alone is not proof of layout)\n');
  process.exit(1);
}
const chromium=playwright.chromium||playwright.default?.chromium;

const BIZ='b1111111-1111-4111-8111-111111111111';
const SLUG='testco';

const ownerStub=`(()=>{
  const BIZ='${BIZ}';
  const MODULES=['loyalty','retention','referrals','memberships','clients','sales','services','till',
    'bookings','reports','inventory','appointments','staffperf','packages','branches','expenses'];
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
    products:[{id:'pr1',business_id:BIZ,name:'Cleanser',active:true,price_cents:3200,sku:'CL-1'}],
    packages:[{id:'pk1',business_id:BIZ,name:'5x Facial',active:true,price_cents:40000,sessions:5}],
    clients:[],sales:[],appointments:[],points_ledger:[],memberships:[],client_packages:[],waitlist:[],
    client_field_definitions:[],client_field_values:[],client_field_options:[],branch_hours:[],
    stock_batches:[],product_stock:[],
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
      case 'get_business_public':return {business:bizRow,services:TABLES.services};
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

/* Every rendered .split on the page, with its computed columns and its children's boxes. Nothing
   is looked up by a hand-written list of routes-to-selectors: whatever the route drew is measured. */
const measureSource=`(()=>{
  const boxOf=el=>{const b=el.getBoundingClientRect();
    return {left:b.left,right:b.right,top:b.top,bottom:b.bottom,width:b.width,height:b.height}};
  const visible=el=>{const s=getComputedStyle(el);
    return s.display!=='none'&&s.visibility!=='hidden'&&el.getClientRects().length>0};
  const splits=[];
  for(const el of document.querySelectorAll('.split')){
    if(!visible(el))continue;
    const s=getComputedStyle(el);
    const kids=[...el.children].filter(visible).map(k=>({
      tag:k.tagName.toLowerCase(),cls:String(k.className||'').slice(0,60),box:boxOf(k)}));
    splits.push({cls:String(el.className||''),display:s.display,
      columns:s.gridTemplateColumns,box:boxOf(el),kids});
  }
  const doc=document.scrollingElement||document.documentElement;
  return {splits,viewport:{width:innerWidth,height:innerHeight},
    docScrollWidth:doc.scrollWidth,docClientWidth:doc.clientWidth};
})`;

/* How many columns did the grid RESOLVE to? getComputedStyle returns used pixel tracks, e.g.
   "349.5px 349.5px" for two and "699px" for one — count the tracks. */
const trackCount=columns=>String(columns).trim().split(/\s+/).filter(Boolean).length;

let server=null;
const probe=async()=>{
  try{
    const r=await fetch(`${ORIGIN}/index.html`);
    if(!r.ok)return false;
    const t=await r.text();
    /* Serving SOMETHING is not serving THIS build. The V447 marker comment proves the tree. */
    return t.includes('V447');
  }catch{return false}
};
const serverReady=async()=>{
  if(await probe())return;
  server=spawn('python3',['-m','http.server',String(PORT),'--bind','127.0.0.1'],{cwd:APP_DIR,stdio:'ignore'});
  server.on('error',e=>process.stdout.write(`server spawn error: ${e}\n`));
  for(let i=0;i<80;i++){
    if(await probe())return;
    await new Promise(r=>setTimeout(r,100));
  }
  throw new Error(`static server did not start on ${ORIGIN}, or it is not serving this build`);
};

/* Routes chosen because they are the .split-heaviest surfaces AND cover the three shapes the class
   is used for: a plain two-field form row (branches), a two-CARD panel layout (Customer Interface
   brand: form | live phone preview), and the settings page (its own .settings-page .split rules). */
const ROUTES=[
  ['#/customer-interface/brand','[data-ci-view-v296="brand"] .split'],
  ['#/settings','.settings-page'],
  ['#/packages','#main'],
  ['#/branches','#main'],
  ['#/inventory','#main'],
  ['#/clients','#main']
];
const WIDTHS=[390,520,599,768,834,1180];
const COLLAPSE_AT=collapseWidth;
const MIN_USABLE_CHILD=200;

const browser=await chromium.launch({
  headless:true,
  executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
});
const pageErrors=[];
try{
  await serverReady();
  let measuredSplits=0;

  for(const width of WIDTHS){
    const context=await browser.newContext({viewport:{width,height:900},bypassCSP:true});
    await context.route('**/*',route=>{
      const url=route.request().url();
      if(url.startsWith(ORIGIN)&&!url.includes('/sw.js'))return route.continue();
      return route.abort();
    });
    await context.addInitScript(ownerStub);
    const page=await context.newPage();
    page.on('pageerror',e=>pageErrors.push(`${width}px: ${e}`));
    await page.goto(`${ORIGIN}/index.html#/customer-interface/brand`,{waitUntil:'domcontentloaded'});
    await page.waitForSelector('[data-ci-view-v296="brand"]',{timeout:25000});

    for(const [hash,waitFor] of ROUTES){
      say(`B. ${hash} at ${width}px`);
      await page.evaluate(h=>{location.hash=h},hash);
      try{await page.waitForSelector(waitFor,{timeout:12000})}
      catch{process.stdout.write(`  .. ${hash}: no ${waitFor} rendered here, skipping\n`);continue}
      await page.waitForFunction(()=>document.querySelectorAll('.split').length>0,null,{timeout:12000})
        .catch(()=>{});
      const m=await page.evaluate(`(${measureSource})()`);
      if(!m.splits.length){process.stdout.write(`  .. ${hash}: no visible .split on this route\n`);continue}
      measuredSplits+=m.splits.length;
      const expected=width<=COLLAPSE_AT?1:2;
      for(const s of m.splits){
        const n=trackCount(s.columns);
        assertTrue(n===expected,
          `${hash} @${width}: .split "${s.cls}" resolved to ${n} column(s) [${s.columns}] `
          +`(expected ${expected} at this width)`);
        if(width<=COLLAPSE_AT){
          for(const kid of s.kids){
            assertTrue(kid.box.width>=MIN_USABLE_CHILD||kid.box.width>=s.box.width-1,
              `${hash} @${width}: child ${kid.tag}.${kid.cls||'-'} is ${kid.box.width.toFixed(0)}px wide `
              +`(full column is ${s.box.width.toFixed(0)}px) — not a crushed panel`);
          }
        }
      }
      assertTrue(m.docScrollWidth<=m.docClientWidth+1,
        `${hash} @${width}: the page does not scroll horizontally `
        +`(${m.docScrollWidth} into ${m.docClientWidth})`);
    }

    /* The headline measurement from REG-003: the brand preview phone frame was 111px at 390. */
    say(`B. brand preview phone width at ${width}px`);
    await page.evaluate(()=>{location.hash='#/customer-interface/brand'});
    await page.waitForSelector('[data-ci-view-v296="brand"] .customer-preview-phone-v243',{timeout:20000});
    const phone=await page.evaluate(()=>{
      const el=document.querySelector('[data-ci-view-v296="brand"] .customer-preview-phone-v243');
      const cell=el.closest('.split')?.lastElementChild;
      return {phone:el.getBoundingClientRect().width,
        cell:cell?cell.getBoundingClientRect().width:null,
        split:el.closest('.split')?.getBoundingClientRect().width??null};
    });
    /* Pre-fix at 390 the phone was 131px inside a 169px half-column — 37% of the .split. The
       assertion is a RATIO, not a magic pixel count, so it holds at every collapsed width. */
    const fill=phone.phone/phone.split;
    if(width<=COLLAPSE_AT){
      /* Either it reached its natural 390px frame, or it fills the collapsed row: both mean the
         column is no longer what is squeezing it. 131px in a 354px row was neither. */
      assertTrue(phone.phone>=250&&(phone.phone>=388||fill>=0.8),
        `@${width}: the live-preview phone is ${phone.phone.toFixed(0)}px wide — `
        +`${(fill*100).toFixed(0)}% of its ${phone.split?.toFixed(0)}px .split row `
        +`(pre-fix at 390 it was 131px = 37% of a 354px row)`);
    }else{
      assertTrue(phone.phone>=250,
        `@${width}: the live-preview phone is still ${phone.phone.toFixed(0)}px wide in the `
        +`two-column layout (${(fill*100).toFixed(0)}% of the row) — no wide-width regression`);
    }
    await context.close();
  }

  assertTrue(measuredSplits>=20,
    `${measuredSplits} rendered .split elements were measured across ${ROUTES.length} routes `
    +`x ${WIDTHS.length} widths — the sweep is not vacuous`);
  assertTrue(pageErrors.length===0,`no uncaught page errors (${pageErrors.length})`);
  process.stdout.write('\nV447 .split collapse: all steps passed\n');
}catch(error){
  process.stdout.write(`\nFAILED: ${error.message}\n`);
  if(pageErrors.length)process.stdout.write(`page errors:\n  ${pageErrors.join('\n  ')}\n`);
  process.exitCode=1;
}finally{
  await browser.close();
  if(server)server.kill();
}
