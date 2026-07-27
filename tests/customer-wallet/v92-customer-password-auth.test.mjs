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
  assert.match(login,/autocomplete="current-password"/);
  assert.match(login,/sb\.auth\.signInWithPassword\(\{phone,password,options:\{captchaToken:challenge\}\}\)/);
  assert.match(login,/Normal sign-in does not send an OTP/);
  assert.doesNotMatch(login,/signInWithOtp|signUp|auth\.resend|verifyOtp|loadCustomerPhoneOtpCapabilities|customerPhoneOtpAvailable/);
  assert.match(login,/id="customerCreateAccount"/);
  assert.match(login,/id="customerForgotPassword"/);
});

test('account creation uses phone and password, then one verification OTP',()=>{
  const start=section('async function renderCustomerOtpStart','async function runCustomerRegistrationProfileSubmission');
  const verify=section('function renderCustomerOtpVerification','function renderCustomerRecoveryPasswordSetup');
  assert.match(start,/sb\.auth\.signUp\(\{phone,password,options\}\)/);
  assert.match(start,/customerSignupPasswordConfirm/);
  assert.match(verify,/verifyOtp\(\{phone,token,type:'sms'\}\)/);
  assert.match(verify,/sb\.auth\.resend\(\{type:'sms',phone,options\}\)/);
  assert.match(supabaseConfig,/\[auth\.sms\][\s\S]*?enable_signup = true[\s\S]*?enable_confirmations = true/);
});

test('forgot password OTP cannot create an account and ends at password login',()=>{
  const start=section('async function renderCustomerOtpStart','async function runCustomerRegistrationProfileSubmission');
  const verify=section('function renderCustomerOtpVerification','function renderCustomerRecoveryPasswordSetup');
  const recovery=section('function renderCustomerRecoveryPasswordSetup','function renderCustomerPasswordSignIn');
  assert.match(start,/signInWithOtp\(\{phone,options:\{\.\.\.options,shouldCreateUser:false\}\}\)/);
  assert.match(verify,/rememberCustomerRecoveryVerified\(true\)/);
  assert.match(recovery,/sb\.auth\.updateUser\(\{password:password\.value\}\)/);
  assert.match(recovery,/await sb\.auth\.signOut\(\)/);
  assert.match(recovery,/resetClientSessionState\(\{preserveInvitation:true\}\)/);
  assert.match(recovery,/renderCustomerPasswordSignIn/);
});

test('verified password recovery survives a refresh without entering the wallet',()=>{
  const registration=section('async function renderCustomerRegistration','const CUSTOMER_PRIMARY_NAV');
  assert.match(app,/CUSTOMER_RECOVERY_SESSION_KEY='nestly\.customer\.passwordRecoveryVerified'/);
  assert.match(registration,/if\(customerRecoveryVerified\(\)\)return renderCustomerRecoveryPasswordSetup\(isRouteCurrent\)/);
  assert.match(app,/rememberCustomerRecoveryVerified\(false\)/);
});

test('pending business QR survives auth and profile is completed before join',()=>{
  const login=section('function renderCustomerPasswordSignIn','async function renderCustomerOtpStart');
  const registration=section('async function renderCustomerRegistration','const CUSTOMER_PRIMARY_NAV');
  assert.match(login,/resetClientSessionState\(\{preserveInvitation:true\}\);[\s\S]*route\(\)/);
  assert.match(registration,/customer_get_profile[\s\S]*if\(profile\?\.profile!==null&&profile\?\.profile!==undefined\)\{[\s\S]*customerRegistrationDestinationPriority/);
  assert.match(registration,/return renderCustomerRegistrationProfile\(isRouteCurrent\)/);
});
