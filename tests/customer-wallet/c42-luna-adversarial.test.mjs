import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const [canonical, source, app] = await Promise.all([
  read('supabase/migrations/20260721135556_frenly_c42_consumer_registration_contracts.sql'),
  read('db/migrations/20260721_frenly_v42_consumer_registration_contracts.sql'),
  read('app/index.html')
]);

function sqlBlock(name) {
  const marker = new RegExp(`create or replace function public\\.${name}\\s*\\(`, 'i');
  const start = canonical.search(marker);
  assert.ok(start >= 0, `C42 function ${name} is missing`);
  const remaining = canonical.slice(start);
  const end = remaining.search(/\ncreate or replace function\b|\nrevoke all on function\b/i);
  return end < 0 ? remaining : remaining.slice(0, end);
}

function appBlock(startMarker, endMarker) {
  const start = app.indexOf(startMarker);
  assert.notEqual(start, -1, `missing app marker ${startMarker}`);
  const end = app.indexOf(endMarker, start + startMarker.length);
  assert.notEqual(end, -1, `missing app boundary ${endMarker}`);
  return app.slice(start, end);
}

test('Luna C42: canonical and materialized migration are identical', () => {
  assert.equal(source, canonical, 'the review target must be the deployable C42 text');
});

test('Luna C42: phone possession is taken only from Auth confirmation and no new table duplicates raw phone', () => {
  const registration = sqlBlock('customer_register_verified_phone');
  const claim = sqlBlock('customer_claim_link_by_verified_phone');

  for (const block of [registration, claim]) {
    assert.match(block, /v_actor uuid := auth\.uid\(\)/i);
    assert.match(block, /select u\.phone, u\.phone_confirmed_at/i);
    assert.doesNotMatch(block, /p_(?:phone|mobile)\s+/i);
  }
  assert.match(registration, /v_phone_confirmed_at is null[\s\S]*nullif\(btrim\(v_phone\), ''\) is null/i);
  assert.match(claim, /v_phone_confirmed_at is null or v_phone_norm is null or v_business is null/i);
  for (const table of [
    'customer_profiles', 'customer_legal_acceptances',
    'customer_registration_preferences', 'customer_registration_operations'
  ]) {
    const definition = canonical.match(new RegExp(`create table public\\.${table}\\b[\\s\\S]*?\\n\\);`, 'i'))?.[0] ?? '';
    assert.ok(definition, `${table} definition is missing`);
    assert.doesNotMatch(definition, /^\s*(?:phone|mobile|phone_norm|contact_fingerprint)\b/im,
      `${table} must not persist a duplicate contact identifier`);
  }
});

test('Luna C42: registration gates are server-side, fail closed, and require two distinct legal decisions', () => {
  const registration = sqlBlock('customer_register_verified_phone');
  const capabilities = sqlBlock('get_customer_feature_capabilities');

  assert.match(registration, /not app\.platform_feature_enabled\('customer_phone_registration'\)[\s\S]*not app\.platform_feature_enabled\('customer_phone_otp'\)/i);
  assert.match(registration, /using errcode = '0A000'/i);
  assert.match(registration, /p_accept_terms is not true or p_accept_privacy is not true/i);
  assert.match(registration, /where d\.document_key = 'terms' and d\.active for share/i);
  assert.match(registration, /where d\.document_key = 'privacy' and d\.active for share/i);
  assert.match(canonical, /customer_legal_acceptances_exact_uk/i);
  assert.match(registration, /platform_marketing_opted_in/i);
  assert.doesNotMatch(registration, /marketing_consent/i,
    'platform registration must not quietly set merchant marketing consent');
  for (const flag of ['customer_phone_otp', 'customer_phone_registration', 'customer_phone_claims']) {
    assert.match(capabilities, new RegExp(`'${flag}', app\\.platform_feature_enabled\\('${flag}'\\)`, 'i'));
  }
});

test('Luna C42: future DOB is rejected at both request and persistence boundaries', () => {
  const registration = sqlBlock('customer_register_verified_phone');
  assert.match(registration, /p_birth_date > current_date/i);
  assert.match(canonical, /if new\.birth_date > current_date/i);
  assert.match(canonical, /raise exception 'birth date cannot be in the future' using errcode = '22023'/i);
  assert.match(app, /id="customerDob" type="date"[\s\S]{0,300}max="\$\{new Date\(\)\.toISOString\(\)\.slice\(0,10\)\}"/i);
});

