import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';

const root = new URL('../..', import.meta.url).pathname;
const migrationPath = 'db/migrations/20260825_nestly_v510_operating_system_crm_foundation.sql';
const uiPath = 'app/platform-console.js';
const read = path => readFile(join(root, path), 'utf8');
const functionBlock = (sql, name) => sql.match(new RegExp(
  `create or replace function (?:public|app)\\.${name}\\([\\s\\S]+?\\nend \\$\\$;`, 'i'))?.[0] || '';

test('v510 establishes one namespaced Company identity and intake path', async () => {
  const sql = await read(migrationPath);
  assert.match(sql, /create table public\.sme_company_identity_keys_v510/i);
  assert.match(sql, /key_namespace text not null/i);
  assert.match(sql, /\(key_type,key_namespace,normalized_value\)[\s\S]+confidence='strong'/i);
  assert.match(sql, /create table public\.sme_lead_intakes_v510/i);
  const ingest = functionBlock(sql, 'platform_ingest_lead_v510');
  assert.match(ingest, /pg_advisory_xact_lock/i);
  assert.match(ingest, /operation:[\s\S]+app\.v76_replay[\s\S]+app\.v76_store_receipt/i);
  assert.match(ingest, /conflicting_strong_keys[\s\S]+duplicate_review/i);
  assert.match(ingest, /sme_prospect_source_lineage/i);
  assert.match(sql, /platform_crm_ingest_discovered_v297[\s\S]+platform_ingest_lead_v510/i);
  assert.match(sql, /platform_commit_prospect_import_v86[\s\S]+platform_ingest_lead_v510/i);
  assert.match(sql, /normalized Company identity conflicts require review before v510/i);
  assert.match(sql, /on conflict on constraint sme_company_identity_provenance_v510_uk do nothing/i);
  assert.doesNotMatch(functionBlock(sql,'v510_sync_company_identity'), /on conflict do nothing/i);
});

test('v510 makes owner-or-queue and next action executable invariants', async () => {
  const sql = await read(migrationPath);
  assert.match(sql, /ownership_state in \('queued','owned','closed'\)/i);
  assert.match(sql, /active lead requires an owner or explicit queue/i);
  assert.match(sql, /active lead requires a next action and deadline/i);
  for (const rpc of [
    'platform_claim_lead_v510','platform_transfer_lead_v510','platform_queue_lead_v510',
    'platform_reassign_consultant_portfolio_v510',
  ]) {
    const body = functionBlock(sql, rpc);
    assert.ok(body, `${rpc} must exist`);
    assert.match(body, /app\.v76_replay[\s\S]+app\.v76_store_receipt/i);
    assert.match(body, /pg_advisory_xact_lock[\s\S]+app\.v76_replay/i);
    assert.match(body, /version conflict|portfolio changed/i);
  }
  assert.match(sql, /sme_prospects_one_open_core_v510_uk/i);
  assert.match(functionBlock(sql,'platform_transfer_lead_v510'), /current_stage_key=case when current_stage_key='new_lead' then 'assigned'/i);
  assert.doesNotMatch(functionBlock(sql,'platform_queue_lead_v510'), /next_action_type='assign_owner'/i);
});

test('v510 has one guarded lifecycle and CLOSED_WON never activates a merchant', async () => {
  const sql = await read(migrationPath);
  const transition = functionBlock(sql, 'platform_transition_lead_v510');
  for (const stage of ['assigned','contacted','interested','appointment','proposal','closed_won','nurture','lost'])
    assert.match(sql, new RegExp(`'${stage}'`));
  assert.match(transition, /transition is not allowed/i);
  assert.match(transition, /sme_stage_entry_evidence/i);
  assert.match(transition, /next action exceeds the canonical stage SLA/i);
  assert.match(transition, /terminal confirmation must be true/i);
  assert.match(transition, /closed won requires accepted commercial terms/i);
  assert.doesNotMatch(transition, /insert into public\.businesses|converted_business_id\s*=/i);
  for (const legacy of [
    'platform_move_prospect_stage_v76','platform_move_prospect_stage_v86','platform_move_my_prospect_stage_v89',
  ]) assert.match(sql, new RegExp(`revoke execute on function public\\.${legacy}`,'i'));
  assert.match(sql,/revoke execute on function public\.platform_explorer_bulk_assign_v312/i);
  assert.match(sql,/revoke execute on function public\.platform_merge_prospects_v184/i);
  assert.match(functionBlock(sql,'convert_sme_prospect_v79'), /current_stage_key not in \('closed_won','client'\)/i);
  assert.match(sql,/payment_verified[\s\S]+business activation requires verified initial payment/i);
});

