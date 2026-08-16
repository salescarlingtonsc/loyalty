import {createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath,pathToFileURL} from 'node:url';

const APP_URL=new URL('../../app/index.html',import.meta.url);
/* The application script was extracted from index.html into app.js. The .test.mjs files
   pass both files joined; this CLI path must read the same pair or it regenerates a
   fixture from a file that no longer contains the components. */
const APP_SCRIPT_URL=new URL('../../app/app.js',import.meta.url);
const readAppSource=async()=>(await Promise.all([readFile(APP_URL,'utf8'),readFile(APP_SCRIPT_URL,'utf8')])).join('\n');
const FIXTURE_URL=new URL('./v145-launch-freeze-visual.html',import.meta.url);

function between(source,start,end){
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  if(from<0||to<=from)throw new Error(`production source section missing: ${start}`);
  return source.slice(from,to).trim();
}

export function buildV145LaunchFreezeVisual(app){
  const style=app.match(/<style>([\s\S]*?)<\/style>/)?.[1];
  if(!style)throw new Error('production inline stylesheet missing');
  const dataHelpers=between(app,'const DATA_API_PAGE_SIZE=1000;','function killCharts()');
  const requestHelpers=between(app,'function createLatestRequestGate','function nav(h)');
  const campaignProjection=between(app,'function campaignEntitlementDisplayV99(item)','function customerRedemptionIntentArgsV89');
  const branchFilter=between(app,'async function visibleBranchesForCurrentUser(','/* ---------- dashboard ---------- */');
  const dashboard=between(app,'async function dashboard()','/* ---------- customers ---------- */');
  const client=between(app,'async function clientDetail(id)','/* ---------- quick earn');
  const reports=between(app,'async function reportsPage()','/* ---------- get started');
  const daily=between(app,'async function dailyReportPage()','/* ---------- expenses ---------- */');
  const expenses=between(app,'async function expensesPage()','/* ---------- P&L ---------- */');
  const pnl=between(app,'async function pnlPage()','/* ---------- settings ---------- */');
  const inbox=between(app,'async function renderCustomerInAppInbox(','async function renderCustomerNotificationPreferences(');
  const studioSafetyHelpers=between(app,'function studioActiveEmergencyPause(item)','/* ----- PS-1C.2 published-rule controls');
  const sourceHash=createHash('sha256').update([
    style,dataHelpers,requestHelpers,campaignProjection,branchFilter,dashboard,client,reports,daily,expenses,pnl,inbox,studioSafetyHelpers
  ].join('\n')).digest('hex');

  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="production-source-sha256" content="${sourceHash}"><link rel="icon" href="data:,"><title>Peekaa V145 launch-freeze browser acceptance</title><style>${style}
  body{padding:20px}.v145-shell{max-width:1280px;margin:auto}.v145-provenance{font-size:11px;color:var(--muted);overflow-wrap:anywhere;margin-bottom:10px}.v145-nav{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:14px}
  @media(max-width:600px){body{padding:10px}.card{padding:16px}.v145-shell{width:100%}}
  </style></head><body><div class="v145-shell"><p class="v145-provenance">Actual production-renderer harness · ${sourceHash}</p>
  <nav class="v145-nav" aria-label="V145 acceptance views"><button class="btn" data-view="dashboard">Dashboard</button><button class="btn ghost" data-view="reports">Reports</button><button class="btn ghost" data-view="daily">Daily report</button><button class="btn ghost" data-view="client">Customer 360</button><button class="btn ghost" data-view="expenses">Expenses</button><button class="btn ghost" data-view="pnl">P&amp;L</button><button class="btn ghost" data-view="inbox">Customer inbox</button><button class="btn ghost" data-view="safety">Launch safety evidence</button></nav><main id="main"></main></div><div id="toast"></div><script>
  const $=id=>document.getElementById(id),M=()=>document.getElementById('main');
  const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
  const money=cents=>'SGD '+(Number(cents||0)/100).toFixed(2);
  const BRAND={downloadPrefix:'peekaa',productName:'Peekaa'};
  const CUI={
    icon:()=>'<span aria-hidden="true">•</span>',announce:message=>{window.__lastAnnouncement=message},
    loadingState:({title})=>'<div class="card"><div class="empty">Loading '+esc(title||'view')+'…</div></div>',
    errorState:({title,message,retryId})=>'<div class="card"><div class="err"><b>'+esc(title)+'</b><p>'+esc(message)+'</p><button class="btn ghost sm" id="'+esc(retryId)+'">Retry</button></div></div>',
    pageHeader:({title,subtitle,actions=''})=>'<div class="topbar cui-page-title"><div><h1>'+esc(title)+'</h1><p class="muted small">'+esc(subtitle||'')+'</p></div><div class="row">'+actions+'</div></div>',
    action:({id,label,variant='',className='',iconName=''})=>'<button type="button" class="btn '+(variant==='secondary'?'ghost ':'')+esc(className)+'" id="'+esc(id)+'">'+(iconName?'<span aria-hidden="true">•</span>':'')+'<span>'+esc(label)+'</span></button>',
    skeletonCard:({className=''})=>'<div class="card '+esc(className)+'"><div class="skeleton-line"></div></div>',
    skeletonGrid:({cards=1})=>Array.from({length:cards},()=>'<div class="card"><div class="skeleton-line"></div></div>').join(''),
    tableSkeleton:()=>'<div class="card"><div class="skeleton-line"></div></div>',
    formSkeleton:()=>'<div class="card"><div class="skeleton-line"></div></div>',
    chartSkeleton:({title})=>'<div class="card"><b>'+esc(title)+'</b><div class="skeleton-line"></div></div>',
    emptyState:({title,body})=>'<div class="empty"><b>'+esc(title)+'</b><p>'+esc(body||'')+'</p></div>',
    setButtonBusy:(button,busy,{busyLabel}={})=>{if(button){button.disabled=Boolean(busy);if(busy&&busyLabel)button.textContent=busyLabel;}},
    activateDialog:(dialog,{onClose,initialFocus}={})=>{const deactivate=()=>dialog?.remove();requestAnimationFrame(()=>dialog?.querySelector(initialFocus||'button')?.focus());dialog?.addEventListener('keydown',event=>{if(event.key==='Escape'){event.preventDefault();(onClose||deactivate)();}});return deactivate}
  };
  const workspaceTemplateHtmlV97=()=> 'How Glow Atelier is doing';
  const workspaceTemplateAttributeV97=()=>'',workspaceTemplateTextV97=()=>'';
  const workspaceTranslationV97=source=>source;
  const localizeWorkspaceSubtreeV97=()=>{};
  const projectionCanWrite=()=>true,projectionCanRead=()=>true;
  const loadBranchModuleProjection=async()=>({});
  const toast=message=>{window.__lastToast=message};
  const fail=error=>{window.__handledErrors.push(String(error?.message||error))};
  const sgt=value=>value?new Intl.DateTimeFormat('en-SG',{timeZone:'Asia/Singapore',dateStyle:'medium',timeStyle:'short'}).format(new Date(value)):'';
  const MODULES={sales:['sales','Sales'],loyalty:['loyalty','Loyalty'],appointments:['appointments','Appointments']};
  const S={myRole:'owner',user:{id:'owner-v145'},biz:{id:'business-v145',name:'Glow Atelier',currency:'SGD'},charts:[]};
  let selectedBranchId='branch-orchard',dashboardRenderEpoch=0,currentView='dashboard',pendingTillPhone=null,pendingApptClientId=null;
  const canReadModule=module=>S.myRole==='owner'||['clients','sales','loyalty','appointments','till'].includes(module);
  const canWriteModule=module=>S.myRole==='owner'&&currentView!=='expenses';
  const hasRoleCapability=capability=>S.myRole==='owner'||capability==='create_sales';
  const loadCustomerFeatureCapabilities=async()=>({customer_birthday_benefits:false});
  const loadReversalWorkflows=async()=>({sales:[],redemptions:[]});
  const bindReversalButtons=()=>{};
  const copyTextToClipboard=async()=>true;
  const nav=hash=>{window.__lastNav=hash};
  const walletDate=value=>value?new Intl.DateTimeFormat('en-SG',{timeZone:'Asia/Singapore',dateStyle:'medium'}).format(new Date(value)):'';
  const walletSectionStillCurrent=(host,isCurrent)=>!!host&&host.isConnected&&isCurrent();
  const previousEquivalentRangeV153=(from,to)=>({previousFrom:from,previousTo:to});
  const buildMerchantInsightsV153=()=>'<section class="merchant-insights"><h2>Merchant insights</h2></section>';
  const openCampaignPrepV153=()=>{};
  const wireLocalCollapseV154=()=>{};
  function killCharts(){S.charts.forEach(chart=>chart.destroy());S.charts=[]}
  window.__chartConfigs=[];window.__rpcCalls=[];window.__dataCalls=[];window.__consoleErrors=[];window.__handledErrors=[];
  class Chart{constructor(canvas,config){this.canvas=canvas;this.config=config;window.__chartConfigs.push({id:canvas.id,config});}destroy(){}}
  const loadChartLibrary=async()=>Chart;
  function dataRows(table){
    if(currentView==='client'){
      const facetError=new URLSearchParams(location.search).get('facetError')==='1';
      return {
        branches:[{id:'branch-orchard',name:'Orchard',active:true,is_default:true},{id:'branch-tampines',name:'Tampines',active:true,is_default:false}],
        staff:[{id:'staff-front',full_name:'Front Desk'}],
        staff_branches:[{staff_id:'staff-front',branches:{id:'branch-orchard',name:'Orchard',active:true}}],
        clients:{id:'customer-v145',business_id:'business-v145',full_name:'Aisha Tan',phone:'81234567',email:'aisha@example.invalid',referral_code:'AISHA1',marketing_consent:true},
        client_points_balance:[{points:300}],client_credit_balance:[{balance_cents:500}],
        loyalty_programs:[{active:true,loyalty_model:'classic',earn_points:10,earn_per_dollar:10,redeem_points:300,reward_credit_cents:1000}],
        points_batches:facetError?{__error:{message:'Synthetic expiry interruption'}}:[{remaining:300,expires_at:'2026-09-28T00:00:00Z'}],
        loyalty_rewards:[],
        sales:[{id:'sale-orchard',branch_id:'branch-orchard',client_id:'customer-v145',staff_id:'staff-front',occurred_at:'2026-08-02T04:00:00Z',kind:'quick_sale',amount_cents:3000,counts_as_revenue:true,counts_as_visit:true,reversal_of:null,note:null}],
        appointments:[],client_field_definitions:[],client_field_values:[],client_field_options:[],memberships:[],client_packages:[]
      }[table]??[];
    }
    if(currentView==='daily'&&table==='sales')return [
      {id:'sale-original',branch_id:'branch-orchard',client_id:'customer-v145',occurred_at:'2026-08-03T02:00:00Z',kind:'quick_sale',amount_cents:1000,counts_as_revenue:true,counts_as_visit:true,reversal_of:null,clients:{full_name:'Aisha Tan',phone:'81234567'},staff:{full_name:'Front Desk'},appointments:null},
      {id:'sale-reversal',branch_id:'branch-orchard',client_id:'customer-v145',occurred_at:'2026-08-03T03:00:00Z',kind:'quick_sale',amount_cents:-1000,counts_as_revenue:true,counts_as_visit:false,reversal_of:'sale-original',reversal_reason:'Duplicate',clients:{full_name:'Aisha Tan',phone:'81234567'},staff:{full_name:'Front Desk'},appointments:null},
      {id:'membership-reversal',branch_id:'branch-orchard',client_id:'customer-v145',occurred_at:'2026-08-03T03:30:00Z',kind:'membership',amount_cents:-500,counts_as_revenue:true,counts_as_visit:false,reversal_of:'membership-original-prior-day',reversal_reason:'Membership charge reversed',clients:{full_name:'Aisha Tan',phone:'81234567'},staff:{full_name:'Front Desk'},appointments:null},
      {id:'gift-issue',branch_id:'branch-orchard',client_id:null,occurred_at:'2026-08-03T04:00:00Z',kind:'gift_card',amount_cents:2500,counts_as_revenue:false,counts_as_visit:false,reversal_of:null,clients:null,staff:{full_name:'Front Desk'},appointments:null}
    ];
    if(currentView==='reports'&&table==='appointments')return [{id:'appt-1',status:'completed',starts_at:'2026-08-02T02:00:00Z',ends_at:'2026-08-02T03:00:00Z',staff_id:'staff-front',branch_id:'branch-orchard'}];
    if(currentView==='expenses'&&table==='expenses')return [{id:'expense-1',branch_id:'branch-orchard',category:'Supplies',supplier:'Paper Co',description:'Receipt rolls',amount_cents:1200,currency:'SGD',fx_rate_to_base:1,occurred_on:'2026-08-02',created_at:'2026-08-02T00:00:00Z',voided_at:null}];
    if(table==='branches')return [{id:'branch-orchard',name:'Orchard',active:true,is_default:true},{id:'branch-tampines',name:'Tampines',active:true,is_default:false}];
    return [];
  }
  function queryRows(table,provided){
    let single=false,limit=null,countRequested=false;
    const modifiers=[];
    const query={
      select(columns,options){countRequested=options?.count==='exact';return query},eq(...args){modifiers.push(['eq',...args]);return query},
      gte(...args){modifiers.push(['gte',...args]);return query},gt(...args){modifiers.push(['gt',...args]);return query},
      lte(...args){modifiers.push(['lte',...args]);return query},lt(...args){modifiers.push(['lt',...args]);return query},
      not(...args){modifiers.push(['not',...args]);return query},is(...args){modifiers.push(['is',...args]);return query},
      in(...args){modifiers.push(['in',...args]);return query},order(){return query},limit(value){limit=value;return query},single(){single=true;return query},maybeSingle(){single=true;return query},
      range(from,to){return finish(from,to)},then(resolve,reject){return finish(0,limit==null?Number.MAX_SAFE_INTEGER:Math.max(0,limit-1)).then(resolve,reject)}
    };
    const finish=async(from,to)=>{
      window.__dataCalls.push({table,modifiers:[...modifiers]});
      const raw=provided===undefined?dataRows(table):provided;
      if(raw&&raw.__error)return {data:null,error:raw.__error,count:null};
      const rows=Array.isArray(raw)?raw:[raw];
      const sliced=rows.slice(from,Math.min(to+1,limit==null?rows.length:limit));
      return {data:single?(sliced[0]??null):sliced,error:null,count:countRequested?rows.length:null};
    };
    return query;
  }
  function rpcValue(data,error=null){return {then(resolve,reject){return Promise.resolve({data:error?null:data,error}).then(resolve,reject)}}}
  let pnlFailOnce=new URLSearchParams(location.search).get('error')==='1';
  const sb={
    from(table){return queryRows(table)},
    rpc(name,args){
      window.__rpcCalls.push({name,args});
      const empty=new URLSearchParams(location.search).get('empty')==='1';
      if(name==='list_customer_redemption_history_v145')return queryRows('redemption_history',[]);
      if(name==='get_dashboard_summary'||name==='get_dashboard_summary_v155'){
        if(currentView==='daily')return rpcValue({visits:0,revenue_cents:-500,unique_customers:0,availability:{sales:true}});
        const params=new URLSearchParams(location.search),clientsOff=params.get('clientsOff')==='1',loyaltyOff=params.get('loyaltyOff')==='1',creditOff=params.get('creditOff')==='1';
        const days=[];for(let day=args.p_from;day<=args.p_to;day=shiftSgDateInput(day,1))days.push(day);
        return rpcValue({visits:empty?0:1,revenue_cents:empty?0:1000,unique_customers:empty?0:1,new_customers:empty?0:4,
          points_issued:loyaltyOff?null:(empty?0:11),credit_liability_cents:creditOff?null:(empty?0:2500),visits_by_weekday:empty?[0,0,0,0,0,0,0]:[0,0,1,0,0,0,0],
          revenue_by_day:days.map((day,index)=>({day,amount_cents:empty||index!==0?0:1000})),
          age_counts:clientsOff?null:(empty?{}:{under_25:1,age_25_34:2,age_35_44:0,age_45_54:0,age_55_plus:0,unknown:1}),
          gender_counts:clientsOff?null:(empty?{}:{female:2,male:1,other:0,unknown:1}),
          availability:{sales:true,clients:!clientsOff,loyalty:!loyaltyOff,credit_liability:!creditOff}});
      }
      if(name==='staff_list_customers_v155'){
        const clientsOff=new URLSearchParams(location.search).get('clientsOff')==='1';
        return clientsOff?rpcValue(null,{code:'42501',message:'Synthetic Clients module denial'}):rpcValue({rows:[],total:2,limit:1,offset:0,has_more:true});
      }
      if(name==='preview_campaign_audience_v155')return rpcValue({matching_customers:1});
      if(name==='staff_list_customers_v155'){
        const clientsOff=new URLSearchParams(location.search).get('clientsOff')==='1';
        return clientsOff?rpcValue(null,{code:'42501',message:'Synthetic Clients module denial'}):rpcValue({rows:[],total:2,limit:1,offset:0,has_more:true});
      }
      if(name==='get_revenue_summary'){
        if(pnlFailOnce){pnlFailOnce=false;return {then(resolve,reject){return Promise.reject(new Error('Synthetic temporary reporting interruption')).then(resolve,reject)}}}
        return rpcValue(empty?{revenue_cash_cents:0,revenue_accrual_cents:0,expenses_cents:0,net_cash_cents:0,expenses_by_category:{},monthly:{}}:
          {revenue_cash_cents:10000,revenue_accrual_cents:9000,expenses_cents:3500,net_cash_cents:6500,
           expenses_by_category:{Rent:2500,Supplies:1000},monthly:{'2026-07':{revenue_accrual_cents:4000,expenses_cents:2000},'2026-08':{revenue_accrual_cents:5000,expenses_cents:1500}}});
      }
      if(name==='get_reports_summary'){
        const creditOff=new URLSearchParams(location.search).get('creditOff')==='1';
        return rpcValue({revenue_by_kind:{quick_sale:3000,membership:0},non_revenue_by_kind:{gift_card:2500},points_by_type:{earn:30,redeem:-10,expire:0,adjust:0},credit_liability_cents:creditOff?null:500,gift_card_liability_cents:2500,active_memberships:0,reversal_reconciliation:{compensating_rows:1,reversed_revenue_cents:1000,net_revenue_cents:2000},availability:{loyalty:true,gift_cards:true,memberships:true,credit_liability:!creditOff,sales_export:true,clients_export:true},scope:{credit_liability:creditOff?'unavailable_without_complete_business_reports_and_sales_source_scope':'business_wide_current_with_complete_business_reports_and_sales_source_scope',gift_card_liability:'business_wide_current',active_memberships:'business_wide_current',points:'business_wide_selected_period'}});
      }
      if(name==='require_module_scope_v145')return rpcValue({status:'ok'});
      if(name==='staff_get_customer_actionable_loyalty_v145')return rpcValue({
        as_of:'2026-08-03T08:00:00Z',points_balance:300,credit_balance_cents:500,
        expiry:{expires_at:'2026-09-28T00:00:00Z',units:300},redemption_enabled:true,
        program:{id:'loyalty-v145',active:true,kind:'points',model:'classic',unit:'points',earn_points_per_dollar:10,stamp_per_cents:null,redeem_points:300,reward_credit_cents:1000,expiry_mode:'fixed',configuration_status:'published'},
        rewards:[{source:'classic',reward_id:null,name:'SGD 10.00 credit',cost_units:300,credit_cents:1000,fulfillment_kind:'credit',remaining_units:0,available_now:true}],
        next_reward:{source:'classic',reward_id:null,name:'SGD 10.00 credit',cost_units:300,credit_cents:1000,fulfillment_kind:'credit',remaining_units:0,available_now:true}
      });
      if(name==='staff_get_reward_entitlements_v99')return rpcValue([]);
      if(name==='staff_list_visit_feedback_v145'){
        const facetError=new URLSearchParams(location.search).get('facetError')==='1';
        return facetError?rpcValue(null,{message:'Synthetic feedback interruption'}):rpcValue({feedback:[]});
      }
      if(name==='staff_get_customer_birthday_benefit')return rpcValue(null);
      if(name==='get_customer_lifecycle_metrics_v145')return rpcValue({status:'unavailable',metrics:{},coverage:{eligible_transactions:0,identified_transactions:0}});
      if(name==='customer_sync_in_app_inbox')return rpcValue({status:'ok'});
      if(name==='customer_get_in_app_inbox_count')return rpcValue({unread_count:1,quiet_hours_active:true});
      if(name==='customer_list_in_app_inbox')return rpcValue({items:[{event_id:'event-v145',state:'unread',title:'Reward ready',body:'A reward is ready in your programme.',deadline_at:'2026-08-31T15:59:59Z',action_available:true,route_key:'wallet_business'}],next_cursor:null});
      if(name==='customer_get_in_app_inbox_preferences')return rpcValue([{topic:'reward_ready',opted_in:true,quiet_hours_timezone:'Asia/Singapore',quiet_hours_start:'22:00:00',quiet_hours_end:'08:00:00'}]);
      if(name==='customer_set_in_app_inbox_preferences')return rpcValue({status:'ok'});
      return rpcValue(null,{message:'Unexpected RPC '+name});
    }
  };
  ${dataHelpers}
  ${requestHelpers}
  ${campaignProjection}
  ${branchFilter}
  ${dashboard}
  ${client}
  ${reports}
  ${daily}
  ${expenses}
  ${pnl}
  ${inbox}
  ${studioSafetyHelpers}
  function renderStudioSafetyEvidence(){
    const systemPause=studioActiveEmergencyPause({emergency_pause:{reason:'Incomplete historical action',paused_at:'2026-08-03T08:00:00Z',actor:STUDIO_LAUNCH_SAFETY_ACTOR,lifted_at:null}});
    const ownerPause=studioActiveEmergencyPause({emergency_pause:{reason:'Owner-requested stop',paused_at:'2026-08-03T09:00:00Z',actor:'owner-v145',lifted_at:null}});
    const systemActor=studioEmergencyPauseActorLabel(systemPause?.actor),ownerActor=studioEmergencyPauseActorLabel(ownerPause?.actor);
    M().innerHTML='<section class="card"><h1>Launch safety attribution</h1><p class="muted">Existing Program Studio emergency-pause evidence.</p><div class="studio-emg-banner" role="alert"><b>Emergency paused.</b> Reason: '+esc(systemPause.reason)+'. By '+esc(systemActor)+'. New effects are stopped; every past record is kept.</div><div class="studio-emg-banner"><b>Owner action remains attributed.</b> By '+esc(ownerActor)+'.</div></section>';
  }
  async function showView(view){
    currentView=view;S.myRole=view==='client'?'frontdesk':view==='expenses'?'viewer':new URLSearchParams(location.search).get('branchLimited')==='1'?'frontdesk':'owner';selectedBranchId=view==='client'?'branch-orchard':view==='reports'||view==='daily'?null:'branch-orchard';
    killCharts();window.__chartConfigs=[];window.__rpcCalls=[];window.__dataCalls=[];M().innerHTML='';
    document.querySelectorAll('[data-view]').forEach(button=>button.className=button.dataset.view===view?'btn':'btn ghost');
    if(view==='pnl')await pnlPage();else if(view==='reports')await reportsPage();else if(view==='daily')await dailyReportPage();else if(view==='client')await clientDetail('customer-v145');else if(view==='expenses')await expensesPage();else if(view==='inbox'){M().innerHTML='<div id="customerInboxBellSlot"></div><section class="card wallet-section" id="customerInAppInbox" aria-busy="true"></section>';await renderCustomerInAppInbox('glow-atelier',()=>true,null);}else if(view==='safety')renderStudioSafetyEvidence();else await dashboard();
  }
  document.querySelectorAll('[data-view]').forEach(button=>button.onclick=()=>showView(button.dataset.view));
  window.addEventListener('error',event=>window.__consoleErrors.push(event.message));
  window.v145Metrics=()=>({sourceHash:'${sourceHash}',view:currentView,width:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth,
    text:document.body.innerText,kpis:[...document.querySelectorAll('.kpi')].map(card=>card.innerText.replace(/\\n+/g,' · ')),
    chartConfigs:window.__chartConfigs,rpcCalls:window.__rpcCalls,dataCalls:window.__dataCalls,errors:window.__consoleErrors,handledErrors:window.__handledErrors,
    visibleButtonHeights:[...document.querySelectorAll('button')].filter(button=>button.offsetParent!==null).map(button=>button.getBoundingClientRect().height),
    overlay:!!document.querySelector('[data-nextjs-dialog],.vite-error-overlay,#webpack-dev-server-client-overlay')});
  const initial=new URLSearchParams(location.search).get('view')||'dashboard';showView(initial).catch(fail);
  </script></body></html>`;
}

if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url){
  const app=await readAppSource();
  await writeFile(FIXTURE_URL,buildV145LaunchFreezeVisual(app));
  process.stdout.write(`${fileURLToPath(FIXTURE_URL)}\n`);
}
