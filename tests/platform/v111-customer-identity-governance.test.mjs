import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const read = (path) => readFile(new URL(`../../${path}`, import.meta.url), 'utf8');
const sourcePath = 'db/migrations/20260729_nestly_v111_customer_identity_governance.sql';
const mirrorPath =
  'supabase/migrations/20260729194101_nestly_v111_customer_identity_governance.sql';
const sqlTestPath = 'db/tests/v111_customer_identity_governance.sql';
const concurrencyPath = 'db/tests/v111_customer_identity_governance_concurrency.sh';

test('v111 migration pair is byte-identical and never rewrites customer truth', async () => {
  const [source, mirror] = await Promise.all([read(sourcePath), read(mirrorPath)]);
  assert.equal(source, mirror);
  assert.match(source, /^-- NESTLY v111 — CUSTOMER IDENTITY GOVERNANCE/m);
  assert.doesNotMatch(
    source,
    /(?:update|delete\s+from)\s+public\.(?:clients|sales|points_ledger|reward_grants|loyalty_redemptions|customer_links)\b/i,
  );
  assert.doesNotMatch(source, /drop\s+(?:table|function|schema)/i);
});

test('identity correction state is tenant-bound, append-only and browser read-only', async () => {
  const source = await read(sourcePath);
  for (const table of [
    'customer_identity_proposals_v111',
    'customer_identity_proofs_v111',
    'customer_identity_decisions_v111',
    'customer_identity_attribution_events_v111',
    'customer_identity_request_ledger_v111',
  ]) {
    assert.match(source, new RegExp(`alter table public\\.${table} enable row level security`, 'i'));
  }
  assert.match(source, /foreign key \(source_client_id,business_id\)[\s\S]*clients\(id,business_id\)/i);
  assert.match(source, /foreign key \(target_client_id,business_id\)[\s\S]*clients\(id,business_id\)/i);
  assert.match(
    source,
    /foreign key \(target_link_id,business_id,target_client_id\)[\s\S]*customer_links\(id,business_id,client_id\)/i,
  );
  assert.match(
    source,
    /foreign key \(target_link_id,business_id,target_identity_id\)[\s\S]*customer_links\(id,business_id,identity_id\)/i,
  );
  assert.match(source, /foreign key \(branch_id,business_id\)[\s\S]*branches\(id,business_id\)/i);
  assert.match(
    source,
    /foreign key \(proposal_id,business_id\)[\s\S]*customer_identity_proposals_v111\(id,business_id\)/i,
  );
  assert.match(
    source,
    /foreign key \(proof_id,proposal_id,business_id\)[\s\S]*customer_identity_proofs_v111\(id,proposal_id,business_id\)/i,
  );
  assert.match(
    source,
    /foreign key \(prior_decision_id,proposal_id,business_id\)[\s\S]*customer_identity_decisions_v111\(id,proposal_id,business_id\)/i,
  );
  assert.match(
    source,
    /foreign key \(decision_id,proposal_id,business_id\)[\s\S]*customer_identity_decisions_v111\(id,proposal_id,business_id\)/i,
  );
  assert.match(source, /v111_append_only_guard/i);
  assert.match(source, /identity proposal scope and evidence are immutable/i);
  assert.match(
    source,
    /revoke all privileges on table[\s\S]*customer_identity_request_ledger_v111[\s\S]*from public,anon,authenticated/i,
  );
});

test('proof validation fails closed for cross-business and ambiguous identity evidence', async () => {
  const source = await read(sourcePath);
  const contactProof = source.match(
    /create or replace function app\.v111_validate_contact_pair[\s\S]+?\nend\n\$\$;/i,
  )?.[0] || '';
  assert.match(contactProof, /link\.business_id=v_proposal\.business_id/i);
  assert.match(contactProof, /link\.client_id=v_proposal\.target_client_id/i);
  assert.match(contactProof, /link\.state='verified'/i);
  assert.match(contactProof, /email_confirmed_at is not null/i);
  assert.match(contactProof, /phone_confirmed_at is not null/i);
  assert.match(contactProof, /v_candidate_count<>1/i);
  assert.match(contactProof, /proof is ambiguous or matches multiple candidate/i);
  assert.match(source, /firm invitation evidence is invalid, expired, or cross-business/i);
  assert.match(source, /source customer already has a verified identity; no automatic merge is allowed/i);
  assert.match(source, /invitation proof is no longer unambiguous/i);
  assert.match(source, /source customer gained a verified identity after proof/i);
  assert.match(source, /identity_row\.status='active'/i);
  assert.match(source, /target customer needs one active verified business identity/i);
});

