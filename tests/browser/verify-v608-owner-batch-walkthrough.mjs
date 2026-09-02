/* nestly_v608 — the owner's eight-item batch, walked in a real browser.
 *
 * WHY THIS FILE EXISTS. Twice in this batch I shipped work that passed every source-level test and
 * was wrong on screen: the join sheet that only ever appeared once per device (v596 -> v599), and
 * the two new package date columns, which printed "2026-07-01 10:00" because sgt() returns a date
 * AND a time and the helper split on a comma that string does not contain. The owner asked for
 * dd/mm/yy. Nothing that greps source could have caught either one — only looking could.
 *
 * So this boots the REAL bundles built from the current app.js in a real Chrome, signs in as an
 * owner against a fixture Supabase, and visits every screen the batch changed:
 *   v604 staff roster — column order, and the Edit chip drawn in the row
 *   v603 customer packages — the two date columns, their FORMAT, and the per-row History dialog
 *   v606 branches — opening hours on the branch's own card
 *   v606 Operations setup — the Reminder & Notification page
 *   v607 Subscription — named for the plan, with the entitlement lists gone
 *   v600 Block time — the Every week mode, which no source test could reach at all
 *
 * Run:
 *   PLAYWRIGHT_MODULE="<repo>/node_modules/playwright-core/index.js" \
 *   PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
 *   node tests/browser/verify-v608-owner-batch-walkthrough.mjs
 */
