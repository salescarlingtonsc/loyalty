import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const migration = 'db/migrations/20260720_frenly_v37b_versioned_retention_taxonomy.sql';

test('v37b makes retention rules typed immutable configuration children', async () => {
  const sql = await read(migration);
  assert.match(sql, /create table public\.retention_program_versions/i);
  assert.match(sql, /foreign key \(program_id, business_id\)[\s\S]*references public\.retention_programs\(id, business_id\) on delete restrict/i);
  assert.match(sql, /foreign key \(config_version_id, business_id\)[\s\S]*references public\.firm_config_versions\(id, business_id\) on delete restrict/i);
  assert.match(sql, /foreign key \(reward_taxonomy_id, business_id\)[\s\S]*references public\.firm_reward_taxonomy\(id, business_id\) on delete restrict/i);
  assert.match(sql, /fulfillment_kind in \('discount_pct','free_item','credit'\)/i);
  assert.match(sql, /discount_percent numeric/i);
  assert.match(sql, /credit_cents integer/i);
  assert.match(sql, /manual_item text/i);
  assert.match(sql, /create trigger trg_guard_retention_program_version/i);
  assert.match(sql, /published retention configuration is immutable/i);
  assert.match(sql, /coalesce\(discount_percent > 0 and discount_percent <= 100, false\)/i);
  assert.match(sql, /coalesce\(credit_cents > 0, false\)/i);
  assert.match(sql, /coalesce\(char_length\(btrim\(manual_item\)\) >= 2, false\)/i);
  const table = sql.match(/create table public\.retention_program_versions \([\s\S]*?\n\);/i)?.[0] || '';
  assert.doesNotMatch(table, /reward_label/i);
});

test('legacy live behavior is copied and browser live writes are closed', async () => {
  const sql = await read(migration);
  assert.match(sql, /insert into public\.retention_program_versions[\s\S]*from public\.retention_programs rp/i);
  assert.match(sql, /join public\.firm_config_versions fv on fv\.business_id=rp\.business_id/i);
  assert.match(sql, /select rp\.id, fv\.id/i);
  assert.match(sql, /case when tax\.fulfillment_kind='discount_pct' then rp\.reward_value end/i);
  assert.match(sql, /case when tax\.fulfillment_kind='credit' then rp\.reward_value::integer end/i);
  assert.match(sql, /case when tax\.fulfillment_kind='free_item' then rp\.reward_item end/i);
  assert.match(sql, /revoke insert, update, delete, truncate on table public\.retention_programs\s+from public, anon, authenticated/i);
  assert.match(sql, /revoke insert, update, delete, truncate on table public\.firm_reward_taxonomy\s+from public, anon, authenticated/i);
  assert.match(sql, /drop policy if exists retention_programs_sa_read/i);
  assert.match(sql, /b\.active_config_version_id=retention_programs\.current_config_version_id/i);
});

test('future businesses receive a controlled starter taxonomy', async () => {
  const sql = await read(migration);
  assert.match(sql, /create or replace function app\.seed_firm_reward_taxonomy\(\)/i);
  for (const kind of ['discount_pct', 'free_item', 'credit']) assert.match(sql, new RegExp(`'${kind}'`));
  assert.match(sql, /create trigger trg_seed_firm_reward_taxonomy\s+after insert on public\.businesses/i);
  assert.match(sql, /on conflict do nothing/i);
  assert.match(sql, /revoke all on function app\.seed_firm_reward_taxonomy\(\)\s+from public,anon,authenticated/i);
});

test('draft clone, snapshot and publish carry retention as one config transaction', async () => {
  const sql = await read(migration);
  assert.match(sql, /create trigger trg_clone_retention_program_versions_on_draft/i);
  assert.match(sql, /where rv\.config_version_id=new\.based_on_version_id/i);
  assert.match(sql, /'retention_programs',coalesce/i);
  assert.match(sql, /from public\.retention_program_versions r where r\.config_version_id=p_version/i);
  assert.match(sql, /create trigger trg_retention_program_versions_snapshot/i);
  assert.match(sql, /perform 1 from public\.businesses where id=v_header\.business_id for update/i);
  assert.match(sql, /update public\.retention_programs rp set[\s\S]*current_config_version_id=p_version/i);
});

