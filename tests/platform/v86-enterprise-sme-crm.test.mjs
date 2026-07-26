import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';

const root = new URL('../..', import.meta.url).pathname;
const sourcePath = 'db/migrations/20260726_nestly_v86_enterprise_sme_crm.sql';
const canonicalPath = 'supabase/migrations/20260726210000_nestly_v86_enterprise_sme_crm.sql';
const read = path => readFile(join(root, path), 'utf8');
const functionBlock = (sql, schema, name) =>
  sql.match(new RegExp(`create or replace function ${schema}\\.${name}[\\s\\S]+?\\n\\$\\$;`, 'i'))?.[0] || '';

const publicFunctions = [
  'platform_record_company_profile_v86',
  'platform_record_contact_profile_v86',
  'platform_record_qualification_v86',
  'platform_record_activity_detail_v86',
  'platform_record_commercial_detail_v86',
  'platform_record_conversion_configuration_v86',
  'platform_upsert_prospect_contact_v86',
  'platform_move_prospect_stage_v86',
  'platform_request_prospect_document_upload_v86',
  'platform_request_prospect_document_read_v86',
  'service_consume_document_signing_request_v86',
  'service_get_consumed_document_upload_v86',
  'service_finalize_document_upload_v86',
  'platform_analyse_prospect_import_v86',
  'platform_stage_prospect_import_v86',
  'platform_decide_import_row_v86',
  'platform_commit_prospect_import_v86',
  'platform_reverse_prospect_import_v86',
  'platform_get_import_errors_v86',
  'platform_get_import_batch_v86',
  'platform_rollback_prospect_import_v86',
  'platform_list_prospects_v86',
  'platform_get_prospect_workspace_v86',
  'platform_refresh_prospect_quality_v86',
  'platform_get_prospect_detail_v86',
  'platform_list_prospect_audit_v86',
  'platform_get_sme_analytics_v86',
];

test('v86 source and canonical migrations are byte-identical and backend-only', async () => {
  const [source, canonical] = await Promise.all([read(sourcePath), read(canonicalPath)]);
  assert.equal(canonical, source);
  assert.match(source, /^-- NESTLY v86/m);
  const bucket = source.match(/insert into storage\.buckets[\s\S]+?allowed_mime_types=excluded\.allowed_mime_types;/i)?.[0] || '';
  assert.match(bucket, /'sme-private','sme-private',false,26214400/i);
  for (const mime of [
    'application/pdf','text/csv',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'image/png','image/jpeg','image/webp','application/zip',
  ]) assert.match(bucket, new RegExp(`'${mime.replaceAll('.', '\\.')}'`));
  assert.match(bucket, /on conflict\(id\) do update set[\s\S]+public=false/i);
  assert.doesNotMatch(source, /create policy[\s\S]+storage\.objects/i);
  assert.doesNotMatch(source, /app\/platform-console|document\.queryselector/i);
});

test('v86 uses typed versioned layers for the full enterprise SME record', async () => {
  const sql = await read(sourcePath);
  const tables = [
    'sme_company_profile_versions',
    'sme_contact_profile_versions',
    'sme_qualification_detail_versions',
    'sme_activity_detail_versions',
    'sme_commercial_detail_versions',
    'sme_conversion_configuration_versions',
  ];
  tables.forEach(table => {
    assert.match(sql, new RegExp(`create table public\\.${table}`));
    assert.match(sql, new RegExp(`unique\\([^\\n]*version\\)`, 'i'));
    assert.match(sql, new RegExp(`${table}_immutable_v86`, 'i'));
  });
  for (const field of [
    'registration_country','entity_type','incorporated_on','business_status',
    'service_areas','sub_industry','directory_code','public_rating',
    'employee_range','expected_seats','location_count','customer_type',
    'required_integrations','digital_maturity','source_value','confirmed_value',
  ]) assert.match(sql, new RegExp(`${field} `));
  for (const field of [
    'decision_role','mobile_original','mobile_e164','preferred_channel',
    'contact_hours','is_billing_contact','consent_basis','marketing_opt_in','do_not_contact',
  ]) assert.match(sql, new RegExp(`${field} `));
  for (const field of [
    'primary_problem','pain_points','required_features','security_requirements',
    'budget_min_cents','expected_subscription_cents','system_suggested_score',
    'human_confirmed_score','score_reasons',
  ]) assert.match(sql, new RegExp(`${field} `));
  for (const field of [
    'duration_seconds','direction','channel','next_action_due_at','meeting_url',
    'calendar_event_id','supersedes_activity_id',
  ]) assert.match(sql, new RegExp(`${field} `));
  for (const field of [
    'unit_price_cents','discount_basis_points','tax_treatment','setup_fee_cents',
    'contract_term_months','renewal_on','purchase_order_number','amount_collected_cents',
  ]) assert.match(sql, new RegExp(`${field} `));
  for (const field of [
    'workspace_slug','administrator_emails','invoice_address','gst_registration_number',
    'brand_primary_color','custom_domain','notification_preferences','require_two_factor',
    'retention_policy_days','customer_success_consultant_id',
  ]) assert.match(sql, new RegExp(`${field} `));
});

