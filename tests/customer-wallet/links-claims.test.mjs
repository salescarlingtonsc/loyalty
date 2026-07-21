import assert from 'node:assert/strict';
import { access, readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const migrationPath = 'db/migrations/20260720_frenly_v31_customer_links_claims.sql';
const rollbackPath = 'db/tests/v31_customer_links_claims.sql';

// These names are the v31 API contract. Signatures remain migration-owned.
const expectedRpcNames = [
  'customer_claim_link_by_email',
  'customer_issue_link_invitation',
  'customer_claim_link_invitation',
  'customer_unlink_business_link'
];

const read = (path) => readFile(new URL(path, root), 'utf8');
const escaped = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const functionBlocks = (sql) => {
  const blocks = [];
  const pattern = /create\s+or\s+replace\s+function\s+((?:public|app)\.)?(customer|staff)_[a-z0-9_]+\s*\([^)]*\)[\s\S]*?(?=\ncreate\s+or\s+replace\s+function\s+|\n(?:alter|revoke|grant|create\s+trigger|--|$))/gi;
  for (const match of sql.matchAll(pattern)) blocks.push({ name: match[0].match(/(?:customer|staff)_[a-z0-9_]+/i)?.[0], sql: match[0] });
  return blocks;
};
const functionIdentityTypes = (sql, name) => {
  const declaration = sql.match(new RegExp(
    `create\\s+or\\s+replace\\s+function\\s+(?:public|app)\\.${escaped(name)}\\s*\\(([^)]*)\\)`,
    'i'
  ))?.[1] ?? '';
  if (!declaration.trim()) return '';
  return declaration
    .split(',')
    .map((argument) => argument
      .replace(/\s+default\s+[\s\S]*$/i, '')
      .trim()
      .replace(/^[a-z_][a-z0-9_]*\s+/i, ''))
    .join(', ');
};

test('v31 migration and rollback suite are present', async () => {
  await access(new URL(migrationPath, root));
  await access(new URL(rollbackPath, root));
});

test('v31 models business-scoped links, invitations, claims, and unlink events', async () => {
  const sql = await read(migrationPath);

  for (const table of [
    'customer_links',
    'customer_link_claim_attempts',
    'customer_link_invitations',
    'customer_link_unlink_events'
  ]) {
    assert.match(sql, new RegExp(`create table public\\.${table}\\b`, 'i'), `${table} table is required`);
    assert.match(sql, new RegExp(`alter table public\\.${table} enable row level security`, 'i'));
    assert.match(sql, new RegExp(`revoke all privileges on table public\\.${table}\\s+from public,\\s*anon,\\s*authenticated`, 'i'));
  }

  assert.match(sql, /customer_links[\s\S]*?foreign key\s*\(\s*identity_id\s*,\s*auth_user_id\s*\)[\s\S]*?references\s+public\.customer_identities\s*\(id\s*,\s*auth_user_id\)/i);
  assert.match(sql, /customer_links[\s\S]*?business_id\s+uuid\s+not null\s+references\s+public\.businesses\s*\(id\)/i);
  assert.match(sql, /customer_links[\s\S]*?business_id\s*,\s*client_id[\s\S]*?references\s+public\.clients\s*\(business_id\s*,\s*id\)/i);

  assert.match(sql, /customer_links[\s\S]*?check\s*\(state\s+in\s*\(\s*'pending'\s*,\s*'verified'\s*,\s*'rejected'\s*,\s*'unlinked'/i);
  assert.match(sql, /create unique index[\s\S]*?on public\.customer_links\s*\(\s*business_id\s*,\s*identity_id\s*\)[\s\S]*?where\s+state\s*=\s*'verified'/i);
  assert.match(sql, /create unique index[\s\S]*?on public\.customer_links\s*\(\s*business_id\s*,\s*client_id\s*\)[\s\S]*?where\s+state\s*=\s*'verified'/i);
  assert.match(sql, /customer_links[\s\S]*?state\s*=\s*'unlinked'[\s\S]*?updated_at/i);

  assert.match(sql, /customer_link_claim_attempts[\s\S]*?request_hash\s+text\s+not null/i);
  assert.match(sql, /customer_link_claim_attempts[\s\S]*?idempotency_key\s+text\s+not null/i);
  assert.match(sql, /customer_link_claim_attempts[\s\S]*?unique\s*\([^)]*identity_id[^)]*idempotency_key[^)]*\)/i);
  assert.match(sql, /customer_link_unlink_events_link_tenant_fk[\s\S]*?foreign key\s*\(\s*link_id\s*,\s*business_id\s*,\s*client_id\s*\)[\s\S]*?references\s+public\.customer_links\s*\(id\s*,\s*business_id\s*,\s*client_id\)/i);
});

