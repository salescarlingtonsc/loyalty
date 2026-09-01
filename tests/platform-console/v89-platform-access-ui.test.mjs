import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadConsole(){
  const source=await read('app/platform-console.js');
  const context={Object,URL};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-console.js'});
  return context.NestlyPlatformConsole;
}

test('v89 access normalization denies ordinary and malformed identities',async()=>{
  const api=await loadConsole();
  assert.equal(api.normalizePlatformAccess(null),null);
  assert.equal(api.normalizePlatformAccess({}),null);
  assert.equal(api.normalizePlatformAccess({role:'customer',module_perms:{'*':'rw'}}),null);
});

test('super admin sees every module plus grant management with write access',async()=>{
  const api=await loadConsole();
  const access=api.normalizePlatformAccess({
    role:'super_admin',module_perms:{'*':'rw'},scope:'all'
  });
  assert.equal(api.canWriteModule(access,'billing'),true);
  assert.equal(api.canWriteModule(access,'automation'),true);
  assert.deepEqual(
    Array.from(api.visibleRoutes(access),route=>route.key),
    // Operating-system IA pass: demo-requests, customer-lifecycle, billing and
    // companies merged into a sibling route as a tab/mode (see
    // legacyRouteRedirects), so they no longer appear as their own routes.
    ['overview','onboarding','crm','prospecting','firms','reports','marketing','subscription-operations','pnl','commissions','sectors','automation','partners','support','access']
  );
});

test('read-only admin keeps permitted routes but cannot write and off modules disappear',async()=>{
  const api=await loadConsole();
  const access=api.normalizePlatformAccess({
    role:'admin',scope:'all',
    module_perms:{overview:'r',onboarding:'rw',firms:'r',reports:'r'}
  });
  assert.equal(api.modulePermission(access,'overview'),'r');
  assert.equal(api.canWriteModule(access,'overview'),false);
  assert.equal(api.canWriteModule(access,'onboarding'),true);
  assert.equal(api.canAccessModule(access,'billing'),false);
  assert.deepEqual(
    Array.from(api.visibleRoutes(access),route=>route.key),
    ['overview','onboarding','crm','prospecting','firms','reports']
  );
  assert.equal(api.isFullLegacyAdmin(access),false);
  const full=api.normalizePlatformAccess({role:'admin',scope:'all',module_perms:{'*':'rw'}});
  assert.equal(api.isFullLegacyAdmin(full),true);
});

test('Sales A navigation and scope copy expose only scoped CRM and reports',async()=>{
  const api=await loadConsole();
  const access=api.normalizePlatformAccess({
    role:'sales_staff',
    module_perms:{onboarding:'rw',firms:'r',reports:'r'},
    scope:'own_created_or_assigned'
  });
  assert.deepEqual(
    Array.from(api.visibleRoutes(access),route=>route.key),
    ['onboarding','crm','prospecting','firms','reports']
  );
  assert.equal(api.canWriteModule(access,'onboarding'),true);
  assert.equal(api.canWriteModule(access,'firms'),false);
  assert.equal(api.canAccessModule(access,'billing'),false);

  const source=await read('app/platform-console.js');
  assert.match(source,/Only firms you created or are assigned to/);
  assert.match(source,/Other sales staff records are never included/);
});

test('console resolves active access before shell and shows an inactive-role denial state',async()=>{
  const source=await read('app/platform-console.js');
  const accessCall=source.indexOf("platform_list_my_access_v89");
  const shellRender=source.lastIndexOf('root.innerHTML = shellHtml');
  assert.ok(accessCall>0&&accessCall<shellRender);
  assert.match(source,/This account has no active Peekaa platform role/);
  assert.match(source,/allowedRoutes\.find\(route=>route\.key===requestedKey\)\|\|allowedRoutes\[0\]/);
  assert.match(source,/history\.replaceState\(null,'',activeRoute\.hash\)/);
});

