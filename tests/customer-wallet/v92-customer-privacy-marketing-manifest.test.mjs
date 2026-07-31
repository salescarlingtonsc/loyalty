import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const root=new URL('../..',import.meta.url);
const [source,canonical,privacy,rollbackSuite]=await Promise.all([
  readFile(new URL('db/migrations/20260728_nestly_v92_customer_privacy_marketing_manifest.sql',root)),
  readFile(new URL('supabase/migrations/20260728110000_nestly_v92_customer_privacy_marketing_manifest.sql',root)),
  readFile(new URL('app/privacy.html',root)),
  readFile(new URL('db/tests/v92_customer_privacy_marketing_manifest.sql',root),'utf8')
]);
const sql=source.toString('utf8');
const privacyDigest=createHash('sha256').update(privacy).digest('hex');
const approvedPrivacyDigest='994400cadc703134d9c8bd3868fe054f94e37153c47c2d2e688064bdc75138c9';

test('v92 source and canonical migration are byte-identical',()=>{
  assert.deepEqual(canonical,source);
  assert.match(sql,/^-- NESTLY v92\b/);
  assert.match(sql,/^begin;$/m);
  assert.match(sql,/^commit;$/m);
});

test('v92 publishes the exact live Privacy Notice digest without changing Terms',()=>{
  assert.equal(privacyDigest,approvedPrivacyDigest);
  assert.match(sql,new RegExp(`'privacy'[\\s\\S]*'2026-07-28'[\\s\\S]*'${approvedPrivacyDigest}'`));
  assert.doesNotMatch(sql,/update app\.customer_legal_documents[\\s\\S]{0,300}document_key = 'terms'/i);
});

test('v92 is exact-predecessor idempotent and preserves acceptance history',()=>{
  assert.match(sql,/lock table app\.customer_legal_documents in share row exclusive mode/i);
  assert.match(sql,/'2026-07-26'[\s\S]*e3b82c000904491591d1d077052099b50f9a25e5a1ebd1e2a587da0789e274b0/i);
  assert.match(sql,/'2026-07-28'[\s\S]*994400cadc703134d9c8bd3868fe054f94e37153c47c2d2e688064bdc75138c9/i);
  assert.doesNotMatch(sql,/\b(?:delete from|truncate)\s+app\.customer_legal_documents\b/i);
  assert.doesNotMatch(sql,/\b(?:insert into|update|delete from|truncate)\s+public\.customer_legal_acceptances\b/i);
});

test('v92 does not broaden old platform-news consent and records immutable versioned evidence',()=>{
  assert.match(sql,/update public\.customer_registration_preferences[\s\S]*set platform_marketing_opted_in = false/i);
  assert.match(sql,/create table public\.customer_platform_marketing_consent_events/i);
  assert.match(sql,/scope_version text not null check \(scope_version = '2026-07-28-selected-partners-v1'\)/i);
  assert.match(sql,/privacy_sha256 text not null check \(privacy_sha256 ~ '\^\[0-9a-f\]\{64\}\$'\)/i);
  assert.match(sql,/source text not null check \(source in \('signup', 'customer_profile'\)\)/i);
  assert.match(sql,/customer_platform_marketing_consent_immutable[\s\S]*before update or delete/i);
  assert.match(sql,/alter table public\.customer_platform_marketing_consent_events enable row level security/i);
  assert.match(sql,/revoke all privileges on table public\.customer_platform_marketing_consent_events\s+from public, anon, authenticated/i);
});

test('v92 preference readers and writers are self-scoped, idempotent and authenticated-only',()=>{
  assert.match(sql,/create or replace function public\.customer_get_platform_marketing_preference\(\)/i);
  assert.match(sql,/where p\.auth_user_id = v_actor/i);
  assert.match(sql,/create or replace function public\.customer_set_platform_marketing_preference\(\s*p_opted_in boolean,\s*p_idempotency_key text\s*\)/i);
  assert.match(sql,/v_identity := app\.v31_current_identity\(\)/i);
  assert.match(sql,/pg_advisory_xact_lock/i);
  assert.match(sql,/idempotency key was already used for a different marketing preference/i);
  assert.match(sql,/grant execute on function public\.customer_get_platform_marketing_preference\(\)\s+to authenticated/i);
  assert.match(sql,/grant execute on function public\.customer_set_platform_marketing_preference\(boolean, text\)\s+to authenticated/i);
  assert.match(sql,/revoke all on function public\.customer_get_platform_marketing_preference\(\)\s+from public, anon, authenticated/i);
  assert.match(sql,/revoke all on function public\.customer_set_platform_marketing_preference\(boolean, text\)\s+from public, anon, authenticated/i);
});

test('v92 behaviorally reserves a no-op Save key, replays it, and rejects changed reuse',()=>{
  assert.match(sql,/new\.platform_marketing_opted_in is not distinct from old\.platform_marketing_opted_in\s+and v_idempotency_key is null/i);
  assert.match(rollbackSuite,/customer_set_platform_marketing_preference\(false, v_key\)/i);
  assert.match(rollbackSuite,/customer_set_platform_marketing_preference\(true, v_key\)/i);
  assert.match(rollbackSuite,/when unique_violation then null/i);
  assert.match(rollbackSuite,/idempotency_key = v_key\s+and not e\.opted_in/i);
});