test('v31 does not persist raw contact or invitation secret material', async () => {
  const sql = await read(migrationPath);
  const tableBlocks = [...sql.matchAll(/create\s+table\s+public\.(customer_(?:links|link_claim_attempts|link_invitations|link_unlink_events))\b[\s\S]*?;\s*/gi)]
    .map((match) => ({ table: match[1], sql: match[0] }));

  assert.ok(tableBlocks.length >= 4, 'all v31 table definitions must be inspectable');
  for (const { table, sql: block } of tableBlocks) {
    assert.doesNotMatch(block, /\b(?:email|phone|token)\s+(?:text|varchar|citext|jsonb)\b/i, `${table} stores raw contact/token material`);
    assert.doesNotMatch(block, /\b(?:email|phone|token)\s+[^,\n]*\bdefault\b/i, `${table} has a raw contact/token default`);
  }

  const invitation = tableBlocks.find(({ table }) => table === 'customer_link_invitations')?.sql ?? '';
  assert.match(invitation, /token_hash\s+(?:text|bytea)\s+not null/i);
  assert.match(invitation, /recipient_email_hash\s+(?:text|bytea)\s+not null/i);
  assert.doesNotMatch(invitation, /\btoken\s+(?:text|varchar|citext|jsonb)\b/i);
  assert.doesNotMatch(invitation, /\b(?:email|phone)\s+(?:text|varchar|citext|jsonb)\b/i);
  assert.match(sql, /token_hash[\s\S]*?(?:unique|index)/i);

  const claimBlocks = functionBlocks(sql).filter(({ name }) => /claim/i.test(name ?? ''));
  assert.ok(claimBlocks.length >= 1, 'a customer claim RPC is required');
  for (const { sql: block } of claimBlocks) {
    assert.doesNotMatch(block, /return\s+jsonb_build_object\s*\([\s\S]{0,700}\b(?:email|phone|token|token_hash)\b/i);
    assert.doesNotMatch(block, /insert\s+into\s+public\.customer_link_invitations[\s\S]{0,900}\btoken\s*(?:,|\))/i);
  }
});

