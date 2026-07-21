import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const migrationPath = 'db/migrations/20260721_frenly_v41_customer_module_hardening.sql';
const deployPath = 'supabase/migrations/20260721074441_frenly_v41_customer_module_hardening.sql';
const suitePath = 'db/tests/v41_customer_module_integrity.sql';
const hardeningSuitePath = 'db/tests/v41_customer_module_hardening.sql';

const compact = (value) => value.replace(/\s+/g, ' ').trim();

function functionBlock(sql, name) {
  const start = sql.search(new RegExp(`create or replace function public\\.${name}\\s*\\(`, 'i'));
  assert.ok(start >= 0, `${name} is missing`);
  const rest = sql.slice(start);
  const end = rest.search(/\n(?:create or replace function|revoke all privileges on function|commit;)\b/i);
  return end < 0 ? rest : rest.slice(0, end);
}

function schemaFunctionBlock(sql, schema, name) {
  const start = sql.search(new RegExp(`create or replace function ${schema}\\.${name}\\s*\\(`, 'i'));
  assert.ok(start >= 0, `${schema}.${name} is missing`);
  const rest = sql.slice(start);
  const end = rest.search(/\n(?:create or replace function|revoke all privileges on function|commit;)\b/i);
  return end < 0 ? rest : rest.slice(0, end);
}

function tableBlock(sql, name) {
  const match = sql.match(new RegExp(`create table public\\.${name}\\s*\\(([\\s\\S]*?)\\n\\);`, 'i'));
  assert.ok(match, `${name} is missing`);
  return match[1];
}

function appSection(source, start, end) {
  const startAt = source.indexOf(start);
  const endAt = source.indexOf(end, startAt + start.length);
  assert.ok(startAt >= 0 && endAt > startAt, `missing app section ${start}`);
  return source.slice(startAt, endAt);
}

test('v41 source and deploy migrations stay byte-identical', async () => {
  const deployNames = (await readdir(new URL('supabase/migrations/', root)))
    .filter((name) => name.endsWith('_frenly_v41_customer_module_hardening.sql'));
  assert.equal(deployNames.length, 1, 'use `supabase migration new frenly_v41_customer_module_hardening` exactly once');
  assert.equal(`supabase/migrations/${deployNames[0]}`, deployPath,
    'deploy migration must retain the Supabase CLI-generated timestamp');
  const [source, deploy] = await Promise.all([
    read(migrationPath),
    read(deployPath)
  ]);
  assert.equal(deploy, source);
});

