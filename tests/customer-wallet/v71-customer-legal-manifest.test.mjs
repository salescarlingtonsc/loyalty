import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root));
const [
  source,
  canonical
] = await Promise.all([
  read('db/migrations/20260726_frenly_v71_customer_legal_manifest.sql'),
  read('supabase/migrations/20260725120000_frenly_v71_customer_legal_manifest.sql')
]);
const sql = source.toString('utf8');

const approved = {
  terms: '8e113ffa36979cab83fcd84221d0baf1107921d030e353a60af428a1ebce09e4',
  privacy: '264045b09e5678c0f38ad48d2ce1e2cc9bdd9e1d11593b69b03a8c9c0c2edba2'
};

test('v71 canonical migration is the byte-identical post-v70 source', () => {
  assert.deepEqual(canonical, source);
  assert.match(sql, /^-- FRENLY v71\b/);
  assert.match(sql, /^begin;$/m);
  assert.match(sql, /^commit;$/m);
});

test('v71 preserves the exact owner-approved 19 July legal digests', () => {
  assert.match(sql, new RegExp(`'terms'[\\s\\S]*'2026-07-19'[\\s\\S]*'${approved.terms}'`));
  assert.match(sql, new RegExp(`'privacy'[\\s\\S]*'2026-07-19'[\\s\\S]*'${approved.privacy}'`));
  assert.ok((sql.match(/timestamptz '2026-07-19 00:00:00\+08:00'/g) || []).length >= 4);
});

test('v71 is exact-idempotent and aborts rather than overwriting a conflicting manifest', () => {
  assert.match(sql, /lock table app\.customer_legal_documents in share row exclusive mode/i);
  assert.ok((sql.match(/customer legal manifest conflicts with owner-approved/g) || []).length === 2);
  assert.match(sql, /on conflict \(document_key\) do nothing/i);
  assert.match(sql, /\)\s*<> 2 then[\s\S]*owner-approved customer legal manifest was not published exactly/i);
  assert.doesNotMatch(sql, /\b(?:update|delete from|truncate)\s+app\.customer_legal_documents\b/i);
  assert.doesNotMatch(sql, /on conflict[\s\S]{0,100}do update/i);
});
