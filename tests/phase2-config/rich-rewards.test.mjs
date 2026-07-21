import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');

/*
 * v27 frontend contract assumptions:
 * - loyalty_rewards keeps the v23 economic columns and adds the rich reward
 *   fields used below; customer_name is separate from the internal name.
 * - The existing allowlisted config draft workflow receives a reward envelope
 *   plus branch/service/product IDs and writes normalized, versioned eligibility
 *   rows transactionally before publication.
 * - Empty eligibility ID lists mean unrestricted eligibility. The browser
 *   never sends a uuid-array column or writes normalized tables independently.
 * - Only credit and manual_item are exposed until another fulfilment kind has
 *   a complete financial, tender, and reversal contract.
 */

test('shared reward snapshot trigger safely handles each table row type', async () => {
  const sql = await read('db/migrations/20260720_frenly_v27_rich_rewards.sql');
  assert.match(sql, /v_row := case when tg_op = 'DELETE' then to_jsonb\(old\) else to_jsonb\(new\) end/i);
  assert.match(sql, /v_row ->> 'reward_version_id'/i,
    'table-specific trigger fields must be read without composite dereference failures');
});

test('reward editor exposes simple customer-facing fields and progressive disclosure', async () => {
  const app = await read('app/index.html');
  for (const field of [
    'Customer-facing name',
    'What the customer gets',
    'cost_points',
    'Estimated business cost',
    'Reward expires after (days)',
    'Uses per customer',
    'Image reference',
    'Internal name'
  ]) assert.match(app, new RegExp(field.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i'));
  assert.match(app, /<details><summary>More options<\/summary>/i);
  assert.match(app, /data-reward-elig="\$\{key\}"/i);
  for (const key of ['branch', 'service', 'product']) assert.match(app, new RegExp(`'${key}'`));
});

test('fulfilment choices are controlled and preserve the existing credit contract', async () => {
  const app = await read('app/index.html');
  assert.match(app, /value="manual_item"[^>]*>Manual item or benefit/i);
  assert.match(app, /value="credit"[^>]*>Store credit/i);
  assert.match(app, /fulfillment_kind:kind/i);
  assert.match(app, /credit_cents:kind==='credit'?/i);
  assert.doesNotMatch(app, /<option value="(?:discount|percentage|custom|cash)"/i);
});

test('saving a reward uses the allowlisted version workflow and never deletes reward history', async () => {
  const app = await read('app/index.html');
  assert.match(app, /sb\.rpc\('create_loyalty_config_draft'/i);
  assert.match(app, /sb\.rpc\('save_loyalty_config_draft'/i);
  assert.match(app, /p_expected_snapshot_hash:draftSnapshotHash\|\|null/i);
  assert.match(app, /sb\.rpc\('publish_loyalty_config'/i);
  assert.match(app, /reward_branch_ids:selected\('branch'\)/i);
  assert.match(app, /reward_service_ids:selected\('service'\)/i);
  assert.match(app, /reward_product_ids:selected\('product'\)/i);
  assert.ok(app.includes('entitlement_expiry_days:expiry>0?expiry:null'));
  assert.ok(app.includes('usage_limit:usage>0?usage:null'));
  assert.ok(app.includes("active:archive?false:$(\'rwActive\').checked"));
  assert.doesNotMatch(app, /from\('loyalty_rewards'\)\.(?:insert|update|delete)\(/i);
  assert.doesNotMatch(app, /\.rwDel\b|id="rwDel"/i);
});

test('eligibility uses relational table reads and empty selections mean all', async () => {
  const app = await read('app/index.html');
  assert.match(app, /sb\.rpc\('get_loyalty_reward_draft'/i);
  assert.match(app, /draft\?\.rewards\|\|\[\]/);
  assert.match(app, /flatMap\(r=>\(r\.eligibility\?\.branches\|\|\[\]\)/);
  for (const table of ['loyalty_reward_branches', 'loyalty_reward_services', 'loyalty_reward_products']) {
    assert.match(app, new RegExp(`from\\('${table}'\\)`));
  }
  assert.match(app, /Leave blank for all/);
  assert.match(app, /No eligibility rows means unrestricted eligibility/);
  assert.doesNotMatch(app, /eligible_(?:branch|service|product)_ids\s*:/i);
});

test('v36 isolates draft reward reads and removes browser access to stale two-argument saves', async () => {
  const migration = await read('db/migrations/20260720_frenly_v36_safe_draft_reward_editor.sql');
  const securityMigration = await read('db/migrations/20260719_frenly_v21_security_hardening.sql');
  const securityTest = await read('db/tests/v21_security_hardening.sql');
  assert.match(migration, /create or replace function public\.get_loyalty_reward_draft\(p_config_version uuid\)/i);
  assert.match(migration, /where rv\.config_version_id = v_header\.id/i);
  assert.match(migration, /where e\.reward_version_id = rv\.id[\s\S]*and e\.reward_id = rv\.reward_id[\s\S]*and e\.business_id = rv\.business_id/i);
  assert.match(migration, /drop function public\.save_loyalty_config_draft\(uuid,jsonb\)/i);
  assert.match(migration, /p_expected_snapshot_hash text\s*\)/i,
    'the browser RPC must require its optimistic-lock argument so the private two-argument wrapper is unambiguous');
  assert.match(migration, /using errcode = '40001'/i);
  assert.match(migration, /create or replace function public\.save_loyalty_config_draft\(p_version uuid, p_config jsonb\)/i);
  assert.match(migration, /revoke all on function public\.save_loyalty_config_draft\(uuid,jsonb\)\s+from public, anon, authenticated/i);
  assert.match(migration, /revoke all on function public\.get_loyalty_reward_draft\(uuid\) from public, anon/i);
  assert.match(migration, /grant execute on function public\.get_loyalty_reward_draft\(uuid\) to authenticated/i);
  assert.match(securityMigration, /'get_loyalty_reward_draft'/);
  assert.match(securityTest, /'get_loyalty_reward_draft'/);
});

test('customer redemption surfaces the customer-facing label when v27 is present', async () => {
  const app = await read('app/index.html');
  assert.match(app, /r\.customer_name\|\|r\.name/);
  assert.match(app, /sb\.rpc\('redeem_reward_at_context'/i);
  for (const key of ['branch','service','product']) {
    assert.match(app, new RegExp(`p_${key}:context\\('${key}'\\)`));
  }
});

test('legacy zero-credit claims retain manual fulfillment meaning', async () => {
  const sql = await read('db/migrations/20260720_frenly_v27_rich_rewards.sql');
  assert.match(sql, /fulfillment_kind\s*=\s*case when x\.credit_cents > 0 then 'credit' else 'manual_item' end/i);
  assert.match(sql, /create or replace function public\.redeem_reward\([^)]*p_idempotency_key text default null\)[\s\S]*app\.redeem_reward_core/i,
    'v27 must preserve the deployed default while its core rejects omitted/short keys');
  assert.match(sql, /alter table public\.products\s+add constraint products_id_business_uk unique \(id, business_id\)[\s\S]*foreign key \(product_id, business_id\)\s+references public\.products\(id, business_id\)/i,
    'product eligibility must have a tenant-safe composite parent key before its foreign key');
});
