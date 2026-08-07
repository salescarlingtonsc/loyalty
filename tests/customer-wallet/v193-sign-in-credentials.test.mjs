import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('../../', import.meta.url);
const read = (file) => readFile(new URL(file, root), 'utf8');
const appJs = await read('app/app.js');

function section(source, start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0, `missing section start: ${start}`);
  assert.ok(to > from, `missing section end: ${end}`);
  return source.slice(from, to);
}
const signIn = section(appJs, 'function renderCustomerPasswordSignIn(', 'async function renderCustomerOtpStart(');
const turnstile = section(appJs, 'async function mountTurnstile(', 'const CUSTOMER_WHATSAPP_OTP_RUNTIME_ENABLED');

/* ------------------------------------------------- a password manager can see a login here */

test('the sign-in fields live in a real form a password manager can read', () => {
  assert.match(signIn, /<form id="customerPasswordForm" novalidate>/);
  assert.match(signIn, /<\/form>/);
  assert.match(signIn, /name="username" type="tel" inputmode="tel" autocomplete="username webauthn"/,
    'a manager pairs a credential to the username field — autocomplete="tel" is not that');
  assert.match(signIn, /passwordControlHtml\('customerPassword',\{autocomplete:'current-password',passkeyButtonId:'customerPasskeySignIn',name:'password'\}\)/);
  assert.match(signIn, /id="customerPasswordSignIn" type="submit"/,
    'a type="button" never fires the submit that browsers listen for');
});

test('the password control can carry a form field name', () => {
  const control = section(appJs, 'function passwordControlHtml(', 'function bindPasswordVisibility');
  assert.match(control, /locale='en',name=''\}=\{\}\)\{/);
  assert.match(control, /name\?`name="\$\{esc\(name\)\}"`:''/);
});

test('sign-in runs from the form submit, so Enter works and the browser prompts', () => {
  assert.match(signIn, /const submitSignIn=async\(\)=>\{/);
  assert.match(signIn, /signInForm\.onsubmit=event=>\{event\.preventDefault\(\);submitSignIn\(\)\}/);
  assert.match(signIn, /else signIn\.onclick=submitSignIn;/, 'no form is still a working button');
  assert.doesNotMatch(signIn, /signIn\.onclick=async\(\)=>\{/);
});

test('a successful sign-in offers the credential to the browser’s own manager', () => {
  assert.match(signIn, /globalThis\.PasswordCredential&&navigator\.credentials\?\.store/);
  assert.match(signIn, /new globalThis\.PasswordCredential\(\{id:phone,password,name:phone\}\)/);
  assert.match(signIn, /\}catch\{\}/, 'a browser without the API must not break sign-in');
  // it runs only after the sign-in succeeded
  const store = signIn.indexOf('navigator.credentials?.store');
  const failure = signIn.indexOf('The mobile number or password is incorrect.');
  assert.ok(failure > 0 && failure < store, 'the failure path returns before anything is stored');
});

/* --------------------------------------- an interactive challenge must say it is waiting for YOU */

test('a Cloudflare checkbox stops pretending the app is still loading', () => {
  // V206: the generation guard (`live()`) replaced the raw `destroyed` check on every callback,
  // and the interactive handoff now also drives the stall watchdog — disarmed the moment the
  // checkbox appears, re-armed once the user is back to a silent "loading" wait.
  assert.match(turnstile, /'before-interactive-callback':\(\)=>\{if\(!live\(\)\)return;stopStall\(\);message\(security\('interactive'\)\)\}/);
  assert.match(turnstile, /'after-interactive-callback':\(\)=>\{if\(!live\(\)\)return;armStall\(mine\);message\(security\('loading'\)\)\}/);
  for (const locale of ['en', "'zh-CN'", 'ms']) {
    assert.ok(appJs.includes('interactive:'), `${locale} needs the interactive copy`);
  }
  assert.match(appJs, /interactive:'Tick “Verify you are human” above to continue\.'/);
  assert.match(appJs, /interactive:'请勾选上方的“确认您是真人”以继续。'/);
  assert.match(appJs, /interactive:'Tandakan “Verify you are human” di atas untuk meneruskan\.'/);
});

test('the blocked buttons explain what is actually blocking them', () => {
  assert.match(signIn, /signIn\.querySelector\('span'\)\.textContent=token\?'Sign in':'Waiting for security check…'/,
    '"Checking…" claimed the app was busy when it was waiting for the person');
  assert.match(signIn, /Complete the security check above first — then Face ID, Touch ID or your passkey\./);
  assert.match(signIn, /Passkeys are not supported in this browser\. Sign in with your password\./);
  // the gate itself is unchanged: no token, no sign-in
  assert.match(signIn, /passkeyButton\.disabled=!passkeySupported\|\|!token/);
  assert.match(signIn, /if\(!captchaToken\)\{/);
});

test('passkey sign-in still runs through the enabled client', () => {
  assert.match(appJs, /experimental:\{passkey:true\}/,
    'signInWithPasskey throws unless the client opts into the experimental API');
  assert.match(signIn, /await sb\.auth\.signInWithPasskey\(\{options:\{captchaToken:challenge\}\}\)/);
  assert.match(signIn, /typeof sb\.auth\.signInWithPasskey==='function'/);
});
