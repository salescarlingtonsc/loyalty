/* nestly_v785 — the Pipeline: the console's CRM home.

   Owner, 2026-09-05 (three photos, four rulings): photo 2 is the look (Peekaa red, five lanes, a
   business drawer); photo 3 is what the drawer carries — next appointment (with time, synced to
   a calendar), next follow-up (a date, shown on the card as "Due in 7D / Due tomorrow / Due today
   / Overdue 2D") and last edited; notes with attached documents and timestamps; everything in
   Singapore time. Rulings: proposal = Pending Decision → Closed; Pipeline replaces the Onboarding
   board; calendar = the console list plus .ics.

   The renderers are EXECUTED (vm-loaded console, stub CUI); routing, dispatch and the migration's
   contract are pinned by source. */
import assert from 'node:assert/strict';
const same=(actual,expected,message)=>assert.equal(JSON.stringify(actual),JSON.stringify(expected),message);
const laneHtml=(html,key)=>{const start=html.indexOf(`data-lane-drop="${key}"`);const rest=html.slice(start+1);const next=rest.search(/data-lane-drop=/);return next<0?rest:rest.slice(0,next)};
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole(){
  const source=await read('app/platform-console.js');
  const context={Object,URL,URLSearchParams,Intl,Date,Map,Set,Proxy,Reflect,JSON,Number,String,Array,RegExp,Math,encodeURIComponent,decodeURIComponent};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}
const stubCUI=Object.freeze({
  icon:name=>`<i data-icon="${name}"></i>`,
  card:({title,description,body})=>`<section><h2>${title}</h2><p>${description??''}</p>${body}</section>`,
  status:(text,tone)=>`<span class="status ${tone}">${text}</span>`,
  loadingState:({title,body})=>`<div><h3>${title}</h3><p>${body}</p></div>`,
  errorState:({title,message})=>`<div><h3>${title}</h3><p>${message}</p></div>`,
  field:({id,label,value=''})=>`<label for="${id}">${label}</label><input id="${id}" value="${value}">`
});

const today='2026-09-05';
const items=[
  {id:'p-jess',company_name:'Jess Salon',sector_key:'beauty',current_stage_key:'proposal',lane:'pending_decision',version:4,
    assigned_consultant_id:'c-1',consultant_name:'Jeya',next_follow_up_on:'2026-09-05',follow_up_days:0,
    next_appointment_at:'2026-09-05T07:00:00+00:00',updated_at:'2026-09-05T06:15:00+00:00',stage_entered_at:'2026-09-03T02:00:00+00:00',
    next_task:{title:'Follow up on proposal'},primary_contact:{full_name:'Sarah Tan',phone:'+65 9123 4567'},payment_due:false},
  {id:'p-daily',company_name:'The Daily Grind Cafe',sector_key:'cafe',current_stage_key:'contacted',lane:'contact',version:2,
    assigned_consultant_id:'c-2',consultant_name:'Ke Ying',next_follow_up_on:'2026-09-03',follow_up_days:-2,
    updated_at:'2026-09-04T01:00:00+00:00',stage_entered_at:'2026-09-01T02:00:00+00:00',last_activity:{activity_type:'call',summary:'Schedule meeting'},payment_due:false},
  {id:'p-carl',company_name:'Carlington Smith Consultancy Pte. Ltd.',sector_key:null,industry:'Business Services',current_stage_key:'new_lead',lane:'new_lead',version:1,
    assigned_consultant_id:null,consultant_name:null,next_follow_up_on:'2026-09-12',follow_up_days:7,updated_at:'2026-09-02T01:00:00+00:00',stage_entered_at:'2026-09-02T01:00:00+00:00',payment_due:false},
  {id:'p-only',company_name:'Cafe Only',sector_key:'cafe',current_stage_key:'activated',lane:'closed',version:9,
    assigned_consultant_id:'c-3',consultant_name:'Jun Wei',next_follow_up_on:null,follow_up_days:null,updated_at:'2026-09-02T01:00:00+00:00',stage_entered_at:'2026-09-02T01:00:00+00:00',
    converted_business_id:'b-1',business_name:'Cafe Only',branch_count:2,payment_due:true},
  {id:'p-lost',company_name:'Gone Bakery',sector_key:'cafe',current_stage_key:'lost',lane:'lost',version:3,
    assigned_consultant_id:'c-1',consultant_name:'Jeya',follow_up_days:null,updated_at:'2026-08-20T01:00:00+00:00',stage_entered_at:'2026-08-20T01:00:00+00:00',payment_due:false},
  {id:'p-tmrw',company_name:'Skin Lab',sector_key:'beauty',current_stage_key:'interested',lane:'proposal',version:2,
    assigned_consultant_id:'c-2',consultant_name:'Ke Ying',next_follow_up_on:'2026-09-06',follow_up_days:1,updated_at:'2026-09-05T01:00:00+00:00',stage_entered_at:'2026-09-04T01:00:00+00:00',payment_due:false}
];