test('admin UI calls only canonical create, ownership and transition writes', async () => {
  const ui = await read(uiPath);
  for (const rpc of [
    'platform_ingest_lead_v510','platform_transfer_lead_v510','platform_queue_lead_v510',
    'platform_transition_lead_v510','platform_bulk_transfer_leads_v510',
  ]) assert.match(ui, new RegExp(`rpc\\(.*'${rpc}'`));
  for (const bypass of [
    'platform_create_prospect_v76','platform_create_my_prospect_v89','platform_assign_prospect_v89',
    'platform_move_prospect_stage_v86','platform_move_my_prospect_stage_v89',
    'platform_commit_prospect_import_v76',
    'platform_explorer_bulk_assign_v312','platform_merge_prospects_v184',
  ]) assert.doesNotMatch(ui, new RegExp(`rpc\\(.*'${bypass}'`));
  assert.match(ui, /\['proposal','Proposal'\],\['closed_won','Closed won'\],\['nurture','Nurture'\]/);
  assert.match(ui, /Payment \/ onboarding follow-up due/);
  assert.match(ui,/data-lead-exception-queue/);
  assert.match(ui,/data-claim-lead/);
});

test('v510 exposes an exception queue and a single operational timeline', async () => {
  const sql = await read(migrationPath);
  const exceptions = functionBlock(sql, 'platform_list_lead_exceptions_v510');
  for (const reason of ['unassigned','inactive_owner','missing_next_action','overdue','due_today'])
    assert.match(exceptions, new RegExp(`'${reason}'`));
  const timeline = functionBlock(sql, 'platform_get_lead_timeline_v510');
  for (const source of [
    'sme_prospect_stage_history','sme_prospect_assignments','sme_prospect_activities',
    'sme_prospect_source_lineage','sme_prospect_tasks','sme_outreach_records',
  ]) assert.match(timeline, new RegExp(source));
  assert.match(sql,/platform_list_identity_reviews_v510/i);
  assert.match(sql,/platform_resolve_identity_review_v510/i);
  assert.match(await read(uiPath),/id="platformIdentityReviews"[\s\S]+platform_list_identity_reviews_v510/i);
});

test('v510 preserves provider facts and separates commercial win, payment and account creation', async()=>{
  const [sql,ui]=await Promise.all([read(migrationPath),read(uiPath)]);
  const discovery=functionBlock(sql,'platform_crm_ingest_discovered_v297');
  assert.match(discovery,/rating=coalesce\(excluded\.rating,public\.sme_company_market_facts\.rating\)/i);
  assert.match(discovery,/coalesce\(excluded\.latitude,public\.sme_company_locations\.latitude\)/i);
  assert.match(sql,/verified payment cannot replace CLOSED_WON commercial agreement/i);
  assert.match(sql,/platform_get_sme_analytics_v510[\s\S]+to_stage_key='closed_won'/i);
  assert.match(ui,/Create the inactive account now so Stripe or a manual invoice can collect payment/);
  assert.match(ui,/Prepare billing account/);
  assert.match(ui,/platform_get_sme_analytics_v510/);
  assert.doesNotMatch(ui,/data-convert/);
});

