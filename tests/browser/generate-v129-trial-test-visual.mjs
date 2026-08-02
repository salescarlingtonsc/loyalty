import {createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath,pathToFileURL} from 'node:url';

const APP_URL=new URL('../../app/index.html',import.meta.url);
const CUSTOMER_UI_URL=new URL('../../app/customer-ui.js',import.meta.url);
const FIXTURE_URL=new URL('./v129-trial-test-visual.html',import.meta.url);

function between(source,start,end){
  const from=source.indexOf(start),to=source.indexOf(end,from+start.length);
  if(from<0||to<=from)throw new Error(`production source section missing: ${start}`);
  return source.slice(from,to).trim();
}

export function buildV129TrialTestVisual(app,customerUi){
  const style=app.match(/<style>([\s\S]*?)<\/style>/)?.[1];
  if(!style)throw new Error('production inline stylesheet missing');
  const customers=between(app,'function normalizeSingaporeCustomerSearch(value)','async function clientDetail(');
  const profile=between(app,'async function clientDetail(','/* ---------- referrals');
  const historyRenderer=between(app,'function renderHistPage(','/* ---------- quick earn');
  const till=between(app,'async function tillPage()','/* ---------- sales ---------- */');
  const whatsapp=between(app,'function appointmentWhatsAppUrlV129','async function appointmentsPage()');
  const appointmentRenderer=between(app,'  function renderAppointmentDetails(item,{startEditing=false}={}){','  function wireAppointmentActions(){');
  const sourceHash=createHash('sha256').update([
    style,customerUi,customers,profile,historyRenderer,till,whatsapp,appointmentRenderer
  ].join('\n')).digest('hex');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="production-source-sha256" content="${sourceHash}"><title>Peekaa V129 actual-renderer browser acceptance</title><style>${style}
  body{padding:20px}.v129-shell{max-width:1180px;margin:auto}.v129-provenance{font-size:11px;color:var(--muted);overflow-wrap:anywhere;margin-bottom:10px}.v129-nav{display:flex;gap:8px;overflow:auto;margin-bottom:14px}.v129-nav button{white-space:nowrap}.appointment-detail-modal{position:relative;inset:auto;background:transparent;padding:0}.appointment-detail-modal .modal-card{margin:0 auto}
  @media(max-width:600px){body{padding:10px}.card{padding:16px}}
  </style></head><body><div class="v129-shell"><p class="v129-provenance">Actual production-renderer harness · ${sourceHash}</p>
  <nav class="v129-nav" aria-label="V129 acceptance views"><button class="btn" data-view="customers">Customers</button><button class="btn ghost" data-view="profile">Customer profile</button><button class="btn ghost" data-view="appointment">Appointment</button><button class="btn ghost" data-view="sale">Record sale</button></nav>
  <main id="main"></main></div><div id="toast" class="toast"></div><div id="appStatus"></div><div id="appAlert"></div><script>
  ${customerUi}
  const CUI=window.FrenlyCustomerUI;
  const BRAND={productName:'Peekaa',downloadPrefix:'nestly'};
  const $=id=>document.getElementById(id);
  const M=()=>document.getElementById('main');
  const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
  const money=cents=>'SGD '+(Number(cents||0)/100).toFixed(2);
  const sgt=iso=>{if(!iso)return null;const date=new Date(new Date(iso).getTime()+8*3600000);return date.toISOString().slice(0,16).replace('T',' ')};
  const workspaceTemplateAttributeV97=(attribute,key,values)=>attribute+'="'+esc(key==='openCustomer'?'Open '+values.name:key)+'"';
  const workspaceTemplateHtmlV97=(key,values)=>key==='customerPagination'?values.total+' customers · page '+values.page+' of '+values.pages:'';
  const workspaceTemplateTextV97=key=>key;
  const workspaceTranslationV97=value=>value;
  const localizeWorkspaceSubtreeV97=()=>{};
  const importBtn=()=>'';
  const toast=message=>{window.__lastToast=message};
  const fail=error=>{window.__consoleErrors.push(String(error?.message||error))};
  const nav=hash=>{window.__lastNavigation=hash};
  const copyTextToClipboard=async()=>{};
  const createLatestRequestGate=isCurrent=>{let generation=0;return {begin(){const mine=++generation;return ()=>mine===generation&&isCurrent()},invalidate(){generation++}}};
  const normalizeCustomerSearchPhoneDigits=value=>{let digits=String(value||'').replace(/\D/g,'');if(digits.length===10&&digits.startsWith('65'))digits=digits.slice(2);return /^\d{8}$/.test(digits)?digits:null};
  const fetchAllRows=async factory=>{const result=await factory();return result.data||[]};
  let pendingCustomerSearch='',pendingTillPhone='',pendingApptClientId='',pendingCustomerInactivity=null;
  let currentView='customers';
  const fixtureRole=new URLSearchParams(location.search).get('role')||'owner';
  const S={myRole:fixtureRole==='readonly'?'frontdesk':'owner',user:{id:fixtureRole+'-v129'},biz:{id:'business-v129',name:'Glow Atelier',currency:'SGD'}};
  const canWriteModule=module=>new URLSearchParams(location.search).get('role')!=='readonly'&&['clients','loyalty','appointments'].includes(module);
  const canReadModule=module=>['clients','loyalty','appointments','till'].includes(module);
  const hasRoleCapability=capability=>currentView==='sale'?false:capability==='create_sales';
  const loadCustomerFeatureCapabilities=async()=>({customer_birthday_benefits:false});
  const loadReversalWorkflows=async()=>({sales:[],redemptions:[]});
  const bindReversalButtons=()=>{};
  const campaignEntitlementDisplayV99=item=>({pending:false,title:item?.program_name||'Reward'});
  const recordProductInteractionV100=()=>{};
  const staffQ=query=>query;
  const normalizeSingaporeCustomerPhone=value=>{let digits=String(value||'').replace(/\D/g,'');if(digits.length===10&&digits.startsWith('65'))digits=digits.slice(2);return /^\d{8}$/.test(digits)?'+65'+digits:''};
  const fixtureCustomers=[
    {id:'active-20',full_name:'Mei Active',phone:'8123 0001',created_at:'2026-01-12T06:00:00.000Z',marketing_consent:true,last_visit_at:'2026-07-12T06:00:00.000Z',days_since_last_visit:20,points:320,balance_cents:0},
    {id:'exact-30',full_name:'Lee Thirty',phone:'8123 0030',created_at:'2026-02-03T06:00:00.000Z',marketing_consent:true,last_visit_at:'2026-07-02T06:00:00.000Z',days_since_last_visit:30,points:90,balance_cents:0},
    {id:'exact-60',full_name:'Lee Sixty',phone:'8123 0060',created_at:'2026-03-15T06:00:00.000Z',marketing_consent:false,last_visit_at:'2026-06-02T06:00:00.000Z',days_since_last_visit:60,points:50,balance_cents:0},
    {id:'exact-90',full_name:'Arun Ninety',phone:'8123 0090',created_at:'2026-04-08T06:00:00.000Z',marketing_consent:true,last_visit_at:'2026-05-03T06:00:00.000Z',days_since_last_visit:90,points:510,balance_cents:1200},
    {id:'package-active',full_name:'Package Active',phone:'8123 0777',created_at:'2026-05-19T06:00:00.000Z',marketing_consent:true,last_visit_at:'2026-07-31T06:00:00.000Z',days_since_last_visit:1,points:0,balance_cents:0},
    {id:'never',full_name:'New Never',phone:'8123 0999',created_at:'2026-07-29T06:00:00.000Z',marketing_consent:false,last_visit_at:null,days_since_last_visit:null,points:0,balance_cents:0}
  ];
  const profileClient={id:'profile-client',business_id:'business-v129',full_name:'Mei Lin',phone:'8123 4567',email:'mei@example.test',referral_code:'MEI2026',marketing_consent:true};
  const profileSales=[{id:'sale-one',occurred_at:'2026-07-24T06:00:00.000Z',kind:'service',amount_cents:8800,note:'Signature facial',counts_as_visit:true,counts_as_revenue:true,reversal_of:null,staff_id:null}];
  const profileProgram=[{id:'programme-one',active:true,loyalty_model:'points_tiers',earn_points_per_dollar:10,redeem_points:500,reward_credit_cents:1000}];
  const profileRewards=[{id:'reward-one',active:true,customer_name:'Signature facial reward',cost_points:500,sort:1,created_at:'2026-01-01'}];
  window.__rpcCalls=[];window.__consoleErrors=[];window.__customerErrorUsed=false;window.__joinedErrorUsed=false;window.__expiryErrorUsed=false;
  function queryData(table,single){
    const params=new URLSearchParams(location.search);
    const rows={clients:profileClient,client_points_balance:[{points:320}],client_credit_balance:[{balance_cents:0}],loyalty_programs:params.get('no_programme')==='1'?[]:profileProgram,points_batches:params.get('no_expiry')==='1'?[]:[{remaining:300,expires_at:'2026-09-28T00:00:00.000Z'}],loyalty_rewards:profileRewards,sales:profileSales,appointments:[],staff:[],client_field_definitions:[],client_field_values:[],client_field_options:[],memberships:[],client_packages:[],branches:[],staff_branches:[]}[table]??[];
    return single&&!Array.isArray(rows)?rows:rows;
  }
  function fixtureQuery(table){
    let single=false,fields='';
    const query={select(value){fields=value||'';return query},eq(){return query},gt(){return query},gte(){return query},lt(){return query},not(){return query},is(){return query},in(){return query},order(){return query},limit(){return query},range(){return query},upsert(){return query},delete(){return query},single(){single=true;return query},maybeSingle(){single=true;return query},
      then(resolve,reject){const params=new URLSearchParams(location.search);if(table==='clients'&&fields==='id,created_at'&&params.get('joined_error')==='1'&&!window.__joinedErrorUsed){window.__joinedErrorUsed=true;return Promise.resolve({data:null,error:{message:'Synthetic Date joined interruption'},count:0}).then(resolve,reject)}if(table==='points_batches'&&params.get('expiry_error')==='1'&&!window.__expiryErrorUsed){window.__expiryErrorUsed=true;return Promise.resolve({data:null,error:{message:'Synthetic expiry interruption'},count:0}).then(resolve,reject)}const data=table==='clients'&&fields==='id,created_at'?fixtureCustomers.map(({id,created_at})=>({id,created_at})):queryData(table,single);return Promise.resolve({data,error:null,count:Array.isArray(data)?data.length:1}).then(resolve,reject)}};
    return query;
  }
  const sb={from:fixtureQuery,rpc:async(name,args)=>{
    window.__rpcCalls.push({name,args});
    if(name==='staff_list_customers_v129'){
      if(new URLSearchParams(location.search).get('denied')==='1')return {data:null,error:{message:'customer read access required',code:'42501'}};
      if(new URLSearchParams(location.search).get('error')==='1'&&!window.__customerErrorUsed){window.__customerErrorUsed=true;return {data:null,error:{message:'Synthetic connection interruption'}}}
      const threshold=Number(args.p_inactive_days||0);
      const customers=new URLSearchParams(location.search).get('empty')==='1'?[]:fixtureCustomers.filter(row=>!threshold||row.days_since_last_visit===null||row.days_since_last_visit>=threshold);
      return {data:{status:'ok',inactive_days:args.p_inactive_days,total:customers.length,customers},error:null};
    }
    if(name==='staff_list_visit_feedback')return {data:{feedback:[]},error:null};
    if(name==='staff_get_reward_entitlements_v99')return {data:[],error:null};
    return {data:null,error:null};
  }};
  ${customers}
  ${profile}
  ${historyRenderer}
  ${till}
  ${whatsapp}
  let closeAppointmentDialog=null;
  const statusGate=createLatestRequestGate(()=>true);
  const canWrite=true,canComplete=true;
  const visibleBranches=[{id:'branch-orchard',name:'Orchard Road'}];
  const staffName={'staff-olivia':'Olivia Tan'};
  const sgInput=iso=>{const date=new Date(new Date(iso).getTime()+8*3600000);return date.toISOString().slice(0,16)};
  const calendarClock=iso=>new Intl.DateTimeFormat('en-SG',{hour:'2-digit',minute:'2-digit',hour12:false,timeZone:'Asia/Singapore'}).format(new Date(iso));
  const appointmentDuration=item=>Math.max(0,Math.round((new Date(item.ends_at)-new Date(item.starts_at))/60000));
  const appointmentTimeRange=item=>calendarClock(item.starts_at)+'–'+calendarClock(item.ends_at);
  const resolveBookedPriceCents=(appointmentTotal,serviceTotal)=>Number(appointmentTotal)>0?Number(appointmentTotal):Number(serviceTotal)>0?Number(serviceTotal):null;
  const safeCallNumber=item=>normalizeSingaporeCustomerPhone(item?.clients?.phone_norm||item?.clients?.phone);
  const appointmentOutcomeIsDue=item=>new Date(item.starts_at).getTime()<=Date.now();
  const branchStaff=()=>[];const staffLabel=person=>person.full_name||'Team member';
  const closeAppointmentDetails=()=>{if(closeAppointmentDialog){const close=closeAppointmentDialog;closeAppointmentDialog=null;close({restoreFocus:false})}else document.getElementById('appointmentDetailDialog')?.remove()};
  const setStatus=async()=>false;const rescheduleGate=createLatestRequestGate(()=>true);let rescheduleAttempt=null;
  const renderRescheduleSuggestions=()=>{};const sgIso=value=>value;const loadCalendar=()=>{};
  ${appointmentRenderer}
  async function showView(view){
    currentView=view;document.querySelectorAll('[data-view]').forEach(button=>{button.className=button.dataset.view===view?'btn':'btn ghost'});closeAppointmentDetails();M().innerHTML='';
    if(view==='customers'){
      await clientsPage();
      const requested=new URLSearchParams(location.search).get('inactive');
      if(requested){$('clientInactivity').value=requested;$('clientInactivity').dispatchEvent(new Event('change'));await new Promise(resolve=>setTimeout(resolve,20))}
    }else if(view==='profile')await clientDetail('profile-client');
    else if(view==='sale')await tillPage();
    else{
      M().innerHTML='<div class="cui-page-head"><div class="cui-page-title"><div><h1>Appointment</h1><p>Actual appointment detail renderer</p></div></div></div>';
      renderAppointmentDetails({id:'appointment-one',branch_id:'branch-orchard',staff_id:'staff-olivia',starts_at:'2026-08-03T06:00:00.000Z',ends_at:'2026-08-03T07:00:00.000Z',status:'completed',total_cents:8800,note:'Consult before treatment',clients:{full_name:'Mei Lin',phone:'8123 4567',phone_norm:'81234567',email:'mei@example.test',notes:'Synthetic browser fixture'},services:{name:'Signature facial',duration_min:60,price_cents:8800}});
    }
  }
  document.querySelectorAll('[data-view]').forEach(button=>button.addEventListener('click',()=>showView(button.dataset.view)));
  window.addEventListener('error',event=>window.__consoleErrors.push(event.message));
  window.v129Metrics=()=>({sourceHash:'${sourceHash}',view:currentView,width:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth,tableClientWidth:document.querySelector('.cui-table-wrap')?.clientWidth||null,tableScrollWidth:document.querySelector('.cui-table-wrap')?.scrollWidth||null,rows:document.querySelectorAll('#list table tr').length-1,genderVisible:/customer gender|gender not set/i.test(document.body.innerText),headings:[...document.querySelectorAll('h1,h2')].map(item=>item.textContent.trim()),expiryText:document.querySelector('.c360-points-expiry')?.textContent.trim()||'',rewardsText:document.querySelector('.c360-rewards-card')?.textContent.trim()||'',whatsappHref:document.getElementById('appointmentWhatsApp')?.href||'',buttons:[...document.querySelectorAll('button,.btn')].filter(item=>item.offsetParent!==null).map(item=>item.getBoundingClientRect().height),rpcCalls:window.__rpcCalls,errors:window.__consoleErrors});
  const initial=new URLSearchParams(location.search).get('view')||'customers';showView(initial).catch(error=>window.__consoleErrors.push(String(error?.stack||error)));
  </script></body></html>`;
}

if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url){
  const [app,customerUi]=await Promise.all([readFile(APP_URL,'utf8'),readFile(CUSTOMER_UI_URL,'utf8')]);
  await writeFile(FIXTURE_URL,buildV129TrialTestVisual(app,customerUi));
  process.stdout.write(`${fileURLToPath(FIXTURE_URL)}\n`);
}
