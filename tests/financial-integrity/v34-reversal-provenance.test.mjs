import assert from 'node:assert/strict';
import { access, readdir, readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const escaped = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const migrationFile = () => findRepoFile(
  'db/migrations/',
  /^\d+_frenly_v34_.*\.sql$/i,
  'v34 reversal provenance migration'
);

const rollbackFile = () => findRepoFile(
  'db/tests/',
  /^v34_.*\.sql$/i,
  'v34 reversal provenance rollback suite'
);

async function findRepoFile(directory, pattern, description) {
  const entries = await readdir(new URL(directory, root));
  const name = entries.find((entry) => pattern.test(entry));
  assert.ok(name, `${description} is missing`);
  return `${directory}${name}`;
}

function declarations(sql) {
  return [...sql.matchAll(
    /create\s+(?:or\s+replace\s+)?function\s+(public|app)\.([a-z0-9_]+)\s*\(([^)]*)\)\s*returns\b/gi
  )].map((match) => ({
    schema: match[1].toLowerCase(),
    name: match[2].toLowerCase(),
    args: match[3],
    start: match.index
  }));
}

function functionBlock(sql, name) {
  const declaration = declarations(sql).find((item) => item.name === name);
  assert.ok(declaration, `${name} declaration is missing from the v34 migration`);
  const rest = sql.slice(declaration.start);
  const next = rest.search(/\ncreate\s+(?:or\s+replace\s+)?function\b/i);
  return next < 0 ? rest : rest.slice(0, next);
}

function argumentTypes(args) {
  return args
    .split(',')
    .map((argument) => argument
      .replace(/\s+default\s+[\s\S]*$/i, '')
      .trim()
      .replace(/^(?:in|out|inout|variadic)\s+/i, '')
      .replace(/^[a-z_][a-z0-9_]*\s+/i, '')
      .replace(/\s+/g, ' '))
    .filter(Boolean)
    .join(', ');
}

function aclStatements(sql, verb, name) {
  return [...sql.matchAll(new RegExp(
    `${verb}\\s+(?:all(?:\\s+privileges)?|execute)\\s+on\\s+function\\s+public\\.${escaped(name)}\\s*\\(([^)]*)\\)[\\s\\S]*?(?=;|$)`,
    'gi'
  ))].map((match) => ({ args: argumentTypes(match[1]), sql: match[0] }));
}

function assertAuthenticatedOnly(sql, name) {
  const declaration = declarations(sql).find((item) => item.name === name);
  assert.ok(declaration, `${name} declaration is required`);
  const signature = argumentTypes(declaration.args);
  const revoke = aclStatements(sql, 'revoke', name).find((item) => item.args === signature);
  const grant = aclStatements(sql, 'grant', name).find((item) => item.args === signature);
  assert.ok(revoke, `${name}(${signature}) must have an explicit execute revoke`);
  assert.match(revoke.sql, /from\s+public\s*,\s*anon(?:\s*,\s*authenticated)?/i);
  assert.ok(grant, `${name}(${signature}) must have an explicit execute grant`);
  assert.match(grant.sql, /to\s+authenticated\b/i);
  assert.doesNotMatch(grant.sql, /to\s+anon\b/i);
  assert.doesNotMatch(sql, new RegExp(
    `grant\\s+execute\\s+on\\s+function\\s+public\\.${escaped(name)}\\s*\\([^)]*\\)\\s+to\\s+anon\\b`,
    'i'
  ));
}

function tableBlocks(sql) {
  return [...sql.matchAll(
    /create\s+table\s+(?:if\s+not\s+exists\s+)?(?:public\.)?([a-z0-9_]+)\s*\(([^]*?)\)\s*;/gi
  )].map((match) => ({ name: match[1].toLowerCase(), body: match[0] }));
}

function assertSafeDefiner(block, name) {
  assert.match(block, /security\s+definer/i, `${name} must be SECURITY DEFINER`);
  assert.match(
    block,
    /set\s+search_path\s+to\s+'pg_catalog',\s*'public',\s*'app',\s*'pg_temp'/i,
    `${name} must pin the v21 search_path`
  );
  assert.match(block, /auth\.uid\s*\(\s*\)/i, `${name} must derive the actor from auth.uid()`);
}

