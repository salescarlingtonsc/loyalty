import assert from 'node:assert/strict';
import { access, readdir, readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const escaped = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

async function repoFile(directory, pattern, description) {
  const entries = await readdir(new URL(directory, root));
  const name = entries.find((entry) => pattern.test(entry));
  assert.ok(name, `${description} file is missing`);
  return `${directory}${name}`;
}

const migrationFile = () => repoFile(
  'db/migrations/',
  /^\d+_frenly_v33_.*(?:action|notification).*\.sql$/i,
  'v33 customer actions and notifications migration'
);

const rollbackFile = () => repoFile(
  'db/tests/',
  /^v33_.*(?:action|notification).*\.sql$/i,
  'v33 customer actions and notifications rollback suite'
);

function functionBlocks(sql) {
  return [...sql.matchAll(
    /create\s+(?:or\s+replace\s+)?function\s+(?:(public|app)\.)?([a-z0-9_]+)\s*\(([^)]*)\)[\s\S]*?(?=\ncreate\s+(?:or\s+replace\s+)?function\b|\n(?:alter|revoke|grant|drop)\s+(?:function|table|policy|trigger)\b|$)/gi
  )].map((match) => ({
    schema: (match[1] ?? 'public').toLowerCase(),
    name: match[2].toLowerCase(),
    signature: match[3].trim(),
    sql: match[0]
  }));
}

function declaration(sql, name) {
  const match = sql.match(new RegExp(
    `create\\s+(?:or\\s+replace\\s+)?function\\s+(?:public\\.)?${escaped(name)}\\s*\\(([^)]*)\\)`,
    'i'
  ));
  assert.ok(match, `${name} declaration is missing`);
  return match[1].trim();
}

function functionBlock(sql, name) {
  const block = functionBlocks(sql).find((item) => item.name === name);
  assert.ok(block, `${name} body is missing`);
  return block;
}

