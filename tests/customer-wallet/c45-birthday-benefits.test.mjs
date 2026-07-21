import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const sourcePath = 'db/migrations/20260721_frenly_v45_birthday_benefits.sql';
const deployPath = 'supabase/migrations/20260721163000_frenly_c45_birthday_benefits.sql';

function fn(sql, name) {
  const start = sql.search(new RegExp(`create or replace function (?:public|app)\\.${name}\\s*\\(`, 'i'));
  assert.ok(start >= 0, `${name} is missing`);
  const rest = sql.slice(start);
  const end = rest.search(/\ncreate or replace function\b|\nalter function\b|\n-- -------------------------------------------------------------------------/i);
  return end < 0 ? rest : rest.slice(0, end);
}

test('C45 is an atomic disabled, byte-identical forward migration', async () => {
  const [source, deploy] = await Promise.all([read(sourcePath), read(deployPath)]);
  assert.equal(source, deploy);
  assert.equal([...source.matchAll(/^begin;$/gim)].length, 1);
  assert.equal([...source.matchAll(/^commit;$/gim)].length, 1);
  assert.match(source, /\('customer_birthday_benefits', false\)/i);
  const bootstrap = source.slice(0, source.indexOf('-- -------------------------------------------------------------------------\n-- Private programme'));
  assert.doesNotMatch(bootstrap, /birthday_programs/i,
    'the migration bootstrap must not seed a starter programme or entitlement');
  const executableSql = source.replace(/--[^\n]*/g, '');
  assert.doesNotMatch(executableSql, /(?:create\s+table\s+public\.[a-z_]*(?:outbox|inbox)|\b(?:enqueue|send_sms|send_email)\b)/i,
    'C45 must not promise or enqueue outbound notification delivery');
});

