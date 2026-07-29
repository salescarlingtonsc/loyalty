import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root=new URL('../..',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');

async function loadCrmUtils(){
  const source=await read('app/platform-crm-utils.js');
  const context={URL,Object};
  context.globalThis=context;
  vm.runInNewContext(source,context,{filename:'platform-crm-utils.js'});
  return context.NestlyPlatformCRMUtils;
}

test('enterprise import parser preserves quoted rows and detects CSV or TSV',async()=>{
  const CRM=await loadCrmUtils();
  const csv=CRM.parseDelimited('Company Name,Notes,Email Address\r\n"Acme, Pte Ltd","Line 1\nLine 2",HELLO@EXAMPLE.COM\r\n');
  assert.equal(csv.delimiter,',');
  assert.deepEqual(Array.from(csv.headers),['Company Name','Notes','Email Address']);
  assert.equal(csv.rows[0].values['Company Name'],'Acme, Pte Ltd');
  assert.equal(csv.rows[0].values.Notes,'Line 1\nLine 2');
  const tsv=CRM.parseDelimited('Firm\tMobile\nExample\t81234567\n');
  assert.equal(tsv.delimiter,'\t');
  assert.equal(tsv.rows[0].values.Mobile,'81234567');
});

test('enterprise mapping handles synonyms, conflicts, custom fields and duplicate rows',async()=>{
  const CRM=await loadCrmUtils();
  const mapping=CRM.suggestMapping(['Firm','UEN','E-mail','Extra Value','812 Flag']);
  assert.equal(mapping.Firm,'company_name');
  assert.equal(mapping.UEN,'registration_number');
  assert.equal(mapping['E-mail'],'email');
  assert.match(mapping['Extra Value'],/^custom:[a-z][a-z0-9_]{1,62}$/);
  assert.match(mapping['812 Flag'],/^custom:[a-z][a-z0-9_]{1,62}$/);
  assert.deepEqual(
    JSON.parse(JSON.stringify(CRM.mappingConflicts({A:'company_name',B:'company_name'}))),
    [{destination:'company_name',headers:['A','B']}]
  );
  const rows=CRM.mapImportRows([
    {row_number:2,values:{Firm:'Acme',UEN:'202600001A','E-mail':'A@EXAMPLE.COM','Extra Value':'Gold'}},
    {row_number:3,values:{Firm:'Acme',UEN:'202600001A','E-mail':'b@example.com','Extra Value':'Silver'}}
  ],mapping);
  assert.equal(rows[0].email,'a@example.com');
  assert.equal(rows[0].custom_fields.extra_value,'Gold');
  const analysed=CRM.analyseImportRows(rows);
  assert.equal(analysed[1].status,'invalid');
  assert.match(analysed[1].errors.join(' '),/duplicate of source row 2/i);
});

test('v86 drawer binds typed firm CRM and governed stage contracts',async()=>{
  const source=await read('app/platform-console.js');
  for(const rpc of [
    'platform_get_prospect_detail_v86','platform_list_prospect_audit_v86',
    'platform_record_company_profile_v86','platform_upsert_prospect_contact_v86',
    'platform_record_qualification_v86','platform_record_activity_detail_v86',
    'platform_record_commercial_detail_v86','platform_record_conversion_configuration_v86',
    'platform_refresh_prospect_quality_v86','platform_move_prospect_stage_v86'
  ])assert.match(source,new RegExp(rpc));
  assert.match(source,/p_expected_version:prospectVersion\(prospect\)/);
  assert.match(source,/p_idempotency_key:idempotencyKey\(\)/);
  assert.doesNotMatch(source,/platform_move_prospect_stage_v76/);
  for(const section of [
    'Company identity and operating profile','Contacts and buying committee',
    'Qualification and discovery','Activities and timeline','Commercial terms',
    'Conversion and account configuration','Audit and stage history'
  ])assert.match(source,new RegExp(section));
});

test('all seventeen pipeline stages have visible gates and system stages stay managed',async()=>{
  const source=await read('app/platform-console.js');
  const stages=[
    'new_lead','appt_set','npu_1','npu_2','npu_3','npu_4','npu_5','npu_6',
    'call_back','reschedule','meeting_sent','pending_decision','client',
    'account_created','onboarding','activated','lost'
  ];
  for(const stage of stages)assert.match(source,new RegExp(`${stage}:|\\['${stage}'`));
  assert.match(source,/stageGateDefinitions/);
  assert.match(source,/This stage is controlled by account conversion and onboarding evidence/i);
  assert.match(source,/Next attempt or terminal disposition/);
  assert.match(source,/Accepted product, seats, billing cycle, value and currency/);
});

test('import preview, explicit decisions, audit-preserving reversal and error export are wired',async()=>{
  const source=await read('app/platform-console.js');
  for(const rpc of [
    'platform_analyse_prospect_import_v86','platform_get_import_errors_v86',
    'platform_decide_import_row_v86','platform_commit_prospect_import_v86',
    'platform_reverse_prospect_import_v86'
  ])assert.match(source,new RegExp(rpc));
  assert.match(source,/custom__\$\{destination\.slice/);
  assert.match(source,/data-import-confirm/);
  assert.match(source,/candidate_prospect_id/);
  assert.match(source,/Download error CSV/);
  assert.match(source,/immutable import provenance retained/i);
  assert.match(source,/Audit provenance was preserved/i);
});

test('private documents use short-lived signer exchange, signed storage upload and popup fallback',async()=>{
  const source=await read('app/platform-console.js');
  for(const rpc of [
    'platform_request_prospect_document_upload_v86',
    'platform_request_prospect_document_read_v86'
  ])assert.match(source,new RegExp(rpc));
  assert.match(source,/functions\.invoke\('sme-document-signer'/);
  assert.match(source,/action:'exchange',request_id:reservation\.request_id,exchange_token:reservation\.exchange_token/);
  assert.match(source,/uploadToSignedUrl/);
  assert.match(source,/action:'finalize',request_id:reservation\.request_id/);
  assert.match(source,/reservation_expires_at/);
  assert.match(source,/maximum 25 MB/);
  assert.match(source,/Your browser blocked the automatic tab/);
  assert.match(source,/rel="noopener noreferrer"/);
});

test('enterprise reports and billing expose cross-domain exports and reconciliation exceptions',async()=>{
  const source=await read('app/platform-console.js');
  assert.match(source,/activeKey==='reports'.*renderPlatformReports/);
  for(const rpc of [
    'platform_generate_improvement_report_v82','platform_get_sme_analytics_v86',
    'platform_get_billing_v89',
    'platform_get_automation_billing_v89','platform_get_automation_reconciliation_v89'
  ])assert.match(source,new RegExp(rpc));
  assert.doesNotMatch(source,/get_billing_reconciliation_v77/);
  assert.doesNotMatch(source,/platform_get_billing_reconciliation_v89/);
  assert.match(source,/sectionAccess\.onboarding[\s\S]*platform_get_sme_analytics_v86[\s\S]*Promise\.resolve\(null\)/);
  assert.match(source,/sectionAccess\.billing\?rpc\(sb,'platform_get_billing_v89'[\s\S]*Promise\.resolve\(null\)/);
  assert.match(source,/SME acquisition and onboarding omitted/);
  assert.match(source,/Subscription billing omitted/);
  assert.match(source,/Enterprise performance report/);
  assert.match(source,/Download complete CSV/);
  assert.match(source,/Billing exception queue/);
  assert.match(source,/Reconciliation history/);
  assert.match(source,/GST remains visible and is not treated as commissionable revenue/);
});

test('mobile platform navigation exposes four primary routes and an accessible More menu',async()=>{
  const [source,styles]=await Promise.all([
    read('app/platform-console.js'),read('app/platform-console.css')
  ]);
  assert.match(source,/\['overview','onboarding','firms','reports'\]/);
  assert.match(source,/class="platform-mobile-more"/);
  assert.match(source,/role="list"/);
  assert.match(styles,/grid-template-columns:repeat\(var\(--platform-mobile-count,5\),minmax\(0,1fr\)\)/);
  assert.match(styles,/\.platform-mobile-more-menu/);
  assert.match(styles,/width:44px;min-width:44px;height:44px/);
  assert.doesNotMatch(styles,/\.platform-mobile-nav\{[^}]*overflow-x:auto/);
});

test('commission policy keeps anniversary bonus editable',async()=>{
  const source=await read('app/platform-console.js');
  assert.match(source,/name="anniversary_bonus_percent"/);
  assert.match(source,/anniversary_bonus_bps:percentInputToBasisPoints\(form\.get\('anniversary_bonus_percent'\)\)/);
  assert.match(source,/p_anniversary_bonus_bps:values\.anniversary_bonus_bps/);
  assert.match(source,/12-month service bonus/);
});