test('active corrections are one-hop and serialize both participating clients', async () => {
  const source = await read(sourcePath);
  assert.match(source, /app\.v111_effective_client_id\(\s*p_business uuid,p_client uuid/i);
  assert.match(
    source,
    /current\.effective_client_id in \(p_source_client,p_target_client\)/i,
  );
  assert.match(
    source,
    /current\.effective_client_id in \(\s*v_proposal\.source_client_id,v_proposal\.target_client_id/i,
  );
  assert.match(source, /least\(p_source_client::text,p_target_client::text\)/i);
  assert.match(source, /greatest\(p_source_client::text,p_target_client::text\)/i);
  assert.match(source, /source or target already participates in an active identity correction/i);
});

test('verified customer-link writers share the v111 client lock and fail active-source relinking', async () => {
  const source = await read(sourcePath);
  const guard = source.match(
    /create or replace function app\.v111_guard_verified_customer_link\(\)[\s\S]+?\nend\n\$\$;/i,
  )?.[0] || '';
  assert.match(
    source,
    /create trigger customer_links_v111_verified_source_guard[\s\S]*before insert or update of state on public\.customer_links/i,
  );
  assert.match(guard, /new\.state<>'verified'/i);
  assert.match(
    guard,
    /pg_advisory_xact_lock\(hashtextextended\(\s*'v111:client:'\|\|new\.business_id\|\|':'\|\|new\.client_id::text,0\s*\)\)/i,
  );
  assert.match(guard, /customer_identity_current_attribution_v111/i);
  assert.match(guard, /current\.source_client_id=new\.client_id/i);
  assert.match(guard, /current\.effective_client_id<>current\.source_client_id/i);
  assert.match(
    guard,
    /verified link cannot be created for a customer with an active identity correction/i,
  );
  assert.match(
    source,
    /revoke all on function app\.v111_guard_verified_customer_link\(\)[\s\S]*from public,anon,authenticated/i,
  );
});

test('branch staff may propose while only owner or global authority may decide', async () => {
  const source = await read(sourcePath);
  assert.match(source, /app\.has_perm\(\$1,'view_sales'\)/i);
  assert.match(source, /app\.can_see_branch\(\$1,\$2\)/i);
  assert.match(source, /app\.is_super_admin\(\) or app\.is_salon_owner\(\$1\)/i);
  assert.match(source, /owner or global business authority is required to approve/i);
  assert.match(source, /owner or global business authority is required to reject/i);
  assert.match(source, /owner or global business authority is required to reverse/i);
});

test('every mutation binds UUID idempotency to a canonical request hash and exact receipt', async () => {
  const source = await read(sourcePath);
  assert.match(source, /unique\(actor_auth_user_id,idempotency_key\)/i);
  assert.match(source, /app\.v111_request_hash\(p_payload jsonb\)/i);
  assert.match(source, /idempotency key is required/g);
  assert.match(source, /pg_advisory_xact_lock\(hashtextextended\([\s\S]*v111:request:/i);
  assert.match(source, /return v_existing\.receipt/g);
  assert.match(source, /idempotency key was already used for a different identity mutation/g);
  for (const operation of ['propose', 'attach_proof', 'approve', 'reject', 'reverse']) {
    assert.match(
      source,
      new RegExp(`values\\(v_actor,[\\s\\S]{0,180}'${operation}',p_idempotency_key,v_hash,v_receipt\\)`, 'i'),
    );
  }
});

test('every receipt replay rechecks current business authority before returning', async () => {
  const source = await read(sourcePath);
  assert.match(
    source,
    /v111_can_propose\(p_business,p_branch\)[\s\S]{0,900}select \* into v_existing from public\.customer_identity_request_ledger_v111/i,
  );
  assert.match(
    source,
    /v111_can_propose\(v_proposal\.business_id,v_proposal\.branch_id\)[\s\S]{0,1600}select \* into v_existing from public\.customer_identity_request_ledger_v111/i,
  );
  assert.ok(
    (
      source.match(
        /v111_can_decide\(v_proposal\.business_id\)[\s\S]{0,900}select \* into v_existing from public\.customer_identity_request_ledger_v111/gi,
      ) ?? []
    ).length >= 3,
  );
});

test('approval and reversal append exact attribution without deleting source history', async () => {
  const source = await read(sourcePath);
  assert.match(source, /'correction_approved'/i);
  assert.match(source, /'correction_reversed'/i);
  assert.match(source, /v_proposal\.source_client_id,v_proposal\.target_client_id/i);
  assert.match(source, /v_proposal\.target_client_id,[\s\S]*v_proposal\.source_client_id,'correction_reversed'/i);
  assert.match(source, /source_sales/i);
  assert.match(source, /source_points/i);
  assert.match(source, /source_reward_grants/i);
  assert.match(source, /source_redemptions/i);
  assert.match(source, /customer_identity_current_attribution_v111/i);
});

test('rollback-only SQL covers replay, scope, ambiguity, terminal convergence and preservation', async () => {
  const sql = await read(sqlTestPath);
  assert.match(sql, /^-- Rollback-only v111/m);
  assert.match(sql, /\nbegin;\n/i);
  assert.match(sql, /\nrollback;\s*$/i);
  for (const phrase of [
    'propose exact replay',
    'proof exact replay',
    'approve exact replay',
    'reject exact replay',
    'reverse exact replay',
    'changed-payload idempotency conflict',
    'cross-business proposal',
    'ambiguous proof',
    'branch-scoped proposal',
    'unauthorized terminal operation',
    'firm-invitation proof',
    'firm_invitation happy path',
    'disabled target identity',
    'active correction chain',
    'active correction cycle',
    'active-source verified link',
    'v107 lifecycle did not consume approved v111 attribution',
    'repeated terminal operation',
    'append-only evidence',
    'source financial history',
  ]) {
    assert.match(sql, new RegExp(phrase, 'i'));
  }
});

test('true two-session harness covers both v111 lock orderings on disposable databases only', async () => {
  const shell = await read(concurrencyPath);
  assert.match(shell, /V111_CONFIRM_DISPOSABLE_DB/);
  assert.match(shell, /DATABASE_URL must not contain embedded password material/i);
  assert.match(shell, /v111:client:/);
  assert.match(shell, /approval-first/i);
  assert.match(shell, /link-first/i);
  assert.match(shell, /customer_links_v111_verified_source_guard/i);
  assert.match(shell, /verified link cannot be created for a customer with an active identity correction/i);
  assert.match(shell, /source customer gained a verified identity after proof/i);
});
