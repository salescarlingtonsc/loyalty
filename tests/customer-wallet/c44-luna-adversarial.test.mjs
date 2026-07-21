import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const sourcePath = 'db/migrations/20260721_frenly_v44_actionable_customer_wallet.sql';
const deployPath = 'supabase/migrations/20260721150000_frenly_c44_actionable_customer_wallet.sql';

function functionBlock(sql, name) {
  const start = sql.search(new RegExp(`create or replace function (?:public|app)\\.${name}\\s*\\(`, 'i'));
  assert.ok(start >= 0, `${name} is missing`);
  const rest = sql.slice(start);
  const end = rest.search(/\ncreate or replace function\b|\nrevoke all on function\b/i);
  return end < 0 ? rest : rest.slice(0, end);
}

test('Luna C44: deploy mirror and public reader boundary stay self-scoped, authenticated, and fixed-path', async () => {
  const [source, deploy] = await Promise.all([read(sourcePath), read(deployPath)]);
  assert.equal(source, deploy, 'the reviewed C44 source must match deployable canonical SQL exactly');
  for (const [name, signature] of [
    ['customer_get_actionable_wallet', ''],
    ['customer_get_actionable_business', 'text']
  ]) {
    const body = functionBlock(source, name);
    assert.match(body, /auth\.uid\(\) is null[\s\S]*authenticated customer session required/i);
    assert.match(body, /security definer[\s\S]*set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
    assert.doesNotMatch(body, /p_(?:business|client|identity|auth_user|config)(?:_id)?\s+uuid/i);
    assert.match(source, new RegExp(`revoke all on function public\\.${name}\\(${signature}\\)\\s+from public, anon, authenticated`, 'i'));
    assert.match(source, new RegExp(`grant execute on function public\\.${name}\\(${signature}\\)\\s+to authenticated`, 'i'));
  }
  const detail = functionBlock(source, 'customer_get_actionable_business');
  assert.match(detail, /app\.v32_customer_wallet_context\(p_business_slug\)[\s\S]*verified customer link required/i);
});

test('Luna C44: actionability is conservative, FEFO-capped, and C45/C46 are deferred', async () => {
  const sql = await read(sourcePath);
  const card = functionBlock(sql, 'c44_actionable_wallet_card');
  const output = card.slice(card.lastIndexOf('select jsonb_build_object('));

  assert.match(card, /greatest\(least\(ledger_balance\.units, batch_balance\.unexpired_units\), 0\)/i);
  assert.match(card, /unexpired_batches[\s\S]*sum\(pb\.remaining\) over \([\s\S]*order by pb\.expires_at nulls last, pb\.earned_at, pb\.id/i,
    'expiry must be allocated in the same deterministic FEFO order as spending');
  assert.match(card, /actionable_batches[\s\S]*least\([\s\S]*loyalty_balance\.balance[\s\S]*cumulative_remaining/i,
    'raw batch expiry must be capped at the actionable ledger/batch balance');
  assert.match(card, /expires_at <= p_as_of \+ interval '7 days'[\s\S]*expiring_7_units/i);
  assert.match(card, /expires_at <= p_as_of \+ interval '30 days'[\s\S]*expiring_30_units/i);
  assert.match(card, /expiry_balance\.expiring_30_units > 0[\s\S]*next_expiry_at else null/i,
    'a zero capped expiry allocation must never retain a next-expiry date');
  assert.match(card, /rv\.cost_points::integer as cost_units[\s\S]*greatest\(rv\.cost_points - loyalty\.balance, 0\)::integer as remaining_units[\s\S]*loyalty\.balance >= rv\.cost_points as available_now/i);
  assert.doesNotMatch(output, /'(?:internal_name|estimated_cost_cents|discount_percent|savings|cash_value|retail_value)'/i);
  assert.doesNotMatch(card, /birthday|inbox|enqueue|send(?:_|\s)|provider/i,
    'birthday and notification/provider scope must remain deferred to C45/C46');
});

test('Luna C44: visit promises depend on the active version and immutable sale snapshot, with a total deterministic tie-break', async () => {
  const sql = await read(sourcePath);
  const card = functionBlock(sql, 'c44_actionable_wallet_card');

  assert.match(card, /retention_program_versions rv[\s\S]*rv\.config_version_id = b\.active_config_version_id[\s\S]*rv\.active/i);
  assert.match(card, /s\.counts_as_visit[\s\S]*s\.reversal_of is null/i);
  assert.doesNotMatch(card, /s\.earns_points|earn_points_per_dollar|stamp_per_cents/i);
  assert.match(card, /order by greatest\(w\.goal_visits - count\(s\.id\)::integer, 0\),\s*w\.period_end, w\.sort, lower\(w\.name\), w\.program_id/i,
    'tie-breaking must end in the immutable program id; name and sort are not unique');
});

test('Luna C44: 101/100 truncation is value-first, home firms stay separate, and C44 only augments the v39 detail readers', async () => {
  const [sql, app] = await Promise.all([read(sourcePath), read('app/index.html')]);
  const wallet = functionBlock(sql, 'customer_get_actionable_wallet');
  const route = app.slice(app.indexOf('async function renderCustomerWallet'), app.indexOf('async function renderCustomerNotificationPreferences'));

  assert.match(wallet, /select action_cards\.card, row_number\(\) over \(order by[\s\S]*action_cards\.card#>>'\{action,sort_band\}'[\s\S]*action_rank/i);
  assert.match(wallet, /filter \(where action_rank <= 100\)[\s\S]*bool_or\(action_rank > 100\)[\s\S]*where action_rank <= 101/i);
  assert.doesNotMatch(wallet, /row_number\(\) over \(order by context\.business_slug|source_rank|context[\s\S]{0,240}limit 101/i,
    'alphabetical pre-limiting would silently omit a lexically-last urgent programme');
  assert.match(route, /customer_get_actionable_wallet[\s\S]*renderActionableWalletHome\(data\)/i);
  assert.match(route, /customer_get_actionable_business[\s\S]*customer_get_business_summary[\s\S]*customer_portal_capabilities/i);
  for (const reader of ['customer_get_reward_catalog', 'customer_get_loyalty_details', 'customer_get_packages', 'customer_get_memberships', 'customer_get_appointments_page']) {
    assert.match(app, new RegExp(reader, 'i'), `C44 detail must retain ${reader}`);
  }
  assert.match(app, /<h1>My Frenly<\/h1>[\s\S]*<h2>No verified business links yet<\/h2>/i);
  assert.match(app, /href="#\/wallet\/\$\{encodeURIComponent\(card\?\.business\?\.slug\|\|''\)\}"/i);
  assert.match(app, /customerWalletRenderEpoch[\s\S]*if\(!isWalletCurrent\(\)\)return;/i);
  assert.match(app, /Showing the 100 highest-priority linked businesses/i);
});

test('Luna C44: every awaited v39 detail loader and capability refresh rejects a stale A route before it can paint B', async () => {
  const app = await read('app/index.html');
  const route = app.slice(app.indexOf('async function renderCustomerWallet'), app.indexOf('async function renderCustomerNotificationPreferences'));

  assert.match(app, /function walletSectionStillCurrent\(host,isCurrent\)[\s\S]*host\.isConnected[\s\S]*\$\(host\.id\)===host/i);
  assert.match(app, /async function walletSectionEmpty[\s\S]*await sb\.rpc\('customer_portal_capabilities'[\s\S]*if\(!walletSectionStillCurrent\(host,isCurrent\)\)return;/i);
  for (const [loader, rpc] of [
    ['loadRewards', 'customer_get_reward_catalog'],
    ['loadActivity', 'customer_get_loyalty_details'],
    ['loadPackages', 'customer_get_packages'],
    ['loadMemberships', 'customer_get_memberships'],
    ['loadAppointments', 'customer_get_appointments_page']
  ]) {
    assert.match(route, new RegExp(`const ${loader}=[\\s\\S]*?await sb\\.rpc\\('${rpc}'[\\s\\S]*?if\\(!isWalletSectionCurrent\\(host\\)\\)return;`, 'i'),
      `${loader} must reject a stale response before touching a shared section ID`);
  }
  assert.match(route, /await Promise\.all\([\s\S]*?if\(!isWalletCurrent\(\)\)return;/i);
});

test('Luna C44: controlled deferred A→B route harness cannot let A overwrite B', async () => {
  let epoch = 0;
  let currentHost = null;
  const deferred = () => {
    let resolve;
    const promise = new Promise((done) => { resolve = done; });
    return { promise, resolve };
  };
  const beginRoute = (route) => {
    const token = ++epoch;
    const host = { id: 'walletRewards', route, isConnected: true, html: '' };
    currentHost = host;
    return { token, host };
  };
  const guardedPaint = async ({ token, host }, pending) => {
    const value = await pending;
    if (token !== epoch || !host.isConnected || currentHost !== host) return false;
    host.html = value;
    return true;
  };
  const pendingA = deferred();
  const routeA = beginRoute('A');
  const paintA = guardedPaint(routeA, pendingA.promise);
  routeA.host.isConnected = false;
  const pendingB = deferred();
  const routeB = beginRoute('B');
  const paintB = guardedPaint(routeB, pendingB.promise);

  pendingB.resolve('B rewards');
  assert.equal(await paintB, true);
  pendingA.resolve('A rewards');
  assert.equal(await paintA, false);
  assert.equal(routeB.host.html, 'B rewards');
});

test('Luna C44: notification fetch and preference mutation also reject a stale or replaced wallet host', async () => {
  const app = await read('app/index.html');
  const notifications = app.slice(
    app.indexOf('async function renderCustomerNotificationPreferences'),
    app.indexOf('function renderWorkspaceAccessUnavailable')
  );

  assert.match(notifications, /customer_get_notification_preferences[\s\S]*if\(!walletSectionStillCurrent\(host,isCurrent\)\)return;/i,
    'a delayed preference read must not render into the next business route');
  assert.match(notifications, /customer_set_notification_preference[\s\S]*if\(!walletSectionStillCurrent\(host,isCurrent\)\|\|!input\.isConnected\)return;/i,
    'a delayed preference mutation must not alter controls from a replacement route');
});

test('Luna C44: FEFO cap allocates an inconsistent ledger across earliest expiry batches and emits no expiry at zero', () => {
  const allocate = (balance, batches) => {
    let remainingBalance = balance;
    return [...batches]
      .sort((a, b) => a.expiresAt.localeCompare(b.expiresAt) || a.earnedAt.localeCompare(b.earnedAt) || a.id.localeCompare(b.id))
      .map((batch) => {
        const allocated = Math.min(batch.remaining, Math.max(remainingBalance, 0));
        remainingBalance -= allocated;
        return { ...batch, allocated };
      });
  };
  const batches = [
    { id: 'b', earnedAt: '2026-01-02', expiresAt: '2026-08-10', remaining: 20 },
    { id: 'a', earnedAt: '2026-01-01', expiresAt: '2026-07-23', remaining: 30 },
    { id: 'c', earnedAt: '2026-01-03', expiresAt: '2026-08-30', remaining: 50 }
  ];
  const allocated = allocate(40, batches);
  assert.deepEqual(allocated.map((batch) => batch.allocated), [30, 10, 0],
    'the customer-visible balance must consume the earliest batches first');
  assert.equal(allocated.filter((batch) => batch.expiresAt <= '2026-07-28').reduce((sum, batch) => sum + batch.allocated, 0), 30);
  assert.equal(allocated.filter((batch) => batch.expiresAt <= '2026-08-20').reduce((sum, batch) => sum + batch.allocated, 0), 40);
  assert.deepEqual(allocate(0, batches).map((batch) => batch.allocated), [0, 0, 0],
    'zero actionable balance cannot expose expiring units or an expiry date');
});

test('Luna C44: rollback suite is transactional and semantically exercises the reviewed projection (not executed here)', async () => {
  const suite = await read('db/tests/v44_actionable_customer_wallet.sql');
  assert.match(suite, /^begin;/im);
  assert.match(suite, /^rollback;/im);
  for (const required of ['customer_get_actionable_wallet', 'customer_get_actionable_business', 'exact delta', 'no-expiry', 'provable', 'unprovable', 'cross-user', 'cross-firm', 'bounded cards', 'ledger/batch mismatch', 'zero-balance', 'legacy customer_get_wallet']) {
    assert.match(suite, new RegExp(required, 'i'));
  }
});
