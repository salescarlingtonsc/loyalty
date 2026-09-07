/* nestly_v818 — owner photo 6, measured in a real Chrome.
 *
 * The photo is the till's Add item sheet, Services tab, annotated:
 *   "1. One of the item added and show ON but not shown here.  2. Bundles not shown here."
 * Three services are listed; "Aromatherapy Ritual" — On in the catalogue — is missing, and there
 * is no Bundles heading at all.
 *
 * WHY THIS FILE EXISTS, and what it is NOT. The client code that builds catalog.bundles was NOT
 * changed by v818 and was never wrong: it deliberately withholds a bundle unless EVERY member is
 * sellable at the branch, because a bundle missing a member is not the deal the customer was
 * quoted. The bug was upstream — business_get_checkout_catalogue_v94 counted a pin to a
 * DEACTIVATED branch as a live restriction, so Aromatherapy Ritual came back withheld, and the
 * bundle that contains it was withheld in turn. One cause, both halves of the photo.
 *
 * So the server fix is proved in SQL (db/tests/v818_v819_owner_photo_acceptance.sql, which calls
 * the same RPC as the owner and finds the service and both bundle members). What SQL cannot show
 * is that the SHEET then draws them. This does that, by feeding the till the two catalogue
 * payloads the RPC actually returns — before the fix and after — and reading the rendered sheet.
 *
 * WHAT IT ASSERTS, with the sheet open on the Services tab:
 *   AFTER  1. all four active services are tiles, "Aromatherapy Ritual" among them
 *          2. a "Bundles" heading is rendered
 *          3. "The Elen Ritual" is a tile under it
 *   BEFORE (the same run, catalogue payload as the RPC returned pre-fix — this is the negative
 *          control, and it is in the same file so the two can never drift apart)
 *          4. "Aromatherapy Ritual" is absent — reproducing annotation 1
 *          5. no "Bundles" heading — reproducing annotation 2
 *   and no uncaught page errors in either state.
 *
 * Run:
 *   PLAYWRIGHT_MODULE=/Users/cs/Downloads/loyalty-v577/node_modules/playwright-core/index.js \
 *   node tests/browser/verify-v818-till-add-item-service-and-bundle.mjs
 */