test('v86 declaratively specifies and validates every stage-entry contract', async () => {
  const sql = await read(sourcePath);
  const seed = sql.match(/insert into public\.sme_stage_entry_requirements[\s\S]+?;\n\ncreate table public\.sme_stage_entry_evidence/i)?.[0] || '';
  const stages = [
    'new_lead','appt_set','npu_1','npu_2','npu_3','npu_4','npu_5','npu_6',
    'call_back','reschedule','meeting_sent','pending_decision','client',
    'account_created','onboarding','activated','lost',
  ];
  stages.forEach(stage => assert.match(seed, new RegExp(`\\('${stage}'`)));
  assert.equal((seed.match(/\('[a-z0-9_]+',array\[/g) || []).length, 17);
  for (const evidence of [
    'appointment_at','callback_at','previous_meeting_reference',
  ]) assert.match(seed, new RegExp(evidence));
  const validator = functionBlock(sql, 'app', 'validate_stage_entry_v86');
  for (const evidence of [
    'next_attempt_at','terminal_disposition','meeting_url','physical_location','decision_at',
    'explicit_confirmation','onboarding_owner_consultant_id','target_go_live',
    'recontact_permission','recontact_at',
  ]) assert.match(validator, new RegExp(evidence));
  assert.match(functionBlock(sql, 'public', 'platform_move_prospect_stage_v86'),
    /insert into public\.sme_stage_entry_evidence[\s\S]+platform_move_prospect_stage_v76/i);
});

test('v86 buying-committee upsert is optimistic, idempotent and versions extended contact data', async () => {
  const sql = await read(sourcePath);
  const upsert = functionBlock(sql, 'public', 'platform_upsert_prospect_contact_v86');
  assert.match(upsert, /p_expected_version/i);
  assert.match(upsert, /prospect version conflict/i);
  assert.match(upsert, /app\.v76_replay[\s\S]+app\.v76_store_receipt/i);
  assert.match(upsert, /insert into public\.sme_prospect_contacts/i);
  assert.match(upsert, /update public\.sme_prospect_contacts/i);
  assert.match(upsert, /platform_record_contact_profile_v86/i);
  assert.match(upsert, /SME_PROSPECT_CONTACT_UPSERTED_V86/i);
});

test('v86 document contracts remain private and delegate signing to a trusted service', async () => {
  const sql = await read(sourcePath);
  assert.match(sql, /bucket_id text not null default 'sme-private' check \(bucket_id='sme-private'\)/i);
  assert.match(sql, /size_bytes bigint not null check \(size_bytes between 1 and 26214400\)/i);
  const upload = functionBlock(sql, 'public', 'platform_request_prospect_document_upload_v86');
  const readRequest = functionBlock(sql, 'public', 'platform_request_prospect_document_read_v86');
  assert.match(upload, /app\.can_access_prospect_sensitive_v86/i);
  assert.match(readRequest, /app\.can_access_prospect_sensitive_v86/i);
  assert.match(upload, /'signed_url',null[\s\S]+'requires_trusted_signer',true/i);
  assert.match(readRequest, /'signed_url',null[\s\S]+'requires_trusted_signer',true/i);
  assert.match(sql, /grant execute on function public\.service_consume_document_signing_request_v86\(uuid,text,uuid\) to service_role/i);
  assert.match(sql, /grant execute on function public\.service_get_consumed_document_upload_v86\(uuid,uuid\) to service_role/i);
  assert.match(sql, /grant execute on function public\.service_finalize_document_upload_v86\(uuid,text,bigint,uuid\) to service_role/i);
  assert.match(functionBlock(sql, 'public', 'service_consume_document_signing_request_v86'),
    /v_request\.requested_by<>p_actor[\s\S]+'original_filename'/i);
  assert.match(functionBlock(sql, 'public', 'service_get_consumed_document_upload_v86'),
    /v_request\.requested_by<>p_actor[\s\S]+v_request\.consumed_at is null[\s\S]+v_request\.expires_at<=now\(\)[\s\S]+'bucket_id'[\s\S]+'object_path'/i);
  assert.match(functionBlock(sql, 'public', 'service_finalize_document_upload_v86'),
    /v_request\.requested_by<>p_actor[\s\S]+v_request\.expires_at<=now\(\)/i);
  assert.doesNotMatch(sql, /grant execute on function public\.service_[^(]*\([^;]+to authenticated/i);
});

test('v86 importer supports synonyms, labelled custom mappings, decisions and guarded reversal', async () => {
  const sql = await read(sourcePath);
  for (const synonym of [
    'company name','legal name','contact person','designation','contact number','email address',
    'registered address','postal','registration number','directory code','star rating',
    'review count','headcount','remarks',
  ]) assert.match(sql, new RegExp(`'${synonym}'`));
  const analyse = functionBlock(sql, 'public', 'platform_analyse_prospect_import_v86');
  assert.match(analyse, /custom__%/i);
  assert.match(analyse, /registration_number[\s\S]+domain[\s\S]+email[\s\S]+phone[\s\S]+company_name_postal/i);
  assert.match(analyse, /invalid_email|invalid_phone|invalid_postal_code|invalid_registration_number/i);
  for (const decision of ['insert','skip','merge','review'])
    assert.match(sql, new RegExp(`'${decision}'`));
  assert.match(functionBlock(sql, 'public', 'platform_decide_import_row_v86'),
    /merge requires a reviewed dedupe candidate/i);
  const rollback = functionBlock(sql, 'public', 'platform_reverse_prospect_import_v86');
  assert.match(rollback, /prospect\.version<>v_line\.prospect_version_at_commit/i);
  assert.match(rollback, /converted_business_id is not null/i);
  assert.match(rollback, /cannot reverse after a prospect was edited or used/i);
  assert.match(rollback, /current_stage_key='lost'[\s\S]+reason_code[\s\S]+'import_reversed'/i);
  assert.match(rollback, /records_preserved_for_audit/i);
  assert.doesNotMatch(rollback, /delete from public\.sme_(?:prospect_stage_history|prospects|companies)/i);
  const batch = functionBlock(sql, 'public', 'platform_get_import_batch_v86');
  assert.match(batch, /import_row_id/i);
  assert.match(batch, /latest_decision/i);
  assert.match(batch, /candidates/i);
});

test('v86 completeness is weighted, immutable and human confirmation stays explicit', async () => {
  const sql = await read(sourcePath);
  const rows = [...sql.matchAll(/\('[a-z_]+',1,'[^']+',(\d+),'(?:info|warning|blocking)'\)/g)];
  assert.equal(rows.length, 11);
  assert.equal(rows.reduce((sum, match) => sum + Number(match[1]), 0), 100);
  assert.match(functionBlock(sql, 'public', 'platform_refresh_prospect_quality_v86'),
    /sme_data_quality_snapshots[\s\S]+duplicate_registration_number[\s\S]+duplicate_domain/i);
  assert.match(sql, /system_suggested_score[\s\S]+human_confirmed_score[\s\S]+confirmed_by[\s\S]+confirmed_at/i);
});

test('v86 readers are authorized, finite, snapshot-stable and keyset paged', async () => {
  const sql = await read(sourcePath);
  const list = functionBlock(sql, 'public', 'platform_list_prospects_v86');
  for (const filter of [
    'search','stage','owner','source','region','segment','priority',
    'qualification','next_action_from','next_action_to','onboarding_health',
  ]) assert.match(list, new RegExp(`'${filter}'`));
  assert.match(list, /p_snapshot_at[\s\S]+p_after_updated_at[\s\S]+p_after_id/i);
  const detail = functionBlock(sql, 'public', 'platform_get_prospect_detail_v86');
  assert.match(detail, /least\(greatest\(coalesce\(p_limit,50\),1\),100\)/i);
  assert.match(detail, /company_profile[\s\S]+conversion_configuration[\s\S]+documents[\s\S]+data_quality/i);
  const audit = functionBlock(sql, 'public', 'platform_list_prospect_audit_v86');
  assert.match(audit, /\(audit\.created_at,audit\.id\)<\(p_after_created_at,p_after_id\)/i);
  assert.match(audit, /app\.can_access_prospect_sensitive_v86/i);
  const analytics = functionBlock(sql, 'public', 'platform_get_sme_analytics_v86');
  assert.match(analytics, /analytics window must contain at most two years/i);
  assert.match(analytics, /sme_prospect_stage_history/i);
  for (const metric of [
    'leads_created','won','activated','overdue_next_actions','pipeline_value_cents',
    'median_age_days','source_page','loss_reasons','contact_attempt_distribution',
  ]) assert.match(analytics, new RegExp(`'${metric}'`));
  assert.match(analytics, /p_after_source[\s\S]+next_after_source/i);
});

test('v86 enables RLS, denies raw browser tables and explicitly ACLs every public function', async () => {
  const sql = await read(sourcePath);
  const tables = [...sql.matchAll(/create table public\.([a-z0-9_]+)/g)].map(match => match[1]);
  assert.equal(tables.length, 19);
  for (const table of tables) {
    assert.match(sql, new RegExp(`alter table public\\.${table} enable row level security`, 'i'));
    assert.match(sql, new RegExp(`revoke all privileges on table public\\.${table} from public,anon,authenticated`, 'i'));
  }
  assert.deepEqual(
    [...sql.matchAll(/^create or replace function public\.([a-z0-9_]+)/gim)].map(match => match[1]),
    publicFunctions
  );
  for (const name of publicFunctions) {
    assert.match(sql, new RegExp(`revoke all on function public\\.${name}\\(`, 'i'), `${name} lacks explicit revoke`);
    if (name.startsWith('service_')) {
      assert.match(sql, new RegExp(`grant execute on function public\\.${name}\\([^;]+?\\) to service_role`, 'i'));
    } else {
      assert.match(sql, new RegExp(`grant execute on function public\\.${name}\\([^;]+?\\) to authenticated`, 'i'));
      assert.match(functionBlock(sql, 'public', name), /app\.(?:is_platform_operator_v75|is_super_admin|can_access_prospect_sensitive_v86)|platform_reverse_prospect_import_v86/i);
    }
  }
});

test('v86 rollback suite exercises typed records, gates, private documents, import reversal and readers', async () => {
  const sql = await read('db/tests/v86_enterprise_sme_crm.sql');
  assert.equal((sql.match(/^begin;$/gim) || []).length, 1);
  assert.equal((sql.match(/^rollback;$/gim) || []).length, 1);
  for (const evidence of [
    'private document bucket constraints were not installed exactly',
    'company profile version was not preserved',
    'contact profile normalization failed',
    'stage accepted missing evidence',
    'stage evidence or history was not preserved',
    'document request exposed a public or signed URL',
    'outsider requested a private prospect document',
    'document signer accepted the wrong bound actor',
    'consumed upload target was not resolved by request and actor',
    'document upload finalization did not preserve verified metadata',
    'custom import mapping was not preserved',
    'import batch reversal did not tombstone untouched inserted records',
    'quality weights did not resolve to 100',
    'non-platform user opened v86 analytics',
  ]) assert.match(sql, new RegExp(evidence));
});
