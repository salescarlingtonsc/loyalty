import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const sourcePath = 'db/migrations/20260721_frenly_v41_customer_module_hardening.sql';
const deployPath = 'supabase/migrations/20260721074441_frenly_v41_customer_module_hardening.sql';

test('v41 is a single atomic byte-identical source/deploy migration', async () => {
  const [source, deploy] = await Promise.all([read(sourcePath), read(deployPath)]);
  assert.equal(deploy, source);
  assert.equal([...source.matchAll(/^begin;$/gim)].length, 1);
  assert.equal([...source.matchAll(/^commit;$/gim)].length, 1);
});

test('fresh canonical order defines every v41 module helper before first use', async () => {
  const [planText, v41] = await Promise.all([
    read('supabase/canonical-migration-order.plan.json'),
    read(sourcePath)
  ]);
  const plan = JSON.parse(planText);
  const v41Index = plan.items.findIndex(({ name }) => name === 'frenly_v41_customer_module_hardening');
  assert.ok(v41Index > 0, 'v41 must be present after the recovered/deployable chain');
  const priorSql = (await Promise.all(plan.items.slice(0, v41Index)
    .map(({ version, name }) => read(`supabase/migrations/${version}_${name}.sql`)))).join('\n');
  assert.match(priorSql, /create or replace function app\.can_module\s*\(/i,
    'v14b deployed primitive must precede v41');
  const column = v41.search(/alter table public\.staff add column if not exists module_perms jsonb/i);
  const readHelper = v41.search(/create or replace function app\.can_module_read\s*\(/i);
  const writeHelper = v41.search(/create or replace function app\.can_module_write\s*\(/i);
  const firstPublicRpc = v41.search(/create or replace function public\.staff_create_client\s*\(/i);
  assert.ok(column >= 0 && column < readHelper && readHelper < writeHelper && writeHelper < firstPublicRpc,
    'module_perms and both helpers must be defined in-file before any v41 RPC or policy uses them');
  assert.match(v41, /staff_module_perms_v41_shape_check[\s\S]*?jsonb_path_exists[\s\S]*?"r"[\s\S]*?"rw"/i);
  for (const helper of ['can_module_read', 'can_module_write']) {
    assert.match(v41, new RegExp(`revoke all privileges on function app\\.${helper}\\(uuid,text\\)[\\s\\S]*?grant execute[^;]+authenticated`, 'i'));
  }
  assert.match(v41, /create or replace function app\.staff_module_perms\s*\(/i);
  assert.match(v41, /create or replace function app\.staff_modules\s*\([\s\S]*?jsonb_object_keys\(app\.staff_module_perms/i);
  assert.match(v41, /create or replace function public\.get_my_modules[\s\S]*?'module_perms', app\.staff_module_perms/i);
});

test('module overrides grant rw, preserve r-only reads, and exclude absent keys', async () => {
  const sql = await read(sourcePath);
  const readHelper = sql.match(/create or replace function app\.can_module_read[\s\S]*?\n\$\$;/i)?.[0] || '';
  const writeHelper = sql.match(/create or replace function app\.can_module_write[\s\S]*?\n\$\$;/i)?.[0] || '';
  assert.match(readHelper, /module_perms is not null and s\.module_perms \? p_module/i);
  assert.match(writeHelper, /module_perms is not null and s\.module_perms ->> p_module = 'rw'/i);
  for (const helper of [readHelper, writeHelper]) {
    assert.match(helper, /module_perms is null and \(s\.modules is null or p_module = any\(s\.modules\)\)/i);
  }
  const publicFunctions = sql.slice(sql.search(/create or replace function public\.staff_create_client/i));
  assert.doesNotMatch(publicFunctions, /not app\.can_module\s*\(/i,
    'legacy modules must not veto a non-null module_perms override');
});

test('Till definer RPCs cannot bypass the clients module boundary', async () => {
  const sql = await read(sourcePath);
  for (const [name, signature] of [
    ['lookup_client_by_phone', 'uuid,text'],
    ['record_sale_by_phone', 'uuid,text,integer,text,text,uuid,text']
  ]) {
    const block = sql.match(new RegExp(`create or replace function public\\.${name}[\\s\\S]*?\\n\\$\\$;`, 'i'))?.[0] || '';
    assert.match(block, /app\.has_perm\(p_business, 'create_sales'\)/i);
    assert.match(block, /app\.can_module_read\(p_business, 'clients'\)/i);
    assert.match(block, /using errcode = '42501'/i);
    assert.match(block, /set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
    assert.match(sql, new RegExp(`revoke all privileges on function public\\.${name}\\(${signature}\\)[\\s\\S]*?grant execute[^;]+authenticated`, 'i'));
  }
  const sale = sql.match(/create or replace function public\.record_sale_by_phone[\s\S]*?\n\$\$;/i)?.[0] || '';
  assert.match(sale, /pg_advisory_xact_lock/i);
  assert.match(sale, /s\.client_id is distinct from c\.id[\s\S]*?s\.amount_cents[\s\S]*?s\.kind[\s\S]*?s\.note[\s\S]*?s\.staff_id/i);
  assert.match(sale, /errcode = '23505'/i);
});

test('customer staff operations are private immutable exact-replay records', async () => {
  const sql = await read(sourcePath);
  const customerTable = sql.match(/create table public\.customer_staff_operations \([\s\S]*?\n\);/i)?.[0] || '';
  assert.match(sql, /create table public\.customer_staff_operations/i);
  assert.match(sql, /unique \(business_id, idempotency_key\)/i);
  assert.match(sql, /request_hash text not null check \(request_hash ~ '\^\[0-9a-f\]\{64\}\$'\)/i);
  assert.match(sql, /customer_staff_operations_immutable_guard/i);
  assert.match(sql, /revoke all privileges on table public\.customer_staff_operations from public, anon, authenticated/i);
  assert.doesNotMatch(customerTable, /request_payload|\bresult\b|full_name|phone|email|birth_date|gender|referrer_code/i,
    'immutable customer operation rows must not duplicate PII or request JSON');
  for (const name of ['staff_create_client', 'staff_set_marketing_consent']) {
    assert.match(sql, new RegExp(`create or replace function public\\.${name}`));
    assert.match(sql, new RegExp(`grant execute on function public\\.${name}[^;]+to authenticated`, 'i'));
  }
  assert.match(sql, /raise exception 'idempotency key conflicts[^']*'[\s\S]*?errcode = '23505'/i);
});

test('gift issuance records one immutable card/sale relationship and hides bearer lists', async () => {
  const sql = await read(sourcePath);
  const giftTable = sql.match(/create table public\.gift_card_issue_operations \([\s\S]*?\n\);/i)?.[0] || '';
  assert.match(sql, /create table public\.gift_card_issue_operations/i);
  assert.match(sql, /foreign key \(gift_card_id, business_id\)[\s\S]*?public\.gift_cards\(id, business_id\)/i);
  assert.match(sql, /foreign key \(sale_id, business_id\)[\s\S]*?public\.sales\(id, business_id\)/i);
  assert.match(sql, /revoke all privileges on table public\.gift_card_issue_operations from public, anon, authenticated/i);
  assert.doesNotMatch(giftTable, /request_payload|\bresult\b|\bcode\b|recipient_email/i,
    'immutable gift operation rows must not duplicate bearer codes or recipient PII');
  assert.match(sql, /revoke all privileges on table public\.gift_cards from public, anon, authenticated/i);
  assert.match(sql, /revoke all privileges on function public\.issue_gift_card\(uuid,integer,uuid,text\)/i);
  assert.match(sql, /create or replace function public\.staff_list_gift_cards/i);
  assert.match(sql, /'code_suffix', right\(x\.code, 4\)/i);
  assert.doesNotMatch(sql.match(/create or replace function public\.staff_list_gift_cards[\s\S]*?end\n\$\$;/i)?.[0] || '', /'code'\s*,/i);
});

test('the SPA has no raw customer-module writes and carries stable retry keys', async () => {
  const app = await read('app/index.html');
  assert.doesNotMatch(app, /sb\.from\('(clients|consents|referrals|referral_programs|gift_cards|membership_plans|memberships)'\)\.(insert|update|delete|upsert)/i);
  for (const rpc of [
    'staff_create_client', 'staff_set_marketing_consent', 'issue_gift_card',
    'staff_list_gift_cards', 'save_referral_program', 'save_membership_plan',
    'set_membership_status', 'enroll_membership_v41', 'redeem_gift_card_v41'
  ]) assert.match(app, new RegExp(`sb\\.rpc\\('${rpc}'`, 'i'), `app must call ${rpc}`);
  assert.match(app, /const createClientIdempotencyKey=crypto\.randomUUID\(\)/i);
  assert.match(app, /const consentIdempotencyKey=crypto\.randomUUID\(\)/i);
  assert.match(app, /let issueGiftCardIdempotencyKey=crypto\.randomUUID\(\)/i);
  assert.match(app, /p_idempotency_key:issueGiftCardIdempotencyKey/i);
  assert.match(app, /issueGiftCardIdempotencyKey=crypto\.randomUUID\(\)[\s\S]*?loadCards\(\)/i);
  assert.doesNotMatch(app, /sb\.rpc\('quick_add_client'/i);
  assert.doesNotMatch(app, /sb\.rpc\('enroll_membership'/i);
  assert.doesNotMatch(app, /sb\.rpc\('redeem_gift_card'/i);
  assert.match(app, /const canWriteModule=module=>S\.myRole==='owner'\|\|S\.myModulePerms\?\.\[module\]==='rw'/i);
  assert.match(app, /mm\.module_perms[\s\S]*?S\.myModulePerms/i);
  for (const module of ['clients', 'referrals', 'memberships', 'giftcards']) {
    assert.match(app, new RegExp(`canWriteModule\\('${module}'\\)`, 'i'),
      `${module} page must suppress write affordances for r-only staff`);
  }
});

test('module tables use read-specific policies and RPC-only writes', async () => {
  const sql = await read(sourcePath);
  for (const [table, module] of [
    ['clients', 'clients'], ['consents', 'clients'], ['referrals', 'referrals'], ['referral_programs', 'referrals'],
    ['membership_plans', 'memberships'], ['memberships', 'memberships']
  ]) {
    assert.match(sql, new RegExp(`create policy [^;]+ on public\\.${table} for select to authenticated[\\s\\S]*?can_module_read\\(business_id, '${module}'\\)`, 'i'));
    assert.match(sql, new RegExp(`revoke insert, update, delete, truncate on table public\\.${table} from public, anon, authenticated`, 'i'));
  }
  assert.match(sql, /drop policy if exists clients_all on public\.clients/i);
  assert.doesNotMatch(sql, /create policy [^;]+ on public\.(consents|referrals|referral_programs|gift_cards|membership_plans|memberships) for all/i);
});