test('email claim derives auth.uid and auth.users, enforces exact-one candidates, and is generic', async () => {
  const sql = await read(migrationPath);
  const claimBlocks = functionBlocks(sql).filter(({ name }) => /customer_.*claim/i.test(name ?? '') && !/invitation|invite|token/i.test(name ?? ''));
  assert.equal(claimBlocks.length, 1, 'exactly one direct customer email-claim RPC is required');
  const claim = claimBlocks[0].sql;

  assert.match(claim, /auth\.uid\s*\(\s*\)/i);
  assert.match(claim, /from\s+auth\.users\s+[a-z]+[\s\n]+where\s+[a-z]+\.id\s*=\s*(?:v_actor|auth\.uid\s*\(\s*\))/i);
  assert.doesNotMatch(claim, /p_(?:email|phone)|email\s+text\s+default|phone\s+text\s+default/i);
  assert.match(claim, /count\s*\(\s*\*\s*\)[\s\S]{0,500}(?:=|>)\s*1|select\s+count\s*\(\s*\*\s*\)[\s\S]{0,500}(?:=|>)\s*1/i);
  assert.match(claim, /duplicate|ambiguous|more than one|exactly one/i);
  assert.match(claim, /generic|try again|unable to|not available|request received/i);
  assert.doesNotMatch(claim, /similar|levenshtein|ilike|lower\s*\([^)]*name|name\s*=|phone\s*=.*email/i);
  assert.match(claim, /customer_link_claim_attempts/i);
  assert.match(claim, /request_hash/i);
  assert.match(claim, /rate.?limit|cooldown|attempt/i);
  assert.match(claim, /customer_link_audit_events\s*\([\s\S]*client_id[\s\S]*link_id/i,
    'successful link audit evidence must carry the client tenant key required by its FK');
});

test('invitation creation and claim are single-use, expiring, idempotent, and return the secret once', async () => {
  const sql = await read(migrationPath);
  const invitationBlocks = functionBlocks(sql).filter(({ name }) => /invite|invitation/i.test(name ?? ''));
  const claimBlocks = functionBlocks(sql).filter(({ name }) => /claim/i.test(name ?? ''));
  assert.ok(invitationBlocks.length >= 1, 'a staff invitation RPC is required');
  assert.ok(claimBlocks.length >= 1, 'a claim RPC is required');

  const invitation = invitationBlocks.map(({ sql: block }) => block).join('\n');
  const claims = claimBlocks.map(({ sql: block }) => block).join('\n');
  assert.match(invitation, /auth\.uid\s*\(\s*\)/i);
  assert.match(invitation, /is_staff|staff|business_id/i);
  assert.match(invitation, /token_hash/i);
  assert.match(invitation, /gen_random_bytes|encode\s*\(|digest\s*\(|md5\s*\(/i);
  assert.match(invitation, /expires_at\s*:=|expires_at\s*[<>]=?|interval/i);
  assert.match(invitation, /customer_link_invitation_issues[\s\S]*count\s*\(\s*\*\s*\)[\s\S]*(?:15 minutes|try later)/i,
    'fresh invitation-issue keys need a bounded abuse control');
  assert.match(invitation, /invitation-issue-rate:[\s\S]*pg_advisory_xact_lock|pg_advisory_xact_lock[\s\S]*invitation-issue-rate:/i,
    'distinct invitation keys must serialize on one actor-scoped rate-limit lock');
  assert.match(invitation, /return\s+jsonb_build_object[\s\S]{0,600}(?:token|invite_token)/i);
  assert.match(invitation, /invitation_already_issued[\s\S]{0,400}'token',\s*null/i);
  assert.match(claims, /expires_at\s*[<>]=?|expired|expiry/i);
  assert.match(claims, /recipient_email_hash[\s\S]*auth\.users|auth\.users[\s\S]*recipient_email_hash/i,
    'an unconsumed invitation must be bound to the intended confirmed Auth email');
  assert.match(claims, /claimed_at|state\s*=\s*'claimed'|consumed_at/i);
  assert.match(claims, /for\s+update|update[\s\S]{0,500}(?:claimed_at|consumed_at|state)/i);
  assert.match(claims, /idempotency_key/i);
  assert.match(claims, /request_hash/i);
  assert.match(claims, /on conflict|already|replay|retry/i);
  assert.doesNotMatch(claims, /return\s+jsonb_build_object\s*\([\s\S]{0,600}\btoken_hash\b/i);
});

test('unlink is an audited state transition and does not delete link or client history', async () => {
  const sql = await read(migrationPath);
  const unlinkBlocks = functionBlocks(sql).filter(({ name }) => /unlink/i.test(name ?? ''));
  assert.ok(unlinkBlocks.length >= 1, 'an unlink RPC is required');
  const unlink = unlinkBlocks.map(({ sql: block }) => block).join('\n');
  assert.match(unlink, /auth\.uid\s*\(\s*\)/i);
  assert.match(unlink, /state\s*=\s*'unlinked'/i);
  assert.match(unlink, /customer_link_unlink_events/i);
  assert.match(unlink, /idempotency_key/i);
  assert.match(unlink, /request_hash/i);
  assert.match(unlink, /count\s*\(\s*\*\s*\)[\s\S]*(?:15 minutes|try later)/i,
    'fresh unlink keys need a bounded abuse control');
  assert.match(unlink, /unlink-rate:[\s\S]*pg_advisory_xact_lock|pg_advisory_xact_lock[\s\S]*unlink-rate:/i,
    'distinct unlink keys must serialize on one identity-scoped rate-limit lock');
  assert.doesNotMatch(unlink, /delete\s+from\s+public\.customer_links/i);
  assert.doesNotMatch(unlink, /delete\s+from\s+public\.clients/i);
  assert.match(sql, /create trigger customer_link_unlink_events_immutable_guard[\s\S]*?before update or delete on public\.customer_link_unlink_events/i);
  assert.match(sql, /new\.recipient_email_hash[\s\S]*old\.recipient_email_hash/i,
    'the intended-recipient binding must be immutable across invitation claim');
});

test('v31 customer and staff RPCs are authenticated-only, safe-search-path, and allowlisted', async () => {
  const sql = await read(migrationPath);
  assert.ok((sql.match(/platform_feature_enabled\('customer_claims'\)/gi)??[]).length >= 4,
    'every claim/invitation/unlink RPC must fail closed behind the private server gate');
  assert.doesNotMatch(sql, /v_identity uuid := app\.v31_current_identity\(\)/i,
    'the gate must run before resolving whether a customer identity exists');
  const blocks = functionBlocks(sql);
  assert.ok(blocks.length >= 3, 'v31 must define customer/staff RPCs');

  for (const name of expectedRpcNames) {
    assert.match(sql, new RegExp(`create\\s+or\\s+replace\\s+function\\s+(?:public|app)\\.${escaped(name)}\\s*\\(`, 'i'), `${name} is required`);
  }

  for (const { name, sql: block } of blocks) {
    assert.match(block, /security\s+definer/i, `${name} must be security definer`);
    assert.match(block, /set\s+search_path\s+to\s+'pg_catalog',\s*'public',\s*'app',\s*'pg_temp'/i, `${name} has unsafe search_path`);
    assert.match(block, /auth\.uid\s*\(\s*\)/i, `${name} must derive caller identity`);
    assert.match(block, /idempotency_key|idempotent/i, `${name} lacks idempotency contract`);
    assert.match(block, /request_hash|audit/i, `${name} lacks immutable request/audit evidence`);
  }

  for (const { name } of blocks) {
    const signature = functionIdentityTypes(sql, name);
    assert.notEqual(signature, '', `${name} signature must be discoverable`);
    const fn = `${name}(${signature})`;
    assert.match(sql, new RegExp(`revoke\\s+all\\s+on\\s+function\\s+(?:public|app)\\.${escaped(fn)}\\s+from\\s+public,\\s*anon,\\s*authenticated`, 'i'), `${fn} raw ACL revoke missing`);
    assert.match(sql, new RegExp(`grant\\s+execute\\s+on\\s+function\\s+(?:public|app)\\.${escaped(fn)}\\s+to\\s+authenticated`, 'i'), `${fn} authenticated grant missing`);
    assert.doesNotMatch(sql, new RegExp(`grant\\s+execute\\s+on\\s+function\\s+(?:public|app)\\.${escaped(fn)}\\s+to\\s+anon`, 'i'));
  }
});

test('v31 rollback suite is a real adversarial transaction suite', async () => {
  const suite = await read(rollbackPath);
  assert.match(suite, /^begin;\s*$/im);
  assert.match(suite, /^rollback;\s*$/im);
  for (const assertion of [
    'raw email', 'raw phone', 'raw token', 'token_hash',
    'generic', 'ambiguous', 'exactly one', 'name', 'phone',
    'same business', 'cross.business', 'expired', 'single.use', 'pre-consumption.*theft',
    'changed.*Auth contact',
    'replay', 'idempot', 'unlinked', 'delete', 'PUBLIC', 'anon',
    'customer A', 'customer B', 'business A', 'business B'
  ]) assert.match(suite, new RegExp(assertion, 'i'), `rollback suite must cover ${assertion}`);
});