test('owner APIs validate draft hash, tenancy and controlled taxonomy behavior', async () => {
  const sql = await read(migration);
  for (const name of ['get_retention_config_draft', 'save_retention_program_draft', 'save_reward_taxonomy']) {
    assert.match(sql, new RegExp(`create or replace function public\\.${name}\\(`, 'i'));
    assert.match(sql, new RegExp(`grant execute on function public\\.${name}\\(`, 'i'));
  }
  assert.match(sql, /app\.is_salon_owner\(v_header\.business_id\)/i);
  assert.match(sql, /draft configuration changed; reload before saving'[\s\S]*errcode='40001'/i);
  assert.match(sql, /expected snapshot hash is required/i);
  assert.match(sql, /v_header\.status<>'draft'[\s\S]*from public\.businesses where id=v_header\.business_id for share[\s\S]*from public\.firm_reward_taxonomy where id=v_tax_id/i);
  assert.match(sql, /a stable program id is required for retry-safe creation/i);
  assert.match(sql, /retention program contains unsupported fields/i);
  assert.match(sql, /reward taxonomy is missing, retired, or belongs to another business/i);
  assert.match(sql, /reward fulfillment behavior is immutable; create a new reward type/i);
  assert.match(sql, /publish a replacement or disable the live retention program before retiring this taxonomy/i);
  assert.match(sql, /revoke all on function public\.get_retention_config_draft\(uuid\) from public,anon/i);
});

test('sale trigger resolves exact version while stable real windows prevent reminting', async () => {
  const sql = await read(migration);
  assert.match(sql, /from public\.retention_program_versions where business_id=new\.business_id and config_version_id=new\.config_version_id and active/i);
  assert.doesNotMatch(sql, /for rp in select \* from public\.retention_programs/i);
  assert.match(sql, /retention_program_version_id\)[\s\S]*new\.config_version_id,rp\.id/i);
  assert.match(sql, /create or replace function app\.snapshot_reward_grant_taxonomy\(\)/i);
  assert.match(sql, /config_version_id=new\.config_version_id/i);
  assert.match(sql, /'retention_program_version_id',v_rule\.id/i);
  assert.match(sql, /reward_grants_retention_version_business_fk/i);
  assert.match(sql, /v37b cannot prove a retention version and real period for every historical reward grant/i);
  assert.match(sql, /alter column retention_program_version_id set not null/i);
  assert.match(sql, /alter column period_start set not null/i);
  assert.match(sql, /alter column period_end set not null/i);
  assert.match(sql, /drop constraint if exists reward_grants_program_id_client_id_period_index_key/i);
  assert.match(sql, /unique\(program_id,client_id,period_start,period_end\)/i);
  assert.match(sql, /pg_advisory_xact_lock\(hashtextextended\(/i);
  assert.match(sql, /g\.period_start<v_period_end and v_period_start<g\.period_end/i);
  assert.match(sql, /retention reward already granted for an overlapping programme window/i);
  assert.match(sql, /new\.reward_label:=v_tax\.label/i);
  assert.match(sql, /reward grant identity, economics, window and provenance are immutable/i);
});

test('draft reads are volatile-compatible with required row locks', async () => {
  const v37 = await read(migration);
  const v36 = await read('db/migrations/20260720_frenly_v36_safe_draft_reward_editor.sql');
  assert.match(v37, /get_retention_config_draft\(p_config_version uuid\)[\s\S]*returns jsonb language plpgsql security definer[\s\S]*for share/i);
  assert.doesNotMatch(v37, /get_retention_config_draft\(p_config_version uuid\)[\s\S]{0,100}stable/i);
  assert.match(v36, /get_loyalty_reward_draft\(p_config_version uuid\)[\s\S]*language plpgsql\s+security definer[\s\S]*for share/i);
  assert.doesNotMatch(v36, /get_loyalty_reward_draft\(p_config_version uuid\)[\s\S]{0,100}stable/i);
});

test('v37b RPCs are registered in both v21 authenticated allowlists', async () => {
  const migrationAcl = await read('db/migrations/20260719_frenly_v21_security_hardening.sql');
  const testAcl = await read('db/tests/v21_security_hardening.sql');
  for (const name of ['get_retention_config_draft', 'save_retention_program_draft', 'save_reward_taxonomy']) {
    assert.match(migrationAcl, new RegExp(`'${name}'`));
    assert.match(testAcl, new RegExp(`'${name}'`));
  }
});

test('retention UI uses RPC drafts and keeps draft identities out of live reads', async () => {
  const app = await read('app/index.html');
  assert.match(app, /sb\.rpc\('get_retention_config_draft'/i);
  assert.match(app, /sb\.rpc\('save_retention_program_draft'/i);
  assert.match(app, /sb\.rpc\('save_reward_taxonomy'/i);
  assert.match(app, /\.eq\('current_config_version_id',currentVersion\)/i);
  assert.doesNotMatch(app, /from\('retention_programs'\)\.insert/i);
  assert.doesNotMatch(app, /from\('retention_programs'\)\.update/i);
  assert.doesNotMatch(app, /from\('firm_reward_taxonomy'\)\.insert/i);
  assert.match(app, /taxonomySort/);
  assert.match(app, /Sort order \(0–10000\)/);
  assert.match(app, /Add or reactivate a reward type before adding a program/);
  assert.match(app, /pendingProgramId&&programs\.some[\s\S]*sessionStorage\.removeItem\(newProgramRetryKey\)/);
  assert.match(app, /sessionStorage\.getItem\(newProgramRetryKey\)\|\|crypto\.randomUUID\(\)/);
});

test('v37b includes rollback and concurrency evidence harnesses', async () => {
  const rollback = await read('db/tests/v37b_versioned_retention_taxonomy.sql');
  const concurrency = await read('db/tests/v37_retention_publish_concurrency.sh');
  assert.match(rollback, /^begin;/m);
  assert.match(rollback, /v37b versioned retention\/taxonomy suite: ALL PASS/i);
  for (const proof of [
    'non-owner read retention draft', 'non-owner saved retention draft',
    'non-owner edited taxonomy', 'anon read retention draft',
    'unrelated owner read cross-business retention draft',
    'member RLS exposed a draft-only retention identity before publish',
    'retired taxonomy was selectable by a new active draft',
    'rollback publication reminted an overlapping stable-program reward or credit',
    'repeated identical publication reminted the same real retention window',
    'non-overlapping later window did not grant once with the live renamed taxonomy label',
    'member rewrote immutable retention grant window',
    'member retargeted immutable retention grant customer',
    'intended retention grant status transition was blocked',
    'pre-v37 live retention was not backfilled into every historical config version'
  ]) assert.match(rollback, new RegExp(proof, 'i'));
  assert.match(rollback, /create or replace function pg_temp\.as_v37_principal/i);
  assert.match(rollback, /set local role authenticated/i);
  assert.match(rollback, /set local role anon/i);
  assert.match(rollback, /request\.jwt\.claim\.sub/i);
  assert.match(rollback, /rollback;\s*$/i);
  assert.match(concurrency, /V37_CONFIRM_DISPOSABLE_DB/);
  assert.match(concurrency, /from public\.businesses where id=:'biz' for update/i);
  assert.match(concurrency, /wait_event_type='Lock'/i);
  assert.doesNotMatch(concurrency, /pg_advisory_(?:xact_)?lock/i);
  assert.doesNotMatch(concurrency, /pg_terminate_backend/i);
  assert.match(concurrency, /cleanup_synthetic_fixture\.sql/i);
  assert.match(concurrency, /select pg_sleep\(5\)/i);
  assert.match(concurrency, /exactly one immutable config version/i);
});
