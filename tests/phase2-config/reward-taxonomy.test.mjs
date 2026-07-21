import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const path = 'db/migrations/20260720_frenly_v28_firm_reward_taxonomy.sql';

test('taxonomy backfills keep created_by explicitly UUID typed', async () => {
  const sql = await read(path);
  assert.equal((sql.match(/null::uuid/gi) || []).length, 2);
});

test('v28 separates merchant labels from controlled fulfillment behavior', async () => {
  const sql = await read(path);
  assert.match(sql, /create table public\.firm_reward_taxonomy/i);
  assert.match(sql, /fulfillment_kind in \('discount_pct','free_item','credit'\)/i);
  assert.match(sql, /reward fulfillment behavior is immutable/i);
  assert.match(sql, /retired reward types cannot be selected/i);
  assert.doesNotMatch(sql, /drop table/i);
});

test('legacy retention types backfill into same-business taxonomy references', async () => {
  const sql = await read(path);
  assert.match(sql, /select distinct rp\.business_id[\s\S]*rp\.reward_type/i);
  assert.match(sql, /foreign key \(reward_taxonomy_id, business_id\)[\s\S]*firm_reward_taxonomy\(id, business_id\)/i);
  assert.match(sql, /foreign key \(program_id, business_id\)[\s\S]*retention_programs\(id, business_id\)/i);
});

test('issued grants snapshot label and machine behavior', async () => {
  const sql = await read(path);
  for (const column of ['reward_taxonomy_id','reward_label','fulfillment_kind']) {
    assert.match(sql, new RegExp(`add column ${column}`, 'i'));
  }
  assert.match(sql, /create trigger trg_snapshot_reward_grant_taxonomy/i);
  assert.match(sql, /new\.reward_label := v_label/i);
  assert.match(sql, /new\.fulfillment_kind := v_kind/i);
});

test('taxonomy rows are tenant isolated and internal triggers are not executable', async () => {
  const sql = await read(path);
  assert.match(sql, /enable row level security/i);
  assert.match(sql, /app\.is_salon_member\(business_id\)/i);
  assert.match(sql, /app\.is_salon_owner\(business_id\)/i);
  assert.equal((sql.match(/revoke execute on function app\.[^;]+from public, anon, authenticated/gi) || []).length, 3);
});

test('retention UI uses firm labels while preserving controlled machine behavior', async () => {
  const app = await read('app/index.html');
  assert.match(app, /from\('firm_reward_taxonomy'\)\.select\('id,label,fulfillment_kind,active,sort'\)/i);
  assert.match(app, /data-kind="\$\{t\.fulfillment_kind\}"/i);
  assert.match(app, /reward_taxonomy_id:\$\('rt'\)\.value/i);
  assert.match(app, /firm_reward_taxonomy\(label,fulfillment_kind(?:,active,sort)?\)/i);
  assert.match(app, /r\.reward_label\|\|'Reward'/i);
  assert.match(app, /sb\.rpc\('save_reward_taxonomy'/i);
});
