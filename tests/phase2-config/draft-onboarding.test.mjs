import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const migrationPath = 'db/migrations/20260720_frenly_v25_draft_onboarding_loyalty.sql';

test('new workspaces receive an inactive loyalty draft', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /alter column configuration_status set default 'draft'/i);
  assert.match(migration, /alter column configuration_status set not null/i);
  assert.match(migration, /configuration_status <> 'draft' or not active/i);
  assert.match(migration, /v_business\.id, 'points', 1, 800, 2000, false, 'classic', 'draft'/i);
  assert.match(migration, /'onboarding_preset'/i);
  assert.match(migration, /insert into public\.subscriptions \(business_id\) values \(v_business\.id\)\s+on conflict \(business_id\) do nothing/i,
    'v25 must preserve the deployed v14 subscription seed');
  assert.doesNotMatch(migration, /v_business\.id, 'points'[^;]+true[^;]+'draft'/i);
});

test('existing loyalty configurations remain published', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /update public\.loyalty_programs\s+set configuration_status = 'published'\s+where configuration_status is null/i);
});

test('the owner sees draft state and explicitly publishes it', async () => {
  const app = await read('app/index.html');
  assert.match(app, /Draft recommendation/);
  assert.match(app, /Nothing is earning or redeeming yet/);
  assert.match(app, /configuration_status:'published'/);
  assert.match(app, /Publish program/);
  assert.match(app, /Loyalty program published/);
});

test('create_business retains authenticated-only execution', async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
  assert.match(migration, /revoke all on function public\.create_business\(text, text, text, text\[\]\) from public, anon/i);
  assert.match(migration, /grant execute on function public\.create_business\(text, text, text, text\[\]\) to authenticated/i);
});