test('super-admin grant editor and delegated platform users use scoped v89 CRM plus v94 intelligence contracts',async()=>{
  const source=await read('app/platform-console.js');
  for(const rpc of [
    'platform_list_my_access_v89','platform_list_access_grants_v89',
    'platform_upsert_access_grant_v89','platform_list_my_firms_v105',
    'platform_ingest_lead_v510','platform_transition_lead_v510','platform_get_my_prospect_v89',
    'platform_add_my_prospect_activity_v89','platform_create_my_prospect_task_v89',
    'platform_complete_my_prospect_task_v89',
    'platform_transfer_lead_v510','platform_queue_lead_v510','platform_list_assignment_consultants_v89'
  ])assert.match(source,new RegExp(rpc));
  for(const rpc of [
    'platform_get_assigned_firm_report_v94','platform_get_catalogue_affinity_v94',
    'platform_get_consultative_recommendations_v94'
  ])assert.match(source,new RegExp(rpc));
  assert.match(source,/const selectedUser=String\(form\.get\('user_id'\)\|\|''\)\.trim\(\)/);
  assert.match(source,/p_user:selectedUser/);
  assert.match(source,/p_role:role,p_module_perms:perms,p_active/);
  assert.match(source,/role==='sales_staff'\)return \{[\s\S]*overview:'r',onboarding:'rw',firms:'r'/);
  assert.match(source,/platformModuleKeys\.every\(key=>requested\[key\]==='rw'\)/);
  assert.match(source,/return\{'\*':'rw'\}/);
  assert.match(source,/const useScopedV89=access\.role!=='super_admin'/);
  assert.match(source,/access\.role==='super_admin'[\s\S]*loadRoster[\s\S]*renderScopedOverview/);
  assert.match(source,/id="platformScopedNewProspect"/);
});

test('partially customized admins use server-scoped onboarding, firms and reports with per-module write guards',async()=>{
  const api=await loadConsole();
  const access=api.normalizePlatformAccess({
    role:'admin',scope:'all',
    module_perms:{onboarding:'rw',firms:'r',reports:'rw'}
  });
  assert.deepEqual(
    Array.from(api.visibleRoutes(access),route=>route.key),
    ['onboarding','crm','prospecting','firms','reports']
  );
  assert.equal(api.canWriteModule(access,'onboarding'),true);
  assert.equal(api.canWriteModule(access,'firms'),false);
  assert.equal(api.canWriteModule(access,'reports'),true);
  const source=await read('app/platform-console.js');
  const routing=source.slice(source.indexOf('const useScopedV89='),source.indexOf('installReadOnlyGuard(context);',source.indexOf('const useScopedV89=')));
  assert.match(routing,/const useScopedV89=access\.role!=='super_admin'/);
  assert.match(routing,/useScopedV89&&activeKey==='firms'\)task=renderScopedFirms\(context\)/);
  assert.match(routing,/useScopedV89&&activeKey==='reports'\)task=renderScopedReports\(context\)/);
  assert.match(routing,/useScopedV89&&activeKey==='onboarding'\)task=renderScopedOnboarding\(context\)/);
  assert.match(source,/canWrite:activeKey==='access'\|\|canWriteModule\(access,activeRoute\.moduleKey\|\|activeKey\)/);
  assert.match(source,/if\(context\.canWrite\)return;[\s\S]*stripPlatformWriteControls\(context\.root\)/);
});