test('v785 the due ladder is the owner\'s exact wording', async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');
  same(api.pipelineDueLabelV785(7),{text:'Due in 7D',tone:'later'});
  same(api.pipelineDueLabelV785(3),{text:'Due in 3D',tone:'soon'});
  same(api.pipelineDueLabelV785(1),{text:'Due tomorrow',tone:'soon'});
  same(api.pipelineDueLabelV785(0),{text:'Due today',tone:'today'});
  same(api.pipelineDueLabelV785(-2),{text:'Overdue 2D',tone:'overdue'});
  same(api.pipelineDueLabelV785(null),{text:'',tone:''});
});

test('v785 KPIs are counted from the same rows the lanes show', async()=>{
  const api=await loadConsole();
  const kpis=api.pipelineKpisV785(items,today);
  assert.equal(kpis.new_leads,1);
  assert.equal(kpis.new_leads_due_today,0);
  assert.equal(kpis.follow_up_due,2,'Jess Salon (today) and The Daily Grind (overdue); never the closed or lost ones');
  assert.equal(kpis.follow_up_overdue,1);
  assert.equal(kpis.pending_decision,1);
  assert.equal(kpis.pending_due_week,1);
  assert.equal(kpis.won_this_month,1,'Cafe Only entered Closed in September');
  assert.equal(kpis.payment_due,1);
  assert.equal(kpis.appointments_upcoming,items.filter(row=>row.next_appointment_at&&new Date(row.next_appointment_at)>=new Date()).length);
});

test('v785 the board has five lanes, lost firms sit inside Closed, and each card says who and when', async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');
  const html=api.pipelineBoardHtmlV785(items,stubCUI,{canWrite:true});
  for(const lane of ['new_lead','contact','proposal','pending_decision','closed'])assert.match(html,new RegExp(`data-lane="${lane}"`));
  assert.equal((html.match(/data-lane-drop=/g)||[]).length,5);
  const closed=laneHtml(html,'closed');
  assert.match(closed,/Gone Bakery/,'a lost firm is shown inside Closed');
  assert.match(closed,/Won · 2 Sept? 2026/);
  assert.match(closed,/Payment due/);
  const contact=laneHtml(html,'contact');
  assert.match(contact,/The Daily Grind Cafe/);
  assert.match(contact,/data-tone="overdue"[^>]*>Overdue 2D/);
  assert.match(contact,/>KY<\/span><span>Ke Ying/,'the advisor shows as initials plus name');
  assert.match(contact,/1 overdue/,'the lane subline counts its overdue firms');
  const newLead=laneHtml(html,'new_lead');
  assert.match(newLead,/Unassigned/);
  assert.match(newLead,/Due in 7D/);
  const pending=laneHtml(html,'pending_decision');
  assert.match(pending,/Due today/);
  assert.match(pending,/Follow up on proposal/);
  assert.match(pending,/1 due this week/);
  // Converted and closed firms are never draggable; open leads are.
  assert.match(closed,/draggable="false"/);
  assert.doesNotMatch(closed,/draggable="true"/);
  assert.match(newLead,/draggable="true"/);
  // Every non-closed lane offers Add Lead to a writer.
  assert.equal((html.match(/data-pipeline-add-lead/g)||[]).length,4);
});

test('v785 lane moves resolve to the stage the lane stands for, and an owned lead never drops back to new_lead', async()=>{
  const api=await loadConsole();
  assert.equal(api.pipelineLaneTargetStageV785('contact',{}),'contacted');
  assert.equal(api.pipelineLaneTargetStageV785('proposal',{}),'interested');
  assert.equal(api.pipelineLaneTargetStageV785('pending_decision',{}),'proposal');
  assert.equal(api.pipelineLaneTargetStageV785('closed',{}),'closed_won');
  assert.equal(api.pipelineLaneTargetStageV785('new_lead',{}),'new_lead');
  assert.equal(api.pipelineLaneTargetStageV785('new_lead',{assigned_consultant_id:'c-1'}),'assigned');
  assert.equal(api.pipelineLaneTargetStageV785('nowhere',{}),null);
});

