import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const migrationPath = 'db/migrations/20260720_frenly_v26_immutable_config_versions.sql';

test('v26 creates typed version headers and loyalty rows', async () => {
  const sql = await read(migrationPath);
  assert.match(sql, /create table public\.firm_config_versions/i);
  assert.match(sql, /create table public\.loyalty_program_versions/i);
  assert.match(sql, /unique \(business_id, version_no\)/i);
  assert.match(sql, /where status = 'published'/i);
  assert.match(sql, /foreign key \(based_on_version_id, business_id\)/i);
  assert.doesNotMatch(sql, /earn_rate_bps/i, 'v23g retired earn_rate_bps from the live schema');
  assert.doesNotMatch(sql, /drop table/i);
});

test('existing configuration is backfilled as v1 without changing live values', async () => {
  const sql = await read(migrationPath);
  assert.match(sql, /select lp\.business_id, 1, lp\.configuration_status, 'legacy_v1'/i);
  assert.match(sql, /update public\.loyalty_programs lp\s+set current_config_version_id = fv\.id/i);
  assert.match(sql, /update public\.businesses b\s+set active_config_version_id = fv\.id/i);
  assert.match(sql, /set_config\('app\.sales_backfill','v26_config_version',true\)[\s\S]*update public\.sales[\s\S]*set_config\('app\.sales_backfill','',true\)/i);
  for (const table of ['points_ledger', 'credit_ledger']) {
    const guard = `trg_${table}_append_only`;
    assert.match(sql, new RegExp(`alter table public\\.${table} disable trigger ${guard}[\\s\\S]*update public\\.${table}[\\s\\S]*alter table public\\.${table} enable trigger ${guard}`, 'i'),
      `${table} provenance backfill must restore its named append-only guard`);
  }
});

test('event tables stamp the locked active version and reversals inherit source version', async () => {
  const sql = await read(migrationPath);
  for (const table of ['sales','points_ledger','points_batches','credit_ledger','loyalty_redemptions','reward_grants']) {
    assert.match(sql, new RegExp(`alter table public\\.${table} add column config_version_id`));
  }
  assert.equal((sql.match(/foreign key \(config_version_id, business_id\) references public\.firm_config_versions\(id, business_id\)/gi) || []).length, 6);
  assert.match(sql, /perform 1 from public\.businesses where id = v_business for share/i);
  assert.match(sql, /tg_table_name = 'sales'[\s\S]*to_jsonb\(new\) ->> 'reversal_of'[\s\S]*if v_reversal_of is not null/i);
  assert.match(sql, /reversal must retain the original sale config version/i);
  assert.match(sql, /tg_table_name in \('points_ledger','points_batches','credit_ledger'\)[\s\S]*to_jsonb\(new\) ->> 'sale_id'[\s\S]*if v_sale_id is not null/i);
  assert.match(sql, /ledger child must retain its linked sale config version/i);
});

test('draft, save and publication are owner-scoped with immutable published rows', async () => {
  const sql = await read(migrationPath);
  assert.match(sql, /create or replace function public\.create_loyalty_config_draft/i);
  assert.match(sql, /select v_id,business_id,kind,loyalty_model,active,earn_points_per_dollar/i,
    'a draft must preserve the base activation state so retention-only edits cannot disable loyalty');
  assert.match(sql, /create or replace function public\.save_loyalty_config_draft/i);
  assert.match(sql, /create or replace function public\.publish_loyalty_config/i);
  assert.match(sql, /if v_header\.status <> 'draft'/i);
  assert.match(sql, /published configuration rows are immutable/i);
  assert.match(sql, /stamp_target=case when p_config \? 'stamp_target'/i);
  assert.match(sql, /set status='superseded',superseded_at=now\(\)/i);
  assert.match(sql, /set status='published',published_at=now\(\)/i);
  assert.match(sql, /'PUBLISH_CONFIG'/i);
});

test('new-business programs get draft v1 and the editor publishes through RPCs', async () => {
  const [sql, app] = await Promise.all([read(migrationPath), read('app/index.html')]);
  assert.match(sql, /create trigger trg_seed_loyalty_config_version/i);
  assert.match(sql, /after insert on public\.loyalty_programs/i);
  assert.match(app, /sb\.rpc\('create_loyalty_config_draft'/);
  assert.match(app, /sb\.rpc\('save_loyalty_config_draft'/);
  assert.match(app, /sb\.rpc\('publish_loyalty_config'/);
  assert.doesNotMatch(app, /from\('loyalty_programs'\)\.update\(row\)/);
});

test('version tables are RLS protected and mutation RPCs deny anonymous callers', async () => {
  const sql = await read(migrationPath);
  assert.equal((sql.match(/enable row level security/gi) || []).length, 3);
  assert.match(sql, /revoke all on public\.firm_config_versions from public, anon, authenticated/i);
  assert.match(sql, /revoke all on public\.loyalty_program_versions from public, anon, authenticated/i);
  assert.equal((sql.match(/revoke all on function public\.(?:create|save|publish)_loyalty_config[^;]+from public,anon/gi) || []).length, 3);
});

test('live loyalty projection cannot bypass draft publication', async () => {
  const sql = await read(migrationPath);
  assert.match(sql, /drop policy if exists loyalty_programs_write/i);
  assert.match(sql, /revoke insert, update, delete, truncate on table public\.loyalty_programs[\s\S]*from public, anon, authenticated/i);
});

test('tier multipliers are immutable configuration, not direct browser writes', async () => {
  const [sql, app] = await Promise.all([read(migrationPath), read('app/index.html')]);
  assert.match(sql, /create table public\.loyalty_tier_versions/i);
  assert.match(sql, /revoke insert,update,delete,truncate on table public\.loyalty_tiers[\s\S]*from public,anon,authenticated/i);
  assert.match(sql, /insert into public\.loyalty_tier_versions[\s\S]*where config_version_id=v_base/i);
  assert.doesNotMatch(app, /from\('loyalty_tiers'\)\.(?:insert|update|delete)/i);
  assert.match(app, /save_loyalty_config_draft',[\s\S]*p_config:\{tier\}/i);
});