test('v34 migration and rollback suite are present', async () => {
  await access(new URL(await migrationFile(), root));
  await access(new URL(await rollbackFile(), root));
});

test('package-session consumption is idempotent and carries immutable sale provenance', async () => {
  const sql = await read(await migrationFile());
  const useSession = functionBlock(sql, 'use_package_session');
  const tables = tableBlocks(sql);
  const packageEvidence = tables.find(({ name, body }) =>
    /package|session|consum/i.test(name)
    && /client[_ ]packages?|client_package/i.test(body)
    && /sale_id/i.test(body)
  );

  assert.ok(packageEvidence, 'v34 must add a package-session provenance table');
  assert.match(packageEvidence.body, /(?:consum|session|usage)/i);
  assert.match(packageEvidence.body, /idempotency_key|operation_key/i);
  assert.match(packageEvidence.body, /request_hash|payload_hash/i);
  assert.match(packageEvidence.body, /sale_id\s+uuid[^;]*not\s+null|sale_id[^\n]*not\s+null/i);
  assert.match(packageEvidence.body, /unique\s*\([^)]*(?:idempotency|operation|sale_id|session)/i);
  assert.match(sql, new RegExp(
    `(?:foreign key|references)[^;]*(?:client_packages|client_package)[^;]*|(?:client_packages|client_package)[^;]*(?:foreign key|references)`,
    'i'
  ));
  assert.match(sql, new RegExp(
    `(?:foreign key|references)[^;]*sales[^;]*|sales[^;]*(?:foreign key|references)`,
    'i'
  ));

  assertSafeDefiner(useSession, 'use_package_session');
  assert.match(useSession, /idempotency_key|operation_key/i);
  assert.match(useSession, /request_hash|payload_hash/i);
  assert.match(useSession, /on\s+conflict|already|replay|duplicate|idempotent/i);
  assert.match(useSession, /client_packages|client_package/i);
  assert.match(useSession, /for\s+update/i);
  assert.match(useSession, /remaining\s*>\s*0/i);
  assert.match(useSession, /remaining\s*=\s*remaining\s*-\s*1|remaining\s*-\s*1/i);
  assert.match(useSession, /insert\s+into\s+(?:public\.)?sales/i);
  assert.match(useSession, /amount_cents\s*[,)]\s*0|amount_cents\s*=\s*0|0\s*,\s*(?:now\s*\(\s*\)|'service')/i);
  assert.match(useSession, /sale_id/i);

  const packageTableName = packageEvidence.name;
  assert.match(sql, new RegExp(
    `alter\\s+table\\s+(?:public\\.)?${escaped(packageTableName)}\\s+enable\\s+row\\s+level\\s+security`,
    'i'
  ));
  assert.match(sql, new RegExp(
    `revoke\\s+all(?:\\s+privileges)?\\s+on\\s+table\\s+(?:public\\.)?${escaped(packageTableName)}\\s+from\\s+public\\s*,\\s*anon\\s*,\\s*authenticated`,
    'i'
  ));
  assert.match(sql, new RegExp(
    `create\\s+trigger[^;]*(?:immutable|append|guard)[^;]*on\\s+(?:public\\.)?${escaped(packageTableName)}|create\\s+trigger[^;]*on\\s+(?:public\\.)?${escaped(packageTableName)}[^;]*(?:immutable|append|guard)`,
    'i'
  ));
});