test('v785 the hash carries scope, advisor, search, sort, KPI filter and the open firm', async()=>{
  const api=await loadConsole();
  const filters={scope:'mine',consultant:'c-1',search:'jess',sort:'name',kpi:'follow_up_due',prospect:'p-jess',calendar:true};
  const hash=api.pipelineHashV785(filters);
  same(api.pipelineFiltersFromHashV785(hash),filters);
  assert.equal(api.pipelineHashV785({}),'#/platform/pipeline');
  assert.equal(api.pipelineFiltersFromHashV785('#/platform/pipeline?sort=bogus').sort,'due');
});

test('v785 sort by due date puts overdue first and firms with no follow-up last', async()=>{
  const api=await loadConsole();
  const sorted=api.pipelineSortV785(items,'due').map(row=>row.id);
  assert.equal(sorted[0],'p-daily');
  assert.equal(sorted[1],'p-jess');
  assert.ok(sorted.indexOf('p-only')>sorted.indexOf('p-carl'));
});

test('v785 the .ics and Google Calendar links carry the appointment in UTC and name the firm', async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');
  const ics=api.pipelineIcsV785(items[0]);
  assert.match(ics,/BEGIN:VCALENDAR/);
  assert.match(ics,/DTSTART:20260905T070000Z/);
  assert.match(ics,/DTEND:20260905T080000Z/);
  assert.match(ics,/SUMMARY:Jess Salon — Peekaa appointment/);
  assert.match(ics,/Contact: Sarah Tan · \+65 9123 4567/);
  const google=api.pipelineGoogleCalendarUrlV785(items[0]);
  assert.match(google,/^https:\/\/calendar\.google\.com\/calendar\/render\?/);
  assert.match(google,/dates=20260905T070000Z%2F20260905T080000Z/);
  assert.match(google,/ctz=Asia%2FSingapore/);
  assert.equal(api.pipelineIcsV785({next_appointment_at:null}),'');
});

