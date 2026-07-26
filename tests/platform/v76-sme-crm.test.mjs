import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';

const root = new URL('../..', import.meta.url).pathname;
const read = path => readFile(join(root, path), 'utf8');
const sourcePath = 'db/migrations/20260726_nestly_v76_sme_crm.sql';
const canonicalPath = 'supabase/migrations/20260726110000_nestly_v76_sme_crm.sql';
const functionBlock = (sql, schema, name) =>
  sql.match(new RegExp(`create or replace function ${schema}\\.${name}[\\s\\S]+?\\n\\$\\$;`, 'i'))?.[0] || '';

const stages = [
  ['new_lead', 'New Lead'], ['appt_set', 'Appointment Set'],
  ['npu_1', 'NPU 1'], ['npu_2', 'NPU 2'], ['npu_3', 'NPU 3'],
  ['npu_4', 'NPU 4'], ['npu_5', 'NPU 5'], ['npu_6', 'NPU 6'],
  ['call_back', 'Call Back'], ['reschedule', 'Reschedule'],
  ['meeting_sent', 'Meeting Link Sent / Calendar Set'], ['pending_decision', 'Pending Decision'],
  ['client', 'Client / Deal Won'], ['account_created', 'Account Created'],
  ['onboarding', 'Onboarding in Progress'], ['activated', 'Activated'], ['lost', 'Lost'],
];

test('v76 source and canonical migrations are byte-identical and backend-only', async () => {
  const [source, canonical] = await Promise.all([read(sourcePath), read(canonicalPath)]);
  assert.equal(canonical, source);
  assert.match(source, /^-- NESTLY v76/m);
  assert.doesNotMatch(source, /stripe|payment_intent|invoice/i);
});