function hasExplicitJson(block) {
  return /jsonb_build_object\s*\(/i.test(block)
    && !/row_to_json\s*\(|to_jsonb\s*\([^)]*\)|select\s+\*/i.test(block);
}

test('v33 migration and adversarial rollback suite are present', async () => {
  const migrationPath = await migrationFile();
  const rollbackPath = await rollbackFile();
  await access(new URL(migrationPath, root));
  await access(new URL(rollbackPath, root));
});

test('authenticated customer actions are business-scoped through slug and verified links', async () => {
  const sql = await read(await migrationFile());
  const actionBlocks = functionBlocks(sql).filter(({ name }) =>
    /customer|booking|appointment/.test(name)
    && /action|cancel|reschedul|request/.test(name)
  );

  assert.ok(actionBlocks.length >= 1, 'v33 must define at least one authenticated customer action RPC');
  for (const { sql: block } of actionBlocks) {
    assert.match(block, /auth\.uid\s*\(\s*\)/i);
    assert.match(block, /customer_links/i);
    assert.match(block, /verified|state\s*=\s*'verified'|status\s*=\s*'verified'/i);
    assert.match(block, /business_id/i);
    assert.match(block, /slug|businesses/i);
    assert.match(block, /appointment_id|appointments/i);
    assert.doesNotMatch(block, /p_(?:business|client|identity|link)_id\s+/i,
      'customer action must derive tenant and customer ownership, not trust caller IDs');
    assert.doesNotMatch(block, /p_phone\s+text|p_email\s+text/i,
      'authenticated customer actions must not fall back to phone/email possession');
  }
});

test('customer actions create immutable requests and never mutate appointments directly', async () => {
  const sql = await read(await migrationFile());
  const actionBlocks = functionBlocks(sql).filter(({ name }) =>
    /customer|booking|appointment/.test(name)
    && /action|cancel|reschedul|request/.test(name)
  );
  const actionTable = sql.match(
    /create\s+table\s+(?:public|app)\.([a-z0-9_]*(?:customer|booking|appointment)[a-z0-9_]*(?:action|request)[a-z0-9_]*)\b[\s\S]*?(?=;\s*(?:create|alter|revoke|grant|comment|$))/i
  )?.[0] ?? '';

  assert.ok(actionTable, 'v33 must persist customer action requests');
  assert.match(actionTable, /business_id\s+uuid\s+not null/i);
  assert.match(actionTable, /appointment_id\s+uuid\s+not null/i);
  assert.match(actionTable, /idempotency|idempotency_key/i);
  assert.match(actionTable, /request_hash|payload_hash|fingerprint/i);
  assert.match(actionTable, /unique\s*\([^)]*(?:idempotency|request_hash)/i);
  assert.match(actionTable, /append.only|immutable|created_at/i);

  assert.ok(actionBlocks.length >= 1);
  for (const { sql: block } of actionBlocks) {
    assert.match(block, /insert\s+into\s+(?:public|app)\.[a-z0-9_]*(?:action|request)/i,
      'customer actions must record a request rather than mutate an appointment');
    assert.match(block, /on\s+conflict|duplicate|replay|idempot/i);
    assert.match(block, /request_hash|payload_hash|fingerprint/i);
    assert.doesNotMatch(block, /(?:insert|update|delete)\s+from\s+public\.appointments/i,
      'customer action RPCs must not directly change appointment rows');
    assert.doesNotMatch(block, /update\s+public\.change_requests/i,
      'new customer actions must not silently reuse the legacy direct-change writer');
  }

  assert.match(sql, /before\s+(?:update\s+or\s+delete|delete\s+or\s+update)[\s\S]{0,500}(?:action|request)/i);
});

test('customer action RPCs are authenticated-only, safe-search-path, and allowlisted', async () => {
  const sql = await read(await migrationFile());
  const v21 = await read('db/migrations/20260719_frenly_v21_security_hardening.sql');
  const blocks = functionBlocks(sql).filter(({ name }) =>
    /customer|booking|appointment/.test(name)
    && /action|cancel|reschedul|request/.test(name)
  );

  assert.ok(blocks.length >= 1);
  for (const { name, signature, sql: block } of blocks) {
    assert.match(block, /security\s+definer/i, `${name} must use the reviewed RPC boundary`);
    assert.match(block, /set\s+search_path\s+to\s+'pg_catalog',\s*'public',\s*'app',\s*'pg_temp'/i,
      `${name} has unsafe search_path`);
    assert.match(block, /auth\.uid\s*\(\s*\)/i);
    assert.match(sql, new RegExp(
      `revoke\\s+all\\s+on\\s+function\\s+(?:public|app)\\.${escaped(name)}\\(${escaped(signature)}\\)\\s+from\\s+public,\\s*anon,\\s*authenticated`,
      'i'
    ), `${name} must revoke default PUBLIC execution`);
    assert.match(sql, new RegExp(
      `grant\\s+execute\\s+on\\s+function\\s+(?:public|app)\\.${escaped(name)}\\(${escaped(signature)}\\)\\s+to\\s+authenticated`,
      'i'
    ));
    assert.doesNotMatch(sql, new RegExp(
      `grant\\s+execute\\s+on\\s+function\\s+(?:public|app)\\.${escaped(name)}\\(${escaped(signature)}\\)\\s+to\\s+anon`,
      'i'
    ));
    assert.match(v21, new RegExp(`['"]${escaped(name)}['"]`, 'i'),
      `${name} must be added to the v21 authenticated RPC allowlist`);
  }
});

test('notification preferences are business-scoped, channel/topic explicit, and consent-timestamped', async () => {
  const sql = await read(await migrationFile());
  const preference = sql.match(
    /create\s+table\s+(?:public|app)\.([a-z0-9_]*(?:notification|communication)[a-z0-9_]*(?:preference|consent)[a-z0-9_]*)\b[\s\S]*?(?=;\s*(?:create|alter|revoke|grant|comment|$))/i
  )?.[0] ?? '';

  assert.ok(preference, 'v33 must define a notification preference/consent table');
  assert.match(preference, /business_id\s+uuid\s+not null/i);
  assert.match(preference, /(?:identity_id|customer_identity_id)\s+uuid\s+not null/i);
  assert.match(preference, /(?:link_id|customer_link_id)\s+uuid\s+not null/i);
  assert.match(preference, /channel\s+text\s+not null/i);
  assert.match(preference, /topic\s+text\s+not null/i);
  assert.match(preference, /(?:consent|opt)[a-z_]*_at\s+timestamptz\s+not null/i);
  assert.match(preference, /(?:marketing|transactional|essential|booking|reminder)/i);
  assert.match(preference, /unique\s*\([^)]*(?:business_id|link_id|customer_link_id)[^)]*(?:channel|topic)/i);
  assert.match(sql, /foreign key\s*\([^)]*(?:business_id|link_id|customer_link_id)[^)]*\)[\s\S]{0,300}customer_links/i);
  assert.doesNotMatch(preference, /global|platform_wide|all_businesses|cross_business/i);
  assert.doesNotMatch(sql, /create\s+table\s+(?:public|app)\.[a-z0-9_]*notification[a-z0-9_]*\s*\([^)]*\b(?:email|phone)\s+text/i);
});