test('v785 the drawer shows next action, company info with last edited, branches, tabs and the note composer', async()=>{
  const api=await loadConsole();
  api.setPlatformLocaleForTest('en');
  const detail={today,
    prospect:{id:'p-only',current_stage_key:'activated',lane:'closed',version:9,converted_business_id:'b-1',
      next_follow_up_on:'2026-09-08',next_appointment_at:'2026-09-06T07:00:00+00:00',created_at:'2026-09-02T01:00:00+00:00',updated_at:'2026-09-05T06:15:00+00:00',region:'Tampines'},
    company:{legal_name:'CAFE ONLY PTE LTD',trading_name:'Cafe Only',sector_key:'cafe',phone:'+65 6123 4567',email:'hello@cafeonly.sg'},
    consultant:{display_name:'Jun Wei'},
    contacts:[{id:'c1',full_name:'Sarah Tan',phone:'+65 9123 4567',email:'sarah@cafeonly.sg',is_primary:true}],
    activities:[{id:'a1',activity_type:'note',summary:'Client wants to discuss with partner.',detail:'Client wants to discuss with partner.',occurred_at:'2026-09-05T06:15:00+00:00',
      attachments:[{document_version_id:'d1',original_filename:'quote.pdf'}]}],
    tasks:[],documents:[{id:'d1',original_filename:'quote.pdf',document_type:'other',created_at:'2026-09-05T06:14:00+00:00'}],documents_visible:true,
    business:{id:'b-1',name:'Cafe Only',branches:[{id:'br1',name:'Tampines (Main)',is_default:true,billing_state:'included'},{id:'br2',name:'Orchard',billing_state:'active'}]},
    stage_history:[]};
  const html=api.pipelineDrawerHtmlV785(items[3],detail,stubCUI,{tab:'activity',canWrite:true,payments:{value:{branches:[],invoices:[]},error:null}});
  assert.match(html,/Next Action/);
  assert.match(html,/Follow up<\/span>|Follow up · 8 Sept? 2026 · Due in 3D/);
  assert.match(html,/Appointment · 6 Sept? 2026/);
  assert.match(html,/Add to calendar/);
  assert.match(html,/data-pipeline-mark-done/);
  assert.match(html,/Last edited<\/dt><dd>5 Sept? 2026/);
  assert.doesNotMatch(html,/Last contacted/,'the owner asked for last edited, not last contacted');
  assert.match(html,/data-pipeline-tab="branches"/,'owner 2026-09-06: a Branches tab');
  assert.match(html,/data-pipeline-tab="activity" aria-selected="true"/);
  // The Branches tab: every branch, what it is paid to, and whether auto deduction is on.
  const branchesTab=api.pipelineDrawerHtmlV785(items[3],detail,stubCUI,{tab:'branches',canWrite:true,payments:{value:{
    subscription:{status:'active',cadence:'annual',cancel_at_period_end:false,current_period_end:'2027-09-04T16:00:00+00:00'},
    branches:[{branch_id:'br1',name:'Tampines (Main)',is_default:true,billing_state:'included'},{branch_id:'br2',name:'Orchard',billing_state:'active'},{branch_id:'br3',name:'Bedok',billing_state:'canceling'}],
    invoices:[{provider_invoice_id:'i1',status:'paid',paid_normalized:true,total_cents:118800,currency:'SGD',paid_at:'2026-09-05T09:59:01+00:00',reason:'initial',detail:{covers_until:'2027-09-05'}},
      {provider_invoice_id:'i2',status:'paid',paid_normalized:true,total_cents:118800,currency:'SGD',paid_at:'2026-09-05T10:15:40+00:00',reason:'branch_added',detail:{branch_id:'br2',branch_name:'Orchard',covers_until:'2027-09-05'}}]
  },error:null}});
  assert.match(branchesTab,/Tampines \(Main\)/);
  assert.match(branchesTab,/Orchard/);
  assert.equal((branchesTab.match(/Paid to 5 Sept? 2027/g)||[]).length,2,'the plan payment covers the main branch, the branch charge covers Orchard');
  assert.equal((branchesTab.match(/Auto deduction · On/g)||[]).length,2);
  assert.match(branchesTab,/Bedok[\s\S]*?No payment yet[\s\S]*?Auto deduction · Off/,'a stopping branch says so');
  assert.match(branchesTab,/Renews on 5 Sept? 2027/);
  assert.match(html,/data-pipeline-tab="deal"/);
  assert.match(html,/5 Sept? 2026, 2:15 pm|5 Sept? 2026, 14:15|2:15 PM/i,'note timestamps are shown in Singapore time');
  assert.match(html,/data-pipeline-attachment="d1"/);
  assert.match(html,/data-pipeline-note-form/);
  assert.match(html,/type="file" name="files" multiple/);
  const files=api.pipelineDrawerHtmlV785(items[3],detail,stubCUI,{tab:'files',canWrite:false});
  assert.match(files,/quote\.pdf/);
  assert.doesNotMatch(files,/data-pipeline-note-form/,'a read-only viewer gets no composer');
});

test('v785 routing: Pipeline is the Sales home, CRM redirects to it, Onboarding keeps its tabs', async()=>{
  const api=await loadConsole();
  const access={role:'super_admin',modulePerms:{},scope:'all'};
  const keys=api.visibleRoutes(access).map(route=>route.key);
  assert.ok(keys.includes('pipeline'));
  assert.ok(!keys.includes('crm'));
  assert.equal(api.routeKey('#/platform/crm?q=jess&consultant=c-1'),'pipeline');
  assert.equal(api.isRoute('#/platform/pipeline'),true);
  assert.equal(api.isRoute('#/platform/crm'),true,'old bookmarks still resolve');
  const sales=api.platformNavigationGroups(api.visibleRoutes(access)).find(group=>group.key==='sales');
  same(sales.routes.map(route=>route.key),['pipeline','onboarding','prospecting']);
  assert.equal(api.routes.find(route=>route.key==='onboarding').hash,'#/platform/onboarding?tab=applications');
  assert.equal(api.routeKey('#/platform/onboarding?tab=applications'),'onboarding');
});

