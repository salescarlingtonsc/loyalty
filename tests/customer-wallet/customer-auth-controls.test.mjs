import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

const app=await readFile(new URL('../../app/index.html',import.meta.url),'utf8');
const ui=await readFile(new URL('../../app/customer-ui.js',import.meta.url),'utf8');
const sw=await readFile(new URL('../../app/sw.js',import.meta.url),'utf8');

const section=(start,end)=>{
  const from=app.indexOf(start),to=app.indexOf(end,from);
  assert.ok(from>=0&&to>from,`missing section ${start}`);
  return app.slice(from,to);
};

test('password fields have accessible visibility controls and Face ID sits beside customer password',()=>{
  const helper=section('function passwordControlHtml','function bindPasswordVisibility');
  const visibility=section('function bindPasswordVisibility','function normalizeSingaporeCustomerPhone');
  const login=section('function renderCustomerPasswordSignIn','async function renderCustomerOtpStart');
  const recovery=section('function renderCustomerRecoveryPasswordSetup','function renderCustomerPasswordSignIn');
  const signup=section('async function renderCustomerOtpStart','async function runCustomerRegistrationProfileSubmission');
  const profile=section('async function renderCustomerProfile','async function renderCustomerQrJoin');
  const businessAuth=section('function renderAuth(','function validNewPassword(');

  assert.match(helper,/locale='en'/);
  assert.match(helper,/authSecurityCopy\(locale,'showPassword'\)/);
  assert.match(helper,/data-password-show-label="\$\{esc\(showLabel\)\}"/);
  assert.match(helper,/aria-label="\$\{esc\(showLabel\)\}"/);
  assert.match(helper,/aria-controls="\$\{esc\(id\)\}"/);
  assert.match(helper,/CUI\.icon\('eye'/);
  assert.match(helper,/CUI\.icon\('faceId'/);
  assert.match(visibility,/input\.type=showing\?'password':'text'/);
  assert.match(visibility,/button\.dataset\.passwordShowLabel/);
  assert.match(visibility,/button\.dataset\.passwordHideLabel/);
  assert.match(visibility,/aria-pressed/);
  assert.match(login,/passkeyButtonId:'customerPasskeySignIn'/);
  assert.doesNotMatch(login,/Use Face ID, Touch ID or passkey<\/span>/);
  assert.match(recovery,/passwordControlHtml\('customerRecoveryPassword'/);
  assert.match(signup,/passwordControlHtml\('customerSignupPassword'/);
  assert.match(profile,/passwordControlHtml\('customerProfilePassword'/);
  assert.match(businessAuth,/passwordControlHtml\('pw'/);
  for(const icon of ['eye','eyeOff','faceId'])assert.match(ui,new RegExp(`${icon}:`));
});

test('forgot-password OTP requires a session and password update verifies the exact user',()=>{
  const verify=section('function renderCustomerOtpVerification','function customerPasswordUpdateErrorMessage');
  const recovery=section('function renderCustomerRecoveryPasswordSetup','function renderCustomerPasswordSignIn');
  assert.match(verify,/verifyOtp\(\{phone,token,type:'sms'\}\)/);
  assert.match(verify,/if\(error\|\|!data\?\.user\|\|!data\?\.session\)/);
  assert.match(verify,/rememberCustomerRecoveryVerified\(data\.user\.id\)/);
  assert.match(recovery,/sb\.auth\.getUser\(\)/);
  assert.match(recovery,/userData\.user\.id!==S\.user\?\.id/);
  assert.match(recovery,/sb\.auth\.updateUser\(\{password:password\.value\}\)/);
  assert.match(recovery,/id="customerRecoveryPasswordBack"/);
  assert.match(recovery,/await sb\.auth\.signOut\(\)/);
});

test('global recovery guard is user-bound and precedes every authenticated route dispatch',()=>{
  const router=section('async function route()','/* ---------- customer wallet ---------- */');
  const registration=section('async function renderCustomerRegistration','const CUSTOMER_PRIMARY_NAV');
  assert.match(app,/function customerRecoveryDisposition\(recoveryUserId,sessionUserId\)/);
  assert.match(router,/customerRecoveryDisposition\(customerRecoveryVerified\(\),S\.user\?\.id\|\|''\)/);
  assert.match(router,/if\(recoveryDisposition==='clear'\)rememberCustomerRecoveryVerified\(''\)/);
  assert.match(router,/if\(recoveryDisposition==='require_password'\)\{[\s\S]*return renderCustomerRecoveryPasswordSetup/);
  assert.ok(router.indexOf("if(recoveryDisposition==='require_password')")<router.indexOf("if(h.startsWith('#/b/'))"));
  assert.match(registration,/if\(customerRecoveryVerified\(\)===S\.user\.id\)/);
});

test('auth-control cache identity changes with the versioned customer UI asset',()=>{
  assert.match(app,/<script src="\/customer-ui\.js\?v=20260728-auth-controls"><\/script>/);
  assert.match(sw,/CACHE_VERSION='v5-20260802-v138-peekaa-convergence'/);
});