test('every v41 authorization helper exists in canonical deploy history', async () => {
  const deployName = deployPath.split('/').at(-1);
  const deployNames = (await readdir(new URL('supabase/migrations/', root)))
    .filter((name) => name.endsWith('.sql') && name < deployName)
    .sort();
  const [v41, ...priorParts] = await Promise.all([
    read(migrationPath),
    ...deployNames.map((name) => read(`supabase/migrations/${name}`))
  ]);
  const prior = priorParts.join('\n');
  const history = `${prior}\n${v41}`;
  const v41Offset = prior.length + 1;
  const helpers = new Set([...v41.matchAll(/\bapp\.([a-z][a-z0-9_]*)\s*\(/gi)].map(([, name]) => name));
  for (const helper of helpers) {
    const created = new RegExp(`create(?: or replace)? function app\\.${helper}\\s*\\(`, 'i').exec(history);
    const moved = new RegExp(`alter function public\\.${helper}\\s*\\([^;]+set schema app`, 'i').exec(history);
    const definition = [created, moved].filter(Boolean).sort((a, b) => a.index - b.index)[0];
    const referenceAt = v41Offset + v41.search(new RegExp(`\\bapp\\.${helper}\\s*\\(`, 'i'));
    assert.ok(definition && definition.index < referenceAt,
      `v41 references app.${helper} before canonical Supabase history creates it`);
  }
});

test('staff consent mutations are authenticated atomic idempotent RPCs', async () => {
  const sql = await read(migrationPath);
  const createClient = functionBlock(sql, 'staff_create_client');
  const setConsent = functionBlock(sql, 'staff_set_marketing_consent');

  assert.match(sql, /create table public\.customer_staff_operations/i);
  assert.match(sql, /unique\s*\(\s*business_id\s*,\s*actor\s*,\s*operation_type\s*,\s*idempotency_key\s*\)/i);
  assert.match(sql, /alter table public\.customer_staff_operations enable row level security/i);
  assert.match(sql, /revoke all privileges on table public\.customer_staff_operations from public, anon, authenticated/i);
  assert.match(sql, /customer_staff_operations[^;]+(?:append-only|immutable)/i);

  for (const [name, block] of [['staff_create_client', createClient], ['staff_set_marketing_consent', setConsent]]) {
    assert.match(block, /security definer/i, `${name} must own the transaction boundary`);
    assert.match(block, /set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
    assert.match(block, /auth\.uid\s*\(\s*\)/i);
    assert.match(block, /public\.staff[\s\S]*?\.active/i);
    assert.match(block, /app\.can_module_write\s*\([^)]*'clients'/i);
    assert.doesNotMatch(block, /app\.can_module\s*\(/i,
      `${name} must not AND an explicit override with the legacy module array`);
    assert.match(block, /idempotency_key/i);
    assert.match(block, /request_hash/i);
    assert.match(block, /'status'\s*,\s*'completed'/i);
    assert.match(block, /23505|unique_violation/i, `${name} must reject changed payload under one key`);
    assert.match(sql, new RegExp(`revoke all privileges on function public\\.${name}[^;]+from public, anon, authenticated`, 'i'));
    assert.match(sql, new RegExp(`grant execute on function public\\.${name}[^;]+to authenticated`, 'i'));
  }

  assert.match(createClient, /insert into public\.clients/i);
  assert.match(createClient, /insert into public\.consents/i);
  assert.match(createClient,
    /v_referrer_code\s+is not null[\s\S]*?app\.can_module_write\s*\(\s*p_business\s*,\s*'referrals'\s*\)/i,
    'linking a referral during client creation requires referrals write access');
  assert.match(setConsent, /for update/i);
  assert.match(setConsent, /update public\.clients[\s\S]*marketing_consent/i);
  assert.match(setConsent, /insert into public\.consents/i);
  assert.doesNotMatch(setConsent, /exception[\s\S]*when others[\s\S]*(?:return|status)/i,
    'consent event failures must abort the transaction, not be converted to success');
});

test('immutable operation rows minimize PII and bearer-secret duplication', async () => {
  const sql = await read(migrationPath);
  const customerOps = tableBlock(sql, 'customer_staff_operations');
  const giftOps = tableBlock(sql, 'gift_card_issue_operations');
  for (const [name, definition] of [
    ['customer_staff_operations', customerOps],
    ['gift_card_issue_operations', giftOps]
  ]) {
    assert.doesNotMatch(definition, /\brequest_payload\b|\bresult\s+jsonb\b/i,
      `${name} must not duplicate requests or public responses`);
  }
  assert.doesNotMatch(customerOps, /\b(?:full_name|phone|email|birth_date|gender|referrer_code)\b/i);
  assert.doesNotMatch(giftOps, /\b(?:recipient_email|code)\b/i,
    'gift operation provenance must not duplicate the bearer code or recipient email');

  for (const name of ['staff_create_client', 'staff_set_marketing_consent', 'issue_gift_card']) {
    const body = functionBlock(sql, name);
    const operationInsert = body.match(/insert into public\.(?:customer_staff_operations|gift_card_issue_operations)\s*\([\s\S]*?\);/i)?.[0] || '';
    assert.ok(operationInsert, `${name} must persist safe idempotency provenance`);
    assert.doesNotMatch(operationInsert, /\brequest_payload\b|\bresult\b/i,
      `${name} must not persist duplicated request/response JSON`);
  }
});

test('gift-card issuance serializes one logical sale and rejects changed replays', async () => {
  const sql = await read(migrationPath);
  const issue = functionBlock(sql, 'issue_gift_card');

  assert.match(sql, /create table public\.gift_card_issue_operations/i);
  assert.match(sql, /unique\s*\(\s*business_id\s*,\s*actor\s*,\s*idempotency_key\s*\)/i);
  assert.match(sql, /alter table public\.gift_card_issue_operations enable row level security/i);
  assert.match(sql, /revoke all privileges on table public\.gift_card_issue_operations from public, anon, authenticated/i);
  assert.match(sql, /gift_card_issue_operations[^;]+(?:append-only|immutable)/i);

  assert.match(sql, /create or replace function public\.issue_gift_card\(\s*p_business uuid,\s*p_amount integer,\s*p_purchaser uuid,\s*p_recipient_email text,\s*p_idempotency_key uuid\s*\)/i);
  assert.match(issue, /security definer/i);
  assert.match(issue, /set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
  assert.match(issue, /auth\.uid\s*\(\s*\)/i);
  assert.match(issue, /app\.has_perm\s*\(\s*p_business\s*,\s*'create_sales'\s*\)/i);
  assert.match(issue, /app\.can_module_write\s*\(\s*p_business\s*,\s*'giftcards'\s*\)/i);
  assert.doesNotMatch(issue, /app\.can_module\s*\(/i);
  assert.match(issue, /public\.staff[\s\S]*?\.active/i);
  assert.match(issue, /public\.clients[\s\S]*?p_purchaser[\s\S]*?business_id\s*=\s*p_business/i);
  assert.match(issue, /request_hash/i);
  assert.match(issue, /23505|unique_violation/i);
  assert.match(issue, /pg_advisory_xact_lock|for update/i,
    'same-key calls need an explicit transaction serialization point');
  assert.match(issue, /insert into public\.gift_cards/i);
  assert.match(issue, /insert into public\.sales/i);
  assert.match(issue, /'status'\s*,\s*'completed'/i);
  const lockAt = issue.search(/pg_advisory_xact_lock/i);
  const replayLookupAt = issue.search(/from public\.gift_card_issue_operations/i);
  const cardInsertAt = issue.search(/insert into public\.gift_cards/i);
  const saleInsertAt = issue.search(/insert into public\.sales/i);
  assert.ok(lockAt >= 0 && replayLookupAt > lockAt && cardInsertAt > replayLookupAt && saleInsertAt > cardInsertAt,
    'simultaneous same-key issuance must serialize before replay lookup and both financial inserts');
  assert.match(sql, /revoke all privileges on function public\.issue_gift_card\(uuid\s*,\s*integer\s*,\s*uuid\s*,\s*text\)\s+from public, anon, authenticated/i);
  assert.match(sql, /grant execute on function public\.issue_gift_card\(uuid\s*,\s*integer\s*,\s*uuid\s*,\s*text\s*,\s*uuid\)\s+to authenticated/i);
});

test('customer financial/configuration tables enforce module reads and deny raw writes', async () => {
  const sql = await read(migrationPath);
  for (const table of ['consents', 'referrals', 'referral_programs', 'membership_plans', 'memberships']) {
    assert.match(sql, new RegExp(`revoke (?:all privileges|insert, update, delete, truncate)[^;]*on table public\\.${table}[^;]*from public, anon, authenticated`, 'i'),
      `${table} must deny browser-role raw writes`);
  }
  assert.match(sql, /revoke all privileges on table public\.gift_cards from public, anon, authenticated/i);

  for (const [table, module] of [
    ['consents', 'clients'],
    ['referrals', 'referrals'],
    ['referral_programs', 'referrals'],
    ['membership_plans', 'memberships'],
    ['memberships', 'memberships']
  ]) {
    assert.match(sql, new RegExp(`create policy[^;]+on public\\.${table}[^;]+for select[^;]+app\\.can_module_read\\([^)]*'${module}'`, 'i'),
      `${table} read policy must enforce the ${module} module`);
  }
  assert.doesNotMatch(sql, /create policy[^;]+on public\.(?:consents|referrals|referral_programs|gift_cards|membership_plans|memberships)[^;]+for all/i);
});

test('clients RLS and module discovery honor explicit r/rw overrides', async () => {
  const sql = await read(migrationPath);
  for (const policy of ['clients_all', 'clients_read', 'clients_ins', 'clients_upd', 'clients_del']) {
    assert.match(sql, new RegExp(`drop policy if exists ${policy} on public\\.clients`, 'i'));
  }
  assert.match(sql, /create policy clients_v41_read on public\.clients\s+for select to authenticated\s+using \(app\.can_module_read\(business_id, 'clients'\)\)/i);
  assert.doesNotMatch(sql, /create policy[^;]+on public\.clients[^;]+for (?:all|insert|update|delete)/i);
  assert.match(sql, /revoke insert, update, delete, truncate on table public\.clients from public, anon, authenticated/i);

  const effective = schemaFunctionBlock(sql, 'app', 'staff_module_perms');
  const staffModules = schemaFunctionBlock(sql, 'app', 'staff_modules');
  assert.match(staffModules, /app\.staff_module_perms\s*\(/i);
  assert.match(effective, /module_perms/i);
  assert.match(effective, /s\.role\s*=\s*'owner'[\s\S]*b\.enabled_modules|unnest\(b\.enabled_modules\)/i);
  assert.match(effective, /s\.module_perms is null[\s\S]*s\.modules/i,
    'NULL module_perms must preserve legacy module behavior');
  assert.match(effective, /s\.module_perms\s*\?\s*module_name/i,
    'effective modules must include only explicit r/rw keys');
  assert.match(sql, /create or replace function public\.get_my_modules\s*\(/i);
  const personas = functionBlock(sql, 'get_my_personas');
  assert.match(personas, /app\.staff_modules\s*\(\s*s\.business_id\s*\)/i,
    'persona discovery must use the same effective module resolver as workspace routing');
  assert.doesNotMatch(personas, /when s\.modules is null[\s\S]*m = any\(s\.modules\)/i,
    'persona discovery must not independently reimplement the legacy-only module array');
});

test('till phone RPCs cannot bypass effective clients read access', async () => {
  const sql = await read(migrationPath);
  for (const [name, signature] of [
    ['lookup_client_by_phone', 'uuid,text'],
    ['record_sale_by_phone', 'uuid,text,integer,text,text,uuid,text']
  ]) {
    const body = functionBlock(sql, name);
    assert.match(body, /security definer/i);
    assert.match(body, /set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
    assert.match(body, /app\.can_module_read\s*\(\s*p_business\s*,\s*'clients'\s*\)/i);
    assert.match(body, /app\.has_perm\s*\(\s*p_business\s*,\s*'create_sales'\s*\)/i);
    assert.doesNotMatch(body, /app\.can_module\s*\(/i);
    assert.match(sql, new RegExp(`revoke all privileges on function public\\.${name}\\(${signature}\\)\\s+from public, anon, authenticated`, 'i'));
    assert.match(sql, new RegExp(`grant execute on function public\\.${name}\\(${signature}\\)\\s+to authenticated`, 'i'));
  }

  const recordSale = functionBlock(sql, 'record_sale_by_phone');
  const lockAt = recordSale.search(/pg_advisory_xact_lock/i);
  const replayLookupAt = recordSale.search(/from public\.sales/i);
  const insertAt = recordSale.search(/insert into public\.sales/i);
  assert.ok(lockAt >= 0 && replayLookupAt > lockAt && insertAt > replayLookupAt,
    'same-key Till sales must serialize before replay lookup and insertion');
  for (const field of ['client_id', 'amount_cents', 'kind', 'note', 'staff_id']) {
    assert.match(recordSale, new RegExp(`s\\.${field}\\s+is distinct from`, 'i'),
      `Till replay identity must include ${field}`);
  }
  assert.match(recordSale, /23505|unique_violation/i,
    'changed Till payloads under one key must conflict');
  assert.match(recordSale, /'status'\s*,\s*'duplicate_ignored'/i,
    'an exact Till replay must return the pre-existing sale');
});

test('loyalty read-only overrides cannot mutate customer balances', async () => {
  const sql = await read(migrationPath);
  assert.match(sql, /alter function public\.redeem_points\(uuid,uuid,text\) rename to redeem_points_v40_internal/i);
  assert.match(sql, /alter function public\.redeem_points_v40_internal\(uuid,uuid,text\) set schema app/i);
  assert.match(sql, /revoke all privileges on function app\.redeem_points_v40_internal\(uuid,uuid,text\)[\s\S]*from public, anon, authenticated/i);
  for (const name of ['redeem_points', 'redeem_reward', 'redeem_reward_at_context']) {
    const body = functionBlock(sql, name);
    assert.match(body, /app\.can_module_write\s*\(\s*p_business\s*,\s*'loyalty'\s*\)/i,
      `${name} must enforce loyalty:rw before entering its financial core`);
    assert.match(body, /using errcode = '42501'/i);
    assert.match(sql, new RegExp(`revoke all privileges on function public\\.${name}[^;]+from public, anon, authenticated`, 'i'));
    assert.match(sql, new RegExp(`grant execute on function public\\.${name}[^;]+to authenticated`, 'i'));
  }
});

test('gift-card listing is bounded and never projects the bearer code', async () => {
  const sql = await read(migrationPath);
  const list = functionBlock(sql, 'staff_list_gift_cards');
  assert.match(list, /stable[\s\S]*security definer/i);
  assert.match(list, /app\.can_module_read\s*\(\s*p_business\s*,\s*'giftcards'\s*\)/i);
  assert.doesNotMatch(list, /app\.can_module\s*\(/i);
  assert.match(list, /least\s*\(\s*greatest[\s\S]*?100\s*\)/i);
  for (const key of ['gift_card_id', 'code_suffix', 'initial_cents', 'balance_cents', 'status', 'created_at']) {
    assert.match(list, new RegExp(`'${key}'`, 'i'));
  }
  assert.doesNotMatch(list, /'code'\s*,/i, 'list projection must not return the full bearer code');
  assert.doesNotMatch(list, /row_to_json|to_jsonb\s*\(\s*g\s*\)|select\s+g\.\*/i);
  assert.match(sql, /revoke all privileges on function public\.staff_list_gift_cards[^;]+from public, anon, authenticated/i);
  assert.match(sql, /grant execute on function public\.staff_list_gift_cards[^;]+to authenticated/i);
});

test('referral and membership writes are confined to permissioned RPCs', async () => {
  const sql = await read(migrationPath);
  const contracts = [
    ['save_referral_program', /app\.can_module_write\s*\(\s*p_business\s*,\s*'referrals'/i],
    ['save_membership_plan', /app\.can_module_write\s*\(\s*p_business\s*,\s*'memberships'/i],
    ['set_membership_status', /app\.can_module_write\s*\(\s*p_business\s*,\s*'memberships'/i],
    ['enroll_membership_v41', /app\.can_module_write\s*\(\s*p_business\s*,\s*'memberships'/i],
    ['redeem_gift_card_v41', /app\.can_module_write\s*\(\s*p_business\s*,\s*'giftcards'/i]
  ];
  for (const [name, authorization] of contracts) {
    const body = functionBlock(sql, name);
    assert.match(body, /security definer/i);
    assert.match(body, /set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
    assert.match(body, /auth\.uid\s*\(\s*\)|public\.staff[\s\S]*?\.active/i);
    assert.match(body, authorization);
    assert.doesNotMatch(body, /app\.can_module\s*\(/i);
    assert.match(sql, new RegExp(`revoke all privileges on function public\\.${name}[^;]+from public, anon, authenticated`, 'i'));
    assert.match(sql, new RegExp(`grant execute on function public\\.${name}[^;]+to authenticated`, 'i'));
  }
  assert.match(functionBlock(sql, 'enroll_membership_v41'), /app\.has_perm\s*\(\s*p_business\s*,\s*'create_sales'/i);
  assert.match(functionBlock(sql, 'redeem_gift_card_v41'), /app\.has_perm\s*\(\s*p_business\s*,\s*'create_sales'/i);
  assert.match(functionBlock(sql, 'redeem_gift_card_v41'), /public\.redeem_gift_card\s*\(/i);
  assert.match(functionBlock(sql, 'enroll_membership_v41'), /public\.enroll_membership\s*\(/i);
});

test('v41 app uses the atomic RPCs and preserves one issuance key across retries', async () => {
  const app = await read('app/index.html');
  assert.match(app, /sb\.rpc\('staff_create_client'/i);
  assert.match(app, /sb\.rpc\('staff_set_marketing_consent'/i);
  assert.doesNotMatch(app, /sb\.from\('consents'\)\.insert/i);
  assert.doesNotMatch(app, /sb\.from\('clients'\)\.update\(\{marketing_consent:/i);
  assert.doesNotMatch(app, /sb\.from\('referral_programs'\)\.(?:insert|upsert|update|delete)/i);
  assert.doesNotMatch(app, /sb\.from\('membership_plans'\)\.(?:insert|upsert|update|delete)/i);
  assert.doesNotMatch(app, /sb\.from\('memberships'\)\.(?:insert|upsert|update|delete)/i);
  for (const rpc of ['save_referral_program', 'save_membership_plan', 'set_membership_status']) {
    assert.match(app, new RegExp(`sb\\.rpc\\('${rpc}'`, 'i'));
  }

  const clientsPage = app.match(/async function clientsPage\(\)\{[\s\S]*?\n\}/)?.[0] || '';
  assert.match(clientsPage, /canWriteReferrals\s*=\s*canWriteModule\s*\(\s*'referrals'\s*\)/i);
  assert.match(clientsPage, /\$\{\s*canWriteReferrals\s*\?[\s\S]{0,500}?id=["']cr["']/i,
    'the referrer field must be rendered only for referrals writers');
  assert.match(clientsPage,
    /p_referrer_code\s*:\s*canWriteReferrals\s*\?[\s\S]*?\$\(\s*'cr'\s*\)[\s\S]*?:\s*null/i,
    'the client RPC payload must omit referrer codes without referrals write access');

  const clientDetail = app.match(/async function clientDetail\(id\)\{[\s\S]*?\n\}/)?.[0] || '';
  assert.match(clientDetail, /const canWriteLoyalty=canWriteModule\('loyalty'\)/i);
  assert.match(clientDetail, /canWriteLoyalty\?`<button class="btn sm" id="redeem"/i,
    'classic redemption must not render for loyalty:r staff');
  assert.match(clientDetail, /canWriteLoyalty\?`<button class="btn sm rewardGo"/i,
    'catalog redemption must not render for loyalty:r staff');
  assert.match(clientDetail, /S\.myRole==='owner'&&canWriteLoyalty[\s\S]*?id="adjGo"/i,
    'manual balance adjustment must remain owner-only');

  const tillPage = appSection(app, 'async function tillPage(){', 'async function salesPage(){');
  assert.match(tillPage, /const canWriteLoyalty=canWriteModule\('loyalty'\)/i);
  assert.match(tillPage,
    /tillClassic&&canWriteLoyalty&&cust\.can_redeem\?`[\s\S]{0,300}?id="tRedeem"/i,
    'loyalty:rw must expose classic Till redemption when the customer is eligible');
  assert.doesNotMatch(tillPage,
    /tillClassic&&cust\.can_redeem\?`[\s\S]{0,300}?id="tRedeem"/i,
    'loyalty:r must not receive the classic Till redemption control');
  assert.match(tillPage, /!canWriteLoyalty&&cust\.can_redeem\?[\s\S]{0,200}?read only for your role/i,
    'an eligible loyalty:r Till user must receive an explicit read-only cue');

  const loyaltyPage = appSection(app, 'async function loyaltyPage(', 'async function retentionPage(');
  assert.match(loyaltyPage, /const canWriteLoyalty=canWriteModule\('loyalty'\)/i);
  assert.match(loyaltyPage,
    /const canManageLoyalty=S\.myRole==='owner'&&canWriteLoyalty/i,
    'program configuration requires both owner role and loyalty:rw');
  assert.match(loyaltyPage, /canManageLoyalty[^\n]*\?[^\n]*loyaltyRecommend[^\n]*Read only/i,
    'loyalty:r and non-owner users need an explicit read-only program cue');
  for (const control of ['lsave', 'rwAdd', 'rwEdit', 'trAdd', 'trEdit', 'trDel', 'boSave', 'boInherit']) {
    assert.match(loyaltyPage, new RegExp(`canManageLoyalty\\?[\\s\\S]{0,500}?${control}`, 'i'),
      `${control} must be visible only to an owner with loyalty:rw`);
  }
  for (const control of ['la', 'lm', 'le', 'lsp', 'lr', 'lc', 'lx', 'ltb']) {
    assert.match(loyaltyPage, new RegExp(`id="${control}"[^>]*\\$\\{loyaltyControlDisabled\\}`, 'i'),
      `${control} must be disabled outside owner loyalty:rw`);
  }
  const readOnlyReturnAt = loyaltyPage.indexOf('if(!canManageLoyalty)return;');
  assert.ok(readOnlyReturnAt > loyaltyPage.indexOf('M().innerHTML='),
    'read-only loyalty state must render before mutation wiring stops');
  for (const rpc of [
    'generate_retention_recommendation', 'save_loyalty_branch_override_draft',
    'remove_loyalty_branch_override_draft', 'create_loyalty_config_draft',
    'save_loyalty_config_draft', 'publish_loyalty_config'
  ]) {
    assert.ok(loyaltyPage.indexOf(`sb.rpc('${rpc}'`, readOnlyReturnAt) > readOnlyReturnAt,
      `${rpc} mutation wiring must remain behind the owner loyalty:rw return guard`);
  }

  const giftPage = app.match(/async function giftcardsPage\(\)\{[\s\S]*?\n\}/)?.[0] || '';
  assert.match(giftPage, /crypto\.randomUUID\s*\(\s*\)/i);
  assert.match(giftPage, /sb\.rpc\('issue_gift_card'[\s\S]*p_idempotency_key\s*:/i);
  assert.match(giftPage, /sb\.rpc\('staff_list_gift_cards'/i);
  assert.doesNotMatch(giftPage, /sb\.from\('gift_cards'\)\.select/i);
  assert.doesNotMatch(giftPage, /\.code\b[\s\S]*Cards on the books/i,
    'list rendering must not rely on the full bearer code');
});

test('rollback suite covers failure atomicity, replays, authorization, RLS and reconciliation', async () => {
  const suite = compact(await read(suitePath));
  assert.match(suite, /\bbegin;/i);
  assert.match(suite, /rollback;$/i);
  for (const phrase of [
    'exact create-client replay', 'changed create-client request',
    'exact consent replay', 'changed consent request', 'forced consent event failure',
    'wrong tenant consent', 'inactive staff consent', 'restricted staff consent', 'anon consent',
    'exact gift-card replay', 'lost-response replay', 'changed gift-card request',
    'wrong-tenant purchaser', 'inactive staff gift', 'restricted staff gift', 'anon gift',
    'raw table', 'module boundary', 'full bearer code', 'sale reconciliation',
    'liability unchanged', 'exactly one consent event', 'module_perms',
    'get_my_modules', 'get_my_personas', 'r override', 'rw override',
    'NULL module_perms', 'mutable PII changed after completion',
    'missing clients key phone lookup PII', 'missing clients key record sale by phone',
    'clients r phone lookup', 'authorized r/rw till sale reconciliation',
    'clients-only referrer link', 'referrals r referrer link',
    'referrals rw atomic link', 'loyalty r classic redemption',
    'loyalty r catalog redemption', 'loyalty r contextual redemption'
  ]) {
    assert.match(suite, new RegExp(phrase, 'i'), `missing rollback coverage: ${phrase}`);
  }
  assert.match(suite, /create trigger[\s\S]*forced consent event failure/i);
  for (const state of ['23505', '42501', '22023']) assert.match(suite, new RegExp(`'${state}'`, 'i'));
});

test('both v41 rollback suites use isolated synthetic fixtures and explicit loyalty r/rw roles', async () => {
  const [integrity, hardening] = await Promise.all([read(suitePath), read(hardeningSuitePath)]);
  for (const [label, suite] of [['integrity', integrity], ['hardening', hardening]]) {
    assert.match(suite, /create temporary table pg_temp\.v41_[a-z_]+_fixture[\s\S]*?on commit drop/i,
      `${label} suite must keep its synthetic identities transaction-local`);
    assert.match(suite, /insert into pg_temp\.v41_[a-z_]+_fixture/i);
    assert.doesNotMatch(suite,
      /select s\.business_id,\s*s\.user_id[\s\S]{0,300}?where s\.role\s*=\s*'owner'[\s\S]{0,300}?limit 1/i,
      `${label} suite must never select an arbitrary existing owner`);
  }
  assert.match(integrity, /'\{"clients":"r","loyalty":"r"\}'::jsonb/i);
  assert.match(integrity, /'\{"clients":"rw","loyalty":"rw"\}'::jsonb/i);
  assert.match(hardening, /'\{"clients":"r","loyalty":"r"\}'::jsonb/i);
  assert.match(hardening, /'\{"clients":"rw","loyalty":"rw"\}'::jsonb/i);
  for (const suite of [integrity, hardening]) {
    assert.match(suite, /app\.can_module_read\(v_business,\s*'loyalty'\)/i);
    assert.match(suite, /app\.can_module_write\(v_business,\s*'loyalty'\)/i);
  }
});