test('Luna C42: registration replay is exact, changed payload conflicts, and every dependent write is after the idempotency reservation', () => {
  const registration = sqlBlock('customer_register_verified_phone');
  const replayAt = registration.indexOf('select * into v_existing');
  const profileAt = registration.indexOf('insert into public.customer_profiles');
  const legalAt = registration.indexOf('insert into public.customer_legal_acceptances');
  const preferencesAt = registration.indexOf('insert into public.customer_registration_preferences');
  const completionAt = registration.indexOf('insert into public.customer_registration_operations');

  assert.match(registration, /for update/i);
  assert.match(registration, /v_existing\.request_hash is distinct from v_request_hash[\s\S]*using errcode = '23505'/i);
  assert.match(registration, /return v_existing\.response/i);
  for (const position of [profileAt, legalAt, preferencesAt, completionAt]) {
    assert.ok(position > replayAt, 'a registration side effect precedes its idempotency check');
  }
  assert.match(registration, /v_response := jsonb_build_object\('outcome', 'registered', 'profile_ready', true\)/i);
});

test('Luna C42: new profile, legal, preference, and operation stores are RLS-enabled and browser-closed', () => {
  for (const table of [
    'customer_profiles', 'customer_legal_acceptances',
    'customer_registration_preferences', 'customer_registration_operations'
  ]) {
    assert.match(canonical, new RegExp(`alter table public\\.${table} enable row level security`, 'i'));
    assert.match(canonical, new RegExp(`revoke all privileges on table public\\.${table} from public, anon, authenticated`, 'i'));
  }
  assert.match(canonical, /customer_legal_acceptances_immutable_guard/i);
  assert.match(canonical, /customer_registration_operations_immutable_guard/i);
  assert.match(canonical, /customer_profiles_guard/i);
  for (const signature of [
    'customer_register_verified_phone\\(text, date, text, boolean, boolean, boolean, text\\)',
    'customer_get_profile\\(\\)',
    'customer_update_profile\\(text, text, text\\)',
    'customer_claim_link_by_verified_phone\\(text, text\\)'
  ]) {
    assert.match(canonical, new RegExp(`revoke all on function public\\.${signature}\\s+from public, anon, authenticated`, 'i'));
    assert.match(canonical, new RegExp(`grant execute on function public\\.${signature}\\s+to authenticated`, 'i'));
  }
});

test('Luna C42: OTP UI has labelled numeric entry, generic failure copy, challenge binding, and a disabled resend cooldown', () => {
  const registrationUi = appBlock('let customerRegistrationState=', 'async function renderCustomerClaim(');
  assert.match(registrationUi, /<label for="customerPhone">Singapore mobile number<\/label>/);
  assert.match(registrationUi, /id="customerOtp" inputmode="numeric" autocomplete="one-time-code" pattern="\[0-9\]\{6\}" maxlength="6"/);
  assert.match(registrationUi, /id="customerOtpError" role="alert" aria-live="assertive"/);
  assert.match(registrationUi, /action:'frenly_customer_otp'/);
  assert.match(registrationUi, /<button[^>]*id="customerOtpResend"[^>]*disabled[^>]*>Resend available in 30 seconds<\/button>/);
  assert.match(registrationUi, /That code could not be verified\. Check it and try again\./);
  assert.match(registrationUi, /We could not send a code\. Please check the number and try again\./);
  assert.doesNotMatch(registrationUi, /(?:existing account|new account|phone is already|customer found)/i,
    'OTP UI must not disclose whether the phone already has an account');
});

test('Luna C42: staff email/password authentication remains a separate path', () => {
  const auth = appBlock('function renderAuth(', 'function validNewPassword(');
  assert.match(auth, /sb\.auth\.signUp\(\{email,password,options:\{captchaToken\}\}\)/);
  assert.match(auth, /sb\.auth\.signInWithPassword\(\{email,password,options:\{captchaToken\}\}\)/);
  assert.match(auth, /id="customerAuth"/);
  assert.match(auth, /I’m a customer/);
  assert.doesNotMatch(auth, /signInWithOtp/i,
    'business sign-in must not silently switch to the customer OTP transport');
});

test('Luna C42 blocker: wallet access must require completed registration, not merely a wallet feature flag', () => {
  const wallet = appBlock('async function renderCustomerWallet(', 'async function renderCustomerNotificationPreferences(');
  assert.match(wallet, /customer_get_profile/i,
    'C42 must check a completed profile before calling customer_get_wallet or business wallet readers');
  assert.match(wallet, /profile_ready|customer profile is unavailable|renderCustomerRegistrationProfile/i,
    'an authenticated but unregistered phone user needs a registration route, not a wallet request');
});

