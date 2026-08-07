import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('../../', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const app = (await read('app/index.html')) + '\n' + (await read('app/app.js'));

function section(start, end) {
  const from = app.indexOf(start), to = app.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return app.slice(from, to);
}

test('the root route is the customer sign-in for anyone without a session', () => {
  const registration = section('async function renderCustomerRegistration(', 'const CUSTOMER_LOCALES=');
  assert.match(registration, /\n  return renderCustomerPasswordSignIn\(isRouteCurrent\);\n\}/,
    'the signed-out path must end at sign-in, never at a sign-up form');
  // the router sends "/" and #/ here
  assert.match(app, /if\(h==='#\/'\|\|h==='#\/customer'\|\|h==='#\/customer\/register'\|\|h\.startsWith\('#\/customer\?'\)\) return renderCustomerRegistration/);
  assert.match(app, /id="customerCreateAccount" type="button">Create account<\/button>/,
    'creating an account stays one tap from sign-in');
});

test('a sign-up that was never finished lands on sign-in instead of a form it cannot submit', () => {
  const registration = section('async function renderCustomerRegistration(', 'const CUSTOMER_LOCALES=');
  assert.match(registration, /if\(!customerSignupConsentRecorded\(\)\)\{/);
  assert.match(registration, /await sb\.auth\.signOut\(\);\s*\n\s*resetClientSessionState\(\);\s*\n\s*S\.user=null;/,
    'the unusable session must be cleared, not carried forward into the next visit');
  assert.match(registration, /That sign-up was never finished\./);
  assert.match(registration, /noticeTone:'info'/, 'this is not a success message');
  // and the guard must sit BEFORE the profile form is rendered
  const guard = registration.indexOf("if(!customerSignupConsentRecorded())");
  const profile = registration.indexOf('return renderCustomerRegistrationProfile(isRouteCurrent);');
  assert.ok(guard > 0 && guard < profile, 'the stranded case must be caught before the form renders');
});

test('the setup form always offers a way out', () => {
  const profile = section('function renderCustomerRegistrationProfile(', 'async function renderCustomerRegistration(');
  assert.match(profile, /id="customerProfileStartOver"/);
  assert.match(profile, /Start again<\/button>/);
  assert.match(profile, /resetClientSessionState\(\);resetCustomerRegistrationState\(\);S\.user=null;/);
  assert.match(profile, /Signed out\. Tap Create account to start again\./);
  // the dead end that made this necessary is still the reason the button exists
  assert.match(profile, /Consent was not recorded\. Return to Create account/);
});

test('the sign-in notice can carry a plain message, not only a green one', () => {
  const signIn = section('function renderCustomerPasswordSignIn(', 'async function renderCustomerOtpStart(');
  assert.match(signIn, /\{notice='',noticeTone='success'\}=\{\}/);
  assert.match(signIn, /noticeTone==='success'\?';color:var\(--green\)':''/);
});
