import {createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {isDirectCliInvocation} from '../../scripts/quality/is-direct-cli-invocation.mjs';

const APP_URL=new URL('../../app/index.html',import.meta.url);
/* The application script was extracted from index.html into app.js. The .test.mjs files
   pass both files joined; this CLI path must read the same pair or it regenerates a
   fixture from a file that no longer contains the components. */
const APP_SCRIPT_URL=new URL('../../app/app.js',import.meta.url);
const readAppSource=async()=>(await Promise.all([readFile(APP_URL,'utf8'),readFile(APP_SCRIPT_URL,'utf8')])).join('\n');
const CUSTOMER_UI_URL=new URL('../../app/customer-ui.js',import.meta.url);
const FIXTURE_URL=new URL('./v141-dashboard-visual.html',import.meta.url);

function between(source,start,end){
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  if(from<0||to<=from)throw new Error(`production source section missing: ${start}`);
  return source.slice(from,to).trim();
}

export function buildV141DashboardVisual(app,customerUi){
  const style=app.match(/<style>([\s\S]*?)<\/style>/)?.[1];
  if(!style)throw new Error('production inline stylesheet missing');
  const branchFilter=between(app,'async function visibleBranchesForCurrentUser(','/* ---------- dashboard ---------- */');
  const dashboard=between(app,'async function dashboard()','/* ---------- customers ---------- */');
  const sourceHash=createHash('sha256').update([style,customerUi,branchFilter,dashboard].join('\n')).digest('hex');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="production-source-sha256" content="${sourceHash}"><title>Peekaa V141 dashboard acceptance</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.3/dist/chart.umd.min.js"></script><style>${style}
  .v141-wordmark{font-size:1.35rem;font-weight:750;letter-spacing:-.04em;padding:4px 10px 22px}.v141-profile{display:flex;align-items:center;gap:8px;min-height:44px;padding:5px 10px;border-radius:999px;background:#fff;border:1px solid var(--hair)}
  </style></head><body><div class="shell"><aside class="side"><div class="v141-wordmark">◉◉<br>peekaa</div><nav class="nav"><a class="act" href="#/dashboard">${customerUi.includes("dashboard")?'':' '}Dashboard</a><a href="#/clients">Customers</a><button class="navhead"><span>Serve &amp; sell</span><span class="chev">+</span></button><button class="navhead"><span>Grow</span><span class="chev">+</span></button><button class="navhead"><span>Money</span><span class="chev">+</span></button><button class="navhead"><span>Operations setup</span><span class="chev">+</span></button></nav><div class="foot">V141 source-bound candidate</div></aside>
  <div class="col"><header class="appbar"><div class="global-actions"><div class="global-search"><span class="global-search-ic">⌕</span><input aria-label="Find a customer" placeholder="Find a customer  ( / )"><button class="global-search-go" aria-label="Search customers">›</button></div><div class="global-quick"><button class="btn sm global-act">Record sale</button><button class="btn ghost sm global-act">New appointment</button></div></div><span class="dashboard-appbar-branch" id="dashboardBranchWrap"><span class="muted small">Loading branches…</span></span><select aria-label="Language" style="width:auto"><option>English</option></select><button class="v141-profile"><span class="avatar">G</span><b>Glow Atelier</b></button></header><main class="main" id="main"></main></div></div><div id="toast" class="toast"></div><script>
  ${customerUi}
  const CUI=window.FrenlyCustomerUI,$=id=>document.getElementById(id),M=()=>document.getElementById('main');
  const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
  const money=cents=>'SGD '+(Number(cents||0)/100).toLocaleString('en-SG',{minimumFractionDigits:2,maximumFractionDigits:2});
  const fixtureParams=new URLSearchParams(location.search);
  const fixtureRole=fixtureParams.get('role')||'owner';
  const S={myRole:fixtureRole,isSA:false,user:{id:fixtureRole+'-v141'},biz:{id:'business-v141',name:'Glow Atelier'}};
  let dashboardRenderEpoch=0,selectedBranchId=null,pendingCustomerInactivity=null;
  const workspaceTemplateHtmlV97=(key,values)=>'How '+esc(values.business)+' is doing';
  const workspaceTemplateAttributeV97=(attribute,key,values)=>attribute+'="'+esc(key+': '+values.metric)+'"';
  const workspaceTranslationV97=value=>value;
  const localizeWorkspaceSubtreeV97=()=>{};
  const createLatestRequestGate=isCurrent=>{let generation=0;return {begin(){const mine=++generation;return ()=>mine===generation&&isCurrent()},invalidate(){generation++}}};
  const canReadModule=()=>true,hasRoleCapability=()=>true;
  const sgDateInputValue=()=>new URLSearchParams(location.search).get('today')||'2026-08-02';
  const shiftSgDateInput=(date,days)=>{const value=new Date(date+'T00:00:00Z');value.setUTCDate(value.getUTCDate()+days);return value.toISOString().slice(0,10)};
  const sgDateBoundary=(date,plusDays=0)=>new Date(shiftSgDateInput(date,plusDays)+'T00:00:00+08:00').toISOString();
  const fetchAllRows=async factory=>(await factory()).data||[];
  const fail=error=>window.__consoleErrors.push(String(error?.message||error));
  const nav=route=>{window.__lastNavigation=route};
  const killCharts=()=>{for(const chart of S.charts||[])chart.destroy?.();S.charts=[]};S.charts=[];
  const branches=[{id:'branch-one',name:'Orchard'},{id:'branch-two',name:'Tampines'}];
  const saleItems=[
    {id:'line-1',item_type:'service',line_cents:128000},{id:'line-2',item_type:'retail',line_cents:39200},{id:'line-3',item_type:'custom',line_cents:6500},
    {id:'line-discount',item_type:'studio_discount',line_cents:-1500}
  ];
  const visitSales=[...Array.from({length:23},(_,index)=>({id:'visit-'+index,occurred_at:new Date(Date.UTC(2026,6,20+(index%13),4+(index%4),0)).toISOString(),counts_as_visit:true,reversal_of:null})),{id:'reversal-one',occurred_at:'2026-07-29T06:00:00.000Z',counts_as_visit:true,reversal_of:'visit-1'}];
  window.__saleItemsReads=0;window.__dashboardReportReads=0;window.__inactiveReads=0;
  function fixtureQuery(table){
    const query={select(){return query},eq(){return query},gte(){return query},lt(){return query},order(){return query},limit(){return query},range(){return query},
      then(resolve,reject){
        if(table==='sale_items'){
          window.__saleItemsReads++;
          if(fixtureParams.get('item_error')==='1'&&window.__saleItemsReads===1)return Promise.reject(new Error('Injected item-detail interruption')).then(resolve,reject);
        }
        const data=table==='branches'?branches:table==='staff'?[{id:'staff-v141'}]:table==='staff_branches'?[{branches:branches[0]}]:table==='sale_items'&&fixtureRole==='owner'?saleItems:table==='sales'?visitSales:[];
        return Promise.resolve({data,error:null,count:data.length}).then(resolve,reject)
      }};
    return query;
  }
  window.__consoleErrors=[];
  const sb={from:fixtureQuery,rpc:async name=>{
    if(name==='get_dashboard_summary'){
      window.__dashboardReportReads++;
      if(fixtureParams.get('report_error')==='1'&&window.__dashboardReportReads===1)return {data:null,error:{message:'Injected report interruption'}};
      return {data:{visits:22,revenue_cents:173730,unique_customers:3,new_customers:4,points_issued:75831,credit_liability_cents:0,visits_by_weekday:[1,3,9,2,1,1,5],revenue_by_day:[{day:'20 Jul',amount_cents:10000},{day:'22 Jul',amount_cents:40000},{day:'29 Jul',amount_cents:63500},{day:'31 Jul',amount_cents:50230}],age_counts:{under_25:1,age_25_34:2,age_35_44:0,age_45_54:0,age_55_plus:0,unknown:1},gender_counts:{female:2,male:1,other:0,unknown:1}},error:null};
    }
    if(name==='staff_list_customers_v155'){
      window.__inactiveReads++;
      if(fixtureParams.get('inactive_error')==='1'&&window.__inactiveReads===1)return {data:null,error:{message:'Injected inactivity interruption'}};
      return {data:{total:2,customers:[]},error:null};
    }
    return {data:null,error:null};
  }};
  ${branchFilter}
  ${dashboard}
  window.addEventListener('error',event=>window.__consoleErrors.push(event.message));
  window.v141DashboardMetrics=()=>({sourceHash:'${sourceHash}',role:fixtureRole,width:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth,taskCards:[...document.querySelectorAll('.task-launcher-card')].length,branchInAppbar:!!document.querySelector('.appbar #dashboardBranchWrap select'),metricKeys:[...document.querySelectorAll('[data-dashboard-metric]')].map(item=>item.dataset.dashboardMetric),charts:[...document.querySelectorAll('.dashboard-chart-head b')].map(item=>item.textContent.trim()),saleItemsReads:window.__saleItemsReads,reportReads:window.__dashboardReportReads,inactiveReads:window.__inactiveReads,itemMixUnavailable:document.querySelector('.dashboard-chart-card:last-of-type .empty')?.textContent||'',saleMixValues:S.charts.find(chart=>chart.canvas?.id==='c6')?.data?.datasets?.[0]?.data||[],dashboardStatus:document.getElementById('dashboardStatus')?.innerText||'',modalTitle:document.getElementById('dashboardMetricTitle')?.textContent||'',lastNavigation:window.__lastNavigation||'',errors:window.__consoleErrors});
  dashboard().catch(error=>window.__consoleErrors.push(String(error?.stack||error)));
  </script></body></html>`;
}

if(isDirectCliInvocation(import.meta.url)){
  const [app,customerUi]=await Promise.all([readAppSource(),readFile(CUSTOMER_UI_URL,'utf8')]);
  await writeFile(FIXTURE_URL,buildV141DashboardVisual(app,customerUi));
  process.stdout.write(`${fileURLToPath(FIXTURE_URL)}\n`);
}
