import assert from 'node:assert/strict';
import { access, readdir, readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const escaped = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const rpcContract = [
  { name: 'customer_get_wallet', signature: '' },
  { name: 'customer_get_business_summary', signature: 'text' },
  { name: 'customer_get_appointments', signature: 'text' },
  { name: 'customer_portal_capabilities', signature: 'text' }
];

async function repoFile(directory, pattern, description) {
  const entries = await readdir(new URL(directory, root));
  const name = entries.find((entry) => pattern.test(entry));
  assert.ok(name, `${description} file is missing`);
  return `${directory}${name}`;
}

const migrationFile = () => repoFile(
  'db/migrations/',
  /^\d+_frenly_v32_.*(?:customer.*wallet|wallet.*customer).*\.sql$/i,
  'v32 customer wallet migration'
);

const rollbackFile = () => repoFile(
  'db/tests/',
  /^v32_.*(?:customer.*wallet|wallet.*customer).*\.sql$/i,
  'v32 customer wallet rollback suite'
);

function declaration(sql, name) {
  const match = sql.match(new RegExp(
    `create\\s+(?:or\\s+replace\\s+)?function\\s+(?:public\\.)?${escaped(name)}\\s*\\(([^)]*)\\)`,
    'i'
  ));
  assert.ok(match, `${name} declaration is missing`);
  return match[1].trim();
}

function functionBlock(sql, name) {
  const start = sql.search(new RegExp(
    `create\\s+(?:or\\s+replace\\s+)?function\\s+(?:public\\.)?${escaped(name)}\\s*\\(`,
    'i'
  ));
  assert.ok(start >= 0, `${name} body is missing`);
  const body = sql.slice(start);
  const end = body.search(/\ncreate\s+(?:or\s+replace\s+)?function\b|\n(?:alter|revoke|grant|drop)\s+(?:function|table|policy)\b/i);
  return end < 0 ? body : body.slice(0, end);
}

function hasVerifiedIdentityProof(block) {
  return /auth\.uid\s*\(\s*\)/i.test(block)
    && /customer_links/i.test(block)
    && /status\s*=\s*'verified'|status\s+in\s*\([^)]*'verified'/i.test(block);
}

function hasExplicitJson(block) {
  return /jsonb_build_object\s*\(/i.test(block)
    && !/row_to_json\s*\(|to_jsonb\s*\([^)]*\)|select\s+\*/i.test(block);
}

test('v32 migration and rollback suite are present', async () => {
  const migrationPath = await migrationFile();
  const rollbackPath = await rollbackFile();

  await access(new URL(migrationPath, root));
  await access(new URL(rollbackPath, root));
});

test('v32 exposes only the four customer wallet RPCs with self-derived arguments', async () => {
  const migrationPath = await migrationFile();
  const sql = await read(migrationPath);
  assert.match(sql,/app\.platform_feature_flags/i);
  assert.match(sql,/app\.platform_feature_enabled\s*\(\s*'customer_wallet'\s*\)/i,
    'customer wallet must fail closed behind a private database launch gate');
  assert.match(sql, /customer_identities[\s\S]*auth_user_id\s*=\s*v_actor[\s\S]*status\s*=\s*'active'[\s\S]*active customer identity required/i,
    'the shared wallet scope must reject authenticated staff who have no active customer identity');

  for (const { name, signature } of rpcContract) {
    const declared=declaration(sql,name);
    if(signature==='') assert.equal(declared,'',`${name} must not accept trusted identity or tenant IDs`);
    else assert.match(declared,/^(?:p_business_slug\s+)?text$/i,
      `${name} may accept only a named business slug lookup argument`);
    assert.match(sql, new RegExp(
      `create\\s+(?:or\\s+replace\\s+)?function\\s+(?:public\\.)?${escaped(name)}\\s*\\(`,
      'i'
    ));
  }

  const publicBlocks = rpcContract.map(({ name }) => functionBlock(sql, name));
  const contextBlocks = [...sql.matchAll(
    /create\s+(?:or\s+replace\s+)?function\s+(?:public\.|app\.)?([a-z0-9_]*(?:context|identity|scope)[a-z0-9_]*)\s*\([^)]*\)[\s\S]*?(?=\ncreate\s+(?:or\s+replace\s+)?function\b|\n(?:alter|revoke|grant|drop)\s+(?:function|table|policy)\b|$)/gi
  )].map((match) => match[0]).filter(hasVerifiedIdentityProof);
  assert.ok(
    publicBlocks.every(hasVerifiedIdentityProof) || contextBlocks.length > 0,
    'every wallet RPC must prove auth.uid plus a verified customer_links row, directly or through a checked context helper'
  );
  if (contextBlocks.length > 0) {
    assert.ok(publicBlocks.every((block) => hasVerifiedIdentityProof(block) || /(?:context|identity|scope)\s*\(/i.test(block)));
  }

  for (const block of publicBlocks) {
    assert.match(block, /returns\s+(?:setof\s+)?jsonb|return\s+jsonb/i);
    assert.match(block, /security\s+definer/i);
    assert.match(block, /set\s+search_path\s+to\s+'pg_catalog',\s*'public',\s*'app',\s*'pg_temp'/i);
    assert.ok(hasExplicitJson(block), 'wallet output must be an explicit JSON column allowlist');
    assert.doesNotMatch(block, /(?:'|\b)(?:email|phone|notes?|internal|password|token|contact_fingerprint|auth_user_id)(?:'|\b)/i);
  }
});

test('wallet is an array of independent firm summaries, not a cross-firm balance', async () => {
  const migrationPath = await migrationFile();
  const sql = await read(migrationPath);
  const wallet = functionBlock(sql, 'customer_get_wallet');

  assert.match(wallet, /jsonb_agg\s*\(/i);
  assert.match(wallet, /jsonb_build_object\s*\(/i);
  assert.match(wallet, /group\s+by[\s\S]*(?:business|link|firm)/i);
  assert.match(wallet, /coalesce\s*\([\s\S]{0,300}jsonb_agg[\s\S]{0,300}(?:'\[\]'|\[\])\s*(?:::\s*jsonb)?/i);
  assert.doesNotMatch(wallet, /sum\s*\([^)]*\)\s+over\s*\(/i);
  assert.doesNotMatch(wallet, /select\s+sum\s*\([^)]*\)\s+into\s+v_?(?:wallet|balance)/i);
});

test('summary, appointments, and capabilities are allowlisted and tenant-contextual', async () => {
  const migrationPath = await migrationFile();
  const sql = await read(migrationPath);

  for (const name of ['customer_get_business_summary', 'customer_get_appointments']) {
    const block = functionBlock(sql, name);
    assert.match(block, /customer_links/i);
    assert.match(block, /status\s*=\s*'verified'|status\s+in\s*\([^)]*'verified'/i);
    assert.ok(hasExplicitJson(block), `${name} must use an explicit output allowlist`);
    assert.doesNotMatch(block, /(?:'|\b)(?:email|phone|notes?|internal|password|token|auth_user_id)(?:'|\b)/i);
    assert.doesNotMatch(block, /(?:business_id|client_id)\s*:=\s*p_/i);
  }

  const capabilities = functionBlock(sql, 'customer_portal_capabilities');
  assert.match(capabilities, /customer_links/i);
  assert.match(capabilities, /status\s*=\s*'verified'|status\s+in\s*\([^)]*'verified'/i);
  assert.match(capabilities, /enabled_modules/i);
  assert.match(capabilities, /(?:exists|relevant|count|data|appointments|sales|services|loyalty)/i);
  assert.ok(hasExplicitJson(capabilities), 'capabilities must use an explicit output allowlist');
  assert.doesNotMatch(capabilities, /(?:'|\b)(?:email|phone|notes?|internal|password|token|auth_user_id)(?:'|\b)/i);
});

test('v32 wallet RPC ACLs are authenticated-only and raw customer tables remain closed', async () => {
  const migrationPath = await migrationFile();
  const sql = await read(migrationPath);

  for (const { name, signature } of rpcContract) {
    const fn = `${name}(${signature})`;
    assert.match(sql, new RegExp(
      `revoke\\s+all\\s+on\\s+function\\s+public\\.${escaped(fn)}\\s+from\\s+public,\\s*anon,\\s*authenticated`,
      'i'
    ), `${fn} must revoke the default PUBLIC/anon/authenticated execute grant`);
    assert.match(sql, new RegExp(
      `grant\\s+execute\\s+on\\s+function\\s+public\\.${escaped(fn)}\\s+to\\s+authenticated`,
      'i'
    ));
    assert.doesNotMatch(sql, new RegExp(
      `grant\\s+execute\\s+on\\s+function\\s+public\\.${escaped(fn)}\\s+to\\s+anon`,
      'i'
    ));
  }

  assert.doesNotMatch(sql, /grant\s+(?:select|insert|update|delete|all\s+privileges)\s+on\s+table\s+public\.(?:customer_|.*customer)/i);
  assert.doesNotMatch(sql, /grant\s+(?:select|insert|update|delete|all\s+privileges)\s+on\s+table\s+public\.(?:customer_links|customer_identities|customer_claim)/i);
});

test('v32 rollback suite covers isolation, authorization, output privacy, and no-aggregate behavior', async () => {
  const rollbackPath = await rollbackFile();
  const suite = await read(rollbackPath);

  assert.match(suite, /^begin\s*;/im);
  assert.match(suite, /^rollback\s*;/im);
  for (const assertion of [
    'auth.uid', 'verified', 'customer_links', 'business A', 'business B',
    'cross.business|cross business|wrong business', 'wallet', 'array',
    'email', 'phone', 'notes', 'internal', 'enabled_modules',
    'capabilit', 'aggregate|sum|cross.firm', 'PUBLIC', 'anon',
    'authenticated', 'search_path', 'raw table|direct table|table grant'
  ]) {
    assert.match(suite, new RegExp(assertion, 'i'), `rollback suite must cover ${assertion}`);
  }
});

test('the SPA has a gated customer wallet route before staff onboarding and keeps its shell independent', async () => {
  const app = await read('app/index.html');
  const routeStart = app.search(/async\s+function\s+route\s*\(/i);
  assert.ok(routeStart >= 0, 'route function is required');
  const route = app.slice(routeStart);
  const walletRouteAt = route.search(/#\/wallet/i);
  const onboardAt = route.search(/if\s*\(!S\.biz\)\s*return\s+renderOnboard\s*\(\s*\)/i);
  assert.ok(walletRouteAt >= 0, 'customer wallet route is missing');
  assert.ok(onboardAt < 0 || walletRouteAt < onboardAt, 'wallet route must be checked before staff onboarding');
  assert.match(route, /loadCustomerFeatureCapabilities[\s\S]*customer_wallet/i, 'wallet route must use the server-derived release gate');
  assert.match(route, /renderCustomerWallet|customer_get_wallet/i, 'wallet route must render the customer shell or invoke its wallet RPC');

  const shell = app.match(/(?:async\s+)?function\s+renderCustomerWallet\s*\([^)]*\)[\s\S]*?(?=\n(?:async\s+)?function\s+|\n\/\*|$)/i)?.[0];
  assert.ok(shell, 'customer wallet shell is missing');
  assert.doesNotMatch(shell, /S\.biz\.(?:id|slug|name|enabled_modules)/i, 'customer shell must not depend on staff S.biz');

  for (const name of ['customer_get_business_summary', 'customer_portal_capabilities']) {
    assert.match(app, new RegExp(`\\.rpc\\(\\s*['"]${name}['"]`, 'i'), `${name} must be wired in the customer shell`);
  }
  assert.match(app, /\.rpc\(\s*['"]customer_get_(?:appointments|appointments_page)['"]/i,
    'the customer shell must wire an allowlisted appointments reader');
  for (const name of rpcContract.filter(({name})=>name!=='customer_get_appointments').map(({ name }) => name)) {
    const calls = [...app.matchAll(new RegExp(
      `\\.rpc\\(\\s*['"]${escaped(name)}['"][\\s\\S]{0,260}?\\)`,
      'gi'
    ))];
    assert.ok(calls.length > 0, `${name} must be called by the SPA`);
    assert.doesNotMatch(calls[0][0], /\b(?:business_id|client_id|p_business|p_client|S\.biz)\b/i, `${name} must use the slug/context, never a trusted tenant ID`);
  }
});

test('v38 adds server-side personas, claim route, and private customer gates', async () => {
  const [migration, suite, app, v21Migration, v21Suite] = await Promise.all([
    read('db/migrations/20260720_frenly_v38_customer_personas_and_gates.sql'),
    read('db/tests/v38_customer_personas_and_gates.sql'),
    read('app/index.html'),
    read('db/migrations/20260719_frenly_v21_security_hardening.sql'),
    read('db/tests/v21_security_hardening.sql')
  ]);
  assert.match(migration, /create or replace function public\.get_my_personas\(\)/i);
  assert.match(migration, /'customer_identity', false/i);
  assert.match(migration, /'customer_claims', false/i);
  assert.match(migration, /'customer_email_otp', false/i);
  assert.match(migration, /'staff'[\s\S]*'customer'[\s\S]*'default_route'/i);
  assert.match(migration, /when s\.modules is null[\s\S]*m = any\(s\.modules\)/i,
    'persona modules must intersect the deployed staff.modules array with enabled modules');
  assert.doesNotMatch(migration, /s\.module_perms/i,
    'the target migration history does not contain the monolithic v14 module_perms column');
  const personas = migration.match(/create or replace function public\.get_my_personas\(\)[\s\S]*?end \$\$;/i)?.[0]||'';
  assert.doesNotMatch(personas, /'client_id'|'phone'|'email'|'balance_cents'|'points_balance'/i);
  assert.match(migration, /revoke all on function public\.get_my_personas\(\) from public, anon/i);
  assert.match(migration, /grant execute on function public\.get_my_personas\(\) to authenticated/i);
  assert.match(migration, /create or replace function public\.get_customer_feature_capabilities\(\)/i);
  assert.match(migration, /revoke all on function public\.get_customer_feature_capabilities\(\) from public, anon/i);
  assert.match(app, /h==='#\/claim'\|\|h\.startsWith\('#\/claim\?'\)/);
  assert.match(app, /sb\.rpc\('get_my_personas'/i);
  assert.match(app, /sb\.rpc\('get_customer_feature_capabilities'/i);
  assert.match(app, /sb\.rpc\('customer_create_identity'/i);
  assert.match(app, /sb\.rpc\('customer_claim_link_by_email'/i);
  assert.match(app, /sb\.rpc\('customer_claim_link_invitation'/i);
  assert.match(app, /sb\.rpc\('customer_unlink_business_link'/i);
  assert.match(app, /history\.replaceState[\s\S]{0,180}#\/claim/i);
  const routeBlock=app.slice(app.search(/async\s+function\s+route\s*\(/i));
  const firstAwait=routeBlock.search(/\bawait\b/);
  const invitationCapture=routeBlock.search(/pendingCustomerInvitationToken\s*=\s*invite/i);
  const invitationScrub=routeBlock.search(/history\.replaceState/i);
  assert.ok(invitationCapture >= 0 && invitationScrub > invitationCapture && invitationScrub < firstAwait,
    'invitation secrets must leave browser history before routing awaits authentication');
  assert.match(app, /dualRoleWorkspace[\s\S]*#\/workspace/i);
  assert.match(app, /S\.hasCustomerPersona\?`<a href="#\/wallet"/i);
  assert.match(app, /function resetClientSessionState/i);
  assert.match(app, /renderCustomerWalletRetry[\s\S]*walletRetry/i);
  assert.match(app, /claimPersonaRetry/i);
  assert.doesNotMatch(app, /if\(mmErr\|\|!mm\)[\s\S]{0,400}S\.myModules=S\.biz\.enabled_modules/i,
    'resolver failures must not broaden restricted staff UI modules');
  assert.match(app, /const CUSTOMER_FEATURES_EMERGENCY_DISABLED=false/);
  assert.doesNotMatch(app, /const CUSTOMER_(?:WALLET|ACTIONS|NOTIFICATIONS)_ENABLED=true/);
  assert.match(suite, /v38 customer personas and gates suite: ALL PASS/i);
  for(const evidence of ['staff-only','customer-only','dual-role','restricted modules','cross-business','unlink']){
    assert.match(suite,new RegExp(evidence,'i'),`v38 rollback suite lacks ${evidence} evidence`);
  }
  assert.match(v21Migration, /'get_my_personas'/);
  assert.match(v21Migration, /'get_customer_feature_capabilities'/);
  assert.match(v21Suite, /'get_my_personas'/);
  assert.match(v21Suite, /'get_customer_feature_capabilities'/);
});
