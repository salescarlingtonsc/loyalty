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

function block(sourceText, expression) {
  return sourceText.match(expression)?.[0] ?? '';
}

test('C42 canonical and source migrations are byte-identical forward-only contracts', () => {
  assert.equal(source, canonical);
  assert.match(canonical, /^-- FRENLY C42[\s\S]*?\bbegin;$/im);
  assert.match(canonical, /commit;\s*$/i);
  assert.match(canonical, /customer_phone_otp', false/i);
  assert.match(canonical, /customer_whatsapp_otp', false/i);
  assert.match(canonical, /customer_phone_registration', false/i);
  assert.match(canonical, /customer_phone_claims', false/i);
  assert.doesNotMatch(canonical, /insert\s+into\s+app\.customer_legal_documents/i,
    'unapproved legal versions must not be invented or auto-enabled');
});

test('C42 preserves email proof and adds Auth-derived phone proof without copying raw phone data', () => {
  assert.match(canonical, /contact_type in \('email', 'phone'\)/i);
  assert.match(canonical, /contact_type = 'email'[\s\S]{0,350}auth_email_confirmation/i);
  assert.match(canonical, /contact_type = 'phone' and proof_method = 'auth_phone_otp'/i);
  const registration = block(canonical, /create or replace function public\.customer_register_verified_phone[\s\S]*?\n\$\$;/i);
  assert.match(registration, /v_actor uuid := auth\.uid\(\)/i);
  assert.match(registration, /select u\.phone, u\.phone_confirmed_at/i);
  assert.match(registration, /v_phone_confirmed_at is null[\s\S]*nullif\(btrim\(v_phone\), ''\) is null/i);
  assert.doesNotMatch(registration, /p_phone\s+/i);
  for (const tableName of ['customer_profiles', 'customer_legal_acceptances', 'customer_registration_preferences', 'customer_registration_operations']) {
    const table = block(canonical, new RegExp(`create table public\\.${tableName}[\\s\\S]*?\\n\\);`, 'i'));
    assert.ok(table, `${tableName} is required`);
    assert.doesNotMatch(table, /^\s*(?:phone|mobile)\s+(?:text|varchar|citext)\b/im,
      `${tableName} must not duplicate raw phone data`);
  }
});

test('C42 profile, legal acceptance, and operation evidence remain private and self-derived', () => {
  assert.match(canonical, /create table public\.customer_profiles/i);
  assert.match(canonical, /birth_date date not null/i);
  assert.match(canonical, /if new\.birth_date > current_date/i);
  assert.match(canonical, /alter table public\.customer_profiles enable row level security/i);
  assert.match(canonical, /revoke all privileges on table public\.customer_profiles from public, anon, authenticated/i);
  assert.match(canonical, /create table public\.customer_legal_acceptances/i);
  assert.match(canonical, /document_version text not null[\s\S]*document_sha256 text not null/i);
  assert.match(canonical, /customer_legal_acceptances_exact_uk/i);
  assert.match(canonical, /customer_legal_acceptances_immutable_guard/i);
  assert.match(canonical, /customer_registration_operations[\s\S]*request_hash text not null[\s\S]*response jsonb not null/i);
  assert.match(canonical, /customer_registration_operations_immutable_guard/i);
  for (const name of ['customer_register_verified_phone', 'customer_get_profile', 'customer_update_profile']) {
    const fn = block(canonical, new RegExp(`create or replace function public\\.${name}[\\s\\S]*?\\n\\$\\$;`, 'i'));
    assert.match(fn, /security definer/i);
    assert.match(fn, /set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
    assert.match(fn, /auth\.uid\(\)/i);
  }
  const register = block(canonical, /create or replace function public\.customer_register_verified_phone[\s\S]*?\n\$\$;/i);
  assert.match(register, /pg_advisory_xact_lock/i);
  assert.match(register, /idempotency key was already used for a different registration request/i);
  assert.match(register, /p_accept_terms is not true or p_accept_privacy is not true/i);
  assert.match(register, /customer registration is unavailable/i);
  assert.doesNotMatch(register, /jsonb_build_object\([^)]*'phone'/i);
});

test('C42 has a minimal public OTP capability gate and grants no broader browser access', () => {
  const capabilities = block(canonical,
    /create or replace function public\.get_customer_phone_otp_capabilities\(\)[\s\S]*?\n\$\$;/i);
  assert.match(capabilities, /security definer/i);
  assert.match(capabilities, /set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'/i);
  assert.match(capabilities, /'sms',[\s\S]*customer_phone_registration[\s\S]*customer_phone_otp/i);
  assert.match(capabilities, /'whatsapp',[\s\S]*customer_phone_registration[\s\S]*customer_phone_otp[\s\S]*customer_whatsapp_otp/i);
  assert.doesNotMatch(capabilities, /auth\.uid\(|auth\.users|customer_profiles|customer_links/i,
    'the unauthenticated pre-auth capability endpoint must expose only channel booleans');
  assert.match(canonical,
    /revoke all on function public\.get_customer_phone_otp_capabilities\(\) from public, anon, authenticated/i);
  assert.match(canonical,
    /grant execute on function public\.get_customer_phone_otp_capabilities\(\) to anon/i);
  assert.match(canonical,
    /grant execute on function public\.get_customer_phone_otp_capabilities\(\) to authenticated/i);
});

test('C42 phone claim is slug-led, exact-one, generic, rate-limited, and cannot reassign a historic link', () => {
  const claim = block(canonical, /create or replace function public\.customer_claim_link_by_verified_phone[\s\S]*?\n\$\$;/i);
  assert.match(claim, /auth\.uid\(\)/i);
  assert.match(claim, /select u\.phone, u\.phone_confirmed_at/i);
  assert.doesNotMatch(claim, /p_phone\s+/i);
  assert.match(claim, /app\.norm_phone\(v_phone\)/i);
  assert.match(claim, /v_candidate_count = 1/i);
  assert.match(claim, /not exists \(select 1 from public\.customer_links prior where prior\.client_id = c\.id\)/i);
  assert.match(claim, /no_link_created/i);
  assert.match(claim, /phone-claim-rate:[\s\S]*pg_advisory_xact_lock|pg_advisory_xact_lock[\s\S]*phone-claim-rate:/i);
  assert.match(claim, /customer_link_claim_attempts/i);
  assert.match(claim, /customer_link_audit_events/i);
  assert.match(canonical, /'phone_claim_linked', 'phone_claim_not_linked', 'phone_claim_rate_limited'/i);
  assert.match(canonical, /grant execute on function public\.customer_claim_link_by_verified_phone\(text, text\) to authenticated/i);
  assert.doesNotMatch(canonical, /grant execute on function public\.customer_claim_link_by_verified_phone\(text, text\) to anon/i);
});

test('customer registration UI is a mobile phone OTP path with an explicit fail-closed provider seam', () => {
  const customerRoute = block(app, /let customerRegistrationState=[\s\S]*?async function renderCustomerClaim\(/i);
  const auth = block(app, /function renderAuth\([\s\S]*?function validNewPassword\(/i);
  assert.match(auth, /id="customerAuth"/);
  assert.match(auth, /I’m a customer/);
  assert.match(app, /h==='#\/customer'\|\|h==='#\/customer\/register'/);
  assert.match(app, /CUSTOMER_PHONE_OTP_RUNTIME_ENABLED[\s\S]*RUNTIME_CONFIG\.environment!=='production'/);
  assert.match(app, /window\.__FRENLY_CUSTOMER_PHONE_OTP_ENABLED__===true/);
  assert.match(customerRoute, /normalizeSingaporeCustomerPhone/);
  assert.match(customerRoute, /\?`\+65\$\{local\}`:null/);
  assert.match(customerRoute, /sb\.rpc\('get_customer_phone_otp_capabilities'\)/);
  assert.match(customerRoute, /await customerPhoneOtpAvailable\(channel\)/);
  assert.match(customerRoute, /customerCapabilities\.customer_whatsapp_otp===true/);
  assert.match(customerRoute, /signInWithOtp\(\{phone,options\}\)/);
  assert.match(customerRoute, /verifyOtp\(\{phone,token,type:'sms'\}\)/);
  assert.match(customerRoute, /WhatsApp \$\{whatsappAvailable\?'':'— unavailable until configured'\}/);
  assert.match(customerRoute, /id="customerDob" type="date"/);
  assert.match(customerRoute, /id="customerTerms" type="checkbox"/);
  assert.match(customerRoute, /id="customerPrivacy" type="checkbox"/);
  assert.doesNotMatch(customerRoute, /id="customerTerms"[^>]*\schecked/i);
  assert.doesNotMatch(customerRoute, /id="customerPrivacy"[^>]*\schecked/i);
  assert.match(customerRoute, /This does not opt me into messages from any business/i);
  assert.match(customerRoute, /Resend available in 30 seconds/);
  assert.match(customerRoute, /customer_register_verified_phone/);
  assert.match(app, /customer_claim_link_by_verified_phone/);
  assert.match(customerRoute, /data\?\.outcome!=='registered'/);
  assert.match(customerRoute, /nav\(businesses\.length\?'#\/wallet':'#\/claim'\)/);
  assert.match(customerRoute, /if\(S\.user\)[\s\S]*customer_get_profile[\s\S]*profile\?\.profile!==null[\s\S]*nav\('#\/wallet'\)/i);
  assert.doesNotMatch(customerRoute, /[🎉🎁📱]/u);
});

test('wallet gates a phone-registration-enabled session on a completed private profile', () => {
  const wallet = block(app,
    /async function renderCustomerWallet\([\s\S]*?async function renderCustomerNotificationPreferences\(/i);
  assert.match(wallet, /customer_phone_registration===true/i);
  assert.match(wallet, /sb\.rpc\('customer_get_profile'\)/i);
  assert.match(wallet, /nav\('#\/customer'\)[\s\S]*renderCustomerRegistrationProfile\(\)/i);
  assert.ok(wallet.indexOf("sb.rpc('customer_get_profile')") < wallet.indexOf("sb.rpc('customer_get_wallet')"),
    'profile completion must be checked before the aggregate wallet reader');
});
