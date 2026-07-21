import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const sourcePath = 'db/migrations/20260721_frenly_v44_actionable_customer_wallet.sql';
const deployPath = 'supabase/migrations/20260721150000_frenly_c44_actionable_customer_wallet.sql';

function block(sql, name) {
  const start = sql.search(new RegExp(`create or replace function (?:public|app)\\.${name}\\s*\\(`, 'i'));
  assert.ok(start >= 0, `${name} is missing`);
  const rest = sql.slice(start);
  const end = rest.search(/\ncreate or replace function\b|\nrevoke all on function\b/i);
  return end < 0 ? rest : rest.slice(0, end);
}

function actionOrderedTop100(cards) {
  const ordered = [...cards].sort((left, right) => {
    const a = left.action;
    const b = right.action;
    return Number(a.sort_band) - Number(b.sort_band)
      || String(a.deadline_at || '\uffff').localeCompare(String(b.deadline_at || '\uffff'))
      || Number(a.sort_units) - Number(b.sort_units)
      || left.business.name.localeCompare(right.business.name)
      || left.business.slug.localeCompare(right.business.slug);
  });
  return { cards: ordered.slice(0, 100), truncated: ordered.length > 100 };
}

test('C44 is an atomic, byte-identical forward-only migration with a private disabled gate', async () => {
  const [source, deploy] = await Promise.all([read(sourcePath), read(deployPath)]);
  assert.equal(deploy, source);
  assert.equal([...source.matchAll(/^begin;$/gim)].length, 1);
  assert.equal([...source.matchAll(/^commit;$/gim)].length, 1);
  assert.match(source, /\('customer_actionable_wallet', false\)/i);
  assert.doesNotMatch(source, /create table public\./i,
    'C44 is a read projection and must not add browser-visible state');
});