import {spawn} from 'node:child_process';
import {cp,mkdtemp,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {OUTPUTS} from '../../scripts/quality/split-app-bundle.mjs';
import {build} from '../../scripts/quality/stamp-app-bundle.mjs';

const playwright=await import(process.env.PLAYWRIGHT_MODULE||'playwright');
const chromium=playwright.chromium||playwright.default?.chromium;

const REPO_ROOT=fileURLToPath(new URL('../../',import.meta.url));
const PORT=Number(process.env.V818_TILL_PORT||4820);
const ORIGIN=`http://127.0.0.1:${PORT}`;

const buildServedTree=async()=>{
  const dir=await mkdtemp(path.join(tmpdir(),'v818-till-'));
  await cp(path.join(REPO_ROOT,'app'),dir,{recursive:true});
  const {chunks,stamped}=await build(REPO_ROOT);
  for(const [surface,target] of Object.entries(OUTPUTS)){
    await writeFile(path.join(dir,path.basename(target)),chunks[surface]);
  }
  await writeFile(path.join(dir,'index.html'),stamped);
  return dir;
};

let step='(boot)';
const failures=[];
const say=name=>{step=name;process.stdout.write(`STEP ${name}\n`)};
const ok=(condition,message)=>{
  if(condition){process.stdout.write(`  ok   - ${message}\n`);return}
  failures.push(`step ${step}: ${message}`);
  process.stdout.write(`  FAIL - ${message}\n`);
};

let server=null;
const probe=async()=>{
  try{
    const response=await fetch(`${ORIGIN}/app-business.js`);
    if(!response.ok)return false;
    return (await response.text()).includes('tillSheetTabsV373');
  }catch{return false}
};
const serverReady=async()=>{
  const dir=await buildServedTree();
  server=spawn('python3',['-m','http.server',String(PORT),'--bind','127.0.0.1'],{cwd:dir,stdio:'ignore'});
  for(let i=0;i<120;i++){if(await probe())return;await new Promise(r=>setTimeout(r,100))}
  throw new Error(`static server did not start on ${ORIGIN}, or the built chunk lacks the till sheet`);
};

const BIZ='b8180000-0000-4000-8000-000000000820';
const SLUG='v818till';

/* The four services and the bundle are ÉLAN Wellness's real shape. AROMA is the one pinned only
   to the deactivated branch; ELEN is the bundle that contains it. */
const stub=`(()=>{
  const BIZ='${BIZ}',SLUG='${SLUG}';
  const MODULES=['loyalty','clients','sales','services','till','bookings','appointments','reports',
    'inventory','packages','staffperf','branches','staffmembers','settings','setup'];
  const AROMA='svc-aroma',FOOT='svc-foot',HOT='svc-hot',SIG='svc-sig',OIL='prd-oil';
  const services=[
    {id:AROMA,business_id:BIZ,name:'Aromatherapy Ritual',price_cents:10800,duration_min:60,active:true},
    {id:FOOT, business_id:BIZ,name:'Foot Reflexology',   price_cents:5800, duration_min:60,active:true},
    {id:HOT,  business_id:BIZ,name:'Hot Stone Ritual',   price_cents:6800, duration_min:30,active:true},
    {id:SIG,  business_id:BIZ,name:'Signature Relaxation Massage',price_cents:8800,duration_min:60,active:true}];
  const item=(kind,id,name,cents)=>({item_type:kind,item_id:id,name,unit_cents:cents,
    checkout_active:true,branch_available:true,version:0,image_url:''});
  /* Exactly what business_get_checkout_catalogue_v94 returns, in each state. The ONLY difference
     is whether the service pinned to the dead branch survives the branch_available filter. */
  const AFTER=[item('service',AROMA,'Aromatherapy Ritual',10800),
               item('service',FOOT,'Foot Reflexology',5800),
               item('service',HOT,'Hot Stone Ritual',6800),
               item('service',SIG,'Signature Relaxation Massage',8800),
               item('product',OIL,'Massage Oil',3000)];
  const BEFORE=AFTER.filter(row=>row.item_id!==AROMA);
  window.__v818CatalogueState='after';
  const TABLES={
    businesses:[{id:BIZ,slug:SLUG,name:'V818 Till',currency:'SGD',industry:'beauty',points_mode:'both',
      enabled_modules:MODULES,join_enabled:true,brand_color:'#b8562a',created_at:'2026-01-01T00:00:00Z'}],
    branches:[{id:'br1',business_id:BIZ,name:'Main',active:true,is_default:true,billing_state:'active'}],
    branch_hours:[],staff:[{id:'st1',business_id:BIZ,full_name:'Owner Person',role:'owner',
      user_id:'u-owner',active:true,title:'Owner',customer_bookable:true}],
    staff_branches:[{business_id:BIZ,staff_id:'st1',branch_id:'br1'}],
    staff_invites:[],staff_hours:[],staff_services:[],
    services,
    products:[{id:OIL,business_id:BIZ,name:'Massage Oil',retail_price_cents:3000,active:true}],
    /* The bundle from the photo: two members, one of them the withheld service. */
    bundles:[{id:'bn1',business_id:BIZ,name:'The Elen Ritual',price_cents:17000,active:true,
      bundle_items:[{service_id:SIG,product_id:null},{service_id:AROMA,product_id:null}]}],
    clients:[],sales:[],appointments:[],booking_requests:[],module_registry:[],module_templates:[],
    membership_plans:[],loyalty_programs:[],stock_batches:[]
  };
  const chainable=resolveOut=>{
    const q={single:false,head:false,countMode:null,op:'select'};
    const chain={};
    for(const m of ['eq','neq','is','in','not','gte','lte','lt','gt','or','ilike','like','contains',
      'overlaps','order','limit','range','abortSignal','filter','match'])chain[m]=()=>chain;
    chain.select=(cols,opts)=>{if(opts&&opts.count){q.countMode=opts.count;q.head=!!opts.head}return chain};
    chain.single=()=>{q.single=true;return chain};
    chain.maybeSingle=()=>{q.single=true;return chain};
    chain.update=()=>{q.op='update';return chain};
    chain.insert=()=>{q.op='insert';return chain};
    chain.upsert=()=>{q.op='upsert';return chain};
    chain.delete=()=>{q.op='delete';return chain};
    chain.then=(res,rej)=>Promise.resolve(resolveOut(q)).then(res,rej);
    return chain;
  };
  const query=table=>chainable(q=>{
    const rows=(TABLES[table]||[]).slice();
    if(q.op!=='select')return {data:null,error:null};
    if(q.countMode&&q.head)return {data:null,count:rows.length,error:null};
    if(q.single)return {data:rows[0]??null,error:null};
    return {data:rows,count:q.countMode?rows.length:null,error:null};
  });
  const rpcData=name=>{
    switch(name){
      case 'get_my_personas':return {staff:[{business_id:BIZ,business_slug:SLUG,business_name:'V818 Till',
        role:'owner',modules:MODULES}],customer:[],default_route:'#/workspace/'+SLUG+'/dashboard'};
      case 'platform_get_business_control_v94':return {workspace_access:true,quick_earn_catalogue_enabled:true};
      case 'get_my_modules':case 'get_my_modules_at_v115':return {role:'owner',is_super_admin:false,
        modules:MODULES,capabilities:[],module_perms:Object.fromEntries(MODULES.map(m=>[m,'rw']))};
      case 'get_customer_feature_capabilities':return {customer_wallet:true,customer_phone_registration:false};
      case 'get_workspace_locale_preference_v97':return {locale:'en',version:1};
      case 'get_notifications':return {unread:0,items:[]};
      case 'get_business_billing_v125':return {plan:'standard',seats_used:1,seats_included:1,
        monthly_cents:2500,status:'active',currency:'SGD'};
      case 'get_programmes_v314':case 'business_get_programmes_v314':
        return {programmes:[],programmes_contract:'v391'};
      case 'business_get_checkout_catalogue_v94':
        return {platform_allowed:true,enabled:true,settings_version:1,selected_branch_id:'br1',
          branches:[{id:'br1',name:'Main',is_default:true}],
          items:window.__v818CatalogueState==='before'?BEFORE:AFTER};
      case 'business_get_checkout_preferences_v102':
        return {package_earns_points:false,gift_card_sales_enabled:false};
      case 'business_list_branch_packages_v627':return {items:[]};
      default:return null;
    }
  };
  const rpc=name=>chainable(()=>({data:rpcData(name),error:null}));
  const channel=()=>{const c={on:()=>c,subscribe:()=>c,unsubscribe:()=>{}};return c};
  const auth=new Proxy({
    getSession:async()=>({data:{session:{user:{id:'u-owner',email:'owner@v818.co'}}},error:null}),
    getUser:async()=>({data:{user:{id:'u-owner',email:'owner@v818.co'}},error:null}),
    onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
    signOut:async()=>({error:null})
  },{get:(t,k)=>k in t?t[k]:async()=>({data:null,error:null})});
  const client={from:query,rpc,auth,channel,removeChannel(){},
    functions:{invoke:async()=>({data:null,error:null})},
    storage:{from:()=>({getPublicUrl:()=>({data:{publicUrl:''}})})}};
  Object.defineProperty(window,'supabase',{value:{createClient:()=>client},writable:false,configurable:false});
})();`;

/* What the Add item sheet actually shows, read off the rendered dialog. */
const READ=`(()=>{
  const sheet=document.querySelector('#tillAddSheetV373');
  if(!sheet)return {open:false};
  const body=sheet.querySelector('#tillAddSheetBodyV373');
  const text=(body.innerText||'').replace(/\\s+/g,' ');
  return {
    open:true,
    tabs:[...body.querySelectorAll('[data-till-tab-v373]')].map(b=>b.textContent.trim()),
    tiles:[...body.querySelectorAll('.till-cart-catalog button')]
      .map(b=>(b.textContent||'').replace(/\\s+/g,' ').trim()),
    hasBundlesHeading:/\\bBundles\\b/.test(text),
    text
  };
})()`;

const browser=await chromium.launch({
  headless:true,
  executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH
    ||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
});
const pageErrors=[];
try{
  await serverReady();
  const context=await browser.newContext({viewport:{width:1180,height:900},bypassCSP:true});
  await context.route('**/*',route=>{
    const url=route.request().url();
    if(url.startsWith(ORIGIN)&&!url.includes('/sw.js'))return route.continue();
    return route.abort();
  });
  await context.addInitScript(stub);
  const page=await context.newPage();
  page.on('pageerror',error=>pageErrors.push(String(error)));

  const openSheet=async state=>{
    await page.addInitScript(`window.__v818CatalogueState=${JSON.stringify(state)};`);
    await page.goto(`${ORIGIN}/index.html#/till`,{waitUntil:'domcontentloaded'});
    await page.evaluate(s=>{window.__v818CatalogueState=s},state);
    await page.reload({waitUntil:'domcontentloaded'});
    /* The till opens on the phone keypad; the cart (and therefore Add item) only exists once a
       customer is identified or the sale is declared a walk-in. Walk-in is the shorter path and
       still renders the Services and Products tabs, which is what photo 6 is about. */
    await page.waitForSelector('#tWalkin',{timeout:30000});
    await page.click('#tWalkin');
    try{
      await page.waitForSelector('#tAddItemV373',{timeout:15000});
    }catch(error){
      const dump=await page.evaluate(()=>({
        hash:location.hash,
        ids:[...document.querySelectorAll('#main [id]')].map(n=>n.id).slice(0,60),
        text:(document.querySelector('#main')||{innerText:''}).innerText.replace(/\s+/g,' ').slice(0,700)
      }));
      throw new Error('till did not offer Add item: '+JSON.stringify(dump,null,1));
    }
    await page.click('#tAddItemV373');
    await page.waitForSelector('#tillAddSheetV373 .till-cart-catalog',{timeout:30000});
    return page.evaluate(READ);
  };

  say('AFTER the fix — the catalogue the RPC returns today');
  const after=await openSheet('after');
  ok(after.open,'the Add item sheet opened');
  ok(after.tiles.some(t=>/Aromatherapy Ritual/.test(t)),
    `"Aromatherapy Ritual" is a tile — got [${after.tiles.join(' | ')}]`);
  ok(after.tiles.length>=4,`all four active services are offered (${after.tiles.length} tiles)`);
  ok(after.hasBundlesHeading,'a "Bundles" heading is rendered');
  ok(/The Elen Ritual/.test(after.text),'"The Elen Ritual" is offered under it');

  say('BEFORE the fix — the same sheet, the catalogue the RPC used to return');
  const before=await openSheet('before');
  ok(before.open,'the Add item sheet opened');
  ok(!before.tiles.some(t=>/Aromatherapy Ritual/.test(t)),
    'annotation 1 reproduced: "Aromatherapy Ritual" was missing');
  ok(!before.hasBundlesHeading,
    'annotation 2 reproduced: there was no "Bundles" heading, because the bundle lost a member');

  say('no uncaught page errors');
  ok(pageErrors.length===0,`no page errors (${pageErrors.slice(0,2).join(' | ')||'none'})`);

  process.stdout.write('\nSHEET AS RENDERED\n');
  process.stdout.write(`  after  tiles: ${after.tiles.join(' | ')}\n`);
  process.stdout.write(`  after  bundles heading: ${after.hasBundlesHeading}\n`);
  process.stdout.write(`  before tiles: ${before.tiles.join(' | ')}\n`);
  process.stdout.write(`  before bundles heading: ${before.hasBundlesHeading}\n`);
}finally{
  await browser.close().catch(()=>{});
  if(server)server.kill();
}

if(failures.length){
  process.stdout.write(`\n${failures.length} FAILED:\n`+failures.map(f=>`  - ${f}\n`).join(''));
  process.exit(1);
}
process.stdout.write('\nphoto 6 verified in a real browser, with its own before/after control.\n');