test('v785 the dispatcher sends the pipeline route and the old board tab to renderPipelineV785; moves keep their evidence', async()=>{
  const source=await read('app/platform-console.js');
  const router=source.slice(source.indexOf('async function render({root,sb,CUI,brand,hash,isCurrent,onSignOut'),source.indexOf('globalObject.NestlyPlatformConsole = Object.freeze({'));
  assert.match(router,/activeKey==='pipeline'\)task=renderPipelineV785\(context\)/);
  assert.match(router,/onboardingFilters\.tab==='pipeline'\s*\?renderPipelineV785\(/);
  assert.doesNotMatch(router,/activeKey==='crm'\)task=renderCrm/);
  const block=source.slice(source.indexOf('const PIPELINE_LANES_V785='),source.indexOf('// nestly_v779 (owner, 2026-09-05): a firm\'s payments, branch by branch.'));
  assert.match(block,/requestStageMove\(\{\.\.\.item,prospect_id:item\.id\},toStage,context\)/,'every lane move goes through the evidence flow');
  assert.match(block,/rpc\(sb,'platform_pipeline_board_v785'/);
  // v787: an admin console registers self-serve workspaces before reading the board; a failure is swallowed.
  assert.match(block,/if\(!salesStaff&&canWrite\)\{\s*try\{await rpc\(sb,'platform_pipeline_sync_live_firms_v787',\{\}\)\}catch\{/);
  assert.ok(block.indexOf("platform_pipeline_sync_live_firms_v787")<block.indexOf("rpc(sb,'platform_pipeline_board_v785'"),'the sync runs before the board read');
  assert.match(block,/rpc\(sb,'platform_pipeline_prospect_v785'/);
  assert.match(block,/rpc\(sb,'platform_pipeline_set_schedule_v785'/);
  assert.match(block,/rpc\(sb,'platform_pipeline_add_note_v785'/);
  assert.match(block,/platform_request_prospect_document_upload_v86/,'attachments travel the v86 vault path');
  assert.match(block,/invokeDocumentSigner\(sb,\{action:'finalize'/);
  assert.doesNotMatch(block,/\.from\('sme_prospects'\)|\.insert\(|\.update\(/,'the browser never writes tables directly');
  assert.match(block,/timeZone:'Asia\/Singapore'/);
  // The Add Lead modal and the stage modals re-render the Pipeline, not the retired board.
  assert.match(source,/try\{if\(context\.refresh\)await context\.refresh\(\);else await renderOnboarding\(context\);\}/);
});

test('v785 the migration adds the two schedule columns and four scoped functions, nothing more', async()=>{
  const sql=await read('db/migrations/20261006_nestly_v785_pipeline_schedule.sql');
  assert.match(sql,/add column if not exists next_appointment_at timestamptz/);
  assert.match(sql,/add column if not exists next_follow_up_on date/);
  assert.match(sql,/create or replace function app\.v785_lane\(p_stage text\)/);
  assert.match(sql,/when p_stage = 'proposal' then 'pending_decision'/,'owner ruling: proposal = Pending Decision');
  for(const fn of ['platform_pipeline_board_v785','platform_pipeline_prospect_v785','platform_pipeline_set_schedule_v785','platform_pipeline_add_note_v785']){
    assert.match(sql,new RegExp(`create or replace function public\\.${fn}\\(`));
    assert.match(sql,new RegExp(`revoke all on function public\\.${fn}\\([^)]*\\) from public, anon;`));
    assert.match(sql,new RegExp(`grant execute on function public\\.${fn}\\([^)]*\\) to authenticated, service_role;`));
  }
  assert.match(sql,/app\.v89_platform_can\('onboarding','r'\)/);
  assert.match(sql,/app\.v89_platform_can\('onboarding','rw'\)/);
  assert.match(sql,/app\.v89_can_access_prospect\(p_prospect\)/);
  assert.match(sql,/app\.can_access_prospect_sensitive_v86\(p_prospect\)/,'documents follow the v86 sensitive scope');
  assert.match(sql,/errcode='40001'/,'a stale version is a conflict, not a silent overwrite');
  assert.match(sql,/attachment does not belong to this prospect/);
  assert.match(sql,/v_mirror <= clock_timestamp\(\) \+ v_sla/,'next_action_at mirrors only inside the stage SLA');
  const mirror=await read('supabase/migrations/20261006050000_nestly_v785_pipeline_schedule.sql');
  assert.equal(mirror,sql,'both migration copies must be byte-identical');
});

test('v785 every new console string has a zh-CN and an ms translation', async()=>{
  const api=await loadConsole();
  const keys=['Paid to {date}','Auto deduction · On','Auto deduction · Off','Pipeline','New Lead','Contact & Meeting','NPU / Proposal','Pending Decision','Closed','Follow-up Due','Won This Month','Payment Due',
    'All Pipeline','My Pipeline','Overdue {count}D','Due today','Due tomorrow','Due in {count}D','Next appt (firm)','Next follow up (task)','Last edited',
    'Add to calendar','Mark as Done','Reschedule','Company Info','Add a note…','Attach documents','Note saved.'];
  for(const locale of ['zh-CN','ms']){
    api.setPlatformLocaleForTest(locale);
    for(const key of keys)assert.notEqual(api.platformText(key),key,`${locale} is missing a translation for "${key}"`);
  }
  api.setPlatformLocaleForTest('en');
});