test('Luna C42 blocker: WhatsApp must have a server capability/configuration gate, not only a mutable browser flag', () => {
  const registrationUi = appBlock('let customerRegistrationState=', 'async function renderCustomerClaim(');
  assert.match(canonical, /'customer_whatsapp_otp', false/i,
    'WhatsApp must remain disabled unless the private platform capability is explicitly enabled');
  assert.match(sqlBlock('get_customer_feature_capabilities'), /'customer_whatsapp_otp', app\.platform_feature_enabled\('customer_whatsapp_otp'\)/i);
  assert.match(registrationUi, /customerCapabilities\.customer_whatsapp_otp===true/i,
    'the UI must require server authority before offering WhatsApp delivery');
});

test('Luna C42 remediation: anonymous pre-auth capability RPC is a two-boolean, fail-closed surface with exact ACLs', () => {
  const preAuth = sqlBlock('get_customer_phone_otp_capabilities');

  assert.match(preAuth, /^create or replace function public\.get_customer_phone_otp_capabilities\(\)\s*returns jsonb/im);
  assert.match(preAuth, /return jsonb_build_object\(\s*'sms',[\s\S]*'whatsapp',[\s\S]*\)/i);
  assert.match(preAuth, /app\.platform_feature_enabled\('customer_phone_registration'\)[\s\S]*app\.platform_feature_enabled\('customer_phone_otp'\)/i);
  assert.match(preAuth, /'customer_whatsapp_otp'/i);
  assert.doesNotMatch(preAuth, /\b(?:select|auth\.|customer_profiles|auth\.users|provider|identity|email|token|secret)\b/i,
    'the pre-auth RPC must not inspect or disclose account, provider, or contact state');
  assert.match(canonical, /revoke all on function public\.get_customer_phone_otp_capabilities\(\) from public, anon, authenticated;\s*grant execute on function public\.get_customer_phone_otp_capabilities\(\) to anon;\s*grant execute on function public\.get_customer_phone_otp_capabilities\(\) to authenticated;/i);
});

test('Luna C42 remediation: both initial send and resend require non-production runtime and fresh server gates', () => {
  const registrationUi = appBlock('let customerRegistrationState=', 'async function renderCustomerClaim(');

  assert.match(app, /const CUSTOMER_PHONE_OTP_RUNTIME_ENABLED=\(\s*RUNTIME_CONFIG\.environment!==['"]production['"]/i);
  assert.match(app, /const CUSTOMER_WHATSAPP_OTP_RUNTIME_ENABLED=\(\s*CUSTOMER_PHONE_OTP_RUNTIME_ENABLED/i);
  assert.match(registrationUi, /async function customerPhoneOtpAvailable\(channel='sms'\)[\s\S]*loadCustomerPhoneOtpCapabilities\(\{refresh:true\}\)/i);
  assert.ok((registrationUi.match(/await customerPhoneOtpAvailable\(channel\)/g) || []).length >= 2,
    'both initial send and resend must check the server capability immediately before transport');
  assert.ok((registrationUi.match(/sb\.auth\.signInWithOtp\(\{phone,options\}\)/g) || []).length >= 2,
    'the test must cover both initial and resend OTP transports');
});

test('Luna C42 remediation: completed and incomplete registration routes terminate without a loop and preserve legacy wallet access', () => {
  const registrationUi = appBlock('async function renderCustomerRegistration()', 'async function renderCustomerClaim(');
  const wallet = appBlock('async function renderCustomerWallet(', 'async function renderCustomerNotificationPreferences(');
  const profileCheck = wallet.slice(wallet.indexOf("if(customerFeatures.customer_phone_registration===true)"), wallet.indexOf("const {data:walletPersonas}"));

  assert.match(registrationUi, /if\(profile\?\.profile!==null\)\{\s*nav\('#\/wallet'\);return;\s*\}/i,
    'an already-complete customer visiting registration must end at the wallet');
  assert.match(profileCheck, /customer_get_profile[\s\S]*if\(profileError\)return renderCustomerCapabilityRetry[\s\S]*if\(profile\?\.profile===null\)\{\s*nav\('#\/customer'\);\s*return renderCustomerRegistrationProfile\(\);\s*\}/i,
    'an incomplete customer must end at the profile form, rather than reach wallet readers');
  assert.ok(wallet.indexOf('customer_get_profile') < wallet.indexOf("sb.rpc('customer_get_wallet')"),
    'the registration gate must precede customer wallet reads');
  assert.match(wallet, /if\(customerFeatures\.customer_phone_registration===true\)\{[\s\S]*customer_get_profile/i,
    'existing email-wallet users remain on the prior wallet path while phone registration is disabled');
});
