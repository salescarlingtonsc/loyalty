import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';

const root = new URL('../..', import.meta.url).pathname;
const read = path => readFile(join(root, path), 'utf8');
const sourcePath = 'db/migrations/20260726_nestly_v79_conversion_onboarding.sql';
const canonicalPath = 'supabase/migrations/20260726140000_nestly_v79_conversion_onboarding.sql';
const functionBlock = (sql, schema, name) =>
  sql.match(new RegExp(`create or replace function ${schema}\\.${name}[\\s\\S]+?\\n\\$\\$;`, 'i'))?.[0] || '';

test('v79 source and canonical migrations are byte-identical', async () => {
  const [source, canonical] = await Promise.all([read(sourcePath), read(canonicalPath)]);
  assert.equal(canonical, source);
  assert.match(source, /^-- NESTLY v79/m);
});

test('v79 extends workspace and subscription with conversion evidence', async () => {
  const sql = await read(sourcePath);
  for (const field of [
    'legal_name', 'registration_number', 'onboarding_started_at',
    'activated_at', 'source_prospect_id',
  ]) assert.match(sql, new RegExp(`add column if not exists ${field}`));
  for (const field of ['plan_code', 'product_code', 'commercial_terms_id', 'seat_limit'])
    assert.match(sql, new RegExp(`add column if not exists ${field}`));
  assert.match(sql, /businesses_source_prospect_uk/i);
  assert.match(sql, /normalized_business_identity_v79\(registration_number\)/i);
});

test('v79 conversion is serialized, optimistic, idempotent and transactional', async () => {
  const sql = await read(sourcePath);
  const fn = functionBlock(sql, 'public', 'convert_sme_prospect_v79');
  assert.match(fn, /is_platform_operator_v75\(\)/i);
  assert.match(fn, /for update/i);
  assert.match(fn, /version<>p_expected_version/i);
  assert.match(fn, /current_stage_key<>'client'/i);
  assert.match(fn, /pg_advisory_xact_lock/i);
  assert.match(fn, /contract_status in \('accepted','signed'\)/i);
  assert.match(fn, /'duplicate_workspace'/i);
  assert.match(fn, /'already_converted'/i);
  assert.match(fn, /v76_replay/i);
  assert.match(fn, /v76_store_receipt/i);
  assert.match(fn, /#-'\{owner_invitation,raw_token\}'/i);
});

test('v79 conversion creates exact inactive workspace projections without starting the commission clock', async () => {
  const sql = await read(sourcePath);
  const fn = functionBlock(sql, 'public', 'convert_sme_prospect_v79');
  for (const relation of [
    'public.businesses', 'public.branches', 'public.loyalty_programs',
    'public.subscriptions', 'public.business_sector_assignments',
  ]) assert.match(fn, new RegExp(`insert into ${relation.replace('.', '\\.')}`));
  assert.match(fn, /values\(v_business\.id,[\s\S]+true,false\)/i);
  assert.match(fn, /'draft','prospect_conversion_v79'/i);
  assert.match(fn, /v_terms\.plan_code,v_terms\.product_code,v_terms\.id,v_terms\.seats/i);
  assert.doesNotMatch(fn, /attribute_consultant_core_v78/i);
  assert.doesNotMatch(fn, /onboarding_started_at,source_prospect_id/i);
  assert.doesNotMatch(fn, /insert into public\.staff/i);
});

test('v79 starts the consultant anniversary on the actual onboarding start and avoids duplicate starts', async () => {
  const sql = await read(sourcePath);
  const fn = functionBlock(sql, 'public', 'start_business_onboarding_v79');
  assert.match(fn, /if v_check\.status='in_progress'[\s\S]+return v_response/i);
  assert.match(fn, /set onboarding_started_at=coalesce\(onboarding_started_at,now\(\)\)/i);
  assert.match(fn, /consultant\.active and consultant\.departed_at is null/i);
  assert.match(fn, /attribute_consultant_core_v78[\s\S]+v_onboarding_started_at/i);
  assert.match(fn, /active assigned consultant at onboarding start/i);
});

test('v79 invitation stores only a hash and returns raw token once', async () => {
  const sql = await read(sourcePath);
  const table = sql.match(/create table public\.workspace_owner_invitations[\s\S]+?\n\);/)?.[0] || '';
  assert.match(table, /token_hash text not null unique/i);
  assert.match(table, /token_last_four text not null/i);
  assert.doesNotMatch(table, /raw_token/i);
  const issue = functionBlock(sql, 'app', 'issue_workspace_owner_invite_core_v79');
  assert.match(issue, /gen_random_bytes\(32\)/i);
  assert.match(issue, /pg_advisory_xact_lock/i);
  assert.match(issue, /'raw_token',v_token/i);
  const accept = functionBlock(sql, 'public', 'accept_workspace_owner_invite_v79');
  assert.match(accept, /from auth\.users where id=v_actor/i);
  assert.match(accept, /owner_email\)\)<>v_email/i);
  assert.match(accept, /insert into public\.staff/i);
  assert.match(accept, /insert into public\.staff_branches/i);
  assert.match(accept, /set status='expired',revoked_at=now\(\)[\s\S]+?'outcome','expired'[\s\S]+?return v_response/i);
});