test('reverse_sale restores exactly one proven package session without a money refund', async () => {
  const sql = await read(await migrationFile());
  const reverseSale = functionBlock(sql, 'reverse_sale');

  assertSafeDefiner(reverseSale, 'reverse_sale');
  assert.match(reverseSale, /package|client_package/i);
  assert.match(reverseSale, /session|consum|provenance/i);
  assert.match(reverseSale, /sale_id|original_sale_id/i);
  assert.match(reverseSale, /for\s+update/i);
  assert.match(reverseSale, /remaining\s*=\s*remaining\s*\+\s*1|remaining\s*\+\s*1|restore[d]?[_ ]?session/i);
  assert.match(reverseSale, /on\s+conflict|already\s+reversed|replayed|idempot/i);
  assert.match(reverseSale, /restor|compensat|reversal/i);
  assert.doesNotMatch(
    reverseSale,
    /if\s+o\.amount_cents\s*<=\s*0\s+then[\s\S]{0,220}raise\s+exception/i,
    'v34 must not reject every zero-dollar package-session sale before proving its type'
  );

  assert.match(reverseSale, /amount_cents\s*=\s*0|amount_cents\s*<=\s*0|zero[- ](?:dollar|amount)/i);
  assert.match(reverseSale, /refunded_payment_cents|payment_refund|refund_payment|payments/i);
  assert.match(reverseSale, /(?:package|session)[\s\S]{0,800}(?:no|zero|0)[\s\S]{0,800}(?:refund|payment|money)|(?:no|zero|0)[\s\S]{0,800}(?:refund|payment|money)[\s\S]{0,800}(?:package|session)/i);

  const tables = tableBlocks(sql);
  const restoreEvidence = tables.find(({ name, body }) =>
    /restore|reversal|compensat/i.test(name)
    && /package|session/i.test(body)
  );
  assert.ok(restoreEvidence, 'session restoration must be recorded as its own immutable event or provenance row');
  assert.match(restoreEvidence.body, /unique\s*\([^)]*(?:sale|consum|session|operation)/i);
  assert.match(sql, new RegExp(
    `create\\s+trigger[^;]*(?:immutable|append|guard)[^;]*on\\s+(?:public\\.)?${escaped(restoreEvidence.name)}|create\\s+trigger[^;]*on\\s+(?:public\\.)?${escaped(restoreEvidence.name)}[^;]*(?:immutable|append|guard)`,
    'i'
  ));
});

test('loyalty redemption provenance links every immutable child and every FEFO batch drain', async () => {
  const sql = await read(await migrationFile());
  const tables = tableBlocks(sql);
  const evidenceTables = tables.filter(({ name, body }) =>
    /redemption|loyalty/i.test(name)
    && /provenance|evidence|drain/i.test(`${name} ${body}`)
  );
  assert.ok(evidenceTables.length > 0, 'v34 must add a loyalty redemption provenance model');
  const evidence = evidenceTables.map(({ body }) => body).join('\n');

  assert.match(evidence, /operation_id|loyalty_operation_id/i);
  assert.match(evidence, /redemption_id|loyalty_redemption_id/i);
  assert.match(evidence, /points_ledger_id|points_entry_id/i);
  assert.match(evidence, /credit_ledger_id|credit_entry_id/i);
  assert.match(evidence, /points_batch_id|batch_id/i);
  assert.match(evidence, /(?:drained|consumed|taken|points)\s+(?:integer|bigint|numeric)|drained_points|consumed_points/i);
  assert.match(evidence, /unique\s*\([^)]*(?:redemption|batch)/i);
  assert.match(sql, /loyalty_operations|loyalty_operation/i);
  assert.match(sql, /loyalty_redemptions/i);
  assert.match(sql, /points_ledger/i);
  assert.match(sql, /credit_ledger/i);
  assert.match(sql, /points_batches/i);
  assert.match(sql, /foreign key|references/i);

  for (const { name } of evidenceTables) {
    assert.match(sql, new RegExp(
      `alter\\s+table\\s+(?:public\\.)?${escaped(name)}\\s+enable\\s+row\\s+level\\s+security`,
      'i'
    ), `${name} must have RLS enabled`);
    assert.match(sql, new RegExp(
      `revoke\\s+all(?:\\s+privileges)?\\s+on\\s+table\\s+(?:public\\.)?${escaped(name)}\\s+from\\s+public\\s*,\\s*anon\\s*,\\s*authenticated`,
      'i'
    ), `${name} must not be directly writable`);
    assert.match(sql, new RegExp(
      `create\\s+trigger[^;]*(?:immutable|append|guard)[^;]*on\\s+(?:public\\.)?${escaped(name)}|create\\s+trigger[^;]*on\\s+(?:public\\.)?${escaped(name)}[^;]*(?:immutable|append|guard)`,
      'i'
    ), `${name} must be append-only`);
  }

  const redemptionWriters = declarations(sql).filter(({ name }) =>
    /^(?:redeem_points|redeem_reward|redeem_reward_core)$/.test(name)
  );
  assert.ok(redemptionWriters.length > 0, 'v34 must integrate provenance into the redemption write path');
  for (const writer of redemptionWriters) {
    const block = functionBlock(sql, writer.name);
    assert.match(block, /loyalty_operations|operation_id/i);
    assert.match(block, /loyalty_redemptions/i);
    assert.match(block, /points_batches/i);
    assert.match(block, /points_batch_id|batch_id|drain/i);
    assert.match(block, /points_ledger/i);
    assert.match(block, /credit_ledger/i);
    assert.match(block, /for\s+update/i);
  }
});