test('owner-only onboarding decisions are hidden from delegated admins',async()=>{
  const api=await loadConsole();
  assert.equal(api.superAdminOnly(false,'owner control'),'');
  assert.equal(api.superAdminOnly(true,'owner control'),'owner control');
  const source=await read('app/platform-console.js');
  assert.match(source,/context\.access\?\.role==='super_admin'/);
  assert.match(source,/function onboardingPanelHtml\(payload,error,CUI,isSuperAdmin=false,review=null,reviewError=null\)/);
  assert.match(source,/superAdminOnly\(isSuperAdmin,checklist\.blocked_at[\s\S]*data-onboarding-unblock[\s\S]*data-onboarding-block/);
  assert.match(source,/superAdminOnly\(isSuperAdmin,`<button type="button" class="btn sm" data-onboarding-activate/);
  assert.match(source,/superAdminOnly\(isSuperAdmin&&canWaive,`<button type="button" class="btn ghost sm" data-onboarding-waive/);
  assert.match(source,/superAdminOnly\(isSuperAdmin,item\.status==='blocked'[\s\S]*data-onboarding-item-unblock[\s\S]*data-onboarding-item-block/);
  assert.match(source,/Final waivers, blocking decisions, and firm activation are completed by a super admin/);
});

test('super-admin grant editor resolves a named/email user and never asks for a pasted auth UUID',async()=>{
  const source=await read('app/platform-console.js');
  const editor=source.slice(source.indexOf('function accessGrantModal'),source.indexOf('async function renderPlatformAccess'));
  assert.match(editor,/label:'Find user by email or name'/);
  assert.match(editor,/platform_lookup_access_user_v89',\{p_query:value\}/);
  assert.match(editor,/payload\.status==='matched'&&items\.length===1/);
  assert.match(editor,/payload\.status==='ambiguous'[\s\S]*Choose the correct name and email/);
  assert.match(editor,/Choose the correct user/);
  assert.match(editor,/display_name\|\|'Unnamed user'[\s\S]*item\.email/);
  assert.match(editor,/type="hidden" name="user_id"/);
  assert.doesNotMatch(editor,/label:'User ID'|authenticated user UUID/);

  const api=await loadConsole();
  const delegated=api.normalizePlatformAccess({
    role:'admin',scope:'all',module_perms:{onboarding:'rw'}
  });
  assert.equal(Array.from(api.visibleRoutes(delegated),route=>route.key).includes('access'),false,
    'non-super-admin shells never expose the grant lookup or access editor');
});

test('read-only guard removes mutation controls while preserving scoped report generation',async()=>{
  const source=await read('app/platform-console.js');
  assert.match(source,/function installReadOnlyGuard\(context\)/);
  assert.match(source,/if\(context\.canWrite\)return/);
  assert.match(source,/stripPlatformWriteControls\(context\.root\)/);
  assert.match(source,/platformWriteSelector/);
  assert.match(source,/context\.canWrite\?`<button type="button" class="btn" data-add-note>/);
  assert.match(source,/id="platformScopedReportForm"/);
  const writeSelectors=source.match(/const platformWriteSelector=\[([\s\S]*?)\]\.join\(','\);/)?.[1]||'';
  assert.doesNotMatch(writeSelectors,/platformScopedReportForm/);
});

test('custom admin with onboarding write access gets a named consultant assignment control',async()=>{
  const api=await loadConsole();
  const access=api.normalizePlatformAccess({
    role:'admin',scope:'all',module_perms:{onboarding:'rw',firms:'r'}
  });
  // Owner rule (2026-08-10): only the super admin assigns firms. An admin's
  // Assignment remains owner-only; v510 performs it through the canonical
  // ownership transition instead of the retired direct-assignment RPC.
  assert.equal(api.canAssignScopedProspect({access,canWrite:api.canWriteModule(access,'onboarding')}),false);
  assert.equal(api.canAssignScopedProspect({
    access:api.normalizePlatformAccess({role:'super_admin',scope:'all',module_perms:{'*':'rw'}}),
    canWrite:true}),true);
  assert.deepEqual(
    Array.from(api.scopedConsultantOptions([
      {assigned_consultant_id:'consultant-b',consultant_name:'Zoe Tan'},
      {id:'consultant-a',display_name:'Amir Lee',active:true},
      {id:'consultant-x',display_name:'Departed',active:false}
    ]),option=>({...option})),
    [{value:'consultant-a',label:'Amir Lee'},{value:'consultant-b',label:'Zoe Tan'}]
  );
  const source=await read('app/platform-console.js');
  assert.match(source,/canAssignScopedProspect\(context\)\?`<button[^>]*data-scoped-assign/);
  assert.match(source,/id:'scopedAssignmentConsultant',label:'Sales consultant',control:'select'/);
  assert.match(source,/platform_transfer_lead_v510',\{\.\.\.common,p_consultant:consultant\}/);
  assert.match(source,/platform_list_assignment_consultants_v89/);
  assert.doesNotMatch(source,/scopedAssignmentConsultant',label:'Consultant ID'/);
});

test('read-only admin and sales-scoped users cannot render reassignment controls',async()=>{
  const api=await loadConsole();
  const readOnly=api.normalizePlatformAccess({
    role:'admin',scope:'all',module_perms:{onboarding:'r'}
  });
  const sales=api.normalizePlatformAccess({
    role:'sales_staff',scope:'own_created_or_assigned',
    module_perms:{onboarding:'rw',firms:'r',reports:'r'}
  });
  assert.equal(api.canAssignScopedProspect({access:readOnly,canWrite:false}),false);
  assert.equal(api.canAssignScopedProspect({access:sales,canWrite:true}),false,
    'sales staff cannot broaden their own-created or assigned scope by reassigning CRM records');
  const source=await read('app/platform-console.js');
  const writeSelectors=source.match(/const platformWriteSelector=\[([\s\S]*?)\]\.join\(','\);/)?.[1]||'';
  assert.match(writeSelectors,/\[data-scoped-assign\]/);
});

test('delegated sectors admin edits reusable defaults without loading or duplicating the firm roster',async()=>{
  const api=await loadConsole();
  const access=api.normalizePlatformAccess({
    role:'admin',scope:'all',module_perms:{sectors:'rw'}
  });
  assert.deepEqual(Array.from(api.visibleRoutes(access),route=>route.key),['sectors']);
  assert.equal(api.canWriteModule(access,'sectors'),true);
  const source=await read('app/platform-console.js');
  const sectors=source.slice(
    source.indexOf('async function renderSectors'),
    source.indexOf('function modulePickerHtml')
  );
  assert.match(sectors,/platform_list_sector_entitlements_v75/);
  assert.doesNotMatch(sectors,/platform_list_sector_firms_v89|super_admin_list_businesses/);
  assert.match(sectors,/Sector defaults are managed here/);
  assert.match(sectors,/open the firm in Firms and use Firm module policy/);
});

test('delegated finance and system-health renders keep operational and technical jobs separate',async()=>{
  const source=await read('app/platform-console.js');
  const billing=source.slice(source.indexOf('async function renderBilling'),source.indexOf('async function renderCommission'));
  const commissions=source.slice(source.indexOf('async function renderCommission'),source.indexOf('async function renderAutomation'));
  const automation=source.slice(source.indexOf('async function renderAutomation'),source.indexOf('function disconnectedRouteHtml'));
  assert.match(billing,/platform_get_billing_v125/);
  assert.doesNotMatch(billing,/platform_get_billing_reconciliation_v89|get_platform_billing_v77|get_billing_reconciliation_v77/);
  assert.match(billing,/Technical reconciliation history is in System health/);
  assert.match(commissions,/platform_list_commission_consultants_v89/);
  assert.match(commissions,/platform_upsert_commission_consultant_v89/);
  assert.doesNotMatch(commissions,/platform_list_consultants_v75|platform_upsert_consultant_v75/);
  assert.match(automation,/platform_get_automation_billing_v89/);
  assert.match(automation,/platform_get_automation_reconciliation_v89/);
  assert.doesNotMatch(automation,/get_platform_billing_v77|get_billing_reconciliation_v77/);
});

test('firms-only admin sees enterprise hierarchy without a duplicate report action',async()=>{
  const api=await loadConsole();
  const access=api.normalizePlatformAccess({
    role:'admin',scope:'all',module_perms:{firms:'r'}
  });
  assert.deepEqual(Array.from(api.visibleRoutes(access),route=>route.key),['firms']);
  assert.equal(api.canAccessModule(access,'reports'),false);
  const source=await read('app/platform-console.js');
  const enterprise=source.slice(
    source.indexOf('function enterpriseHtml'),
    source.indexOf('function enterpriseDetailTable')
  );
  assert.match(enterprise,/canGenerateReport\?`<a[^>]*data-open-canonical-reports[^>]*href="\$\{escapeHtml\(canonicalReportHash\)\}"/);
  assert.match(enterprise,/Continue in Reports/);
  assert.match(source,/const canGenerateReport=canAccessModule\(context\.access,'reports'\)/);
  assert.doesNotMatch(enterprise,/enterpriseGenerateReport|Generate report/);
});

test('reports-only admin receives the core report without unauthorized optional RPCs',async()=>{
  const api=await loadConsole();
  const access=api.normalizePlatformAccess({
    role:'admin',scope:'all',module_perms:{reports:'rw'}
  });
  assert.deepEqual(Array.from(api.visibleRoutes(access),route=>route.key),['reports']);
  assert.deepEqual({...api.reportSectionAccess(access)},{onboarding:false,billing:false});
  const source=await read('app/platform-console.js');
  const renderer=source.slice(
    source.indexOf('async function renderCrossDomainReport'),
    source.indexOf('async function renderPlatformReports')
  );
  assert.match(renderer,/sectionAccess\.onboarding[\s\S]*platform_get_sme_analytics_v510[\s\S]*:Promise\.resolve\(null\)/);
  assert.match(renderer,/sectionAccess\.billing\?rpc\(sb,'platform_get_billing_v125'[\s\S]*:Promise\.resolve\(null\)/);
  assert.doesNotMatch(renderer,/platform_get_billing_reconciliation_v89/);
  assert.match(source,/SME acquisition and onboarding omitted/);
  assert.match(source,/Subscription billing omitted/);
  assert.match(source,/No billing or reconciliation reader was called/);
});

test('access controls and mobile navigation meet 44px touch and responsive requirements',async()=>{
  const [source,styles]=await Promise.all([
    read('app/platform-console.js'),read('app/platform-console.css')
  ]);
  assert.match(source,/--platform-mobile-count/);
  assert.match(styles,/repeat\(var\(--platform-mobile-count,5\),minmax\(0,1fr\)\)/);
  assert.match(styles,/\.platform-permission-row select\{width:min\(160px,42%\);min-height:44px\}/);
  assert.match(styles,/\.platform-scoped-search \.btn\{min-height:44px\}/);
  assert.match(styles,/@media\(max-width:760px\)[\s\S]*\.platform-access-list,.platform-scoped-report-options\{grid-template-columns:1fr\}/);
});