test('v79 creates real evidence-backed onboarding with strict control modes', async () => {
  const sql = await read(sourcePath);
  for (const table of [
    'business_onboarding_checklists', 'business_onboarding_items',
    'business_onboarding_events',
  ]) assert.match(sql, new RegExp(`create table public\\.${table}`));
  for (const key of [
    'legal_identity', 'owner_access', 'billing_terms', 'core_workspace',
    'users_ready', 'first_value_configured', 'training_completed',
    'go_live_readiness', 'data_import_readiness', 'integration_readiness',
    'security_readiness', 'go_live_approved',
  ]) assert.match(sql, new RegExp(`'${key}'`));
  assert.match(sql, /'go_live_approved'[\s\S]+?'sa_approval',true,false/i);
  assert.match(functionBlock(sql, 'public', 'record_onboarding_manual_evidence_v79'),
    /verification_mode not in \('manual','sa_approval'\)/i);
  assert.match(functionBlock(sql, 'public', 'waive_onboarding_item_v79'),
    /item_key='go_live_approved'/i);
});

test('v79 freezes post-conversion v76 mutation and direct activation bypasses', async () => {
  const sql = await read(sourcePath);
  assert.match(sql, /sme_prospects_v79_lifecycle_guard/i);
  assert.match(sql, /sme_commercial_terms_v79_conversion_guard/i);
  assert.match(sql, /businesses_v79_conversion_guard/i);
  assert.match(sql, /branches_v79_activation_guard/i);
  assert.match(sql, /converted prospect lifecycle is controlled by v79 onboarding/i);
  assert.match(sql, /commercial terms are frozen after prospect conversion/i);
});

test('v79 activation is SA-only and requires refreshed mandatory evidence', async () => {
  const sql = await read(sourcePath);
  const fn = functionBlock(sql, 'public', 'activate_business_v79');
  assert.match(fn, /if not app\.is_super_admin\(\)/i);
  assert.match(fn, /refresh_onboarding_core_v79/i);
  assert.match(fn, /mandatory[\s\S]+status not in \('satisfied', 'waived'\)/i);
  assert.match(fn, /item_key = 'go_live_approved'[\s\S]+status = 'satisfied'/i);
  assert.match(fn, /current_stage_key <> 'onboarding'/i);
  assert.match(fn, /set active = true/i);
  assert.match(fn, /set current_stage_key = 'activated'/i);
  assert.doesNotMatch(fn, /update public\.subscriptions[\s\S]+status='active'/i);
});

test('v79 keeps tables closed and exposes only finite authenticated RPCs', async () => {
  const sql = await read(sourcePath);
  for (const table of [
    'workspace_owner_invitations', 'business_onboarding_checklists',
    'business_onboarding_items', 'business_onboarding_events',
  ]) {
    assert.match(
      sql,
      new RegExp(`alter table public\\.${table} enable row level security`, 'i')
    );
    assert.match(
      sql,
      new RegExp(`revoke all privileges on table public\\.${table} from public, anon, authenticated`, 'i')
    );
  }
  const names = [
    'convert_sme_prospect_v79', 'accept_workspace_owner_invite_v79',
    'reissue_workspace_owner_invite_v79', 'get_business_onboarding_v79',
    'start_business_onboarding_v79', 'refresh_business_onboarding_v79',
    'record_onboarding_manual_evidence_v79', 'waive_onboarding_item_v79',
    'block_business_onboarding_v79', 'unblock_business_onboarding_v79',
    'activate_business_v79',
  ];
  names.forEach(name => {
    assert.match(sql, new RegExp(`revoke all on function public\\.${name}`));
    assert.match(sql, new RegExp(`grant execute on function public\\.${name}[\\s\\S]+?to authenticated`));
  });
});

test('v79 rollback evidence covers conversion, invitation, blockers and activation', async () => {
  const sql = await read('db/tests/v79_conversion_onboarding.sql');
  assert.match(sql, /^begin;/m);
  assert.match(sql, /^rollback;/m);
  for (const evidence of [
    'duplicate conversion retry mutated state',
    'duplicate firm outcome mutated prospect',
    'raw invitation token was persisted',
    'wrong-email invitation acceptance succeeded',
    'checklist did not contain twelve mandatory items',
    'blocked onboarding became ready',
    'activation succeeded without every mandatory gate',
    'activation did not atomically update workspace, prospect and branch',
  ]) assert.match(sql, new RegExp(evidence));
});
