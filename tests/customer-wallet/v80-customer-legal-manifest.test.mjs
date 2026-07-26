import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root));
const [
  source,
  canonical,
  terms,
  privacy
] = await Promise.all([
  read('db/migrations/20260726_nestly_v80_customer_legal_manifest.sql'),
  read('supabase/migrations/20260726150000_nestly_v80_customer_legal_manifest.sql'),
  read('app/terms.html'),
  read('app/privacy.html')
]);
const sql = source.toString('utf8');
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

const approved = {
  terms: '12aff22e35449a889c75d7cb3705a0f7c58a5de333a8b25a81128e89b76b4618',
  privacy: 'e3b82c000904491591d1d077052099b50f9a25e5a1ebd1e2a587da0789e274b0'
};

test('v80 canonical migration is byte-identical to its Nestly source', () => {
  assert.deepEqual(canonical, source);
  assert.match(sql, /^-- NESTLY v80\b/);
  assert.match(sql, /^begin;$/m);
  assert.match(sql, /^commit;$/m);
});

test('v80 approved digests are exact SHA-256 hashes of the live Nestly legal pages', () => {
  assert.equal(sha256(terms), approved.terms);
  assert.equal(sha256(privacy), approved.privacy);
  assert.match(sql, new RegExp(`'terms'[\\s\\S]*'2026-07-26'[\\s\\S]*'${approved.terms}'`));
  assert.match(sql, new RegExp(`'privacy'[\\s\\S]*'2026-07-26'[\\s\\S]*'${approved.privacy}'`));
  assert.ok((sql.match(/timestamptz '2026-07-26 00:00:00\+08:00'/g) || []).length >= 6);
});

test('v80 advances only an exact v71 predecessor and preserves acceptance history', () => {
  assert.match(sql, /lock table app\.customer_legal_documents in share row exclusive mode/i);
  assert.ok((sql.match(/conflicts with owner-approved Nestly/g) || []).length === 2);
  assert.ok((sql.match(/update app\.customer_legal_documents/g) || []).length === 2);
  assert.match(sql, /\)\s*<> 2 then[\s\S]*owner-approved Nestly customer legal manifest was not published exactly/i);
  assert.doesNotMatch(sql, /\b(?:delete from|truncate)\s+app\.customer_legal_documents\b/i);
  assert.doesNotMatch(sql, /\b(?:insert into|update|delete from|truncate)\s+public\.customer_legal_acceptances\b/i);
});