import {spawn} from 'node:child_process';
import {cp,mkdtemp,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {OUTPUTS} from '../../scripts/quality/split-app-bundle.mjs';
import {build} from '../../scripts/quality/stamp-app-bundle.mjs';
import {fileURLToPath} from 'node:url';
const ROOT=fileURLToPath(new URL('../../',import.meta.url));
const pw=await import(process.env.PLAYWRIGHT_MODULE);
const chromium=pw.chromium||pw.default?.chromium;
const PORT=Number(process.env.V608_PORT||4611), ORIGIN=`http://127.0.0.1:${PORT}`;
const dir=await mkdtemp(path.join(tmpdir(),'v608-'));
await cp(path.join(ROOT,'app'),dir,{recursive:true});
const {chunks,stamped}=await build(ROOT);
for(const [s,t] of Object.entries(OUTPUTS)) await writeFile(path.join(dir,path.basename(t)),chunks[s]);
await writeFile(path.join(dir,'index.html'),stamped);
const server=spawn('python3',['-m','http.server',String(PORT),'--bind','127.0.0.1'],{cwd:dir,stdio:'ignore'});
await new Promise(r=>setTimeout(r,1500));

const BIZ='b6080000-0000-4000-8000-000000000608', SLUG='v608co';
/* F013: no production tenant's enabled_modules/platform_module_overrides_v94 ever contains
   'settings' (it is not a module_registry key at all — Settings, Branches and Reminder &
   Notification are all owner-role-gated surfaces, not sector entitlements). This fixture used
   to include 'settings' anyway, which let the walkthrough open #/remindernotify against an
   entitlement the server can never produce and mask the real bug (F013: the route was gated on
   canReadModule('settings'), unreachable for every real tenant including the owner). Kept to a
   real sector-bundle-shaped list so this walkthrough proves the real gate. */
const MODULES=['dashboard','till','clients','appointments','sales','services','bookings','waitlist',
  'inventory','packages','loyalty','retention','referrals','memberships','giftcards','reports',
  'customerintel','staffperf','dailyreport','pnl','expenses'];
const stub=`(()=>{
 const MOD=${JSON.stringify(MODULES)};
 const BIZ='${BIZ}';
 const biz={id:BIZ,slug:'${SLUG}',name:'V608 Co',currency:'SGD',industry:'salon',enabled_modules:MOD,
   created_at:'2026-01-01T00:00:00Z',brand_color:'#FF6B5E',join_enabled:true,booking_staff_choice:true};
 const T={
  businesses:[biz],
  branches:[{id:'br1',business_id:BIZ,name:'Orchard',is_default:true,active:true,billing_state:'active',timezone:'Asia/Singapore',address:'313 Orchard Rd'},
            {id:'br2',business_id:BIZ,name:'Bedok',is_default:false,active:true,billing_state:'active',timezone:'Asia/Singapore',address:'1 Bedok Rd'}],
  staff:[{id:'st1',business_id:BIZ,full_name:'Chuan',role:'owner',user_id:'u1',active:true,access_state:'approved',customer_bookable:true,title:'Senior Therapist',commission_service_bps:1000,commission_product_bps:0,email:'o@v608.co',phone:'81863833',modules:null,module_perms:null},
         {id:'st2',business_id:BIZ,full_name:'Kelvin',role:'staff',user_id:null,active:true,access_state:null,customer_bookable:true,title:'Junior Therapist',commission_service_bps:null,commission_product_bps:null,email:null,phone:null,modules:null,module_perms:null}],
  staff_branches:[{staff_id:'st1',branch_id:'br1'},{staff_id:'st2',branch_id:'br1'}],
  service_branches:[{service_id:'sv1',branch_id:'br1'}],
  services:[{id:'sv1',business_id:BIZ,name:'Facial',variant_label:null,price_cents:5000,duration_min:60,buffer_before_min:0,buffer_after_min:0,active:true}],
  clients:[{id:'c1',business_id:BIZ,full_name:'Mei',phone:'80000001',phone_norm:'80000001',email:''}],
  branch_hours:[{branch_id:'br1',business_id:BIZ,weekday:1,opens_at:'10:00',closes_at:'19:00'}],
  staff_hours:[],staff_off_days:[],branch_breaks:[],staff_recurring_off_days:[{staff_id:'st1',weekday:3}],
  package_plans:[{id:'pl1',business_id:BIZ,name:'5x Facial',price_cents:40000,sessions:5,service_id:'sv1',active:true,version_no:2,expiry_days:null,retired_at:null,list_value_cents_snapshot:25000,created_at:'2026-01-02T00:00:00Z'}],
  client_packages:[{plan_id:'pl1'}],
  appointments:[],sales:[],points_ledger:[],memberships:[],module_registry:[],business_programmes:[],
  staff_blocked_times:[],booking_requests:[],products:[],client_field_definitions:[],client_field_values:[],client_field_options:[]
 };
 const chain=(out,t)=>{const q={single:false,head:false,countMode:null,t};const c={};
  for(const m of ['neq','is','in','not','gte','lte','lt','gt','or','ilike','like','contains','overlaps','order','limit','range','abortSignal','filter','match','eq'])c[m]=()=>c;
  c.select=(x,o)=>{if(o&&o.count){q.countMode=o.count;q.head=!!o.head}return c};
  c.single=()=>{q.single=true;return c};c.maybeSingle=()=>{q.single=true;return c};
  c.update=()=>c;c.insert=()=>c;c.upsert=()=>c;c.delete=()=>c;
  c.then=(r,j)=>Promise.resolve(out(q)).then(r,j);return c};
 const query=t=>chain(q=>{const rows=(T[t]||[]).slice();
  if(q.countMode&&q.head)return{data:null,count:rows.length,error:null};
  if(q.single)return{data:rows[0]??null,error:null};
  return{data:rows,count:q.countMode?rows.length:null,error:null}},t);
 const rpcData=n=>({
  get_my_personas:{staff:[{business_id:BIZ,business_slug:'${SLUG}',business_name:'V608 Co',role:'owner',modules:MOD}],customer:[],default_route:'#/workspace/${SLUG}/dashboard'},
  get_my_modules:{role:'owner',is_super_admin:false,modules:MOD,capabilities:[],module_perms:Object.fromEntries(MOD.map(m=>[m,'rw']))},
  get_my_modules_at_v115:{role:'owner',is_super_admin:false,modules:MOD,capabilities:[],module_perms:Object.fromEntries(MOD.map(m=>[m,'rw']))},
  platform_get_business_control_v94:{workspace_access:true,quick_earn_catalogue_enabled:true},
  get_workspace_locale_preference_v97:{locale:'en',version:1},
  get_notifications:{unread:0,items:[]},
  get_customer_feature_capabilities:{customer_wallet:true,customer_phone_registration:true},
  get_dashboard_summary_v155:{revenue_cents:0,visits:0,new_customers:0,visits_by_weekday:[0,0,0,0,0,0,0],points_issued:0,revenue_by_day:[],availability:{}},
  business_get_checkout_preferences_v102:{package_earns_points:true},
  staff_list_package_entitlements_v102:[{client_package_id:'cp1',client_id:'c1',client_name:'Mei',client_phone:'80000001',
    plan_id:'pl1',plan_name:'5x Facial',sessions:5,price_cents:40000,remaining:3,status:'active',
    purchased_at:'2026-07-01T02:00:00Z',last_used_at:'2026-08-20T02:00:00Z',service_name:'Facial'}],
  staff_package_session_history_v603:{client_package_id:'cp1',plan_name:'5x Facial',sessions:5,remaining:3,
    purchased_at:'2026-07-01T02:00:00Z',sessions_used:[{consumption_id:'k1',sale_id:'s1',used_at:'2026-08-20T02:00:00Z',remaining_after:3,reversed:false}]},
  get_business_billing_v125:{business_id:BIZ,status:'active',
    terms:{cadence:'annual',customer_capacity:1000,amount_cents:118800},
    next_payment_at:'2027-08-25T00:00:00Z',plans:[{cadence:'annual',amount_cents:118800},{cadence:'monthly',amount_cents:16800}],
    provider:{subscription_id:'sub_1'},current_customer_count:8},
  business_get_customer_join_qr_status_v91:{join_token:null,active_count:0},
  get_grow_usage_v386:{rows:[]},
  business_get_programmes_v314:{programmes:[],programmes_contract:'v391'}
 }[n]??{});
 const rpc=n=>chain(()=>({data:rpcData(n),error:null}),'rpc:'+n);
 const auth=new Proxy({getSession:async()=>({data:{session:{user:{id:'u1',email:'o@v608.co'}}},error:null}),
  getUser:async()=>({data:{user:{id:'u1',email:'o@v608.co'}},error:null}),
  onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),signOut:async()=>({error:null})},
  {get:(t,k)=>k in t?t[k]:async()=>({data:null,error:null})});
 Object.defineProperty(window,'supabase',{value:{createClient:()=>({from:query,rpc,auth,
  channel:()=>{const c={on:()=>c,subscribe:()=>c,unsubscribe(){}};return c},removeChannel(){},
  functions:{invoke:async()=>({data:null,error:null})},storage:{from:()=>({getPublicUrl:()=>({data:{publicUrl:''}})})}})},writable:false});
})();`;

const browser=await chromium.launch({headless:true,executablePath:process.env.PLAYWRIGHT_EXECUTABLE_PATH});
let pass=0,fail=0;
const ok=(c,m)=>{if(c){pass++;console.log('  ok  - '+m)}else{fail++;console.log('  FAIL- '+m)}};
const open=async hash=>{
  const ctx=await browser.newContext({viewport:{width:1280,height:900},bypassCSP:true});
  await ctx.route('**/*',r=>{const u=r.request().url();
    if(u.startsWith(ORIGIN)&&!u.includes('/sw.js'))return r.continue();
    if(u.startsWith('https://cdn.jsdelivr.net/'))return r.continue();return r.abort()});
  await ctx.addInitScript(stub);
  const page=await ctx.newPage();
  const errs=[];page.on('pageerror',e=>errs.push(String(e).slice(0,120)));
  await page.goto(`${ORIGIN}/index.html#/workspace/${SLUG}${hash}`,{waitUntil:'domcontentloaded'});
  await page.waitForTimeout(3500);
  return {ctx,page,errs};
};
const text=page=>page.evaluate(()=>(document.body.innerText||'').replace(/\s+/g,' '));

console.log('\n### v604 staff list');
{ const {ctx,page,errs}=await open('/staffmembers');
  const heads=await page.evaluate(()=>[...document.querySelectorAll('.staff-col-head-v226 span')].map(s=>s.textContent.trim()));
  const firstGroup=await page.evaluate(()=>{const g=document.querySelector('.staff-col-head-v226');return g?[...g.children].map(s=>s.textContent.trim()):[]});
  ok(JSON.stringify(firstGroup)===JSON.stringify(['Name','Phone','Email','Branch','Position','Commission','App access','']),'columns: '+firstGroup.join('|'));
  ok(await page.evaluate(()=>!!document.querySelector('.staff-edit-chip-v603 .pill')),'Edit chip is drawn in the row');
  ok(!(await text(page)).includes('Access and status'),'the dialog heading is gone from the page');
  ok(errs.length===0,'no page errors ('+errs.slice(0,1)+')');
  await ctx.close(); }

console.log('\n### v603 customer packages');
{ const {ctx,page,errs}=await open('/custpackages');
  const t=await text(page);
  const heads=await page.evaluate(()=>[...document.querySelectorAll('#klist th')].map(h=>h.textContent.trim()));
  const cells=await page.evaluate(()=>[...document.querySelectorAll('#klist tr')].map(r=>[...r.children].map(c=>c.textContent.trim().slice(0,18))));
  console.log('     headers:',JSON.stringify(heads));
  console.log('     row    :',JSON.stringify(cells[1]||cells[0]));
  ok(heads.includes('Date bought'),'Date bought column');
  ok(heads.includes('Last used'),'Last used column');
  ok(await page.evaluate(()=>!!document.querySelector('[data-package-history-v603]')),'per-row History button');
  ok(!/Recent session correction history/.test(t),'the shared correction block is gone');
  ok(/^\d{2}\/\d{2}\/\d{4}$/.test((await page.evaluate(()=>[...document.querySelectorAll('#klist tr')][1]?.children[2]?.textContent.trim()))||''),'the dates read dd/mm/yyyy, not a timestamp');
  await page.click('[data-package-history-v603]'); await page.waitForTimeout(1500);
  const dlg=await page.evaluate(()=>{const d=document.querySelector('#packageHistoryTitleV603');return d?document.querySelector('.modal-card').innerText.replace(/\s+/g,' '):''});
  ok(/5x Facial/.test(dlg),'the History dialog opens and names the package');
  ok(/session used/.test(dlg),'and lists that package\'s own sessions');
  ok(/Undo session use/.test(dlg),'with Undo on a session that was not reversed');
  ok(errs.length===0,'no page errors ('+errs.slice(0,1)+')');
  await ctx.close(); }

console.log('\n### v606 branches: opening hours');
{ const {ctx,page,errs}=await open('/branches');
  ok(await page.evaluate(()=>!!document.querySelector('[data-branch-hours-open-v606]')),'each branch offers Opening hours');
  await page.click('[data-branch-hours-open-v606]'); await page.waitForTimeout(1800);
  const t=await text(page);
  ok(/Opening hours/.test(t),'the panel opens');
  ok(await page.evaluate(()=>document.querySelectorAll('[data-day-closed]').length===7),'seven weekday rows');
  ok(errs.length===0,'no page errors ('+errs.slice(0,1)+')');
  await ctx.close(); }

console.log('\n### v606 Reminder & Notification');
{ const {ctx,page,errs}=await open('/remindernotify');
  const t=await text(page);
  ok(/Reminder & Notification/.test(t),'the page renders');
  ok(errs.length===0,'no page errors ('+errs.slice(0,1)+')');
  await ctx.close(); }

console.log('\n### v607 Subscription');
{ const {ctx,page,errs}=await open('/settings');
  const t=await text(page);
  ok(/Subscription/.test(t),'the page is named Subscription');
  ok(!/What do you sell/.test(t),'"What do you sell?" is gone');
  ok(!/Everything else is set by Peekaa for your sector/.test(t),'the modules list is gone');
  ok(errs.length===0,'no page errors ('+errs.slice(0,1)+')');
  await ctx.close(); }

console.log('\n### v600 Block time — recurring off days');
{ const {ctx,page,errs}=await open('/appointments');
  const has=await page.evaluate(()=>!!document.querySelector('#openBlockTime'));
  ok(has,'the Block time button is on the page');
  if(has){
    await page.click('#openBlockTime'); await page.waitForTimeout(1200);
    ok(await page.evaluate(()=>!!document.querySelector('#blockModeWeeklyV600')),'the Every week mode exists');
    await page.click('#blockModeWeeklyV600'); await page.waitForTimeout(600);
    ok(await page.evaluate(()=>!document.querySelector('#blockWeeklyV600').hidden),'the weekday panel shows');
    ok(await page.evaluate(()=>document.querySelector('#blockOnceV600').hidden),'the date/time half hides');
    ok(await page.evaluate(()=>document.querySelectorAll('[data-weekly-off-v600]').length===7),'seven weekday ticks');
    ok(await page.evaluate(()=>document.querySelector('[data-weekly-off-v600="3"]').checked),'Wednesday is pre-ticked from the stub');
    ok(/Currently off every Wednesday/.test(await text(page)),'and it says so in words');
  }
  ok(errs.length===0,'no page errors ('+errs.slice(0,1)+')');
  await ctx.close(); }

console.log('\n### item 1 — the Subscription branch table');
{ const {ctx,page,errs}=await open('/settings');
  await page.waitForTimeout(2000);
  const heads=await page.evaluate(()=>[...document.querySelectorAll('#billingWrap th')].map(h=>h.textContent.trim()));
  /* nestly_v612 built this with six columns, as the owner confirmed when asked. A later owner
     photo (v628, another session) refined it: the business name column went because every row
     carried the same value and the heading already says it, "Plan" became "Payment Frequency"
     because that is what the cell holds, and "Expires on" became "Billed until" because the
     subscription is paid up to that date rather than expiring on it. The SHAPE this file guards is
     unchanged — one row per active branch, one company subscription — so the assertion follows the
     owner's newer wording rather than pinning wording they have since replaced. */
  ok(JSON.stringify(heads)===JSON.stringify(['Branch','Payment Frequency','Billed until','Status','Payment method']),'five columns: '+heads.join(' | '));
  const rows=await page.evaluate(()=>[...document.querySelectorAll('#billingWrap tr')].slice(1).map(r=>[...r.children].map(c=>c.textContent.trim())));
  console.log('     rows:',JSON.stringify(rows));
  ok(rows.length===2,'one row per active branch');
  const statusCol=heads.indexOf('Status'),branchCol=heads.indexOf('Branch');
  ok(rows.every(r=>r[statusCol]==='Ongoing'),'every row says Ongoing — it is one company subscription');
  ok(rows[0][branchCol]!==rows[1][branchCol],'and the branch is what differs down the table');
  ok(new Set(rows.map(r=>r[heads.indexOf('Billed until')])).size===1,
     'one renewal date across every branch, because there is one subscription');
  ok(errs.length===0,'no page errors ('+errs.slice(0,1)+')');
  await ctx.close(); }

console.log('\n### photo 5 — Customer Action');
{ const {ctx,page,errs}=await open('/customer-interface/appointment');
  await page.waitForTimeout(1500);
  const tabs=await page.evaluate(()=>[...document.querySelectorAll('.settings-tabs button, [role=tablist] a, [role=tablist] button')].map(b=>b.textContent.trim()).filter(Boolean));
  console.log('     tabs:',tabs.slice(0,4).join(' | '));
  /* The swap means Customer Action opens first, so the appointment card is present but hidden —
     innerText would not see it. Read the DOM. */
  const card=await page.evaluate(()=>{const c=document.querySelector('#aac')?.closest('.card');return c?c.innerHTML:''});
  ok(/Customer Appointment Request/.test(card),'the card is renamed');
  ok(!/Change requests/.test(card),'the old name is gone');
  ok(await page.evaluate(()=>{
       const panes=[...document.querySelectorAll('[data-ci-section],[data-settings-panel],section')];
       return document.querySelector('#aac')!==null;}),'the appointment card still exists on the page');
  ok(await page.evaluate(()=>{const c=document.querySelector('#aac')?.closest('.card');return !!c&&!!c.querySelector('#setStaffChoice')}),'the team-member switch sits in that same card');
  ok(await page.evaluate(()=>{const c=document.querySelector('#aac')?.closest('.card');return !!c&&!!c.querySelector('#setStaffChoiceSaveV606')}),'and its Save came with it');
  ok(errs.length===0,'no page errors ('+errs.slice(0,1)+')');
  await ctx.close(); }

console.log('\n### item 2 — package status sub-tabs');
{ const {ctx,page,errs}=await open('/custpackages');
  const tabs=await page.evaluate(()=>[...document.querySelectorAll('[data-package-status-v612]')].map(b=>b.textContent.trim()));
  ok(tabs.length===3,'three tabs: '+tabs.join(' | '));
  const rows=()=>page.evaluate(()=>document.querySelectorAll('#klist tbody tr, #klist table tr').length-1);
  console.log('     All rows:',await rows());
  await page.click('[data-package-status-v612="used"]'); await page.waitForTimeout(700);
  console.log('     Used up :',await rows(),'| tab labels:',(await page.evaluate(()=>[...document.querySelectorAll('[data-package-status-v612]')].map(b=>b.textContent.trim()))).join(' | '));
  ok(await page.evaluate(()=>document.querySelector('[data-package-status-v612=\"used\"]').getAttribute('aria-selected')==='true'),'Used up becomes the selected tab');
  await page.click('[data-package-status-v612="active"]'); await page.waitForTimeout(700);
  const activeRows=await rows();
  console.log('     Active  :',activeRows);
  ok(activeRows===1,'Active shows the one package with sessions left');
  ok(errs.length===0,'no page errors ('+errs.slice(0,1)+')');
  await ctx.close(); }

console.log(`\nRESULT  pass=${pass} fail=${fail}`);
await browser.close(); server.kill();
process.exitCode=fail?1:0;
