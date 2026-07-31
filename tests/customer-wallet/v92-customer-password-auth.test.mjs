import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const app=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');
const supabaseConfig=await readFile(new URL('../../supabase/config.toml',import.meta.url),'utf8');
const section=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from);
  assert.ok(from>=0&&to>from,`missing section ${start}`);
  return app.slice(from,to);
};

test('normal customer login uses phone and password without touching OTP transport',()=>{
  const login=section('function renderCustomerPasswordSignIn','async function renderCustomerOtpStart');
  assert.match(login,/passwordControlHtml\('customerPassword',\{autocomplete:'current-password',passkeyButtonId:'customerPasskeySignIn'\}\)/);
  assert.match(login,/sb\.auth\.signInWithPassword\(\{phone,password,options:\{captchaToken:challenge\}\}\)/);
  assert.match(login,/Normal sign-in does not send an OTP/);
  assert.doesNotMatch(login,/signInWithOtp|signUp|auth\.resend|verifyOtp|loadCustomerPhoneOtpCapabilities|customerPhoneOtpAvailable/);
  assert.match(login,/id="customerCreateAccount"/);
  assert.match(login,/id="customerForgotPassword"/);
  assert.doesNotMatch(login,/previously used OTP-only sign-in/);
});

test('account creation uses phone and password, then one verification OTP',()=>{
  const start=section('async function renderCustomerOtpStart','async function runCustomerRegistrationProfileSubmission');
  const verify=section('function renderCustomerOtpVerification','function renderCustomerRecoveryPasswordSetup');
  assert.match(start,/sb\.auth\.signUp\(\{phone,password,options\}\)/);
  assert.match(start,/customerSignupPasswordConfirm/);
  assert.match(start,/id="customerSignupLegal" type="checkbox"/);
  assert.match(start,/id="customerSignupMarketing" type="checkbox"/);
  assert.match(start,/if\(!\$\('customerSignupLegal'\)\.checked\)/);
  assert.match(start,/marketingOptedIn:recovering\?false:\$\('customerSignupMarketing'\)\.checked/);
  assert.match(start,/selected partners as described in the Privacy Notice/);
  assert.match(start,/\$\('customerOtpBack'\)\.onclick=\(\)=>\{[\s\S]*resetCustomerRegistrationState\(\)/);
  assert.match(verify,/verifyOtp\(\{phone,token,type:'sms'\}\)/);
  assert.match(verify,/sb\.auth\.resend\(\{type:'sms',phone,options\}\)/);
  assert.match(supabaseConfig,/\[auth\.sms\][\s\S]*?enable_signup = true[\s\S]*?enable_confirmations = true/);
});

test('fresh signup clears abandoned consent while immediate OTP back preserves it',()=>{
  const login=section('function renderCustomerPasswordSignIn','async function renderCustomerOtpStart');
  const start=section('async function renderCustomerOtpStart','async function runCustomerRegistrationProfileSubmission');
  const verify=section('function renderCustomerOtpVerification','function customerPasswordUpdateErrorMessage');
  assert.match(app,/function resetCustomerRegistrationState\(\{phone=''\}=\{\}\)/);
  assert.match(login,/id="customerCreateAccount"[\s\S]*resetCustomerRegistrationState\(\);[\s\S]*renderCustomerOtpStart\(isRouteCurrent,'signup'\)/);
  assert.match(start,/id="customerSignupLegal" type="checkbox" \$\{customerRegistrationState\.legalAccepted\?'checked':''\}/);
  assert.match(start,/id="customerSignupMarketing" type="checkbox" \$\{customerRegistrationState\.marketingOptedIn\?'checked':''\}/);
  assert.match(verify,/customerOtpVerifyBack[\s\S]*renderCustomerOtpStart\(isRouteCurrent,purpose\)/);
  assert.doesNotMatch(verify,/customerOtpVerifyBack[\s\S]*resetCustomerRegistrationState/);
});

test('forgot password OTP cannot create an account and ends at password login',()=>{
  const start=section('async function renderCustomerOtpStart','async function runCustomerRegistrationProfileSubmission');
  const verify=section('function renderCustomerOtpVerification','function renderCustomerRecoveryPasswordSetup');
  const recovery=section('function renderCustomerRecoveryPasswordSetup','function renderCustomerPasswordSignIn');
  assert.match(start,/signInWithOtp\(\{phone,options:\{\.\.\.options,shouldCreateUser:false\}\}\)/);
  assert.match(verify,/rememberCustomerRecoveryVerified\(data\.user\.id\)/);
  assert.match(verify,/if\(error\|\|!data\?\.user\|\|!data\?\.session\)/);
  assert.match(recovery,/sb\.auth\.getUser\(\)/);
  assert.match(recovery,/userData\.user\.id!==S\.user\?\.id/);
  assert.match(recovery,/sb\.auth\.updateUser\(\{password:password\.value\}\)/);
  assert.match(recovery,/customerPasswordUpdateErrorMessage\(error\)/);
  assert.match(recovery,/id="customerRecoveryPasswordBack"/);
  assert.match(recovery,/await sb\.auth\.signOut\(\)/);
  assert.match(recovery,/resetClientSessionState\(\{preserveInvitation:true\}\)/);
  assert.match(recovery,/renderCustomerPasswordSignIn/);
});

test('installed app makes one best-effort automatic passkey attempt with password fallback',()=>{
  const login=section('function renderCustomerPasswordSignIn','async function renderCustomerOtpStart');
  assert.match(app,/let customerAutomaticPasskeyAttempted=false/);
  assert.match(login,/navigator\?\.standalone===true/);
  assert.match(login,/matchMedia\?\.\('\(display-mode: standalone\)'\)/);
  assert.match(login,/installedApp&&passkeySupported&&!customerAutomaticPasskeyAttempted/);
  assert.match(login,/customerAutomaticPasskeyAttempted=true/);
  assert.match(login,/runPasskeySignIn\(\{automatic:true\}\)/);
  assert.match(login,/Passkey sign-in was not completed\. Use your password or the Face ID button\./);
});

test('password fields expose accessible visibility controls and Face ID stays beside customer password',()=>{
  const helper=section('function passwordControlHtml','function bindPasswordVisibility');
  const visibility=section('function bindPasswordVisibility','function resetCustomerRegistrationState');
  const login=section('function renderCustomerPasswordSignIn','async function renderCustomerOtpStart');
  const recovery=section('function renderCustomerRecoveryPasswordSetup','function renderCustomerPasswordSignIn');
  const signup=section('async function renderCustomerOtpStart','async function runCustomerRegistrationProfileSubmission');
  const profile=section('async function renderCustomerProfile','async function renderCustomerQrJoin');

  assert.match(helper,/const showLabel=authSecurityCopy\(locale,'showPassword'\),hideLabel=authSecurityCopy\(locale,'hidePassword'\)/);
  assert.match(helper,/data-password-show-label="\$\{esc\(showLabel\)\}"/);
  assert.match(helper,/aria-label="\$\{esc\(showLabel\)\}"/);
  assert.doesNotMatch(helper,/aria-label="Show password"/);
  assert.match(helper,/aria-controls="\$\{esc\(id\)\}"/);
  assert.match(helper,/CUI\.icon\('eye'/);
  assert.match(helper,/CUI\.icon\('faceId'/);
  assert.match(visibility,/input\.type=showing\?'password':'text'/);
  assert.match(visibility,/aria-pressed/);
  assert.match(login,/passkeyButtonId:'customerPasskeySignIn'/);
  assert.doesNotMatch(login,/Use Face ID, Touch ID or passkey<\/span>/);
  assert.match(recovery,/passwordControlHtml\('customerRecoveryPassword'/);
  assert.match(signup,/passwordControlHtml\('customerSignupPassword'/);
  assert.match(profile,/passwordControlHtml\('customerProfilePassword'/);
});

test('OTP and password recovery surfaces provide predictable back navigation',()=>{
  const verify=section('function renderCustomerOtpVerification','function customerPasswordUpdateErrorMessage');
  const recovery=section('function renderCustomerRecoveryPasswordSetup','function renderCustomerPasswordSignIn');
  assert.match(verify,/id="customerOtpVerifyBack"/);
  assert.match(verify,/renderCustomerOtpStart\(isRouteCurrent,purpose\)/);
  assert.match(recovery,/id="customerRecoveryPasswordBack"/);
  assert.match(recovery,/rememberCustomerRecoveryVerified\(''\)/);
  assert.doesNotMatch(recovery,/rememberCustomerRecoveryVerified\(false\)/);
  assert.match(recovery,/renderCustomerPasswordSignIn\(isRouteCurrent\)/);
});

test('verified password recovery survives a refresh without entering the wallet',()=>{
  const registration=section('async function renderCustomerRegistration','const CUSTOMER_PRIMARY_NAV');
  const router=section('async function route()','/* ---------- customer wallet ---------- */');
  assert.match(app,/CUSTOMER_RECOVERY_SESSION_KEY='nestly\.customer\.passwordRecoveryVerified'/);
  assert.match(registration,/if\(customerRecoveryVerified\(\)===S\.user\.id\)return renderCustomerRecoveryPasswordSetup\(isRouteCurrent\)/);
  assert.match(router,/const recoveryDisposition=customerRecoveryDisposition\(customerRecoveryVerified\(\),S\.user\?\.id\|\|''\)/);
  assert.match(router,/if\(recoveryDisposition==='clear'\)rememberCustomerRecoveryVerified\(''\)/);
  assert.match(router,/if\(recoveryDisposition==='require_password'\)\{[\s\S]*?return renderCustomerRecoveryPasswordSetup\(isRouteCurrent\)/);
  assert.ok(
    router.indexOf("if(recoveryDisposition==='require_password')")
      <router.indexOf("if(h.startsWith('#/b/'))"),
    'recovery must be guarded before any authenticated customer, portal, join, claim, or platform dispatch',
  );
  assert.match(app,/rememberCustomerRecoveryVerified\(''\)/);
});

test('recovery guard binds the OTP session to one user and rejects marker mismatch',()=>{
  const source=app.match(/function customerRecoveryDisposition\(recoveryUserId,sessionUserId\)\{[\s\S]*?\n\}/)?.[0];
  assert.ok(source,'missing recovery disposition helper');
  const disposition=Function(`${source};return customerRecoveryDisposition`)();
  assert.equal(disposition('','customer-a'),'none');
  assert.equal(disposition('customer-a','customer-a'),'require_password');
  assert.equal(disposition('customer-a','customer-b'),'clear');
  assert.equal(disposition('customer-a',''),'clear');
});

test('pending business QR survives auth and profile is completed before join',()=>{
  const login=section('function renderCustomerPasswordSignIn','async function renderCustomerOtpStart');
  const registration=section('async function renderCustomerRegistration','const CUSTOMER_PRIMARY_NAV');
  assert.match(login,/resetClientSessionState\(\{preserveInvitation:true\}\);[\s\S]*route\(\)/);
  assert.match(registration,/customer_get_profile[\s\S]*if\(profile\?\.profile!==null&&profile\?\.profile!==undefined\)\{[\s\S]*customerRegistrationDestinationPriority/);
  assert.match(registration,/return renderCustomerRegistrationProfile\(isRouteCurrent\)/);
});

test('profile exposes a server-backed marketing consent withdrawal control',()=>{
  const profile=section('async function renderCustomerProfile','async function renderCustomerQrJoin');
  assert.match(profile,/customer_get_platform_marketing_preference/);
  assert.match(profile,/id="customerProfileMarketing"/);
  assert.match(profile,/customer_set_platform_marketing_preference/);
  assert.match(profile,/p_opted_in:optedIn,p_idempotency_key:marketingAttempt\.key/);
  assert.match(profile,/Marketing consent withdrawn\./);
});
