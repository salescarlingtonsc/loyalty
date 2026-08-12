import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../..', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');
const [canonical, source, app, v163] = await Promise.all([
  read('supabase/migrations/20260721135556_frenly_c42_consumer_registration_contracts.sql'),
  read('db/migrations/20260721_frenly_v42_consumer_registration_contracts.sql'),
  Promise.all([read('app/index.html'),read('app/app.js')]).then(f=>f.join('\n')),
  read('supabase/migrations/20260804180000_nestly_v163_signup_lead_management_consent.sql')
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

test('customer authentication defaults to password while signup and recovery alone use OTP', () => {
  const customerRoute = block(app, /let customerRegistrationState=[\s\S]*?async function renderCustomerClaim\(/i);
  const auth = block(app, /function renderAuth\([\s\S]*?function validNewPassword\(/i);
  /* V274: bare "/" serves the marketing landing now, so the customer-app link says /app. */
  assert.match(auth, /href="\/app"/);
  assert.match(auth, /I’m a customer/);
  assert.match(app, /h==='#\/'\|\|h==='#\/customer'\|\|h==='#\/customer\/register'\|\|h\.startsWith\('#\/customer\?'\)/);
  assert.match(app, /href="\/business">Business sign in<\/a>/);
  assert.match(app, /CUSTOMER_PHONE_OTP_RUNTIME_ENABLED[\s\S]*RUNTIME_CONFIG\.environment!=='production'/);
  assert.match(app, /RUNTIME_CONFIG\.customerPhoneOtpEnabled===true/);
  assert.match(customerRoute, /normalizeSingaporeCustomerPhone/);
  assert.match(customerRoute, /\?`\+65\$\{local\}`:null/);
  assert.match(customerRoute, /preAuthSb\.rpc\('get_customer_phone_otp_capabilities'\)/);
  assert.match(customerRoute, /await customerPhoneOtpAvailable\(channel\)/);
  assert.match(customerRoute, /serverCapabilities\.whatsapp===true/);
  assert.match(customerRoute, /signInWithPassword\(\{phone,password,options:\{captchaToken:challenge\}\}\)/);
  assert.match(customerRoute, /signUp\(\{phone,password,options\}\)/);
  assert.match(customerRoute, /signInWithOtp\(\{phone,options:\{\.\.\.options,shouldCreateUser:false\}\}\)/);
  assert.match(customerRoute, /auth\.resend\(\{type:'sms',phone,options\}\)/);
  assert.match(customerRoute, /verifyOtp\(\{phone,token,type:'sms'\}\)/);
  assert.match(customerRoute, /\$\{whatsappAvailable\?`<label[^`]*customerOtpWhatsapp[^`]*<span>WhatsApp<\/span><\/label>`:''\}/,
    'WhatsApp OTP is shown only after both runtime and server capability are live');
  assert.doesNotMatch(customerRoute, /coming soon/i,
    'an unavailable OTP provider must be hidden instead of advertised as a placeholder');
  assert.match(customerRoute, /Mobile verification is not available right now\./);
  assert.match(customerRoute, /id="customerOtpSend" type="button" disabled/,
    'the primary OTP action must start disabled in both available and unavailable states');
  assert.doesNotMatch(customerRoute, /id="customerOtpSend"[^>]*\$\{smsAvailable\?'disabled':''\}/,
    'an unavailable SMS provider must not render an enabled button without a handler');
  assert.match(customerRoute, /id="customerDob" type="date"/);
  assert.match(customerRoute, /id="customerSignupConsent" type="checkbox"/);
  assert.match(customerRoute, /id="customerSignupMarketing" type="checkbox"/);
  assert.doesNotMatch(customerRoute, /id="customerProfileConsent" type="checkbox"/);
  assert.doesNotMatch(customerRoute, /id="customerMarketing" type="checkbox"/);
  assert.doesNotMatch(customerRoute, /id="customerSignupConsent"[^>]*checked=["']checked["']/i);
  assert.match(customerRoute, /Yes — send me offers and updates/i);
  // V265 (owner ruling C, 2026-08-09): the withdrawal route moved from "Profile → Marketing
  // choices" to the Communications screen, and the tick now also fires the v263 master grant.
  assert.match(customerRoute, /turn this off any time in Profile → Communications/i);
  assert.match(customerRoute, /if\(!\$\('customerSignupConsent'\)\.checked\)/);
  assert.match(customerRoute, /if\(!customerSignupConsentRecorded\(\)\)/);
  assert.match(customerRoute, /id="customerGender"/);
  assert.match(customerRoute, /<option value="female">Female<\/option><option value="male">Male<\/option>/);
  assert.match(customerRoute, /p_gender:gender/);
  assert.match(customerRoute, /p_platform_marketing_opted_in:customerSignupMarketingOptedIn\(\)/);
  assert.match(customerRoute, /Resend available in 30 seconds/);
  assert.match(customerRoute, /customer_register_verified_phone/);
  assert.match(app, /customer_join_business_from_qr_v89/);
  assert.match(customerRoute, /data\?\.outcome!=='registered'/);
  assert.match(customerRoute, /customerRegistrationDestinationPriority\(pendingCustomerJoinToken,pendingCustomerBusinessSlug\)==='join'[\s\S]*if\(location\.hash==='#\/join'\)route\(\);else nav\('#\/join'\);[\s\S]{0,20}?return 'navigated'/); /* v281: same-hash-safe */
  assert.match(customerRoute, /nav\(takePendingCustomerDestination\('#\/wallet'\)\)/);
  assert.match(customerRoute, /if\(S\.user\)[\s\S]*customer_get_profile[\s\S]*profile\?\.profile!==null[\s\S]*nav\(takePendingCustomerDestination\('#\/wallet'\)\);return;/i);
  assert.doesNotMatch(customerRoute, /[🎉🎁📱]/u);
});

test('V163 customer signup persists owner-requested male/female gender through the private registration RPC', () => {
  assert.match(v163, /alter table public\.customer_profiles[\s\S]*add column if not exists gender text[\s\S]*check \(gender in \('female','male'\)\)/i);
  assert.match(v163, /drop function if exists public\.customer_register_verified_phone\(\s*text, date, text, boolean, boolean, boolean, text\s*\)/i);
  assert.match(v163, /create or replace function public\.customer_register_verified_phone\(\s*p_full_name text,\s*p_birth_date date,\s*p_gender text,/i);
  assert.match(v163, /v_gender text := lower\(nullif\(btrim\(p_gender\), ''\)\)/i);
  assert.match(v163, /v_gender not in \('female','male'\)/i);
  assert.match(v163, /identity_id, auth_user_id, full_name, birth_date, gender, preferred_language/i);
  assert.match(v163, /full_name = excluded\.full_name, gender = excluded\.gender, preferred_language = excluded\.preferred_language/i);
  assert.match(v163, /'full_name', p\.full_name, 'birth_date', p\.birth_date, 'gender', p\.gender, 'preferred_language'/i);
  assert.match(v163, /revoke all on function public\.customer_register_verified_phone\(\s*text, date, text, text, boolean, boolean, boolean, text\s*\)/i);
  assert.match(v163, /grant execute on function public\.customer_register_verified_phone\(\s*text, date, text, text, boolean, boolean, boolean, text\s*\) to authenticated/i);
});

test('production phone OTP has no fixed-number bypass and requires the explicit runtime provider seam', () => {
  const runtimeSource = block(app, /const customerPhoneOtpRuntimeConfigured=\(\)=>\([\s\S]*?\n\);/);
  const productionGuardSource = block(app, /const customerPhoneBlockedInProduction=\(\)=>\([\s\S]*?\n\);/);
  assert.doesNotMatch(app, /DEMO_CUSTOMER_PHONE_NUMBERS/);
  assert.match(runtimeSource, /RUNTIME_CONFIG\.customerPhoneOtpEnabled===true/);
  assert.match(productionGuardSource, /RUNTIME_CONFIG\.environment==='production'/);
  assert.match(productionGuardSource, /!customerPhoneOtpRuntimeConfigured\(\)/);

  const buildGuard = ({environment, runtimeEnabled}) => new Function(
    'RUNTIME_CONFIG',
    `${runtimeSource}\n${productionGuardSource}\nreturn customerPhoneBlockedInProduction;`
  )({environment, customerPhoneOtpEnabled:runtimeEnabled});

  const productionDefault = buildGuard({environment:'production', runtimeEnabled:false});
  assert.equal(productionDefault('+6581234567'), true,
    'the former demo mobile must not bypass the production provider gate');
  assert.equal(productionDefault('+6587654321'), true,
    'every production mobile must stay blocked by default');
  assert.equal(buildGuard({environment:'production', runtimeEnabled:true})('+6587654321'), false,
    'the explicit runtime provider seam may enable production mobile verification');
  assert.equal(buildGuard({environment:'development', runtimeEnabled:false})('+6587654321'), false,
    'non-production transport remains governed by its separate runtime capability gate');
  assert.doesNotMatch(app, /888888/,
    'the Auth test OTP must remain provider configuration, never a client-side bypass');
});

test('pre-auth OTP capability checks cannot inherit a stale persisted session', () => {
  assert.match(app, /const preAuthSb=window\.supabase\.createClient\(SB_URL,SB_KEY,\{auth:\{\s*storageKey:'nestly-preauth-anon',persistSession:false,\s*autoRefreshToken:false,detectSessionInUrl:false/);
  assert.match(app, /preAuthSb\.rpc\('get_customer_phone_otp_capabilities'\)/);
  assert.doesNotMatch(
    app,
    /const \{data,error\}=await sb\.rpc\('get_customer_phone_otp_capabilities'\)/
  );
});

test('signup/recovery OTP initial send and resend use fresh server capability checks', () => {
  const customerRoute = block(app, /let customerRegistrationState=[\s\S]*?async function renderCustomerClaim\(/i);
  const otpStart = block(customerRoute, /async function renderCustomerOtpStart\([^\n]*\)[\s\S]*?(?=async function runCustomerRegistrationProfileSubmission)/i);
  const verification = block(customerRoute, /function renderCustomerOtpVerification\([^\n]*\)[\s\S]*?(?=async function runCustomerRegistrationProfileSubmission)/i);

  assert.match(otpStart,
    /loadCustomerPhoneOtpCapabilities\(\{refresh:true\}\)[\s\S]*await customerPhoneOtpAvailable\(channel\)/i,
    'each explicit signup/recovery page visit and initial send must use current server flags');
  assert.match(verification,
    /resend\.onclick=async\(\)=>\{[\s\S]*customerPhoneBlockedInProduction\(phone\)[\s\S]*await customerPhoneOtpAvailable\(channel\)[\s\S]*auth\.resend\(\{type:'sms',phone,options\}\)/i,
    'resend must independently re-check both the production allowlist and current server flags');
  assert.ok((customerRoute.match(/loadCustomerPhoneOtpCapabilities\(\{refresh:true\}\)/g) || []).length >= 2,
    'the render path and transport availability helper must both force a fresh capability read');
  assert.ok((customerRoute.match(/await customerPhoneOtpAvailable\(channel\)/g) || []).length >= 2,
    'initial send and resend must both refresh immediately before calling Auth');
});

test('wallet gates a phone-registration-enabled session on a completed private profile', () => {
  const context = block(app,
    /async function loadCustomerSurfaceContext\([\s\S]*?async function renderCustomerProgrammes\(/i);
  const wallet = block(app,/async function renderCustomerWallet\([\s\S]*?async function renderCustomerNotificationPreferences\(/i);
  assert.match(context, /customer_phone_registration===true/i);
  assert.match(context, /(?:sb\.rpc|customerRpc)\('customer_get_profile'\)/i);
  assert.match(context, /customerSurfaceQualifies\(profile,customer\)/i);
  assert.match(context, /renderNoCustomerDestination\(staff\)/i);
  assert.doesNotMatch(context, /renderCustomerRegistrationProfile\(\)/i);
  assert.match(wallet,/loadCustomerSurfaceContext\(isWalletCurrent\)/);
});