test('C45 programme history is one-per-config, immutable when published, cloned, and composite-bound', async () => {
  const sql = await read(sourcePath);
  assert.match(sql, /birthday_program_versions_one_program_per_config_uk unique \(business_id, config_version_id\)/i);
  assert.match(sql, /birthday_program_versions_id_config_business_uk unique \(id, config_version_id, business_id\)/i);
  assert.match(sql, /customer_birthday_entitlements_program_provenance_fk[\s\S]*birthday_program_versions\(id, config_version_id, business_id\)/i);
  assert.match(sql, /birthday_program_draft_operations_config_fk[\s\S]*firm_config_versions\(id, business_id\)/i);
  assert.match(sql, /birthday_program_draft_operations_program_fk[\s\S]*birthday_programs\(id, business_id\)/i);
  assert.match(sql, /customer_birthday_activation_operations_entitlement_fk[\s\S]*customer_birthday_entitlements\(id, business_id, client_id, identity_id\)/i);
  assert.match(sql, /customer_birthday_redemptions_entitlement_fk[\s\S]*customer_birthday_entitlements\(id, business_id, client_id\)/i);
  assert.match(sql, /c45_clone_birthday_programs_on_draft[\s\S]*new\.based_on_version_id/i);
  assert.match(sql, /published birthday configuration is immutable/i);
  assert.match(sql, /birthday_programs',coalesce\(/i, 'the snapshot must include C45 rules');
  assert.match(sql, /only one birthday program may exist in a configuration version/i);
});

test('C45 keeps DOB private and uses only an explicit Singapore calendar boundary', async () => {
  const sql = await read(sourcePath);
  const context = fn(sql, 'c45_customer_birthday_context');
  const readBenefit = fn(sql, 'customer_get_birthday_benefit');
  const activate = fn(sql, 'customer_activate_birthday_benefit');
  assert.match(context, /app\.v32_customer_wallet_context\(p_business_slug\)/i);
  assert.match(context, /cp\.birth_date[\s\S]*from public\.customer_profiles cp/i);
  assert.match(context, /active customer identity|required/i);
  assert.match(sql, /timezone\('Asia\/Singapore', p_as_of\)/i);
  assert.match(sql, /generate_series\([\s\S]*local_now\)::integer - 1[\s\S]*\+ 1/i);
  assert.match(sql, /extract\(month from p_birth_date\) = 2[\s\S]*extract\(day from p_birth_date\) = 29[\s\S]*make_date\(p_year, 2, 28\)/i);
  assert.match(sql, /at time zone 'Asia\/Singapore'/i);
  assert.match(sql, /valid_until > valid_from/i);
  assert.match(sql, /window_days_before \+ window_days_after \+ 1 <= 365/i);
  assert.match(readBenefit, /return coalesce\(v_benefit, jsonb_build_object\('status','unavailable'\)\)/i);
  assert.match(activate, /return app\.c45_safe_birthday_entitlement/i,
    'public activation must return only the safe projection after the private context is used');
  const safe = fn(sql, 'c45_safe_birthday_entitlement');
  const staffSafe = fn(sql, 'c45_staff_safe_birthday_entitlement');
  assert.doesNotMatch(safe, /birthday_year|identity_id|client_id|program_id|config_version_id|discount_percent|savings|cost/i);
  assert.match(safe, /'validity',\s*jsonb_build_object\([\s\S]*available_from[\s\S]*available_until/i,
    'the customer may receive its own truthful half-open validity range');
  assert.doesNotMatch(staffSafe, /'validity'|'available_from'|'available_until'|'valid_from'|'valid_until'|'birthday_year'|'observed_date'|'birth_date'|'dob'|'description'|'terms'/i,
    'the counter projection must contain no date or DOB-derived inference material');
  assert.match(staffSafe, /p_entitlement\.status = 'available' and p_entitlement\.valid_until <= p_as_of then 'expired'/i,
    'staff expiry is an effective projection, not a persisted error-path update');
});

test('C45 separates participation from marketing and preserves an existing promise after opt-out', async () => {
  const sql = await read(sourcePath);
  assert.match(sql, /customer_birthday_participation[\s\S]*opted_in boolean not null default false/i);
  assert.match(sql, /separate from every marketing preference/i);
  assert.match(sql, /customer_get_birthday_participation/i);
  const helper = fn(sql, 'c45_customer_birthday_benefit_for_context');
  assert.match(helper, /valid_until > p_as_of/i);
  assert.match(helper, /existing promise remains visible after opt-out/i);
  const activate = fn(sql, 'customer_activate_birthday_benefit');
  assert.match(activate, /customer_birthday_participation[\s\S]*p\.opted_in/i);
  for (const table of ['customer_birthday_participation_operations', 'birthday_program_draft_operations', 'customer_birthday_activation_operations']) {
    assert.match(sql, new RegExp(`trg_c45_${table.replace('customer_birthday_', 'birthday_').replace(/s$/, '')}_immutable|${table}`, 'i'));
  }
  assert.match(sql, /c45_append_only_guard/i);
});

test('C45 lifecycle is self-scoped, idempotent, immutable, and never mutates money or sales', async () => {
  const sql = await read(sourcePath);
  const activate = fn(sql, 'customer_activate_birthday_benefit');
  const staffRead = fn(sql, 'staff_get_customer_birthday_benefit');
  const redeem = fn(sql, 'redeem_customer_birthday_benefit');
  const internalReverse = fn(sql, 'reverse_customer_birthday_benefit_redemption');
  const reverse = fn(sql, 'reverse_customer_birthday_benefit_for_client');
  assert.match(activate, /customer_birthday_entitlements_customer_year_uk|business_id=v_context\.business_id[\s\S]*birthday_year=v_window\.birthday_year/i);
  assert.match(activate, /request_hash is distinct from v_request_hash[\s\S]*40001/i);
  assert.match(redeem, /p_business_id uuid,[\s\S]*p_client_id uuid,[\s\S]*p_branch_id uuid/i);
  assert.doesNotMatch(redeem, /p_entitlement_id/i, 'customer-safe counter workflow cannot depend on an ID exposed to a customer');
  assert.match(redeem, /app\.can_module_write\(p_business_id,'loyalty'\)/i);
  assert.match(redeem, /re-check after the lock[\s\S]*replayed',true/i,
    'same-key retry must be rechecked after the entitlement lock');
  assert.match(redeem, /staff_branches/i);
  assert.match(redeem, /request_hash is distinct from v_hash[\s\S]*40001/i);
  assert.match(redeem, /birthday redemption conflicts with an existing operation/i);
  assert.match(redeem, /valid_until<=v_as_of[\s\S]*raise exception 'birthday benefit unavailable'/i);
  assert.doesNotMatch(redeem, /update\s+public\.customer_birthday_entitlements[\s\S]*status\s*=\s*'expired'/i,
    'an expired redemption must not write and then raise, because the raise rolls back the write');
  assert.match(staffRead, /return app\.c45_staff_safe_birthday_entitlement/i);
  const customerReader = fn(sql, 'c45_customer_birthday_benefit_for_context');
  assert.match(customerReader, /e\.birthday_year = v_window\.birthday_year[\s\S]*if found then return app\.c45_safe_birthday_entitlement/i,
    'the customer reader must derive effective expiry for the current immutable promise');
  assert.match(customerReader, /Outside the current birthday window[\s\S]*effective expired state/i,
    'past immutable promise history must expose an effective expired state without a write');
  assert.match(reverse, /app\.c45_owner_loyalty_write/i);
  assert.match(reverse, /app\.reverse_customer_birthday_benefit_redemption/i);
  assert.match(sql, /a reversal reason is required/i);
  assert.doesNotMatch(reverse, /staff_branches/i, 'an active authorized owner need not be assigned to the original branch');
  assert.match(sql, /operation_kind\s*=\s*'reversal'/i);
  assert.match(sql, /revoke all on function app\.reverse_customer_birthday_benefit_redemption\(uuid,text,uuid\) from public, anon, authenticated/i);
  assert.doesNotMatch(sql, /grant execute on function public\.reverse_customer_birthday_benefit_redemption/i);
  assert.doesNotMatch(sql, /(?:credit_ledger|points_ledger|sales\s+set|refund_sale|amount_cents)/i,
    'C45 is a manual non-cash benefit and must not mutate a monetary sale/credit ledger');
  for (const [name, operationalPath] of Object.entries({staffRead, redeem, internalReverse, reverse})) {
    assert.match(operationalPath,
      /begin\s+if not app\.platform_feature_enabled\('customer_birthday_benefits'\) then\s+raise exception 'birthday benefit unavailable' using errcode='0A000';/i,
      `${name} must fail closed before authorization, client lookup, or state mutation when C45 is disabled`);
  }
});

test('C45 forward-wraps C44 without changing its source and ranks only actionable birthday CTAs with the full comparator', async () => {
  const [c44, c45] = await Promise.all([
    read('db/migrations/20260721_frenly_v44_actionable_customer_wallet.sql'), read(sourcePath)
  ]);
  assert.doesNotMatch(c44, /birthday_benefit/i, 'C44 remains historically byte-stable');
  assert.match(c45, /rename to c45_base_actionable_wallet_card/i);
  const wrapper = fn(c45, 'c44_actionable_wallet_card');
  assert.match(wrapper, /v_birthday->>'status' not in \('ready_to_activate','available'\)/i);
  assert.match(wrapper, /coalesce\(v_birthday->>'cta',''\) not in \('activate','show_at_counter'\)/i);
  assert.match(wrapper, /v_birthday_band < v_base_band[\s\S]*v_birthday_deadline < v_base_deadline[\s\S]*0 < v_base_units/i);
  assert.match(wrapper, /'birthday_benefit',v_birthday/i);
  assert.match(c44, /filter \(where action_rank <= 100\)[\s\S]*bool_or\(action_rank > 100\)/i,
    'C45 must preserve C44’s full-set rank then 100+1 truncation algorithm');
});

test('C45 wallet UI has a truthful separate consent seam, no DOB disclosure, accessible counter actions, and stale guards', async () => {
  const app = await read('app/index.html');
  const wallet = app.slice(app.indexOf('async function renderCustomerWallet'), app.indexOf('async function renderCustomerNotificationPreferences'));
  assert.match(app, /customer_birthday_benefits:false/i);
  assert.match(app, /customerFeatures\.customer_birthday_benefits/i);
  assert.match(wallet, /customer_get_birthday_participation/i);
  assert.match(wallet, /customer_set_birthday_participation/i);
  assert.match(wallet, /customer_activate_birthday_benefit/i);
  assert.match(app, /renderCustomerWallet\(businessSlug\)/i, 'consent success must refresh the actionable card');
  assert.match(app, /walletDate\(validity\.available_until,true\)/i, 'exclusive end must include an instant, not a misleading date');
  assert.match(app, /Show this screen to the team at the counter\. No birthday details are shared with the business\./i);
  assert.match(app, /Your date of birth is used by Frenly[\s\S]*not shown to businesses[\s\S]*separate from marketing/i);
  assert.match(wallet, /walletSectionStillCurrent\(host,isWalletCurrent\)/i);
  assert.match(wallet, /if\(!walletSectionStillCurrent\(host,isWalletCurrent\)\|\|!toggle\.isConnected\)return;/i);
  assert.match(app, /birthdayBenefitActivate[\s\S]*if\(!isWalletCurrent\(\)\|\|!birthdayActivate\.isConnected\)return;/i);
  assert.match(app, /\.btn\.sm\{[\s\S]*min-height:44px/i);
  const clientDetail = app.slice(app.indexOf('async function clientDetail'), app.indexOf('/* catalog / milestone redemption'));
  assert.match(clientDetail, /const birthdayBenefitsEnabled=customerFeatures\.customer_birthday_benefits===true/i);
  assert.match(clientDetail, /birthdayBenefitsEnabled\s*\?sb\.rpc\('staff_get_customer_birthday_benefit'/i,
    'staff detail must not call the birthday reader while C45 is disabled');
  assert.match(clientDetail, /birthdayBenefitsEnabled&&birthdayBenefit&&birthdayBenefit\.status!=='unavailable'/i,
    'staff detail must omit the birthday card when C45 is disabled');
  assert.match(clientDetail, /select\('id,business_id,full_name,phone,email,gender,referral_code,marketing_consent'\)/i,
    'staff detail must not fetch DOB to render a birthday benefit');
  assert.doesNotMatch(clientDetail, /c\.birth_date/i,
    'staff detail must not display DOB');
  assert.doesNotMatch(clientDetail, /birthdayBenefit\.validity|birthdayBenefit\.description|available_until|available_from|walletDate\(birthdayBenefit/i,
    'staff detail must not render the customer-only birthday validity window');
  assert.match(clientDetail, /never sees the customer’s birthday date or validity window/i);
});

test('C45 local-only DB suite and two-session harness document exhaustive rollback and synthetic cleanup without being run here', async () => {
  const [suite, harness] = await Promise.all([
    read('db/tests/v45_birthday_benefits.sql'), read('db/tests/v45_birthday_benefits_concurrency.sh')
  ]);
  assert.match(suite, /^begin;/im);
  assert.match(suite, /^rollback;/im);
  for (const term of ['default off', 'owner', 'loyalty-r', 'loyalty-rw', 'denied', 'foreign', 'anon', 'consent', 'DOB', 'Asia/Singapore', 'SG midnight', 'Feb 29', 'December/January', 'cross-year', 'replay', 'conflict', 'expired', 'reversal', 'RLS', 'ACL', 'outbox']) {
    assert.match(suite, new RegExp(term, 'i'));
  }
  assert.match(suite, /create or replace function pg_temp\.as_c45_user/i);
  assert.match(suite, /customer_activate_birthday_benefit/i);
  assert.match(suite, /feature_not_supported/i);
  assert.match(suite, /reverse_customer_birthday_benefit_for_client/i);
  assert.match(harness, /C45_CONFIRM_DISPOSABLE_DB=YES/i);
  assert.match(harness, /synthetic-fixture-cleanup/i);
  assert.match(harness, /same-key two-session activation/i);
  assert.match(harness, /different-key loser conflict/i);
  assert.match(harness, /reversal[\s\S]*expiry|expiry[\s\S]*reversal/i);
  assert.match(harness, /same-key activation responses were not exact replays/i);
  assert.match(harness, /same-key reversal did not succeed in both sessions/i);
  assert.match(harness, /exclusive expiry-boundary race/i);
  assert.match(harness, /effective expired state is derived from valid_until/i);
  assert.match(harness, /c45_staff_safe_birthday_entitlement/i);
  assert.doesNotMatch(harness, /select status from public\.customer_birthday_entitlements/i,
    'the concurrency harness must assert effective expiry rather than persisted status');
  assert.match(harness, /gadpooereceldfpfxsod/i);
});