test('notification outbox is append-only and provider-neutral', async () => {
  const sql = await read(await migrationFile());
  const outbox = sql.match(
    /create\s+table\s+(?:public|app)\.([a-z0-9_]*(?:notification|communication)[a-z0-9_]*(?:outbox|event|delivery)[a-z0-9_]*)\b[\s\S]*?(?=;\s*(?:create|alter|revoke|grant|comment|$))/i
  )?.[0] ?? '';

  assert.ok(outbox, 'v33 must define an append-only notification event/outbox model');
  assert.match(outbox, /business_id\s+uuid\s+not null/i);
  assert.match(outbox, /(?:identity_id|customer_identity_id|link_id|customer_link_id)/i);
  assert.match(outbox, /(?:event_type|topic|kind)\s+text\s+not null/i);
  assert.match(outbox, /(?:delivery_status|status)\s+text\s+not null/i);
  assert.match(outbox, /(?:pending|queued|suppressed|failed|processing|sent)/i);
  assert.match(outbox, /created_at\s+timestamptz\s+not null/i);
  assert.match(sql, /before\s+(?:update\s+or\s+delete|delete\s+or\s+update)[\s\S]{0,500}(?:notification|outbox|event)/i);
  assert.doesNotMatch(sql, /(?:pg_net|http_post|net\.http|resend|sendgrid|twilio|whatsapp|smtp|fetch\s*\()/i,
    'v33 must not claim or require an outbound provider');
  assert.doesNotMatch(outbox, /(?:delivered_at|provider_delivered|delivery_confirmed_at)\s+/i,
    'the outbox must not imply provider delivery without a provider contract');
});

test('booking preference controls pending versus suppressed outbox state', async () => {
  const sql = await read(await migrationFile());
  assert.match(sql, /'appointment_action_requested',\s*'booking_updates',\s*'in_app'/i);
  assert.match(sql, /customer_notification_preferences[\s\S]*p\.topic = 'booking_updates'[\s\S]*not p\.opted_in[\s\S]*then 'suppressed' else 'pending'/i);
});

test('legacy anonymous Turnstile gateway and opaque management tokens remain intact', async () => {
  const [v19, v33] = await Promise.all([
    read('db/migrations/20260718180602_frenly_v19_public_gateway_security.sql'),
    read(await migrationFile())
  ]);

  for (const symbol of [
    'internal_public_booking_submit',
    'internal_public_booking_lookup',
    'internal_public_booking_change',
    'booking_management_tokens',
    'booking_management_change_submissions'
  ]) assert.match(v19, new RegExp(escaped(symbol), 'i'), `${symbol} must remain the legacy gateway contract`);

  assert.doesNotMatch(v33, /drop\s+(?:table|function)\s+(?:public\.)?(?:appointments|booking_requests|change_requests|internal_public_booking|request_change)/i);
  assert.doesNotMatch(v33, /create\s+(?:or\s+replace\s+)?function\s+public\.(?:internal_public_booking|request_change)/i);
  assert.match(v19, /turnstile|captcha/i);
  assert.match(v19, /token_hash\s+bytea|opaque|management_token/i);
});

test('SPA customer actions and notifications remain launch-gated until provider operations are approved', async () => {
  const app = await read('app/index.html');
  assert.match(app, /CUSTOMER_FEATURES_EMERGENCY_DISABLED/i,
    'customer-facing features need an emergency fail-closed build gate');
  assert.match(app, /\.rpc\(\s*['"]get_customer_feature_capabilities['"]/i,
    'normal customer enablement must come from private server capabilities');
  assert.match(app, /customerFeatures\.customer_actions/i);
  assert.match(app, /customerFeatures\.customer_notifications/i);
  assert.doesNotMatch(app, /customer_(?:request|cancel|reschedule|notification)[a-z_]*\s*\([^)]*\)\s*;?\s*(?!if|&&|\?)/i,
    'customer actions must not be wired as unconditional calls');
});

test('v33 rollback suite covers isolation, replay, consent, provider neutrality, and legacy boundaries', async () => {
  const suite = await read(await rollbackFile());
  assert.match(suite, /^begin\s*;/im);
  assert.match(suite, /^rollback\s*;/im);
  for (const assertion of [
    'auth.uid', 'verified', 'customer_links', 'business A', 'business B',
    'cross.business|cross business|wrong business', 'appointment', 'booking',
    'cancel', 'reschedul', 'direct.*appointment|appointment.*direct',
    'idempot', 'request_hash|payload_hash', 'replay', 'mismatch|hash',
    'anonymous|anon|PUBLIC', 'staff', 'rate.?limit',
    'notification', 'preference', 'channel', 'topic', 'consent',
    'outbox|event', 'pending|queued|failed|suppressed', 'provider',
    'no duplicate|duplicate', 'Turnstile|captcha', 'opaque|management token',
    'search_path', 'ACL|grant|execute', 'direct table|raw table'
  ]) assert.match(suite, new RegExp(assertion, 'i'), `rollback suite must cover ${assertion}`);
});
