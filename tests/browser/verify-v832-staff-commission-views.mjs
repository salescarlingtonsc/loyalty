/* nestly_v832 — the two new answers on the Staff commission page, executed in a real Chrome.
 *
 * v832 added a "By line | By sale" toggle (opening on By sale), an item-kind select, a free-text
 * search, and a Team comparison card. The unit tests execute the two pure helpers behind all of
 * that; this boots the REAL business bundle against the same stub Supabase the v825 proof uses and
 * reads what a browser actually painted, because the repo's own lesson is that a helper can be
 * correct while the page never calls it.
 *
 * WHAT IT ASSERTS
 *   1. The page opens on By sale: one row per sale, its lines beneath it, the reversed sale
 *      flagged and counted in no total.
 *   2. By line still draws the flat list it always did.
 *   3. The item-kind select filters both views, and the sale header subtotals only the lines it
 *      is showing, saying so when it hides some.
 *   4. The search reads the customer and the item.
 *   5. The Team comparison card ranks the members, states each one's average and biggest ticket,
 *      and prints ONE insight sentence.
 *   6. The four summary cards follow the filter, so the numbers reconcile with the rows below.
 *   7. No uncaught page errors.
 *
 * Run:
 *   PLAYWRIGHT_MODULE=/Users/cs/Downloads/loyalty-v577/node_modules/playwright-core/index.js \
 *   node tests/browser/verify-v832-staff-commission-views.mjs
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
const PORT=Number(process.env.V832_PORT||4832);
const ORIGIN=`http://127.0.0.1:${PORT}`;

const buildServedTree=async()=>{
  const dir=await mkdtemp(path.join(tmpdir(),'v832-app-'));
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
    line({sale_id:'s1',line_id:'l2',description:'Lotion 50ml',item_type:'retail',qty:2,line_cents:5000,rate_bps:2000,commission_cents:1000}),
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
  const table=()=>document.querySelector('#pbody table');
  return {
    view:[...document.querySelectorAll('[data-commission-view-v832]')].map(b=>({kind:b.dataset.commissionViewV832,active:b.classList.contains('act'),label:text(b)})),
    kindOptions:[...document.querySelectorAll('#staffCommissionKindV832 option')].map(o=>o.value),
    headers:[...(table()?.querySelectorAll('thead th')||[])].map(th=>text(th)),
    cards:[...document.querySelectorAll('#staffRankSummary article')].map(a=>text(a)),
    responsive:document.querySelector('#pbody table')?.getAttribute('data-responsive'),
    theadDisplay:(()=>{const h=document.querySelector('#pbody table thead');return h?getComputedStyle(h).display:''})(),
    saleRows:[...document.querySelectorAll('#pbody tr.staff-commission-sale-v832')].map(tr=>({
      text:text(tr),cells:[...tr.querySelectorAll(':scope > td')].map(td=>text(td)),
      lines:(()=>{const out=[];let next=tr.nextElementSibling;
        while(next&&next.classList.contains('staff-commission-sale-line-v832')){
          out.push([...next.querySelectorAll('td')].map(td=>text(td)));next=next.nextElementSibling}
        return out})()})),
    flatRows:[...document.querySelectorAll('#pbody > .cui-table-wrap > table > tbody > tr')]
      .filter(tr=>!tr.classList.contains('total-row')&&!tr.classList.contains('staff-commission-sale-v832')
        &&!tr.classList.contains('staff-commission-sale-line-v832'))
      .map(tr=>({text:text(tr),cells:[...tr.querySelectorAll('td')].map(td=>text(td))})),
    total:text(document.querySelector('#pbody tr.total-row')),
    empty:text(document.querySelector('#pbody .cui-empty-state'))||text(document.querySelector('#pbody')),
    compare:{
      hidden:!!document.getElementById('staffCommissionCompareV832')?.hidden,
      headers:[...document.querySelectorAll('#staffCommissionCompareV832 thead th')].map(th=>text(th)),
      rows:[...document.querySelectorAll('#staffCommissionCompareV832 tbody tr')].map(tr=>
        [...tr.querySelectorAll('td')].map(td=>text(td))),
      insight:text(document.querySelector('.staff-commission-insight-v832')),
      explainer:text(document.querySelector('#staffCommissionCompareV832 p.muted.small'))
    }
  };
})()`;

const browser=await chromium.launch({
  headless:true,
  executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH
    ||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
});
const pageErrors=[];
const SHOT_DIR=process.env.V832_SHOT_DIR||'/tmp';
try{
  await serverReady();
  const context=await browser.newContext({viewport:{width:1440,height:1100},bypassCSP:true});
  await context.route('**/*',route=>{
    const url=route.request().url();
    if(url.startsWith(ORIGIN)&&!url.includes('/sw.js'))return route.continue();
    return route.abort();
  });
  await context.addInitScript(ownerStub);
  const page=await context.newPage();
  page.on('pageerror',error=>pageErrors.push(String(error)));
  const settle=async()=>{await page.waitForTimeout(220);return page.evaluate(READ)};

  say('open Staff commission');
  await page.goto(`${ORIGIN}/index.html#/staffperf`,{waitUntil:'domcontentloaded'});
  await page.waitForFunction(()=>document.querySelectorAll('#pbody tbody tr').length>0,null,{timeout:30000});
  let seen=await page.evaluate(READ);

  say('1. it opens on By sale, one row per sale, lines beneath');
  ok(seen.view.map(v=>`${v.label}${v.active?'*':''}`).join('|')==='By line|By sale*',
    `the toggle offers By line and By sale, opening on By sale — got ${JSON.stringify(seen.view)}`);
  ok(seen.headers.slice(0,8).join('|')==='When|Customer|Item|Team member|Amount|Rate|Commission|Status',
    `both views draw the same columns — got ${JSON.stringify(seen.headers.slice(0,8))}`);
  ok(seen.responsive==='true',`no colspan survives, so CUI leaves the table responsive — got data-responsive="${seen.responsive}"`);
  ok(seen.saleRows.length===4,`the five lines are four sales — got ${seen.saleRows.length}`);
  const first=seen.saleRows[0];
  ok(first.cells[1]==='Debby'&&first.cells[2]==='Quick sale · 2 lines'&&first.cells[3]==='John'
    &&first.cells[4]==='SGD 80.00'&&first.cells[6]==='SGD 13.00',
    `John's two-line sale for Debby totals SGD 80.00 / SGD 13.00 across 2 lines — got ${JSON.stringify(first.cells)}`);
  ok(seen.saleRows.map(r=>r.lines.length).join(',')==='2,1,1,1',
    `every sale carries its own lines beneath it — got ${seen.saleRows.map(r=>r.lines.length).join(',')}`);
  ok(first.lines.map(l=>l[2]).join('|')==='↳ facial · service|↳ Lotion 50ml · product × 2',
    `the lines name both items, indented — got ${JSON.stringify(first.lines.map(l=>l[2]))}`);
  ok(first.lines[1][4]==='SGD 50.00'&&first.lines[1][5]==='20%'&&first.lines[1][6]==='SGD 10.00'
    &&[0,1,3,7].every(i=>first.lines[1][i]===''),
    `the retail line keeps its own amount, rate and SGD 10.00 and leaves the sale-level cells blank (they are hidden on mobile by td:empty) — got ${JSON.stringify(first.lines[1])}`);
  const reversedRow=seen.saleRows.find(r=>r.cells[7]==='Reversed');
  ok(!!reversedRow&&reversedRow.cells[6]==='SGD 18.80',
    `the reversed sale is still listed, flagged, and shows its struck-through SGD 18.80 — got ${JSON.stringify(reversedRow?.cells)}`);
  ok(seen.saleRows.filter(r=>r.cells[7]==='Counted').length===3,'the other three sales are counted');
  ok(/SGD 15\.00/.test(seen.total),`the total counts SGD 15.00, the reversed SGD 18.80 excluded — got "${seen.total}"`);

  say('5. the Team comparison card ranks the members');
  ok(seen.compare.hidden===false,'the comparison card is shown');
  ok(seen.compare.headers.join('|')==='Team member|Sales|Avg per sale|Biggest sale|Amount sold|Share|Commission|Effective rate|Mix',
    `the comparison answers deals, ticket size and cost per dollar — got ${JSON.stringify(seen.compare.headers)}`);
  ok(seen.compare.rows.length===4,`two members, one unattributed line and the team row — got ${seen.compare.rows.length}`);
  ok(seen.compare.rows[0][0]==='John'&&seen.compare.rows[0][1]==='1'&&seen.compare.rows[0][2]==='SGD 80.00'
    &&seen.compare.rows[0][3]==='SGD 80.00'&&seen.compare.rows[0][7]==='16.25%',
    `John: 1 sale, SGD 80.00 average, an effective 16.25% — got ${JSON.stringify(seen.compare.rows[0])}`);
  ok(seen.compare.rows[1][0]==='Jess'&&seen.compare.rows[1][1]==='1'&&seen.compare.rows[1][2]==='SGD 40.00'
    &&seen.compare.rows[1][8]==='Bundles 100%',
    `Jess sold one bundle worth SGD 40.00 — got ${JSON.stringify(seen.compare.rows[1])}`);
  ok(seen.compare.rows[2][0]==='Unattributed'&&seen.compare.rows[3][0]==='Whole team',
    `unattributed is listed last, above the team line — got ${JSON.stringify(seen.compare.rows.map(r=>r[0]))}`);
  ok(seen.compare.rows[3][1]==='3'&&seen.compare.rows[3][4]==='SGD 178.00',
    `the team line is three counted sales worth SGD 178.00 — got ${JSON.stringify(seen.compare.rows[3])}`);
  ok(seen.compare.insight==='Sales are level (1 each); John has the biggest average sale (SGD 80.00).', // every member has one sale — a tie is not a lead
    `one sentence, naming only a real member — got "${seen.compare.insight}"`);
  ok(!/Unattributed/.test(seen.compare.insight),'the unattributed line is never named as a person');
  ok(/Effective rate = commission ÷ amount sold/.test(seen.compare.explainer),
    `the card explains its own arithmetic — got "${seen.compare.explainer}"`);
  await page.screenshot({path:`${SHOT_DIR}/v832-staff-commission-by-sale.png`,fullPage:true});

  say('2. By line still draws the flat list');
  await page.click('[data-commission-view-v832="line"]');
  seen=await settle();
  ok(seen.headers.slice(0,8).join('|')==='When|Customer|Item|Team member|Amount|Rate|Commission|Status',
    `the line table is unchanged — got ${JSON.stringify(seen.headers.slice(0,8))}`);
  ok(seen.flatRows.length===5,`all five lines are listed — got ${seen.flatRows.length}`);
  ok(seen.saleRows.length===0,'no sale headers survive into the line view');
  ok(seen.responsive==='true',`the line view is responsive too — got data-responsive="${seen.responsive}"`);
  ok(/SGD 15\.00/.test(seen.total),`the same total — got "${seen.total}"`);
  await page.screenshot({path:`${SHOT_DIR}/v832-staff-commission-by-line.png`,fullPage:true});

  say('3. the item-kind filter narrows both views and subtotals only what it shows');
  ok(seen.kindOptions.join(',')==='all,service,product,package,bundle,custom,discount,other',
    `every kind is offered — got ${seen.kindOptions.join(',')}`);
  await page.selectOption('#staffCommissionKindV832','product');
  seen=await settle();
  ok(seen.flatRows.length===2&&seen.flatRows.every(r=>/Lotion|Pillow/.test(r.text)),
    `two retail lines survive — got ${seen.flatRows.map(r=>r.cells[2]).join(' / ')}`);
  ok(/SGD 10\.00/.test(seen.total),`the total follows the filter — got "${seen.total}"`);
  ok(seen.cards[0]&&/SGD 10\.00/.test(seen.cards[0])&&/filtered/.test(seen.cards[0]),
    `the summary card says it is filtered — got "${seen.cards[0]}"`);
  await page.click('[data-commission-view-v832="sale"]');
  seen=await settle();
  ok(seen.saleRows.length===2,`the sale view shows the two sales holding a product — got ${seen.saleRows.length}`);
  ok(/Quick sale · 1 of 2 lines/.test(seen.saleRows[0].cells[2])&&seen.saleRows[0].cells[4]==='SGD 50.00',
    `the two-line sale says 1 of 2 and subtotals only the shown line — got ${JSON.stringify(seen.saleRows[0].cells)}`);
  ok(/1 line hidden by the current filter, so this subtotal covers only the lines shown\./.test(seen.saleRows[0].cells[2]),
    `and says so in words — got "${seen.saleRows[0].cells[2]}"`);
  ok(seen.saleRows[0].lines.length===1,`only the matching line is listed — got ${seen.saleRows[0].lines.length}`);

  say('4. the search reads the customer and the item');
  await page.selectOption('#staffCommissionKindV832','all');
  await page.fill('#staffCommissionSearchV832','debby');
  seen=await settle();
  ok(seen.saleRows.length===3&&seen.saleRows.every(r=>r.cells[1]==='Debby')&&seen.saleRows[0].lines.length===2,
    `a customer match brings her three sales whole — got ${JSON.stringify(seen.saleRows.map(r=>r.cells))}`);
  await page.fill('#staffCommissionSearchV832','LOTION');
  seen=await settle();
  ok(seen.saleRows.length===1&&/1 of 2 lines/.test(seen.saleRows[0].cells[2]),
    `an item match is case-insensitive and shows the matching line only — got ${JSON.stringify(seen.saleRows.map(r=>r.cells))}`);
  ok(seen.compare.rows.length===2&&seen.compare.rows[0][0]==='John'&&!seen.compare.insight,
    `the comparison follows the filter and drops the sentence when one member is left — got ${JSON.stringify(seen.compare.rows.map(r=>r[0]))}`);
  await page.fill('#staffCommissionSearchV832','nothing sold like this');
  seen=await settle();
  ok(/Nothing matches these filters/.test(seen.empty),`an empty filter says so — got "${seen.empty.slice(0,80)}"`);

  say('6. Clear filters puts everything back');
  await page.click('#staffCommissionClearV832');
  seen=await settle();
  ok(seen.saleRows.length===4&&/SGD 15\.00/.test(seen.total),
    `all four sales and the full total return — got ${seen.saleRows.length} / "${seen.total}"`);

  say('7. no uncaught page errors');
  ok(pageErrors.length===0,`no page errors (${pageErrors.slice(0,2).join(' | ')||'none'})`);
}finally{
  await browser.close().catch(()=>{});
  if(server)server.kill();
}

if(failures.length){
  process.stdout.write(`\n${failures.length} FAILED:\n`+failures.map(f=>`  - ${f}\n`).join(''));
  process.exit(1);
}
process.stdout.write('\nStaff commission By sale / By line, the filters and the Team comparison verified in a real browser.\n');
