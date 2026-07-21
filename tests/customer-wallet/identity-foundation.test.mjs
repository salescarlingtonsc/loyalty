import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const migrationPath = 'db/migrations/20260720_frenly_v30_customer_identity.sql';
const sqlTestPath = 'db/tests/v30_customer_identity.sql';

test('v30 creates an auth-bound platform identity without creating a business relationship', async () => {
  const sql = await read(migrationPath);
  assert.match(sql, /create table public\.customer_identities/i);
  assert.match(sql, /auth_user_id uuid not null unique references auth\.users\(id\) on delete restrict/i);
  assert.match(sql, /create table public\.customer_contact_proofs/i);
  assert.match(sql, /create table public\.customer_verified_contacts/i);
  assert.match(sql, /create table public\.customer_identity_audit_events/i);
  assert.match(sql, /customer_contact_proofs_identity_auth_fk[\s\S]*?foreign key \(identity_id, auth_user_id\)[\s\S]*?references public\.customer_identities\(id, auth_user_id\)/i);
  assert.match(sql, /customer_verified_contacts_proof_integrity_fk[\s\S]*?foreign key \(verification_proof_id, identity_id, auth_user_id, contact_type\)/i);
  assert.doesNotMatch(sql, /create table public\.customer_links/i);
  assert.doesNotMatch(sql, /insert into public\.customer_identities[\s\S]{0,300}from public\.clients/i);
  assert.doesNotMatch(sql, /customer_create_identity[\s\S]*?public\.clients/i);
});

test('v30 contact evidence is identity-bound, expiring, and never stores contact material', async () => {
  const sql = await read(migrationPath);
  assert.match(sql, /expires_at timestamptz not null/i);
  assert.match(sql, /customer_contact_proofs_expiry_check check \(expires_at > issued_at\)/i);
  assert.match(sql, /now\(\) \+ interval '15 minutes'/i);
  assert.match(sql, /contact_type text not null check \(contact_type = 'email'\)/i);
  assert.doesNotMatch(sql, /contact_fingerprint/i);
  assert.doesNotMatch(sql, /extensions\.digest/i);
  assert.doesNotMatch(sql, /customer_create_identity\([^)]*(?:phone|client|business)/i);
  assert.doesNotMatch(sql, /customer_create_identity[\s\S]*?app\.norm_phone/i);
});

test('v30 customer RPCs are self-derived authenticated-only security-definer functions', async () => {
  const sql = await read(migrationPath);
  assert.match(sql, /platform_feature_enabled\('customer_identity'\)/i,
    'identity reads and writes must fail closed behind the private server gate');
  for (const fn of ['customer_create_identity(text)', 'customer_get_identity()']) {
    assert.match(sql, new RegExp(`revoke all on function public\\.${fn.replace(/[()]/g, '\\$&')}\\s+from public, anon, authenticated`, 'i'));
    assert.match(sql, new RegExp(`grant execute on function public\\.${fn.replace(/[()]/g, '\\$&')} to authenticated`, 'i'));
  }
  assert.equal((sql.match(/v_actor uuid := auth\.uid\(\)/gi) ?? []).length, 2);
  assert.equal((sql.match(/authenticated customer session required/gi) ?? []).length, 2);
  for (const fn of ['customer_create_identity', 'customer_get_identity']) {
    assert.match(sql, new RegExp(
      `create or replace function public\\.${fn}[\\s\\S]*?security definer\\s+set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'`,
      'i'
    ));
  }
  assert.match(sql, /return jsonb_build_object\('identity', null\)/i);
  assert.match(sql, /request_hash\s+text[\s\S]*response\s+jsonb/i);
  assert.match(sql, /if v_response is not null then\s*return v_response/i,
    'same-key identity retries must return the original stored response');
  assert.doesNotMatch(sql, /return jsonb_build_object\([\s\S]{0,500}'(?:email|phone|contact_fingerprint|request_hash|verification_proof_id)'/i);
  assert.doesNotMatch(sql, /grant execute on function public\.customer_[^(]+\([^)]*\) to anon/i);
});

test('raw customer identity tables are RLS-protected and have no browser-role access', async () => {
  const sql = await read(migrationPath);
  for (const table of [
    'customer_identities', 'customer_contact_proofs',
    'customer_verified_contacts', 'customer_identity_audit_events'
  ]) {
    assert.match(sql, new RegExp(`alter table public\\.${table} enable row level security`, 'i'));
    assert.match(sql, new RegExp(`revoke all privileges on table public\\.${table}\\s+from public, anon, authenticated`, 'i'));
  }
  assert.doesNotMatch(sql, /create policy .*customer_/i);
});

test('v30 protects immutable mappings and audit evidence, with rollback adversarial coverage', async () => {
  const [sql, suite] = await Promise.all([read(migrationPath), read(sqlTestPath)]);
  assert.match(sql, /customer identity auth mapping is immutable/i);
  assert.match(sql, /customer contact proofs are append-only evidence/i);
  assert.match(sql, /customer identity audit events are append-only/i);
  assert.match(sql, /unique \(identity_id, event_type, idempotency_key\)/i);
  assert.match(suite, /^begin;/im);
  assert.match(suite, /^rollback;/im);
  for (const assertion of [
    'customer identity raw table ACL is open',
    'customer identity raw table has a PUBLIC grant',
    'create RPC exposed contact or request material',
    'phone proof was accepted by v30',
    'authenticated raw identity read unexpectedly succeeded',
    'staff user could not independently create a customer identity',
    'v30 identity creation must not create customer links',
    'v30 customer RPC unexpectedly references legacy clients'
  ]) assert.match(suite, new RegExp(assertion, 'i'));
});
