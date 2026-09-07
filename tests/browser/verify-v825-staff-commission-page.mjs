/* nestly_v825 — the Staff commission page, executed in a real Chrome.
 *
 * The page is new code on a route no unit test executes; the repo's own lesson is that a
 * source-regex test stays green while the behaviour is dead. So this boots the REAL business
 * bundle, built from the current app/app.js, against a stub Supabase whose commission-lines RPC
 * answers with the shape the owner asked for — two members, a walk-in, a reversed sale — and reads
 * what was rendered.
 *
 * WHAT IT ASSERTS
 *   1. The page opens on Today, with This week / This month / This year offered.
 *   2. All / <member> chips exist, one per member plus Unattributed, and each names its total.
 *   3. The table lists every line with customer, item, member and commission.
 *   4. The reversed sale is drawn, marked Reversed, and counted in NO total: the All total and
 *      the member's chip both exclude it.
 *   5. Clicking a member chip narrows the table to that member's lines only.
 *   6. No uncaught page errors.
 *
 * Run:
 *   PLAYWRIGHT_MODULE=/Users/cs/Downloads/loyalty-v577/node_modules/playwright-core/index.js \
 *   node tests/browser/verify-v825-staff-commission-page.mjs
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
const PORT=Number(process.env.V825_PORT||4825);
const ORIGIN=`http://127.0.0.1:${PORT}`;

const buildServedTree=async()=>{
  const dir=await mkdtemp(path.join(tmpdir(),'v825-app-'));
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
    return (await response.text()).includes('business_staff_commission_lines_v825');
  }catch{return false}
};
const serverReady=async()=>{
  const dir=await buildServedTree();
  server=spawn('python3',['-m','http.server',String(PORT),'--bind','127.0.0.1'],{cwd:dir,stdio:'ignore'});
  for(let i=0;i<120;i++){if(await probe())return;await new Promise(r=>setTimeout(r,100))}
  throw new Error(`static server did not start on ${ORIGIN}, or the built chunk is the wrong tree`);
};

const BIZ='b8250000-0000-4000-8000-000000000825';
const SLUG='v825co';
const NOW=new Date();
const at=minutesAgo=>new Date(NOW.getTime()-minutesAgo*60000).toISOString();

const ownerStub=`(()=>{
  const BIZ='${BIZ}',SLUG='${SLUG}';
  const MODULES=['loyalty','clients','sales','services','till','bookings','appointments','reports',
    'inventory','packages','staffperf','branches','staffmembers','settings','setup','dailyreport','customerintel'];
  const bizRow={id:BIZ,slug:SLUG,name:'V825 Co',currency:'SGD',industry:'beauty',points_mode:'both',
    enabled_modules:MODULES,join_enabled:true,brand_color:'#b8562a',created_at:'2026-01-01T00:00:00Z'};
  const TABLES={
    businesses:[bizRow],
    branches:[{id:'br1',business_id:BIZ,name:'Main',active:true,is_default:true,billing_state:'active'}],
    staff:[{id:'st-john',business_id:BIZ,full_name:'John',role:'staff',user_id:null,active:true},
           {id:'st-jess',business_id:BIZ,full_name:'Jess',role:'staff',user_id:null,active:true}],
    staff_branches:[],services:[],products:[],clients:[],sales:[],appointments:[],
    module_registry:[],module_templates:[],loyalty_programs:[],waitlist:[]
  };
  const line=(o)=>Object.assign({sale_id:'s1',line_id:'l1',occurred_at:'${at(30)}',branch_id:'br1',sale_kind:'quick_sale',
    client_id:'c1',client_name:'Debby',staff_id:'st-john',staff_name:'John',item_type:'service',description:'facial',
    qty:1,line_cents:3000,rate_bps:1000,flat_cents:null,commission_cents:300,bundle_id:null,
    reversed:false,reversed_at:null,reversal_reason:null},o);
  const LINES=[
    line({}),
    line({sale_id:'s1',line_id:'l2',description:'Lotion 50ml',item_type:'retail',line_cents:5000,rate_bps:2000,commission_cents:1000}),
    line({sale_id:'s2',line_id:'l3',occurred_at:'${at(90)}',staff_id:'st-jess',staff_name:'Jess',client_id:null,client_name:null,
      description:'spa · Rainbow special',bundle_id:'bd1',line_cents:4000,rate_bps:500,commission_cents:200}),
    line({sale_id:'s3',line_id:'l4',occurred_at:'${at(200)}',staff_id:'st-jess',staff_name:'Jess',description:'SPAAAA',
      line_cents:18800,rate_bps:1000,commission_cents:1880,reversed:true,reversed_at:'${at(100)}',reversal_reason:'customer changed her mind'}),
    line({sale_id:'s4',line_id:'l5',occurred_at:'${at(240)}',staff_id:null,staff_name:null,description:'Pillow for Massage',
      item_type:'retail',line_cents:5800,rate_bps:0,commission_cents:0})
  ];
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
  window.__v825RpcCalls=[];
  const rpcData=(name,args)=>{
    window.__v825RpcCalls.push({name,args});
    switch(name){
      case 'get_my_personas':return {staff:[{business_id:BIZ,business_slug:SLUG,business_name:'V825 Co',
        role:'owner',modules:MODULES}],customer:[],default_route:'#/workspace/'+SLUG+'/dashboard'};
      case 'platform_get_business_control_v94':return {workspace_access:true,quick_earn_catalogue_enabled:true};
      case 'get_my_modules':case 'get_my_modules_at_v115':return {role:'owner',is_super_admin:false,
        modules:MODULES,capabilities:['view_finance'],module_perms:Object.fromEntries(MODULES.map(m=>[m,'rw']))};
      case 'get_customer_feature_capabilities':return {customer_wallet:true,customer_phone_registration:false};
      case 'get_workspace_locale_preference_v97':return {locale:'en',version:1};
      case 'get_notifications':return {unread:0,items:[]};
      case 'get_business_billing_v125':return {plan:'standard',seats_used:1,seats_included:1,
        monthly_cents:2500,status:'active',currency:'SGD'};
      case 'get_programmes_v314':case 'business_get_programmes_v314':
        return {programmes:[],programmes_contract:'v391'};
      case 'require_module_scope_v145':return {ok:true};
      case 'business_staff_commission_lines_v825':return LINES;
      default:return null;
    }
  };
  const rpc=(name,args,opts)=>chainable(q=>{
    const data=rpcData(name,args);
    return {data,count:Array.isArray(data)&&opts&&opts.count?data.length:null,error:null};
  });
  const channel=()=>{const c={on:()=>c,subscribe:()=>c,unsubscribe:()=>{}};return c};
  const auth=new Proxy({
    getSession:async()=>({data:{session:{user:{id:'u-owner',email:'owner@v825.co'}}},error:null}),
    getUser:async()=>({data:{user:{id:'u-owner',email:'owner@v825.co'}},error:null}),
    onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
    signOut:async()=>({error:null})
  },{get:(t,k)=>k in t?t[k]:async()=>({data:null,error:null})});
  const client={from:query,rpc,auth,channel,removeChannel(){},
    functions:{invoke:async()=>({data:null,error:null})},
    storage:{from:()=>({getPublicUrl:()=>({data:{publicUrl:''}})})}};
  Object.defineProperty(window,'supabase',{value:{createClient:()=>client},writable:false,configurable:false});
})();`;

const READ=`(()=>{
  const text=el=>(el?.textContent||'').replace(/\\s+/g,' ').trim();
  return {
    title:text(document.querySelector('.cui-page-title h1')),
    periods:[...document.querySelectorAll('[data-commission-period-v825]')].map(b=>({kind:b.dataset.commissionPeriodV825,active:b.classList.contains('act'),label:text(b)})),
    from:document.getElementById('pf')?.value,to:document.getElementById('pt')?.value,
    chips:[...document.querySelectorAll('[data-commission-staff-v825]')].map(b=>({key:b.dataset.commissionStaffV825,label:text(b),active:b.classList.contains('act')})),
    cards:[...document.querySelectorAll('#staffRankSummary article')].map(a=>text(a)),
    rows:[...document.querySelectorAll('#pbody tbody tr')].filter(tr=>!tr.classList.contains('total-row')).map(tr=>({
      text:text(tr),reversed:tr.classList.contains('staff-commission-reversed-v825'),
      cells:[...tr.querySelectorAll('td')].map(td=>text(td))})),
    total:text(document.querySelector('#pbody tr.total-row')),
    hash:location.hash
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
  const context=await browser.newContext({viewport:{width:1440,height:1000},bypassCSP:true});
  await context.route('**/*',route=>{
    const url=route.request().url();
    if(url.startsWith(ORIGIN)&&!url.includes('/sw.js'))return route.continue();
    return route.abort();
  });
  await context.addInitScript(ownerStub);
  const page=await context.newPage();
  page.on('pageerror',error=>pageErrors.push(String(error)));

  say('open Staff commission');
  await page.goto(`${ORIGIN}/index.html#/staffperf`,{waitUntil:'domcontentloaded'});
  await page.waitForFunction(()=>document.querySelectorAll('#pbody tbody tr').length>0,null,{timeout:30000});
  let seen=await page.evaluate(READ);
  ok(seen.title==='Staff commission',`title reads "Staff commission" — got "${seen.title}"`);

  say('1. opens on Today with the four presets');
  ok(seen.periods.map(p=>p.kind).join(',')==='today,week,month,year',`presets are today,week,month,year — got ${seen.periods.map(p=>p.kind).join(',')}`);
  ok(seen.periods.find(p=>p.kind==='today')?.active===true,'Today is the active preset');
  ok(seen.from===seen.to&&/^\d{4}-\d{2}-\d{2}$/.test(seen.from),`from and to are the same day — ${seen.from} → ${seen.to}`);

  say('2. All / member chips, each with its total');
  ok(seen.chips.map(c=>c.key).join(',')==='all,st-jess,st-john,__unattributed',`chips are All, Jess, John, Unattributed — got ${seen.chips.map(c=>c.key).join(',')}`);
  const chip=key=>seen.chips.find(c=>c.key===key)?.label||'';
  ok(/^All\s*SGD 15\.00$/.test(chip('all')),`All total is SGD 15.00 (3.00 + 10.00 + 2.00, reversed 18.80 excluded) — got "${chip('all')}"`);
  ok(/^John\s*SGD 13\.00$/.test(chip('st-john')),`John's chip says SGD 13.00 — got "${chip('st-john')}"`);
  ok(/^Jess\s*SGD 2\.00$/.test(chip('st-jess')),`Jess's chip says SGD 2.00, her reversed 18.80 excluded — got "${chip('st-jess')}"`);

  say('3. every line is listed with customer, item, member and commission');
  ok(seen.rows.length===5,`5 lines rendered — got ${seen.rows.length}`);
  const row=needle=>seen.rows.find(r=>r.text.includes(needle));
  ok(row('facial')&&row('facial').cells[1]==='Debby'&&row('facial').cells[3]==='John'&&row('facial').cells[6]==='SGD 3.00',
    `facial: Debby · John · SGD 3.00 — got ${JSON.stringify(row('facial')?.cells)}`);
  ok(row('Rainbow special')&&row('Rainbow special').cells[1]==='Walk-in'&&/bundle/.test(row('Rainbow special').cells[2]),
    `bundle member line reads Walk-in and is tagged bundle — got ${JSON.stringify(row('Rainbow special')?.cells)}`);
  ok(row('Pillow')&&row('Pillow').cells[3]==='Unattributed',`a line with no member reads Unattributed — got ${JSON.stringify(row('Pillow')?.cells)}`);

  say('4. the reversed sale is shown as reversed and counted nowhere');
  const rev=row('SPAAAA');
  ok(rev&&rev.reversed&&rev.cells[7]==='Reversed',`SPAAAA row is marked Reversed — got ${JSON.stringify(rev?.cells)}`);
  ok(/Total counted SGD 11\.80/.test(seen.total)===false&&/SGD 15\.00/.test(seen.total),`the total row counts SGD 15.00 — got "${seen.total}"`);
  ok(seen.cards.some(c=>/Sales reversed\s*1(?!\d)/.test(c)),`the summary reports 1 reversed sale — got ${JSON.stringify(seen.cards)}`);

  say('5. a member chip narrows the table');
  await page.click('[data-commission-staff-v825="st-jess"]');
  await page.waitForTimeout(200);
  seen=await page.evaluate(READ);
  ok(seen.rows.length===2&&seen.rows.every(r=>r.cells[3]==='Jess'),`Jess shows her 2 lines only — got ${seen.rows.map(r=>r.cells[3]).join(',')}`);
  ok(/SGD 2\.00/.test(seen.total),`Jess's total counts SGD 2.00 — got "${seen.total}"`);
  ok(seen.cards[0]&&/Commission earned\s*SGD 2\.00\s*Jess/.test(seen.cards[0]),`Jess's card reads SGD 2.00 — got "${seen.cards[0]}"`);

  say('the reader was asked for Today, business-wide');
  const calls=await page.evaluate(()=>window.__v825RpcCalls.filter(c=>c.name==='business_staff_commission_lines_v825'));
  ok(calls.length>=1&&calls[0].args.p_branch===null&&calls[0].args.p_business===BIZ,`RPC called with p_branch null — got ${JSON.stringify(calls[0]?.args)}`);

  say('6. no uncaught page errors');
  ok(pageErrors.length===0,`no page errors (${pageErrors.slice(0,2).join(' | ')||'none'})`);
  await page.click('[data-commission-staff-v825="all"]');
  await page.waitForTimeout(200);
  await page.screenshot({path:process.env.V825_SHOT||'/tmp/v825-staff-commission.png',fullPage:true});
}finally{
  await browser.close().catch(()=>{});
  if(server)server.kill();
}

if(failures.length){
  process.stdout.write(`\n${failures.length} FAILED:\n`+failures.map(f=>`  - ${f}\n`).join(''));
  process.exit(1);
}
process.stdout.write('\nStaff commission page verified in a real browser.\n');
