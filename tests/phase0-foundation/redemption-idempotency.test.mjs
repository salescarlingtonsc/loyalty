import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const migrationPath = 'db/migrations/20260720_frenly_v24a_redemption_idempotency.sql';

test('both redemption paths reserve one immutable operation key', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /create table if not exists public\.loyalty_operations/i);
  assert.match(migration, /unique\s*\(business_id, operation_type, idempotency_key\)/i);
  assert.match(migration, /request_hash = md5\(request_payload::text\)/i);
  assert.match(migration, /loyalty_operations is append-only: DELETE is not permitted/i);
  assert.equal((migration.match(/on conflict \(business_id, operation_type, idempotency_key\) do nothing/gi) || []).length, 2);
  assert.equal((migration.match(/if v_operation\.status = 'completed' then return v_operation\.result::json/gi) || []).length, 2);
  assert.equal((migration.match(/set status = 'completed', result = v_result::jsonb, completed_at = now\(\)/gi) || []).length, 2);
});

test('keyless classic redemption is no longer application executable', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /create or replace function public\.redeem_points\(\s*p_business uuid,\s*p_client uuid,\s*p_idempotency_key text\s*\)/i);
  assert.match(migration, /create or replace function public\.redeem_reward\([\s\S]*p_idempotency_key text default null[\s\S]*if p_idempotency_key is null or length\(btrim\(p_idempotency_key\)\) < 8/i,
    'redeem_reward must retain the deployed default for replacement compatibility but reject omitted keys at runtime');
  assert.match(migration, /revoke all on function public\.redeem_points\(uuid, uuid\) from public, anon, authenticated/i);
  assert.match(migration, /grant execute on function public\.redeem_points\(uuid, uuid, text\) to authenticated/i);
  assert.match(migration, /revoke all on function public\.redeem_reward\(uuid, uuid, uuid, text\) from public, anon/i);
  assert.doesNotMatch(migration, /grant execute on function public\.redeem_points\(uuid, uuid\) to authenticated/i);
});

test('normal merchant redemption is scanner-only in the shipped browser', async () => {
  const app = await read('app/index.html');
  const calls = [...app.matchAll(/sb\.rpc\('(redeem_points|redeem_reward(?:_at_context)?)',\{([\s\S]*?)\}\)/g)];
  assert.equal(calls.length, 0,
    'the browser must not expose a direct redemption writer outside the branch-scoped merchant scanner');
  assert.match(app,/Customer redemptions are completed only after scanning the customer’s pending QR in Quick Earn/);
  assert.match(app,/Open Quick Earn scanner/);
  const tillStart = app.indexOf('async function tillPage(){');
  const tillEnd = app.indexOf('async function salesPage(){',tillStart);
  const till=app.slice(tillStart,tillEnd);
  assert.doesNotMatch(till,/redeem_points|redeem_reward(?:_at_context)?|redemptionIdem/);
  assert.match(till,/openMerchantRedemptionScanner/,
    'Quick earn may open only the merchant scanner for an already-pending customer QR redemption');
  assert.match(app,/merchant_scan_redemption_qr_v117/);
});

test('operation table is RLS-protected and has no client write grant', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /alter table public\.loyalty_operations enable row level security/i);
  assert.match(migration, /revoke all privileges on table public\.loyalty_operations from public, anon, authenticated/i);
  assert.match(migration, /grant select on table public\.loyalty_operations to authenticated/i);
  assert.doesNotMatch(migration, /grant (?:insert|update|delete|all)\b[^;]*loyalty_operations[^;]*authenticated/i);
});