test('reverse_loyalty_redemption is a dedicated staff-only compensation path', async () => {
  const sql = await read(await migrationFile());
  const reverse = functionBlock(sql, 'reverse_loyalty_redemption');
  const declaration = declarations(sql).find(({ name }) => name === 'reverse_loyalty_redemption');

  assertSafeDefiner(reverse, 'reverse_loyalty_redemption');
  assert.match(declaration.args, /redemption|claim/i, 'the RPC must identify a redemption, not a sale');
  assert.match(declaration.args, /idempotency/i);
  assert.doesNotMatch(declaration.args, /(?:p_)?sale(?:_id)?\s+uuid/i, 'standalone loyalty reversal must not require a sale id');
  assert.match(reverse, /auth\.uid\s*\(\s*\)/i);
  assert.match(reverse, /staff/i);
  assert.match(reverse, /active/i);
  assert.match(reverse, /app\.has_perm\s*\([^)]*,\s*'(?:refund_sales|create_sales|manage_loyalty)'\)/i);
  assert.match(reverse, /for\s+update/i);
  assert.match(reverse, /idempotency_key|operation_key/i);
  assert.match(reverse, /request_hash|payload_hash/i);
  assert.match(reverse, /on\s+conflict|replay|already|duplicate/i);
  assert.match(reverse, /points_batches/i);
  assert.match(reverse, /points_batch_id|batch_id|drain/i);
  assert.match(reverse, /remaining\s*=\s*remaining\s*\+|remaining\s*\+/i);
  assert.match(reverse, /points_ledger/i);
  assert.match(reverse, /points\s*[+]|points\s*>\s*0|positive/i);
  assert.match(reverse, /credit_ledger/i);
  assert.match(reverse, /credit_ledger_id|credit_entry_id/i);
  assert.match(reverse, /amount_cents\s*[+-]|amount_cents\s*<\s*0|credit_cents/i);
  assert.match(reverse, /if|case/i);
  assert.match(reverse, /provenance|evidence/i);
  assert.match(reverse, /not\s+found|missing|incomplete|complete/i);
  assert.match(reverse, /raise\s+exception/i);
  assert.doesNotMatch(reverse, /(?:update|delete)\s+from\s+public\.loyalty_redemptions/i);
  assert.doesNotMatch(reverse, /(?:update|delete)\s+from\s+public\.(?:points_ledger|credit_ledger|points_batches)/i);

  assertAuthenticatedOnly(sql, 'reverse_loyalty_redemption');
});

