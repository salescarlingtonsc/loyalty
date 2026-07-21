import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');

test('v29 creates version-scoped branch overrides with same-business composite FKs', async () => {
  const sql = await read('db/migrations/20260720_frenly_v29_branch_overrides_custom_fields.sql');
  assert.match(sql, /create table public\.loyalty_branch_overrides/i);
  assert.match(sql, /primary key \(config_version_id, branch_id\)/i);
  assert.match(sql, /foreign key \(config_version_id, business_id\)\s+references public\.firm_config_versions\(id, business_id\)/i);
  assert.match(sql, /foreign key \(branch_id, business_id\)\s+references public\.branches\(id, business_id\)/i);
  assert.match(sql, /create trigger trg_clone_loyalty_branch_overrides_on_draft/i);
  assert.match(sql, /select new\.id, new\.business_id, branch_id/i);
});

test('branch resolver explicitly applies branch values over firm defaults', async () => {
  const sql = await read('db/migrations/20260720_frenly_v29_branch_overrides_custom_fields.sql');
  for (const column of [
    'active', 'earn_points_per_dollar', 'stamp_per_cents', 'expiry_mode', 'expiry_days'
  ]) assert.match(sql, new RegExp(`coalesce\\(o\\.${column}, d\\.${column}\\)`));
  for (const column of ['redeem_points', 'reward_credit_cents', 'stamp_target', 'tier_basis']) {
    assert.match(sql, new RegExp(`\\bd\\.${column}\\b`));
    assert.doesNotMatch(sql, new RegExp(`coalesce\\(o\\.${column}, d\\.${column}\\)`));
  }
  assert.match(sql, /case when o\.branch_id is null then 'firm_default' else 'branch_override' end/i);
  assert.match(sql, /branch does not belong to business/i);
  assert.match(sql, /revoke all on function app\.resolve_loyalty_branch_config\(uuid, uuid, uuid\)\s+from public, anon, authenticated/i);
});

