import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

function sourceSection(source,start,end){
  const from=source.indexOf(start);
  assert.notEqual(from,-1,`missing source boundary: ${start}`);
  const to=source.indexOf(end,from+start.length);
  assert.notEqual(to,-1,`missing source boundary: ${end}`);
  return source.slice(from,to);
}

async function loadConsole(){
  const source=await read('app/platform-console.js');
  const context={Object,URL,URLSearchParams,Intl,Date,Map,Set,Proxy,Reflect};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

const daysAgo=count=>new Date(Date.now()-(count*86_400_000)).toISOString();

function realisticTodayFixture(){
  return {
    applications:[{
      id:'application-spa-001',
      business_name:'Serene Spa Pte Ltd',
      contact_name:'Alicia Tan',
      submitted_at:daysAgo(2),
      status:'submitted'
    }],
    prospects:[{
      prospect_id:'prospect-spa-001',
      company_name:'Radiance Facial Studio',
      stage:'onboarding',
      onboarding_status:'blocked',
      stage_entered_at:daysAgo(9),
      assigned_consultant_name:'Consultant Mei',
      overdue_task_count:2
    },{
      prospect_id:'prospect-healthy-001',
      company_name:'Healthy Salon',
      stage:'activated',
      stage_entered_at:daysAgo(1),
      assigned_consultant_name:'Consultant Mei',
      next_action_at:new Date(Date.now()+86_400_000).toISOString()
    }],
    billing:[{
      business_id:'business-spa-001',
      business_name:'Glow Wellness',
      payment_status:'past_due',
      days_past_due:6,
      due_at:daysAgo(6),
      account_manager_name:'Consultant Arun'
    },{
      business_id:'business-paid-001',
      business_name:'Paid Salon',
      payment_status:'active',
      next_payment_at:new Date(Date.now()+86_400_000).toISOString(),
      account_manager_name:'Consultant Arun'
    }],
    commissions:[{
      accrual_id:'commission-001',
      consultant_name:'Senior Consultant Nora',
      status:'payable',
      due_at:daysAgo(1),
      owner_name:'Finance team'
    },{
      accrual_id:'commission-paid-001',
      consultant_name:'Junior Consultant Kai',
      status:'paid',
      owner_name:'Finance team'
    }],
    incidents:[{
      run_id:'reconciliation-001',
      provider_object_id:'stored-value-ledger-001',
      object_type:'stored_value',
      status:'failed',
      created_at:daysAgo(1)
    },{
      run_id:'reconciliation-healthy-001',
      provider_object_id:'stored-value-ledger-healthy',
      object_type:'stored_value',
      status:'healthy',
      created_at:daysAgo(1)
    }]
  };
}

test('Today is the first task destination while all authorised deep links remain available',async()=>{
  const Console=await loadConsole();
  const access=Console.normalizePlatformAccess({
    role:'super_admin',scope:'all',module_perms:{}
  });
  const allowed=Console.visibleRoutes(access);
  const groups=Console.platformNavigationGroups(allowed);

  assert.equal(groups[0].key,'overview');
  assert.equal(groups[0].label,'Today');
  assert.deepEqual(Array.from(groups[0].routes,route=>route.key),['overview']);
  assert.equal(groups.filter(group=>!group.secondary).length,5);
  assert.deepEqual(
    Array.from(allowed,route=>route.key),
    ['overview','onboarding','firms','reports','billing','pnl','commissions','sectors','automation','access'],
    'task-first navigation must not delete an authorised route or its deep link'
  );
});

test('realistic Today data becomes one decision-ready row per actionable record',async()=>{
  const Console=await loadConsole();
  const queue=Console.buildPlatformTodayQueue(realisticTodayFixture());

  assert.deepEqual(
    Array.from(queue,item=>item.type).sort(),
    ['application','billing','commission','incident','prospect'],
    'submitted applications, blocked onboarding, overdue billing, payable commissions and system incidents all belong in Today'
  );
  assert.ok(!queue.some(item=>/Healthy Salon|Paid Salon|Junior Consultant Kai|stored-value-ledger-healthy/.test(item.name)),
    'healthy, paid and completed records are not presented as work');

  for(const item of queue){
    assert.match(item.id,/\S/);
    assert.match(item.name,/\S/);
    assert.match(item.reason,/\S/);
    assert.match(item.status,/\S/);
    assert.match(item.age,/\S/);
    assert.match(item.sla,/\S/);
    assert.match(item.owner,/\S/);
    assert.equal(typeof item.priority,'number');
    assert.deepEqual(Object.keys(item.primaryAction).sort(),['href','label']);
    assert.match(item.primaryAction.label,/\S/);
    assert.match(item.primaryAction.href,/^#\/platform\/(?:onboarding|billing|commissions|automation)/);
  }
  assert.deepEqual(
    Array.from(queue,item=>item.priority),
    Array.from(queue,item=>item.priority).sort((left,right)=>left-right),
    'Today is ordered by decision urgency rather than by database arrival order'
  );
});

test('Today renderer exposes visible decision context and exactly one primary action per row',async()=>{
  const Console=await loadConsole();
  const queue=Console.buildPlatformTodayQueue(realisticTodayFixture());
  const CUI={
    emptyState:({title,body})=>`<div data-empty-state><b>${title}</b><p>${body}</p></div>`
  };
  const html=Console.platformTodayQueueHtml(queue,CUI,{
    title:'Today',description:'Work the highest-priority item first.'
  });
  const rows=html.match(/<article class="platform-today-item"[\s\S]*?<\/article>/g)||[];

  assert.match(html,/data-platform-today-queue/);
  assert.equal(rows.length,queue.length);
  for(const row of rows){
    for(const selector of [
      'data-today-reason','data-today-status','data-today-age',
      'data-today-sla','data-today-owner'
    ])assert.match(row,new RegExp(selector),`${selector} must be visible in every task row`);
    assert.equal((row.match(/data-today-primary-action/g)||[]).length,1,
      'each task row has one unambiguous next action');
  }

  const emptyHtml=Console.platformTodayQueueHtml([],CUI);
  assert.match(emptyHtml,/You are caught up/);
  assert.doesNotMatch(emptyHtml,/data-platform-today-item/);
});

test('the super-admin default route actually renders Today rather than the legacy roster',async()=>{
  const source=await read('app/platform-console.js');
  const router=sourceSection(source,'const useScopedV89=','installReadOnlyGuard(context);');

  assert.match(router,/access\.role==='super_admin'\s*\?loadOverview\(context\)/,
    'the Today helper is not sufficient unless the default super-admin route invokes it');
  assert.doesNotMatch(router,/access\.role==='super_admin'\s*\?loadRoster\(\{/,
    'the legacy roster must not bypass Today');
});

test('sales staff permissions default to their own scoped Today surface',async()=>{
  const Console=await loadConsole();
  assert.equal(typeof Console.normalizePlatformGrantPermissions,'function',
    'role defaults must be a reusable policy, not duplicated event-handler mutations');

  const permissions=Console.normalizePlatformGrantPermissions('sales_staff',{
    overview:'off',billing:'rw',automation:'rw'
  });
  assert.deepEqual(
    {...permissions},
    {overview:'r',onboarding:'rw',firms:'r',reports:'r'}
  );
  const access=Console.normalizePlatformAccess({
    role:'sales_staff',
    scope:'own_created_or_assigned',
    module_perms:permissions
  });
  assert.equal(access.scope,'own_created_or_assigned');
  assert.deepEqual(
    Array.from(Console.visibleRoutes(access),route=>route.key),
    ['overview','onboarding','firms','reports']
  );

  const CUI={emptyState:({title,body})=>`<div><b>${title}</b><p>${body}</p></div>`};
  const scopedHtml=Console.platformTodayQueueHtml(
    Console.buildPlatformTodayQueue(realisticTodayFixture()),
    CUI,
    {sales:true,scope:access.scope,title:'Your work today'}
  );
  assert.match(scopedHtml,/data-platform-sales-today/);
  assert.match(scopedHtml,/data-platform-scope="own_created_or_assigned"/);
});

test('application gate uses exact decisions and explains consequences before mutation',async()=>{
  const source=await read('app/platform-console.js');
  const queue=sourceSection(
    source,
    'function businessApplicationQueueHtml',
    'function wireBusinessApplicationQueue'
  );
  const decision=sourceSection(
    source,
    'function businessApplicationDecisionModal',
    'function wireOnboarding'
  );

  assert.match(queue,/data-application-decision="approve"[^>]*>[\s\S]*Approve application/);
  assert.match(queue,/data-application-decision="reject"[^>]*>[\s\S]*Reject application/);
  assert.doesNotMatch(queue,/>[\s\S]*Approve<\/button>/,
    'the business gate never uses the ambiguous bare label “Approve”');
  assert.doesNotMatch(queue,/>[\s\S]*Reject<\/button>/,
    'the business gate never uses the ambiguous bare label “Reject”');

  assert.match(decision,/data-application-consequence/);
  assert.match(decision,/secure owner invitation/i);
  assert.match(decision,/does not activate the firm/i,
    'approval copy distinguishes application approval from firm activation');
  assert.match(decision,/owner account creation/i);
  assert.match(decision,/remain blocked|keeps?[^.]*blocked|blocks?/i,
    'rejection copy states that owner creation/activation stays blocked');
  assert.match(decision,/submitLabel:isApproval\?'Approve application':'Reject application'/);
});

test('Firms delegates report generation to Reports and round-trips the selected scope',async()=>{
  const Console=await loadConsole();
  const filters={
    search:'wellness east',
    sector:'facial',
    businesses:['business-001','business-002'],
    branch:'branch-003',
    from:'2026-01-01',
    to:'2026-07-29'
  };
  const hash=Console.enterpriseReportHash(filters);
  const restored=Console.enterpriseReportFiltersFromHash(hash);

  assert.match(hash,/^#\/platform\/reports\?/);
  assert.deepEqual({...restored,businesses:Array.from(restored.businesses)},filters,
    'report scope survives Firms → Reports navigation without asking the user to re-enter it');

  const source=await read('app/platform-console.js');
  const enterprise=sourceSection(source,'function enterpriseHtml','function enterpriseDetailTable');
  assert.doesNotMatch(enterprise,/enterpriseGenerateReport|enterpriseReportHost|Generate detailed report/);
  assert.match(enterprise,/data-open-canonical-reports/);
  assert.doesNotMatch(source,/querySelector\(['"]#enterpriseGenerateReport['"]\)/,
    'no obsolete inline report event handler remains');
});

test('task-first desktop groups remain permission-filtered for sales staff',async()=>{
  const Console=await loadConsole();
  const access=Console.normalizePlatformAccess({
    role:'sales_staff',
    scope:'own_created_or_assigned',
    module_perms:{overview:'r',onboarding:'rw',firms:'r',reports:'r'}
  });
  const groups=Console.platformNavigationGroups(Console.visibleRoutes(access));
  assert.deepEqual(
    Array.from(groups,group=>({
      key:group.key,
      label:group.label,
      routes:Array.from(group.routes,route=>route.key)
    })),
    [
      {key:'overview',label:'Today',routes:['overview']},
      {key:'firms',label:'Firms',routes:['firms','onboarding']},
      {key:'reports',label:'Reports',routes:['reports']}
    ]
  );
  assert.ok(groups.every(group=>!group.secondary),
    'sales staff never receive platform-control disclosure groups');
});

test('sector defaults and firm or branch exceptions have one canonical home each',async()=>{
  const source=await read('app/platform-console.js');
  const sectors=sourceSection(source,'async function renderSectors','function modulePickerHtml');
  const governance=sourceSection(source,'function firmGovernanceHtml','function businessApprovalModal');

  assert.doesNotMatch(sectors,/Firm entitlements|platform_list_sector_firms_v89|data-override-firm/,
    'Sector modules must not duplicate firm assignment or override controls');
  assert.match(sectors,/Sector defaults are managed here/);
  assert.match(sectors,/open the firm in Firms and use Firm module policy/);

  assert.match(governance,/data-change-sector/);
  assert.match(governance,/data-module-control/);
  assert.match(governance,/data-manage-branch/);
  assert.match(governance,/Branch overrides take priority over firm and sector settings/);
});

test('Finance resolves payment exceptions while System health owns technical reconciliation history',async()=>{
  const source=await read('app/platform-console.js');
  const billing=sourceSection(source,'async function renderBilling','function billingPriceModal');
  const health=sourceSection(source,'async function renderAutomation','function disconnectedRouteHtml');
  const Console=await loadConsole();
  const superAdmin=Console.normalizePlatformAccess({role:'super_admin',scope:'all',module_perms:{}});
  const healthRoute=Console.visibleRoutes(superAdmin).find(route=>route.key==='automation');

  assert.equal(healthRoute.label,'System health');
  assert.doesNotMatch(billing,/Reconciliation history|Latest provider reconciliation|platform_get_billing_reconciliation_v89/);
  assert.match(billing,/Billing exception queue/);
  assert.match(billing,/Technical reconciliation history is in System health/);

  assert.match(health,/title:'System health'/);
  assert.match(health,/Reconciliation history/);
  assert.match(health,/Resolve affected firm payments in Finance/);
});

test('scoped Firms has one Firm 360 entry and trusts server assignment checks for direct links',async()=>{
  const Console=await loadConsole();
  const businessId='f89b9603-6f0d-4a6b-940a-1682c75df2d9';
  const hash=Console.scopedFirmHash(businessId);

  assert.equal(hash,`#/platform/firms?firm=${businessId}`);
  assert.equal(Console.scopedFirmIdFromHash(hash),businessId);

  const source=await read('app/platform-console.js');
  const table=sourceSection(source,'function scopedFirmTable','async function openScopedFirm');
  const drawer=sourceSection(source,'async function openScopedFirm','async function renderScopedFirms');
  const renderer=sourceSection(source,'async function renderScopedFirms','function scopedActivityModal');

  assert.match(table,/data-scoped-firm/);
  assert.equal((table.match(/data-scoped-firm/g)||[]).length,1,
    'each converted firm row has one unambiguous Firm 360 entry');
  assert.match(drawer,/platform_get_assigned_firm_report_v94/);
  assert.match(drawer,/platform_get_catalogue_affinity_v94/);
  assert.match(drawer,/platform_get_consultative_recommendations_v94/);
  assert.doesNotMatch(drawer,/platform_get_enterprise_hierarchy_v82|platform_list_enterprise_customers_v82/,
    'sales and admin Firm 360 must never fall through to super-admin data readers');
  assert.match(drawer,/Firm unavailable in your access scope/);
  assert.match(drawer,/No firm or customer information was returned/);
  assert.match(renderer,/scopedDirectoryStateFromHash\(context\.hash\)/);
  assert.match(renderer,/requestedFirm=route\.firm/);
  assert.match(renderer,/\|\|\{business_id:requestedFirm\}/,
    'a direct URL is sent to the server-authoritative report boundary even when absent from the visible list');
});

test('Firms and Reports load one bounded page before an explicit load-more action',async()=>{
  const Console=await loadConsole();
  const calls=[];
  const sb={rpc:async(name,args)=>{
    calls.push({name,args});
    if(name==='platform_get_enterprise_hierarchy_v82')return{data:{
      snapshot_at:'2026-07-29T10:00:00Z',firms:[],
      pagination:{total_firms:200,returned_firms:0,has_more:true,next_cursor:{
        created_at:'2026-01-01T00:00:00Z',business_id:'00000000-0000-0000-0000-000000000001'
      }}
    }};
    return{data:{snapshot_at:'2026-07-29T10:00:00Z',items:[],next_cursor:null}};
  }};
  const filters={
    search:'',sector:'',businesses:[],branch:'',
    from:'2026-01-01',to:'2026-07-29'
  };

  await Console.fetchEnterpriseFirmPage(sb,filters);
  await Console.fetchFirmDirectoryPageV88(sb,filters);
  assert.equal(calls.length,2);
  assert.equal(calls[0].args.p_limit,50);
  assert.equal(calls[1].args.p_limit,50);
  assert.equal(calls[0].args.p_after_business,null);
  assert.equal(calls[1].args.p_after_id,null);

  const source=await read('app/platform-console.js');
  const firms=sourceSection(source,'async function renderEnterprise','function reportsPageHtml');
  const reports=sourceSection(source,'async function renderPlatformReports','function prospectCompany');
  const onboarding=sourceSection(source,'async function renderOnboarding','function businessApplicationQueueHtml');
  assert.match(firms,/data-enterprise-load-more/);
  assert.match(firms,/fetchEnterpriseFirmPage/);
  assert.doesNotMatch(firms,/do\s*\{|while\s*\(\s*cursor\s*\)|p_limit:500/);
  assert.match(reports,/fetchEnterpriseFirmPage\(sb,catalogueFilters,\{limit:50\}\)/);
  assert.match(reports,/platformReportFirmLoadMore/);
  assert.match(reports,/\{snapshot:state\.snapshot,cursor:state\.cursor,limit:50\}/);
  assert.doesNotMatch(reports,/fetchEnterpriseFirmPages/);
  assert.match(onboarding,/fetchFirmDirectoryPageV88/);
  assert.doesNotMatch(onboarding,/fetchFirmDirectoryV88/);
});

test('firm filters, branch scope and dates survive refresh through the canonical URL',async()=>{
  const Console=await loadConsole();
  const filters={
    search:'Radiance owner 8123',
    sector:'facial',
    businesses:['business-spa-001'],
    branch:'branch-orchard-001',
    from:'2026-04-01',
    to:'2026-07-29'
  };
  const hash=Console.enterpriseFirmHash(filters);
  const restored=Console.enterpriseReportFiltersFromHash(hash);

  assert.match(hash,/^#\/platform\/firms\?/);
  assert.deepEqual({...restored,businesses:Array.from(restored.businesses)},filters);

  const source=await read('app/platform-console.js');
  const renderer=sourceSection(source,'async function renderEnterprise','function reportsPageHtml');
  const router=sourceSection(source,'const useScopedV89=','installReadOnlyGuard(context);');
  assert.match(renderer,/history\.replaceState\(null,'',nextHash\)/);
  assert.match(renderer,/enterpriseFirmHash\(next\)/);
  assert.match(router,/renderEnterprise\(\s*context,enterpriseReportFiltersFromHash\(hash\)\s*\)/);
});

test('money and percentage forms use human units while preserving exact database integers',async()=>{
  const Console=await loadConsole();

  assert.equal(Console.moneyInputToCents('300'),30000);
  assert.equal(Console.moneyInputToCents('300.05'),30005);
  assert.equal(Console.centsToMoneyInput(30005),'300.05');
  assert.equal(Console.percentInputToBasisPoints('15'),1500);
  assert.equal(Console.percentInputToBasisPoints('5.25'),525);
  assert.equal(Console.basisPointsToPercentInput(525),'5.25');
  assert.throws(()=>Console.moneyInputToCents('3.009'));
  assert.throws(()=>Console.percentInputToBasisPoints('100.01'));
});

test('normal Finance workflows show SGD, percentages, names and firms instead of database fields',async()=>{
  const source=await read('app/platform-console.js');
  const billing=sourceSection(source,'function billingPriceModal','async function openBillingDetail');
  const commission=sourceSection(source,'async function renderCommission','function forfeitCommissionModal');

  assert.match(billing,/Monthly is fixed at SGD 149/);
  assert.match(billing,/Annual is fixed at SGD 1,188/);
  assert.match(billing,/Stripe \+1,000-customer price ID/);
  assert.match(billing,/Advanced provider mapping/);
  assert.doesNotMatch(billing,/base_amount|seat_amount|included_seats|moneyInputToCents/);
  assert.doesNotMatch(billing,/label:'Base amount \(cents\)'|label:'Per-seat amount \(cents\)'|Per-seat charge/);

  assert.match(commission,/Year-one base rate \(%\)/);
  assert.match(commission,/12-month service bonus \(%\)/);
  assert.match(commission,/Renewal rate \(%\)/);
  assert.match(commission,/Paid amount \(SGD\)/);
  assert.match(commission,/Payment amount \(SGD\)/);
  assert.match(commission,/label:'Consultant',control:'select'/);
  assert.match(commission,/label:'Firm',control:'select'/);
  assert.match(commission,/label:'Approved commission',control:'select'/);
  assert.doesNotMatch(commission,/label:'(?:Consultant|Prospect|Business) ID'/);
  assert.doesNotMatch(commission,/label:'(?:Amount|Paid amount) \(integer cents\)'/);
  assert.doesNotMatch(commission,/label:'[^']+ \(basis points\)'/);
});

test('onboarding filters, sort and the open firm survive refresh through one canonical URL',async()=>{
  const Console=await loadConsole();
  const filters={
    search:'Radiance Spa',
    lane:'decision',
    attention:'warning',
    consultant:'consultant-mei',
    stage:'pending_decision',
    source:'website',
    region:'central',
    segment:'facial',
    priority:'high',
    qualification:'qualified',
    nextAction:'next_7_days',
    health:'at_risk',
    sort:'priority'
  };
  const hash=Console.onboardingHash(filters,{prospect:'prospect-spa-001'});
  const restored=Console.onboardingStateFromHash(hash);

  assert.match(hash,/^#\/platform\/onboarding\?/);
  assert.deepEqual({...restored.filters},filters);
  assert.equal(restored.prospect,'prospect-spa-001');

  const source=await read('app/platform-console.js');
  const renderer=sourceSection(source,'async function renderOnboarding','function businessApplicationQueueHtml');
  const wiring=sourceSection(source,'function wireOnboarding','function newProspectModal');
  const detail=sourceSection(source,'async function openProspectDetail','async function loadProspectDetail');
  const router=sourceSection(source,'const useScopedV89=','installReadOnlyGuard(context);');
  assert.match(renderer,/onboardingStateFromHash\(context\.hash\)\.prospect/);
  assert.match(renderer,/openProspectDetail\(requestedItem/);
  assert.match(wiring,/replaceOnboardingState\(context,next\)/);
  assert.match(wiring,/prospect:item\.id\|\|item\.prospect_id/);
  assert.match(detail,/context\.prospectCloseHash/);
  assert.match(router,/renderOnboarding\(\s*context,onboardingStateFromHash\(hash\)\.filters\s*\)/);
});

test('Firm 360 keeps only frequent actions visible and moves specialist actions behind one disclosure',async()=>{
  const source=await read('app/platform-console.js');
  const detail=sourceSection(source,'function prospectDetailHtml','function wireProspectDetail');
  const shortcuts=sourceSection(
    detail,
    '<div class="platform-actions platform-detail-shortcuts"',
    '<section class="card platform-detail-section" id="detail-overview">'
  );

  assert.match(shortcuts,/pt\("Call"\)/);
  assert.match(shortcuts,/pt\("WhatsApp"\)/);
  assert.match(shortcuts,/data-add-note/);
  assert.match(shortcuts,/platform-action-disclosure/);
  assert.match(shortcuts,/More actions/);
  for(const specialist of [
    'data-edit-prospect','data-assign-prospect','data-add-task',
    'data-upload-document','data-add-npu'
  ]){
    assert.match(shortcuts,new RegExp(specialist));
    assert.ok(
      shortcuts.indexOf(specialist)>shortcuts.indexOf('platform-action-disclosure-menu'),
      `${specialist} belongs in More actions, not the primary toolbar`
    );
  }
  assert.equal((shortcuts.match(/platform-action-disclosure-menu/g)||[]).length,1);
});

test('firm and branch module access is managed in one plain-language grouped workspace',async()=>{
  const source=await read('app/platform-console.js');
  const modal=sourceSection(source,'function moduleControlModal','function openEnterpriseFirm');
  const effectiveRows=sourceSection(source,'function moduleControlRows','function firmGovernanceHtml');
  const governance=sourceSection(source,'function firmGovernanceHtml','function businessApprovalModal');
  const sectorPicker=sourceSection(source,'function modulePickerHtml','function sectorBundleReviewModal');

  assert.match(modal,/Manage firm modules/);
  assert.match(modal,/Manage branch modules/);
  assert.match(modal,/Reset all to sector defaults/);
  assert.match(modal,/Reset all to firm settings/);
  assert.match(modal,/data-module-mode/);
  assert.match(modal,/Save module access/);
  assert.match(modal,/platform_set_module_overrides_v105/);
  assert.match(modal,/p_changes:changes/);
  assert.doesNotMatch(modal,/platform_set_module_override_v94/);
  assert.doesNotMatch(modal,/for\(const change of changes\)/);
  assert.doesNotMatch(modal,/Comma-separated module keys/);
  assert.doesNotMatch(modal,/label:'Module'/);
  assert.doesNotMatch(sectorPicker,/<small>\$\{escapeHtml\(module\.key\)\}/);
  assert.match(sectorPicker,/module\.description/);
  assert.doesNotMatch(effectiveRows,/data-module-control/,
    'the effective-state table must not repeat one Edit button for every module');
  assert.equal((governance.match(/data-module-control/g)||[]).length,1,
    'Firm 360 exposes one bulk module-management action');
  assert.match(governance,/Manage firm modules/);
});

test('Today and Onboarding avoid unbounded CRM reads and expose deliberate pagination',async()=>{
  const source=await read('app/platform-console.js');
  const today=sourceSection(source,'async function loadOverview','function accessPermissionRows');
  const onboarding=sourceSection(source,'async function renderOnboarding','function businessApplicationQueueHtml');
  const onboardingHtml=sourceSection(source,'function onboardingHtml','function defaultOnboardingFilters');
  const wiring=sourceSection(source,'function wireOnboarding','function newProspectModal');

  assert.doesNotMatch(today,/platform_get_sme_board_v76/,
    'Today must not download the complete CRM board just to build its action queue');
  assert.match(today,/fetchAllFirmAttentionV88[\s\S]*limit:250/);
  assert.match(source,/async function fetchAllFirmAttentionV88[\s\S]*platform_list_firm_attention_v88/);
  assert.match(today,/fetchFirmDirectoryPageV88[\s\S]*limit:50/);
  assert.doesNotMatch(onboarding,/platform_get_sme_board_v76/,
    'Onboarding must not download every stage and every prospect before first paint');
  assert.match(onboarding,/fetchFirmDirectoryPageV88[\s\S]*limit:50/);
  assert.match(onboarding,/p_limit:50/);
  assert.match(onboardingHtml,/platformOnboardingLoadMore/);
  assert.match(onboardingHtml,/Load 50 more firms/);
  assert.match(wiring,/onboardingLoadMore:true/);
});

test('daily onboarding forms use consultant names, SGD and percentages instead of database units or IDs',async()=>{
  const source=await read('app/platform-console.js');
  const newProspect=sourceSection(source,'async function newProspectModal','function prospectImportModal');
  const qualification=sourceSection(source,'function qualificationModal','function commercialDetailModal');
  const commercial=sourceSection(source,'function commercialDetailModal','function conversionConfigurationModal');
  const tasks=sourceSection(source,'async function taskModal','function completeTaskModal');
  const stage=sourceSection(source,'function stageEvidenceFieldSpecs','function stageEvidenceModal');
  const conversion=sourceSection(source,'async function commercialTermsModal','async function performStageMove');

  assert.match(newProspect,/fetchScopedConsultants/);
  assert.match(newProspect,/label:'Sales consultant'/);
  assert.doesNotMatch(newProspect,/Consultant ID/);
  assert.match(tasks,/label:'Assign to'/);
  assert.doesNotMatch(tasks,/Assigned consultant ID/);
  assert.match(qualification,/Expected subscription \(SGD\)/);
  assert.match(qualification,/nullableMoneyInputToCents/);
  assert.doesNotMatch(qualification,/Expected subscription \(cents\)/);
  assert.match(commercial,/Discount \(%\)/);
  assert.match(commercial,/percentInputToBasisPoints/);
  assert.doesNotMatch(commercial,/basis points/);
  assert.doesNotMatch(commercial,/\(cents\)/);
  assert.match(stage,/Proposed value \(SGD\)/);
  assert.match(conversion,/Accepted amount \(SGD\)/);
  assert.match(conversion,/label:'Onboarding owner'/);
  assert.doesNotMatch(conversion,/Onboarding owner ID/);
});