test('v76 freezes the exact ordered 17-stage vocabulary', async () => {
  const sql = await read(sourcePath);
  const seed = sql.match(/insert into public\.sme_pipeline_stages[\s\S]+?;/i)?.[0] || '';
  assert.equal((seed.match(/\('[a-z0-9_]+','[^']+',\d+\)/g) || []).length, 17);
  stages.forEach(([key, label], index) =>
    assert.match(seed, new RegExp(`\\('${key}','${label}',${index + 1}\\)`)));
  assert.doesNotMatch(seed, /unmapped/i);
});

test('v76 normalizes companies, prospects and conversion-facing fields', async () => {
  const sql = await read(sourcePath);
  assert.match(sql, /create table public\.sme_companies/i);
  assert.match(sql, /legal_name text/i);
  assert.match(sql, /trading_name text/i);
  assert.match(sql, /registration_number text/i);
  assert.match(sql, /sector_key text references public\.sector_profiles/i);
  const prospect = sql.match(/create table public\.sme_prospects[\s\S]+?\n\);/)?.[0] || '';
  for (const field of [
    'company_id', 'current_stage_key', 'assigned_consultant_id',
    'converted_business_id', 'converted_at', 'converted_by', 'version',
  ]) assert.match(prospect, new RegExp(`${field} `));
});

test('v76 commercial terms are immutable accepted conversion snapshots', async () => {
  const sql = await read(sourcePath);
  const terms = sql.match(/create table public\.sme_commercial_terms[\s\S]+?\n\);/)?.[0] || '';
  for (const field of [
    'plan_code', 'product_code', 'billing_cycle', 'seats', 'currency',
    'accepted_value_cents', 'owner_email', 'onboarding_owner_consultant_id',
    'target_go_live', 'contract_status', 'accepted_at',
  ]) assert.match(terms, new RegExp(`${field} `));
  assert.match(sql, /sme_commercial_terms_immutable_guard/i);
  assert.match(terms, /unique\(prospect_id,version\)/i);
});

test('v76 models contacts, assignments, activities, tasks, qualification, tags and lineage', async () => {
  const sql = await read(sourcePath);
  for (const table of [
    'sme_prospect_contacts', 'sme_prospect_assignments', 'sme_prospect_activities',
    'sme_prospect_stage_history', 'sme_prospect_tasks',
    'sme_prospect_qualification_versions', 'sme_tags', 'sme_prospect_tags',
    'sme_prospect_source_lineage', 'sme_prospect_data_quality_flags',
    'sme_prospect_import_batches', 'sme_prospect_import_rows',
  ]) assert.match(sql, new RegExp(`create table public\\.${table}`));
});

test('v76 board always returns all stages plus visible Unmapped prospects', async () => {
  const sql = await read(sourcePath);
  const board = functionBlock(sql, 'public', 'platform_get_sme_board_v76');
  assert.match(board, /from public\.sme_pipeline_stages stage/i);
  assert.match(board, /'columns'/i);
  assert.match(board, /'unmapped'/i);
  assert.match(board, /prospect\.current_stage_key is null/i);
  assert.match(board, /app\.sme_prospect_card_v76/i);
  const card = functionBlock(sql, 'app', 'sme_prospect_card_v76');
  for (const field of [
    'primary_contact','source','region','tags','priority','fit_score','last_activity',
    'stage_entered_at','stage_age_days','next_action_overdue',
    'data_completeness_percent','open_data_quality_warnings',
  ]) assert.match(card, new RegExp(`'${field}'`));
});

test('v76 detail returns the complete prospect operating context', async () => {
  const sql = await read(sourcePath);
  const detail = functionBlock(sql, 'public', 'platform_get_prospect_detail_v76');
  for (const key of [
    'prospect', 'company', 'contacts', 'assignment', 'activities', 'tasks',
    'stage_history', 'qualification', 'commercial_terms', 'sources', 'tags',
    'data_quality_flags',
  ]) assert.match(detail, new RegExp(`'${key}'`));
});

test('v76 optimistic writes and retries have version/hash replay contracts', async () => {
  const sql = await read(sourcePath);
  assert.match(sql, /create table public\.sme_operation_receipts/i);
  assert.match(sql, /unique\(actor,operation,idempotency_key\)/i);
  assert.match(sql, /idempotency key was reused with different input/i);
  for (const name of ['platform_update_prospect_v76', 'platform_assign_prospect_v76', 'platform_move_prospect_stage_v76']) {
    const fn = functionBlock(sql, 'public', name);
    assert.match(fn, /p_expected_version/i);
    assert.match(fn, /using errcode='40001'/i);
    assert.match(fn, /app\.v76_replay/i);
    assert.match(fn, /app\.v76_store_receipt/i);
  }
});

test('v76 NPU, Lost and Client transitions enforce the product rules', async () => {
  const sql = await read(sourcePath);
  const move = functionBlock(sql, 'public', 'platform_move_prospect_stage_v76');
  const create = functionBlock(sql, 'public', 'platform_create_prospect_v76');
  assert.match(move, /p_to_stage in \('npu_1','npu_2','npu_3','npu_4','npu_5','npu_6'\)/i);
  assert.match(move, /'npu_attempt'/i);
  assert.match(move, /Lost requires a structured reason code/i);
  for (const reason of [
    'no_response','not_interested','no_budget','timing','chose_competitor',
    'missing_required_feature','procurement_security_blocker','price',
    'internal_priority_changed','business_ceased','duplicate','bad_fit','other',
  ]) assert.match(move, new RegExp(`'${reason}'`));
  assert.doesNotMatch(move, /'competitor'|'unreachable'|'not_qualified'/);
  assert.match(move, /Client requires accepted commercial fields/i);
  assert.match(move, /quarterly','half_yearly','annual/i);
  assert.match(move, /insert into public\.sme_commercial_terms/i);
  assert.match(move, /p_to_stage in \('account_created','onboarding','activated'\)/i);
  assert.match(move, /system-managed and requires conversion evidence/i);
  assert.match(create, /p_stage_key in \('account_created','onboarding','activated'\)/i);
  assert.match(create, /system-managed and requires conversion evidence/i);
});

test('v76 imports preserve unknown legacy stage evidence in Unmapped', async () => {
  const sql = await read(sourcePath);
  const stage = functionBlock(sql, 'public', 'platform_stage_prospect_import_v76');
  const commit = functionBlock(sql, 'public', 'platform_commit_prospect_import_v76');
  assert.match(stage, /v_status:='unmapped'/i);
  assert.match(stage, /raw_stage,mapped_stage_key,row_status/i);
  assert.match(commit, /legacy_stage_raw/i);
  assert.match(commit, /'unmapped_stage','warning'/i);
  assert.match(commit, /row_status in \('valid','unmapped'\)/i);
  assert.match(stage, /v_status:='conflict'/i);
  assert.match(stage, /duplicate_registration_number/i);
  assert.match(commit, /'conflict_rows'/i);
  assert.match(commit, /'skipped_rows'/i);
});

test('v76 search and activities cover the platform operating workflow', async () => {
  const sql = await read(sourcePath);
  const search = functionBlock(sql, 'app', 'sme_prospect_search_match_v76');
  assert.match(search, /sme_prospect_contacts/i);
  assert.match(search, /contact\.full_name/i);
  assert.match(search, /sme_prospect_activities/i);
  assert.match(search, /activity\.summary/i);
  assert.match(search, /qualification\.notes/i);
  const activity = functionBlock(sql, 'public', 'platform_add_prospect_activity_v76');
  for (const type of [
    'whatsapp','demo','task','document_sent','proposal_sent','contract_sent',
    'payment','onboarding_session',
  ]) assert.match(activity, new RegExp(`'${type}'`));
});

test('v76 exposes only finite authenticated RPCs through a platform-operator check', async () => {
  const sql = await read(sourcePath);
  const names = [
    'platform_get_sme_board_v76', 'platform_list_prospects_v76',
    'platform_get_prospect_detail_v76', 'platform_create_prospect_v76',
    'platform_update_prospect_v76', 'platform_assign_prospect_v76',
    'platform_add_prospect_activity_v76', 'platform_create_prospect_task_v76',
    'platform_complete_prospect_task_v76', 'platform_move_prospect_stage_v76',
    'platform_stage_prospect_import_v76', 'platform_commit_prospect_import_v76',
  ];
  names.forEach(name => assert.match(
    functionBlock(sql, 'public', name),
    /if not app\.is_platform_operator_v75\(\)/i
  ));
  assert.match(sql, /revoke all privileges on table public\./i);
  names.forEach(name => {
    assert.match(
      sql,
      new RegExp(`revoke all on function public\\.${name}\\(`, 'i'),
      `${name} must explicitly revoke PostgreSQL's default execute grant`
    );
    assert.match(
      sql,
      new RegExp(`grant execute on function public\\.${name}\\([^;]+?\\) to authenticated`, 'i'),
      `${name} must explicitly grant only the reviewed browser role`
    );
  });
});

test('v76 audits platform changes without assigning tenant business scope', async () => {
  const sql = await read(sourcePath);
  for (const action of [
    'SME_PROSPECT_CREATED_V76', 'SME_PROSPECT_UPDATED_V76',
    'SME_PROSPECT_ASSIGNED_V76', 'SME_PROSPECT_ACTIVITY_ADDED_V76',
    'SME_PROSPECT_TASK_CREATED_V76', 'SME_PROSPECT_TASK_COMPLETED_V76',
    'SME_PROSPECT_STAGE_MOVED_V76', 'SME_PROSPECT_IMPORT_STAGED_V76',
    'SME_PROSPECT_IMPORT_COMMITTED_V76',
  ]) assert.match(sql, new RegExp(action));
  assert.match(sql, /values\(null,v_actor,'SME_PROSPECT/i);
});

test('v76 rollback evidence covers replay, transitions, rules and Unmapped', async () => {
  const rollback = await read('db/tests/v76_sme_crm.sql');
  assert.match(rollback, /^begin;/m);
  assert.match(rollback, /^rollback;/m);
  for (const evidence of [
    'prospect create replay was not idempotent',
    'stale prospect update did not conflict',
    'NPU transition did not create one activity',
    'Lost accepted no structured reason',
    'Client accepted no commercial fields',
    'user moved a prospect into a system-managed stage',
    'accepted commercial snapshot was not preserved',
    'duplicate registration import was not isolated as conflict',
    'unknown imported stage was hidden instead of Unmapped',
    'non-platform user opened the SME board',
  ]) assert.match(rollback, new RegExp(evidence));
});
