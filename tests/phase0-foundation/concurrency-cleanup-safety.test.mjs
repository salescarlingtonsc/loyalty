import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = fileURLToPath(new URL('../..', import.meta.url));
const read = (relative) => readFile(path.join(root, relative), 'utf8');

test('v20 concurrency uses current authenticated tender APIs and exact scoped cleanup', async () => {
  const script = await read('db/tests/v20_financial_concurrency.sh');
  assert.match(script, /PGPASSWORD is required with the passwordless DATABASE_URL/);
  assert.match(script, /cleanup_synthetic_fixture\.sql/);
  assert.match(script, /YES-SCOPED-SYNTHETIC-CLEANUP/);
  assert.match(script, /trap 'cleanup "\$\?"' EXIT/);
  assert.match(script, /fixture_output="\$\(psql/);
  assert.doesNotMatch(script, /}\s*\|\s*tail\s+-n\s+1/,
    'fixture psql failures must not be hidden behind a pipeline');
  assert.match(script, /public\.redeem_gift_card_v41\(/);
  assert.doesNotMatch(script, /public\.redeem_gift_card\(/);
  assert.match(script, /set role authenticated;[\s\S]*public\.record_credit_tender\(/,
    'raced financial calls must execute through the current authenticated runtime API');
  assert.ok(
    script.indexOf('insert into public.gift_cards') < script.indexOf('set role authenticated;'),
    'privileged fixture setup must finish before an authenticated raced session begins'
  );
  assert.match(script,/result_message="v20 two-session concurrency checks: PASS/);
});

test('concurrency holders self-release and every harness traps scoped cleanup', async () => {
  const [v37, v40] = await Promise.all([
    read('db/tests/v37_retention_publish_concurrency.sh'),
    read('db/tests/v40_reversal_credit_concurrency.sh')
  ]);
  for (const [name, script] of [['v37', v37], ['v40', v40]]) {
    assert.doesNotMatch(script, /pg_terminate_backend/i, `${name} must never terminate a backend`);
    assert.match(script, /select pg_sleep\(5\)/i);
    assert.match(script, /wait "\$holder_pid"/);
    assert.match(script, /trap 'cleanup "\$\?"' EXIT/);
    assert.match(script, /cleanup_synthetic_fixture\.sql/);
    assert.match(script, /YES-SCOPED-SYNTHETIC-CLEANUP/);
    assert.match(script, /PGCONNECT_TIMEOUT/);
    assert.match(script, /export PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=10000"/,
      `${name} must bound every foreground psql statement and lock wait`);
    assert.match(script, /PGPASSWORD is required with the passwordless DATABASE_URL/);
    assert.match(script, /\*:\*\|\*%3\[Aa\]\*/,
      `${name} must reject literal and percent-encoded userinfo passwords`);
    assert.match(script, /\*\\\?\*pass\*=\*\|\*\\&\*pass\*=\*/,
      `${name} must reject password-bearing URL query parameters`);
    assert.doesNotMatch(script, /echo[^\n]*\$\{?DATABASE_URL\}?/,
      `${name} must never print the connection URL`);
    assert.match(script, /statement_timeout='20s'/i);
    assert.match(script, /lock_timeout='10s'/i);
    assert.match(script, /gen_random_uuid\(\)/i,
      `${name} must know auth UUIDs before any fixture write can fail`);
    assert.doesNotMatch(script, /}\s*\|\s*tail\s+-n\s+1/i,
      `${name} must not hide fixture psql failures behind a POSIX pipeline`);
    assert.match(script, /fixture_output="\$\(psql/);
    assert.match(script, /fixture setup returned an invalid UUID/i);
    assert.match(script, /result_message=/,
      `${name} must defer PASS output until EXIT cleanup succeeds`);
    assert.match(script, /run_[a-z]+\(\)\{\s*exec psql/g,
      `${name} worker background PIDs must be the owned psql processes`);

    const cleanupBlock = script.match(/cleanup\(\)\{[\s\S]*?\n\}/)?.[0] || '';
    assert.ok(cleanupBlock.indexOf('kill -TERM "$child_pid"') >= 0);
    assert.ok(cleanupBlock.indexOf('kill -TERM "$child_pid"') < cleanupBlock.indexOf('wait "$holder_pid"'),
      `${name} must signal its owned child sessions before waiting on a failing exit`);
    for (const pidName of name === 'v37'
      ? ['holder', 'sale', 'publish']
      : ['holder', 'tender', 'reverse']) {
      assert.match(cleanupBlock, new RegExp(
        `wait "\\$${pidName}_pid"[^\\n]*; cleanup_${pidName}_status=\\$\\?; ${pidName}_pid=""`),
      `${name} cleanup must clear ${pidName}_pid immediately after reaping it`);
    }
    assert.match(cleanupBlock, /sed -n '1,8p'/);
    assert.match(cleanupBlock, /cut -c1-240/);
    assert.match(cleanupBlock, /redacted-database-url/);
    assert.ok(cleanupBlock.indexOf('first sanitized lines') < cleanupBlock.indexOf('rm -f'),
      `${name} must emit bounded cleanup diagnostics before deleting its log`);
  }
  assert.match(v37, /holder_app="v37-retention-holder-\$owner_prefix"/);
  assert.match(v37, /sale_app="v37-retention-sale-\$owner_prefix"/);
  assert.match(v37, /publish_app="v37-retention-publish-\$owner_prefix"/);
  assert.match(v37, /application_name=:'holder_app'/);
  assert.match(v37, /application_name in \(:'sale_app',:'publish_app'\)/);
  assert.match(v40, /holder_app="v40-credit-holder-\$owner_prefix"/);
  assert.match(v40, /tender_app="v40-credit-tender-\$owner_prefix"/);
  assert.match(v40, /reversal_app="v40-credit-reversal-\$owner_prefix"/);
  assert.match(v40, /application_name=:'holder_app'/);
  assert.match(v40, /application_name in \(:'tender_app',:'reversal_app'\)/);
  assert.match(v37,
    /set \+e\s+wait "\$holder_pid"; holder_status=\$\?\s+holder_pid=""\s+set -e\s+if \[ "\$holder_status" -ne 0 \]/,
    'v37 holder PID must clear before its status branch');
  assert.match(v37,
    /set \+e\s+wait "\$sale_pid"; sale_status=\$\?\s+sale_pid=""\s+wait "\$publish_pid"; publish_status=\$\?\s+publish_pid=""\s+set -e\s+if \[ "\$sale_status" -ne 0 \][\s\S]*if \[ "\$publish_status" -ne 0 \]/,
    'v37 worker PIDs must clear before either status branch');
  assert.match(v40,
    /set \+e\s+wait "\$holder_pid"; holder_status=\$\?\s+holder_pid=""\s+set -e\s+if \[ "\$holder_status" -ne 0 \]/,
    'v40 holder PID must clear before its status branch');
  assert.match(v40,
    /set \+e\s+wait "\$tender_pid"; tender_status=\$\?\s+tender_pid=""\s+wait "\$reverse_pid"; reverse_status=\$\?\s+reverse_pid=""\s+set -e\s+if \[ "\$tender_status" -eq "\$reverse_status" \]/,
    'v40 worker PIDs must clear before the result-status branch');
  assert.match(v37, /cleanup_auth_user_1="\$owner"/);
  assert.match(v40, /cleanup_auth_user_1="\$owner"[\s\S]*cleanup_auth_user_2="\$manager"/);
  assert.match(v40, /fixture setup returned an invalid barrier/i);
});

test('shared cleanup is exact-scope, transactional, retry-bounded and proves zero rows', async () => {
  const cleanup = await read('db/tests/cleanup_synthetic_fixture.sql');
  assert.match(cleanup, /^begin;/m);
  assert.match(cleanup, /commit;\s*select 'synthetic-fixture-cleanup: PASS'/i);
  assert.match(cleanup, /YES-SCOPED-SYNTHETIC-CLEANUP/);
  assert.match(cleanup, /business UUID\/name\/slug cleanup guard did not match exactly/i);
  assert.match(cleanup, /update public\.businesses set active_config_version_id = null/i);
  assert.match(cleanup, /disable trigger user/i);
  assert.match(cleanup, /enable trigger user/i);
  assert.equal((cleanup.match(/not t\.tgisinternal and t\.tgenabled <> 'O'/g) || []).length, 2,
    'cleanup must preflight and post-assert that selected user triggers are origin-enabled');
  assert.match(cleanup, /refusing cleanup: selected user triggers are not origin-enabled/i);
  assert.match(cleanup, /cleanup did not restore origin-enabled user triggers/i);
  assert.match(cleanup, /c\.relname = 'businesses'[\s\S]*a\.attname = 'business_id'/i,
    'temporary trigger suspension must be limited to the scoped business table family');
  assert.doesNotMatch(cleanup, /disable trigger all|session_replication_role/i);
  assert.match(cleanup, /exception when foreign_key_violation/i);
  assert.match(cleanup, /made no FK progress/i);
  assert.match(cleanup, /post-cleanup rows remain/i);
  assert.match(cleanup, /post-cleanup synthetic auth user row remains/i);
  assert.match(cleanup, /where id = v_user and email = v_email/i);
  assert.match(cleanup, /linked to another business/i);
});

test('partial fixture setup can clean exact auth users when no business was created', async () => {
  const cleanup = await read('db/tests/cleanup_synthetic_fixture.sql');
  assert.match(cleanup, /if v_matches = 0 then[\s\S]*where id = v_business[\s\S]*v_business := null/i);
  assert.match(cleanup, /delete from auth\.users[\s\S]*auth_email_1[\s\S]*auth_email_2/i);
  assert.match(cleanup, /post-cleanup synthetic auth user row remains/i);
  const [v37, v40] = await Promise.all([
    read('db/tests/v37_retention_publish_concurrency.sh'),
    read('db/tests/v40_reversal_credit_concurrency.sh')
  ]);
  for (const script of [v37, v40]) {
    assert.match(script, /biz=""/);
    assert.match(script, /fixture_biz/);
    assert.match(script, /biz="\$fixture_biz"/,
      'business cleanup UUID must only become live after parsed fixture validation');
  }
});

test('orphan cleanup defaults to inventory-only and requires exact synthetic confirmation', async () => {
  const script = await read('db/tests/cleanup_v37_mcp_concurrency_fixture.sh');
  assert.match(script, /3547cfc9-ad9b-4f9c-8b3a-132b9cb04e12/);
  assert.match(script, /V37 MCP concurrency/);
  assert.match(script, /v37-mcp-c814a28d/);
  assert.match(script, /Dry run only; no rows changed/);
  assert.match(script, /V37_CONFIRM_DISPOSABLE_DB/);
  assert.match(script, /DELETE-V37-MCP-CONCURRENCY-3547CFC9/);
  assert.match(script, /v37-mcp-\*@example\.test/);
  assert.match(script, /cleanup_synthetic_fixture\.sql/);
  assert.match(script, /PGPASSWORD is required with the passwordless DATABASE_URL/);
  assert.match(script, /export PGOPTIONS="-c statement_timeout=30000 -c lock_timeout=10000"/);
  assert.match(script, /PGAPPNAME="v37-mcp-cleanup-3547cfc9"/);
  assert.doesNotMatch(script, /echo[^\n]*\$\{?DATABASE_URL\}?/);
  const mutation = script.indexOf('-f "$script_dir/cleanup_synthetic_fixture.sql"');
  const confirmation = script.indexOf('V37_MCP_CLEANUP_CONFIRM');
  assert.ok(confirmation >= 0 && mutation > confirmation,
    'orphan cleanup mutation must remain behind the explicit confirmation guard');
});

test('all cleanup and concurrency shell scripts are syntactically valid', () => {
  for (const relative of [
    'db/tests/v37_retention_publish_concurrency.sh',
    'db/tests/v40_reversal_credit_concurrency.sh',
    'db/tests/cleanup_v37_mcp_concurrency_fixture.sh'
  ]) {
    const result = spawnSync('sh', ['-n', relative], { cwd: root, encoding: 'utf8' });
    assert.equal(result.status, 0, `${relative}: ${result.stderr}`);

    for (const badUrl of [
      'postgresql://guard-user:do-not-print-me@example.test/postgres',
      'postgresql://guard-user%3Ado-not-print-me@example.test/postgres',
      'postgresql://guard-user@example.test/postgres?password=do-not-print-me'
    ]) {
      const guarded = spawnSync('sh', [relative], {
        cwd: root,
        encoding: 'utf8',
        env: {
          ...process.env,
          DATABASE_URL: badUrl,
          PGPASSWORD: 'environment-only',
          V37_CONFIRM_DISPOSABLE_DB: 'YES',
          V40_CONFIRM_DISPOSABLE_DB: 'YES'
        }
      });
      assert.equal(guarded.status, 2, `${relative} must reject ${badUrl.split('@')[0]}`);
      assert.doesNotMatch(`${guarded.stdout}${guarded.stderr}`, /do-not-print-me|postgresql:\/\//,
        `${relative} must not echo a rejected URL or password`);
    }

    const missingPassword = spawnSync('sh', [relative], {
      cwd: root,
      encoding: 'utf8',
      env: {
        ...process.env,
        DATABASE_URL: 'postgresql://guard-user@example.test/postgres',
        PGPASSWORD: '',
        V37_CONFIRM_DISPOSABLE_DB: 'YES',
        V40_CONFIRM_DISPOSABLE_DB: 'YES'
      }
    });
    assert.equal(missingPassword.status, 2);
    assert.match(missingPassword.stderr, /PGPASSWORD is required/);
  }
});
