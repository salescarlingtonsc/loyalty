import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const sourcePath = 'db/migrations/20260721_frenly_v45_birthday_benefits.sql';
const deployPath = 'supabase/migrations/20260721163000_frenly_c45_birthday_benefits.sql';

function functionBlock(sql, name) {
  const start = sql.search(new RegExp(`create or replace function (?:public|app)\\.${name}\\s*\\(`, 'i'));
  assert.ok(start >= 0, `${name} is missing`);
  const rest = sql.slice(start);
  const end = rest.search(/\ncreate or replace function\b|\nalter function\b|\n-- -------------------------------------------------------------------------/i);
  return end < 0 ? rest : rest.slice(0, end);
}

test('Luna C45: canonical source/deploy mirror is exact and the flag starts disabled', async () => {
  const [source, deploy] = await Promise.all([read(sourcePath), read(deployPath)]);
  assert.equal(source, deploy);
  assert.match(source, /values \('customer_birthday_benefits', false\)\s*on conflict \(feature_key\) do nothing/i);
});

test('Luna C45: disabling birthday benefits closes every public operational path', async () => {
  const sql = await read(sourcePath);
  for (const name of [
    'customer_get_birthday_participation',
    'staff_get_customer_birthday_benefit',
    'redeem_customer_birthday_benefit',
    'reverse_customer_birthday_benefit_for_client'
  ]) {
    const body = functionBlock(sql, name);
    assert.match(body, /app\.platform_feature_enabled\('customer_birthday_benefits'\)/i,
      `${name} must fail closed when the C45 feature is disabled`);
  }
  for (const name of [
    'customer_get_birthday_benefit',
    'customer_activate_birthday_benefit'
  ]) {
    const body = functionBlock(sql, name);
    assert.match(body, /app\.c45_customer_birthday_context\(p_business_slug\)/i,
      `${name} must use the feature-gated private customer context`);
  }
});

test('Luna C45: expiry is derived, and the staff projection cannot disclose calendar or free-form customer details', async () => {
  const [sql, app, suite, harness] = await Promise.all([
    read(sourcePath), read('app/index.html'), read('db/tests/v45_birthday_benefits.sql'), read('db/tests/v45_birthday_benefits_concurrency.sh')
  ]);
  const customerSafe = functionBlock(sql, 'c45_safe_birthday_entitlement');
  const staffSafe = functionBlock(sql, 'c45_staff_safe_birthday_entitlement');
  const staffRead = functionBlock(sql, 'staff_get_customer_birthday_benefit');
  const redeem = functionBlock(sql, 'redeem_customer_birthday_benefit');
  const clientDetail = app.slice(app.indexOf('async function clientDetail'), app.indexOf('/* catalog / milestone redemption'));

  assert.match(customerSafe, /valid_until <= p_as_of[\s\S]*'expired'/i);
  assert.match(staffSafe, /valid_until <= p_as_of[\s\S]*'expired'/i);
  assert.doesNotMatch(staffSafe, /'(?:validity|available_from|available_until|description|terms)'/i,
    'staff must not receive a birthday window or merchant free-form customer copy');
  assert.match(staffRead, /return app\.c45_staff_safe_birthday_entitlement\(v_entitlement,statement_timestamp\(\)\)/i);
  assert.doesNotMatch(redeem, /update public\.customer_birthday_entitlements set status='expired'/i,
    'a failed expired redemption must never persist a doomed status transition');
  assert.match(clientDetail, /select\('id,business_id,full_name,phone,email,gender,referral_code,marketing_consent'\)/i);
  assert.doesNotMatch(clientDetail, /c\.birth_date|birthdayBenefit\.validity|birthdayBenefit\.description|birthdayBenefit\.terms/i);
  assert.match(suite, /loyalty-r reader was not a staff-safe available projection/i);
  assert.match(suite, /non-leap Feb 29 window failed/i);
  assert.match(suite, /SG midnight window inherited the session timezone/i);
  assert.match(suite, /December\/January birthday window failed/i);
  assert.match(harness, /effective expired state is derived from valid_until/i);
  assert.match(harness, /expiry_redemptions[\s\S]*\[ "\$expiry_redemptions" = "0" \]/i);
});
