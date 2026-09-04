import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const root = new URL('../..', import.meta.url);
const read = path => readFile(new URL(path, root), 'utf8');

// Mirrors public.sme_pipeline_stages in production. Owner directive replaced
// the old 19-stage vocabulary (inherited from a different business's sales
// motion: six separate "no pick up" stages, site visits, quotations) with a
// canonical sales stages plus preserved legacy/system states. CLOSED_WON is a
// commercial agreement only; payment, workspace creation and activation remain separate.
const officialStages = [
  'new_lead','assigned','contacted','interested','appointment',
  'proposal','closed_won','nurture',
  'client','account_created','onboarding','activated',
  'not_interested','no_response','invalid_contact','closed_business',
  'do_not_contact','lost'
];

test('onboarding exposes canonical CRM stages and maps them into five operational lanes', async () => {
  const source = await read('app/platform-console.js');
  const context = { Object };
  context.globalThis = context;
  vm.runInNewContext(source, context, { filename:'platform-console.js' });

  const stages = Array.from(context.NestlyPlatformConsole.prospectStages, stage => stage.key);
  const lanes = Array.from(context.NestlyPlatformConsole.operationalLanes, lane => ({
    key:lane.key,label:lane.label,stages:Array.from(lane.stages)
  }));
  assert.deepEqual(stages, officialStages);
  assert.doesNotMatch(JSON.stringify(stages), /unmapped/i);
  assert.equal(lanes.length,5);
  assert.deepEqual(lanes.find(lane=>lane.key==='case_won')?.stages,[
    'closed_won','client','account_created','onboarding','activated'
  ]);
  assert.equal(lanes.find(lane=>lane.key==='case_won')?.label,'Case won');
  assert.deepEqual(lanes.flatMap(lane=>lane.stages).sort(),[...officialStages,'unmapped'].sort());
  assert.match(source, /canonicalTransitionTargets/);
  assert.match(source, /evidence-backed onboarding gates and an auditable launch decision/);
  assert.doesNotMatch(source, /Activated remains unavailable until the real launch checklist is connected/);
  assert.doesNotMatch(source, /data-drop-stage/);
  assert.match(source, /data-move-select/);
});