test('C44 public readers are authenticated, self-scoped, and slug-only where one business is requested', async () => {
  const sql = await read(sourcePath);
  for (const [name, signature] of [
    ['customer_get_actionable_wallet', ''],
    ['customer_get_actionable_business', 'text']
  ]) {
    const body = block(sql, name);
    assert.match(body, /auth\.uid\(\)/i);
    assert.match(body, /security definer/i);
    assert.match(body, /set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
    assert.match(body, /customer_actionable_wallet/i);
    assert.doesNotMatch(body, /p_(?:business|client|identity|auth_user|config)\s+uuid/i);
    assert.match(sql, new RegExp(`revoke all on function public\\.${name}\\(${signature}\\)\\s+from public, anon, authenticated`, 'i'));
    assert.match(sql, new RegExp(`grant execute on function public\\.${name}\\(${signature}\\)\\s+to authenticated`, 'i'));
  }
  const detail = block(sql, 'customer_get_actionable_business');
  assert.match(detail, /app\.v32_customer_wallet_context\(p_business_slug\)/i);
  assert.match(detail, /verified customer link required/i);
  const wallet = block(sql, 'customer_get_actionable_wallet');
  assert.match(wallet, /app\.v32_customer_wallet_context\(null\)/i);
  assert.match(wallet, /from app\.v32_customer_wallet_context\(null\) context/i);
  assert.doesNotMatch(wallet, /context[\s\S]{0,240}limit 101/i,
    'linked contexts must not be alphabetically pre-limited before action ranking');
  assert.match(wallet, /select action_cards\.card, row_number\(\) over \(order by[\s\S]*action_rank/i);
  assert.match(wallet, /filter \(where action_rank <= 100\)[\s\S]*bool_or\(action_rank > 100\)[\s\S]*where action_rank <= 101/i);
});

test('C44 action balance is no more than unexpired remaining batches and leaves legacy readers intact', async () => {
  const sql = await read(sourcePath);
  const card = block(sql, 'c44_actionable_wallet_card');
  assert.match(card, /greatest\(least\(ledger_balance\.units, batch_balance\.unexpired_units\), 0\)/i);
  assert.match(card, /pb\.remaining > 0[\s\S]*?pb\.expires_at is null or pb\.expires_at > p_as_of/i);
  assert.match(card, /p_as_of \+ interval '7 days'/i);
  assert.match(card, /p_as_of \+ interval '30 days'/i);
  assert.match(sql, /c44_points_batches_actionable_idx[\s\S]*?\(business_id, client_id, expires_at, earned_at, id\)[\s\S]*?where remaining > 0/i);
  assert.doesNotMatch(sql, /create or replace function public\.customer_get_wallet/i,
    'legacy aggregate reader must remain byte-for-byte owned by v32');
  assert.doesNotMatch(sql, /create or replace function public\.customer_get_business_summary/i,
    'legacy per-business reader must remain owned by v32');
});

test('C44 expiry, rewards, visits, and value-first order are explicit and conservative', async () => {
  const sql = await read(sourcePath);
  const card = block(sql, 'c44_actionable_wallet_card');
  const wallet = block(sql, 'customer_get_actionable_wallet');
  assert.match(card, /expiry_mode <> 'none'[\s\S]*?expiring_units/i);
  assert.match(card, /unexpired_batches[\s\S]*?sum\(pb\.remaining\) over \([\s\S]*?order by pb\.expires_at nulls last, pb\.earned_at, pb\.id/i,
    'the projection must use the same deterministic FEFO order as redemption');
  assert.match(card, /least\([\s\S]*?loyalty_balance\.balance[\s\S]*?cumulative_remaining/i,
    'expiry batches must be allocated only up to the customer-actionable balance');
  assert.match(card, /expiring_7_units[\s\S]*?expiring_30_units[\s\S]*?next_expiry_at/i);
  assert.match(card, /expiry_balance\.expiring_30_units > 0[\s\S]*?expiry_balance\.next_expiry_at else null/i,
    'zero capped expiry must not retain a next-expiry date');
  assert.match(card, /rv\.cost_points::integer as cost_units/i);
  assert.match(card, /greatest\(rv\.cost_points - loyalty\.balance, 0\)::integer as remaining_units/i);
  assert.match(card, /loyalty\.balance >= rv\.cost_points as available_now/i);
  assert.match(card, /retention_program_versions rv[\s\S]*?rv\.config_version_id = b\.active_config_version_id[\s\S]*?rv\.active/i);
  assert.match(card, /rv\.program_id[\s\S]*?w\.program_id[\s\S]*?group by w\.program_id[\s\S]*?lower\(w\.name\), w\.program_id/i,
    'same-value retention rules must resolve by stable program identity');
  assert.match(card, /s\.counts_as_visit[\s\S]*?s\.reversal_of is null/i);
  assert.doesNotMatch(card, /s\.earns_points|earn_points_per_dollar|stamp_per_cents/i,
    'variable spend/stamp earning must never become a visit promise');
  assert.match(card, /when visit_candidate\.visits_remaining = 1 then 'one_qualifying_visit_remaining'/i);
  for (const band of [
    /when loyalty\.expiring_7_units > 0 then 1/i,
    /when coalesce\(reward_candidate\.available_now, false\) then 2/i,
    /when loyalty\.expiring_units > 0 then 3/i,
    /when visit_candidate\.visits_remaining = 1 then 4/i,
    /when reward_candidate\.name is not null then 5/i
  ]) assert.match(card, band);
  assert.match(wallet, /action_cards\.card#>>'\{action,sort_band\}'[\s\S]*?deadline_at[\s\S]*?sort_units[\s\S]*?lower\(action_cards\.card#>>'\{business,name\}'\)[\s\S]*?action_cards\.card#>>'\{business,slug\}'/i);
  assert.match(wallet, /action_rank <= 100/i);
  assert.match(wallet, /'truncated', v_truncated/i);
});

test('C44 102-link behavioral contract returns a lexically-last urgent business before truncation', async () => {
  const sql = await read(sourcePath);
  const wallet = block(sql, 'customer_get_actionable_wallet');
  const filler = Array.from({ length: 101 }, (_, index) => ({
    business: { name: `A filler ${String(index + 1).padStart(3, '0')}`, slug: `aaa-filler-${String(index + 1).padStart(3, '0')}` },
    action: { sort_band: 6, deadline_at: null, sort_units: 0 }
  }));
  const lexicallyLastUrgent = {
    business: { name: 'Z urgent', slug: 'zzz-urgent-expiry' },
    action: { sort_band: 1, deadline_at: '2026-07-23T00:00:00.000Z', sort_units: 0 }
  };
  const payload = actionOrderedTop100([...filler, lexicallyLastUrgent]);

  assert.equal(payload.cards.length, 100);
  assert.equal(payload.truncated, true);
  assert.equal(payload.cards[0].business.slug, 'zzz-urgent-expiry',
    'an urgent programme must win even when it is lexically last among 102 linked businesses');
  assert.match(wallet, /row_number\(\) over \(order by[\s\S]*?\) as action_rank[\s\S]*?from app\.v32_customer_wallet_context\(null\) context[\s\S]*?\) action_cards/i);
  assert.doesNotMatch(wallet, /row_number\(\) over \(order by context\.business_slug/i,
    'alphabetical context ranking would recreate the urgent-card omission');
});

test('C44 outputs only the reviewed customer-safe projection and defers birthday/inbox/provider work', async () => {
  const sql = await read(sourcePath);
  const card = block(sql, 'c44_actionable_wallet_card');
  const output = card.slice(card.lastIndexOf('select jsonb_build_object('));
  for (const key of [
    'business', 'loyalty', 'credit', 'packages', 'expiry',
    'next_eligible_reward', 'visits_remaining', 'visit_progress', 'action'
  ]) assert.match(output, new RegExp(`'${key}'`, 'i'));
  for (const key of ['currency', 'model', 'expiring_within_7_days', 'cost_units', 'available_now', 'customer_description']) {
    assert.match(output, new RegExp(`'${key}'`, 'i'));
  }
  assert.doesNotMatch(output, /'(?:business_id|client_id|identity_id|auth_user_id|config_version_id|reward_id|sale_id|email|phone|birth_date|dob|internal_name|estimated_cost_cents|cost_points|credit_cents|discount_percent|reward_value)'/i);
  assert.doesNotMatch(output, /'(?:savings|cash_value|retail_value)'/i);
  assert.doesNotMatch(card, /birthday|inbox|enqueue|send(?:_|\s)|provider/i,
    'C45 birthday and C46 inbox/provider work are explicitly out of C44');
});

test('C44 SPA renders separate responsive cards and a slug drill-down without value claims', async () => {
  const app = await read('app/index.html');
  assert.match(app, /customerFeatures\.customer_actionable_wallet===true/i);
  assert.match(app, /sb\.rpc\('customer_get_actionable_wallet'\)/i);
  assert.match(app, /sb\.rpc\('customer_get_actionable_business',\{p_business_slug:businessSlug\}\)/i);
  assert.match(app, /href="#\/wallet\/\$\{encodeURIComponent\(card\?\.business\?\.slug\|\|''\)\}"/i);
  assert.match(app, /Never expires/i);
  assert.match(app, /business\.currency/i);
  assert.match(app, /Credit balance/i);
  assert.match(app, /Package session balance/i);
  assert.match(app, /expiring_within_7_days/i);
  assert.match(app, /min-height:44px/i);
  assert.match(app, /No verified business links yet/i);
  assert.match(app, /customerWalletRenderEpoch/i);
  assert.match(app, /if\(!isWalletCurrent\(\)\)return;/i);
  assert.match(app, /Showing the 100 highest-priority linked businesses/i);
  assert.match(app, /let actionableCard=null;/i);
  assert.match(app, /customer_get_business_summary/i);
  assert.match(app, /customer_portal_capabilities/i);
  for (const reader of [
    'customer_get_reward_catalog', 'customer_get_loyalty_details', 'customer_get_packages',
    'customer_get_memberships', 'customer_get_appointments_page'
  ]) assert.match(app, new RegExp(reader, 'i'), `actionable detail must retain ${reader}`);
  const actionableUi = app.slice(app.indexOf('function actionableWalletExpiryText'), app.indexOf('async function renderCustomerWallet'));
  assert.doesNotMatch(actionableUi, /(?:savings|cash value|retail value)/i);
});

test('C44 rollback fixture covers isolation, action math, omissions, ACLs, bounds, and legacy readers', async () => {
  const suite = await read('db/tests/v44_actionable_customer_wallet.sql');
  assert.match(suite, /^begin;/im);
  assert.match(suite, /^rollback;/im);
  for (const term of [
    'self', 'cross-user', 'cross-firm', 'exact delta', 'zero', 'no-expiry',
    'ordering bands', 'provable', 'unprovable', 'sensitive', 'internal', 'savings',
    'ACL', 'RLS', 'bound', 'legacy', 'customer_get_actionable_wallet',
    'customer_get_actionable_business', 'ledger/batch mismatch', 'zero-balance', 'FEFO'
  ]) assert.match(suite, new RegExp(term, 'i'), `missing C44 rollback coverage: ${term}`);
  assert.match(suite, /v_retention_program_tie/i);
  assert.match(suite, /v_expected_visit_description/i);
  assert.match(suite, /still a draft[\s\S]*?publish_loyalty_config/i,
    'fixture must narrow cloned rules before published-row immutability takes effect');
});