test('sale earning consumes the resolver and redemption scope is explicit', async () => {
  const sql = await read('db/migrations/20260720_frenly_v29_branch_overrides_custom_fields.sql');
  assert.match(sql, /create or replace function app\.on_sale_recorded\(\)[\s\S]+from app\.resolve_loyalty_branch_config\([\s\S]+new\.business_id[\s\S]+new\.branch_id[\s\S]+new\.config_version_id/i);
  assert.match(sql, /redemption functions are not changed by v29[\s\S]+do not affect\s+-- redemption economics/i);
});

test('branch overrides participate in deterministic configuration hashing', async () => {
  const sql = await read('db/migrations/20260720_frenly_v29_branch_overrides_custom_fields.sql');
  assert.match(sql, /create or replace function app\.refresh_loyalty_config_snapshot\(p_version uuid\)/i);
  assert.match(sql, /'branch_overrides'/i);
  assert.match(sql, /from public\.loyalty_branch_overrides o\s+where o\.config_version_id = p_version/i);
  assert.match(sql, /jsonb_agg\([\s\S]+order by o\.branch_id/i);
  assert.match(sql, /create trigger trg_loyalty_branch_overrides_snapshot/i);
  assert.match(sql, /client-field definitions are deliberately\s+-- excluded/i);
});

test('client custom fields use typed columns and normalized select options', async () => {
  const sql = await read('db/migrations/20260720_frenly_v29_branch_overrides_custom_fields.sql');
  assert.match(sql, /create table public\.client_field_definitions/i);
  assert.match(sql, /value_type text not null check \(value_type in \('text','number','date','boolean','select'\)\)/i);
  assert.match(sql, /classification text not null default 'operational'/i);
  assert.match(sql, /create table public\.client_field_options/i);
  assert.match(sql, /create table public\.client_field_values/i);
  assert.match(sql, /create or replace function public\.create_client_field_definition\(/i);
  assert.match(sql, /p_options jsonb default '\[\]'::jsonb/i);
  assert.match(sql, /jsonb_array_length\(p_options\) > 100/i);
  assert.match(sql, /p_value_type = 'select' and jsonb_array_length\(p_options\) < 2/i);
  assert.match(sql, /jsonb_array_elements\(p_options\)/i);
  assert.match(sql, /if not app\.is_salon_owner\(p_business\)/i);
  assert.match(sql, /set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
  assert.match(sql, /revoke all on function public\.create_client_field_definition\(uuid, text, text, text, text, jsonb\)\s+from public, anon/i);
  assert.match(sql, /grant execute on function public\.create_client_field_definition\(uuid, text, text, text, text, jsonb\)\s+to authenticated/i);
  assert.match(sql, /revoke insert on public\.client_field_definitions from authenticated/i);
  assert.match(sql, /revoke insert on public\.client_field_options from authenticated/i);
  for (const column of ['text_value', 'number_value', 'date_value', 'boolean_value', 'select_value']) {
    assert.match(sql, new RegExp(`\\b${column}\\s+(?:text|numeric|date|boolean)`));
  }
  assert.match(sql, /one_typed_value_check/i);
  assert.match(sql, /exactly one typed client field value is required/i);
  assert.match(sql, /select value is not an active option for this field/i);
  assert.match(sql, /o\.option_key = new\.select_value/i);
  assert.match(sql, /new\.select_value := lower\(btrim\(new\.select_value\)\)/i);
  assert.doesNotMatch(sql, /client_field_values[\s\S]{0,400}jsonb/i);
});

test('custom-field keys are unique per business and values are tenant-bound', async () => {
  const sql = await read('db/migrations/20260720_frenly_v29_branch_overrides_custom_fields.sql');
  assert.match(sql, /unique index client_field_definitions_business_key_uk\s+on public\.client_field_definitions \(business_id, field_key\)/i);
  assert.match(sql, /foreign key \(client_id, business_id\)\s+references public\.clients\(id, business_id\)/i);
  assert.match(sql, /foreign key \(field_definition_id, business_id\)\s+references public\.client_field_definitions\(id, business_id\)/i);
  assert.match(sql, /field_key = lower\(field_key\)/i);
  assert.match(sql, /create or replace function app\.guard_client_field_definition\(\)/i);
  assert.match(sql, /client field key is immutable/i);
  assert.match(sql, /client field value type is immutable after values or options exist/i);
  assert.match(sql, /client field classification is immutable after values exist/i);
  assert.match(sql, /select option identity is immutable after values exist/i);
  assert.match(sql, /retired client fields cannot receive new values/i);
  assert.doesNotMatch(sql, /insert into public\.client_field_values/i);
  assert.doesNotMatch(sql, /update public\.clients/i);
});

test('v29 denies raw anon access and keeps client field writes owner-only', async () => {
  const sql = await read('db/migrations/20260720_frenly_v29_branch_overrides_custom_fields.sql');
  for (const table of ['loyalty_branch_overrides', 'client_field_definitions', 'client_field_options', 'client_field_values']) {
    assert.match(sql, new RegExp(`alter table public\\.${table} enable row level security`, 'i'));
    assert.match(sql, new RegExp(`revoke all on public\\.${table} from public, anon`, 'i'));
    assert.match(sql, new RegExp(`${table}[^;]+app\\.is_salon_owner\\(business_id\\)`, 'is'));
  }
  for (const fn of [
    'app.clone_loyalty_branch_overrides_on_draft()',
    'app.guard_client_field_definition()',
    'app.validate_client_field_option()',
    'app.validate_client_field_value()',
    'app.refresh_v29_branch_snapshot_trigger()'
  ]) assert.match(sql, new RegExp(`revoke all on function ${fn.replace(/[()]/g, '\\$&')}\\s+from public, anon, authenticated`, 'i'));
  assert.doesNotMatch(sql, /grant execute on function app\.resolve_loyalty_branch_config/i);
  assert.doesNotMatch(sql, /grant execute on function public\.(?!create_client_field_definition)/i);
});

test('v37 replaces raw branch override writes with owner-only draft RPCs', async () => {
  const sql = await read('db/migrations/20260720_frenly_v37_branch_override_editor_rpc.sql');
  const app = await read('app/index.html');
  const securityMigration = await read('db/migrations/20260719_frenly_v21_security_hardening.sql');
  const securityTest = await read('db/tests/v21_security_hardening.sql');
  assert.match(sql, /drop policy if exists loyalty_branch_overrides_write/i);
  assert.match(sql, /revoke insert, update, delete, truncate on table public\.loyalty_branch_overrides\s+from public, anon, authenticated/i);
  assert.match(sql, /create or replace function public\.save_loyalty_branch_override_draft\(/i);
  assert.match(sql, /create or replace function public\.remove_loyalty_branch_override_draft\(/i);
  assert.match(sql, /where k not in \('active','earn_points_per_dollar','stamp_per_cents','expiry_mode','expiry_days'\)/i);
  assert.match(sql, /using errcode = '40001'/i);
  assert.match(sql, /grant execute on function public\.save_loyalty_branch_override_draft\(uuid,uuid,jsonb,text\)\s+to authenticated/i);
  assert.match(sql, /grant execute on function public\.remove_loyalty_branch_override_draft\(uuid,uuid,text\)\s+to authenticated/i);
  assert.match(app, /Branch settings/);
  assert.match(app, /sb\.rpc\('save_loyalty_branch_override_draft'/i);
  assert.match(app, /sb\.rpc\('remove_loyalty_branch_override_draft'/i);
  assert.match(app, /p_expected_snapshot_hash:draftSnapshotHash\|\|null/i);
  assert.match(securityMigration, /'save_loyalty_branch_override_draft'/);
  assert.match(securityMigration, /'remove_loyalty_branch_override_draft'/);
  assert.match(securityTest, /'save_loyalty_branch_override_draft'/);
  assert.match(securityTest, /'remove_loyalty_branch_override_draft'/);
});

test('v29 includes a rollback-only behavioral suite', async () => {
  const sql = await read('db/tests/v29_branch_overrides_custom_fields.sql');
  assert.match(sql, /^begin;/m);
  assert.match(sql, /public\.create_client_field_definition\(/i);
  assert.match(sql, /at least 2 options|options_created/i);
  assert.match(sql, /atomic field RPC left a partial definition/i);
  assert.match(sql, /v29 branch\/custom-field suite: ALL PASS/i);
  assert.match(sql, /rollback;\s*$/i);
});

test('owner UI creates fields atomically and edits typed customer values', async () => {
  const app = await read('app/index.html');
  assert.match(app, /sb\.rpc\('create_client_field_definition'/i);
  assert.doesNotMatch(app, /from\('client_field_definitions'\)\.insert/i);
  assert.doesNotMatch(app, /from\('client_field_options'\)\.insert/i);
  assert.match(app, /from\('client_field_values'\)\.upsert\(payload/i);
  assert.match(app, /S\.myRole==='owner'\?sb\.from\('client_field_definitions'\)/i);
  assert.match(app, /Sensitive[^<]*owner only/i);
});