test('v34 preserves ledger guards, invariant checks, and v21 RPC registration', async () => {
  const sql = await read(await migrationFile());
  const stamp = functionBlock(sql, 'stamp_config_version');

  assert.match(stamp, /to_jsonb\(new\)\s*->>\s*'reversal_of'/i,
    'the shared trigger must not dereference a sales-only NEW field on ledger tables');
  assert.match(stamp, /to_jsonb\(new\)\s*->>\s*'sale_id'/i,
    'the shared trigger must not dereference a ledger-only NEW field on other tables');
  const v21Migration = await read('db/migrations/20260719_frenly_v21_security_hardening.sql');
  const v21Suite = await read('db/tests/v21_security_hardening.sql');

  for (const name of ['use_package_session', 'reverse_sale', 'reverse_loyalty_redemption']) {
    assertAuthenticatedOnly(sql, name);
    assert.match(v21Migration, new RegExp(`['"]${escaped(name)}['"]`, 'i'), `${name} is missing from the v21 migration allowlist`);
    assert.match(v21Suite, new RegExp(`['"]${escaped(name)}['"]`, 'i'), `${name} is missing from the v21 suite allowlist`);
  }

  const changedPublic = declarations(sql).filter(({ schema, name }) =>
    schema === 'public' && /^(?:redeem_points|redeem_reward|redeem_reward_core|use_package_session|reverse_sale|reverse_loyalty_redemption)$/.test(name)
  );
  for (const declaration of changedPublic) {
    assertSafeDefiner(functionBlock(sql, declaration.name), declaration.name);
  }

  assert.match(sql, /app\.points_ledger_write_guard|points_ledger_insert_id/i);
  assert.match(sql, /app\.credit_ledger_write_guard|credit_ledger_insert_id/i);
  assert.match(sql, /app\.points_ledger_write_scope/i);
  assert.match(sql, /app\.credit_ledger_write_scope/i);
  assert.match(sql, /sale_trigger|redeem_points|adjust_points|points_expiry/i);
  assert.doesNotMatch(sql, /points_ledger_write_scope['"]\s*,\s*['"](?:bypass|unsafe|reverse_without_proof)/i);
});

test('v34 rollback suite proves exact reversals, legacy rejection, and v20/v21 regression coverage', async () => {
  const suite = await read(await rollbackFile());
  assert.match(suite, /^begin\s*;/im);
  assert.match(suite, /^rollback\s*;/im);
  assert.doesNotMatch(suite, /^commit\s*;/im, 'rollback suite must not commit fixture data');

  for (const assertion of [
    'v20', 'v21', 'reverse_sale', 'reverse_loyalty_redemption', 'use_package_session',
    'package', 'session', 'sale', 'idempot', 'replay', 'conflict', 'cross.business|cross tenant',
    'forbidden|unauthorized|staff|owner', 'zero|0 cents|\\$0', 'refund|payment|money',
    'restore|remaining', 'exact|exactly one|count\\s*\\(\\s*\\*',
    'loyalty_redemptions', 'points_ledger', 'credit_ledger', 'points_batches',
    'drain|FEFO|batch', 'legacy|missing|incomplete', 'provenance|evidence',
    'append.only|immutable|restrict_violation', 'auth.uid|PUBLIC|anon|authenticated',
    'search_path', 'has_function_privilege', 'sum\\s*\\([^)]*points|sum\\s*\\([^)]*remaining'
  ]) {
    assert.match(suite, new RegExp(assertion, 'i'), `rollback suite must cover ${assertion}`);
  }

  const pointsAndRemaining = /sum\s*\([^)]*points[^)]*\)[\s\S]{0,1000}sum\s*\([^)]*remaining[^)]*\)/i.test(suite)
    || /sum\s*\([^)]*remaining[^)]*\)[\s\S]{0,1000}sum\s*\([^)]*points[^)]*\)/i.test(suite);
  assert.ok(pointsAndRemaining, 'rollback suite must assert points_ledger and points_batches.remaining equality');
  assert.match(suite, /reverse_loyalty_redemption\s*\([^)]*\)/i);
  assert.match(suite, /(?:update|delete)\s+from\s+public\.loyalty_redemptions/i);
  assert.match(suite, /(?:expected|assert)[\s\S]{0,500}(?:missing|incomplete|legacy)[\s\S]{0,500}(?:provenance|evidence)/i);
});