test('v510 derives entitlement only from the exact accepted payment obligation', async()=>{
  const sql=await read(migrationPath);
  assert.match(sql,/accepted_value_cents'\)::integer,0\)<=0/i);
  assert.match(sql,/values\(v_business\.id,'incomplete'[^;]+v_terms\.accepted_value_cents[^;]+'not_collected'/is);
  assert.match(sql,/create or replace function app\.v510_verified_initial_payment/i);
  assert.match(sql,/invoice\.amount_paid_cents=obligation\.period_total_cents/i);
  assert.match(sql,/document\.service_period_start=obligation\.obligation_period_start/i);
  assert.match(sql,/adjustment\.adjustment_type in \('refund','chargeback'\)/i);
  assert.match(functionBlock(sql,'v510_guard_paid_handoff'),/v510_has_verified_initial_payment/i);
  assert.match(sql,/initial_payment_source[\s\S]+initial_payment_evidence_id[\s\S]+initial_payment_verified_at/i);
});

test('v510 keeps assisted-sale shells unusable until paid and activated', async()=>{
  const sql=await read(migrationPath);
  const conversion=functionBlock(sql,'convert_sme_prospect_v79');
  assert.match(conversion,/source_prospect_id,join_enabled[\s\S]+p_prospect,false/i);
  const guard=functionBlock(sql,'v510_guard_inactive_shell_rails');
  assert.match(guard,/workspace owner access requires verified initial payment/i);
  assert.match(guard,/active branch requires activated Business/i);
  assert.match(guard,/customer join QR requires activated Business/i);
  assert.match(sql,/update public\.branches branch set active=false/i);
  assert.match(sql,/business_customer_join_qr_v89 qr set status='revoked'/i);
});

test('v510 converges merchant identity, reviewed CSV facts and dirty next actions', async()=>{
  const sql=await read(migrationPath);
  const ingest=functionBlock(sql,'platform_ingest_lead_v510');
  assert.match(ingest,/from public\.businesses business[\s\S]+business\.place_id[\s\S]+business\.postal_code/i);
  assert.match(ingest,/disposition','existing_merchant'/i);
  const csv=functionBlock(sql,'platform_commit_prospect_import_v86');
  assert.match(csv,/reviewed merge conflicts with the Company UEN/i);
  assert.match(csv,/insert into public\.sme_prospect_contacts/i);
  assert.doesNotMatch(sql,/Superseded by canonical v510 next action/i);
  assert.doesNotMatch(functionBlock(sql,'v510_project_canonical_task'),/update public\.sme_prospect_tasks set status='cancelled'/i);
  assert.match(sql,/v510 lead backfill did not converge canonical ownership\/action state/i);
  assert.match(functionBlock(sql,'v510_freeze_converted_company_identity'),/audited identity-change workflow/i);
  assert.match(functionBlock(sql,'convert_sme_prospect_v79'),/v_company\.registration_number is null or business\.registration_number is null/i);
});

test('outreach retries reuse one backend command and one browser attempt key', async()=>{
  const [sql,ui]=await Promise.all([read(migrationPath),read(uiPath)]);
  const outreach=functionBlock(sql,'platform_crm_log_outreach_v297');
  assert.match(outreach,/require_idempotency_key_v79/i);
  assert.match(outreach,/pg_advisory_xact_lock[\s\S]+v76_replay/i);
  assert.match(outreach,/follow-up exceeds the canonical stage SLA/i);
  assert.match(outreach,/insert into public\.sme_outreach_records[\s\S]+insert into public\.sme_prospect_tasks[\s\S]+CRM_OUTREACH_LOGGED_V510[\s\S]+v76_store_receipt/i);
  assert.doesNotMatch(outreach,/v297_refresh_lead_score|sme_lead_scores/i);
  assert.match(ui,/let outreachAttemptKey=''[\s\S]+let outreachFingerprint=''/i);
  assert.match(ui,/if\(fingerprint!==outreachFingerprint\)[\s\S]+p_idempotency_key:outreachAttemptKey/i);
});
