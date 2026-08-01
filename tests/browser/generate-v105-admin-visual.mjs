import {createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath,pathToFileURL} from 'node:url';

const APP_URL=new URL('../../app/index.html',import.meta.url);
const PLATFORM_CSS_URL=new URL('../../app/platform-console.css',import.meta.url);
const PLATFORM_JS_URL=new URL('../../app/platform-console.js',import.meta.url);
const PEEKAA_LOGO_URL=new URL('../../app/brand/peekaa-logo.png',import.meta.url);
const FIXTURE_URL=new URL('./v105-admin-visual.html',import.meta.url);

export async function buildV105AdminVisualFixture(){
  const [app,platformCss,platformJs,peekaaLogo]=await Promise.all([
    readFile(APP_URL,'utf8'),readFile(PLATFORM_CSS_URL,'utf8'),
    readFile(PLATFORM_JS_URL,'utf8'),readFile(PEEKAA_LOGO_URL)
  ]);
  const baseCss=app.match(/<style>([\s\S]*?)<\/style>/)?.[1];
  if(!baseCss)throw new Error('production inline stylesheet missing');
  const sourceHash=createHash('sha256')
    .update(baseCss).update('\n').update(platformCss).update('\n')
    .update(platformJs).update('\n/app/brand/peekaa-logo.png\n').update(peekaaLogo)
    .digest('hex');
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="v105-production-component-sha256" content="${sourceHash}">
<title>Peekaa v105 admin visual acceptance</title>
<style>${baseCss}\n${platformCss}
.v105-provenance{position:fixed;right:8px;bottom:8px;z-index:99;padding:4px 8px;border-radius:999px;background:#fff;border:1px solid #ddd;color:#67616d;font:11px/1.2 system-ui}
</style>
</head>
<body>
<div id="appStatus" class="sr-only" aria-live="polite"></div>
<div id="appAlert" class="sr-only" aria-live="assertive"></div>
<div id="v105AdminRoot"></div>
<span class="v105-provenance">v105 production-component harness · ${sourceHash.slice(0,12)}</span>
<script src="../../app/customer-ui.js"></script>
<script src="../../app/platform-console.js"></script>
<script>
const params=new URLSearchParams(location.search);
const role=params.get('role')||'super_admin';
const failure=params.get('failure')||'';
const route=params.get('route')||'overview';
const now='2026-07-29T10:00:00+08:00';
const responses={
  get_workspace_locale_preference_v97:{locale:'en',version:1},
  platform_list_my_access_v89:role==='denied'?{role:'business_owner'}:{
    role,scope:role==='sales_staff'?'own_created_or_assigned':'all',
    module_perms:role==='admin'?{overview:'r',onboarding:'rw',firms:'r',reports:'rw'}
      :role==='sales_staff'?{overview:'r',onboarding:'rw',firms:'r',reports:'r'}:{}
  },
  platform_list_firm_onboarding_v88:{
    items:[
      {business_id:'firm-glow',name:'Glow Atelier',sector_key:'facial',lane_key:'contacting',
       source_stage_key:'appt_set',attention_severity:'warning',attention_due:true,
       days_unattended:3,owner_name:'Aisha Tan',boss_phone:'81234567'},
      {business_id:'firm-cafe',name:'Harbour Bean',sector_key:'fnb',lane_key:'case_won',
       source_stage_key:'onboarding',attention_severity:'info',attention_due:false,
       days_unattended:1,owner_name:'Marcus Lim',boss_phone:'82345678'}
    ],
    total_count:148,snapshot_at:now,attention_summary:{due:1,warning:1,info:1}
  },
  platform_list_firm_attention_v88:{items:[
    {business_id:'firm-glow',name:'Glow Atelier',lane_key:'contacting',source_stage_key:'appt_set',
     attention_severity:'warning',attention_due:true,days_unattended:3,
     next_action_at:'2026-07-29T09:00:00+08:00',owner_name:'Aisha Tan'}
  ]},
  get_platform_billing_v77:[
    {business_id:'firm-well',business_name:'Wellness House',status:'past_due',
     payment_status:'past_due',days_past_due:4,owner_name:'Nadia Lee',updated_at:now}
  ],
  get_consultant_commission_dashboard_v78:{accruals:[
    {id:'commission-1',consultant_name:'Marcus Lim',status:'payable',due_at:'2026-07-30T10:00:00+08:00'}
  ]},
  platform_list_business_applications_v95:{applications:[
    {id:'application-1',business_name:'Little Orchard Salon',status:'submitted',
     submitted_at:'2026-07-28T09:00:00+08:00',owner_name:'Unassigned'}
  ]},
  platform_get_automation_reconciliation_v89:{runs:[]},
  platform_list_my_firms_v105:{items:[
    {business_id:'firm-glow',name:'Glow Atelier',prospect_id:'prospect-1',
     row_id:'11111111-1111-4111-8111-111111111111',updated_at:'2026-07-29T09:00:00+08:00',
     lane_key:'contacting',source_stage_key:'appt_set',attention_due:true,
     attention_severity:'warning',days_unattended:3,owner_name:'Aisha Tan'},
    {business_id:'firm-cafe',name:'Harbour Bean',prospect_id:'prospect-2',
     row_id:'22222222-2222-4222-8222-222222222222',updated_at:'2026-07-28T09:00:00+08:00',
     lane_key:'case_won',source_stage_key:'onboarding',attention_due:false,
     attention_severity:'none',owner_name:'Aisha Tan'}
  ],scope:role==='sales_staff'?'own_created_or_assigned':'all',
    snapshot_at:now,total_count:2,next_cursor:null},
  platform_get_enterprise_hierarchy_v82:{
    firms:[{
      business_id:'firm-glow',id:'firm-glow',name:'Glow Atelier',
      legal_name:'Glow Atelier Pte Ltd',industry:'facial',sector_key:'facial',
      registration_number:'202612345N',owner_name:'Aisha Tan',
      owner_email:'owner@glow.test',owner_phone:'81234567',
      branch_count:2,staff_count:8,customer_count:164,currency:'SGD',
      created_at:'2026-01-10T10:00:00+08:00',
      summary:{
        net_revenue_cents:18425000,cash_collected_cents:18000000,
        returning_customers:71,completed_transactions:428
      },
      branches:[
        {branch_id:'branch-orchard',name:'Orchard',active:true,is_default:true,
         customer_count:101,staff_count:5,net_revenue_cents:11500000,completed_transactions:271},
        {branch_id:'branch-tampines',name:'Tampines',active:true,is_default:false,
         customer_count:63,staff_count:3,net_revenue_cents:6925000,completed_transactions:157}
      ]
    }],
    snapshot_at:now,
    pagination:{total_firms:1,returned_firms:1,has_more:false,next_cursor:null}
  },
  platform_list_enterprise_customers_v82:{
    customers:[
      {client_id:'customer-1',full_name:'Mei Lin Tan',phone:'89881234',
       email:'mei@example.test',net_revenue_cents:48600,cash_collected_cents:48600,
       completed_transactions:8,visit_count:8,first_purchase_at:'2026-02-11T10:00:00+08:00',
       last_purchase_at:'2026-07-28T17:30:00+08:00'}
    ],
    snapshot_at:now,
    pagination:{total_customers:164,returned_customers:1,has_more:false,next_cursor:null}
  },
  platform_get_business_control_v94:{
    approval:{status:'approved',version:2},
    subscription:{state:'active',due_date:'2026-08-01',workspace_paused:false},
    representative:{display_name:'Nadia Lee',hotline_phone:'81234567'},
    catalogue_intelligence:{enabled:true,version:1},
    workspace_access:true
  },
  platform_get_effective_modules_v105:{
    business_id:'firm-glow',branch_id:null,workspace_access:true,inventory_global_disabled:true,
    modules:[
      {module_key:'dashboard',mode:'rw',source:'sector',version:null,override_mode:'inherit',override_version:null},
      {module_key:'clients',mode:'rw',source:'sector',version:null,override_mode:'inherit',override_version:null},
      {module_key:'appointments',mode:'rw',source:'sector',version:null,override_mode:'inherit',override_version:null},
      {module_key:'loyalty',mode:'rw',source:'sector',version:null,override_mode:'inherit',override_version:null},
      {module_key:'reports',mode:'r',source:'firm',version:3,override_mode:'r',override_version:3}
    ]
  },
  platform_set_module_overrides_v105:{business_id:'firm-glow',branch_id:null,updated_count:2,modules:[]},
  platform_list_sector_entitlements_v75:{profiles:[
    {sector_key:'facial',name:'Facial / Spa',status:'active',versions:[{version:1,status:'published'}]}
  ],businesses:[
    {business_id:'firm-glow',business_name:'Glow Atelier',sector_key:'facial',assignment_version:1}
  ]}
};
const sb={rpc:async(name)=>{
  if(failure===name)return{data:null,error:{code:'PGRST500',message:'fixture failure'}};
  return{data:Object.prototype.hasOwnProperty.call(responses,name)?responses[name]:null,error:null};
}};
const root=document.getElementById('v105AdminRoot');
const CUI=window.FrenlyCustomerUI;
window.NestlyPlatformConsole.render({
  root,sb,CUI,brand:{productName:'Peekaa',logoPath:'/app/brand/peekaa-logo.png'},
  hash:'#/platform/'+route,isCurrent:()=>true,onSignOut:()=>{},workspaceHash:'#/workspace'
}).then(()=>document.documentElement.dataset.ready='true').catch(error=>{
  document.documentElement.dataset.ready='error';
  root.textContent='Harness error: '+error.message;
});
window.v105AcceptanceMetrics=()=>({
  sourceHash:'${sourceHash}',
  ready:document.documentElement.dataset.ready,
  viewport:{clientWidth:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth},
  role,
  primaryGroups:[...document.querySelectorAll('.platform-nav-group:not(.platform-nav-secondary)')].map(node=>node.textContent.trim()),
  secondaryGroups:[...document.querySelectorAll('.platform-nav-secondary')].map(node=>node.textContent.trim()),
  todayItems:document.querySelectorAll('[data-platform-today-item]').length,
  primaryActions:document.querySelectorAll('[data-today-primary-action]').length,
  firmDirectoryRows:document.querySelectorAll('[data-enterprise-firm]').length,
  firmModuleManagers:document.querySelectorAll('[data-module-control]').length,
  perModuleEditButtons:[...document.querySelectorAll('button')].filter(node=>/^edit$/i.test(node.textContent.trim())).length,
  modulePolicy:{
    open:Boolean(document.querySelector('.platform-module-policy-list')),
    groups:document.querySelectorAll('.platform-module-policy-group').length,
    rows:document.querySelectorAll('.platform-module-policy-row').length,
    selectors:document.querySelectorAll('[data-module-mode]').length,
    resetButtons:document.querySelectorAll('[data-reset-module-policy]').length,
    saveButtons:[...document.querySelectorAll('button')].filter(node=>/save module access/i.test(node.textContent.trim())).length
  },
  touchTargets:[...document.querySelectorAll('button,.btn,a.platform-nav-link')].map(node=>({
    text:node.textContent.trim(),width:node.getBoundingClientRect().width,height:node.getBoundingClientRect().height,
    visible:Boolean(node.getClientRects().length)
  })),
  horizontalOverflow:document.documentElement.scrollWidth>document.documentElement.clientWidth,
  visibleText:document.body.innerText
});
</script>
</body>
</html>`;
}

if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url){
  await writeFile(FIXTURE_URL,await buildV105AdminVisualFixture());
  process.stdout.write(`${fileURLToPath(FIXTURE_URL)}\n`);
}