test('platform console wires v75 sector mutations through dry-run previews', async () => {
  const source = await read('app/platform-console.js');
  for (const rpc of [
    'platform_list_sector_entitlements_v75',
    'platform_create_sector_bundle_v75',
    'platform_publish_sector_bundle_v75',
    'platform_assign_business_sector_v75',
    'platform_set_module_overrides_v105'
  ]) assert.match(source, new RegExp(rpc));

  assert.match(source, /platform_create_sector_bundle_v75',args/);
  assert.match(source, /platform_publish_sector_bundle_v75',\{p_bundle_version:createdBundleId,p_dry_run:true\}/);
  assert.match(source, /platform_assign_business_sector_v75',args/);
  assert.match(source, /platform_set_module_overrides_v105',\{/);
  assert.match(source, /previewThenConfirm/);
});

test('pipeline reads preserve compatibility while writes use v510 canonical contracts', async () => {
  const source = await read('app/platform-console.js');
  for (const rpc of [
    'platform_list_firm_onboarding_v88','platform_list_prospects_v76',
    'platform_get_prospect_detail_v76','platform_ingest_lead_v510',
    'platform_update_prospect_v76','platform_transfer_lead_v510','platform_queue_lead_v510',
    'platform_add_prospect_activity_v76','platform_create_prospect_task_v76',
    'platform_complete_prospect_task_v76','platform_transition_lead_v510',
    'platform_stage_prospect_import_v76','platform_commit_prospect_import_v86'
  ]) assert.match(source, new RegExp(rpc));

  assert.match(source, /platform_get_prospect_detail_v76',\{p_prospect:id\}/);
  assert.match(source, /p_company:\{legal_name:/);
  assert.match(source, /p_primary_contact:\{full_name:/);
  assert.match(source, /p_source_system:'platform_console',p_source_name:/);
  assert.match(source, /platform_commit_prospect_import_v86',\{p_batch:batch\}/);
  assert.match(source, /item\.current_stage_key\|\|item\.stage_key/);
  assert.match(source, /item\.legal_name\|\|item\.trading_name/);
  assert.match(source, /item\.primary_contact\?\.full_name/);
  assert.match(source, /item\.data_completeness_percent/);
  assert.match(source, /staged\.valid_rows/);
  assert.match(source, /committed\.imported_rows/);
  assert.match(source, /plan_code:form\.get\('plan_code'\)/);
  assert.match(source, /accepted_value_cents:moneyInputToCents/);
  assert.match(source, /onboarding_owner_consultant_id:form\.get\('onboarding_owner'\)/);
  assert.match(source, /const fields=\{reason_code:form\.get\('reason_code'\),context:/);
  assert.match(source, /p_entry_evidence:options\.entryEvidence\|\|\{\}/);
});

test('billing, automation and commission views use delegated v89 platform truth', async () => {
  const source = await read('app/platform-console.js');
  for (const rpc of [
    'platform_get_billing_v125','get_business_billing_v125',
    'request_billing_command_v124',
    'get_billing_plan_catalog_v125','preview_billing_plan_catalog_v125',
    'confirm_billing_plan_catalog_v125',
    'platform_list_commission_consultants_v89','platform_upsert_commission_consultant_v89',
    'platform_get_automation_billing_v89','platform_get_automation_reconciliation_v89',
    'get_consultant_commission_dashboard_v78',
    'get_consultant_commission_policies_v78',
    'create_consultant_commission_policy_v78',
    'attribute_consultant_v78',
    'approve_consultant_accrual_v78','create_consultant_payout_batch_v78',
    'add_consultant_payout_line_v78','approve_consultant_payout_batch_v78',
    'record_consultant_payout_v78','forfeit_consultant_open_commission_v78'
  ]) assert.match(source, new RegExp(rpc));

  assert.match(source, /create_consultant_commission_policy_v78',\{p_tier:values\.role/);
  assert.match(source, /row\.status==='accrued'/);
  assert.match(source, /payout_lines/);
  assert.match(source, /net-of-GST subscription amounts/);
  assert.match(source, /integer cents/);
  assert.match(source, /failed_event_count/);
  assert.match(source, /billingCommands\(detail\)/);
  assert.match(source, /sb\.functions\.invoke\('razorpay-billing-command'/);
  assert.match(source, /p_confirmation_hash:preview\.confirmation_hash/);
});

test('responsive pipeline keeps a mobile list and accessible dialogs', async () => {
  const [source,styles,index] = await Promise.all([
    read('app/platform-console.js'),
    read('app/platform-console.css'),
    Promise.all([read('app/index.html'),read('app/app.js')]).then(f=>f.join('\n'))
  ]);
  assert.match(source, /aria-modal/);
  // v181 (owner request 2026-08-06): the board drags again, so aria-grabbed is
  // now required rather than forbidden — and it must be cleared when the drag
  // ends, or assistive tech reports a card as permanently held.
  assert.match(source, /card\.setAttribute\('aria-grabbed','true'\)/);
  assert.match(source, /card\.removeAttribute\('aria-grabbed'\)/);
  assert.match(source, /Five clear operating lanes/);
  assert.match(styles, /\.platform-kanban:not\(\[hidden\]\)\{display:grid;grid-template-columns:1fr\}/);
  assert.match(styles, /\.platform-prospect-list:not\(\[hidden\]\)\{display:grid/);
  assert.match(styles, /\.platform-kanban\[hidden\],\.platform-prospect-list\[hidden\]\{display:none!important\}/);
  assert.match(styles, /min-height:44px/);
  /* V385 (owner, photo 11: "make editable"). The sector select is the owner's now; the platform
     still owns the entitlement, which is what the two assertions below are about. */
  assert.match(index, /<select id="bi" aria-describedby="biSectorHint">/);
  assert.doesNotMatch(index, /You can change them anytime in Settings/);
  assert.doesNotMatch(index, /id="msave"/);
});
